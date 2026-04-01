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
FORCE_FULL_INSTALL="${FORCE_FULL_INSTALL:-0}"
REBUILD_VENV_ON_BOOT="${REBUILD_VENV_ON_BOOT:-0}"
UPDATE_CUSTOM_NODES_ON_BOOT="${UPDATE_CUSTOM_NODES_ON_BOOT:-0}"
REINSTALL_NODE_DEPS_ON_BOOT="${REINSTALL_NODE_DEPS_ON_BOOT:-0}"
CUDA_WHL_INDEX_URL="${CUDA_WHL_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
LENOVO_ULTRAREAL_WAN_URL="${LENOVO_ULTRAREAL_WAN_URL:-}"
MANUAL_ACTIONS=()

existing_install_ready() {
    [ -d "$COMFYUI_DIR" ] && [ -f /workspace/run_gpu.sh ] && [ -x "$VENV_BIN/python" ]
}

note_manual_action() {
    local message="$1"
    MANUAL_ACTIONS+=("$message")
}

install_requirements_preserving_cuda_stack() {
    local requirements_file="$1"
    local filtered_file
    filtered_file="$(mktemp)"

    # Keep the pod's CUDA 12.8-compatible acceleration stack. Some custom nodes
    # ask pip for newer torch/xformers/triton wheels, which breaks on drivers
    # that only expose CUDA 12.8 (reported by torch as version 12080).
    grep -v -E '^\s*(torch|torchvision|torchaudio|xformers|triton)\s*($|[><=!~;#])' "$requirements_file" > "$filtered_file"

    if [ -s "$filtered_file" ]; then
        "$VENV_BIN/pip" install -r "$filtered_file"
    else
        echo "No non-CUDA Python requirements left in $(basename "$requirements_file"), skipping pip install."
    fi

    rm -f "$filtered_file"
}

venv_cuda_stack_is_compatible() {
    "$VENV_BIN/python" - <<'PY'
import inspect
import pathlib
import sys

try:
    import torch
except Exception as exc:
    print(f"Failed to import torch from the ComfyUI venv: {exc}")
    raise SystemExit(1)

torch_path = pathlib.Path(inspect.getfile(torch)).resolve()
cuda_version = getattr(torch.version, "cuda", "") or ""

print(f"Detected torch: {torch.__version__}")
print(f"Detected torch CUDA runtime: {cuda_version or 'none'}")
print(f"Detected torch path: {torch_path}")

if not cuda_version.startswith("12.8"):
    raise SystemExit(1)
PY
}

