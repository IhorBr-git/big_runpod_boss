#!/bin/bash

# -- Installation Script ---
# This script handles the full installation of ComfyUI,
# and comfyui-model-downloader

# Change to the /workspace directory to ensure all files are downloaded correctly.
cd /workspace

# Download and install ComfyUI using the ComfyUI-Manager script.
echo "Installing ComfyUI and ComfyUI Manager..."
wget https://github.com/ltdrdata/ComfyUI-Manager/raw/main/scripts/install-comfyui-venv-linux.sh -O install-comfyui-venv-linux.sh
chmod +x install-comfyui-venv-linux.sh
./install-comfyui-venv-linux.sh

# Add the --listen flag to the run_gpu.sh script for network access.
echo "Configuring ComfyUI for network access..."
sed -i "$ s/$/ --listen /" /workspace/run_gpu.sh
chmod +x /workspace/run_gpu.sh

# Installing comfyui-model-downloader nodes.
echo "clone comfyui-model-downloader"
git -C /workspace/ComfyUI/custom_nodes clone https://github.com/dsigmabcn/comfyui-model-downloader.git

# Installing ComfyUI-RunpodDirect.
echo "clone ComfyUI-RunpodDirect"
git -C /workspace/ComfyUI/custom_nodes clone https://github.com/MadiatorLabs/ComfyUI-RunpodDirect.git

# Clean up the installation scripts.
echo "Cleaning up..."
rm install_script.sh run_cpu.sh install-comfyui-venv-linux.sh

# Start the main Runpod service and the ComfyUI service in the background.
echo "Starting ComfyUI and Runpod services..."
(/start.sh & /workspace/run_gpu.sh)
