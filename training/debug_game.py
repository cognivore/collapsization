#!/usr/bin/env python3
"""Debug script to trace through games and understand the dynamics."""

import sys
import random
from pathlib import Path
from collections import defaultdict

sys.path.insert(0, str(Path(__file__).parent))

from collapsization import CollapsizationGame, Role, Phase, Suit

try:
    import torch
    from agents.learned_agent import LearnedAgent

    TORCH_AVAILABLE = True
except ImportError:
    TORCH_AVAILABLE = False


def find_latest_checkpoint() -> Path:
    """Find the latest checkpoint directory."""
    results_dir = Path(__file__).parent / "results"
    dated_dirs = sorted(
        [d for d in results_dir.iterdir() if d.is_dir() and d.name.startswith("202")],
        reverse=True,
    )
    for date_dir in dated_dirs:
        checkpoint_dirs = sorted(
            [d for d in date_dir.iterdir() if d.is_dir() and d.name.isdigit()],
            key=lambda x: int(x.name),
            reverse=True,
        )
        for ckpt_dir in checkpoint_dirs:
            files = list(ckpt_dir.glob("ppo_*.pt"))
            roles_found = set()
            for f in files:
                for role in ["mayor", "industry", "urbanist"]:
                    if role in f.name.lower():
                        roles_found.add(role)
            if len(roles_found) == 3:
                return ckpt_dir
    return None


def suit_name(suit_val):
    names = {0: "♥Hearts", 1: "♦Diamonds", 2: "♠Spades", 3: "♣Clubs"}
    return names.get(suit_val, f"?{suit_val}")


def main():
    ckpt_dir = find_latest_checkpoint()
    print(f"Using checkpoint: {ckpt_dir}")

    game = CollapsizationGame({"max_turns": 50, "max_frontier": 50})
    rng = random.Random(42)

    # Load agents
    agents = {}
    for role_name in ["mayor", "industry", "urbanist"]:
        role = Role[role_name.upper()]
        files = list(ckpt_dir.glob(f"ppo_{role_name}_*.pt"))
        if files:
            sample_state = game.new_initial_state()
            obs_size = len(sample_state.observation_tensor(int(role)))
            num_actions = game.num_distinct_actions()
            agent = LearnedAgent(int(role), obs_size=obs_size, num_actions=num_actions)
            agent.load_checkpoint(str(files[0]))
            agents[role] = agent

    # Play multiple games and collect stats
    num_games = 20
    stats = defaultdict(int)
    game_details = []

    for game_idx in range(num_games):
        state = game.new_initial_state()

        while not state.is_terminal():
            player = state.current_player()

            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = rng.choices(
                    [a for a, _ in outcomes], weights=[p for _, p in outcomes]
                )[0]
            else:
                role = Role(player)
                legal_actions = state.legal_actions(player)
                if not legal_actions:
                    break
                agent = agents.get(role)
                action = agent.step(state) if agent else rng.choice(legal_actions)

            state.apply_action(action)

        # Analyze game end
        turn = state._turn
        stats[f"turn_{turn}"] += 1

        # Check if ended by mine
        ended_by_mine = False
        mine_claimer = None
        if state._turn_history:
            last = state._turn_history[-1]
            reality = last.get("reality", {})
            if reality.get("suit") == Suit.SPADES:
                ended_by_mine = True
                stats["mine_endings"] += 1
                # Who nominated this hex with spade claim vs non-spade?
                noms = last.get("nominations", [])
                for nom in noms:
                    if nom.get("hex") == last["build"]["hex"]:
                        claim_suit = nom.get("claim", {}).get("suit", -1)
                        advisor = nom.get("advisor", "?")
                        if claim_suit == Suit.SPADES:
                            mine_claimer = f"{advisor}(honest)"
                        else:
                            mine_claimer = f"{advisor}(lied)"

        returns = state.returns()
        winner = "tie"
        max_ret = max(returns)
        if returns.count(max_ret) == 1:
            winner = ["mayor", "industry", "urbanist"][returns.index(max_ret)]
        stats[f"winner_{winner}"] += 1

        game_details.append(
            {
                "turn": turn,
                "scores": state._scores.copy(),
                "returns": returns,
                "mine": ended_by_mine,
                "mine_claimer": mine_claimer,
                "winner": winner,
            }
        )

    # Print analysis
    print("\n" + "=" * 70)
    print(f" GAME ANALYSIS ({num_games} games)")
    print("=" * 70)

    print("\n📊 Turn Distribution:")
    for i in range(10):
        count = stats.get(f"turn_{i}", 0)
        if count > 0:
            bar = "█" * (count * 3)
            print(f"  Turn {i}: {count:3} {bar}")

    print(
        f"\n💣 Mine Endings: {stats['mine_endings']} ({stats['mine_endings']/num_games*100:.0f}%)"
    )

    print("\n🏆 Winners:")
    for role in ["mayor", "industry", "urbanist", "tie"]:
        count = stats.get(f"winner_{role}", 0)
        pct = count / num_games * 100
        bar = "█" * int(pct / 5)
        print(f"  {role.capitalize():12}: {count:3} ({pct:5.1f}%) {bar}")

    print("\n📋 Game Details:")
    print("-" * 70)
    for i, g in enumerate(game_details[:10]):
        mine_str = f" 💣{g['mine_claimer']}" if g["mine"] else ""
        print(
            f"  Game {i+1}: Turn {g['turn']}, Winner: {g['winner']}, Scores: {g['scores']}{mine_str}"
        )

    # Key insight
    print("\n" + "=" * 70)
    print(" KEY INSIGHT")
    print("=" * 70)
    mine_rate = stats["mine_endings"] / num_games
    if mine_rate > 0.5:
        print(f" ⚠️  {mine_rate*100:.0f}% of games end by MINE on turn 0-1!")
        print("    Advisors have learned to trick Mayor immediately.")
        print("    Mayor needs better bluff detection training.")
    elif stats.get("turn_0", 0) + stats.get("turn_1", 0) > num_games * 0.7:
        print("    Games are ending very early but not always by mine.")
        print("    Check if scoring is making early termination attractive.")


if __name__ == "__main__":
    main()
