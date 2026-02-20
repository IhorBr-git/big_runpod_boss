#!/bin/bash

# -- Installation & Start Script for A1111 on RTX 4090 ---
# Base image: runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04
#
# This script installs and launches AUTOMATIC1111 Stable Diffusion WebUI
# on RunPod optimized for RTX 4090.
#
# Setup:
#   - CUDA 12.4.1 — RTX 4090 (Ada Lovelace architecture)
#   - PyTorch 2.4.0+cu124 from base image (pre-installed for Python 3.11)
#   - Python 3.11 venv with --system-site-packages (inherits GPU-enabled torch)
#   - SDP attention (PyTorch native) — xformers also works well on RTX 4090
#   - CLIP installed with --no-deps to prevent torch version conflicts

set -e

WEBUI_DIR="/workspace/stable-diffusion-webui"

# ---- Install extra system dependencies ----
echo "Installing extra system dependencies..."
apt-get update && apt-get install -y --no-install-recommends \
    google-perftools bc libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# ---- Install filebrowser if not present ----
if ! command -v filebrowser &> /dev/null; then
    echo "Installing filebrowser..."
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
fi

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
python_cmd="python3"
venv_dir="venv"
# Stability-AI repos were made private (Dec 2025) — use community mirrors
export STABLE_DIFFUSION_REPO="https://github.com/w-e-w/stablediffusion.git"
# Skip torch install — already provided by the base image (torch 2.4.0 + CUDA 12.4)
export TORCH_COMMAND="pip --version"
# SDP attention uses Flash Attention 2 under the hood in PyTorch 2.0+
# xformers is also a good option on RTX 4090 but SDP keeps things simpler
export COMMANDLINE_ARGS="--listen --port 3000 --opt-sdp-attention --enable-insecure-extension-access --no-half-vae --no-download-sd-model --api --skip-python-version-check --theme=dark"
EOF

# ---- Pre-create venv inheriting system packages (torch 2.4.0+cu124 for Python 3.11) ----
echo "Setting up Python venv..."
if [ ! -d "$WEBUI_DIR/venv" ]; then
    python3 -m venv --system-site-packages "$WEBUI_DIR/venv"
fi

echo "Installing build dependencies in venv..."
"$WEBUI_DIR/venv/bin/pip" install --upgrade pip wheel
# Pin setuptools to 69.5.1 — newer versions break pkg_resources imports needed by CLIP
"$WEBUI_DIR/venv/bin/pip" install "setuptools==69.5.1"

# ---- Pre-install CLIP without dependencies (torch is already in base image) ----
echo "Pre-installing CLIP..."
"$WEBUI_DIR/venv/bin/pip" install --no-build-isolation --no-deps \
    https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip
# Install only CLIP's lightweight dependencies (not torch)
"$WEBUI_DIR/venv/bin/pip" install ftfy regex tqdm

# ---- Install extensions ----
echo "Installing extensions..."
[ ! -d "$WEBUI_DIR/extensions/aspect-ratio-helper" ] && \
    git clone https://github.com/thomasasfk/sd-webui-aspect-ratio-helper.git "$WEBUI_DIR/extensions/aspect-ratio-helper" || true
[ ! -d "$WEBUI_DIR/extensions/ultimate-upscale" ] && \
    git clone https://github.com/Coyote-A/ultimate-upscale-for-automatic1111.git "$WEBUI_DIR/extensions/ultimate-upscale" || true
[ ! -d "$WEBUI_DIR/extensions/lobe-theme" ] && \
    git clone https://github.com/lobehub/sd-webui-lobe-theme.git "$WEBUI_DIR/extensions/lobe-theme" || true
# ---- Create VRAM Guard extension (unload button next to checkpoint refresh) ----
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

# ---- File Browser (configure database) ----
FB_DB="/workspace/.filebrowser.db"
if [ ! -f "$FB_DB" ]; then
    echo "Configuring File Browser..."
    filebrowser config init --database "$FB_DB"
    filebrowser config set --address 0.0.0.0 --port 8080 --root /workspace --database "$FB_DB"
    filebrowser users add admin adminadmin11 --perm.admin --database "$FB_DB"
fi

# ---- Clean up ----
echo "Cleaning up..."
rm -f /workspace/install_script.sh

# ---- Start services ----
echo "Starting RunPod handler, A1111 WebUI, and File Browser..."
/start.sh &
filebrowser --database "$FB_DB" &
cd "$WEBUI_DIR" && bash webui.sh -f
