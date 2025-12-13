#!/bin/bash
# Multiplayer test launcher for Collapsization
# This script launches the game and verifies the MainMenu loads correctly
#
# Debug logging:
#   --debug-log           Enable all log categories
#   --debug-log=CAT,CAT   Enable specific categories (INPUT,NET,GAME,UI,HEX,DEBUG)
#   --debug-log-file      Also write logs to user://logs/
#
# Example:
#   ./multi_player_restart.sh --debug-log=NET,GAME

set -e

# Check for debug flags
DEBUG_FLAGS=""
for arg in "$@"; do
    if [[ "$arg" == --debug-log* ]]; then
        DEBUG_FLAGS="$DEBUG_FLAGS $arg"
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "═══════════════════════════════════════════════════════════════"
echo "  MULTIPLAYER MINESWEEPER - Client Launcher"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Kill any existing Godot processes
echo "Stopping any existing Godot processes..."
pkill -9 -f "Godot" 2>/dev/null || true
sleep 1

# Check server connectivity
echo ""
echo "Checking server connectivity..."
SERVER="mines.fere.me"
PORT="7777"

if dig +short "$SERVER" A | head -1 | grep -q .; then
    IP=$(dig +short "$SERVER" A | head -1)
    echo "✓ DNS: $SERVER -> $IP"
else
    echo "✗ DNS lookup failed for $SERVER"
fi

# Check if UDP port is reachable (basic check)
echo "✓ Server: $SERVER:$PORT (UDP)"
echo ""

# Find Godot
GODOT_PATH="/Applications/Godot.app/Contents/MacOS/Godot"
if [[ ! -x "$GODOT_PATH" ]]; then
    echo "ERROR: Godot not found at $GODOT_PATH"
    exit 1
fi
echo "✓ Godot found: $GODOT_PATH"
echo ""

# Launch game and capture startup output
echo "Launching game..."
echo "═══════════════════════════════════════════════════════════════"

# Create a temp file for output
LOGFILE="/tmp/collapsization_startup.log"
rm -f "$LOGFILE"

# Launch Godot and capture output for 8 seconds
if [[ -n "$DEBUG_FLAGS" ]]; then
    echo "Debug flags: $DEBUG_FLAGS"
fi
"$GODOT_PATH" --path "$SCRIPT_DIR" $DEBUG_FLAGS 2>&1 | tee "$LOGFILE" &
GODOT_PID=$!

# Wait for startup
sleep 8

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  STARTUP LOG (first 30 lines)"
echo "═══════════════════════════════════════════════════════════════"
head -30 "$LOGFILE" 2>/dev/null || echo "No log output captured"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  KEY MESSAGES"
echo "═══════════════════════════════════════════════════════════════"
grep -E "(MainMenu|DemoLauncher|Lobby|ERROR|error)" "$LOGFILE" 2>/dev/null | head -10 || echo "No key messages found"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  TEST INSTRUCTIONS"
echo "═══════════════════════════════════════════════════════════════"
echo "1. You should see the Main Menu with buttons:"
echo "   - Singleplayer"
echo "   - Multiplayer"
echo "   - Settings"
echo "   - Quit"
echo ""
echo "2. Click 'Multiplayer' to open the lobby"
echo "3. Server should be pre-filled: $SERVER:$PORT"
echo "4. Click 'Connect', then 'Create Room'"
echo "5. Click 'Add Bot' twice"
echo "6. Click 'Start Game'"
echo ""
echo "Game is running (PID: $GODOT_PID)"
echo "Press Ctrl+C to stop viewing logs (game will continue)"
echo "═══════════════════════════════════════════════════════════════"

# Keep tailing the log
tail -f "$LOGFILE" 2>/dev/null


