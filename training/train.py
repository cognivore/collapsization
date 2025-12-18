#!/usr/bin/env python3
"""Main training script for Collapsization RL bots.

Progressive training phases:
1. Random baseline (smoke test)
2. Tabular Q-learning (validate interface)
3. DQN with legal action masking
4. PPO self-play with population mixing

Usage:
    python train.py --phase=random --episodes=1000
    python train.py --phase=tabular --episodes=10000
    python train.py --phase=dqn --episodes=100000 --save-every=10000
    python train.py --phase=ppo --population=5 --episodes=500000
"""

import argparse
import os
import sys
import random
import time
from pathlib import Path
from collections import defaultdict
from typing import Optional

import numpy as np

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

from collapsization import CollapsizationGame, Role, Phase
from collapsization.constants import NUM_CARDS, index_to_card, card_label, Suit
from collapsization.game import ACTION_COMMIT_BASE
from agents import RandomAgent, ScriptedAdvisorAgent, ScriptedMayorAgent

try:
    import torch
    import torch.nn as nn
    import torch.optim as optim
    from torch.utils.tensorboard import SummaryWriter

    TORCH_AVAILABLE = True
except ImportError:
    TORCH_AVAILABLE = False
    print("Warning: PyTorch not available, deep learning phases disabled")

from tqdm import tqdm
import glob
import math


# ─────────────────────────────────────────────────────────────────────────────
# Checkpoint Pool for Diverse Agent Training (PFSP)
# ─────────────────────────────────────────────────────────────────────────────


class CheckpointPool:
    """Manages a pool of historical checkpoints for diverse training.

    Implements Prioritized Fictitious Self-Play (PFSP):
    - Tracks win rates against each historical checkpoint
    - Prioritizes opponents that beat the current agent
    - Maintains diverse agent population for robust training
    """

    def __init__(self, pool_dir: str, max_pool_size: int = 50):
        self.pool_dir = pool_dir
        self.max_pool_size = max_pool_size
        os.makedirs(pool_dir, exist_ok=True)

        # Win rate tracking: {role: {checkpoint_id: (wins, games)}}
        self.win_rates: dict[Role, dict[str, tuple[int, int]]] = {
            role: {} for role in Role
        }

        # Loaded networks cache: {checkpoint_path: network}
        self._cache: dict[str, any] = {}

    def save_checkpoint(
        self,
        role: Role,
        network: "torch.nn.Module",
        episode: int,
        architecture: str = "alphazero",
    ) -> str:
        """Save a checkpoint to the pool."""
        checkpoint_id = f"{role.name.lower()}_v{episode:07d}"
        path = os.path.join(self.pool_dir, f"{checkpoint_id}.pt")

        torch.save(
            {
                "policy_net": network.state_dict(),
                "architecture": architecture,
                "episode": episode,
                "role": role.name,
            },
            path,
        )

        # Initialize win rate tracking for this checkpoint
        if checkpoint_id not in self.win_rates[role]:
            self.win_rates[role][checkpoint_id] = (0, 0)

        # Prune old checkpoints if pool is too large
        self._prune_pool(role)

        return path

    def _prune_pool(self, role: Role):
        """Remove oldest checkpoints if pool exceeds max size."""
        pattern = os.path.join(self.pool_dir, f"{role.name.lower()}_v*.pt")
        checkpoints = sorted(glob.glob(pattern))

        while len(checkpoints) > self.max_pool_size:
            oldest = checkpoints.pop(0)
            os.remove(oldest)
            # Remove from win rate tracking
            checkpoint_id = os.path.basename(oldest).replace(".pt", "")
            if checkpoint_id in self.win_rates[role]:
                del self.win_rates[role][checkpoint_id]

    def get_checkpoints(self, role: Role) -> list[str]:
        """Get all checkpoint paths for a role."""
        pattern = os.path.join(self.pool_dir, f"{role.name.lower()}_v*.pt")
        return sorted(glob.glob(pattern))

    def sample_opponent_pfsp(
        self,
        role: Role,
        device: str = "cpu",
        alpha: float = 2.0,
        network_class: type = None,
        network_kwargs: dict = None,
    ) -> tuple[str, "torch.nn.Module"]:
        """Sample an opponent using PFSP (Prioritized Fictitious Self-Play).

        Prioritizes opponents that beat the current agent:
        P(opponent_i) ∝ (1 - win_rate_vs_i)^alpha

        Args:
            role: The role to sample an opponent for
            device: Device to load network to
            alpha: PFSP exponent (higher = more focus on hard opponents)
            network_class: Network class to instantiate
            network_kwargs: Arguments for network class

        Returns:
            (checkpoint_id, loaded_network)
        """
        checkpoints = self.get_checkpoints(role)
        if not checkpoints:
            return None, None

        # Calculate PFSP weights
        weights = []
        checkpoint_ids = []
        for path in checkpoints:
            checkpoint_id = os.path.basename(path).replace(".pt", "")
            checkpoint_ids.append(checkpoint_id)

            wins, games = self.win_rates[role].get(checkpoint_id, (0, 0))
            if games > 0:
                win_rate = wins / games
            else:
                win_rate = 0.5  # Assume 50% for untested opponents

            # PFSP: prioritize opponents we lose to
            weight = (1.0 - win_rate + 0.01) ** alpha
            weights.append(weight)

        # Normalize weights
        total = sum(weights)
        weights = [w / total for w in weights]

        # Sample checkpoint
        idx = random.choices(range(len(checkpoints)), weights=weights)[0]
        chosen_path = checkpoints[idx]
        chosen_id = checkpoint_ids[idx]

        # Load network
        network = self._load_network(chosen_path, device, network_class, network_kwargs)

        return chosen_id, network

    def _load_network(
        self,
        path: str,
        device: str,
        network_class: type,
        network_kwargs: dict,
    ) -> "torch.nn.Module":
        """Load a network from checkpoint, using cache."""
        if path in self._cache:
            return self._cache[path]

        checkpoint = torch.load(path, map_location=device)
        network = network_class(**network_kwargs).to(device)
        network.load_state_dict(checkpoint["policy_net"])
        network.eval()

        # Cache the loaded network
        self._cache[path] = network

        # Limit cache size
        if len(self._cache) > 20:
            # Remove oldest entry
            oldest_key = next(iter(self._cache))
            del self._cache[oldest_key]

        return network

    def update_win_rate(self, role: Role, checkpoint_id: str, won: bool):
        """Update win rate tracking after a game."""
        if checkpoint_id not in self.win_rates[role]:
            self.win_rates[role][checkpoint_id] = (0, 0)

        wins, games = self.win_rates[role][checkpoint_id]
        games += 1
        if won:
            wins += 1
        self.win_rates[role][checkpoint_id] = (wins, games)

    def get_pool_stats(self) -> dict:
        """Get statistics about the checkpoint pool."""
        stats = {}
        for role in Role:
            checkpoints = self.get_checkpoints(role)
            stats[role.name] = {
                "count": len(checkpoints),
                "win_rates": {
                    k: v[0] / v[1] if v[1] > 0 else 0.5
                    for k, v in self.win_rates[role].items()
                },
            }
        return stats


# Training-time mine density control
# Training: Start with 0 mines in initial frontier so Mayor can learn to survive
# This gives Mayor time to learn game mechanics before mines appear from deck
# Set to -1 for fully random (production/evaluation)
MAX_INITIAL_SPADES = 0


