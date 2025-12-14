#!/usr/bin/env bash
# Run the AI inference server locally
# Usage: ./run_inference.sh [checkpoint_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Find checkpoint directory (default to latest H100 results)
CHECKPOINT_DIR="${1:-$(ls -dt results/H100_SXM_* 2>/dev/null | head -1)}"

if [[ -z "$CHECKPOINT_DIR" || ! -d "$CHECKPOINT_DIR" ]]; then
    echo "❌ No checkpoint directory found"
    echo "Usage: $0 [checkpoint_dir]"
    echo "Example: $0 results/H100_SXM_20251214_083408"
    exit 1
fi

echo "=== Collapsization AI Inference Server ==="
echo "Checkpoint dir: $CHECKPOINT_DIR"

# Setup venv if needed
if [[ ! -d ".venv" ]]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
fi

source .venv/bin/activate

# Install dependencies if needed
if ! python -c "import torch, websockets, pyspiel" 2>/dev/null; then
    echo "Installing dependencies..."
    pip install --quiet torch numpy websockets open_spiel
fi

# Check for checkpoint files
MAYOR_CKPT="$CHECKPOINT_DIR/checkpoints/ppo_mayor_ep500000.pt"
INDUSTRY_CKPT="$CHECKPOINT_DIR/checkpoints/ppo_industry_ep500000.pt"
URBANIST_CKPT="$CHECKPOINT_DIR/checkpoints/ppo_urbanist_ep500000.pt"

for ckpt in "$MAYOR_CKPT" "$INDUSTRY_CKPT" "$URBANIST_CKPT"; do
    if [[ ! -f "$ckpt" ]]; then
        echo "❌ Checkpoint not found: $ckpt"
        exit 1
    fi
done

echo ""
echo "🤖 Starting inference server on ws://localhost:8765"
echo "   Press Ctrl+C to stop"
echo ""

exec python serve.py \
    --mayor-checkpoint="$MAYOR_CKPT" \
    --industry-checkpoint="$INDUSTRY_CKPT" \
    --urbanist-checkpoint="$URBANIST_CKPT" \
    --port=8765
