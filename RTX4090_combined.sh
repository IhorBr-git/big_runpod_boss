#!/bin/bash

# -- Combined Installation & Start Script for RTX 4090 ---
# Base image: runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04
#
# This script installs and launches BOTH:
#   - AUTOMATIC1111 Stable Diffusion WebUI  (port 3000)
#   - ComfyUI                               (port 8188)
#   - File Browser                           (port 8080)
# on a single RunPod pod optimized for RTX 4090 (Ada Lovelace architecture).
#
# On pod restart (both dirs already exist) the script skips installation
# entirely and goes straight to starting services — same logic as the
# individual container start commands.
#
# Container Start Command (must use bash -c on RunPod):
#   bash -c 'cd /workspace && wget -q https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/test/start_combined.sh -O start_combined.sh && chmod +x start_combined.sh && ./start_combined.sh'
#   bash -c 'cd /workspace && wget -q https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/test/RTX4090_combined.sh -O install_script.sh && chmod +x install_script.sh && ./install_script.sh'
#
# Force full reinstall on a pod with existing /workspace: FORCE_FULL_INSTALL=1 ./install_script.sh

set -e

WEBUI_DIR="/workspace/stable-diffusion-webui"
COMFYUI_DIR="/workspace/ComfyUI"
MODELS_DIR="/workspace/models"
FB_DB="/workspace/.filebrowser.db"
A1111_PIP_CONSTRAINTS="/workspace/a1111-pip-constraints.txt"
FORCE_FULL_INSTALL="${FORCE_FULL_INSTALL:-0}"

TORCH_VERSION="2.4.0"
TORCHVISION_VERSION="0.19.0"
TORCHAUDIO_VERSION="2.4.0"
TORCH_INDEX_URL="https://download.pytorch.org/whl/cu124"
# cuDNN that ships with torch 2.4.0+cu124. The Ada base image is cuda12.4.1-devel
# (NOT a -cudnn- variant), so it carries nvidia-cudnn-cu12 only as dist-info
# metadata in the system site-packages — pip then marks it "already satisfied"
# and never copies libcudnn.so.9 into the --system-site-packages venv, crashing
# ComfyUI at `import torch`. Pin the matching wheel so it can be forced into venv.
CUDNN_VERSION="9.1.0.70"

# ------------------------------------------------------------------------------
# cleanup_pip_tilde_dirs — remove ~umpy / ~orch-* from interrupted pip installs
# ------------------------------------------------------------------------------
cleanup_pip_tilde_dirs() {
local site_dir="$1"
[ -d "$site_dir" ] || return 0
shopt -s nullglob
for _bad in "$site_dir"/~*; do rm -rf "$_bad"; done
shopt -u nullglob
}

# ------------------------------------------------------------------------------
# pip_install_filtered_reqs — install requirements without overriding torch stack
# ------------------------------------------------------------------------------
pip_install_filtered_reqs() {
local pip_bin="$1"
local req_file="$2"
local filtered
filtered="$(mktemp)"
grep -v -E '^\s*(torch|torchvision|torchaudio|xformers|triton)\s*($|[><=!~;#])' "$req_file" > "$filtered"
if [ -s "$filtered" ]; then
"$pip_bin" install -r "$filtered"
fi
rm -f "$filtered"
}

# ------------------------------------------------------------------------------
# setup_comfyui_venv — inherit base-image GPU torch; pin cu124 stack afterward
# ------------------------------------------------------------------------------
setup_comfyui_venv() {
echo "Recreating ComfyUI venv with system-site-packages (GPU-enabled torch)..."
rm -rf "$COMFYUI_DIR/venv"
python3.11 -m venv --system-site-packages "$COMFYUI_DIR/venv"
"$COMFYUI_DIR/venv/bin/pip" install --upgrade pip wheel
pip_install_filtered_reqs "$COMFYUI_DIR/venv/bin/pip" "$COMFYUI_DIR/requirements.txt"
echo "Installing ComfyUI PyTorch ${TORCH_VERSION}+cu124 (pinned)..."
"$COMFYUI_DIR/venv/bin/pip" install \
  "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" "torchaudio==${TORCHAUDIO_VERSION}" \
  --index-url "$TORCH_INDEX_URL"
ensure_comfyui_cudnn
}

