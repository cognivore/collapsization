# Collapsization RL Training

Self-play reinforcement learning for training game-breaking bots for Collapsization.

## Overview

This training infrastructure implements Collapsization as an OpenSpiel game for self-play reinforcement learning. The trained models can be integrated with the Godot game via WebSocket inference server.

## Directory Structure

```
training/
├── deploy.py                # One-click VAST.AI deployment script
├── setup.sh                 # VENV setup script
├── requirements.txt         # Python dependencies
├── train.py                 # Main training entrypoint
├── evaluate.py              # Agent evaluation
├── serve.py                 # WebSocket inference server
├── env.example              # Example configuration file
├── collapsization/          # OpenSpiel game implementation
│   ├── __init__.py
│   ├── constants.py         # Game constants (suits, ranks, etc.)
│   ├── observation.py       # Player-specific observation encoding
│   └── game.py              # OpenSpiel game definition
├── agents/                  # Agent implementations
│   ├── __init__.py
│   ├── random_agent.py      # Random baseline
│   ├── scripted_agent.py    # Rule-based baseline (ported from GDScript)
│   └── learned_agent.py     # DQN/PPO wrapper
└── tests/                   # Unit tests
    ├── test_game.py
    └── test_agents.py
```

---

## One-Click VAST.AI Deployment

The simplest way to train bots is with the automated deployment script.

### Setup

```bash
cd training

# Copy example config and edit with your VAST.AI API key
cp env.example .env
# Edit .env with your values (especially VAST_API_KEY)
```

### Full Deployment (Recommended)

```bash
# This will: provision instance → upload code → setup env → start training
python deploy.py
```

That's it! The script will:
1. Find the cheapest GPU matching your criteria
2. Create a VAST.AI instance
3. Upload the training code
4. Setup the Python environment
5. Start training in a tmux session
6. Report progress to mothership (if configured)

### Individual Commands

```bash
# Just provision an instance
python deploy.py provision

# Upload code to existing instance
python deploy.py upload

# Setup environment
python deploy.py setup

# Start training
python deploy.py train

# Check training status
python deploy.py status

# Monitor until complete (polls every 60s, reports to mothership)
python deploy.py monitor

# Download results
python deploy.py download

# Stop instance (keeps data)
python deploy.py stop

# Destroy instance (loses data)
python deploy.py destroy
```

### Configuration Options (.env)

```bash
# Optional - if not set, uses: passveil show vast.ai/api
# VAST_API_KEY=your_key_here

# Training
TRAINING_PHASE=ppo           # random, scripted, tabular, dqn, ppo
TRAINING_EPISODES=500000
POPULATION_SIZE=5
SAVE_EVERY=50000

# Instance (defaults to H100 for fast training)
GPU_TYPE=H100                # H100, A100, RTX_4090, RTX_3090, A10
MAX_PRICE_PER_HOUR=3.50
MIN_GPU_RAM=80
MIN_DISK=100
MIN_RAM=64

# Optional: Webhook for status updates
MOTHERSHIP_URL=https://your-server.com/api/training/report
```

**Note:** If `VAST_API_KEY` is not set in `.env`, the script will automatically try to retrieve it from `passveil show vast.ai/api`.

---

## Local Development

### Quick Start

```bash
cd training
./setup.sh
source .venv/bin/activate

# Run tests
pytest

# Run random baseline (smoke test)
python train.py --phase=random --episodes=1000

# Run scripted baseline
python train.py --phase=scripted --episodes=1000
```

### Training Phases

The training follows a progressive approach:

1. **Random Baseline** - Smoke test the game implementation
2. **Scripted Baseline** - Establish baseline with rule-based bots
3. **Tabular Q-Learning** - Validate observation/action interface
4. **DQN** - Deep Q-network with experience replay
5. **PPO Self-Play** - Population-based self-play training

```bash
# Phase 1: Random (quick validation)
python train.py --phase=random --episodes=1000

# Phase 2: Scripted (baseline metrics)
python train.py --phase=scripted --episodes=1000

# Phase 3: Tabular Q (interface validation)
python train.py --phase=tabular --episodes=10000

# Phase 4: DQN (requires GPU)
python train.py --phase=dqn --episodes=100000 --save-every=10000

# Phase 5: PPO self-play (requires GPU)
python train.py --phase=ppo --population=5 --episodes=500000
```

---

## Manual VAST.AI Access

If you need to SSH into the instance manually after using deploy.py:

