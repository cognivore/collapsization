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


def create_game() -> CollapsizationGame:
    """Create a new Collapsization game instance."""
    return CollapsizationGame({"max_turns": 50, "max_frontier": 50})


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
# Adversarial Reward Computation
# ─────────────────────────────────────────────────────────────────────────────


def compute_adversarial_rewards(returns: list[float], win_bonus: float = 10.0) -> dict:
    """Compute adversarial rewards based on competitive standing.

    Instead of raw scores, rewards are:
    - Delta: own_score - next_closest_score (how much you beat the runner-up)
    - Win bonus: huge reward for being the sole winner

    This creates proper competitive tension where agents learn to beat opponents,
    not just maximize their own score.

    Args:
        returns: List of [mayor_score, industry_score, urbanist_score]
        win_bonus: Bonus for being sole winner (default 10.0)

    Returns:
        Dict mapping Role to adversarial reward
    """
    scores = {
        Role.MAYOR: returns[0],
        Role.INDUSTRY: returns[1],
        Role.URBANIST: returns[2],
    }

    rewards = {}
    max_score = max(scores.values())
    winners = [r for r, s in scores.items() if s == max_score]

    for role in Role:
        own_score = scores[role]
        other_scores = [s for r, s in scores.items() if r != role]
        next_closest = max(other_scores)  # Best opponent score

        # Delta reward: how much you beat the runner-up by
        delta = own_score - next_closest

        # Win bonus: huge reward for being sole winner
        # This is like "checkmate" vs "winning material" in chess
        bonus = win_bonus if (role in winners and len(winners) == 1) else 0.0

        rewards[role] = delta + bonus

    return rewards


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
    entropy_coef: float = 0.01,
    value_coef: float = 0.5,
    epochs_per_update: int = 4,
    rollout_length: int = 2048,
    save_every: int = 50000,
    checkpoint_dir: str = "checkpoints",
    seed: Optional[int] = None,
    device: str = "cuda" if TORCH_AVAILABLE and torch.cuda.is_available() else "cpu",
) -> dict:
    """Train with PPO and population-based self-play."""
    if not TORCH_AVAILABLE:
        print("Error: PyTorch required for PPO training")
        return {}

    print(
        f"\n=== Phase 5: PPO Self-Play ({num_episodes} episodes, population={population_size}) ===\n"
    )
    print(f"Device: {device}")

    from agents.learned_agent import PolicyNetwork, ValueNetwork

    rng = random.Random(seed)
    game = create_game()

    os.makedirs(checkpoint_dir, exist_ok=True)

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

    writer = SummaryWriter(log_dir=os.path.join(checkpoint_dir, "logs_ppo"))

    stats = defaultdict(list)
    rollout_data = {role: [] for role in Role}

    # Track which role we're training this episode (rotate through roles)
    training_role_idx = 0
    roles_list = list(Role)

    for ep in tqdm(range(num_episodes), desc="PPO self-play"):
        state = game.new_initial_state()

        # Rotate training role each episode for balanced learning
        training_role = roles_list[training_role_idx % len(roles_list)]
        training_role_idx += 1

        # Select opponent policies from population (actually use them!)
        # Training role uses populations[role][0], opponents use random from population
        opponent_policies = {}
        for role in Role:
            if role == training_role:
                opponent_policies[role] = populations[role][0]  # Training policy
            else:
                opponent_policies[role] = rng.choice(
                    populations[role]
                )  # Random opponent

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
                logits = policy(obs.unsqueeze(0), legal_mask.unsqueeze(0))
                probs = torch.softmax(logits, dim=-1).squeeze(0)

                # Sample action from policy
                dist = torch.distributions.Categorical(probs)
                action = dist.sample().item()
                log_prob = dist.log_prob(torch.tensor(action, device=device))
                value = value_nets[role](obs.unsqueeze(0)).squeeze()

            if action not in legal_actions:
                action = legal_actions[0]

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

        # Compute adversarial returns and advantages (only for training role)
        raw_returns = state.returns()
        adversarial_rewards = compute_adversarial_rewards(raw_returns)

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
            # Weight intermediate rewards to encourage learning from them
            step_data["return"] = intermediate * 0.5 + discounted_terminal
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
                    logits = populations[role][0](obs_batch, legal_masks)
                    probs = torch.softmax(logits, dim=-1)
                    dist = torch.distributions.Categorical(probs)
                    new_log_probs = dist.log_prob(action_batch)
                    entropy = dist.entropy().mean()
                    new_values = value_nets[role](obs_batch)

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
                    value_optimizers[role].zero_grad()
                    loss.backward()
                    nn.utils.clip_grad_norm_(populations[role][0].parameters(), 0.5)
                    nn.utils.clip_grad_norm_(value_nets[role].parameters(), 0.5)
                    policy_optimizers[role].step()
                    value_optimizers[role].step()

                writer.add_scalar(f"ppo_loss/{role.name}", loss.item(), ep)
                writer.add_scalar(f"ppo_entropy/{role.name}", entropy.item(), ep)

        # Periodically add current policy to population
        if (ep + 1) % (num_episodes // (population_size * 2)) == 0:
            for role in Role:
                # Shift population and add current policy
                populations[role] = populations[role][1:] + [populations[role][0]]
                # Create new current policy (with role-specific observation size)
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

        # Checkpointing
        if (ep + 1) % save_every == 0:
            for role in Role:
                path = os.path.join(
                    checkpoint_dir, f"ppo_{role.name.lower()}_ep{ep+1}.pt"
                )
                torch.save(
                    {
                        "policy_net": populations[role][0].state_dict(),
                        "value_net": value_nets[role].state_dict(),
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
