#!/bin/bash

# -- Installation & Start Script for A1111 on RTX 5090 ---
# Base image: runpod/pytorch:1.0.3-cu1300-torch291-ubuntu2404
#
# This script installs and launches AUTOMATIC1111 Stable Diffusion WebUI
# on RunPod optimized for RTX 5090 (Blackwell architecture).
#
# RTX 5090 optimizations:
#   - CUDA 13.0 native — full Blackwell (sm_120) kernel support
#   - PyTorch 2.9.1+cu130 (installed for Python 3.13 at startup)
#   - Python 3.13 venv with --system-site-packages (inherits torch)
#   - SDP attention (PyTorch native Flash Attention 2) — no xformers needed
#   - CLIP installed with --no-deps to prevent torch version conflicts
#   - filebrowser, git, etc. already in base image

set -e

WEBUI_DIR="/workspace/stable-diffusion-webui"

# ---- Install extra system dependencies ----
# Most deps are already in the base image (git, wget, curl, libgl1, zstd, etc.)
# python3.13-venv is needed to create venvs with Python 3.13
echo "Installing extra system dependencies..."
apt-get update && apt-get install -y --no-install-recommends \
    google-perftools bc libglib2.0-0 python3.13-venv \
    && rm -rf /var/lib/apt/lists/*

# ---- Install PyTorch 2.9.1+cu130 for Python 3.13 ----
# The base image ships torch for the default Python 3.12; we need it for 3.13
# so that --system-site-packages venvs inherit the correct torch build.
echo "Installing PyTorch 2.9.1+cu130 for Python 3.13..."
python3.13 -m pip install --no-cache-dir \
    torch==2.9.1 torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu130

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
python_cmd="python3.13"
venv_dir="venv"
# Stability-AI repos were made private (Dec 2025) — use community mirrors
export STABLE_DIFFUSION_REPO="https://github.com/w-e-w/stablediffusion.git"
# Skip torch install — already provided by the base image (torch 2.9.1 + CUDA 13.0)
# A1111 runs this as: python -m {TORCH_COMMAND}, so it must be a valid module command
export TORCH_COMMAND="pip --version"
# SDP attention uses Flash Attention 2 under the hood in PyTorch 2.0+
# No xformers needed — avoids version mismatch with base image's torch build
export COMMANDLINE_ARGS="--listen --port 3000 --opt-sdp-attention --enable-insecure-extension-access --no-half-vae --no-download-sd-model --api --skip-python-version-check"
EOF

# ---- Pre-create venv inheriting system packages (torch 2.9.1+cu130 for Python 3.13) ----
echo "Setting up Python venv..."
if [ ! -d "$WEBUI_DIR/venv" ]; then
    python3.13 -m venv --system-site-packages "$WEBUI_DIR/venv"
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
[ ! -d "$WEBUI_DIR/extensions/lobe-theme" ] && \
    git clone https://github.com/lobehub/sd-webui-lobe-theme.git "$WEBUI_DIR/extensions/lobe-theme" || true
[ ! -d "$WEBUI_DIR/extensions/aspect-ratio-helper" ] && \
    git clone https://github.com/thomasasfk/sd-webui-aspect-ratio-helper.git "$WEBUI_DIR/extensions/aspect-ratio-helper" || true
[ ! -d "$WEBUI_DIR/extensions/ultimate-upscale" ] && \
    git clone https://github.com/Coyote-A/ultimate-upscale-for-automatic1111.git "$WEBUI_DIR/extensions/ultimate-upscale" || true

# ---- File Browser (already in base image — just configure) ----
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
