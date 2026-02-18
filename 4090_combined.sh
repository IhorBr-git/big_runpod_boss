#!/bin/bash

# -- Combined Installation & Start Script for RTX 4090 ---
# Base image: runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04
#
# This script installs and launches BOTH:
#   - AUTOMATIC1111 Stable Diffusion WebUI  (port 3000)
#   - ComfyUI                               (port 8188)
#   - File Browser                           (port 8080)
#   - Ollama                                 (port 11434)
# on a single RunPod pod optimized for RTX 4090 (Ada Lovelace architecture).
#
# On pod restart (both dirs already exist) the script skips installation
# entirely and goes straight to starting services — same logic as the
# individual container start commands.
#
# Container Start Command (use the script for both fresh install and restart):
#   cd /workspace && wget -q https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/main/4090_combined.sh -O install_script.sh && chmod +x install_script.sh && ./install_script.sh

set -e

WEBUI_DIR="/workspace/stable-diffusion-webui"
COMFYUI_DIR="/workspace/ComfyUI"
MODELS_DIR="/workspace/models"
FB_DB="/workspace/.filebrowser.db"
# Persist Ollama models on the workspace volume (survives pod restarts)
export OLLAMA_MODELS="/workspace/.ollama/models"

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
echo "  - File Browser    (port 8080)"
echo "  - Ollama          (port 11434)"
echo "========================================"

# Forward SIGTERM/SIGINT to all child processes for clean container shutdown
trap 'echo "Shutting down..."; kill $(jobs -p) 2>/dev/null; wait' SIGTERM SIGINT

# Ensure File Browser binary is available (not persisted across pod restarts)
if ! command -v filebrowser &> /dev/null; then
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
fi

# Ensure zstd is available (required by Ollama installer, not persisted across restarts)
if ! command -v zstd &> /dev/null; then
apt-get update && apt-get install -y --no-install-recommends zstd && rm -rf /var/lib/apt/lists/*
fi

# Ensure Ollama is installed (binary is not persisted across pod restarts)
if ! command -v ollama &> /dev/null; then
echo "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh
# The install script auto-starts a systemd service with GPU enabled — kill it.
systemctl disable ollama 2>/dev/null || true
systemctl stop ollama 2>/dev/null || true
fi

# Disable A1111 auto-loading checkpoint at startup (saves ~8 GB VRAM for ComfyUI).
# User can still select a model manually from the A1111 dropdown.
A1111_CONFIG="$WEBUI_DIR/config.json"
if [ ! -f "$A1111_CONFIG" ]; then
echo '{"sd_checkpoint_autoload": false}' > "$A1111_CONFIG"
else
python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg['sd_checkpoint_autoload'] = False
json.dump(cfg, open(sys.argv[1], 'w'), indent=4)
" "$A1111_CONFIG"
fi

# Start RunPod handler (only once for both services)
/start.sh &

# Start A1111 WebUI
(cd "$WEBUI_DIR" && bash webui.sh -f) &

# Start ComfyUI
/workspace/run_gpu.sh &

# Start File Browser
filebrowser --database "$FB_DB" &

# Start Ollama server (used by comfyui-ollama node)
# Force CPU-only mode: ComfyUI's diffusion models (Flux, CLIP, VAE, ControlNet)
# consume most of the 24 GB VRAM, leaving too little for Ollama's LLM on GPU.
# CPU inference is fast enough for text-prompt generation and avoids OOM crashes.
OLLAMA_HOST=0.0.0.0:11434 OLLAMA_NUM_GPU=0 ollama serve &

    # Pull the vision-language model if not already present (e.g. after fresh Ollama reinstall)
    echo "Ensuring Ollama model qwen3-vl:4b is available..."
    sleep 3  # wait for Ollama server to be ready
    OLLAMA_HOST=0.0.0.0:11434 ollama pull qwen3-vl:4b &

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
echo "[1/8] Installing system dependencies..."
echo "========================================"
apt-get update && apt-get install -y --no-install-recommends \
wget curl git python3 python3-venv libgl1 libglib2.0-0 google-perftools bc zstd \
&& rm -rf /var/lib/apt/lists/*

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
# Skip torch install — already provided by the base image (torch 2.4.0 + CUDA 12.4).
export TORCH_COMMAND="echo 'Torch pre-installed in base image, skipping'"
# SDP attention uses Flash Attention 2 under the hood in PyTorch 2.0+
# xformers is also a good option on RTX 4090 but SDP keeps things simpler
export COMMANDLINE_ARGS="--listen --port 3000 --opt-sdp-attention --enable-insecure-extension-access --no-half-vae --no-download-sd-model --api"
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
echo "[3/8] Setting up ComfyUI..."
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

# Ensure ComfyUI's PyTorch uses cu124 wheels matching the pod's CUDA 12.4 driver.
# The ComfyUI-Manager installer may default to cu121 — cu124 wheels ensure
# full compatibility with the host CUDA 12.4 driver and RTX 4090 Ada Lovelace arch.
echo "Upgrading ComfyUI's PyTorch to cu124 for CUDA 12.4 driver compatibility..."
"$COMFYUI_DIR/venv/bin/pip" install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

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
# 6. Ollama (LLM inference server for comfyui-ollama)
# ==============================================================================
echo "========================================"
echo "[6/8] Installing Ollama & pulling qwen3-vl:4b model..."
echo "========================================"
curl -fsSL https://ollama.com/install.sh | sh
# The install script auto-starts a systemd service with GPU enabled — kill it.
systemctl disable ollama 2>/dev/null || true
systemctl stop ollama 2>/dev/null || true

# Pull the vision-language model used by the OllamaGenerateV2 node in ComfyUI.
# Start serve temporarily, pull the model, then stop.
OLLAMA_HOST=0.0.0.0:11434 OLLAMA_NUM_GPU=0 ollama serve &
OLLAMA_TMP_PID=$!
sleep 3
echo "Pulling qwen3-vl:4b model..."
OLLAMA_HOST=0.0.0.0:11434 ollama pull qwen3-vl:4b
kill $OLLAMA_TMP_PID 2>/dev/null
wait $OLLAMA_TMP_PID 2>/dev/null || true

# ==============================================================================
# 7. Cleanup
# ==============================================================================
echo "========================================"
echo "[7/8] Cleaning up..."
echo "========================================"
rm -f /workspace/install_script.sh

# ==============================================================================
# 8. Start all services
# ==============================================================================