```bash
# Check connection details
cat .env.instance

# SSH into the instance
ssh -p <SSH_PORT> root@<SSH_HOST>

# Attach to training session
tmux attach -t training

# TensorBoard (forward port to local)
ssh -L 6006:localhost:6006 -p <SSH_PORT> root@<SSH_HOST>
```

### Cost Optimization Tips

1. **Use deploy.py**: Automatically finds cheapest matching GPU
2. **Start small**: Validate with 10K episodes before 500K
3. **Monitor early**: Check TensorBoard after 5K episodes
4. **Stop when done**: `python deploy.py stop` to pause billing
5. **Destroy unused**: `python deploy.py destroy` when finished

---

## Inference Server

### Running Locally

```bash
# With scripted agents (no checkpoints needed)
python serve.py --scripted --port=8765

# With trained checkpoints
python serve.py --checkpoint=checkpoints/best.pt --port=8765

# With per-role checkpoints
python serve.py \
    --mayor-checkpoint=checkpoints/ppo_mayor_ep500000.pt \
    --industry-checkpoint=checkpoints/ppo_industry_ep500000.pt \
    --urbanist-checkpoint=checkpoints/ppo_urbanist_ep500000.pt \
    --port=8765
```

### Testing the Server

```bash
# In another terminal
python -c "
import asyncio
import websockets
import json

async def test():
    async with websockets.connect('ws://localhost:8765') as ws:
        # Send ping
        await ws.send(json.dumps({'type': 'ping'}))
        response = await ws.recv()
        print('Ping response:', response)

        # Request action
        await ws.send(json.dumps({
            'type': 'get_action',
            'player': 1,
            'observation': {
                'phase': 2,
                'turn': 1,
                'scores': {'mayor': 0, 'industry': 0, 'urbanist': 0},
                'frontier_hexes': [[1,0,-1], [0,1,-1]],
                'revealed_card': {'suit': 0, 'rank': '7', 'value': 7},
            }
        }))
        response = await ws.recv()
        print('Action response:', response)

asyncio.run(test())
"
```

### Godot Integration

1. Enable RL bots in GameManager:
   - Set `use_rl_bots = true`
   - Set `rl_server_url` to your server address

2. Start the inference server before running the game

3. The game will automatically:
   - Connect to the server
   - Request actions for bot-controlled roles
   - Fall back to scripted bots if server is unavailable

---

## Evaluation

### Compare Against Baselines

```bash
# Evaluate checkpoint against random
python evaluate.py --checkpoint=checkpoints/dqn_mayor_ep100000.pt --role=mayor --games=100

# Custom matchup
python evaluate.py --matchup mayor:dqn industry:scripted urbanist:random --games=100
```

### Expected Results

| Phase | Mayor Win Rate | Notes |
|-------|----------------|-------|
| Random | ~33% | Equal chance baseline |
| Scripted | ~40-50% | Strategic bot baseline |
| DQN (100K) | ~55-60% | Early learning |
| PPO (500K) | ~65-70% | Self-play improvement |

---

## Troubleshooting

### CUDA Out of Memory

Reduce batch size:
```bash
python train.py --phase=dqn --batch-size=32
```

### Game Not Terminating

Check for infinite loops in legal actions. Run with debug logging:
```bash
python -c "
from collapsization import CollapsizationGame
from agents import play_random_game
scores = play_random_game(CollapsizationGame(), seed=42)
print('Scores:', scores)
"
```

### WebSocket Connection Failed

1. Check server is running: `netstat -tlnp | grep 8765`
2. Check firewall rules
3. Try localhost first: `python serve.py --host=127.0.0.1`

---

## Architecture Notes

### Why OpenSpiel?

- Built-in support for imperfect information games
- Standardized API for game definition
- Integration with various RL algorithms
- Active development and documentation

### Observation Design

Observations are role-specific to respect information asymmetry:
- **Mayor**: Hand, revealed card, nominations (no reality tiles)
- **Advisors**: Reality tiles, revealed card, own tray (no full hand)

### Action Encoding

- **Mayor Reveal**: Actions 0-2 (which card to reveal)
- **Advisor Commit**: `frontier_idx × 39 + claim_card_idx`
- **Mayor Build**: `hand_card_idx × 2 + nomination_idx`

### Reward Shaping

Dense per-turn rewards (faster learning):
- Mayor: +1 on scoring, -10 on mine hit
- Advisors: +1 when Mayor builds on their nomination

---

## License

MIT License - See main repository for details.