# ------------------------------------------------------------------------------
# ensure_comfyui_cudnn — guarantee libcudnn.so.9 is loadable by the venv torch.
# Because the venv is created with --system-site-packages, pip sees the base
# image's nvidia-cudnn-cu12 as "already satisfied" and skips installing it into
# the venv. On the Ada base (cuda12.4.1-devel, no system cuDNN) torch then can't
# find libcudnn.so.9 and ComfyUI dies at `import torch`. Force the matching cuDNN
# wheel into the venv (its lib dir precedes system dist-packages on sys.path).
# Conditional + idempotent: a no-op whenever torch already imports cleanly.
# ------------------------------------------------------------------------------
ensure_comfyui_cudnn() {
local py="$COMFYUI_DIR/venv/bin/python"
[ -x "$py" ] || return 0
"$py" -c "import torch" 2>/dev/null && return 0
if "$py" -c "import torch" 2>&1 | grep -q 'libcudnn\.so\.9'; then
echo "ComfyUI: torch can't find libcudnn.so.9; installing nvidia-cudnn-cu12==${CUDNN_VERSION} into venv..."
"$COMFYUI_DIR/venv/bin/pip" install -q --force-reinstall --no-deps "nvidia-cudnn-cu12==${CUDNN_VERSION}" \
  || echo "WARNING: nvidia-cudnn-cu12 install failed; ComfyUI may not start" >&2
fi
}

# ------------------------------------------------------------------------------
# ensure_comfyui_torch — self-heal broken or driver-incompatible ComfyUI torch
# ------------------------------------------------------------------------------
configure_comfyui_run_gpu() {
local run_gpu="/workspace/run_gpu.sh"
[ -f "$run_gpu" ] || return 0
if ! grep -q -- '--listen' "$run_gpu"; then
sed -i '$ s/$/ --listen /' "$run_gpu"
fi
if ! grep -q -- 'enable-cors-header' "$run_gpu"; then
sed -i '$ s/$/ --enable-cors-header '"'"'*'"'"' /' "$run_gpu"
fi
chmod +x "$run_gpu"
}

reinstall_comfyui_torch_stack() {
"$COMFYUI_DIR/venv/bin/pip" install -q \
  "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" "torchaudio==${TORCHAUDIO_VERSION}" \
  --index-url "$TORCH_INDEX_URL"
# A bare torch reinstall still skips the system-satisfied cuDNN, so re-ensure it.
ensure_comfyui_cudnn
}

