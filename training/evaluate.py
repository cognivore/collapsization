#!/usr/bin/env python3
"""Evaluation script for Collapsization RL bots.

Features:
- Compare agents against baselines
- Head-to-head matchups
- Win rate statistics
- Strategy analysis

Usage:
    python evaluate.py --checkpoint=checkpoints/dqn_mayor_ep10000.pt --baseline=scripted
    python evaluate.py --matchup mayor:dqn industry:scripted urbanist:random
"""

import argparse
import os
import sys
import random
from pathlib import Path
from collections import defaultdict
from typing import Optional, Dict, Any

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

from collapsization import CollapsizationGame, Role
from agents import RandomAgent, ScriptedAdvisorAgent, ScriptedMayorAgent

try:
    import torch
    from agents.learned_agent import LearnedAgent, PolicyNetwork

    TORCH_AVAILABLE = True
except ImportError:
    TORCH_AVAILABLE = False

from tqdm import tqdm


def create_game() -> CollapsizationGame:
    """Create a new Collapsization game instance."""
    return CollapsizationGame({"max_turns": 50, "max_frontier": 50})


def create_agent(
    role: Role,
    agent_type: str,
    checkpoint_path: Optional[str] = None,
    seed: Optional[int] = None,
    device: str = "cpu",
) -> Any:
    """Create an agent based on type specification."""
    if agent_type == "random":
        return RandomAgent(int(role), seed=seed)
    elif agent_type == "scripted":
        if role == Role.MAYOR:
            return ScriptedMayorAgent(int(role), seed=seed)
        else:
            return ScriptedAdvisorAgent(int(role), seed=seed)
    elif agent_type in ("dqn", "ppo", "learned"):
        if not TORCH_AVAILABLE:
            raise ImportError("PyTorch required for learned agents")
        if not checkpoint_path:
            raise ValueError(f"Checkpoint path required for {agent_type} agent")

        game = create_game()
        sample_state = game.new_initial_state()
        obs_size = len(sample_state.observation_tensor(0))
        num_actions = game.num_distinct_actions()

        agent = LearnedAgent(
            int(role),
            obs_size=obs_size,
            num_actions=num_actions,
            device=device,
        )
        agent.load_checkpoint(checkpoint_path)
        return agent
    else:
        raise ValueError(f"Unknown agent type: {agent_type}")


def run_evaluation(
    agents: Dict[Role, Any],
    num_games: int = 100,
    seed: Optional[int] = None,
    verbose: bool = False,
) -> Dict[str, Any]:
    """Run evaluation games between agents.

    Returns detailed statistics about the matchup.
    """
    rng = random.Random(seed)
    game = create_game()

    stats = {
        "wins": {"mayor": 0, "industry": 0, "urbanist": 0, "tie": 0},
        "scores": {"mayor": [], "industry": [], "urbanist": []},
        "turns": [],
        "mine_endings": 0,
    }

    for game_idx in tqdm(range(num_games), desc="Evaluating", disable=not verbose):
        state = game.new_initial_state()

        while not state.is_terminal():
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = rng.choices(
                    [a for a, _ in outcomes], weights=[p for _, p in outcomes]
                )[0]
            else:
                player = state.current_player()
                role = Role(player)
                agent = agents.get(role)
                if agent:
                    action = agent.step(state)
                else:
                    action = rng.choice(state.legal_actions(player))

            state.apply_action(action)

        returns = state.returns()

        # Record scores
        stats["scores"]["mayor"].append(returns[0])
        stats["scores"]["industry"].append(returns[1])
        stats["scores"]["urbanist"].append(returns[2])
        stats["turns"].append(state._turn)

        # Check for mine ending (typically negative mayor score pattern)
        if returns[0] < 0:
            stats["mine_endings"] += 1

        # Determine winner
        max_score = max(returns)
        winners = [i for i, s in enumerate(returns) if s == max_score]
        if len(winners) > 1:
            stats["wins"]["tie"] += 1
        else:
            role_names = ["mayor", "industry", "urbanist"]
            stats["wins"][role_names[winners[0]]] += 1

    # Compute summary statistics
    stats["summary"] = {
        "num_games": num_games,
        "avg_turns": np.mean(stats["turns"]),
        "mine_rate": stats["mine_endings"] / num_games,
    }
    for role in ["mayor", "industry", "urbanist"]:
        scores = stats["scores"][role]
        stats["summary"][f"{role}_avg"] = np.mean(scores)
        stats["summary"][f"{role}_std"] = np.std(scores)
        stats["summary"][f"{role}_win_rate"] = stats["wins"][role] / num_games

    return stats


