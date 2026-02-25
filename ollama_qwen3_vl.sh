#!/bin/bash

# --- Ollama Configuration Script: Qwen3-VL (8B + 30B) ---
# Base image: runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
#
# This script installs and configures Ollama with:
#   - qwen3-vl:8b   (vision-language model)
#   - qwen3-vl:30b  (vision-language model)
#
# Ollama is exposed on port 11434.
#
# Environment variables (set in RunPod template):
#   OLLAMA_GPU_MODE=cpu   — force CPU-only (default: gpu)
#   OLLAMA_PORT=11434     — change listen port (default: 11434)
#
# On pod restart the script skips installation and goes straight to starting
# Ollama — same logic as the other combined scripts.
#
# Container Start Command:
#   cd /workspace && wget -q https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/main/ollama_qwen3_vl.sh -O ollama_qwen3_vl.sh && chmod +x ollama_qwen3_vl.sh && ./ollama_qwen3_vl.sh

set -e

# Persist Ollama models on the workspace volume (survives pod restarts)
export OLLAMA_MODELS="/workspace/.ollama/models"

OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_GPU_MODE="${OLLAMA_GPU_MODE:-gpu}"

MODELS=(
  "qwen3-vl:8b"
  "qwen3-vl:30b"
)

# Build env prefix depending on GPU mode
if [ "$OLLAMA_GPU_MODE" = "cpu" ]; then
  export OLLAMA_NUM_GPU=0
  OLLAMA_ENV="CUDA_VISIBLE_DEVICES=\"\" OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
  echo "Ollama GPU mode: CPU-only (OLLAMA_GPU_MODE=cpu)"
else
  OLLAMA_ENV="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
  echo "Ollama GPU mode: GPU-accelerated"
fi

# ------------------------------------------------------------------------------
# wait_for_ollama — block until the Ollama API is reachable
# ------------------------------------------------------------------------------
wait_for_ollama() {
  local retries=30
  echo "Waiting for Ollama server to become ready..."
  for i in $(seq 1 $retries); do
    if curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" > /dev/null 2>&1; then
      echo "Ollama server is ready."
      return 0
    fi
    sleep 2
  done
  echo "ERROR: Ollama server did not start within 60 seconds."
  exit 1
}

# ------------------------------------------------------------------------------
# pull_models — pull all models that are not already present
# ------------------------------------------------------------------------------
pull_models() {
  for model in "${MODELS[@]}"; do
    echo "Ensuring model ${model} is available..."
    eval $OLLAMA_ENV ollama pull "$model"
    echo "Model ${model} — OK"
  done
}

# ------------------------------------------------------------------------------
# install_ollama — install the Ollama binary if not present
# ------------------------------------------------------------------------------
install_ollama() {
  if command -v ollama &> /dev/null; then
    echo "Ollama is already installed."
    return 0
  fi

  if ! command -v zstd &> /dev/null; then
    apt-get update && apt-get install -y --no-install-recommends zstd && rm -rf /var/lib/apt/lists/*
  fi

  echo "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh

  systemctl disable ollama 2>/dev/null || true
  systemctl stop ollama 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# start_and_serve — start Ollama and keep the container alive
# ------------------------------------------------------------------------------
start_and_serve() {
  echo "========================================"
  echo "Starting Ollama server on port ${OLLAMA_PORT}"
  echo "  Models: ${MODELS[*]}"
  echo "  GPU mode: ${OLLAMA_GPU_MODE}"
  echo "  Model storage: ${OLLAMA_MODELS}"
  echo "========================================"

  trap 'echo "Shutting down Ollama..."; kill $(jobs -p) 2>/dev/null; wait' SIGTERM SIGINT

  eval $OLLAMA_ENV ollama serve &

  wait_for_ollama

  pull_models &

  wait
}

# ==============================================================================
# Main
# ==============================================================================
install_ollama
start_and_serve
