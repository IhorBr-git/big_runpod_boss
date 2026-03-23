#!/bin/bash

# -- Animator Installation Script for ComfyUI on RTX 5090 ---
# Base image: runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
#
# This script is based on RTX5090_ComfyUI.sh and is tailored for the
# animator team's WAN workflow(s), including the provided football.json.
#
# It installs:
#   - ComfyUI + ComfyUI Manager
#   - File Browser
#   - Workflow-specific custom nodes for WAN video pipelines
#   - Known model folders expected by the workflow
#
# It only auto-downloads models that are clearly identified.
# Models with unclear or team-local provenance are intentionally left manual.
#
# Container Start Command:
#   cd /workspace && wget -q https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/main/RTX5090_ComfyUI_animators.sh -O install_script.sh && chmod +x install_script.sh && ./install_script.sh
#
# Manual model drops still required for football.json:
#   /workspace/ComfyUI/models/diffusion_models/Wan2.2/Wan2.2_T2V_High_Noise_14B_VACE-Q8_0.gguf
#   /workspace/ComfyUI/models/diffusion_models/Wan2.2/Wan2.2_T2V_Low_Noise_14B_VACE-Q8_0.gguf
#   /workspace/ComfyUI/models/text_encoders/umt5-xxl-encoder-Q8_0.gguf
#   /workspace/ComfyUI/models/loras/art1fact_pod_wan.safetensors
#   /workspace/ComfyUI/models/loras/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank128_bf16.safetensors
#   /workspace/ComfyUI/models/loras/gl1der_spaceship_wan_000002700.safetensors
#
# Optional workflow inputs expected by football.json:
#   /workspace/ComfyUI/input/20_mask (2).mp4
#   /workspace/ComfyUI/input/20001-0250.mp4
#   /workspace/ComfyUI/input/20001-0250 (1) (1).mp4

set -euo pipefail

cd /workspace

COMFYUI_DIR="/workspace/ComfyUI"
CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
VENV_BIN="$COMFYUI_DIR/venv/bin"
FB_DB="/workspace/.filebrowser.db"
AUTO_DOWNLOAD_KNOWN_MODELS="${AUTO_DOWNLOAD_KNOWN_MODELS:-1}"
INSTALL_LTX_VIDEO="${INSTALL_LTX_VIDEO:-0}"

