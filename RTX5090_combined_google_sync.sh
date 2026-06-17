#!/bin/bash

# -- Combined Installation & Start Script for RTX 5090 (Google Drive Sync) ---
# Base image: runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
#
# This script installs and launches BOTH:
#   - AUTOMATIC1111 Stable Diffusion WebUI  (port 3000)
#   - ComfyUI                               (port 8188)
#   - File Browser                           (port 8080)
# on a single RunPod pod optimized for RTX 5090 (Blackwell architecture).
#
# Google Drive Integration:
#   Models are mounted from Google Drive via rclone with VFS caching.
#   All files are visible immediately; actual data is downloaded on demand.
#   Requires a pre-configured rclone.conf at /workspace/.config/rclone/rclone.conf
#
# On pod restart (both dirs already exist) the script skips installation
# entirely and goes straight to starting services — same logic as the
# individual container start commands.
#
# Container Start Command (use the script for both fresh install and restart):
#   cd /workspace && wget -q https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/main/RTX5090_combined_google_sync.sh -O install_script.sh && chmod +x install_script.sh && ./install_script.sh

set -e

WEBUI_DIR="/workspace/stable-diffusion-webui"
COMFYUI_DIR="/workspace/ComfyUI"
MODELS_DIR="/workspace/models"
FB_DB="/workspace/.filebrowser.db"

# --- Google Drive rclone mount settings ---
RCLONE_CONF="/workspace/.config/rclone/rclone.conf"
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive:models}"
RCLONE_CACHE_DIR="/workspace/.cache/rclone"
RCLONE_VFS_CACHE_MAX_SIZE="${RCLONE_VFS_CACHE_MAX_SIZE:-50G}"

