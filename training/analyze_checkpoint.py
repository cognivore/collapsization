#!/usr/bin/env python3
"""Checkpoint Analysis Script for Collapsization.

Analyzes win rates and performance of RL agents from a checkpoint directory.

Usage:
    # Analyze latest checkpoint
    python analyze_checkpoint.py

    # Analyze specific checkpoint
    python analyze_checkpoint.py --checkpoint /path/to/checkpoint/dir

    # More games for statistical significance
    python analyze_checkpoint.py --games 500

    # Compare against baselines
    python analyze_checkpoint.py --vs-baselines
"""

import argparse
import os
import sys
import random
from pathlib import Path
from collections import defaultdict
from typing import Optional, Dict, Any, Tuple
from datetime import datetime

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


def find_latest_checkpoint() -> Optional[Path]:
    """Find the latest checkpoint directory with all 3 model files."""
    results_dir = Path(__file__).parent / "results"
    if not results_dir.exists():
        return None

    # Find dated directories
    dated_dirs = sorted(
        [d for d in results_dir.iterdir() if d.is_dir() and d.name.startswith("202")],
        reverse=True,
    )

    for date_dir in dated_dirs:
        # Find checkpoint directories (numbered)
        checkpoint_dirs = sorted(
            [d for d in date_dir.iterdir() if d.is_dir() and d.name.isdigit()],
            key=lambda x: int(x.name),
            reverse=True,
        )

        for ckpt_dir in checkpoint_dirs:
            # Check if all 3 model files exist
            files = list(ckpt_dir.glob("ppo_*.pt"))
            roles_found = set()
            for f in files:
                for role in ["mayor", "industry", "urbanist"]:
                    if role in f.name.lower():
                        roles_found.add(role)
            if len(roles_found) == 3:
                return ckpt_dir

    return None


def get_checkpoint_info(checkpoint_dir: Path) -> Dict[str, Any]:
    """Extract checkpoint information."""
    info = {
        "path": str(checkpoint_dir),
        "name": checkpoint_dir.name,
        "date": (
            checkpoint_dir.parent.name
            if checkpoint_dir.parent.name.startswith("202")
            else "unknown"
        ),
        "episodes": 0,
        "files": {},
    }

    for role in ["mayor", "industry", "urbanist"]:
        files = list(checkpoint_dir.glob(f"ppo_{role}_*.pt"))
        if files:
            info["files"][role] = str(files[0])
            # Extract episode count from filename
            name = files[0].stem
            ep_part = name.split("_ep")[-1]
            if ep_part.isdigit():
                info["episodes"] = max(info["episodes"], int(ep_part))

    return info


def create_game() -> CollapsizationGame:
    """Create a new Collapsization game instance."""
    return CollapsizationGame({"max_turns": 50, "max_frontier": 50})


def create_learned_agent(role: Role, checkpoint_path: str, device: str = "cpu") -> Any:
    """Create a learned agent from checkpoint."""
    if not TORCH_AVAILABLE:
        raise ImportError("PyTorch required")

    import torch
    from agents.learned_agent import AlphaZeroNetwork

    game = create_game()
    sample_state = game.new_initial_state()
    obs_size = len(sample_state.observation_tensor(int(role)))
    num_actions = game.num_distinct_actions()

    # Load checkpoint to detect architecture
    checkpoint = torch.load(checkpoint_path, map_location=device)
    arch = checkpoint.get("architecture", "legacy")

    if arch == "alphazero":
        # AlphaZero architecture
        hidden_dim = 512
        num_blocks = 8
        policy_net = AlphaZeroNetwork(obs_size, num_actions, hidden_dim=hidden_dim, num_blocks=num_blocks)
        policy_net.load_state_dict(checkpoint["policy_net"])
        policy_net.to(device)
        policy_net.eval()

        # Create a wrapper that mimics LearnedAgent interface
        class AlphaZeroAgent:
            def __init__(self, net, role, dev):
                self.policy_net = net
                self.role = role
                self.device = dev

            def step(self, state):
                obs = torch.tensor(state.observation_tensor(self.role), dtype=torch.float32, device=self.device).unsqueeze(0)
                with torch.no_grad():
                    logits, value = self.policy_net(obs)
                    probs = torch.softmax(logits, dim=-1)

                legal_actions = state.legal_actions(self.role)
                if not legal_actions:
                    return None

                # Mask illegal actions
                legal_probs = probs[0, legal_actions].cpu().numpy()
                legal_probs = legal_probs / legal_probs.sum()
                action = legal_actions[int(legal_probs.argmax())]
                return action

        return AlphaZeroAgent(policy_net, int(role), device)
    else:
        # Legacy architecture
        agent = LearnedAgent(
            int(role),
            obs_size=obs_size,
            num_actions=num_actions,
            device=device,
        )
        agent.load_checkpoint(checkpoint_path)
        return agent


