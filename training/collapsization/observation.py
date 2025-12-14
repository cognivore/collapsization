"""Player-specific observation encoding for Collapsization.

Observations are role-specific due to asymmetric information:
- Mayor: sees hand, revealed card, nominations (once revealed), but NOT reality tiles
- Advisors: see reality tiles on frontier, revealed card, but NOT mayor's full hand
"""

import numpy as np
from typing import Optional

from .constants import (
    Suit,
    Phase,
    Role,
    NUM_SUITS,
    NUM_RANKS,
    NUM_CARDS,
    NUM_PLAYERS,
    card_to_index,
    INVALID_HEX,
)


# Observation dimensions
PHASE_DIM = 5  # One-hot for phases (LOBBY, DRAW, NOMINATE, PLACE, GAME_OVER)
SCORE_DIM = NUM_PLAYERS  # 3 scores
CARD_DIM = NUM_CARDS + 1  # 39 cards + 1 null indicator = 40
HAND_SIZE = 4  # Mayor now draws 4 cards
REVEALED_CARDS = 2  # Mayor reveals 2 cards

# For a reasonable game, frontier rarely exceeds ~50 hexes
MAX_FRONTIER_SIZE = 50
MAX_BUILT_SIZE = 50

# Each advisor nominates 2 hexes
NOMINATIONS_PER_ADVISOR = 2
MAX_NOMINATIONS = NOMINATIONS_PER_ADVISOR * 2  # 4 total


