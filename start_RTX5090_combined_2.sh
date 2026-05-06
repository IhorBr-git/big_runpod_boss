#!/bin/bash

set -euo pipefail

cd /workspace

SCRIPT_URL="https://raw.githubusercontent.com/IhorBr-git/big_runpod_boss/refs/heads/main/RTX5090_combined_2.sh"
SCRIPT_PATH="/workspace/RTX5090_combined_2.sh"

rm -f "$SCRIPT_PATH"

for i in $(seq 1 30); do
    if wget -q "$SCRIPT_URL" -O "$SCRIPT_PATH"; then
        chmod +x "$SCRIPT_PATH"
        exec "$SCRIPT_PATH"
    fi

    echo "Attempt $i/30 failed, retrying in 10s..."
    sleep 10
done

echo "Failed to download RTX5090_combined_2.sh after 30 attempts."
exit 1