def create_scripted_agent(role: Role, seed: Optional[int] = None) -> Any:
    """Create a scripted baseline agent."""
    if role == Role.MAYOR:
        return ScriptedMayorAgent(int(role), seed=seed)
    else:
        return ScriptedAdvisorAgent(int(role), seed=seed)


def create_random_agent(role: Role, seed: Optional[int] = None) -> Any:
    """Create a random baseline agent."""
    return RandomAgent(int(role), seed=seed)


def run_games(
    agents: Dict[Role, Any],
    num_games: int = 100,
    seed: Optional[int] = None,
    verbose: bool = True,
    desc: str = "Playing",
) -> Dict[str, Any]:
    """Run games and collect statistics."""
    rng = random.Random(seed)
    game = create_game()

    stats = {
        "wins": {"mayor": 0, "industry": 0, "urbanist": 0, "tie": 0},
        "scores": {"mayor": [], "industry": [], "urbanist": []},
        "turns": [],
        "mine_endings": 0,
        "spade_builds": 0,
    }

    iterator = tqdm(range(num_games), desc=desc, disable=not verbose)
    for _ in iterator:
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

        # Check for mine ending - game ends early with low turn count
        # (Mine = spade reality causes immediate termination)
        if state._turn < 3 and state.is_terminal():
            # Check last build for spade reality
            if state._turn_history:
                last_turn = state._turn_history[-1]
                reality = last_turn.get("reality", {})
                if reality.get("suit") == 2:  # Suit.SPADES
                    stats["mine_endings"] += 1

        # Determine winner
        max_score = max(returns)
        winners = [i for i, s in enumerate(returns) if s == max_score]
        if len(winners) > 1:
            stats["wins"]["tie"] += 1
        else:
            role_names = ["mayor", "industry", "urbanist"]
            stats["wins"][role_names[winners[0]]] += 1

    # Compute summary
    stats["summary"] = {
        "num_games": num_games,
        "avg_turns": np.mean(stats["turns"]),
        "std_turns": np.std(stats["turns"]),
        "mine_rate": stats["mine_endings"] / num_games,
    }
    for role in ["mayor", "industry", "urbanist"]:
        scores = stats["scores"][role]
        stats["summary"][f"{role}_avg"] = np.mean(scores)
        stats["summary"][f"{role}_std"] = np.std(scores)
        stats["summary"][f"{role}_win_rate"] = stats["wins"][role] / num_games

    # Advisor combined win rate (advisors work together)
    advisor_wins = stats["wins"]["industry"] + stats["wins"]["urbanist"]
    stats["summary"]["advisor_win_rate"] = advisor_wins / num_games

    return stats