ensure_comfyui_torch() {
local comfy_site="$COMFYUI_DIR/venv/lib/python3.11/site-packages"
local py="$COMFYUI_DIR/venv/bin/python"
[ -x "$py" ] || return 0

cleanup_pip_tilde_dirs "$comfy_site"

# Fix the common case first (torch fine, only cuDNN missing) so we don't trigger
# a wasteful full torch uninstall/reinstall just to recover libcudnn.so.9.
ensure_comfyui_cudnn

if ! "$py" -c "import torch" 2>/dev/null; then
echo "ComfyUI: PyTorch import failed (broken partial install); reinstalling torch==${TORCH_VERSION}+cu124..."
"$COMFYUI_DIR/venv/bin/pip" uninstall -y torch torchvision torchaudio 2>/dev/null || true
rm -rf "$comfy_site"/torch "$comfy_site"/torch.lib "$comfy_site"/functorch \
  "$comfy_site"/torchvision "$comfy_site"/torchaudio \
  "$comfy_site"/torch-*.dist-info "$comfy_site"/torchvision-*.dist-info "$comfy_site"/torchaudio-*.dist-info
cleanup_pip_tilde_dirs "$comfy_site"
reinstall_comfyui_torch_stack
elif ! "$py" -c "import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
echo "ComfyUI: CUDA not available; pinning PyTorch ${TORCH_VERSION}+cu124 (matches base image)..."
reinstall_comfyui_torch_stack
elif ! "$py" -c "import torchvision; from torchvision.ops import nms" 2>/dev/null; then
# torchvision's compiled ops (e.g. torchvision::nms) fail to register when it
# was built against a different torch than the one installed. On a restart the
# venv is reused as-is, so a drifted torchvision (often dragged in by a custom
# node) crashes ComfyUI at `import torchvision` with
# "RuntimeError: operator torchvision::nms does not exist". Re-pin the matched
# torch/torchvision/torchaudio trio so they share an ABI again.
echo "ERROR: ComfyUI torchvision is broken/mismatched against torch (operator torchvision::nms unavailable); re-pinning torch==${TORCH_VERSION}/torchvision==${TORCHVISION_VERSION}/torchaudio==${TORCHAUDIO_VERSION}+cu124..." >&2
"$COMFYUI_DIR/venv/bin/pip" uninstall -y torchvision 2>/dev/null || true
rm -rf "$comfy_site"/torchvision "$comfy_site"/torchvision-*.dist-info
cleanup_pip_tilde_dirs "$comfy_site"
reinstall_comfyui_torch_stack
fi

# Final guard: if the stack is still broken after repair attempts, surface a
# loud, greppable error in the pod logs instead of letting ComfyUI crash later
# with only a deep traceback.
if ! "$py" -c "import torch, torchvision; from torchvision.ops import nms; assert torch.cuda.is_available()" 2>/dev/null; then
echo "ERROR: ComfyUI PyTorch/torchvision stack is still broken after repair attempts; ComfyUI will likely fail to start." >&2
echo "ERROR:   Expected torch==${TORCH_VERSION}+cu124 paired with torchvision==${TORCHVISION_VERSION} (CUDA available)." >&2
"$py" -c "import torch, torchvision; print('installed torch=%s torchvision=%s cuda=%s' % (torch.__version__, torchvision.__version__, torch.cuda.is_available()))" 2>&1 | sed 's/^/ERROR:   /' >&2 || true
fi
}

# ------------------------------------------------------------------------------
# ensure_comfyui_deps — on a fast restart the venv is reused as-is. If ComfyUI
# was updated to a newer checkout needing packages the old venv lacks (e.g.
# `filelock` for the new app.database layer), main.py crashes on import before
# the server starts. Probe the boot imports and reinstall requirements only when
# something is missing, so a healthy venv pays no cost.
# ------------------------------------------------------------------------------
ensure_comfyui_deps() {
[ -x "$COMFYUI_DIR/venv/bin/python" ] || return 0
if "$COMFYUI_DIR/venv/bin/python" -c "import filelock, yaml, numpy, torchsde" 2>/dev/null; then
return 0
fi
echo "ComfyUI: missing runtime deps detected; reinstalling requirements..."
cleanup_pip_tilde_dirs "$COMFYUI_DIR/venv/lib/python3.11/site-packages"
pip_install_filtered_reqs "$COMFYUI_DIR/venv/bin/pip" "$COMFYUI_DIR/requirements.txt"
if [ -f "$COMFYUI_DIR/custom_nodes/comfyui-manager/requirements.txt" ]; then
pip_install_filtered_reqs "$COMFYUI_DIR/venv/bin/pip" "$COMFYUI_DIR/custom_nodes/comfyui-manager/requirements.txt"
fi
}