def create_game() -> CollapsizationGame:
    """Create a new Collapsization game instance."""
    return CollapsizationGame(
        {
            "max_frontier": 50,
            "max_initial_spades": MAX_INITIAL_SPADES,
        }
    )


# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Random Baseline
# ─────────────────────────────────────────────────────────────────────────────


def run_random_baseline(num_episodes: int = 1000, seed: Optional[int] = None) -> dict:
    """Run random agents to smoke test the game implementation.

    Returns statistics about game outcomes.
    """
    print(f"\n=== Phase 1: Random Baseline ({num_episodes} episodes) ===\n")

    rng = random.Random(seed)
    game = create_game()

    stats = defaultdict(list)
    win_counts = {"mayor": 0, "industry": 0, "urbanist": 0, "tie": 0}

    for ep in tqdm(range(num_episodes), desc="Random games"):
        state = game.new_initial_state()
        turns = 0

        while not state.is_terminal():
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = rng.choices(
                    [a for a, _ in outcomes], weights=[p for _, p in outcomes]
                )[0]
            else:
                player = state.current_player()
                legal_actions = state.legal_actions(player)
                action = rng.choice(legal_actions)

            state.apply_action(action)
            turns += 1

        returns = state.returns()
        stats["mayor_score"].append(returns[0])
        stats["industry_score"].append(returns[1])
        stats["urbanist_score"].append(returns[2])
        stats["turns"].append(turns)

        # Determine winner
        max_score = max(returns)
        winners = [i for i, s in enumerate(returns) if s == max_score]
        if len(winners) > 1:
            win_counts["tie"] += 1
        else:
            win_counts[["mayor", "industry", "urbanist"][winners[0]]] += 1

    # Print summary
    print("\n=== Random Baseline Results ===")
    print(f"Episodes: {num_episodes}")
    print(f"Avg turns: {np.mean(stats['turns']):.1f} ± {np.std(stats['turns']):.1f}")
    print(
        f"Mayor avg score: {np.mean(stats['mayor_score']):.2f} ± {np.std(stats['mayor_score']):.2f}"
    )
    print(
        f"Industry avg score: {np.mean(stats['industry_score']):.2f} ± {np.std(stats['industry_score']):.2f}"
    )
    print(
        f"Urbanist avg score: {np.mean(stats['urbanist_score']):.2f} ± {np.std(stats['urbanist_score']):.2f}"
    )
    print(
        f"Win rates: Mayor={win_counts['mayor']/num_episodes:.1%}, "
        f"Industry={win_counts['industry']/num_episodes:.1%}, "
        f"Urbanist={win_counts['urbanist']/num_episodes:.1%}, "
        f"Tie={win_counts['tie']/num_episodes:.1%}"
    )

    return dict(stats)


# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Scripted Baseline
# ─────────────────────────────────────────────────────────────────────────────


def run_scripted_baseline(num_episodes: int = 1000, seed: Optional[int] = None) -> dict:
    """Run scripted agents to establish a baseline.

    Returns statistics about game outcomes.
    """
    print(f"\n=== Phase 2: Scripted Baseline ({num_episodes} episodes) ===\n")

    rng = random.Random(seed)
    game = create_game()

    agents = {
        Role.MAYOR: ScriptedMayorAgent(Role.MAYOR, seed=seed),
        Role.INDUSTRY: ScriptedAdvisorAgent(Role.INDUSTRY, seed=seed),
        Role.URBANIST: ScriptedAdvisorAgent(Role.URBANIST, seed=seed),
    }

    stats = defaultdict(list)
    win_counts = {"mayor": 0, "industry": 0, "urbanist": 0, "tie": 0}

    for ep in tqdm(range(num_episodes), desc="Scripted games"):
        state = game.new_initial_state()
        turns = 0

        while not state.is_terminal():
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = rng.choices(
                    [a for a, _ in outcomes], weights=[p for _, p in outcomes]
                )[0]
            else:
                player = state.current_player()
                agent = agents.get(Role(player))
                if agent:
                    action = agent.step(state)
                else:
                    action = rng.choice(state.legal_actions(player))

            state.apply_action(action)
            turns += 1

        returns = state.returns()
        stats["mayor_score"].append(returns[0])
        stats["industry_score"].append(returns[1])
        stats["urbanist_score"].append(returns[2])
        stats["turns"].append(turns)

        max_score = max(returns)
        winners = [i for i, s in enumerate(returns) if s == max_score]
        if len(winners) > 1:
            win_counts["tie"] += 1
        else:
            win_counts[["mayor", "industry", "urbanist"][winners[0]]] += 1

    print("\n=== Scripted Baseline Results ===")
    print(f"Episodes: {num_episodes}")
    print(f"Avg turns: {np.mean(stats['turns']):.1f} ± {np.std(stats['turns']):.1f}")
    print(
        f"Mayor avg score: {np.mean(stats['mayor_score']):.2f} ± {np.std(stats['mayor_score']):.2f}"
    )
    print(
        f"Industry avg score: {np.mean(stats['industry_score']):.2f} ± {np.std(stats['industry_score']):.2f}"
    )
    print(
        f"Urbanist avg score: {np.mean(stats['urbanist_score']):.2f} ± {np.std(stats['urbanist_score']):.2f}"
    )
    print(
        f"Win rates: Mayor={win_counts['mayor']/num_episodes:.1%}, "
        f"Industry={win_counts['industry']/num_episodes:.1%}, "
        f"Urbanist={win_counts['urbanist']/num_episodes:.1%}, "
        f"Tie={win_counts['tie']/num_episodes:.1%}"
    )

    return dict(stats)


# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Tabular Q-Learning
# ─────────────────────────────────────────────────────────────────────────────


def run_tabular_q(
    num_episodes: int = 10000,
    learning_rate: float = 0.1,
    discount: float = 0.99,
    epsilon_start: float = 1.0,
    epsilon_end: float = 0.1,
    seed: Optional[int] = None,
) -> dict:
    """Run tabular Q-learning to validate the game interface.

    Note: This won't scale well but validates the observation/action interface.
    """
    print(f"\n=== Phase 3: Tabular Q-Learning ({num_episodes} episodes) ===\n")

    rng = random.Random(seed)
    game = create_game()

    # Q-tables per player (using info string as state key)
    q_tables = {
        Role.MAYOR: defaultdict(lambda: defaultdict(float)),
        Role.INDUSTRY: defaultdict(lambda: defaultdict(float)),
        Role.URBANIST: defaultdict(lambda: defaultdict(float)),
    }

    stats = defaultdict(list)
    recent_returns = defaultdict(list)

    for ep in tqdm(range(num_episodes), desc="Q-learning"):
        epsilon = epsilon_start - (epsilon_start - epsilon_end) * (ep / num_episodes)
        state = game.new_initial_state()

        # Track (state, action) pairs for each player
        trajectories = {r: [] for r in Role}

        while not state.is_terminal():
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = rng.choices(
                    [a for a, _ in outcomes], weights=[p for _, p in outcomes]
                )[0]
                state.apply_action(action)
                continue

            player = state.current_player()
            role = Role(player)
            legal_actions = state.legal_actions(player)

            # Get state key (truncated info string for memory efficiency)
            state_key = state.information_state_string(player)[:200]

            # Epsilon-greedy action selection
            if rng.random() < epsilon:
                action = rng.choice(legal_actions)
            else:
                q_values = q_tables[role][state_key]
                if not any(a in q_values for a in legal_actions):
                    action = rng.choice(legal_actions)
                else:
                    action = max(legal_actions, key=lambda a: q_values.get(a, 0.0))

            trajectories[role].append((state_key, action))
            state.apply_action(action)

        # Update Q-values with terminal returns
        returns = state.returns()
        for role in Role:
            reward = returns[int(role)]
            recent_returns[role].append(reward)

            # Backward update with discount
            for i, (s, a) in enumerate(reversed(trajectories[role])):
                discounted_reward = reward * (discount**i)
                old_q = q_tables[role][s][a]
                q_tables[role][s][a] = old_q + learning_rate * (
                    discounted_reward - old_q
                )

        # Logging
        if (ep + 1) % 1000 == 0:
            for role in Role:
                avg = np.mean(recent_returns[role][-1000:])
                stats[f"{role.name.lower()}_avg"].append(avg)

    print("\n=== Tabular Q-Learning Results ===")
    print(
        f"Q-table sizes: Mayor={len(q_tables[Role.MAYOR])}, "
        f"Industry={len(q_tables[Role.INDUSTRY])}, "
        f"Urbanist={len(q_tables[Role.URBANIST])}"
    )
    print(f"Final avg returns (last 1000):")
    for role in Role:
        avg = np.mean(recent_returns[role][-1000:])
        print(f"  {role.name}: {avg:.2f}")

    return dict(stats)


# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: DQN Training
# ─────────────────────────────────────────────────────────────────────────────


def run_dqn(
    num_episodes: int = 100000,
    batch_size: int = 64,
    learning_rate: float = 1e-4,
    discount: float = 0.99,
    epsilon_start: float = 1.0,
    epsilon_end: float = 0.05,
    buffer_size: int = 100000,
    target_update_freq: int = 1000,
    save_every: int = 10000,
    checkpoint_dir: str = "checkpoints",
    seed: Optional[int] = None,
    device: str = "cuda" if TORCH_AVAILABLE and torch.cuda.is_available() else "cpu",
) -> dict:
    """Train DQN agents with experience replay and target networks."""
    if not TORCH_AVAILABLE:
        print("Error: PyTorch required for DQN training")
        return {}

    print(f"\n=== Phase 4: DQN Training ({num_episodes} episodes) ===\n")
    print(f"Device: {device}")

    from agents.learned_agent import PolicyNetwork

    rng = random.Random(seed)
    game = create_game()

    # Create checkpoint directory
    os.makedirs(checkpoint_dir, exist_ok=True)

    # Get observation and action sizes from a sample state
    sample_state = game.new_initial_state()
    # Process chance nodes to get a proper game state for observation sizes
    while sample_state.is_chance_node():
        outcomes = sample_state.chance_outcomes()
        action = outcomes[0][0]
        sample_state.apply_action(action)

    # Get role-specific observation sizes (Mayor vs Advisors have different obs sizes)
    obs_sizes = {
        Role.MAYOR: len(sample_state.observation_tensor(int(Role.MAYOR))),
        Role.INDUSTRY: len(sample_state.observation_tensor(int(Role.INDUSTRY))),
        Role.URBANIST: len(sample_state.observation_tensor(int(Role.URBANIST))),
    }
    num_actions = game.num_distinct_actions()

    print(
        f"Observation sizes: Mayor={obs_sizes[Role.MAYOR]}, Advisors={obs_sizes[Role.INDUSTRY]}, Action space: {num_actions}"
    )

    # Create networks for each player (with role-specific observation sizes)
    policy_nets = {
        role: PolicyNetwork(obs_sizes[role], num_actions).to(device) for role in Role
    }
    target_nets = {
        role: PolicyNetwork(obs_sizes[role], num_actions).to(device) for role in Role
    }
    for role in Role:
        target_nets[role].load_state_dict(policy_nets[role].state_dict())
        target_nets[role].eval()

    optimizers = {
        role: optim.Adam(policy_nets[role].parameters(), lr=learning_rate)
        for role in Role
    }

    # Experience replay buffers
    replay_buffers = {role: [] for role in Role}

    # TensorBoard logging
    writer = SummaryWriter(log_dir=os.path.join(checkpoint_dir, "logs"))

    stats = defaultdict(list)

    for ep in tqdm(range(num_episodes), desc="DQN training"):
        epsilon = epsilon_start - (epsilon_start - epsilon_end) * (ep / num_episodes)
        state = game.new_initial_state()

        episode_transitions = {role: [] for role in Role}

        while not state.is_terminal():
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = rng.choices(
                    [a for a, _ in outcomes], weights=[p for _, p in outcomes]
                )[0]
                state.apply_action(action)
                continue

            player = state.current_player()
            role = Role(player)
            legal_actions = state.legal_actions(player)

            obs = torch.tensor(
                state.observation_tensor(player), dtype=torch.float32, device=device
            )

            # Epsilon-greedy with legal action masking
            if rng.random() < epsilon:
                action = rng.choice(legal_actions)
            else:
                with torch.no_grad():
                    legal_mask = torch.zeros(num_actions, device=device)
                    for a in legal_actions:
                        legal_mask[a] = 1.0
                    q_values = policy_nets[role](
                        obs.unsqueeze(0), legal_mask.unsqueeze(0)
                    )
                    action = q_values.argmax().item()
                    if action not in legal_actions:
                        action = legal_actions[0]

            episode_transitions[role].append((obs, action, legal_actions))
            state.apply_action(action)

        # Store transitions with terminal rewards
        returns = state.returns()
        for role in Role:
            reward = returns[int(role)]
            for i, (obs, action, legal) in enumerate(episode_transitions[role]):
                # Use discounted reward for intermediate steps
                discounted = reward * (
                    discount ** (len(episode_transitions[role]) - i - 1)
                )
                transition = (obs, action, discounted, legal)
                replay_buffers[role].append(transition)
                if len(replay_buffers[role]) > buffer_size:
                    replay_buffers[role].pop(0)

        # Training step
        if ep >= batch_size:
            for role in Role:
                if len(replay_buffers[role]) < batch_size:
                    continue

                batch = rng.sample(replay_buffers[role], batch_size)
                obs_batch = torch.stack([t[0] for t in batch])
                action_batch = torch.tensor([t[1] for t in batch], device=device)
                reward_batch = torch.tensor(
                    [t[2] for t in batch], dtype=torch.float32, device=device
                )

                # Compute Q-values for taken actions
                q_values = policy_nets[role](obs_batch)
                q_taken = q_values.gather(1, action_batch.unsqueeze(1)).squeeze(1)

                # Simple supervised loss toward discounted returns
                loss = nn.functional.mse_loss(q_taken, reward_batch)

                optimizers[role].zero_grad()
                loss.backward()
                nn.utils.clip_grad_norm_(policy_nets[role].parameters(), 1.0)
                optimizers[role].step()

                if ep % 100 == 0:
                    writer.add_scalar(f"loss/{role.name}", loss.item(), ep)

        # Update target networks
        if ep % target_update_freq == 0:
            for role in Role:
                target_nets[role].load_state_dict(policy_nets[role].state_dict())

        # Logging
        if ep % 1000 == 0:
            for i, role in enumerate(Role):
                stats[f"{role.name.lower()}_return"].append(returns[i])
                writer.add_scalar(f"return/{role.name}", returns[i], ep)
            writer.add_scalar("epsilon", epsilon, ep)

        # Checkpointing
        if (ep + 1) % save_every == 0:
            for role in Role:
                path = os.path.join(
                    checkpoint_dir, f"dqn_{role.name.lower()}_ep{ep+1}.pt"
                )
                torch.save(
                    {
                        "policy_net": policy_nets[role].state_dict(),
                        "optimizer": optimizers[role].state_dict(),
                        "episode": ep + 1,
                    },
                    path,
                )
            print(f"  Saved checkpoints at episode {ep + 1}")

    writer.close()
    print("\n=== DQN Training Complete ===")
    return dict(stats)


