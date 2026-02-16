#!/bin/bash

# -- Combined Installation & Start Script for RTX 5090 ---
# Base image: runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
#
# This script installs and launches:
#   - AUTOMATIC1111 Stable Diffusion WebUI  (port 3000)
#   - ComfyUI                               (port 8188)
#   - Ollama server (for comfyui-ollama)    (port 11434)
#   - File Browser                           (port 8080)
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
FB_DB="/workspace/.filebrowser.db"
OLLAMA_MODELS_DIR="/workspace/.ollama/models"

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
    echo "  - Ollama server   (port 11434)"
    echo "  - File Browser    (port 8080)"
    echo "========================================"

    # Forward SIGTERM/SIGINT to all child processes for clean container shutdown
    trap 'echo "Shutting down..."; kill $(jobs -p) 2>/dev/null; wait' SIGTERM SIGINT

    # Ensure File Browser binary is available (not persisted across pod restarts)
    if ! command -v filebrowser &> /dev/null; then
        curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
    fi

    # Ensure Ollama binary is available (not persisted across pod restarts)
    if ! command -v ollama &> /dev/null; then
        curl -fsSL https://ollama.com/install.sh | sh
    fi

    # Store Ollama models in /workspace so they persist across pod restarts
    export OLLAMA_MODELS="$OLLAMA_MODELS_DIR"

    # Start RunPod handler (only once for both services)
    /start.sh &

    # Start Ollama server
    ollama serve &

    # Pull the default model (no-op if already downloaded); runs in background
    (sleep 5 && ollama pull qwen3-vl:4b) &

    # Start A1111 WebUI
    (cd "$WEBUI_DIR" && bash webui.sh -f) &

    # Start ComfyUI
    /workspace/run_gpu.sh &

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
echo "[1/8] Installing system dependencies & Ollama server..."
echo "========================================"
apt-get update && apt-get install -y --no-install-recommends \
    wget curl git python3 python3-venv libgl1 libglib2.0-0 google-perftools bc zstd \
    python3.13 python3.13-venv python3.13-dev \
    && rm -rf /var/lib/apt/lists/*

# ---- Install Ollama server ----
echo "Installing Ollama server..."
curl -fsSL https://ollama.com/install.sh | sh
mkdir -p "$OLLAMA_MODELS_DIR"

# ==============================================================================
# 2. A1111 Stable Diffusion WebUI
# ==============================================================================
echo "========================================"
echo "[2/8] Setting up A1111 WebUI..."
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
echo "[3/8] Setting up ComfyUI + comfyui-ollama..."
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

    # ---- Recreate ComfyUI venv with Python 3.13 + PyTorch cu130 ----
    # The ComfyUI-Manager installer created a venv with the system Python (3.11).
    # We need Python 3.13 with cu130 for full Blackwell (sm_120) kernel support.
    echo "Recreating ComfyUI venv with Python 3.13..."
    rm -rf "$COMFYUI_DIR/venv"
    python3.13 -m venv "$COMFYUI_DIR/venv"

    echo "Installing PyTorch cu130 for Blackwell (sm_120) support..."
    "$COMFYUI_DIR/venv/bin/pip" install --upgrade pip wheel
    "$COMFYUI_DIR/venv/bin/pip" install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130

    echo "Installing ComfyUI requirements..."
    "$COMFYUI_DIR/venv/bin/pip" install -r "$COMFYUI_DIR/requirements.txt"

    # Update run_gpu.sh to use the new Python 3.13 venv explicitly
    sed -i 's|python |python3.13 |g' /workspace/run_gpu.sh

    # Install custom nodes
    echo "Installing ComfyUI custom nodes..."
    git -C "$COMFYUI_DIR/custom_nodes" clone https://github.com/dsigmabcn/comfyui-model-downloader.git
    git -C "$COMFYUI_DIR/custom_nodes" clone https://github.com/MadiatorLabs/ComfyUI-RunpodDirect.git
    git -C "$COMFYUI_DIR/custom_nodes" clone https://github.com/stavsap/comfyui-ollama.git

    # Clean up ComfyUI installer artifacts
    rm -f /workspace/install-comfyui-venv-linux.sh /workspace/run_cpu.sh
else
    echo "ComfyUI already exists, skipping installation."
fi

# Install comfyui-ollama Python dependencies
echo "Installing comfyui-ollama dependencies..."
"$COMFYUI_DIR/venv/bin/pip" install ollama==0.6.0 python-dotenv

# ==============================================================================
# 4. Shared models directory
# ==============================================================================
echo "========================================"
echo "[4/8] Setting up shared models directory..."
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
echo "[5/8] Setting up File Browser..."
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
echo "[6/8] Cleaning up..."
echo "========================================"
rm -f /workspace/install_script.sh

# ==============================================================================
# 7. Start all services
# ==============================================================================
start_services
