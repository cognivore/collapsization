#!/usr/bin/env bash
# Self-play training script for local development/testing
# Usage: ./self_play_restart.sh [num_episodes]

set -e

EPISODES="${1:-10000}"
cd "$(dirname "$0")/training"

echo "=== Starting Self-Play Training ==="
echo "Episodes: $EPISODES"
echo "Device: CPU (MPS not well supported by PyTorch)"
echo ""

source .venv/bin/activate
python3 -c "
import sys
sys.path.insert(0, '.')
from train import run_ppo_selfplay
run_ppo_selfplay(num_episodes=$EPISODES, device='cpu', save_every=1000)
"

