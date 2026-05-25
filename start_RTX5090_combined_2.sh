#!/bin/bash

set -euo pipefail

cd /workspace

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/test}"
SCRIPT_URL="$REPO_BASE/RTX5090_combined_2.sh"
SCRIPT_PATH="/workspace/RTX5090_combined_2.sh"

echo "RTX 5090 bootstrap starting..."
echo "Expected image: runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04"
echo "Waiting 20s before bootstrap so RunPod networking sidecar can attach..."
sleep 20

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true
else
    echo "WARNING: nvidia-smi not found yet."
fi

rm -f "$SCRIPT_PATH"

for i in $(seq 1 30); do
    echo "Downloading $SCRIPT_URL (attempt $i/30)..."
    if wget "$SCRIPT_URL" -O "$SCRIPT_PATH"; then
        chmod +x "$SCRIPT_PATH"
        echo "Launching RTX5090_combined_2.sh..."
        "$SCRIPT_PATH" || {
            rc=$?
            echo "RTX5090_combined_2.sh failed with exit code $rc"
            echo "Keeping container alive for log inspection."
            sleep infinity
        }
        exit 0
    fi

    echo "Download attempt $i/30 failed, retrying in 10s..."
    sleep 10
done

echo "Failed to download RTX5090_combined_2.sh after 30 attempts."
echo "Keeping container alive for log inspection."
sleep infinity
