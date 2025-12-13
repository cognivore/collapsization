#!/bin/bash
# Run GUT (Godot Unit Testing) tests for Collapsization
#
# Usage:
#   ./run_tests.sh           Run all tests
#   ./run_tests.sh -v         Verbose output
#   ./run_tests.sh -gtest=X   Run specific test file or pattern

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Find Godot
GODOT_PATH="/Applications/Godot.app/Contents/MacOS/Godot"
if [[ ! -x "$GODOT_PATH" ]]; then
    # Try finding via which (might be in PATH on Linux/Nix)
    GODOT_PATH=$(which godot 2>/dev/null || true)
    if [[ -z "$GODOT_PATH" || ! -x "$GODOT_PATH" ]]; then
        echo "ERROR: Godot not found. Install Godot or set GODOT_PATH."
        exit 1
    fi
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  COLLAPSIZATION - Running Tests (GUT)"
echo "═══════════════════════════════════════════════════════════════"
echo "Using: $GODOT_PATH"
echo ""

# Pass through any additional arguments to GUT
"$GODOT_PATH" --headless -s addons/gut/gut_cmdln.gd "$@"

EXIT_CODE=$?

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "═══════════════════════════════════════════════════════════════"
    echo "  ✓ All tests passed!"
    echo "═══════════════════════════════════════════════════════════════"
else
    echo "═══════════════════════════════════════════════════════════════"
    echo "  ✗ Some tests failed (exit code: $EXIT_CODE)"
    echo "═══════════════════════════════════════════════════════════════"
fi

exit $EXIT_CODE

