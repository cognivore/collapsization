"""Player-specific observation encoding for Collapsization.

Observations are role-specific due to asymmetric information:
- Mayor: sees hand, revealed card, nominations (once revealed), but NOT reality tiles
- Advisors: see reality tiles on frontier, revealed card, but NOT mayor's full hand
"""

import numpy as np
from typing import Optional, Dict

from .constants import (
    Suit,
    Phase,
    Role,
    ControlMode,
    SuitConfig,
    NUM_SUITS,
    NUM_RANKS,
    NUM_CARDS,
    NUM_PLAYERS,
    card_to_index,
    INVALID_HEX,
)


# Observation dimensions
PHASE_DIM = 6  # One-hot for phases (LOBBY, DRAW, CONTROL, NOMINATE, PLACE, GAME_OVER)
CONTROL_MODE_DIM = 3  # NONE, FORCE_SUITS, FORCE_HEXES
SUIT_CONFIG_DIM = 2  # URB_DIAMOND_IND_HEART, URB_HEART_IND_DIAMOND
SCORE_DIM = NUM_PLAYERS  # 3 scores
CARD_DIM = NUM_CARDS + 1  # 39 cards + 1 null indicator = 40
HAND_SIZE = 4  # Mayor now draws 4 cards
REVEALED_CARDS = 2  # Mayor reveals 2 cards
FACILITY_DIM = 2  # Hearts and Diamonds facility progress (normalized 0-1)

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
            + FACILITY_DIM  # Hearts/Diamonds facility progress (Mayor's endgame)
            + MAX_BUILT_SIZE  # Built hex mask
            + self.max_frontier  # Frontier hex mask
            + CARD_DIM * REVEALED_CARDS  # 2 revealed cards
            + CONTROL_MODE_DIM  # Control mode one-hot
            + SUIT_CONFIG_DIM  # Suit config one-hot (or zeros if not FORCE_SUITS)
            + self.max_frontier * 2  # Forced hexes (one mask per advisor)
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

    def encode_control_mode(self, control_mode: ControlMode) -> np.ndarray:
        """Encode control mode as one-hot vector."""
        vec = np.zeros(CONTROL_MODE_DIM, dtype=np.float32)
        if 0 <= int(control_mode) < CONTROL_MODE_DIM:
            vec[int(control_mode)] = 1.0
        return vec

    def encode_suit_config(self, suit_config: Optional[SuitConfig]) -> np.ndarray:
        """Encode suit configuration as one-hot vector."""
        vec = np.zeros(SUIT_CONFIG_DIM, dtype=np.float32)
        if suit_config is not None and 0 <= int(suit_config) < SUIT_CONFIG_DIM:
            vec[int(suit_config)] = 1.0
        return vec

    def encode_common(
        self,
        phase: Phase,
        turn: int,
        scores: dict[str, int],
        built_hexes: list[tuple[int, int, int]],
        frontier_hexes: list[tuple[int, int, int]],
        revealed_cards: list[dict],
        control_mode: ControlMode = ControlMode.NONE,
        forced_suit_config: Optional[SuitConfig] = None,
        forced_hexes: Optional[dict[str, tuple[int, int, int]]] = None,
        facilities: Optional[dict[str, int]] = None,
    ) -> np.ndarray:
        """Encode features common to all players."""
        facilities = facilities or {"hearts": 1, "diamonds": 0}
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
            # Facility progress (Mayor's endgame condition: 10♥ + 10♦)
            np.array(
                [
                    facilities.get("hearts", 0) / 10.0,  # Normalized to 0-1
                    facilities.get("diamonds", 0) / 10.0,
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

        # Encode control state
        parts.append(self.encode_control_mode(control_mode))
        parts.append(self.encode_suit_config(forced_suit_config))

        # Encode forced hexes (one mask per advisor)
        forced_hexes = forced_hexes or {}
        urb_forced_hex = forced_hexes.get("urbanist")
        ind_forced_hex = forced_hexes.get("industry")
        parts.append(
            self.encode_hex_mask(
                [urb_forced_hex] if urb_forced_hex else [], self.max_frontier
            )
        )
        parts.append(
            self.encode_hex_mask(
                [ind_forced_hex] if ind_forced_hex else [], self.max_frontier
            )
        )

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
        control_mode: ControlMode = ControlMode.NONE,
        forced_suit_config: Optional[SuitConfig] = None,
        forced_hexes: Optional[dict[str, tuple[int, int, int]]] = None,
        facilities: Optional[dict[str, int]] = None,
    ) -> np.ndarray:
        """Encode full observation for Mayor player.

        Args:
            revealed_indices: List of revealed card indices (up to 2).
            nominations: List of nomination dicts (up to 4).
            control_mode: Current control mode.
            forced_suit_config: Suit configuration if FORCE_SUITS mode.
            forced_hexes: Dict of forced hexes per advisor if FORCE_HEXES mode.
            facilities: Dict of facility counts {"hearts": N, "diamonds": M}.
        """
        revealed_cards = [hand[idx] for idx in revealed_indices if 0 <= idx < len(hand)]
        common = self.encode_common(
            phase,
            turn,
            scores,
            built_hexes,
            frontier_hexes,
            revealed_cards,
            control_mode,
            forced_suit_config,
            forced_hexes,
            facilities,
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
        control_mode: ControlMode = ControlMode.NONE,
        forced_suit_config: Optional[SuitConfig] = None,
        forced_hexes: Optional[dict[str, tuple[int, int, int]]] = None,
        facilities: Optional[dict[str, int]] = None,
    ) -> np.ndarray:
        """Encode full observation for Advisor player (Industry or Urbanist).

        Args:
            revealed_cards: List of revealed cards (up to 2).
            nominations: List of nomination dicts (up to 4).
            control_mode: Current control mode.
            forced_suit_config: Suit configuration if FORCE_SUITS mode.
            forced_hexes: Dict of forced hexes per advisor if FORCE_HEXES mode.
            facilities: Dict of facility counts {"hearts": N, "diamonds": M}.
        """
        common = self.encode_common(
            phase,
            turn,
            scores,
            built_hexes,
            frontier_hexes,
            revealed_cards,
            control_mode,
            forced_suit_config,
            forced_hexes,
            facilities,
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