# ------------------------------------------------------------------------------
# ensure_vram_guard — create the VRAM Guard extension if it doesn't exist yet.
# Called from start_services() so it works on both fresh install and pod restart.
# ------------------------------------------------------------------------------
ensure_vram_guard() {
echo "Creating VRAM Guard extension..."
mkdir -p "$WEBUI_DIR/extensions/vram-guard/scripts"
mkdir -p "$WEBUI_DIR/extensions/vram-guard/javascript"
cat > "$WEBUI_DIR/extensions/vram-guard/scripts/vram_guard.py" << 'PYEOF'
import gc
import threading
import time
import torch
from modules import script_callbacks, shared, sd_models


def _flush():
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
        torch.cuda.ipc_collect()


def _vram_str():
    if not torch.cuda.is_available():
        return "CUDA N/A"
    dev = torch.cuda.current_device()
    alloc = torch.cuda.memory_allocated(dev) / 1024**3
    total = torch.cuda.get_device_properties(dev).total_memory / 1024**3
    return f"Used: {alloc:.1f}/{total:.1f} GB"


def _unload_all():
    try:
        sd_models.unload_model_weights()
    except Exception:
        pass
    _flush()
    return _vram_str()


def _reload_model():
    try:
        # Clear stale reference so reload_model_weights() does a fresh load
        # instead of comparing checkpoint info and skipping (happens after unload).
        shared.sd_model = None
        _flush()
        sd_models.reload_model_weights()
    except Exception:
        pass
    return _vram_str()


def _model_is_loaded():
    # Read the stored model reference WITHOUT touching shared.sd_model, whose
    # lazy getter would force a checkpoint load — the opposite of what we want.
    try:
        return sd_models.model_data.sd_model is not None
    except Exception:
        return False


def _boot_unload_worker():
    # A1111 preloads the checkpoint into VRAM at startup. Wait for that initial
    # load to land, then unload it once so the pod boots with the full GPU free.
    # The model is transparently reloaded on the first generation (or via the
    # Reload button). We never yank VRAM out from under an active job.
    deadline = time.time() + 180
    while time.time() < deadline:
        time.sleep(5)
        try:
            if getattr(shared.state, "job_count", 0) > 0:
                continue
        except Exception:
            pass
        if _model_is_loaded():
            print("[vram-guard] boot unload: " + _unload_all(), flush=True)
            return


def _add_api(_demo, app):
    @app.post("/vram-guard/unload-all")
    async def api_unload_all():
        return {"vram": _unload_all()}

    @app.post("/vram-guard/reload")
    async def api_reload():
        return {"vram": _reload_model()}

    # Free VRAM on pod boot by default.
    threading.Thread(target=_boot_unload_worker, daemon=True).start()

script_callbacks.on_app_started(_add_api)
PYEOF
cat > "$WEBUI_DIR/extensions/vram-guard/javascript/vram_guard.js" << 'JSEOF'
onUiLoaded(function () {
    var qs = gradioApp().getElementById("quicksettings");
    if (!qs) return;

    function makeBtn(label, title, bg, bgHover, endpoint) {
        var b = document.createElement("button");
        b.textContent = label;
        b.title = title;
        b.style.cssText =
            "max-height:42px;margin:auto 0 auto 4px;background:" + bg + ";color:#fff;" +
            "border:none;border-radius:8px;padding:8px 16px;font-weight:600;" +
            "font-size:14px;cursor:pointer;white-space:nowrap;";
        b.addEventListener("mouseenter", function () { b.style.background = bgHover; });
        b.addEventListener("mouseleave", function () { b.style.background = bg; });
        b.addEventListener("click", async function () {
            var orig = b.textContent;
            b.textContent = "\u23F3";
            b.disabled = true;
            try {
                var r = await fetch(endpoint, { method: "POST" });
                var d = await r.json();
                b.textContent = d.vram || "Done";
                setTimeout(function () { b.textContent = orig; b.disabled = false; }, 3000);
            } catch (e) {
                b.textContent = "Error";
                setTimeout(function () { b.textContent = orig; b.disabled = false; }, 2000);
            }
        });
        return b;
    }

    qs.appendChild(makeBtn(
        "Unload Model",
        "Free VRAM \u2014 unload the current checkpoint",
        "#dc2626", "#b91c1c",
        "/vram-guard/unload-all"
    ));
    qs.appendChild(makeBtn(
        "Load Model",
        "Reload the selected checkpoint into VRAM",
        "#2563eb", "#1d4ed8",
        "/vram-guard/reload"
    ));
});
JSEOF
}

