#!/bin/bash

# -- Installation Script for ComfyUI on RTX 5090 ---
# Base image: runpod/pytorch:1.0.3-cu1300-torch291-ubuntu2404
#
# This script handles the full installation of ComfyUI,
# comfyui-model-downloader, comfyui-ollama, Ollama LLM server, and File Browser.
#
# RTX 5090 optimizations:
#   - CUDA 13.0 native — full Blackwell (sm_120) kernel support
#   - PyTorch 2.9.1+cu130 (installed for Python 3.13 at startup)
#   - Python 3.13 venv with --system-site-packages (inherits torch)
#   - filebrowser, zstd, git, etc. already in base image

cd /workspace

# ---- Install Python 3.13 venv support + PyTorch for 3.13 ----
echo "Installing Python 3.13 venv support..."
apt-get update && apt-get install -y --no-install-recommends python3.13-venv \
    && rm -rf /var/lib/apt/lists/*

# The base image ships torch for the default Python 3.12; we need it for 3.13
# so that --system-site-packages venvs inherit the correct torch build.
echo "Installing PyTorch 2.9.1+cu130 for Python 3.13..."
python3.13 -m pip install --no-cache-dir \
    torch==2.9.1 torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu130

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
# Inherit torch 2.9.1+cu130 installed for Python 3.13 (native CUDA 13.0 / Blackwell).
echo "Recreating ComfyUI venv with system-site-packages (torch for Python 3.13)..."
rm -rf /workspace/ComfyUI/venv
python3.13 -m venv --system-site-packages /workspace/ComfyUI/venv

/workspace/ComfyUI/venv/bin/pip install --upgrade pip wheel

# Install ComfyUI requirements — but keep the system torch stack
# (torch 2.9.1+cu130 for Python 3.13 with native CUDA 13.0 / Blackwell support).
# pip's dependency resolver would otherwise pull torch 2.10+cu12 via torchvision,
# which lacks Blackwell support and causes CUDA Error 804 at runtime.
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

# ---- File Browser (already in base image — just configure) ----
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

# Clean up the installation scripts.
echo "Cleaning up..."
rm -f install_script.sh run_cpu.sh install-comfyui-venv-linux.sh

# Start the main Runpod service, ComfyUI, Ollama, and File Browser in the background.
echo "Starting ComfyUI, Ollama, File Browser, and Runpod services..."
(/start.sh & ollama serve & filebrowser --database "$FB_DB" & /workspace/run_gpu.sh)
