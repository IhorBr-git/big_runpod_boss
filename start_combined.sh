#!/bin/bash

# -- GPU-aware bootstrap for RunPod combined templates ---
#
# Detects the installed RunPod GPU and runs the matching combined install script:
#   blackwell  → RTX5090_combined_2.sh  (CUDA 12.8 / torch 2.8.0+cu128)
#   ada        → 4090_combined.sh       (CUDA 12.4 / torch 2.4.0+cu124)
#   legacy     → 4090_combined.sh       (Hopper/Ampere/Turing — same stack as Ada)
#
# GPU groups (by architecture / PyTorch wheel compatibility):
#   Blackwell (sm_120/sm_100): B300, B200, RTX PRO 6000, RTX PRO 4500,
#     RTX PRO 4000, RTX 5090, 5080, 5070 Ti, 5070, 5060 Ti, 5060, …
#     Requires runpod/pytorch:2.8.0-cuda12.8 base image + cu128 wheels.
#   Ada Lovelace (sm_89): RTX 6000 Ada, RTX 4000 Ada, RTX 2000 Ada,
#     RTX 4090, 4080, 4070, 4060, L40, L40S, L4, …
#     Requires runpod/pytorch:2.4.0-cuda12.4 base image + cu124 wheels.
#   Legacy/Hopper/Ampere/Turing (sm_90/sm_86/sm_80/sm_75/…):
#     H200, H100, A100, A6000, A5000, A4500, A4000, A40, RTX 3090/3080/…,
#     Quadro RTX, …
#     Uses the Ada/cu124 stack; ensure the pod template is the 2.4.0-cuda12.4 image.
#   AMD MI300X is listed on RunPod, but these templates are CUDA/NVIDIA-only.
#
# Overrides:
#   GPU_PROFILE=blackwell|ada|legacy   skip auto-detection
#   REPO_BASE=...                      script download base URL (default: test branch)
#
# RunPod Container start command (must use bash -c — bare "cd && ..." fails with exec: cd: not found):
#   bash -c 'cd /workspace && wget -q https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/test/start_combined.sh -O start_combined.sh && chmod +x start_combined.sh && ./start_combined.sh'

set -euo pipefail

cd /workspace

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/test}"
GPU_PROFILE="${GPU_PROFILE:-}"

detect_gpu_profile() {
# Lowercase via tr (portable to bash 3.x; ${name,,} needs bash 4+).
local name
name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

# Blackwell — sm_120/sm_100, needs CUDA 12.8 / cu128 (RTX 50-series, RTX PRO, B-series)
if [[ "$name" =~ (blackwell|gb20|gb200|b200|b300|rtx[[:space:]]*pro[[:space:]]*(4000|4500|6000)|rtx[[:space:]]*50[0-9]{2}|rtx[[:space:]]*5090|rtx[[:space:]]*5080|rtx[[:space:]]*5070|rtx[[:space:]]*5060|rtx[[:space:]]*5050) ]]; then
echo "blackwell"
return 0
fi

# Ada Lovelace — sm_89, CUDA 12.4 / cu124 (RTX 40-series, L40/L4)
if [[ "$name" =~ (ada|l4($|[^0-9a-z])|l40s|l40($|[^0-9a-z])|rtx[[:space:]]*40[0-9]{2}|rtx[[:space:]]*4090|rtx[[:space:]]*4080|rtx[[:space:]]*4070|rtx[[:space:]]*4060|rtx[[:space:]]*4050) ]]; then
echo "ada"
return 0
fi

# Hopper/Ampere/Turing/Volta and other datacenter GPUs — cu124 stack (same as Ada)
if [[ "$name" =~ (hopper|h100|h200|a100|a6000|a5000|a4500|a4000|a30($|[^0-9a-z])|a10($|[^0-9a-z])|a40($|[^0-9a-z])|tesla|quadro|titan|v100|p100|p40|m40|gtx[[:space:]]|rtx[[:space:]]*30[0-9]{2}|rtx[[:space:]]*20[0-9]{2}|gtx[[:space:]]*16|gtx[[:space:]]*10) ]]; then
echo "legacy"
return 0
fi

if [[ "$name" =~ (amd|mi300x|gfx942|instinct) ]]; then
echo "amd"
return 0
fi

echo "unknown"
}

wait_for_gpu() {
local i
for i in $(seq 1 30); do
if nvidia-smi &>/dev/null; then
return 0
fi
echo "Waiting for NVIDIA driver/GPU... ($i/30)"
sleep 2
done
return 1
}

download_with_retry() {
local url="$1"
local dest="$2"
local i

rm -f "$dest"
for i in $(seq 1 30); do
if wget -q "$url" -O "$dest"; then
chmod +x "$dest"
return 0
fi
echo "Download attempt $i/30 failed, retrying in 10s..."
sleep 10
done
return 1
}

if ! wait_for_gpu; then
if command -v rocm-smi &>/dev/null; then
echo "ERROR: AMD/ROCm GPU detected, but these combined templates are CUDA/NVIDIA-only."
echo "RunPod MI300X requires a separate ROCm-compatible template/script."
else
echo "ERROR: nvidia-smi not available after 60s. Is this a GPU pod?"
fi
exit 1
fi

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | sed 's/^[[:space:]]*//')"
DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | sed 's/^[[:space:]]*//')"
echo "Detected GPU: $GPU_NAME (driver $DRIVER_VERSION)"

if [ -n "$GPU_PROFILE" ]; then
profile="$GPU_PROFILE"
echo "Using GPU_PROFILE override: $profile"
else
profile="$(detect_gpu_profile "$GPU_NAME")"
fi

case "$profile" in
blackwell)
SCRIPT="RTX5090_combined_2.sh"
echo "Selected profile: Blackwell → $SCRIPT"
echo "  Base image: runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04"
echo "  PyTorch pin: 2.8.0+cu128"
;;
ada)
SCRIPT="4090_combined.sh"
echo "Selected profile: Ada Lovelace → $SCRIPT"
echo "  Base image: runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04"
echo "  PyTorch pin: 2.4.0+cu124"
;;
legacy)
SCRIPT="4090_combined.sh"
echo "Selected profile: Legacy/Hopper/Ampere/Turing/datacenter → $SCRIPT"
echo "  Base image: runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04"
echo "  WARNING: Blackwell GPUs must use the 5090 template, not this stack."
;;
amd)
echo "ERROR: AMD/ROCm GPU detected: $GPU_NAME"
echo "RunPod MI300X is not supported by these CUDA/NVIDIA combined templates."
exit 1
;;
*)
echo "ERROR: Unknown GPU profile '$profile' for: $GPU_NAME"
echo "Set GPU_PROFILE to one of: blackwell, ada, legacy"
exit 1
;;
esac

SCRIPT_URL="$REPO_BASE/$SCRIPT"
SCRIPT_PATH="/workspace/$SCRIPT"

echo "Downloading $SCRIPT_URL ..."
if ! download_with_retry "$SCRIPT_URL" "$SCRIPT_PATH"; then
echo "ERROR: Failed to download $SCRIPT after 30 attempts."
exit 1
fi

exec "$SCRIPT_PATH"
