#!/bin/bash
# Setup script for Collapsization RL training environment
# Designed for VAST.AI deployment with VENV

set -e

echo "=== Collapsization RL Training Setup ==="

# Check Python version (minimum 3.9)
PYTHON_VERSION=$(python3 --version 2>&1 | cut -d' ' -f2)
PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d'.' -f1)
PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d'.' -f2)
echo "Python version: $PYTHON_VERSION"

if [[ "$PYTHON_MAJOR" -lt 3 ]] || [[ "$PYTHON_MAJOR" -eq 3 && "$PYTHON_MINOR" -lt 9 ]]; then
    echo "Error: Python 3.9+ required, got $PYTHON_VERSION"
    exit 1
fi

# Create virtual environment
if [ -d ".venv" ]; then
    echo "Virtual environment already exists, removing..."
    rm -rf .venv
fi

echo "Creating virtual environment..."
python3 -m venv .venv

echo "Activating virtual environment..."
source .venv/bin/activate

echo "Upgrading pip..."
pip install --upgrade pip wheel setuptools

echo "Installing dependencies..."
pip install -r requirements.txt

# Verify installations
echo ""
echo "=== Verifying installations ==="
python3 -c "import pyspiel; print(f'OpenSpiel: {pyspiel.__file__}')"
python3 -c "import torch; print(f'PyTorch: {torch.__version__}, CUDA: {torch.cuda.is_available()}')"
python3 -c "import numpy; print(f'NumPy: {numpy.__version__}')"

# Test game import
echo ""
echo "=== Testing Collapsization game ==="
python3 -c "
import sys
sys.path.insert(0, '.')
from collapsization import CollapsizationGame, CollapsizationState
game = CollapsizationGame()
state = game.new_initial_state()
print(f'Game created successfully')
print(f'Initial state: {state}')
print(f'Current player: {state.current_player()}')
"

echo ""
echo "=== Setup complete ==="
echo ""
echo "To activate the environment:"
echo "  source .venv/bin/activate"
echo ""
echo "To run training:"
echo "  python train.py --phase=random --episodes=1000"
echo ""