# ------------------------------------------------------------------------------
# mount_gdrive — mount Google Drive models folder via rclone with VFS caching.
# Files are visible immediately; data is downloaded on demand when accessed.
# Requires /workspace/.config/rclone/rclone.conf (one-time setup by user).
# ------------------------------------------------------------------------------
mount_gdrive() {
if [ ! -f "$RCLONE_CONF" ]; then
echo "========================================"
echo "WARNING: rclone config not found at $RCLONE_CONF"
echo "Google Drive mount SKIPPED — models directory will be local only."
echo ""
echo "To enable Google Drive sync:"
echo "  1. Install rclone on a machine with a browser: https://rclone.org/install/"
echo "  2. Run: rclone config"
echo "     - Choose 'n' for new remote"
echo "     - Name it: gdrive"
echo "     - Type: Google Drive (option 18 or 'drive')"
echo "     - Follow the OAuth prompts in your browser"
echo "  3. Copy the config to the pod:"
echo "     scp ~/.config/rclone/rclone.conf root@<POD_IP>:/workspace/.config/rclone/rclone.conf"
echo "  4. Restart the pod"
echo ""
echo "  Optional env vars (set in RunPod template):"
echo "    GDRIVE_REMOTE=gdrive:my_models_folder  (default: gdrive:models)"
echo "    RCLONE_VFS_CACHE_MAX_SIZE=100G          (default: 50G)"
echo "========================================"
return 0
fi

if ! command -v rclone &> /dev/null; then
echo "Installing rclone..."
if ! command -v unzip &> /dev/null; then
apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*
fi
curl -fsSL https://rclone.org/install.sh | bash
fi

if ! command -v fusermount3 &> /dev/null && ! command -v fusermount &> /dev/null; then
echo "Installing fuse3..."
apt-get update && apt-get install -y --no-install-recommends fuse3 && rm -rf /var/lib/apt/lists/*
fi

mkdir -p "$MODELS_DIR" "$RCLONE_CACHE_DIR"

if mountpoint -q "$MODELS_DIR" 2>/dev/null; then
echo "Google Drive already mounted at $MODELS_DIR"
return 0
fi

echo "Mounting Google Drive ($GDRIVE_REMOTE) to $MODELS_DIR ..."
rclone mount "$GDRIVE_REMOTE" "$MODELS_DIR" \
  --config "$RCLONE_CONF" \
  --vfs-cache-mode full \
  --vfs-cache-max-size "$RCLONE_VFS_CACHE_MAX_SIZE" \
  --vfs-read-ahead 128M \
  --dir-cache-time 30m \
  --poll-interval 1m \
  --cache-dir "$RCLONE_CACHE_DIR" \
  --allow-non-empty \
  --allow-other \
  --daemon

sleep 2
if mountpoint -q "$MODELS_DIR" 2>/dev/null; then
echo "Google Drive mounted successfully at $MODELS_DIR"
echo "  Remote:    $GDRIVE_REMOTE"
echo "  Cache dir: $RCLONE_CACHE_DIR"
echo "  Cache max: $RCLONE_VFS_CACHE_MAX_SIZE"
else
echo "ERROR: Google Drive mount failed. Falling back to local models directory."
echo "Check rclone config and remote name. Test with: rclone ls $GDRIVE_REMOTE --config $RCLONE_CONF"
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


def _add_api(_demo, app):
    @app.post("/vram-guard/unload-all")
    async def api_unload_all():
        return {"vram": _unload_all()}

    @app.post("/vram-guard/reload")
    async def api_reload():
        return {"vram": _reload_model()}

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
# Mount Google Drive before anything else (FUSE mounts don't survive restarts)
mount_gdrive

# Ensure the VRAM Guard extension exists (covers pod restarts where install is skipped)
ensure_vram_guard

echo "========================================"
echo "Starting services..."
echo "========================================"
echo "  - RunPod handler  (/start.sh)"
echo "  - A1111 WebUI     (port 3000)"
echo "  - ComfyUI         (port 8188)"
echo "  - File Browser    (port 8080)"
echo "  - Google Drive    (rclone mount)"
echo "========================================"

# Forward SIGTERM/SIGINT to all child processes for clean container shutdown
trap 'echo "Shutting down..."; fusermount -u "$MODELS_DIR" 2>/dev/null || true; kill $(jobs -p) 2>/dev/null; wait' SIGTERM SIGINT

# Ensure File Browser binary is available (not persisted across pod restarts)
if ! command -v filebrowser &> /dev/null; then
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
fi

# Start RunPod handler (only once for both services)
/start.sh &

WEBUI_SITE="$WEBUI_DIR/venv/lib/python3.11/site-packages"
if [ -d "$WEBUI_SITE" ]; then
shopt -s nullglob
for _bad in "$WEBUI_SITE"/~*; do rm -rf "$_bad"; done
shopt -u nullglob
fi

"$WEBUI_DIR/venv/bin/pip" install -q --force-reinstall "typing_extensions>=4.12.2" \
  || echo "WARNING: typing_extensions upgrade failed; A1111 may fail to import gradio"

COMFY_SITE="$COMFYUI_DIR/venv/lib/python3.11/site-packages"
if [ -d "$COMFY_SITE" ]; then
shopt -s nullglob
for _bad in "$COMFY_SITE"/~*; do rm -rf "$_bad"; done
shopt -u nullglob
fi

if [ -x "$COMFYUI_DIR/venv/bin/python" ]; then
if ! "$COMFYUI_DIR/venv/bin/python" -c "import torch" 2>/dev/null; then
echo "ComfyUI: PyTorch import failed (broken partial install); reinstalling torch==2.8.0+cu128..."
"$COMFYUI_DIR/venv/bin/pip" uninstall -y torch torchvision torchaudio 2>/dev/null || true
rm -rf "$COMFY_SITE"/torch "$COMFY_SITE"/torch.lib "$COMFY_SITE"/functorch \
  "$COMFY_SITE"/torchvision "$COMFY_SITE"/torchaudio \
  "$COMFY_SITE"/torch-*.dist-info "$COMFY_SITE"/torchvision-*.dist-info "$COMFY_SITE"/torchaudio-*.dist-info
shopt -s nullglob
for _bad in "$COMFY_SITE"/~*; do rm -rf "$_bad"; done
shopt -u nullglob
"$COMFYUI_DIR/venv/bin/pip" install -q \
  "torch==2.8.0" "torchvision==0.23.0" "torchaudio==2.8.0" \
  --index-url https://download.pytorch.org/whl/cu128
elif ! "$COMFYUI_DIR/venv/bin/python" -c "import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
echo "ComfyUI: CUDA not available; pinning PyTorch 2.8.0+cu128 to match base image..."
"$COMFYUI_DIR/venv/bin/pip" install -q \
  "torch==2.8.0" "torchvision==0.23.0" "torchaudio==2.8.0" \
  --index-url https://download.pytorch.org/whl/cu128
elif ! "$COMFYUI_DIR/venv/bin/python" -c "import torchvision; from torchvision.ops import nms" 2>/dev/null; then
# torchvision's compiled ops (torchvision::nms) fail to register when it was
# built against a different torch than the one installed. On a restart the venv
# is reused as-is, so a drifted torchvision (often dragged in by a custom node)
# crashes ComfyUI at `import torchvision` with
# "RuntimeError: operator torchvision::nms does not exist". Re-pin the matched trio.
echo "ERROR: ComfyUI torchvision is broken/mismatched against torch (operator torchvision::nms unavailable); re-pinning torch/torchvision/torchaudio 2.8.0/0.23.0/2.8.0+cu128..." >&2
"$COMFYUI_DIR/venv/bin/pip" uninstall -y torchvision 2>/dev/null || true
rm -rf "$COMFY_SITE"/torchvision "$COMFY_SITE"/torchvision-*.dist-info
shopt -s nullglob
for _bad in "$COMFY_SITE"/~*; do rm -rf "$_bad"; done
shopt -u nullglob
"$COMFYUI_DIR/venv/bin/pip" install -q \
  "torch==2.8.0" "torchvision==0.23.0" "torchaudio==2.8.0" \
  --index-url https://download.pytorch.org/whl/cu128
fi
# Final guard: surface a loud, greppable error if the stack is still broken.
if ! "$COMFYUI_DIR/venv/bin/python" -c "import torch, torchvision; from torchvision.ops import nms; assert torch.cuda.is_available()" 2>/dev/null; then
echo "ERROR: ComfyUI PyTorch/torchvision stack is still broken after repair attempts; ComfyUI will likely fail to start." >&2
echo "ERROR:   Expected torch==2.8.0+cu128 paired with torchvision==0.23.0 (CUDA available)." >&2
"$COMFYUI_DIR/venv/bin/python" -c "import torch, torchvision; print('installed torch=%s torchvision=%s cuda=%s' % (torch.__version__, torchvision.__version__, torch.cuda.is_available()))" 2>&1 | sed 's/^/ERROR:   /' >&2 || true
fi
fi

# Start A1111 WebUI
(cd "$WEBUI_DIR" && bash webui.sh -f) &

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
if [ -d "$WEBUI_DIR" ] && [ -d "$COMFYUI_DIR" ]; then
echo "Both A1111 and ComfyUI already installed. Skipping installation..."
rm -f /workspace/install_script.sh
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
wget curl git python3 python3-venv libgl1 libglib2.0-0 google-perftools bc fuse3 unzip \
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
# Skip torch install — already provided by the base image (torch 2.8.0 + CUDA 12.8).
# NOTE: RTX 5090 ideally needs cu130+ for optimized CUDA ops, but RunPod's host
# driver only supports CUDA 12.8 (version 12080), so cu130 will crash.
# cu128 works but with reduced performance on Blackwell GPUs.
export TORCH_COMMAND="echo 'Torch pre-installed in base image, skipping'"
# SDP attention uses Flash Attention 2 under the hood in PyTorch 2.0+
# No xformers needed — avoids version mismatch with base image's dev torch build
export COMMANDLINE_ARGS="--listen --port 3000 --opt-sdp-attention --enable-insecure-extension-access --no-half-vae --no-download-sd-model --api --theme=dark"
EOF

# ---- Pre-create venv inheriting base image packages (torch 2.8.0, torchvision, CUDA 12.8) ----
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
# ==============================================================================
# 3. ComfyUI
# ==============================================================================
echo "========================================"
echo "[3/7] Setting up ComfyUI..."
echo "========================================"

if [ ! -d "$COMFYUI_DIR" ]; then
echo "Installing ComfyUI and ComfyUI Manager..."
cd /workspace

# Download and run the ComfyUI-Manager install script
wget https://github.com/ltdrdata/ComfyUI-Manager/raw/main/scripts/install-comfyui-venv-linux.sh -O install-comfyui-venv-linux.sh
chmod +x install-comfyui-venv-linux.sh
./install-comfyui-venv-linux.sh

# Add the --listen flag to run_gpu.sh for network access
echo "Configuring ComfyUI for network access..."
sed -i "$ s/$/ --listen /" /workspace/run_gpu.sh
chmod +x /workspace/run_gpu.sh

# Install custom nodes
echo "Installing ComfyUI custom nodes..."
git -C "$COMFYUI_DIR/custom_nodes" clone https://github.com/dsigmabcn/comfyui-model-downloader.git
git -C "$COMFYUI_DIR/custom_nodes" clone https://github.com/MadiatorLabs/ComfyUI-RunpodDirect.git
git -C "$COMFYUI_DIR/custom_nodes" clone https://github.com/crystian/ComfyUI-Crystools.git
"$COMFYUI_DIR/venv/bin/pip" install -r "$COMFYUI_DIR/custom_nodes/ComfyUI-Crystools/requirements.txt"

# Clean up ComfyUI installer artifacts
rm -f /workspace/install-comfyui-venv-linux.sh /workspace/run_cpu.sh
else
echo "ComfyUI already exists, skipping installation."
fi

# Pin PyTorch 2.8.0 + cu128 (same generation as base image runpod/pytorch:2.8.0-cuda12.8).
# Unpinned `pip install --upgrade torch` can pull 2.10+cu130 and, if interrupted, leave
# dangling ~orch-*.dist-info and a broken torch (libtorch_global_deps.so missing).
echo "Installing ComfyUI PyTorch 2.8.0+cu128 (pinned)..."
"$COMFYUI_DIR/venv/bin/pip" install \
  "torch==2.8.0" "torchvision==0.23.0" "torchaudio==2.8.0" \
  --index-url https://download.pytorch.org/whl/cu128

# ==============================================================================
# 4. Shared models directory
# ==============================================================================
echo "========================================"
echo "[4/7] Setting up shared models directory..."
echo "========================================"

# Mount Google Drive to the shared models directory (on-demand VFS cache)
mount_gdrive

# Create shared models root (no-op if already mounted from Google Drive)
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