def print_evaluation_results(stats: Dict[str, Any], title: str = "Evaluation Results"):
    """Pretty print evaluation results."""
    print(f"\n{'=' * 60}")
    print(f" {title}")
    print(f"{'=' * 60}")

    summary = stats["summary"]
    print(f"\nGames played: {summary['num_games']}")
    print(f"Average turns: {summary['avg_turns']:.1f}")
    print(f"Mine endings: {summary['mine_rate']:.1%}")

    print(f"\n{'Role':<12} {'Avg Score':<12} {'Std':<10} {'Win Rate':<10}")
    print("-" * 44)
    for role in ["mayor", "industry", "urbanist"]:
        avg = summary[f"{role}_avg"]
        std = summary[f"{role}_std"]
        win_rate = summary[f"{role}_win_rate"]
        print(f"{role.capitalize():<12} {avg:<12.2f} {std:<10.2f} {win_rate:<10.1%}")

    print()


def compare_against_baselines(
    checkpoint_path: str,
    role: Role,
    num_games: int = 100,
    seed: Optional[int] = None,
    device: str = "cpu",
):
    """Compare a learned agent against random and scripted baselines."""
    print(f"\nComparing {role.name} checkpoint against baselines...")

    learned_agent = create_agent(role, "learned", checkpoint_path, device=device)

    results = {}

    # vs Random opponents
    print("\n--- vs Random Opponents ---")
    agents = {r: create_agent(r, "random", seed=seed) for r in Role}
    agents[role] = learned_agent
    stats = run_evaluation(agents, num_games, seed)
    results["vs_random"] = stats
    print_evaluation_results(stats, f"{role.name} (Learned) vs Random")

    # vs Scripted opponents
    print("\n--- vs Scripted Opponents ---")
    agents = {r: create_agent(r, "scripted", seed=seed) for r in Role}
    agents[role] = learned_agent
    stats = run_evaluation(agents, num_games, seed)
    results["vs_scripted"] = stats
    print_evaluation_results(stats, f"{role.name} (Learned) vs Scripted")

    return results


def main():
    parser = argparse.ArgumentParser(description="Collapsization Agent Evaluation")
    parser.add_argument(
        "--checkpoint", type=str, default=None, help="Path to checkpoint file"
    )
    parser.add_argument(
        "--role",
        type=str,
        default="mayor",
        choices=["mayor", "industry", "urbanist"],
        help="Role of the checkpoint agent",
    )
    parser.add_argument(
        "--baseline",
        type=str,
        default="all",
        choices=["random", "scripted", "all"],
        help="Baseline to compare against",
    )
    parser.add_argument(
        "--games", type=int, default=100, help="Number of games to play"
    )
    parser.add_argument("--seed", type=int, default=None, help="Random seed")
    parser.add_argument(
        "--device", type=str, default="cpu", help="Device for neural networks"
    )
    parser.add_argument(
        "--matchup",
        nargs=3,
        metavar=("MAYOR", "INDUSTRY", "URBANIST"),
        help="Specify agent types as role:type (e.g., mayor:dqn)",
    )

    args = parser.parse_args()

    if args.matchup:
        # Custom matchup mode
        agents = {}
        for i, spec in enumerate(args.matchup):
            role = [Role.MAYOR, Role.INDUSTRY, Role.URBANIST][i]
            if ":" in spec:
                agent_type, checkpoint = spec.split(":", 1)
            else:
                agent_type, checkpoint = spec, None
            agents[role] = create_agent(
                role, agent_type, checkpoint, args.seed, args.device
            )

        stats = run_evaluation(agents, args.games, args.seed, verbose=True)
        print_evaluation_results(stats, "Custom Matchup")
    elif args.checkpoint:
        # Compare checkpoint against baselines
        role = Role[args.role.upper()]
        compare_against_baselines(
            args.checkpoint,
            role,
            args.games,
            args.seed,
            args.device,
        )
    else:
        # Default: compare scripted vs random
        print("Running baseline comparison: Scripted vs Random")

        print("\n--- All Scripted ---")
        agents = {r: create_agent(r, "scripted", seed=args.seed) for r in Role}
        stats = run_evaluation(agents, args.games, args.seed, verbose=True)
        print_evaluation_results(stats, "All Scripted Agents")

        print("\n--- All Random ---")
        agents = {r: create_agent(r, "random", seed=args.seed) for r in Role}
        stats = run_evaluation(agents, args.games, args.seed, verbose=True)
        print_evaluation_results(stats, "All Random Agents")


if __name__ == "__main__":
    main()