# ------------------------------------------------------------------------------
# start_services — launches all three processes and waits
# ------------------------------------------------------------------------------
start_services() {
# Ensure the VRAM Guard extension exists (covers pod restarts where install is skipped)
ensure_vram_guard

echo "========================================"
echo "Starting services..."
echo "========================================"
echo "  - RunPod handler  (/start.sh)"
echo "  - A1111 WebUI     (port 3000)"
echo "  - ComfyUI         (port 8188)"
echo "  - File Browser    (port 8080)"
echo "========================================"

# Forward SIGTERM/SIGINT to all child processes for clean container shutdown
trap 'echo "Shutting down..."; kill $(jobs -p) 2>/dev/null; wait' SIGTERM SIGINT

# Ensure File Browser binary is available (not persisted across pod restarts)
if ! command -v filebrowser &> /dev/null; then
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
fi

# Start RunPod handler (only once for both services)
/start.sh &

cleanup_pip_tilde_dirs "$WEBUI_DIR/venv/lib/python3.11/site-packages"

# Force a venv-local typing_extensions (TypeIs for gradio/altair); system-site-packages
# otherwise resolves /usr/local/.../typing_extensions.py which is often too old.
"$WEBUI_DIR/venv/bin/pip" install -q --force-reinstall "typing_extensions>=4.12.2" \
  || echo "WARNING: typing_extensions upgrade failed; A1111 may fail to import gradio"

# ControlNet's installer can leave a numpy/scikit-image combo with mismatched
# binary ABI (skimage compiled for one numpy major, a different numpy installed),
# which crashes A1111 at `from skimage import exposure`. Pinning here alone is
# NOT enough: ControlNet's own pip installs run *during* webui.sh launch (after
# this point) and pull a numpy-2 build of scikit-image on top of numpy 1.26.2.
# A pip constraints file (exported as PIP_CONSTRAINT below) forces every pip
# invocation during A1111 startup — including the extension installers — to keep
# these versions, so the ABI can't drift. mediapipe is pinned because recent
# releases (0.10.31+) dropped the legacy `solutions` API controlnet_aux needs.
cat > "$A1111_PIP_CONSTRAINTS" << 'EOF'
numpy==1.26.2
scikit-image==0.21.0
mediapipe==0.10.14
EOF
PIP_CONSTRAINT="$A1111_PIP_CONSTRAINTS" "$WEBUI_DIR/venv/bin/pip" install -q \
  "numpy==1.26.2" "scikit-image==0.21.0" "mediapipe==0.10.14" \
  || echo "WARNING: numpy/scikit-image/mediapipe pin failed; A1111 startup may break"

ensure_comfyui_torch
ensure_comfyui_deps
configure_comfyui_run_gpu

# Start A1111 WebUI (constrain every pip install it triggers so ControlNet's
# extension installers can't reintroduce the numpy/scikit-image ABI mismatch).
(cd "$WEBUI_DIR" && PIP_CONSTRAINT="$A1111_PIP_CONSTRAINTS" bash webui.sh -f) &

# Start ComfyUI (wrap so a crash is logged loudly — its traceback can scroll
# far above the prompt, so make the failure obvious and greppable in pod logs).
(
  set +e
  /workspace/run_gpu.sh
  rc=$?
  echo "ERROR: ComfyUI (port 8188) exited unexpectedly (exit code ${rc}). See the traceback above; a torch/torchvision mismatch is the usual cause." >&2
) &

# Start File Browser
filebrowser --database "$FB_DB" &

# Keep the container alive as long as any service is running
wait
}