install_os_packages() {
    echo "Installing OS packages..."
    apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg git wget curl python3 python3-venv libgl1 libglib2.0-0 \
        && rm -rf /var/lib/apt/lists/*
}

ensure_filebrowser() {
    if ! command -v filebrowser &> /dev/null; then
        echo "Installing filebrowser..."
        curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
    fi
}

install_comfyui() {
    if [ -d "$COMFYUI_DIR" ] && [ -f /workspace/run_gpu.sh ]; then
        echo "ComfyUI already installed, skipping base install."
        return
    fi

    echo "Installing ComfyUI and ComfyUI Manager..."
    wget https://github.com/ltdrdata/ComfyUI-Manager/raw/main/scripts/install-comfyui-venv-linux.sh -O install-comfyui-venv-linux.sh
    chmod +x install-comfyui-venv-linux.sh
    ./install-comfyui-venv-linux.sh

    echo "Configuring ComfyUI for network access..."
    sed -i '$ s/$/ --listen /' /workspace/run_gpu.sh
    chmod +x /workspace/run_gpu.sh
}

rebuild_venv() {
    echo "Recreating ComfyUI venv with system-site-packages..."
    rm -rf "$COMFYUI_DIR/venv"
    python3 -m venv --system-site-packages "$COMFYUI_DIR/venv"

    "$VENV_BIN/pip" install --upgrade pip wheel

    echo "Installing ComfyUI requirements while keeping base-image torch..."
    grep -v -E '^\s*(torch|torchvision|torchaudio)\s*($|[><=!~;#])' "$COMFYUI_DIR/requirements.txt" \
        > /tmp/comfyui_reqs_filtered.txt
    "$VENV_BIN/pip" install -r /tmp/comfyui_reqs_filtered.txt

    if [ -f "$CUSTOM_NODES_DIR/comfyui-manager/requirements.txt" ]; then
        "$VENV_BIN/pip" install -r "$CUSTOM_NODES_DIR/comfyui-manager/requirements.txt"
    fi
}

install_node_repo() {
    local repo_url="$1"
    local dir_name="$2"
    local repo_dir="$CUSTOM_NODES_DIR/$dir_name"

    if [ -d "$repo_dir/.git" ]; then
        echo "Updating $dir_name..."
        git -C "$repo_dir" pull --ff-only || true
    elif [ -d "$repo_dir" ]; then
        echo "Directory $dir_name already exists and is not a git repo, leaving as-is."
    else
        echo "Cloning $dir_name..."
        git -C "$CUSTOM_NODES_DIR" clone "$repo_url" "$dir_name"
    fi

    if [ -f "$repo_dir/requirements.txt" ]; then
        echo "Installing Python requirements for $dir_name..."
        "$VENV_BIN/pip" install -r "$repo_dir/requirements.txt"
    fi

    if [ -f "$repo_dir/install.py" ]; then
        echo "Running install.py for $dir_name..."
        "$VENV_BIN/python" "$repo_dir/install.py" || true
    fi
}

install_custom_nodes() {
    echo "Installing ComfyUI custom nodes..."

    # Existing baseline utilities
    install_node_repo "https://github.com/dsigmabcn/comfyui-model-downloader.git" "comfyui-model-downloader"
    install_node_repo "https://github.com/MadiatorLabs/ComfyUI-RunpodDirect.git" "ComfyUI-RunpodDirect"
    install_node_repo "https://github.com/crystian/ComfyUI-Crystools.git" "ComfyUI-Crystools"
    install_node_repo "https://github.com/stavsap/comfyui-ollama.git" "comfyui-ollama"

    # Workflow-specific dependencies detected from football.json
    install_node_repo "https://github.com/kijai/ComfyUI-WanVideoWrapper.git" "ComfyUI-WanVideoWrapper"
    install_node_repo "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" "ComfyUI-VideoHelperSuite"
    install_node_repo "https://github.com/kijai/ComfyUI-KJNodes.git" "ComfyUI-KJNodes"
    install_node_repo "https://github.com/yolain/ComfyUI-Easy-Use.git" "ComfyUI-Easy-Use"
    install_node_repo "https://github.com/cubiq/ComfyUI_essentials.git" "ComfyUI_essentials"
    install_node_repo "https://github.com/sipherxyz/comfyui-art-venture.git" "comfyui-art-venture"
    install_node_repo "https://github.com/city96/ComfyUI-GGUF.git" "ComfyUI-GGUF"
    install_node_repo "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git" "ComfyUI-Custom-Scripts"
    install_node_repo "https://github.com/alexopus/ComfyUI-Image-Saver.git" "ComfyUI-Image-Saver"
    install_node_repo "https://github.com/rgthree/rgthree-comfy.git" "rgthree-comfy"

    # Optional extra support for future animator workflows.
    if [ "$INSTALL_LTX_VIDEO" = "1" ]; then
        install_node_repo "https://github.com/Lightricks/ComfyUI-LTXVideo.git" "ComfyUI-LTXVideo"
    fi

    echo "NOTE: If the workflow still reports a missing 'Use Everywhere' node pack,"
    echo "install it manually through ComfyUI Manager after first boot."
}

prepare_model_layout() {
    echo "Preparing model folders..."
    mkdir -p \
        "$COMFYUI_DIR/input" \
        "$COMFYUI_DIR/output" \
        "$COMFYUI_DIR/models/diffusion_models/Wan2.2" \
        "$COMFYUI_DIR/models/text_encoders" \
        "$COMFYUI_DIR/models/vae" \
        "$COMFYUI_DIR/models/loras"
}

download_known_models() {
    if [ "$AUTO_DOWNLOAD_KNOWN_MODELS" != "1" ]; then
        echo "Skipping known model downloads because AUTO_DOWNLOAD_KNOWN_MODELS=$AUTO_DOWNLOAD_KNOWN_MODELS"
        return
    fi

    if [ ! -f "$COMFYUI_DIR/models/vae/wan_2.1_vae.safetensors" ]; then
        echo "Downloading known WAN VAE..."
        wget -q \
            "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" \
            -O "$COMFYUI_DIR/models/vae/wan_2.1_vae.safetensors"
    fi
}

print_manual_requirements() {
    echo "========================================"
    echo "Manual model files still required"
    echo "========================================"
    echo "diffusion_models/Wan2.2/Wan2.2_T2V_High_Noise_14B_VACE-Q8_0.gguf"
    echo "diffusion_models/Wan2.2/Wan2.2_T2V_Low_Noise_14B_VACE-Q8_0.gguf"
    echo "text_encoders/umt5-xxl-encoder-Q8_0.gguf"
    echo "loras/art1fact_pod_wan.safetensors"
    echo "loras/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank128_bf16.safetensors"
    echo "loras/gl1der_spaceship_wan_000002700.safetensors"
    echo
    echo "Optional workflow input files for football.json belong in:"
    echo "$COMFYUI_DIR/input"
    echo "========================================"
}

configure_filebrowser() {
    if [ ! -f "$FB_DB" ]; then
        echo "Configuring File Browser..."
        filebrowser config init --database "$FB_DB"
        filebrowser config set --address 0.0.0.0 --port 8080 --root /workspace --database "$FB_DB"
        filebrowser users add admin adminadmin11 --perm.admin --database "$FB_DB"
    fi
}

cleanup() {
    echo "Cleaning up..."
    rm -f /workspace/install_script.sh /workspace/run_cpu.sh /workspace/install-comfyui-venv-linux.sh
}

start_services() {
    echo "Starting ComfyUI, File Browser, and Runpod services..."
    (/start.sh & filebrowser --database "$FB_DB" & /workspace/run_gpu.sh)
}

install_os_packages
ensure_filebrowser
install_comfyui
rebuild_venv
install_custom_nodes
prepare_model_layout
download_known_models
print_manual_requirements
configure_filebrowser
cleanup
start_services
