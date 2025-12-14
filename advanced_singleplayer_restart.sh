#!/usr/bin/env bash
#
# Advanced Singleplayer - Play against trained RL bots
#
# This script:
#   1. Kills any existing inference server
#   2. Starts the AI inference server with trained checkpoints
#   3. Waits for server to be ready
#   4. Launches Godot in singleplayer mode with RL bots enabled
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

GODOT_APP="/Applications/Godot.app/Contents/MacOS/Godot"
PROJECT_PATH="$SCRIPT_DIR/project.godot"
TRAINING_DIR="$SCRIPT_DIR/training"
SERVER_PORT=8765
SERVER_URL="ws://localhost:$SERVER_PORT"

# Find latest checkpoint directory
# Priority: argument > new format (YYYY-MM-DD/NNNNNNN) > old format (GPU_DATE)
find_latest_checkpoint() {
    local results_dir="$TRAINING_DIR/results"

    # New format: find latest date folder, then latest episode folder within it
    local latest_date=$(ls -d "$results_dir"/20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] 2>/dev/null | sort -r | head -1)
    if [[ -n "$latest_date" ]]; then
        local latest_episode=$(ls -d "$latest_date"/[0-9]* 2>/dev/null | sort -r | head -1)
        # Check if there are any .pt files
        if [[ -n "$latest_episode" ]] && ls "$latest_episode"/ppo_mayor_ep*.pt >/dev/null 2>&1; then
            echo "$latest_episode"
            return 0
        fi
    fi

    # Old format: H100_SXM_* or RTX_*
    local old_format=$(ls -dt "$results_dir"/H100_SXM_* "$results_dir"/RTX_* 2>/dev/null | head -1)
    if [[ -n "$old_format" ]]; then
        echo "$old_format"
        return 0
    fi

    return 1
}

CHECKPOINT_DIR="${1:-$(find_latest_checkpoint)}"

# ─────────────────────────────────────────────────────────────────────────────
# Functions
# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
    echo ""
    echo "🛑 Shutting down..."
    pkill -f "serve.py" 2>/dev/null || true
    exit 0
}

trap cleanup SIGINT SIGTERM

check_godot() {
    if [[ ! -x "$GODOT_APP" ]]; then
        # Try to find Godot
        local found
        found=$(ls -d /Applications/Godot*.app/Contents/MacOS/Godot 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            GODOT_APP="$found"
        else
            echo "❌ Godot not found at $GODOT_APP"
            echo "   Install Godot or set GODOT_APP environment variable"
            exit 1
        fi
    fi
}

check_checkpoints() {
    if [[ -z "$CHECKPOINT_DIR" || ! -d "$CHECKPOINT_DIR" ]]; then
        echo "❌ No checkpoint directory found"
        echo "   Run training first or specify checkpoint dir:"
        echo "   $0 /path/to/checkpoints"
        exit 1
    fi

    # Find mayor checkpoint - try new format first (direct in folder), then old format (in checkpoints/)
    # Disable glob failure temporarily
    MAYOR_CKPT=""
    shopt -s nullglob
    local direct_ckpts=("$CHECKPOINT_DIR"/ppo_mayor_ep*.pt)
    local subdir_ckpts=("$CHECKPOINT_DIR"/checkpoints/ppo_mayor_ep*.pt)
    shopt -u nullglob

    if [[ ${#direct_ckpts[@]} -gt 0 ]]; then
        MAYOR_CKPT=$(printf '%s\n' "${direct_ckpts[@]}" | sort -V | tail -1)
    elif [[ ${#subdir_ckpts[@]} -gt 0 ]]; then
        MAYOR_CKPT=$(printf '%s\n' "${subdir_ckpts[@]}" | sort -V | tail -1)
    fi

    if [[ -z "$MAYOR_CKPT" || ! -f "$MAYOR_CKPT" ]]; then
        echo "❌ No mayor checkpoint found in $CHECKPOINT_DIR"
        echo "   Looked for: $CHECKPOINT_DIR/ppo_mayor_ep*.pt"
        echo "   And: $CHECKPOINT_DIR/checkpoints/ppo_mayor_ep*.pt"
        exit 1
    fi

    # Extract episode number and find matching checkpoints for other roles
    local episode=$(echo "$MAYOR_CKPT" | grep -oE 'ep[0-9]+' | grep -oE '[0-9]+')
    local ckpt_dir=$(dirname "$MAYOR_CKPT")

    INDUSTRY_CKPT="$ckpt_dir/ppo_industry_ep${episode}.pt"
    URBANIST_CKPT="$ckpt_dir/ppo_urbanist_ep${episode}.pt"

    if [[ ! -f "$INDUSTRY_CKPT" || ! -f "$URBANIST_CKPT" ]]; then
        echo "❌ Missing checkpoints for episode $episode"
        echo "   Mayor: $MAYOR_CKPT"
        echo "   Industry: $INDUSTRY_CKPT (exists: $(test -f "$INDUSTRY_CKPT" && echo yes || echo no))"
        echo "   Urbanist: $URBANIST_CKPT (exists: $(test -f "$URBANIST_CKPT" && echo yes || echo no))"
        exit 1
    fi

    echo "📁 Using checkpoints from: $CHECKPOINT_DIR"
    echo "   Episode: $episode"
}

start_inference_server() {
    echo "🤖 Starting AI inference server..."

    # Kill existing server
    pkill -f "serve.py" 2>/dev/null || true
    sleep 1

    # Setup Python environment
    cd "$TRAINING_DIR"

    if [[ ! -d ".venv" ]]; then
        echo "   Creating virtual environment..."
        python3 -m venv .venv
    fi

    source .venv/bin/activate

    # Install deps if needed
    if ! python -c "import torch, websockets, pyspiel" 2>/dev/null; then
        echo "   Installing dependencies..."
        pip install --quiet torch numpy websockets open_spiel
    fi

    # Start server in background (using checkpoints found by check_checkpoints)
    python serve.py \
        --mayor-checkpoint="$MAYOR_CKPT" \
        --industry-checkpoint="$INDUSTRY_CKPT" \
        --urbanist-checkpoint="$URBANIST_CKPT" \
        --port=$SERVER_PORT \
        > "$TRAINING_DIR/inference.log" 2>&1 &

    SERVER_PID=$!
    echo "   Server PID: $SERVER_PID"

    cd "$SCRIPT_DIR"
}

wait_for_server() {
    echo "⏳ Waiting for server to be ready..."

    local max_wait=30
    local waited=0

    while ! nc -z localhost $SERVER_PORT 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $max_wait ]]; then
            echo "❌ Server failed to start (timeout after ${max_wait}s)"
            echo "   Check logs: $TRAINING_DIR/inference.log"
            cat "$TRAINING_DIR/inference.log" | tail -20
            exit 1
        fi
    done

    echo "✅ Server ready on port $SERVER_PORT"
}

launch_godot() {
    echo ""
    echo "🎮 Launching Collapsization..."
    echo "   You play as MAYOR"
    echo "   AI plays INDUSTRY & URBANIST advisors"
    echo ""
    echo "   Press Ctrl+C to stop"
    echo ""

    # Launch Godot with --rl-bots flag to enable AI opponents
    "$GODOT_APP" --path "$SCRIPT_DIR" -- --rl-bots 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         COLLAPSIZATION - Advanced Singleplayer             ║"
echo "║              Play against trained AI bots                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

check_godot
check_checkpoints
start_inference_server
wait_for_server
launch_godot

# Cleanup on exit
cleanup

