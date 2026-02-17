#!/bin/bash

# -- Installation Script for ComfyUI on RTX 5090 ---
# Base image: runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
#
# This script handles the full installation of ComfyUI,
# comfyui-model-downloader, comfyui-ollama, Ollama LLM server, and File Browser.
#
# Setup:
#   - CUDA 12.8.1 with cuDNN — RTX 5090 supported via forward-compatible PTX
#   - PyTorch 2.8.0+cu128 from base image (pre-installed for Python 3.11)
#   - Python 3.11 venv with --system-site-packages (inherits GPU-enabled torch)
#
# The critical step for GPU detection is recreating the ComfyUI venv with
# --system-site-packages so it inherits the base image's CUDA-enabled PyTorch.
# Without this, pip may install a CPU-only torch and ComfyUI only sees CPU.

cd /workspace

# ---- Install filebrowser if not present ----
if ! command -v filebrowser &> /dev/null; then
    echo "Installing filebrowser..."
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
fi

# Download and install ComfyUI using the ComfyUI-Manager script.
echo "Installing ComfyUI and ComfyUI Manager..."
wget https://github.com/ltdrdata/ComfyUI-Manager/raw/main/scripts/install-comfyui-venv-linux.sh -O install-comfyui-venv-linux.sh
chmod +x install-comfyui-venv-linux.sh
./install-comfyui-venv-linux.sh

# Add the --listen flag to the run_gpu.sh script for network access.
echo "Configuring ComfyUI for network access..."
sed -i "$ s/$/ --listen /" /workspace/run_gpu.sh
chmod +x /workspace/run_gpu.sh

# ---- Recreate ComfyUI venv with system-site-packages ----
# Inherit torch 2.8.0+cu128 from the base image (Python 3.11).
# This is the key step that makes ComfyUI see the GPU instead of CPU-only.
echo "Recreating ComfyUI venv with system-site-packages (GPU-enabled torch)..."
rm -rf /workspace/ComfyUI/venv
python3 -m venv --system-site-packages /workspace/ComfyUI/venv

/workspace/ComfyUI/venv/bin/pip install --upgrade pip wheel

# Install ComfyUI requirements — but keep the system torch stack
# (torch 2.8.0+cu128 with CUDA 12.8.1 / GPU support).
# pip's dependency resolver would otherwise pull a different torch build
# that may lack GPU support or be incompatible with the CUDA driver.
echo "Installing ComfyUI requirements (keeping system torch)..."
grep -v -E '^\s*(torch|torchvision|torchaudio)\s*($|[><=!~;#])' /workspace/ComfyUI/requirements.txt \
    > /tmp/comfyui_reqs_filtered.txt
/workspace/ComfyUI/venv/bin/pip install -r /tmp/comfyui_reqs_filtered.txt

# Installing custom nodes
echo "Installing ComfyUI custom nodes..."
git -C /workspace/ComfyUI/custom_nodes clone https://github.com/dsigmabcn/comfyui-model-downloader.git
git -C /workspace/ComfyUI/custom_nodes clone https://github.com/MadiatorLabs/ComfyUI-RunpodDirect.git
git -C /workspace/ComfyUI/custom_nodes clone https://github.com/stavsap/comfyui-ollama.git
/workspace/ComfyUI/venv/bin/pip install -r /workspace/ComfyUI/custom_nodes/comfyui-ollama/requirements.txt

# ---- File Browser (configure database) ----
FB_DB="/workspace/.filebrowser.db"
if [ ! -f "$FB_DB" ]; then
    echo "Configuring File Browser..."
    filebrowser config init --database "$FB_DB"
    filebrowser config set --address 0.0.0.0 --port 8080 --root /workspace --database "$FB_DB"
    filebrowser users add admin adminadmin11 --perm.admin --database "$FB_DB"
fi

# ---- Install Ollama LLM server (used by comfyui-ollama extension) ----
echo "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# Clean up
echo "Cleaning up..."
rm -f install_script.sh run_cpu.sh install-comfyui-venv-linux.sh

# Start the main Runpod service, ComfyUI, Ollama, and File Browser in the background.
echo "Starting ComfyUI, Ollama, File Browser, and Runpod services..."
# Force Ollama to CPU-only (OLLAMA_NUM_GPU=0) to avoid VRAM conflicts with ComfyUI models
(/start.sh & OLLAMA_NUM_GPU=0 ollama serve & filebrowser --database "$FB_DB" & /workspace/run_gpu.sh)