# ─────────────────────────────────────────────────────────────────────────────
# Reward Mode Configuration
# ─────────────────────────────────────────────────────────────────────────────


from enum import Enum


class RewardMode(Enum):
    """Reward computation strategy for training.

    ADVERSARIAL (default, recommended):
        - Uses delta reward: own_score - best_opponent_score
        - Adds win bonus for sole winner
        - Teaches agents that WINNING requires BEATING opponents
        - For Advisors: Learn to overcome the -2 mine-lie penalty by successfully
          tricking Mayor into mines (ending the game favorably)
        - For Mayor: Learn to survive and outscore Advisors despite their deception

    RAW_SCORES:
        - Uses game's terminal scores directly
        - May lead to score-maximizing play that ignores competitive dynamics
        - Advisors might avoid risky mine-traps even when they'd win

    HYBRID:
        - Weighted combination of raw and adversarial
        - Experimental

    Note: Neither approach guarantees Nash equilibrium for imperfect information games.
    """

    ADVERSARIAL = "adversarial"
    RAW_SCORES = "raw_scores"
    HYBRID = "hybrid"


# Current reward mode (change this to experiment with different strategies)
CURRENT_REWARD_MODE = RewardMode.ADVERSARIAL


def compute_rewards(
    returns: list[float],
    mayor_hit_mine: bool = False,
    mode: RewardMode = CURRENT_REWARD_MODE,
    win_bonus: float = 3.0,
    hybrid_weight: float = 0.5,
) -> dict:
    """Compute rewards based on the selected reward mode.

    Args:
        returns: List of [mayor_score, industry_score, urbanist_score]
        mayor_hit_mine: Whether Mayor hit a mine (for RL penalty, not game score)
        mode: Reward computation strategy (ADVERSARIAL, RAW_SCORES, or HYBRID)
        win_bonus: Bonus for being sole winner (only used in ADVERSARIAL/HYBRID)
        hybrid_weight: Weight for raw scores in HYBRID mode (0-1)

    Returns:
        Dict mapping Role to reward value
    """
    if mode == RewardMode.RAW_SCORES:
        rewards = compute_raw_rewards(returns)
        if mayor_hit_mine:
            rewards[Role.MAYOR] -= 100.0
        return rewards
    elif mode == RewardMode.HYBRID:
        adversarial = compute_adversarial_rewards(returns, mayor_hit_mine, win_bonus)
        raw = compute_raw_rewards(returns)
        if mayor_hit_mine:
            raw[Role.MAYOR] -= 100.0
        return {
            role: hybrid_weight * raw[role] + (1 - hybrid_weight) * adversarial[role]
            for role in Role
        }
    else:  # ADVERSARIAL (default)
        return compute_adversarial_rewards(returns, mayor_hit_mine, win_bonus)


def compute_raw_rewards(returns: list[float]) -> dict:
    """Compute rewards using raw game scores.

    This directly uses the game's terminal scores, which are based on:
    - Per-turn bluff detection scoring (+1/-2)
    - Mayor suit matching (+1)

    Aligns with game mechanics but doesn't create adversarial tension.
    """
    return {
        Role.MAYOR: returns[0],
        Role.INDUSTRY: returns[1],
        Role.URBANIST: returns[2],
    }


def compute_adversarial_rewards(
    returns: list[float], mayor_hit_mine: bool = False, win_bonus: float = 3.0
) -> dict:
    """Compute adversarial rewards based on competitive standing.

    KEY INSIGHT: Mayor hitting a mine = Mayor LOST. Period.
    - Mayor's win condition: SURVIVE and outscore advisors
    - Advisor's win condition: Outscore everyone (including Mayor)
    - If Mayor dies, they CANNOT win. Advisors compete among themselves.

    However, advisors who LIED (negative score) should still be punished.
    So if Mayor dies:
    - Mayor gets massive penalty (-100)
    - Advisors compete among themselves (highest non-negative score wins)
    - If all advisors have non-positive scores, nobody "wins" (failed game)

    Args:
        returns: List of [mayor_score, industry_score, urbanist_score]
        mayor_hit_mine: Whether Mayor hit a mine
        win_bonus: Bonus for being sole winner (default 3.0)

    Returns:
        Dict mapping Role to adversarial reward
    """
    scores = {
        Role.MAYOR: returns[0],
        Role.INDUSTRY: returns[1],
        Role.URBANIST: returns[2],
    }

    rewards = {}

    if mayor_hit_mine:
        # Mayor LOST - they failed their primary objective
        rewards[Role.MAYOR] = -100.0

        # Advisors: you failed to keep Mayor alive
        # If you have positive score, you can still "win" among advisors
        # If you have non-positive score, you also failed - no positive reward
        advisor_scores = {
            Role.INDUSTRY: scores[Role.INDUSTRY],
            Role.URBANIST: scores[Role.URBANIST],
        }
        max_advisor = max(advisor_scores.values())
        advisor_winners = [r for r, s in advisor_scores.items() if s == max_advisor]

        for role in [Role.INDUSTRY, Role.URBANIST]:
            own = scores[role]
            other = scores[Role.URBANIST if role == Role.INDUSTRY else Role.INDUSTRY]
            delta = own - other

            # Win bonus only if sole winner with POSITIVE score
            is_winner = (
                role in advisor_winners and len(advisor_winners) == 1 and own > 0
            )
            bonus = win_bonus if is_winner else 0.0

            # KEY: If you didn't score positive points, you failed too
            # Don't reward "not losing as badly" when Mayor died
            if own <= 0:
                rewards[role] = min(
                    0.0, delta
                )  # At best 0, at worst your negative delta
            else:
                rewards[role] = delta + bonus
    else:
        # Mayor survived - normal 3-way competition
        max_score = max(scores.values())
        winners = [r for r, s in scores.items() if s == max_score]

        for role in Role:
            own_score = scores[role]
            other_scores = [s for r, s in scores.items() if r != role]
            next_closest = max(other_scores)

            delta = own_score - next_closest
            is_winner = role in winners and len(winners) == 1 and own_score > 0
            bonus = win_bonus if is_winner else 0.0

            rewards[role] = delta + bonus

    return rewards


# ─────────────────────────────────────────────────────────────────────────────
# Behavioral Cloning: Pre-train Mayor on Smart Strategy
# ─────────────────────────────────────────────────────────────────────────────


