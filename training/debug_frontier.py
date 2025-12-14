#!/usr/bin/env python3
"""Check spade density in typical game states."""

import sys
import random
from pathlib import Path
from collections import defaultdict

sys.path.insert(0, str(Path(__file__).parent))

from collapsization import CollapsizationGame, Role, Phase, Suit


def main():
    game = CollapsizationGame({"max_turns": 50, "max_frontier": 50})
    rng = random.Random(42)

    samples = 100
    spade_counts = []
    frontier_sizes = []

    for _ in range(samples):
        state = game.new_initial_state()

        # Draw cards to get to nominate phase
        while state._pending_draws > 0:
            outcomes = state.chance_outcomes()
            action = rng.choices(
                [a for a, _ in outcomes], weights=[p for _, p in outcomes]
            )[0]
            state.apply_action(action)

        # Reveal 2 cards
        for i in range(2):
            legal = state.legal_actions()
            if legal:
                state.apply_action(legal[0])

        # Now check frontier
        frontier = state._get_playable_frontier()
        reality = state._reality

        spade_count = 0
        for hex_coord in frontier:
            if reality.get(hex_coord, {}).get("suit") == Suit.SPADES:
                spade_count += 1

        spade_counts.append(spade_count)
        frontier_sizes.append(len(frontier))

    print(f"\n{'=' * 60}")
    print(" FRONTIER ANALYSIS")
    print(f"{'=' * 60}")
    print(f" Samples: {samples}")
    print(f" Avg frontier size: {sum(frontier_sizes)/len(frontier_sizes):.1f}")
    print(f" Avg spades in frontier: {sum(spade_counts)/len(spade_counts):.1f}")
    print(f" Min spades: {min(spade_counts)}")
    print(f" Max spades: {max(spade_counts)}")

    # Distribution
    print(f"\n Spade Count Distribution:")
    dist = defaultdict(int)
    for c in spade_counts:
        dist[c] += 1
    for count in sorted(dist.keys()):
        pct = dist[count] / samples * 100
        bar = "█" * int(pct / 2)
        print(f"   {count} spades: {dist[count]:3} ({pct:5.1f}%) {bar}")

    # Probability of having at least 1 spade
    has_spade = sum(1 for c in spade_counts if c > 0)
    print(
        f"\n Games with ≥1 spade in frontier: {has_spade}/{samples} ({has_spade/samples*100:.0f}%)"
    )

    # How many suits are represented?
    print(f"\n Suit distribution in reality tiles:")
    suit_counts = defaultdict(int)
    total_tiles = 0

    for _ in range(10):  # Smaller sample for this
        state = game.new_initial_state()
        while state._pending_draws > 0:
            outcomes = state.chance_outcomes()
            action = rng.choices(
                [a for a, _ in outcomes], weights=[p for _, p in outcomes]
            )[0]
            state.apply_action(action)

        for hex_coord, card in state._reality.items():
            suit = card.get("suit", -1)
            suit_counts[suit] += 1
            total_tiles += 1

    suit_names = {0: "Hearts", 1: "Diamonds", 2: "Spades", 3: "Clubs"}
    for suit in [0, 1, 2, 3]:
        count = suit_counts.get(suit, 0)
        pct = count / total_tiles * 100 if total_tiles > 0 else 0
        print(f"   {suit_names.get(suit, '?'):10}: {count:3} ({pct:5.1f}%)")


if __name__ == "__main__":
    main()
