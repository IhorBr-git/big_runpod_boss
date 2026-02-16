#!/bin/bash

# -- Installation Script ---
# This script handles the full installation of ComfyUI,
# comfyui-model-downloader, comfyui-ollama, and Ollama LLM server

# Change to the /workspace directory to ensure all files are downloaded correctly.
cd /workspace

# Download and install ComfyUI using the ComfyUI-Manager script.
echo "Installing ComfyUI and ComfyUI Manager..."
wget https://github.com/ltdrdata/ComfyUI-Manager/raw/main/scripts/install-comfyui-venv-linux.sh -O install-comfyui-venv-linux.sh
chmod +x install-comfyui-venv-linux.sh
./install-comfyui-venv-linux.sh

# Add the --listen flag and --fast fp16_accumulation to the run_gpu.sh script.
echo "Configuring ComfyUI for network access and FP16 accumulation..."
sed -i "$ s/$/ --listen --fast fp16_accumulation /" /workspace/run_gpu.sh
chmod +x /workspace/run_gpu.sh

# Installing comfyui-model-downloader nodes.
echo "clone comfyui-model-downloader"
git -C /workspace/ComfyUI/custom_nodes clone https://github.com/dsigmabcn/comfyui-model-downloader.git

# Installing ComfyUI-RunpodDirect.
echo "clone ComfyUI-RunpodDirect"
git -C /workspace/ComfyUI/custom_nodes clone https://github.com/MadiatorLabs/ComfyUI-RunpodDirect.git

# Installing comfyui-ollama (LLM nodes for ComfyUI via Ollama).
echo "clone comfyui-ollama"
git -C /workspace/ComfyUI/custom_nodes clone https://github.com/stavsap/comfyui-ollama.git
/workspace/ComfyUI/venv/bin/pip install -r /workspace/ComfyUI/custom_nodes/comfyui-ollama/requirements.txt

# Install File Browser (web-based file manager on port 8080)
echo "Installing File Browser..."
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

FB_DB="/workspace/.filebrowser.db"
if [ ! -f "$FB_DB" ]; then
    filebrowser config init --database "$FB_DB"
    filebrowser config set --address 0.0.0.0 --port 8080 --root /workspace --noauth --database "$FB_DB"
fi

# Install Ollama LLM server (used by comfyui-ollama extension).
echo "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# Clean up the installation scripts.
echo "Cleaning up..."
rm install_script.sh run_cpu.sh install-comfyui-venv-linux.sh

# Start the main Runpod service, ComfyUI, Ollama, and File Browser in the background.
echo "Starting ComfyUI, Ollama, File Browser, and Runpod services..."
(/start.sh & ollama serve & filebrowser --database "$FB_DB" & /workspace/run_gpu.sh)