def print_matchup_results(stats: Dict[str, Any], title: str):
    """Pretty print results for a matchup."""
    s = stats["summary"]

    print(f"\n┌{'─' * 58}┐")
    print(f"│ {title:<56} │")
    print(f"├{'─' * 58}┤")
    print(
        f"│ Games: {s['num_games']:<6}  Avg Turns: {s['avg_turns']:.1f} ± {s['std_turns']:.1f}  Mine Rate: {s['mine_rate']:.0%}  │"
    )
    print(f"├{'─' * 58}┤")
    print(f"│ {'Role':<12} {'Avg Score':>10} {'Std':>8} {'Win Rate':>12} {'Wins':>8} │")
    print(f"├{'─' * 58}┤")

    for role in ["mayor", "industry", "urbanist"]:
        avg = s[f"{role}_avg"]
        std = s[f"{role}_std"]
        win_rate = s[f"{role}_win_rate"]
        wins = stats["wins"][role]
        bar = "█" * int(win_rate * 20)
        print(
            f"│ {role.capitalize():<12} {avg:>10.2f} {std:>8.2f} {win_rate:>11.1%} {wins:>8} │"
        )

    print(f"├{'─' * 58}┤")
    print(
        f"│ Ties: {stats['wins']['tie']:<6}  Advisor Combined: {s['advisor_win_rate']:.1%}                   │"
    )
    print(f"└{'─' * 58}┘")


def print_comparison_table(results: Dict[str, Dict[str, Any]]):
    """Print a comparison table across different matchups."""
    print(f"\n{'=' * 70}")
    print(" WIN RATE COMPARISON")
    print(f"{'=' * 70}")
    print(
        f"{'Matchup':<25} {'Mayor':>10} {'Industry':>10} {'Urbanist':>10} {'Advisor':>10}"
    )
    print("-" * 70)

    for name, stats in results.items():
        s = stats["summary"]
        print(
            f"{name:<25} "
            f"{s['mayor_win_rate']:>10.1%} "
            f"{s['industry_win_rate']:>10.1%} "
            f"{s['urbanist_win_rate']:>10.1%} "
            f"{s['advisor_win_rate']:>10.1%}"
        )
    print()


def analyze_checkpoint(
    checkpoint_dir: Path,
    num_games: int = 100,
    seed: Optional[int] = None,
    device: str = "cpu",
    vs_baselines: bool = False,
) -> Dict[str, Any]:
    """Run full analysis on a checkpoint."""
    info = get_checkpoint_info(checkpoint_dir)

    print("\n" + "=" * 60)
    print(" COLLAPSIZATION CHECKPOINT ANALYSIS")
    print("=" * 60)
    print(f" Checkpoint: {info['name']}")
    print(f" Date: {info['date']}")
    print(f" Episodes: {info['episodes']:,}")
    print(f" Progress: {info['episodes'] / 500000 * 100:.1f}% of 500k target")
    print("=" * 60)

    results = {}

    # Load learned agents
    print("\nLoading models...")
    learned_agents = {}
    for role_name, path in info["files"].items():
        role = Role[role_name.upper()]
        print(f"  Loading {role_name}: {Path(path).name}")
        learned_agents[role] = create_learned_agent(role, path, device)

    # 1. All Learned Agents (the main metric)
    print("\n" + "-" * 60)
    print(" LEARNED vs LEARNED (Self-Play)")
    print("-" * 60)
    stats = run_games(learned_agents, num_games, seed, desc="RL Self-Play")
    results["RL Self-Play"] = stats
    print_matchup_results(stats, "All RL Agents")

    if vs_baselines:
        # 2. RL vs Scripted Advisors (Mayor RL only)
        print("\n" + "-" * 60)
        print(" RL MAYOR vs SCRIPTED ADVISORS")
        print("-" * 60)
        agents = {
            Role.MAYOR: learned_agents[Role.MAYOR],
            Role.INDUSTRY: create_scripted_agent(Role.INDUSTRY, seed),
            Role.URBANIST: create_scripted_agent(Role.URBANIST, seed),
        }
        stats = run_games(agents, num_games, seed, desc="Mayor RL vs Scripted")
        results["Mayor RL vs Scripted"] = stats
        print_matchup_results(stats, "RL Mayor vs Scripted Advisors")

        # 3. Scripted Mayor vs RL Advisors
        print("\n" + "-" * 60)
        print(" SCRIPTED MAYOR vs RL ADVISORS")
        print("-" * 60)
        agents = {
            Role.MAYOR: create_scripted_agent(Role.MAYOR, seed),
            Role.INDUSTRY: learned_agents[Role.INDUSTRY],
            Role.URBANIST: learned_agents[Role.URBANIST],
        }
        stats = run_games(agents, num_games, seed, desc="Scripted vs Advisors RL")
        results["Scripted vs Advisors RL"] = stats
        print_matchup_results(stats, "Scripted Mayor vs RL Advisors")

        # 4. All Scripted (baseline)
        print("\n" + "-" * 60)
        print(" ALL SCRIPTED (Baseline)")
        print("-" * 60)
        agents = {r: create_scripted_agent(r, seed) for r in Role}
        stats = run_games(agents, num_games, seed, desc="All Scripted")
        results["All Scripted"] = stats
        print_matchup_results(stats, "All Scripted Agents")

        # 5. All Random (sanity check)
        print("\n" + "-" * 60)
        print(" ALL RANDOM (Sanity Check)")
        print("-" * 60)
        agents = {r: create_random_agent(r, seed) for r in Role}
        stats = run_games(agents, num_games, seed, desc="All Random")
        results["All Random"] = stats
        print_matchup_results(stats, "All Random Agents")

        # Print comparison
        print_comparison_table(results)

    # Summary interpretation
    print("\n" + "=" * 60)
    print(" INTERPRETATION")
    print("=" * 60)

    s = results["RL Self-Play"]["summary"]
    mayor_wr = s["mayor_win_rate"]
    advisor_wr = s["advisor_win_rate"]

    if mayor_wr > 0.55:
        print(f" ⚠️  Mayor is dominating ({mayor_wr:.0%}) - Advisors need more training")
    elif mayor_wr < 0.35:
        print(
            f" ⚠️  Advisors are dominating ({advisor_wr:.0%}) - Mayor needs more training"
        )
    else:
        print(
            f" ✓  Balanced gameplay (Mayor: {mayor_wr:.0%}, Advisors: {advisor_wr:.0%})"
        )

    mine_rate = s["mine_rate"]
    if mine_rate < 0.05:
        print(
            f" ⚠️  Very few mine endings ({mine_rate:.0%}) - Advisors may not be bluffing enough"
        )
    elif mine_rate > 0.30:
        print(f" ⚠️  Many mine endings ({mine_rate:.0%}) - Mayor may be too trusting")
    else:
        print(f" ✓  Healthy mine rate ({mine_rate:.0%})")

    print()
    return results


