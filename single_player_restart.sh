#!/bin/bash
# Single Player Restart Script for Collapsization
# Kills all Godot processes and restarts the game in single player mode

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_APP="/Applications/Godot.app/Contents/MacOS/Godot"
LOG_FILE="$SCRIPT_DIR/godot_play.txt"

echo "=== Collapsization Single Player Restart ==="
echo "Script directory: $SCRIPT_DIR"

# Kill any existing Godot processes
echo "Killing existing Godot processes..."
pkill -9 -f Godot 2>/dev/null || true
sleep 1

# Double-check all are dead
if pgrep -f Godot > /dev/null 2>&1; then
    echo "Warning: Some Godot processes still running, force killing..."
    pkill -9 -f Godot 2>/dev/null || true
    sleep 1
fi

# Clear old log
rm -f "$LOG_FILE"

echo "Starting Godot in single player mode..."
echo "Log file: $LOG_FILE"

# Start Godot with the project
cd "$SCRIPT_DIR"
"$GODOT_APP" --path . 2>&1 | tee "$LOG_FILE" &

GODOT_PID=$!
echo "Godot started with PID: $GODOT_PID"

# Wait a moment for startup
sleep 3

# Check if it's still running
if ps -p $GODOT_PID > /dev/null 2>&1; then
    echo "✓ Godot is running successfully"
    echo ""
    echo "To view logs in real-time:"
    echo "  tail -f $LOG_FILE"
    echo ""
    echo "To stop the game:"
    echo "  pkill -f Godot"
else
    echo "✗ Godot may have crashed. Check $LOG_FILE for errors:"
    echo ""
    head -50 "$LOG_FILE"
fi