def pretrain_mayor_bc(
    mayor_net: "ResNetPolicyValueNetwork",
    num_demos: int = 5000,
    batch_size: int = 256,
    learning_rate: float = 1e-3,
    epochs: int = 10,
    device: str = "cpu",
) -> None:
    """Pre-train Mayor policy using behavioral cloning on smart strategy.

    The smart strategy:
    1. In Place phase, VERIFY unverified hexes before building
    2. Only BUILD on verified non-Spade hexes
    3. This achieves ~30% survival vs 0% for random

    This gives the policy a head start before self-play fine-tuning.
    """
    from collapsization.game import (
        ACTION_CONTROL_REVEAL_BASE,
        ACTION_BUILD_BASE,
        ACTION_COMMIT_BASE,
        MAX_NOMINATIONS,
        TOTAL_ACTIONS,
    )

    print(f"\n=== Behavioral Cloning: Pre-training Mayor ===")
    print(f"Collecting {num_demos} demonstrations from smart strategy...")

    game = create_game()
    demos = []  # (obs, action) tuples

    for _ in tqdm(range(num_demos), desc="Collecting demos"):
        state = game.new_initial_state()

        while not state.is_terminal():
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = outcomes[0][0]
            else:
                player = state.current_player()
                legal = state.legal_actions()

                if player == Role.MAYOR and state._phase == Phase.PLACE:
                    # Smart Mayor strategy
                    verify_actions = [
                        a
                        for a in legal
                        if ACTION_CONTROL_REVEAL_BASE <= a < ACTION_COMMIT_BASE
                    ]
                    build_actions = [a for a in legal if a >= ACTION_BUILD_BASE]

                    # Find unverified nominations
                    unverified = []
                    for a in verify_actions:
                        nom_idx = a - ACTION_CONTROL_REVEAL_BASE
                        if nom_idx < len(state._nominations):
                            nom = state._nominations[nom_idx]
                            h = nom.get("hex")
                            if h and h not in state._mayor_verified_hexes:
                                unverified.append(a)

                    # Find safe builds (verified non-Spade)
                    safe_builds = []
                    for a in build_actions:
                        place_idx = a - ACTION_BUILD_BASE
                        nom_idx = place_idx % MAX_NOMINATIONS
                        if nom_idx < len(state._nominations):
                            nom = state._nominations[nom_idx]
                            h = nom.get("hex")
                            if h in state._mayor_verified_hexes:
                                reality = state._reality.get(h, {})
                                if reality.get("suit") != Suit.SPADES:
                                    safe_builds.append(a)

                    if unverified:
                        action = random.choice(unverified)
                    elif safe_builds:
                        action = random.choice(safe_builds)
                    else:
                        action = (
                            random.choice(build_actions)
                            if build_actions
                            else random.choice(legal)
                        )

                    # Record demonstration
                    obs = state.observation_tensor(Role.MAYOR)
                    demos.append((obs, action))
                else:
                    action = random.choice(legal)

            state.apply_action(action)

    print(f"Collected {len(demos)} demonstrations")

    # Convert to tensors
    obs_batch = torch.tensor(
        np.array([d[0] for d in demos]), dtype=torch.float32, device=device
    )
    action_batch = torch.tensor([d[1] for d in demos], dtype=torch.long, device=device)

    # Create dataset
    dataset = torch.utils.data.TensorDataset(obs_batch, action_batch)
    dataloader = torch.utils.data.DataLoader(
        dataset, batch_size=batch_size, shuffle=True
    )

    # Train
    optimizer = optim.Adam(mayor_net.parameters(), lr=learning_rate)
    criterion = nn.CrossEntropyLoss()

    mayor_net.train()
    for epoch in range(epochs):
        total_loss = 0
        correct = 0
        total = 0

        for obs, actions in dataloader:
            optimizer.zero_grad()
            logits, _ = mayor_net(obs)
            loss = criterion(logits, actions)
            loss.backward()
            optimizer.step()

            total_loss += loss.item()
            _, predicted = logits.max(1)
            correct += (predicted == actions).sum().item()
            total += actions.size(0)

        acc = correct / total * 100
        print(f"  Epoch {epoch+1}/{epochs}: loss={total_loss/len(dataloader):.4f}, acc={acc:.1f}%")

    mayor_net.eval()
    print("Behavioral cloning complete!\n")


# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: PPO Self-Play (Adversarial)
# ─────────────────────────────────────────────────────────────────────────────