def main():
    parser = argparse.ArgumentParser(
        description="Analyze Collapsization RL checkpoint performance",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python analyze_checkpoint.py                    # Analyze latest checkpoint
  python analyze_checkpoint.py --games 500        # More games for accuracy
  python analyze_checkpoint.py --vs-baselines     # Compare against baselines
  python analyze_checkpoint.py --checkpoint /path/to/checkpoint/dir
        """,
    )
    parser.add_argument(
        "--checkpoint",
        "-c",
        type=str,
        default=None,
        help="Path to checkpoint directory (default: auto-find latest)",
    )
    parser.add_argument(
        "--games",
        "-n",
        type=int,
        default=100,
        help="Number of games to play (default: 100)",
    )
    parser.add_argument(
        "--seed",
        "-s",
        type=int,
        default=42,
        help="Random seed for reproducibility (default: 42)",
    )
    parser.add_argument(
        "--device",
        "-d",
        type=str,
        default="cpu",
        help="Device for neural networks (default: cpu)",
    )
    parser.add_argument(
        "--vs-baselines",
        "-b",
        action="store_true",
        help="Also compare against scripted and random baselines",
    )

    args = parser.parse_args()

    # Find checkpoint
    if args.checkpoint:
        checkpoint_dir = Path(args.checkpoint)
        if not checkpoint_dir.exists():
            print(f"Error: Checkpoint directory not found: {args.checkpoint}")
            sys.exit(1)
    else:
        checkpoint_dir = find_latest_checkpoint()
        if not checkpoint_dir:
            print("Error: No checkpoint found. Train some models first!")
            sys.exit(1)

    # Run analysis
    analyze_checkpoint(
        checkpoint_dir,
        num_games=args.games,
        seed=args.seed,
        device=args.device,
        vs_baselines=args.vs_baselines,
    )


if __name__ == "__main__":
    main()
