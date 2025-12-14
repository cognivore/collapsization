"""Random agent for smoke testing the game implementation."""

import random
from typing import Optional

import pyspiel


class RandomAgent:
    """Uniformly random policy over legal actions."""

    def __init__(self, player_id: int, seed: Optional[int] = None):
        self.player_id = player_id
        self._rng = random.Random(seed)

    def step(self, state: pyspiel.State) -> int:
        """Select a random legal action."""
        legal_actions = state.legal_actions(self.player_id)
        if not legal_actions:
            raise ValueError(f"No legal actions for player {self.player_id}")
        return self._rng.choice(legal_actions)

    def reset(self):
        """Reset agent state (no-op for random agent)."""
        pass


def play_random_game(game: pyspiel.Game, seed: Optional[int] = None) -> list[float]:
    """Play a full game with random agents, returning final scores."""
    state = game.new_initial_state()
    rng = random.Random(seed)

    while not state.is_terminal():
        if state.is_chance_node():
            outcomes = state.chance_outcomes()
            action = rng.choices(
                [a for a, _ in outcomes], weights=[p for _, p in outcomes]
            )[0]
            state.apply_action(action)
        else:
            player = state.current_player()
            legal_actions = state.legal_actions(player)
            action = rng.choice(legal_actions)
            state.apply_action(action)

    return state.returns()