repair_cuda_stack() {
    local base_packages=()

    echo "Repairing the ComfyUI CUDA stack to stay on CUDA 12.8-compatible wheels..."

    mapfile -t base_packages < <(python3 - <<'PY'
import importlib.metadata as md

for name in ("torch", "torchvision", "torchaudio"):
    try:
        print(f"{name}=={md.version(name)}")
    except md.PackageNotFoundError:
        pass
PY
)

    if [ ${#base_packages[@]} -eq 0 ]; then
        echo "Could not determine the base image PyTorch versions."
        return 1
    fi

    # Remove optional accelerator wheels that commonly pull in a newer CUDA toolchain.
    "$VENV_BIN/pip" uninstall -y xformers triton >/dev/null 2>&1 || true

    "$VENV_BIN/pip" install --upgrade --index-url "$CUDA_WHL_INDEX_URL" "${base_packages[@]}"
}

ensure_compatible_cuda_stack() {
    if venv_cuda_stack_is_compatible; then
        echo "ComfyUI torch stack is already CUDA 12.8-compatible."
        return 0
    fi

    echo "Detected an incompatible ComfyUI torch stack; repairing it now..."
    repair_cuda_stack
    venv_cuda_stack_is_compatible
}

install_os_packages() {
    if command -v ffmpeg >/dev/null 2>&1 \
        && command -v git >/dev/null 2>&1 \
        && command -v wget >/dev/null 2>&1 \
        && command -v curl >/dev/null 2>&1 \
        && command -v python3 >/dev/null 2>&1; then
        echo "Required OS packages already available, skipping apt install."
        return
    fi

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
    if [ "$REBUILD_VENV_ON_BOOT" != "1" ] && [ -x "$VENV_BIN/python" ]; then
        echo "ComfyUI venv already present, skipping rebuild."
        return
    fi

    echo "Recreating ComfyUI venv with system-site-packages..."
    rm -rf "$COMFYUI_DIR/venv"
    python3 -m venv --system-site-packages "$COMFYUI_DIR/venv"

    "$VENV_BIN/pip" install --upgrade pip wheel

    echo "Installing ComfyUI requirements while keeping base-image torch..."
    install_requirements_preserving_cuda_stack "$COMFYUI_DIR/requirements.txt"

    if [ -f "$CUSTOM_NODES_DIR/comfyui-manager/requirements.txt" ]; then
        "$VENV_BIN/pip" install -r "$CUSTOM_NODES_DIR/comfyui-manager/requirements.txt"
    fi
}

install_node_repo() {
    local repo_url="$1"
    local dir_name="$2"
    local repo_dir="$CUSTOM_NODES_DIR/$dir_name"
    local should_install_deps="0"

    if [ -d "$repo_dir/.git" ]; then
        if [ "$UPDATE_CUSTOM_NODES_ON_BOOT" = "1" ]; then
            echo "Updating $dir_name..."
            git -C "$repo_dir" pull --ff-only || true
            should_install_deps="1"
        else
            echo "$dir_name already present, skipping git update."
        fi
    elif [ -d "$repo_dir" ]; then
        echo "Directory $dir_name already exists and is not a git repo, leaving as-is."
    else
        echo "Cloning $dir_name..."
        git -C "$CUSTOM_NODES_DIR" clone "$repo_url" "$dir_name"
        should_install_deps="1"
    fi

    if [ -f "$repo_dir/requirements.txt" ]; then
        if [ "$should_install_deps" = "1" ] || [ "$REINSTALL_NODE_DEPS_ON_BOOT" = "1" ]; then
            echo "Installing Python requirements for $dir_name..."
            install_requirements_preserving_cuda_stack "$repo_dir/requirements.txt"
        else
            echo "Python requirements for $dir_name already installed, skipping."
        fi
    fi

    if [ -f "$repo_dir/install.py" ]; then
        if [ "$should_install_deps" = "1" ] || [ "$REINSTALL_NODE_DEPS_ON_BOOT" = "1" ]; then
            echo "Running install.py for $dir_name..."
            "$VENV_BIN/python" "$repo_dir/install.py" || true
        else
            echo "install.py for $dir_name already handled, skipping."
        fi
    fi
}

download_if_missing() {
    local url="$1"
    local dest="$2"
    local tmp_dest="${dest}.part"

    if [ -f "$dest" ]; then
        echo "Already present: $(basename "$dest")"
        return
    fi

    echo "Downloading $(basename "$dest")..."
    rm -f "$tmp_dest"
    if ! wget -q --show-progress --tries=3 --waitretry=5 --retry-connrefused "$url" -O "$tmp_dest"; then
        rm -f "$tmp_dest"
        return 1
    fi
    mv "$tmp_dest" "$dest"
}

download_civitai_if_missing() {
    local model_version_id="$1"
    local dest="$2"
    local url="${LENOVO_ULTRAREAL_WAN_URL:-https://civitai.com/api/download/models/$model_version_id}"

    if [ -f "$dest" ]; then
        echo "Already present: $(basename "$dest")"
        return
    fi

    if [ -n "$CIVITAI_TOKEN" ]; then
        if [[ "$url" == *\?* ]]; then
            url="${url}&token=${CIVITAI_TOKEN}"
        else
            url="${url}?token=${CIVITAI_TOKEN}"
        fi
    fi

    echo "Downloading $(basename "$dest") from Civitai..."
    if ! download_if_missing "$url" "$dest"; then
        rm -f "$dest" "${dest}.part"
        note_manual_action "Download Lenovo UltraReal Wan LoRA manually to $COMFYUI_DIR/models/loras/Lenovo_UltraReal_v1.0_Wan.safetensors, or rerun with CIVITAI_TOKEN set or LENOVO_ULTRAREAL_WAN_URL pointing at a direct download URL."
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
    install_node_repo "https://github.com/calcuis/gguf.git" "gguf"
    install_node_repo "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git" "ComfyUI-Custom-Scripts"
    install_node_repo "https://github.com/giriss/comfy-image-saver.git" "comfy-image-saver"
    install_node_repo "https://github.com/rgthree/rgthree-comfy.git" "rgthree-comfy"
    install_node_repo "https://github.com/mickmumpitz/ComfyUI-Mickmumpitz-Nodes.git" "ComfyUI-Mickmumpitz-Nodes"
    install_node_repo "https://github.com/PozzettiAndrea/ComfyUI-DepthAnythingV3.git" "ComfyUI-DepthAnythingV3"
    install_node_repo "https://github.com/Fannovel16/comfyui_controlnet_aux.git" "comfyui_controlnet_aux"
    install_node_repo "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git" "ComfyUI-Impact-Pack"
    install_node_repo "https://github.com/ClownsharkBatwing/RES4LYF.git" "RES4LYF"
    install_node_repo "https://github.com/drozbay/ComfyUI-WanVaceAdvanced.git" "ComfyUI-WanVaceAdvanced"

    # Optional extra support for future animator workflows.
    if [ "$INSTALL_LTX_VIDEO" = "1" ]; then
        install_node_repo "https://github.com/Lightricks/ComfyUI-LTXVideo.git" "ComfyUI-LTXVideo"
    fi

    ensure_compatible_cuda_stack

    echo "NOTE: If the workflow still reports a missing 'Use Everywhere' node pack,"
    echo "install it manually through ComfyUI Manager after first boot."
}

prepare_model_layout() {
    echo "Preparing model folders..."
    mkdir -p \
        "$COMFYUI_DIR/input" \
        "$COMFYUI_DIR/output" \
        "$COMFYUI_DIR/models/diffusion_models/Wan2.2" \
        "$COMFYUI_DIR/models/diffusion_models" \
        "$COMFYUI_DIR/models/model_patches" \
        "$COMFYUI_DIR/models/text_encoders" \
        "$COMFYUI_DIR/models/vae" \
        "$COMFYUI_DIR/models/loras"
}

download_known_models() {
    if [ "$AUTO_DOWNLOAD_KNOWN_MODELS" != "1" ]; then
        echo "Skipping known model downloads because AUTO_DOWNLOAD_KNOWN_MODELS=$AUTO_DOWNLOAD_KNOWN_MODELS"
        return
    fi

    download_if_missing \
        "https://huggingface.co/lym00/Wan2.2_T2V_A14B_VACE-test/resolve/main/Wan2.2_T2V_High_Noise_14B_VACE-Q8_0.gguf" \
        "$COMFYUI_DIR/models/diffusion_models/Wan2.2/Wan2.2_T2V_High_Noise_14B_VACE-Q8_0.gguf"

    download_if_missing \
        "https://huggingface.co/lym00/Wan2.2_T2V_A14B_VACE-test/resolve/main/Wan2.2_T2V_Low_Noise_14B_VACE-Q8_0.gguf" \
        "$COMFYUI_DIR/models/diffusion_models/Wan2.2/Wan2.2_T2V_Low_Noise_14B_VACE-Q8_0.gguf"

    download_if_missing \
        "https://huggingface.co/city96/umt5-xxl-encoder-gguf/resolve/main/umt5-xxl-encoder-Q8_0.gguf" \
        "$COMFYUI_DIR/models/text_encoders/umt5-xxl-encoder-Q8_0.gguf"

    download_if_missing \
        "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" \
        "$COMFYUI_DIR/models/vae/wan_2.1_vae.safetensors"

    download_if_missing \
        "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors" \
        "$COMFYUI_DIR/models/text_encoders/qwen_3_4b.safetensors"

    download_if_missing \
        "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors" \
        "$COMFYUI_DIR/models/diffusion_models/z_image_turbo_bf16.safetensors"

    download_if_missing \
        "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" \
        "$COMFYUI_DIR/models/vae/ae.safetensors"

    download_if_missing \
        "https://huggingface.co/alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union-2.1/resolve/main/Z-Image-Turbo-Fun-Controlnet-Union-2.1-2601-8steps.safetensors" \
        "$COMFYUI_DIR/models/model_patches/Z-Image-Fun-Controlnet-Union-2.1.safetensors"

    download_if_missing \
        "https://huggingface.co/Inner-Reflections/VACE_Skyreels_V3_R2V_Merge/resolve/main/wan-14B_vace_skyreels_v3_R2V_e4m3fn_v1.safetensors" \
        "$COMFYUI_DIR/models/diffusion_models/wan-14B_vace_skyreels_v3_R2V_e4m3fn_v1.safetensors"

    download_if_missing \
        "https://huggingface.co/vrgamedevgirl84/Wan14BT2VFusioniX/resolve/main/FusionX_LoRa/Wan2.1_T2V_14B_FusionX_LoRA.safetensors" \
        "$COMFYUI_DIR/models/loras/Wan2.1_T2V_14B_FusionX_LoRA.safetensors"

    download_if_missing \
        "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank64_bf16.safetensors" \
        "$COMFYUI_DIR/models/loras/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank64_bf16.safetensors"

    download_civitai_if_missing \
        "2066914" \
        "$COMFYUI_DIR/models/loras/Lenovo_UltraReal_v1.0_Wan.safetensors"

    download_if_missing \
        "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
        "$COMFYUI_DIR/models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

    download_if_missing \
        "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" \
        "$COMFYUI_DIR/models/vae/wan_2.1_vae.safetensors"
}

print_manual_requirements() {
    echo "========================================"
    echo "Manual model files still required"
    echo "========================================"
    echo "loras/art1fact_pod_wan.safetensors"
    echo "loras/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank128_bf16.safetensors"
    echo "loras/gl1der_spaceship_wan_000002700.safetensors"
    echo
    echo "Optional workflow input files for football.json belong in:"
    echo "$COMFYUI_DIR/input"
    if [ ${#MANUAL_ACTIONS[@]} -gt 0 ]; then
        echo
        echo "Additional follow-up actions:"
        for action in "${MANUAL_ACTIONS[@]}"; do
            echo "$action"
        done
    fi
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

if [ "$FORCE_FULL_INSTALL" = "1" ]; then
    echo "FORCE_FULL_INSTALL=1, running full setup."
elif existing_install_ready; then
    echo "Existing ComfyUI install detected, using fast start path."
    if ! ensure_compatible_cuda_stack; then
        echo "Fast start compatibility repair failed; rebuilding the ComfyUI venv."
        REBUILD_VENV_ON_BOOT="1"
        REINSTALL_NODE_DEPS_ON_BOOT="1"
        rebuild_venv
        install_custom_nodes
        ensure_compatible_cuda_stack
    fi
    prepare_model_layout
    download_known_models
    print_manual_requirements
    configure_filebrowser
    cleanup
    start_services
    exit 0
fi

install_comfyui
rebuild_venv
install_custom_nodes
prepare_model_layout
download_known_models
print_manual_requirements
configure_filebrowser
cleanup
start_services
