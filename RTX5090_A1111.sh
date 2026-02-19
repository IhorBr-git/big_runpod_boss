#!/bin/bash

# -- Installation & Start Script for A1111 on RTX 5090 ---
# Base image: runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
#
# This script installs and launches AUTOMATIC1111 Stable Diffusion WebUI
# on RunPod optimized for RTX 5090.
#
# Setup:
#   - CUDA 12.8.1 with cuDNN — RTX 5090 supported via forward-compatible PTX
#   - PyTorch 2.8.0+cu128 from base image (pre-installed for Python 3.11)
#   - Python 3.11 venv with --system-site-packages (inherits GPU-enabled torch)
#   - SDP attention (PyTorch native Flash Attention 2) — no xformers needed
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
# Skip torch install — already provided by the base image (torch 2.8.0 + CUDA 12.8)
export TORCH_COMMAND="pip --version"
# SDP attention uses Flash Attention 2 under the hood in PyTorch 2.0+
# No xformers needed — avoids version mismatch with base image's torch build
export COMMANDLINE_ARGS="--listen --port 3000 --opt-sdp-attention --enable-insecure-extension-access --no-half-vae --no-download-sd-model --api --skip-python-version-check"
EOF

# ---- Pre-create venv inheriting system packages (torch 2.8.0+cu128 for Python 3.11) ----
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
# ---- Create VRAM Guard extension (unload models & monitor VRAM from the UI) ----
VRAM_GUARD_DIR="$WEBUI_DIR/extensions/vram-guard"
if [ ! -d "$VRAM_GUARD_DIR" ]; then
    echo "Creating VRAM Guard extension..."
    mkdir -p "$VRAM_GUARD_DIR/scripts"
    cat > "$VRAM_GUARD_DIR/scripts/vram_guard.py" << 'PYEOF'
import gc
import torch
import gradio as gr
from modules import script_callbacks, shared, sd_models


def _vram_info():
    if not torch.cuda.is_available():
        return "CUDA not available"
    dev = torch.cuda.current_device()
    alloc = torch.cuda.memory_allocated(dev) / 1024**3
    total = torch.cuda.get_device_properties(dev).total_mem / 1024**3
    name = torch.cuda.get_device_name(dev)
    return (
        f"GPU:        {name}\n"
        f"Allocated:  {alloc:.2f} GB\n"
        f"Total:      {total:.2f} GB\n"
        f"Free:       {total - alloc:.2f} GB"
    )


def _flush():
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
        torch.cuda.ipc_collect()


def unload_checkpoint():
    try:
        sd_models.unload_model_weights()
    except Exception:
        pass
    _flush()
    return _vram_info()


def unload_all():
    try:
        sd_models.unload_model_weights()
    except Exception:
        pass
    _flush()
    return _vram_info()


def on_ui_tabs():
    with gr.Blocks(analytics_enabled=False) as tab:
        with gr.Column():
            gr.Markdown("## VRAM Manager")
            gr.Markdown(
                "Free GPU memory by unloading models. "
                "Useful when switching between A1111 and ComfyUI."
            )
            vram_box = gr.Textbox(
                label="VRAM Status", value=_vram_info(),
                lines=5, interactive=False,
            )
            with gr.Row():
                btn_ckpt = gr.Button("Unload Checkpoint", variant="primary")
                btn_all = gr.Button("Unload Everything", variant="stop")
                btn_ref = gr.Button("Refresh")
            btn_ckpt.click(fn=unload_checkpoint, outputs=[vram_box])
            btn_all.click(fn=unload_all, outputs=[vram_box])
            btn_ref.click(fn=_vram_info, outputs=[vram_box])
    return [(tab, "VRAM Manager", "vram_manager")]


def add_api(_demo, app):
    @app.post("/vram-guard/unload-checkpoint")
    async def api_unload_ckpt():
        return {"vram": unload_checkpoint()}

    @app.post("/vram-guard/unload-all")
    async def api_unload_all():
        return {"vram": unload_all()}

    @app.get("/vram-guard/vram-info")
    async def api_vram():
        return {"vram": _vram_info()}


script_callbacks.on_ui_tabs(on_ui_tabs)
script_callbacks.on_app_started(add_api)
PYEOF
fi

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
