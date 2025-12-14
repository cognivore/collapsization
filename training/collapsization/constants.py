"""Shared constants for Collapsization game - mirrors GDScript MapLayers and GameManager."""

from enum import IntEnum
from typing import Final


class Suit(IntEnum):
    """Card suits - matches MapLayers.Suit in GDScript."""

    HEARTS = 0  # Urbanist's suit
    DIAMONDS = 1  # Industry's suit
    SPADES = 2  # Mines - game ending


class Phase(IntEnum):
    """Game phases - matches GameManager.Phase in GDScript."""

    LOBBY = 0
    DRAW = 1  # Mayor has 3 cards, must reveal 1
    NOMINATE = 2  # Advisors commit nominations (hidden until both commit)
    PLACE = 3  # Mayor picks card + nominated hex
    GAME_OVER = 4  # Spade placed or error


class Role(IntEnum):
    """Player roles - matches GameManager.Role in GDScript."""

    MAYOR = 0
    INDUSTRY = 1
    URBANIST = 2


# Card ranks in order (Queen outranks King per RULES.md)
RANKS: Final[tuple[str, ...]] = (
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
    "10",
    "J",
    "K",
    "Q",
    "A",
)

# Rank to numeric value mapping
RANK_VALUES: Final[dict[str, int]] = {
    "2": 2,
    "3": 3,
    "4": 4,
    "5": 5,
    "6": 6,
    "7": 7,
    "8": 8,
    "9": 9,
    "10": 10,
    "J": 11,
    "K": 12,
    "Q": 13,
    "A": 14,  # Q > K per rules
}

NUM_SUITS: Final[int] = 3
NUM_RANKS: Final[int] = 13
NUM_CARDS: Final[int] = NUM_SUITS * NUM_RANKS  # 39 cards in deck

NUM_PLAYERS: Final[int] = 3

# Special sentinel for invalid hex coordinates
INVALID_HEX: Final[tuple[int, int, int]] = (0x7FFFFFFF, 0, 0)

# Cube direction vectors for hex neighbors
HEX_DIRECTIONS: Final[tuple[tuple[int, int, int], ...]] = (
    (1, -1, 0),
    (1, 0, -1),
    (0, 1, -1),
    (-1, 1, 0),
    (-1, 0, 1),
    (0, -1, 1),
)


def make_card(suit: Suit, rank: str) -> dict:
    """Create a card dictionary matching GDScript MapLayers.make_card."""
    return {
        "suit": int(suit),
        "rank": rank,
        "value": RANK_VALUES[rank],
    }


def card_label(card: dict) -> str:
    """Human-readable card label matching GDScript MapLayers.label."""
    if not card:
        return ""
    suit_symbols = {Suit.HEARTS: "♥", Suit.DIAMONDS: "♦", Suit.SPADES: "♠"}
    return f"{card['rank']}{suit_symbols.get(card['suit'], '?')}"


def card_to_index(card: dict) -> int:
    """Convert card to flat index (0-38). Returns -1 for empty/invalid card."""
    if not card or "suit" not in card or "rank" not in card:
        return -1
    suit = card["suit"]
    rank = card["rank"]
    if rank not in RANK_VALUES:
        return -1
    rank_idx = RANKS.index(rank)
    return suit * NUM_RANKS + rank_idx


def index_to_card(idx: int) -> dict:
    """Convert flat index (0-38) back to card dictionary."""
    if idx < 0 or idx >= NUM_CARDS:
        return {}
    suit = Suit(idx // NUM_RANKS)
    rank = RANKS[idx % NUM_RANKS]
    return make_card(suit, rank)


def get_adjacent_hexes(cube: tuple[int, int, int]) -> list[tuple[int, int, int]]:
    """Get all 6 adjacent hexes around a center cube coordinate."""
    return [(cube[0] + d[0], cube[1] + d[1], cube[2] + d[2]) for d in HEX_DIRECTIONS]


def cube_distance(a: tuple[int, int, int], b: tuple[int, int, int]) -> int:
    """Calculate cube distance between two hexes."""
    return (abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])) // 2