class ObservationEncoder:
    """Encodes game state into player-specific observation tensors."""

    def __init__(self, max_frontier: int = MAX_FRONTIER_SIZE):
        self.max_frontier = max_frontier
        self._hex_to_idx: dict[tuple[int, int, int], int] = {}
        self._idx_to_hex: list[tuple[int, int, int]] = []

    def reset(self):
        """Reset hex indexing for a new game."""
        self._hex_to_idx.clear()
        self._idx_to_hex.clear()

    def get_hex_index(self, hex_coord: tuple[int, int, int]) -> int:
        """Get stable index for a hex coordinate, assigning new index if needed."""
        if hex_coord == INVALID_HEX:
            return -1
        if hex_coord not in self._hex_to_idx:
            idx = len(self._idx_to_hex)
            if idx >= self.max_frontier:
                return -1  # Overflow - shouldn't happen in normal games
            self._hex_to_idx[hex_coord] = idx
            self._idx_to_hex.append(hex_coord)
        return self._hex_to_idx[hex_coord]

    def hex_from_index(self, idx: int) -> Optional[tuple[int, int, int]]:
        """Convert index back to hex coordinate."""
        if 0 <= idx < len(self._idx_to_hex):
            return self._idx_to_hex[idx]
        return None

    @property
    def observation_size(self) -> int:
        """Total observation tensor size (common features only)."""
        return (
            PHASE_DIM  # Phase one-hot
            + 1  # Turn counter (normalized)
            + SCORE_DIM  # Scores
            + MAX_BUILT_SIZE  # Built hex mask
            + self.max_frontier  # Frontier hex mask
            + CARD_DIM * REVEALED_CARDS  # 2 revealed cards
        )

    @property
    def mayor_observation_size(self) -> int:
        """Mayor-specific observation size."""
        return (
            self.observation_size
            + HAND_SIZE * CARD_DIM  # Full hand (4 cards)
            + MAX_NOMINATIONS * (self.max_frontier + CARD_DIM)  # 4 nominations
        )

    @property
    def advisor_observation_size(self) -> int:
        """Advisor-specific observation size."""
        return (
            self.observation_size
            + self.max_frontier * CARD_DIM  # Reality tiles on frontier
            + NUM_CARDS  # Own tray remaining mask
            + MAX_NOMINATIONS * (self.max_frontier + CARD_DIM)  # 4 nominations
        )

    def encode_card(self, card: Optional[dict]) -> np.ndarray:
        """Encode a single card as one-hot vector (40 dims: 39 cards + null)."""
        vec = np.zeros(CARD_DIM, dtype=np.float32)
        if card is None or not card:
            vec[NUM_CARDS] = 1.0  # Null indicator
        else:
            idx = card_to_index(card)
            if idx >= 0:
                vec[idx] = 1.0
            else:
                vec[NUM_CARDS] = 1.0
        return vec

    def encode_phase(self, phase: Phase) -> np.ndarray:
        """Encode phase as one-hot vector."""
        vec = np.zeros(PHASE_DIM, dtype=np.float32)
        if 0 <= int(phase) < PHASE_DIM:
            vec[int(phase)] = 1.0
        return vec

    def encode_hex_mask(
        self, hexes: list[tuple[int, int, int]], size: int
    ) -> np.ndarray:
        """Encode a set of hexes as a binary mask."""
        mask = np.zeros(size, dtype=np.float32)
        for h in hexes:
            idx = self.get_hex_index(h)
            if 0 <= idx < size:
                mask[idx] = 1.0
        return mask

    def encode_common(
        self,
        phase: Phase,
        turn: int,
        scores: dict[str, int],
        built_hexes: list[tuple[int, int, int]],
        frontier_hexes: list[tuple[int, int, int]],
        revealed_cards: list[dict],
    ) -> np.ndarray:
        """Encode features common to all players."""
        parts = [
            self.encode_phase(phase),
            np.array([turn / 50.0], dtype=np.float32),  # Normalized turn
            np.array(
                [
                    scores.get("mayor", 0) / 20.0,
                    scores.get("industry", 0) / 20.0,
                    scores.get("urbanist", 0) / 20.0,
                ],
                dtype=np.float32,
            ),
            self.encode_hex_mask(built_hexes, MAX_BUILT_SIZE),
            self.encode_hex_mask(frontier_hexes, self.max_frontier),
        ]
        # Encode 2 revealed cards
        for i in range(REVEALED_CARDS):
            card = revealed_cards[i] if i < len(revealed_cards) else None
            parts.append(self.encode_card(card))
        return np.concatenate(parts)

    def encode_nominations(
        self,
        nominations: list[dict],
    ) -> np.ndarray:
        """Encode revealed nominations (up to 4 nominations, hex + claim each).

        Args:
            nominations: List of nomination dicts with "hex", "claim", "advisor" keys.
        """
        parts = []
        for i in range(MAX_NOMINATIONS):
            hex_mask = np.zeros(self.max_frontier, dtype=np.float32)
            claim_vec = self.encode_card(None)

            if i < len(nominations):
                nom = nominations[i]
                if nom and nom.get("hex") != INVALID_HEX:
                    hex_coord = nom.get("hex", INVALID_HEX)
                    if isinstance(hex_coord, (list, tuple)) and len(hex_coord) == 3:
                        hex_coord = tuple(hex_coord)
                        idx = self.get_hex_index(hex_coord)
                        if 0 <= idx < self.max_frontier:
                            hex_mask[idx] = 1.0
                    claim_vec = self.encode_card(nom.get("claim"))
            parts.extend([hex_mask, claim_vec])
        return np.concatenate(parts)

    def encode_mayor_observation(
        self,
        phase: Phase,
        turn: int,
        scores: dict[str, int],
        built_hexes: list[tuple[int, int, int]],
        frontier_hexes: list[tuple[int, int, int]],
        hand: list[dict],
        revealed_indices: list[int],
        nominations: list[dict],
    ) -> np.ndarray:
        """Encode full observation for Mayor player.

        Args:
            revealed_indices: List of revealed card indices (up to 2).
            nominations: List of nomination dicts (up to 4).
        """
        revealed_cards = [hand[idx] for idx in revealed_indices if 0 <= idx < len(hand)]
        common = self.encode_common(
            phase, turn, scores, built_hexes, frontier_hexes, revealed_cards
        )

        # Mayor's full hand (4 cards)
        hand_vec = np.concatenate(
            [
                self.encode_card(hand[i] if i < len(hand) else None)
                for i in range(HAND_SIZE)
            ]
        )

        # Nominations (only visible in PLACE phase) - up to 4
        nom_vec = self.encode_nominations(nominations if nominations else [])

        return np.concatenate([common, hand_vec, nom_vec])

    def encode_advisor_observation(
        self,
        role: Role,
        phase: Phase,
        turn: int,
        scores: dict[str, int],
        built_hexes: list[tuple[int, int, int]],
        frontier_hexes: list[tuple[int, int, int]],
        revealed_cards: list[dict],
        reality_tiles: dict[tuple[int, int, int], dict],
        tray_remaining: list[int],
        nominations: list[dict],
    ) -> np.ndarray:
        """Encode full observation for Advisor player (Industry or Urbanist).

        Args:
            revealed_cards: List of revealed cards (up to 2).
            nominations: List of nomination dicts (up to 4).
        """
        common = self.encode_common(
            phase, turn, scores, built_hexes, frontier_hexes, revealed_cards
        )

        # Reality tiles on frontier
        reality_vec = np.zeros(self.max_frontier * CARD_DIM, dtype=np.float32)
        for hex_coord, card in reality_tiles.items():
            idx = self.get_hex_index(hex_coord)
            if 0 <= idx < self.max_frontier:
                card_vec = self.encode_card(card)
                start = idx * CARD_DIM
                reality_vec[start : start + CARD_DIM] = card_vec

        # Own tray remaining (which claim cards are still available)
        tray_vec = np.zeros(NUM_CARDS, dtype=np.float32)
        for card_idx in tray_remaining:
            if 0 <= card_idx < NUM_CARDS:
                tray_vec[card_idx] = 1.0

        # Nominations (only visible in PLACE phase, or own commit in NOMINATE) - up to 4
        nom_vec = self.encode_nominations(nominations if nominations else [])

        return np.concatenate([common, reality_vec, tray_vec, nom_vec])