def run_ppo_selfplay(
    num_episodes: int = 500000,
    population_size: int = 5,
    batch_size: int = 256,
    learning_rate: float = 3e-4,
    discount: float = 0.99,
    gae_lambda: float = 0.95,
    clip_ratio: float = 0.2,
    entropy_coef: float = 0.05,  # Increased from 0.01 to prevent mode collapse
    value_coef: float = 0.5,
    epochs_per_update: int = 4,
    rollout_length: int = 2048,
    save_every: int = 50000,
    checkpoint_dir: str = "checkpoints",
    seed: Optional[int] = None,
    device: str = "cuda" if TORCH_AVAILABLE and torch.cuda.is_available() else "cpu",
    use_checkpoint_pool: bool = True,  # NEW: Enable diverse agent pool
    pool_save_interval: int = 10000,  # Save to pool every N episodes
    pfsp_alpha: float = 2.0,  # PFSP prioritization exponent
) -> dict:
    """Train with PPO and population-based self-play.

    With use_checkpoint_pool=True, implements Prioritized Fictitious Self-Play (PFSP):
    - Saves checkpoints to a pool at regular intervals
    - Samples opponents from pool, prioritizing those that beat current agent
    - Creates diverse, robust agents
    """
    if not TORCH_AVAILABLE:
        print("Error: PyTorch required for PPO training")
        return {}

    print(
        f"\n=== Phase 5: PPO Self-Play ({num_episodes} episodes, population={population_size}) ===\n"
    )
    print(f"Device: {device}")
    if use_checkpoint_pool:
        print(f"Using checkpoint pool with PFSP sampling (alpha={pfsp_alpha})")

    from agents.learned_agent import (
        PolicyNetwork,
        ValueNetwork,
        ResNetPolicyValueNetwork,
    )

    rng = random.Random(seed)
    game = create_game()

    os.makedirs(checkpoint_dir, exist_ok=True)

    # Use ResNet policy-value architecture (inspired by AlphaZero, trained with PPO)
    # NOTE: This is NOT full AlphaZero - no MCTS, just the network architecture
    USE_RESNET_ARCH = True

    sample_state = game.new_initial_state()
    # Process chance nodes to get a proper game state for observation sizes
    while sample_state.is_chance_node():
        outcomes = sample_state.chance_outcomes()
        action = outcomes[0][0]  # Just pick first for sizing
        sample_state.apply_action(action)

    # Get role-specific observation sizes (Mayor vs Advisors have different obs sizes)
    obs_sizes = {
        Role.MAYOR: len(sample_state.observation_tensor(int(Role.MAYOR))),
        Role.INDUSTRY: len(sample_state.observation_tensor(int(Role.INDUSTRY))),
        Role.URBANIST: len(sample_state.observation_tensor(int(Role.URBANIST))),
    }
    num_actions = game.num_distinct_actions()

    print(
        f"Observation sizes: Mayor={obs_sizes[Role.MAYOR]}, Advisors={obs_sizes[Role.INDUSTRY]}, Action space: {num_actions}"
    )

    # Population of policies for each role (with role-specific observation sizes)
    if USE_RESNET_ARCH:
        # ResNet policy-value networks (shared trunk for policy and value)
        # All roles get equally powerful networks - Mayor must be strong
        # for advisors to learn meaningful counter-strategies
        hidden_dims = {
            Role.MAYOR: 512,  # Same capacity as advisors
            Role.INDUSTRY: 512,
            Role.URBANIST: 512,
        }
        num_blocks = {
            Role.MAYOR: 8,  # Same depth as advisors
            Role.INDUSTRY: 8,
            Role.URBANIST: 8,
        }
        populations = {
            role: [
                ResNetPolicyValueNetwork(
                    obs_sizes[role],
                    num_actions,
                    hidden_dim=hidden_dims[role],
                    num_blocks=num_blocks[role],
                ).to(device)
                for _ in range(population_size)
            ]
            for role in Role
        }
        # With ResNet arch, value comes from same network (shared trunk)
        value_nets = None  # Not needed - use populations[role][0].value_forward()

        # Single optimizer per network (policy+value are shared)
        policy_optimizers = {
            role: optim.Adam(populations[role][0].parameters(), lr=learning_rate)
            for role in Role
        }
        value_optimizers = None  # Not needed
        print("Using ResNet policy-value architecture (PPO training, no MCTS)")
    else:
        # Legacy separate policy/value networks
        populations = {
            role: [
                PolicyNetwork(obs_sizes[role], num_actions).to(device)
                for _ in range(population_size)
            ]
            for role in Role
        }
        value_nets = {role: ValueNetwork(obs_sizes[role]).to(device) for role in Role}

        # Optimizers for current policy (index 0 in population)
        policy_optimizers = {
            role: optim.Adam(populations[role][0].parameters(), lr=learning_rate)
            for role in Role
        }
        value_optimizers = {
            role: optim.Adam(value_nets[role].parameters(), lr=learning_rate)
            for role in Role
        }
        print("Using legacy MLP architecture")

    writer = SummaryWriter(log_dir=os.path.join(checkpoint_dir, "logs_ppo"))

    # Pre-train Mayor using behavioral cloning on smart strategy
    # This gives Mayor a head start - random exploration can't discover "verify first"
    pretrain_mayor_bc(
        populations[Role.MAYOR][0],
        num_demos=3000,  # 3000 games of demonstrations
        epochs=5,
        device=device,
    )

    # Initialize checkpoint pool for diverse training
    checkpoint_pool = None
    opponent_checkpoint_ids = {}  # Track which checkpoints we're playing against
    network_kwargs = {}  # Will be set based on architecture

    if use_checkpoint_pool:
        pool_dir = os.path.join(checkpoint_dir, "pool")
        checkpoint_pool = CheckpointPool(pool_dir, max_pool_size=50)
        print(f"Checkpoint pool initialized at {pool_dir}")

        # Network kwargs for loading checkpoints
        if USE_RESNET_ARCH:
            network_kwargs = {
                role: {
                    "obs_size": obs_sizes[role],
                    "num_actions": num_actions,
                    "hidden_dim": hidden_dims[role],
                    "num_blocks": num_blocks[role],
                }
                for role in Role
            }
            network_class = ResNetPolicyValueNetwork
        else:
            network_kwargs = {
                role: {
                    "obs_size": obs_sizes[role],
                    "num_actions": num_actions,
                }
                for role in Role
            }
            network_class = PolicyNetwork

    stats = defaultdict(list)
    rollout_data = {role: [] for role in Role}

    # Track action distribution for mode collapse detection
    action_counts = {role: defaultdict(int) for role in Role}
    action_log_interval = 10000  # Log action distribution every N episodes

    # Win rate tracking for model collapse detection
    WIN_RATE_WINDOW = 1000  # Track last 1000 games
    COLLAPSE_THRESHOLD = 0.05  # 5% Mayor SURVIVAL rate triggers warning
    COLLAPSE_PATIENCE = 50000  # Episodes before triggering early stop
    win_history = {"mayor": [], "industry": [], "urbanist": [], "tie": []}
    survival_history = []  # Track Mayor survival (the prerequisite for winning)
    collapse_counter = 0
    mine_hit_count = 0  # Track Mayor mine hits for logging

    # Track which role we're training this episode (rotate through roles)
    training_role_idx = 0
    roles_list = list(Role)

    for ep in tqdm(range(num_episodes), desc="PPO self-play"):
        state = game.new_initial_state()

        # Rotate training role each episode for balanced learning
        training_role = roles_list[training_role_idx % len(roles_list)]
        training_role_idx += 1

        # Select opponent policies
        opponent_policies = {}
        opponent_checkpoint_ids = {}

        for role in Role:
            if role == training_role:
                opponent_policies[role] = populations[role][0]  # Training policy
                opponent_checkpoint_ids[role] = "current"
            elif (
                use_checkpoint_pool
                and checkpoint_pool
                and len(checkpoint_pool.get_checkpoints(role)) > 0
            ):
                # Use PFSP to sample from checkpoint pool
                checkpoint_id, network = checkpoint_pool.sample_opponent_pfsp(
                    role, device, pfsp_alpha, network_class, network_kwargs[role]
                )
                if network is not None:
                    opponent_policies[role] = network
                    opponent_checkpoint_ids[role] = checkpoint_id
                else:
                    # Fallback to population
                    opponent_policies[role] = rng.choice(populations[role])
                    opponent_checkpoint_ids[role] = "population"
            else:
                # Fallback to population
                opponent_policies[role] = rng.choice(populations[role])
                opponent_checkpoint_ids[role] = "population"

        episode_data = {role: [] for role in Role}

        while not state.is_terminal():
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = rng.choices(
                    [a for a, _ in outcomes], weights=[p for _, p in outcomes]
                )[0]
                state.apply_action(action)
                continue

            player = state.current_player()
            role = Role(player)
            legal_actions = state.legal_actions(player)

            # Guard against empty legal actions (should not happen, but defensive)
            if not legal_actions:
                print(f"WARNING: Empty legal actions! Player={player}, State={state}")
                break

            obs = torch.tensor(
                state.observation_tensor(player), dtype=torch.float32, device=device
            )

            # Use the selected policy for this role (training or opponent)
            policy = opponent_policies[role]

            with torch.no_grad():
                legal_mask = torch.zeros(num_actions, device=device)
                for a in legal_actions:
                    legal_mask[a] = 1.0

                if USE_RESNET_ARCH:
                    # Combined forward pass for policy and value
                    logits, value = policy(obs.unsqueeze(0), legal_mask.unsqueeze(0))
                    logits = logits.squeeze(0)
                else:
                    logits = policy(obs.unsqueeze(0), legal_mask.unsqueeze(0)).squeeze(
                        0
                    )
                    value = value_nets[role](obs.unsqueeze(0)).squeeze()

                probs = torch.softmax(logits, dim=-1)

                # Sample action from policy
                dist = torch.distributions.Categorical(probs)
                action = dist.sample().item()
                log_prob = dist.log_prob(torch.tensor(action, device=device))

            if action not in legal_actions:
                action = legal_actions[0]

            # Track action for distribution analysis
            action_counts[role][action] += 1

            # Only collect experience for the training role
            if role == training_role:
                episode_data[role].append(
                    {
                        "obs": obs,
                        "action": action,
                        "log_prob": log_prob,
                        "value": value,
                        "legal_mask": legal_mask,
                        "intermediate_reward": 0.0,  # Will be filled after action
                    }
                )

            state.apply_action(action)

            # Capture intermediate rewards after action (dense reward shaping)
            if role == training_role and episode_data[role]:
                turn_rewards = state.turn_rewards()
                episode_data[role][-1]["intermediate_reward"] = turn_rewards[int(role)]

        # Compute rewards based on configured reward mode (only for training role)
        raw_returns = state.returns()
        hit_mine = state.mayor_hit_mine()

        # Use compute_rewards which respects CURRENT_REWARD_MODE setting
        # Pass mayor_hit_mine separately so RL penalty doesn't affect who "wins"
        adversarial_rewards = compute_rewards(raw_returns, mayor_hit_mine=hit_mine)

        # Track winner for win rate monitoring
        # KEY: If Mayor hit mine, Mayor CANNOT win - they lost
        if hit_mine:
            # Mayor lost - check if an advisor won (positive score)
            advisor_scores = [raw_returns[1], raw_returns[2]]
            max_advisor = max(advisor_scores)
            if max_advisor > 0:
                advisor_winners = [
                    i for i, s in enumerate(advisor_scores) if s == max_advisor
                ]
                if len(advisor_winners) > 1:
                    winner = "tie"  # Advisors tied
                else:
                    winner = ["industry", "urbanist"][advisor_winners[0]]
            else:
                winner = "tie"  # Everyone failed (Mayor died, advisors didn't score)
        else:
            # Mayor survived - normal 3-way competition
            max_score = max(raw_returns)
            winners = [i for i, s in enumerate(raw_returns) if s == max_score]
            if len(winners) > 1:
                winner = "tie"
            else:
                winner = ["mayor", "industry", "urbanist"][winners[0]]

        # Track mine hits and survival
        if hit_mine:
            mine_hit_count += 1
            survival_history.append(0)
        else:
            survival_history.append(1)
        if len(survival_history) > WIN_RATE_WINDOW:
            survival_history.pop(0)

        # Update rolling win history
        for role_key in win_history:
            win_history[role_key].append(1 if role_key == winner else 0)
            if len(win_history[role_key]) > WIN_RATE_WINDOW:
                win_history[role_key].pop(0)

        # Update PFSP win rates based on game outcome
        if use_checkpoint_pool and checkpoint_pool:
            training_score = raw_returns[int(training_role)]
            for role in Role:
                if role == training_role:
                    continue
                checkpoint_id = opponent_checkpoint_ids.get(role)
                if checkpoint_id and checkpoint_id not in ("current", "population"):
                    opponent_score = raw_returns[int(role)]
                    # Training role "wins" if it beats this opponent
                    won = training_score > opponent_score
                    checkpoint_pool.update_win_rate(role, checkpoint_id, won)

        role = training_role
        terminal_reward = adversarial_rewards[
            role
        ]  # Use adversarial reward, not raw score

        # Dense reward assignment: intermediate rewards + discounted terminal reward
        # Work backwards from terminal state
        num_steps = len(episode_data[role])
        for i, step_data in enumerate(episode_data[role]):
            # Intermediate reward from this step (dense shaping)
            intermediate = step_data.get("intermediate_reward", 0.0)

            # Discounted terminal reward
            steps_remaining = num_steps - i - 1
            discounted_terminal = terminal_reward * (discount**steps_remaining)

            # Total return: immediate reward + discounted future
            # Weight intermediate rewards strongly to encourage learning from them
            step_data["return"] = intermediate * 1.0 + discounted_terminal
            step_data["advantage"] = step_data["return"] - step_data["value"].item()
            rollout_data[role].append(step_data)

        # PPO update when rollout buffer is full
        if len(rollout_data[Role.MAYOR]) >= rollout_length:
            for role in Role:
                if len(rollout_data[role]) < batch_size:
                    continue

                # Prepare batch
                batch = rollout_data[role][:rollout_length]
                rollout_data[role] = rollout_data[role][rollout_length:]

                obs_batch = torch.stack([d["obs"] for d in batch])
                action_batch = torch.tensor([d["action"] for d in batch], device=device)
                old_log_probs = torch.stack([d["log_prob"] for d in batch])
                returns_batch = torch.tensor(
                    [d["return"] for d in batch], dtype=torch.float32, device=device
                )
                advantages_batch = torch.tensor(
                    [d["advantage"] for d in batch], dtype=torch.float32, device=device
                )
                legal_masks = torch.stack([d["legal_mask"] for d in batch])

                # Normalize advantages
                advantages_batch = (advantages_batch - advantages_batch.mean()) / (
                    advantages_batch.std() + 1e-8
                )

                for _ in range(epochs_per_update):
                    # Compute new log probs and values
                    if USE_RESNET_ARCH:
                        logits, new_values = populations[role][0](
                            obs_batch, legal_masks
                        )
                    else:
                        logits = populations[role][0](obs_batch, legal_masks)
                        new_values = value_nets[role](obs_batch)

                    probs = torch.softmax(logits, dim=-1)
                    dist = torch.distributions.Categorical(probs)
                    new_log_probs = dist.log_prob(action_batch)
                    entropy = dist.entropy().mean()

                    # PPO clipped objective
                    ratio = torch.exp(new_log_probs - old_log_probs.detach())
                    surr1 = ratio * advantages_batch
                    surr2 = (
                        torch.clamp(ratio, 1 - clip_ratio, 1 + clip_ratio)
                        * advantages_batch
                    )
                    policy_loss = -torch.min(surr1, surr2).mean()

                    # Value loss
                    value_loss = nn.functional.mse_loss(new_values, returns_batch)

                    # Combined loss
                    loss = (
                        policy_loss + value_coef * value_loss - entropy_coef * entropy
                    )

                    policy_optimizers[role].zero_grad()
                    if not USE_RESNET_ARCH:
                        value_optimizers[role].zero_grad()
                    loss.backward()
                    nn.utils.clip_grad_norm_(populations[role][0].parameters(), 0.5)
                    if not USE_RESNET_ARCH:
                        nn.utils.clip_grad_norm_(value_nets[role].parameters(), 0.5)
                    policy_optimizers[role].step()
                    if not USE_RESNET_ARCH:
                        value_optimizers[role].step()

                writer.add_scalar(f"ppo_loss/{role.name}", loss.item(), ep)
                writer.add_scalar(f"ppo_entropy/{role.name}", entropy.item(), ep)

        # Periodically add current policy to population
        if (ep + 1) % (num_episodes // (population_size * 2)) == 0:
            for role in Role:
                # Shift population and add current policy
                populations[role] = populations[role][1:] + [populations[role][0]]
                # Create new current policy (with role-specific observation size)
                if USE_RESNET_ARCH:
                    hidden_dims = {
                        Role.MAYOR: 512,
                        Role.INDUSTRY: 512,
                        Role.URBANIST: 512,
                    }
                    num_blocks_cfg = {Role.MAYOR: 8, Role.INDUSTRY: 8, Role.URBANIST: 8}
                    new_policy = ResNetPolicyValueNetwork(
                        obs_sizes[role],
                        num_actions,
                        hidden_dim=hidden_dims[role],
                        num_blocks=num_blocks_cfg[role],
                    ).to(device)
                else:
                    new_policy = PolicyNetwork(obs_sizes[role], num_actions).to(device)
                new_policy.load_state_dict(populations[role][-1].state_dict())
                populations[role][0] = new_policy
                policy_optimizers[role] = optim.Adam(
                    populations[role][0].parameters(), lr=learning_rate
                )

        # Logging
        if ep % 1000 == 0:
            for i, role in enumerate(Role):
                writer.add_scalar(f"raw_return/{role.name}", raw_returns[i], ep)
                writer.add_scalar(
                    f"adversarial_reward/{role.name}", adversarial_rewards[role], ep
                )

            # Win rate logging and collapse detection
            if len(win_history["mayor"]) >= 100:
                for role_key in ["mayor", "industry", "urbanist"]:
                    window_size = min(WIN_RATE_WINDOW, len(win_history[role_key]))
                    wr = sum(win_history[role_key][-window_size:]) / window_size
                    writer.add_scalar(f"win_rate/{role_key}", wr, ep)

                # Mine hit rate logging
                mine_rate = mine_hit_count / max(1, ep + 1)
                writer.add_scalar("mayor_survival/mine_hit_rate", mine_rate, ep)

                # Model collapse detection based on SURVIVAL rate (not win rate)
                # Mayor must survive to have any chance of winning
                if len(survival_history) >= WIN_RATE_WINDOW:
                    survival_rate = sum(survival_history) / WIN_RATE_WINDOW
                    writer.add_scalar("survival/mayor", survival_rate, ep)

                    if survival_rate < COLLAPSE_THRESHOLD:
                        collapse_counter += 1000
                        print(
                            f"\n[WARNING] Mayor survival={survival_rate:.1%} below {COLLAPSE_THRESHOLD:.0%} threshold, "
                            f"collapse_counter={collapse_counter}/{COLLAPSE_PATIENCE}"
                        )
                    else:
                        if collapse_counter > 0:
                            print(
                                f"\n[RECOVERY] Mayor survival={survival_rate:.1%} recovered above threshold"
                            )
                        collapse_counter = 0  # Reset on recovery

                    if collapse_counter >= COLLAPSE_PATIENCE:
                        print(
                            f"\n[EARLY STOP] Model collapse detected: Mayor survival={survival_rate:.1%} "
                            f"for {collapse_counter} consecutive episodes"
                        )
                        print("Saving final checkpoint before exit...")
                        # Save checkpoint before exiting
                        for role in Role:
                            path = os.path.join(
                                checkpoint_dir,
                                f"ppo_{role.name.lower()}_ep{ep + 1}_COLLAPSED.pt",
                            )
                            torch.save(
                                {
                                    "policy_net": populations[role][0].state_dict(),
                                    "episode": ep + 1,
                                    "mayor_wr": mayor_wr,
                                    "collapse_reason": "mayor_win_rate_below_threshold",
                                },
                                path,
                            )
                        print("Training terminated due to model collapse.")
                        writer.close()
                        return stats

        # Action distribution logging (mode collapse detection)
        if ep > 0 and ep % action_log_interval == 0:
            print(f"\n[ACTION DISTRIBUTION] Episode {ep}:")
            for role in Role:
                counts = action_counts[role]
                if not counts:
                    continue
                total = sum(counts.values())
                unique_actions = len(counts)
                # Calculate entropy of action distribution
                probs = [c / total for c in counts.values()]
                entropy = -sum(p * np.log(p + 1e-10) for p in probs)
                max_entropy = np.log(unique_actions + 1e-10)
                normalized_entropy = entropy / max_entropy if max_entropy > 0 else 0
                # Find top 5 most common actions
                top_actions = sorted(counts.items(), key=lambda x: -x[1])[:5]
                top_pct = sum(c for _, c in top_actions) / total * 100
                print(
                    f"  {role.name}: {unique_actions} unique actions, entropy={normalized_entropy:.3f}, top5={top_pct:.1f}%"
                )
                for action, count in top_actions:
                    pct = count / total * 100
                    # Decode action for advisors (commit actions)
                    if role != Role.MAYOR and action >= ACTION_COMMIT_BASE:
                        commit_idx = action - ACTION_COMMIT_BASE
                        hex_idx = commit_idx // NUM_CARDS
                        claim_idx = commit_idx % NUM_CARDS
                        claim_card = index_to_card(claim_idx)
                        claim_str = card_label(claim_card) if claim_card else "?"
                        print(
                            f"    Action {action} (hex={hex_idx}, claim={claim_str}): {pct:.1f}%"
                        )
                    else:
                        print(f"    Action {action}: {pct:.1f}%")
                writer.add_scalar(
                    f"action_diversity/unique_{role.name}", unique_actions, ep
                )
                writer.add_scalar(
                    f"action_diversity/entropy_{role.name}", normalized_entropy, ep
                )
                writer.add_scalar(f"action_diversity/top5_pct_{role.name}", top_pct, ep)
            # Reset counts for next interval
            action_counts = {role: defaultdict(int) for role in Role}

        # Save to checkpoint pool for diverse training (more frequently than main checkpoints)
        if (
            use_checkpoint_pool
            and checkpoint_pool
            and (ep + 1) % pool_save_interval == 0
        ):
            for role in Role:
                arch = "alphazero" if USE_RESNET_ARCH else "legacy"
                pool_path = checkpoint_pool.save_checkpoint(
                    role, populations[role][0], ep + 1, arch
                )
            pool_stats = checkpoint_pool.get_pool_stats()
            print(f"\n[POOL] Saved to pool at episode {ep + 1}")
            for role in Role:
                count = pool_stats[role.name]["count"]
                print(f"  {role.name}: {count} checkpoints in pool")

        # Checkpointing (main checkpoints)
        if (ep + 1) % save_every == 0:
            for role in Role:
                path = os.path.join(
                    checkpoint_dir, f"ppo_{role.name.lower()}_ep{ep+1}.pt"
                )
                if USE_RESNET_ARCH:
                    # ResNet arch: combined network has both policy and value
                    torch.save(
                        {
                            "policy_net": populations[role][0].state_dict(),
                            "architecture": "alphazero",
                            "episode": ep + 1,
                        },
                        path,
                    )
                else:
                    torch.save(
                        {
                            "policy_net": populations[role][0].state_dict(),
                            "value_net": value_nets[role].state_dict(),
                            "architecture": "legacy",
                            "episode": ep + 1,
                        },
                        path,
                    )
            print(f"  Saved checkpoints at episode {ep + 1}")

    writer.close()
    print("\n=== PPO Self-Play Complete ===")
    return dict(stats)


# ─────────────────────────────────────────────────────────────────────────────
# Main Entry Point
# ─────────────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Collapsization RL Training")
    parser.add_argument(
        "--phase",
        type=str,
        default="random",
        choices=["random", "scripted", "tabular", "dqn", "ppo"],
        help="Training phase to run",
    )
    parser.add_argument(
        "--episodes", type=int, default=1000, help="Number of episodes to run"
    )
    parser.add_argument("--seed", type=int, default=None, help="Random seed")
    parser.add_argument(
        "--save-every", type=int, default=10000, help="Save checkpoint every N episodes"
    )
    parser.add_argument(
        "--checkpoint-dir",
        type=str,
        default="checkpoints",
        help="Directory for checkpoints",
    )
    parser.add_argument(
        "--population", type=int, default=5, help="Population size for self-play"
    )
    parser.add_argument(
        "--device", type=str, default="auto", help="Device (cpu/cuda/auto)"
    )

    args = parser.parse_args()

    if args.device == "auto":
        args.device = "cuda" if TORCH_AVAILABLE and torch.cuda.is_available() else "cpu"

    print(f"Collapsization RL Training")
    print(f"Phase: {args.phase}")
    print(f"Episodes: {args.episodes}")
    print(f"Seed: {args.seed}")
    print()

    if args.phase == "random":
        run_random_baseline(args.episodes, args.seed)
    elif args.phase == "scripted":
        run_scripted_baseline(args.episodes, args.seed)
    elif args.phase == "tabular":
        run_tabular_q(args.episodes, seed=args.seed)
    elif args.phase == "dqn":
        run_dqn(
            args.episodes,
            save_every=args.save_every,
            checkpoint_dir=args.checkpoint_dir,
            seed=args.seed,
            device=args.device,
        )
    elif args.phase == "ppo":
        run_ppo_selfplay(
            args.episodes,
            population_size=args.population,
            save_every=args.save_every,
            checkpoint_dir=args.checkpoint_dir,
            seed=args.seed,
            device=args.device,
        )


if __name__ == "__main__":
    main()