# ==============================================================================
# Fast restart: if both are already installed, skip straight to startup
# ==============================================================================
if [ "$FORCE_FULL_INSTALL" = "1" ]; then
echo "FORCE_FULL_INSTALL=1, running full setup."
elif [ -d "$WEBUI_DIR" ] && [ -d "$COMFYUI_DIR" ]; then
echo "Both A1111 and ComfyUI already installed. Skipping installation..."
rm -f /workspace/install_script.sh /workspace/start_combined.sh
start_services
exit 0
fi

# ==============================================================================
# 1. System dependencies (Debian-based) — covers both A1111 and ComfyUI
# ==============================================================================
echo "========================================"
echo "[1/7] Installing system dependencies..."
echo "========================================"
apt-get update && apt-get install -y --no-install-recommends \
wget curl git python3 python3-venv libgl1 libglib2.0-0 google-perftools bc \
pkg-config libcairo2-dev \
&& rm -rf /var/lib/apt/lists/*

# ==============================================================================
# 2. A1111 Stable Diffusion WebUI
# ==============================================================================
echo "========================================"
echo "[2/7] Setting up A1111 WebUI..."
echo "========================================"

# ---- Clone A1111 (skip if already present for pod restarts) ----
if [ ! -d "$WEBUI_DIR" ]; then
echo "Cloning AUTOMATIC1111 Stable Diffusion WebUI..."
git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git "$WEBUI_DIR"
else
echo "WebUI already exists, pulling latest changes..."
cd "$WEBUI_DIR" && git pull
fi

# ---- Configure webui-user.sh ----
echo "Configuring webui-user.sh..."
cat > "$WEBUI_DIR/webui-user.sh" << 'EOF'
#!/bin/bash
python_cmd="python3.11"
venv_dir="venv"
# Stability-AI repos were made private (Dec 2025) — use community mirrors
export STABLE_DIFFUSION_REPO="https://github.com/w-e-w/stablediffusion.git"
# Skip torch install — already provided by the base image (torch 2.4.0 + CUDA 12.4).
export TORCH_COMMAND="echo 'Torch pre-installed in base image, skipping'"
# SDP attention uses Flash Attention 2 under the hood in PyTorch 2.0+
# xformers is also a good option on RTX 4090 but SDP keeps things simpler
export COMMANDLINE_ARGS="--listen --port 3000 --opt-sdp-attention --enable-insecure-extension-access --no-half-vae --no-download-sd-model --api --skip-python-version-check --theme=dark"
EOF

# ---- Pre-create venv inheriting base image packages (torch 2.4.0, torchvision, CUDA 12.4) ----
echo "Setting up A1111 Python venv..."
if [ ! -d "$WEBUI_DIR/venv" ]; then
python3.11 -m venv --system-site-packages "$WEBUI_DIR/venv"
fi

echo "Installing build dependencies in A1111 venv..."
"$WEBUI_DIR/venv/bin/pip" install --upgrade pip wheel
# Pin setuptools to 69.5.1 — newer versions break pkg_resources imports needed by CLIP
"$WEBUI_DIR/venv/bin/pip" install "setuptools==69.5.1"
"$WEBUI_DIR/venv/bin/pip" install "typing_extensions>=4.12.2"

# ---- Pre-install CLIP without dependencies (torch is already in base image) ----
echo "Pre-installing CLIP..."
"$WEBUI_DIR/venv/bin/pip" install --no-build-isolation --no-deps \
https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip
# Install only CLIP's lightweight dependencies (not torch)
"$WEBUI_DIR/venv/bin/pip" install ftfy regex tqdm

# ---- Install extensions (only if not already present) ----
echo "Installing A1111 extensions..."
[ ! -d "$WEBUI_DIR/extensions/aspect-ratio-helper" ] && \
git clone https://github.com/thomasasfk/sd-webui-aspect-ratio-helper.git "$WEBUI_DIR/extensions/aspect-ratio-helper" || true
[ ! -d "$WEBUI_DIR/extensions/ultimate-upscale" ] && \
git clone https://github.com/Coyote-A/ultimate-upscale-for-automatic1111.git "$WEBUI_DIR/extensions/ultimate-upscale" || true
[ ! -d "$WEBUI_DIR/extensions/lobe-theme" ] && \
git clone https://github.com/lobehub/sd-webui-lobe-theme.git "$WEBUI_DIR/extensions/lobe-theme" || true
[ ! -d "$WEBUI_DIR/extensions/sd-webui-controlnet" ] && \
git clone https://github.com/Mikubill/sd-webui-controlnet.git "$WEBUI_DIR/extensions/sd-webui-controlnet" || true
# ==============================================================================
# 3. ComfyUI
# ==============================================================================
echo "========================================"
echo "[3/7] Setting up ComfyUI..."
echo "========================================"

if [ ! -d "$COMFYUI_DIR" ]; then
echo "Installing ComfyUI and ComfyUI Manager..."
cd /workspace

# NOTE: we deliberately do NOT run the upstream install-comfyui-venv-linux.sh.
# That installer pip-installs a multi-GB torch into a throwaway venv, which we
# immediately wipe and replace with the pinned cu124 build in setup_comfyui_venv
# — minutes of bandwidth burned for nothing. Replicate just its useful side
# effects (clone + run_gpu.sh) by hand instead.
git clone https://github.com/comfyanonymous/ComfyUI "$COMFYUI_DIR"
git -C "$COMFYUI_DIR/custom_nodes" clone https://github.com/ltdrdata/ComfyUI-Manager comfyui-manager

# Recreate the GPU launcher the upstream installer would have produced.
cat > /workspace/run_gpu.sh << 'EOF'
#!/bin/bash
cd ComfyUI
source venv/bin/activate
python main.py --preview-method auto
EOF
chmod +x /workspace/run_gpu.sh

# RunPod proxy needs --listen and --enable-cors-header (host/origin mismatch → HTTP 403)
echo "Configuring ComfyUI for RunPod network access..."
configure_comfyui_run_gpu

# Install custom nodes
echo "Installing ComfyUI custom nodes..."
git -C "$COMFYUI_DIR/custom_nodes" clone https://github.com/dsigmabcn/comfyui-model-downloader.git
git -C "$COMFYUI_DIR/custom_nodes" clone https://github.com/MadiatorLabs/ComfyUI-RunpodDirect.git
git -C "$COMFYUI_DIR/custom_nodes" clone https://github.com/crystian/ComfyUI-Crystools.git

# Recreate venv inheriting base-image torch; pin cu124 before node deps
setup_comfyui_venv
pip_install_filtered_reqs "$COMFYUI_DIR/venv/bin/pip" "$COMFYUI_DIR/custom_nodes/comfyui-manager/requirements.txt"
pip_install_filtered_reqs "$COMFYUI_DIR/venv/bin/pip" "$COMFYUI_DIR/custom_nodes/ComfyUI-Crystools/requirements.txt"

# Clean up any leftover CPU runner from older installs
rm -f /workspace/run_cpu.sh
else
echo "ComfyUI already exists, skipping installation."
if [ "$FORCE_FULL_INSTALL" = "1" ]; then
setup_comfyui_venv
if [ -f "$COMFYUI_DIR/custom_nodes/comfyui-manager/requirements.txt" ]; then
pip_install_filtered_reqs "$COMFYUI_DIR/venv/bin/pip" "$COMFYUI_DIR/custom_nodes/comfyui-manager/requirements.txt"
fi
if [ -f "$COMFYUI_DIR/custom_nodes/ComfyUI-Crystools/requirements.txt" ]; then
pip_install_filtered_reqs "$COMFYUI_DIR/venv/bin/pip" "$COMFYUI_DIR/custom_nodes/ComfyUI-Crystools/requirements.txt"
fi
fi
fi

# ==============================================================================
# 4. Shared models directory
# ==============================================================================
echo "========================================"
echo "[4/7] Setting up shared models directory..."
echo "========================================"

# Create shared models root
mkdir -p "$MODELS_DIR"

# --- ComfyUI: symlink ALL model subdirectories to the shared location ---
# Dynamically discover every folder inside ComfyUI/models/ so nothing is missed
# (checkpoints, clip, clip_vision, controlnet, diffusers, diffusion_models,
#  embeddings, gligen, hypernetworks, loras, photomaker, style_models,
#  unet, upscale_models, vae, vae_approx, …and any future additions).
echo "Symlinking ComfyUI model directories to shared models..."
for comfy_subdir in "$COMFYUI_DIR/models"/*/; do
# Skip if the glob matched nothing
[ -d "$comfy_subdir" ] || continue

