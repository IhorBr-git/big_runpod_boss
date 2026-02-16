#!/bin/bash

# -- Installation & Start Script for RTX 5090 ---
# Base image: runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
# This script installs and launches AUTOMATIC1111 Stable Diffusion WebUI
# on RunPod optimized for RTX 5090 (Blackwell architecture).
#
# RTX 5090 optimizations:
#   - CUDA 12.8 base image for native Blackwell support
#   - --system-site-packages venv to reuse base image torch (no re-download)
#   - SDP attention (PyTorch native Flash Attention 2) — no xformers needed
#   - TORCH_COMMAND skipped — base image torch used as-is
#   - CLIP installed with --no-deps to prevent torch version conflicts

set -e

WEBUI_DIR="/workspace/stable-diffusion-webui"

# ---- Install system dependencies (Debian-based) ----
echo "Installing system dependencies..."
apt-get update && apt-get install -y --no-install-recommends \
    wget curl git python3 python3-venv libgl1 libglib2.0-0 google-perftools bc \
    && rm -rf /var/lib/apt/lists/*

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
# Skip torch install — already provided by the base image (torch 2.8.0 + CUDA 12.8)
export TORCH_COMMAND="echo 'Torch pre-installed in base image, skipping'"
# SDP attention uses Flash Attention 2 under the hood in PyTorch 2.0+
# No xformers needed — avoids version mismatch with base image's dev torch build
export COMMANDLINE_ARGS="--listen --port 3000 --opt-sdp-attention --enable-insecure-extension-access --no-half-vae --api"
EOF

# ---- Pre-create venv inheriting base image packages (torch 2.8.0, torchvision, CUDA 12.8) ----
echo "Setting up Python venv..."
if [ ! -d "$WEBUI_DIR/venv" ]; then
    python3.11 -m venv --system-site-packages "$WEBUI_DIR/venv"
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
git clone https://github.com/lobehub/sd-webui-lobe-theme.git "$WEBUI_DIR/extensions/lobe-theme"
git clone https://github.com/thomasasfk/sd-webui-aspect-ratio-helper.git "$WEBUI_DIR/extensions/aspect-ratio-helper"
git clone https://github.com/Coyote-A/ultimate-upscale-for-automatic1111.git "$WEBUI_DIR/extensions/ultimate-upscale"

# ---- Install File Browser (web-based file manager on port 8080) ----
echo "Installing File Browser..."
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

FB_DB="/workspace/.filebrowser.db"
if [ ! -f "$FB_DB" ]; then
    filebrowser config init --database "$FB_DB"
    filebrowser config set --address 0.0.0.0 --port 8080 --root /workspace --noauth --database "$FB_DB"
fi

# ---- Clean up ----
echo "Cleaning up..."
rm -f /workspace/install_script.sh

# ---- Start services ----
echo "Starting RunPod handler, A1111 WebUI, and File Browser..."
/start.sh &
filebrowser --database "$FB_DB" &
cd "$WEBUI_DIR" && bash webui.sh -f