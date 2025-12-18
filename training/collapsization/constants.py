"""Shared constants for Collapsization game - mirrors GDScript MapLayers and GameManager.

RULE EVOLUTION AND CONTROL PHASE
================================

This module defines constants for Collapsization, a 3-player asymmetric information game.
The rules have evolved significantly, with the major addition being the CONTROL PHASE.

MAJOR RULE CHANGES (v2.0):
--------------------------
1. CONTROL PHASE (NEW)
   - Added between DRAW and NOMINATE phases
   - Mayor chooses how to constrain Advisors: Force Suits OR Force Hexes
   - Creates strategic depth: Mayor can probe suspicious areas or force predictable claims
   - Implications for RL: +2,502 actions (55% of action space!)

2. MAYOR DRAWS 4 CARDS (was 3)
   - Mayor reveals 2 cards (was 1)
   - More information for Advisors to work with
   - Implications for RL: Larger observation space, more complex strategy

3. EACH ADVISOR NOMINATES 2 HEXES (was 1)
   - 4 total nominations per turn (was 2)
   - Mayor has more choices in BUILD phase
   - Implications for RL: More nomination combinations to learn

4. SIMPLIFIED SCORING
   - Mayor: +1 if placed card suit matches reality suit
   - Advisors: Bluff detection scoring (+1 trusted/honest, -2 mine lies)
   - Implications for RL: Cleaner reward signal, but adversarial rewards diverge

5. MINE DETECTION REWARDS
   - Advisor honestly warns about Spade: +1
   - Advisor lies about mine (claims non-Spade on Spade reality): -2
   - Implications for RL: Strong incentive for honest mine reporting

INFORMATION STRUCTURE (Imperfect Information Game):
---------------------------------------------------
- Mayor: Sees hand, frontier fog boundary. Does NOT see reality tiles.
- Advisors: See reality tiles on frontier. Do NOT see Mayor's full hand (only revealed).
- This asymmetry makes MCTS inappropriate; CFR-based methods preferred theoretically.

TRAINING IMPLICATIONS:
----------------------
- Large action space (~4,500) requires legal action masking
- Imperfect information means standard AlphaZero/MCTS won't work correctly
- Adversarial rewards may diverge from optimal Nash equilibrium play
- Scripted agents must handle all phases including Control Phase
"""

from enum import IntEnum
from typing import Final


class Suit(IntEnum):
    """Card suits - matches MapLayers.Suit in GDScript.

    Domain associations:
    - HEARTS: Urbanist's domain (community/people theme)
    - DIAMONDS: Industry's domain (resources theme)
    - SPADES: Mines - building on Spade reality ends the game
    """

    HEARTS = 0  # Urbanist's suit
    DIAMONDS = 1  # Industry's suit
    SPADES = 2  # Mines - game ending


class Phase(IntEnum):
    """Game phases - matches GameManager.Phase in GDScript.

    Turn structure (v2.0):
    1. DRAW: Mayor draws 4 cards, reveals 2 (one at a time)
    2. CONTROL (NEW): Mayor chooses Force Suits or Force Hexes
    3. NOMINATE: Each Advisor commits 2 nominations (4 total)
    4. PLACE: Mayor picks one card + one nominated hex

    The CONTROL phase is the major v2.0 addition, giving Mayor agency
    to shape Advisor behavior before nominations are made.
    """

    LOBBY = 0  # Pre-game state
    DRAW = 1  # Mayor draws 4 cards, reveals 2
    CONTROL = 2  # NEW: Mayor chooses how to constrain Advisors
    NOMINATE = 3  # Advisors commit nominations (hidden until all commit)
    PLACE = 4  # Mayor picks card + nominated hex, scoring occurs
    GAME_OVER = 5  # Spade placed or max turns reached


class ControlMode(IntEnum):
    """Mayor's control mode choice in the Control Phase.

    FORCE_SUITS:
        Mayor assigns suit constraints to each Advisor.
        At least one of their two nominations must use the assigned suit.
        Strategic use: Test Advisor honesty in a specific suit domain.

    FORCE_HEXES:
        Mayor picks one hex for each Advisor that they MUST include.
        Their second nomination is free choice.
        Strategic use: Probe specific areas of interest, limit manipulation.

    REVEAL_HEX:
        Mayor reveals ONE hex's true identity BEFORE nominations.
        This is the KEY DEDUCTION TOOL - gives Mayor verified information.
        Strategic use: Verify suspicious areas, catch liars, find safe paths.

    The choice creates a cat-and-mouse dynamic between Mayor and Advisors.
    REVEAL_HEX is the safest but gives away Mayor's interest in that hex.
    """

    NONE = 0  # No control yet selected (pre-Control phase)
    FORCE_SUITS = 1  # Mayor forces suit assignments (2 legal actions)
    FORCE_HEXES = 2  # Mayor forces hex assignments (up to 2,500 legal actions)
    REVEAL_HEX = 3  # Mayor reveals one hex's reality (up to 50 legal actions)


class SuitConfig(IntEnum):
    """Suit assignment configurations for FORCE_SUITS mode.

    When Mayor chooses FORCE_SUITS, they pick one of these configurations.
    Each Advisor must claim their assigned suit in at least one nomination.

    Note: This doesn't require reality to match - it's about the CLAIM.
    Advisors can still bluff about the hex's actual reality.
    """

    # Config A: Urbanist→Diamonds, Industry→Hearts
    # Use when: Mayor's hand is Diamonds-heavy (can match Industry's other claims)
    URB_DIAMOND_IND_HEART = 0

    # Config B: Urbanist→Hearts, Industry→Diamonds
    # Use when: Mayor's hand is Hearts-heavy (can trust Urbanist's Hearts claims)
    URB_HEART_IND_DIAMOND = 1


class Role(IntEnum):
    """Player roles - matches GameManager.Role in GDScript.

    Asymmetric information:
    - MAYOR: Sees hand and fog boundary, NOT reality tiles
    - INDUSTRY: Sees reality tiles, NOT Mayor's full hand (only revealed cards)
    - URBANIST: Sees reality tiles, NOT Mayor's full hand (only revealed cards)

    This asymmetry is why the game is IMPERFECT_INFORMATION and why
    standard MCTS/AlphaZero approaches are theoretically inappropriate.
    """

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