dir_name="$(basename "$comfy_subdir")"
shared_subdir="$MODELS_DIR/$dir_name"
mkdir -p "$shared_subdir"

# If it's a real directory (not already a symlink), migrate its contents
if [ ! -L "$comfy_subdir" ]; then
cp -rn "$comfy_subdir"* "$shared_subdir"/ 2>/dev/null || true
rm -rf "$comfy_subdir"
fi
ln -sfn "$shared_subdir" "${comfy_subdir%/}"
done

# --- A1111: symlink model directories to the same shared location ---
# Map A1111 folder names → shared folder names (where they differ)
echo "Symlinking A1111 model directories to shared models..."
declare -A A1111_MAP=(
["Stable-diffusion"]="checkpoints"
["VAE"]="vae"
["Lora"]="loras"
["hypernetworks"]="hypernetworks"
["ESRGAN"]="upscale_models"
["ControlNet"]="controlnet"
)

for a1111_name in "${!A1111_MAP[@]}"; do
shared_name="${A1111_MAP[$a1111_name]}"
src="$WEBUI_DIR/models/$a1111_name"
dst="$MODELS_DIR/$shared_name"
mkdir -p "$dst"

if [ -d "$src" ] && [ ! -L "$src" ]; then
cp -rn "$src"/* "$dst"/ 2>/dev/null || true
rm -rf "$src"
fi
ln -sfn "$dst" "$src"
done

# A1111 embeddings live at top level, not inside models/
mkdir -p "$MODELS_DIR/embeddings"
if [ -d "$WEBUI_DIR/embeddings" ] && [ ! -L "$WEBUI_DIR/embeddings" ]; then
cp -rn "$WEBUI_DIR/embeddings"/* "$MODELS_DIR/embeddings"/ 2>/dev/null || true
rm -rf "$WEBUI_DIR/embeddings"
fi
ln -sfn "$MODELS_DIR/embeddings" "$WEBUI_DIR/embeddings"

echo "Shared models directory ready at $MODELS_DIR"
echo "Shared subdirectories:"
ls -1 "$MODELS_DIR"

# ==============================================================================
# 5. File Browser (web-based file manager on port 8080)
# ==============================================================================
echo "========================================"
echo "[5/7] Setting up File Browser..."
echo "========================================"

curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

if [ ! -f "$FB_DB" ]; then
filebrowser config init --database "$FB_DB"
filebrowser config set --address 0.0.0.0 --port 8080 --root /workspace --database "$FB_DB"
filebrowser users add admin adminadmin11 --perm.admin --database "$FB_DB"
fi

# ==============================================================================
# 6. Cleanup
# ==============================================================================
echo "========================================"
echo "[6/7] Cleaning up..."
echo "========================================"
rm -f /workspace/install_script.sh

# ==============================================================================
# 7. Start all services
# ==============================================================================
start_services
