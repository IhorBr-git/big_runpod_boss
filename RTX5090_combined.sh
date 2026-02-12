#!/bin/bash

# -- Combined Installation & Start Script for RTX 5090 ---
# Base image: runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
#
# This script installs and launches BOTH:
#   - AUTOMATIC1111 Stable Diffusion WebUI  (port 3000)
#   - ComfyUI                               (port 8188)
# on a single RunPod pod optimized for RTX 5090 (Blackwell architecture).
#
# On pod restart (both dirs already exist) the script skips installation
# entirely and goes straight to starting services — same logic as the
# individual container start commands.
#
# Container Start Command:
#   bash -c '[ -d "/workspace/stable-diffusion-webui" ] && [ -d "/workspace/ComfyUI" ] && ((cd /workspace && /workspace/run_gpu.sh) & (cd /workspace/stable-diffusion-webui && bash webui.sh -f) & /start.sh) || (cd /workspace && wget https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/main/RTX5090_combined.sh -O install_script.sh && chmod +x install_script.sh && ./install_script.sh)'

set -e

WEBUI_DIR="/workspace/stable-diffusion-webui"
COMFYUI_DIR="/workspace/ComfyUI"
MODELS_DIR="/workspace/models"

# ------------------------------------------------------------------------------
# start_services — launches all three processes and waits
# ------------------------------------------------------------------------------
start_services() {
    echo "========================================"
    echo "Starting services..."
    echo "========================================"
    echo "  - RunPod handler  (/start.sh)"
    echo "  - A1111 WebUI     (port 3000)"
    echo "  - ComfyUI         (port 8188)"
    echo "========================================"

    # Forward SIGTERM/SIGINT to all child processes for clean container shutdown
    trap 'echo "Shutting down..."; kill $(jobs -p) 2>/dev/null; wait' SIGTERM SIGINT

    # Start RunPod handler (only once for both services)
    /start.sh &

    # Start A1111 WebUI
    (cd "$WEBUI_DIR" && bash webui.sh -f) &

    # Start ComfyUI
    /workspace/run_gpu.sh &

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
echo "[1/6] Installing system dependencies..."
echo "========================================"
apt-get update && apt-get install -y --no-install-recommends \
    wget git python3 python3-venv libgl1 libglib2.0-0 google-perftools bc \
    && rm -rf /var/lib/apt/lists/*

# ==============================================================================
# 2. A1111 Stable Diffusion WebUI
# ==============================================================================
echo "========================================"
echo "[2/6] Setting up A1111 WebUI..."
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
# Skip torch install — already provided by the base image (torch 2.8.0 + CUDA 12.8)
export TORCH_COMMAND="echo 'Torch pre-installed in base image, skipping'"
# SDP attention uses Flash Attention 2 under the hood in PyTorch 2.0+
# No xformers needed — avoids version mismatch with base image's dev torch build
export COMMANDLINE_ARGS="--listen --port 3000 --opt-sdp-attention --enable-insecure-extension-access --no-half-vae --no-download-sd-model --api"
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

# ---- Pre-install CLIP without dependencies (torch is already in base image) ----
echo "Pre-installing CLIP..."
"$WEBUI_DIR/venv/bin/pip" install --no-build-isolation --no-deps \
    https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip
# Install only CLIP's lightweight dependencies (not torch)
"$WEBUI_DIR/venv/bin/pip" install ftfy regex tqdm

# ---- Install extensions (only if not already present) ----
echo "Installing A1111 extensions..."
[ ! -d "$WEBUI_DIR/extensions/lobe-theme" ] && \
    git clone https://github.com/lobehub/sd-webui-lobe-theme.git "$WEBUI_DIR/extensions/lobe-theme" || true
[ ! -d "$WEBUI_DIR/extensions/aspect-ratio-helper" ] && \
    git clone https://github.com/thomasasfk/sd-webui-aspect-ratio-helper.git "$WEBUI_DIR/extensions/aspect-ratio-helper" || true
[ ! -d "$WEBUI_DIR/extensions/ultimate-upscale" ] && \
    git clone https://github.com/Coyote-A/ultimate-upscale-for-automatic1111.git "$WEBUI_DIR/extensions/ultimate-upscale" || true

# ==============================================================================
# 3. ComfyUI
# ==============================================================================
echo "========================================"
echo "[3/6] Setting up ComfyUI..."
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

    # Clean up ComfyUI installer artifacts
    rm -f /workspace/install-comfyui-venv-linux.sh /workspace/run_cpu.sh
else
    echo "ComfyUI already exists, skipping installation."
fi

# Upgrade PyTorch to cu130 for RTX 5090 (Blackwell architecture).
# The ComfyUI-Manager installer may use an older cu121 index by default.
# RTX 5090 requires cu130+ for optimized CUDA operations — without it the GPU
# falls back to generic (very slow) code paths despite being detected on cuda:0.
# PyTorch bundles its own CUDA runtime, so cu130 works even on a CUDA 12.8
# base image as long as the host NVIDIA driver is new enough (RunPod RTX 5090
# pods ship with a compatible driver).
# echo "Upgrading ComfyUI's PyTorch to cu130 for RTX 5090 Blackwell support..."
#"$COMFYUI_DIR/venv/bin/pip" install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130

# ==============================================================================
# 4. Shared models directory
# ==============================================================================
echo "========================================"
echo "[4/6] Setting up shared models directory..."
echo "========================================"

# Create shared model directories at /workspace/models/
mkdir -p "$MODELS_DIR"/{checkpoints,vae,loras,embeddings,controlnet,upscale_models,hypernetworks,clip,clip_vision}

# --- ComfyUI: extra_model_paths.yaml ---
echo "Configuring ComfyUI to use shared models..."
cat > "$COMFYUI_DIR/extra_model_paths.yaml" << 'YAML'
shared_models:
    base_path: /workspace/models/
    checkpoints: checkpoints/
    vae: vae/
    loras: loras/
    embeddings: embeddings/
    controlnet: controlnet/
    upscale_models: upscale_models/
    hypernetworks: hypernetworks/
    clip: clip/
    clip_vision: clip_vision/
YAML

# --- A1111: symlink model directories to shared location ---
echo "Symlinking A1111 model directories to shared models..."
declare -A A1111_MAP=(
    ["$WEBUI_DIR/models/Stable-diffusion"]="$MODELS_DIR/checkpoints"
    ["$WEBUI_DIR/models/VAE"]="$MODELS_DIR/vae"
    ["$WEBUI_DIR/models/Lora"]="$MODELS_DIR/loras"
    ["$WEBUI_DIR/models/hypernetworks"]="$MODELS_DIR/hypernetworks"
    ["$WEBUI_DIR/models/ESRGAN"]="$MODELS_DIR/upscale_models"
    ["$WEBUI_DIR/models/ControlNet"]="$MODELS_DIR/controlnet"
)

for src in "${!A1111_MAP[@]}"; do
    dst="${A1111_MAP[$src]}"
    if [ -d "$src" ] && [ ! -L "$src" ]; then
        # Move any pre-existing models to the shared directory
        cp -rn "$src"/* "$dst"/ 2>/dev/null || true
        rm -rf "$src"
    fi
    ln -sfn "$dst" "$src"
done

# A1111 embeddings live at top level, not inside models/
if [ -d "$WEBUI_DIR/embeddings" ] && [ ! -L "$WEBUI_DIR/embeddings" ]; then
    cp -rn "$WEBUI_DIR/embeddings"/* "$MODELS_DIR/embeddings"/ 2>/dev/null || true
    rm -rf "$WEBUI_DIR/embeddings"
fi
ln -sfn "$MODELS_DIR/embeddings" "$WEBUI_DIR/embeddings"

echo "Shared models directory ready at $MODELS_DIR"

# ==============================================================================
# 5. Cleanup
# ==============================================================================
echo "========================================"
echo "[5/6] Cleaning up..."
echo "========================================"
rm -f /workspace/install_script.sh

# ==============================================================================
# 6. Start all services
# ==============================================================================
start_services
