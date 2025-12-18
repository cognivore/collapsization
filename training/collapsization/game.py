"""OpenSpiel game implementation for Collapsization.

This implements the 3-player asymmetric information game where:
- Mayor: draws cards, reveals one, places on nominated hexes
- Industry/Urbanist (Advisors): see reality tiles, nominate hexes with claims

The simultaneous advisor nominations are modeled as sequential hidden commitments.
"""

import numpy as np
import pyspiel
from typing import Optional
import random

from .constants import (
    Suit,
    Phase,
    Role,
    ControlMode,
    SuitConfig,
    RANKS,
    RANK_VALUES,
    NUM_SUITS,
    NUM_RANKS,
    NUM_CARDS,
    NUM_PLAYERS,
    INVALID_HEX,
    make_card,
    card_label,
    card_to_index,
    index_to_card,
    get_adjacent_hexes,
    cube_distance,
)
from .observation import ObservationEncoder, MAX_FRONTIER_SIZE


# Game type registration
_GAME_TYPE = pyspiel.GameType(
    short_name="collapsization",
    long_name="Collapsization",
    dynamics=pyspiel.GameType.Dynamics.SEQUENTIAL,
    chance_mode=pyspiel.GameType.ChanceMode.EXPLICIT_STOCHASTIC,
    information=pyspiel.GameType.Information.IMPERFECT_INFORMATION,
    utility=pyspiel.GameType.Utility.GENERAL_SUM,
    reward_model=pyspiel.GameType.RewardModel.TERMINAL,
    max_num_players=NUM_PLAYERS,
    min_num_players=NUM_PLAYERS,
    provides_information_state_string=True,
    provides_information_state_tensor=True,
    provides_observation_string=True,
    provides_observation_tensor=True,
)

# Game parameters
_DEFAULT_PARAMS = {
    "max_frontier": MAX_FRONTIER_SIZE,
    "max_initial_spades": -1,  # -1 = no limit (random), 0+ = limit spades in initial frontier
}

# Mayor's endgame condition: Build 10 Hearts + 10 Diamonds facilities
# When Mayor completes the city, the game ends and scores are compared.
# This is NOT a win condition - Mayor still needs highest score to win.
# Facilities are counted by REALITY tile suit (not placed card suit)
#
# Game termination conditions:
# 1. Mayor hits a mine (Spade reality) → Game ends
# 2. Mayor completes city (10♥ + 10♦) → Game ends
# 3. Max turns reached → Game ends
# Winner = highest score at termination
FACILITIES_TO_COMPLETE = 10  # Need 10 of each suit (Hearts and Diamonds)

# ─────────────────────────────────────────────────────────────────────────────
# ACTION SPACE DOCUMENTATION
# ─────────────────────────────────────────────────────────────────────────────
#
# TOTAL ACTION SPACE: ~4,500 actions (vs typical board games with ~100-500)
#
# This is a LARGE action space that creates challenges for RL training:
# - Sparse reward signal (most actions never explored)
# - Legal action masking is CRITICAL for tractable learning
# - Policy networks must generalize across similar action semantics
#
# ACTION SPACE BREAKDOWN:
# ┌─────────────────────┬─────────┬─────────────────────────────────────────┐
# │ Phase               │ Count   │ Description                             │
# ├─────────────────────┼─────────┼─────────────────────────────────────────┤
# │ REVEAL (Mayor)      │ 4       │ Which of 4 hand cards to reveal         │
# │ CONTROL (Mayor)     │ 2,502   │ 2 suit configs + 50×50 hex pairs        │
# │ COMMIT (Advisors)   │ 1,950   │ 50 hexes × 39 claim cards               │
# │ BUILD (Mayor)       │ 16      │ 4 hand cards × 4 nominations            │
# │ CHANCE              │ 39      │ Card draws (handled by OpenSpiel)       │
# ├─────────────────────┼─────────┼─────────────────────────────────────────┤
# │ TOTAL               │ ~4,511  │                                         │
# └─────────────────────┴─────────┴─────────────────────────────────────────┘
#
# THE CONTROL PHASE EXPLOSION:
# The Control Phase alone adds 2,502 actions (55% of total!):
# - 2 suit configurations (Force Suits)
# - 2,500 hex pairs (Force Hexes: urb_hex × ind_hex = 50 × 50)
#
# MITIGATION STRATEGIES:
# 1. Legal action masking: Only ~10-20 actions legal at any decision point
# 2. Action semantics: Network can learn hex/suit patterns that generalize
# 3. Curriculum learning: Start with smaller frontiers, increase gradually
# 4. Future: Hierarchical action decomposition (choose mode, then parameters)
#
# ─────────────────────────────────────────────────────────────────────────────

# Action space definitions
# - Mayor reveal: 0-3 (which of 4 cards to reveal, done twice)
# - Mayor control: suit config (0-1) OR hex pair (2 + urb_hex * MAX_FRONTIER + ind_hex)
# - Advisor commit: frontier_hex_idx * NUM_CARDS + claim_card_idx
#   Each advisor commits 2 nominations sequentially (4 sub-phases total)
# - Mayor build: hand_card_idx * MAX_NOMINATIONS + nominated_hex_idx (0-3)
# - Chance actions: 0 to NUM_CARDS-1 for deck draws

MAX_FRONTIER_ACTIONS = MAX_FRONTIER_SIZE * NUM_CARDS
NOMINATIONS_PER_ADVISOR = 2  # Each advisor nominates 2 hexes
MAX_NOMINATIONS = NOMINATIONS_PER_ADVISOR * 2  # 4 total (2 per advisor)

ACTION_REVEAL_BASE = 0
ACTION_REVEAL_COUNT = 4  # Mayor draws 4 cards, reveals 2 (one at a time)

# Control phase actions (NEW - accounts for 55% of action space!)
ACTION_CONTROL_BASE = ACTION_REVEAL_COUNT
ACTION_CONTROL_SUIT_A = ACTION_CONTROL_BASE + 0  # Urb→Diamond, Ind→Heart
ACTION_CONTROL_SUIT_B = ACTION_CONTROL_BASE + 1  # Urb→Heart, Ind→Diamond
ACTION_CONTROL_HEX_BASE = ACTION_CONTROL_BASE + 2  # + urb_hex * MAX_FRONTIER + ind_hex
ACTION_CONTROL_HEX_COUNT = MAX_FRONTIER_SIZE * MAX_FRONTIER_SIZE  # 50×50 = 2,500
# REVEAL_HEX: Mayor reveals one hex's true identity (KEY DEDUCTION TOOL)
ACTION_CONTROL_REVEAL_BASE = ACTION_CONTROL_BASE + 2 + ACTION_CONTROL_HEX_COUNT
ACTION_CONTROL_REVEAL_COUNT = MAX_FRONTIER_SIZE  # Up to 50 hexes to reveal
ACTION_CONTROL_COUNT = (
    2 + ACTION_CONTROL_HEX_COUNT + ACTION_CONTROL_REVEAL_COUNT
)  # 2 suit configs + hex pairs + reveals = 2,552

ACTION_COMMIT_BASE = ACTION_CONTROL_BASE + ACTION_CONTROL_COUNT
ACTION_COMMIT_COUNT = MAX_FRONTIER_ACTIONS  # 50 hexes × 39 cards = 1,950
ACTION_BUILD_BASE = ACTION_COMMIT_BASE + ACTION_COMMIT_COUNT
ACTION_BUILD_COUNT = 4 * MAX_NOMINATIONS  # 4 hand cards × 4 nominations = 16
ACTION_CHANCE_BASE = ACTION_BUILD_BASE + ACTION_BUILD_COUNT
ACTION_CHANCE_COUNT = NUM_CARDS  # 39 cards

TOTAL_ACTIONS = ACTION_CHANCE_BASE + ACTION_CHANCE_COUNT  # ~4,511

# Action space summary for logging/debugging
ACTION_SPACE_SUMMARY = f"""
ACTION SPACE: {TOTAL_ACTIONS} total actions
  REVEAL:  {ACTION_REVEAL_COUNT:>5} ({ACTION_REVEAL_COUNT/TOTAL_ACTIONS*100:>5.1f}%)
  CONTROL: {ACTION_CONTROL_COUNT:>5} ({ACTION_CONTROL_COUNT/TOTAL_ACTIONS*100:>5.1f}%)  <- Control Phase explosion!
  COMMIT:  {ACTION_COMMIT_COUNT:>5} ({ACTION_COMMIT_COUNT/TOTAL_ACTIONS*100:>5.1f}%)
  BUILD:   {ACTION_BUILD_COUNT:>5} ({ACTION_BUILD_COUNT/TOTAL_ACTIONS*100:>5.1f}%)
  CHANCE:  {ACTION_CHANCE_COUNT:>5} ({ACTION_CHANCE_COUNT/TOTAL_ACTIONS*100:>5.1f}%)
"""


class CollapsizationGame(pyspiel.Game):
    """Collapsization game for OpenSpiel."""

    def __init__(self, params: Optional[dict] = None):
        params = params or {}
        self.max_frontier = params.get("max_frontier", _DEFAULT_PARAMS["max_frontier"])
        self.max_initial_spades = params.get(
            "max_initial_spades", _DEFAULT_PARAMS["max_initial_spades"]
        )

        # Game ends via: mine hit (Mayor loses) or city completion (10♥ + 10♦)
        # No turn limit - but set max_game_length for OpenSpiel (upper bound estimate)
        # Minimum 19 builds needed (9♥ + 10♦), but could take longer
        game_info = pyspiel.GameInfo(
            num_distinct_actions=TOTAL_ACTIONS,
            max_chance_outcomes=NUM_CARDS,
            num_players=NUM_PLAYERS,
            min_utility=-100.0,  # Mayor can get -100 if they hit a mine
            max_utility=50.0,
            utility_sum=None,  # General sum game
            max_game_length=500,  # Upper bound for OpenSpiel (no actual limit)
        )
        super().__init__(_GAME_TYPE, game_info, params or {})

    def new_initial_state(self) -> "CollapsizationState":
        return CollapsizationState(self)

    def make_py_observer(self, iig_obs_type=None, params=None):
        return CollapsizationObserver(self, iig_obs_type, params)


class CollapsizationState(pyspiel.State):
    """Game state for Collapsization."""

    def __init__(self, game: CollapsizationGame):
        super().__init__(game)
        self._game = game
        self._encoder = ObservationEncoder(game.max_frontier)

        # Phase and turn tracking
        self._phase = Phase.DRAW
        self._turn = 0
        self._is_terminal = False

        # Scores
        self._scores = {"mayor": 0, "industry": 0, "urbanist": 0}

        # Per-turn reward signals for dense reward shaping
        # These are relative improvements: own_delta - (avg_others_delta)
        self._turn_rewards = {"mayor": 0.0, "industry": 0.0, "urbanist": 0.0}

        # Mayor state
        self._hand: list[dict] = []
        self._revealed_indices: list[int] = []  # Mayor reveals 2 cards

        # Deck management
        self._deck: list[dict] = []
        self._discard: list[dict] = []
        self._build_deck()

        # Map state
        self._town_center = (0, 0, 0)
        self._built_hexes: list[tuple[int, int, int]] = [self._town_center]
        self._reality: dict[tuple[int, int, int], dict] = {
            self._town_center: make_card(Suit.HEARTS, "A")  # Center is A♥
        }

        # Advisor state - each advisor commits 2 nominations
        self._advisor_commits: dict[str, list[dict]] = {"industry": [], "urbanist": []}
        self._nominations: list[dict] = []  # Flat list of all nominations for Mayor
        self._advisor_trays: dict[str, list[int]] = {
            "industry": list(range(NUM_CARDS)),
            "urbanist": list(range(NUM_CARDS)),
        }

        # Revealed hexes (fog cleared - tile exists)
        self._revealed_hexes: set[tuple[int, int, int]] = set()
        # Mayor verified hexes (Mayor has used REVEAL_HEX to see the reality)
        self._mayor_verified_hexes: set[tuple[int, int, int]] = set()
        self._reveal_initial_frontier()

        # Track which draws are pending (for chance nodes)
        # Start with 4 pending draws - Mayor needs 4 cards before revealing
        self._pending_draws = 4
        # Sub-phases for sequential nominations:
        # "drawing", "reveal_1", "reveal_2", "control", "industry_commit_1", "industry_commit_2",
        # "urbanist_commit_1", "urbanist_commit_2", "ready"
        self._sub_phase = "ready"

        # NEW: Control phase state
        self._control_mode = ControlMode.NONE
        # For FORCE_SUITS: which config was chosen
        self._forced_suit_config: Optional[SuitConfig] = None
        # For FORCE_HEXES: {role_key: hex_coord}
        self._forced_hexes: dict[str, tuple[int, int, int]] = {}
        # For REVEAL_HEX: which hex was revealed this turn
        self._control_revealed_hex: Optional[tuple[int, int, int]] = None

        # Turn history for deduction (full game history)
        # Each entry: {turn, revealed_indices, control_mode, nominations, build, reality, scores_delta}
        self._turn_history: list[dict] = []

        # Mayor's endgame: Track facilities built by reality suit
        # Town center starts as A♥, so hearts starts at 1
        self._facilities = {"hearts": 1, "diamonds": 0}
        self._city_complete = False  # True when Mayor reaches 10♥ + 10♦ (game ends)
        self._mayor_hit_mine = False  # True when Mayor builds on Spade (Mayor loses)

    def _build_deck(self):
        """Build and shuffle the 39-card deck."""
        self._deck = []
        for suit in Suit:
            for rank in RANKS:
                self._deck.append(make_card(suit, rank))
        random.shuffle(self._deck)

    def _draw_card(self) -> dict:
        """Draw a card from deck, reshuffling discard if needed."""
        if not self._deck:
            self._deck = self._discard.copy()
            self._discard = []
            random.shuffle(self._deck)
        return self._deck.pop() if self._deck else make_card(Suit.HEARTS, "7")

    def _reveal_initial_frontier(self):
        """Reveal the initial frontier around town center with controlled mine density.

        If max_initial_spades is set (>= 0), ensures the initial 6 frontier tiles
        have at most that many Spades. This helps training by reducing early game
        deaths from random mine placement.
        """
        self._revealed_hexes.add(self._town_center)
        adjacent = get_adjacent_hexes(self._town_center)

        max_spades = self._game.max_initial_spades
        if max_spades < 0:
            # No limit - use random cards
            for adj in adjacent:
                self._revealed_hexes.add(adj)
                if adj not in self._reality:
                    self._reality[adj] = self._draw_card()
        else:
            # Controlled mine density: draw cards until we have valid set
            spade_count = 0
            for adj in adjacent:
                self._revealed_hexes.add(adj)
                if adj not in self._reality:
                    # Keep drawing until we get a non-Spade or we haven't hit limit
                    card = self._draw_card()
                    attempts = 0
                    while card["suit"] == Suit.SPADES and spade_count >= max_spades:
                        # Put it back and try again (up to 10 attempts to avoid infinite loop)
                        self._deck.insert(0, card)
                        random.shuffle(self._deck)
                        card = self._draw_card()
                        attempts += 1
                        if attempts > 10:
                            break  # Give up and accept the Spade
                    if card["suit"] == Suit.SPADES:
                        spade_count += 1
                    self._reality[adj] = card

    def _reveal_around(self, hex_coord: tuple[int, int, int]):
        """Reveal fog around a hex (the hex and its 6 neighbors)."""
        self._revealed_hexes.add(hex_coord)
        for adj in get_adjacent_hexes(hex_coord):
            self._revealed_hexes.add(adj)
            # Generate reality tile if not already known
            if adj not in self._reality:
                self._reality[adj] = self._draw_card()

    def _get_playable_frontier(self) -> list[tuple[int, int, int]]:
        """Get all hexes adjacent to built hexes that aren't built."""
        frontier = []
        seen = set()
        for built in self._built_hexes:
            for adj in get_adjacent_hexes(built):
                if adj not in self._built_hexes and adj not in seen:
                    frontier.append(adj)
                    seen.add(adj)
        return frontier

    def _is_valid_nomination(self, hex_coord: tuple[int, int, int]) -> bool:
        """Check if a hex can be nominated."""
        if hex_coord in self._built_hexes:
            return False
        return hex_coord in self._get_playable_frontier()

    # ─────────────────────────────────────────────────────────────────────────
    # OpenSpiel State Interface
    # ─────────────────────────────────────────────────────────────────────────

    def current_player(self) -> int:
        """Return current player (0=Mayor, 1=Industry, 2=Urbanist, or chance)."""
        if self._is_terminal:
            return pyspiel.PlayerId.TERMINAL
        if self._pending_draws > 0:
            return pyspiel.PlayerId.CHANCE

        if self._phase == Phase.DRAW:
            if self._sub_phase == "drawing":
                return pyspiel.PlayerId.CHANCE
            return Role.MAYOR
        elif self._phase == Phase.CONTROL:
            return Role.MAYOR  # Mayor chooses control mode
        elif self._phase == Phase.NOMINATE:
            # Each advisor commits 2 nominations sequentially
            if self._sub_phase in ("industry_commit_1", "industry_commit_2"):
                return Role.INDUSTRY
            elif self._sub_phase in ("urbanist_commit_1", "urbanist_commit_2"):
                return Role.URBANIST
            return Role.INDUSTRY  # Start with industry
        elif self._phase == Phase.PLACE:
            return Role.MAYOR
        return pyspiel.PlayerId.TERMINAL

    def is_terminal(self) -> bool:
        return self._is_terminal

    def returns(self) -> list[float]:
        """Return final GAME scores for each player.

        These are the actual accumulated scores used to determine who WINS.
        Note: For RL training, use mayor_hit_mine() to check if Mayor should
        receive a large penalty - but that penalty should NOT affect who wins.

        If Mayor hit a mine, their score is still their accumulated points
        (usually 0 or low since game ended early). The -100 RL penalty is
        applied separately in the training code.
        """
        return [
            float(self._scores["mayor"]),
            float(self._scores["industry"]),
            float(self._scores["urbanist"]),
        ]

    def mayor_hit_mine(self) -> bool:
        """Check if Mayor hit a mine (for RL penalty purposes)."""
        return self._mayor_hit_mine

    def turn_rewards(self) -> list[float]:
        """Return per-turn reward signals for dense reward shaping.

        These are relative improvements: own_delta - (avg_others_delta).
        Use these for intermediate rewards during training.
        """
        return [
            float(self._turn_rewards["mayor"]),
            float(self._turn_rewards["industry"]),
            float(self._turn_rewards["urbanist"]),
        ]

    def legal_actions(self, player: Optional[int] = None) -> list[int]:
        """Return list of legal actions for the current player."""
        if self._is_terminal:
            return []

        if player is None:
            player = self.current_player()

        if player == pyspiel.PlayerId.CHANCE:
            return self._chance_legal_actions()

        if self._phase == Phase.DRAW:
            return self._draw_legal_actions()
        elif self._phase == Phase.CONTROL:
            return self._control_legal_actions()
        elif self._phase == Phase.NOMINATE:
            return self._nominate_legal_actions(player)
        elif self._phase == Phase.PLACE:
            return self._place_legal_actions()
        return []

    def _chance_legal_actions(self) -> list[int]:
        """Legal actions for chance node (drawing cards)."""
        # All remaining cards in deck are equally likely
        return list(range(ACTION_CHANCE_BASE, ACTION_CHANCE_BASE + NUM_CARDS))

    def _draw_legal_actions(self) -> list[int]:
        """Legal actions in draw phase - Mayor reveals cards (2 total, one at a time).

        Only unrevealed cards can be selected.
        """
        actions = []
        for i in range(len(self._hand)):
            if i not in self._revealed_indices:
                actions.append(ACTION_REVEAL_BASE + i)
        return actions

    def _control_legal_actions(self) -> list[int]:
        """Legal actions in control phase - Mayor chooses control mode.

        Options:
        - ACTION_CONTROL_SUIT_A: Force suits (Urb→Diamond, Ind→Heart)
        - ACTION_CONTROL_SUIT_B: Force suits (Urb→Heart, Ind→Diamond)
        - ACTION_CONTROL_HEX_BASE + urb_hex * MAX_FRONTIER + ind_hex: Force specific hexes
        - ACTION_CONTROL_REVEAL_BASE + hex_idx: REVEAL one hex's true identity (KEY TOOL)
        """
        actions = []

        # Suit forcing options (always available)
        actions.append(ACTION_CONTROL_SUIT_A)
        actions.append(ACTION_CONTROL_SUIT_B)

        # Hex forcing options - all valid pairs of frontier hexes
        frontier = self._get_playable_frontier()
        max_frontier = min(len(frontier), self._game.max_frontier)

        for urb_idx in range(max_frontier):
            for ind_idx in range(max_frontier):
                # Both advisors can be forced to same hex (overlap allowed)
                action = ACTION_CONTROL_HEX_BASE + urb_idx * MAX_FRONTIER_SIZE + ind_idx
                actions.append(action)

        # NOTE: REVEAL_HEX is now in PLACE phase (after seeing nominations)
        # Removed from Control phase because Mayor needs to see nominations first!

        return actions

    def _nominate_legal_actions(self, player: int) -> list[int]:
        """Legal actions in nominate phase - Advisor commits hex + claim.

        Constraints:
        - For second nomination, hex must be different from first
        - If FORCE_HEXES: first nomination must be the forced hex
        - If FORCE_SUITS: at least one nomination must use the forced suit
        """
        frontier = self._get_playable_frontier()
        if not frontier:
            print(f"WARNING: No frontier in nominate phase for player {player}")
            return []

        role_key = "industry" if player == Role.INDUSTRY else "urbanist"
        tray = self._advisor_trays[role_key]

        # Refill tray if empty (like reshuffling the deck)
        if not tray:
            self._advisor_trays[role_key] = list(range(NUM_CARDS))
            tray = self._advisor_trays[role_key]

        # Check if this is the second nomination (must be different hex)
        is_first_nom = self._sub_phase in ("industry_commit_1", "urbanist_commit_1")
        is_second_nom = self._sub_phase in ("industry_commit_2", "urbanist_commit_2")
        first_hex = None
        first_claim_suit = None
        if is_second_nom and self._advisor_commits[role_key]:
            first_hex = self._advisor_commits[role_key][0].get("hex")
            first_claim = self._advisor_commits[role_key][0].get("claim", {})
            first_claim_suit = first_claim.get("suit")

        # Determine forced suit (if any)
        forced_suit = None
        if (
            self._control_mode == ControlMode.FORCE_SUITS
            and self._forced_suit_config is not None
        ):
            if self._forced_suit_config == SuitConfig.URB_DIAMOND_IND_HEART:
                forced_suit = Suit.DIAMONDS if role_key == "urbanist" else Suit.HEARTS
            else:  # URB_HEART_IND_DIAMOND
                forced_suit = Suit.HEARTS if role_key == "urbanist" else Suit.DIAMONDS

        # Determine forced hex (if any)
        forced_hex = (
            self._forced_hexes.get(role_key)
            if self._control_mode == ControlMode.FORCE_HEXES
            else None
        )

        actions = []
        for hex_idx, hex_coord in enumerate(frontier):
            if hex_idx >= self._game.max_frontier:
                break

            # FORCE_HEXES: first nomination MUST be the forced hex
            if is_first_nom and forced_hex is not None:
                if hex_coord != forced_hex:
                    continue

            # Skip first hex for second nomination
            if is_second_nom and hex_coord == first_hex:
                continue

            # Register hex in encoder for consistent indexing
            self._encoder.get_hex_index(hex_coord)

            for claim_idx in tray:
                # FORCE_SUITS: check suit constraint
                if forced_suit is not None:
                    claim_card = index_to_card(claim_idx)
                    claim_suit = claim_card.get("suit")

                    if is_first_nom:
                        # First nomination can be any suit (second must satisfy constraint if first didn't)
                        pass  # No restriction on first nomination
                    elif is_second_nom:
                        # If first nomination already used forced suit, second is free
                        # If first nomination did NOT use forced suit, second MUST use it
                        if (
                            first_claim_suit != forced_suit
                            and claim_suit != forced_suit
                        ):
                            continue  # Must use forced suit in at least one nomination

                action = ACTION_COMMIT_BASE + hex_idx * NUM_CARDS + claim_idx
                actions.append(action)

        # Fallback: if no valid actions due to constraints, allow any nomination
        # This can happen late game when frontier is very small
        if not actions and frontier and tray:
            for hex_idx, hex_coord in enumerate(frontier):
                if hex_idx >= self._game.max_frontier:
                    break
                for claim_idx in tray:
                    action = ACTION_COMMIT_BASE + hex_idx * NUM_CARDS + claim_idx
                    actions.append(action)

        return actions

    def _place_legal_actions(self) -> list[int]:
        """Legal actions in place phase - Mayor picks card + nominated hex, OR verifies a hex.

        With 2 nominations per advisor, there can be up to 4 nominations.

        Actions:
        - BUILD: card_idx * 4 + nom_idx (standard building)
        - VERIFY: ACTION_CONTROL_REVEAL_BASE + nom_idx (verify a nominated hex, skip building)

        VERIFY is the KEY DEDUCTION TOOL:
        - Mayor sees the nominated hex's TRUE reality
        - Turn ends (no building) - this is the cost of verification
        - Mayor can use this info in future turns to detect liars
        """
        actions = []

        # Debug: if no nominations, something is wrong
        if not self._nominations:
            print(
                f"WARNING: No nominated hexes in PLACE phase! Nominations: {self._nominations}"
            )
            # Fall back to frontier hexes to avoid crash
            frontier = self._get_playable_frontier()
            if frontier:
                self._nominations = [
                    {"advisor": "industry", "hex": frontier[0], "claim": {}},
                ]
                if len(frontier) > 1:
                    self._nominations.append(
                        {"advisor": "urbanist", "hex": frontier[1], "claim": {}}
                    )

        # BUILD actions: pick card + nomination
        for card_idx in range(len(self._hand)):
            for nom_idx in range(len(self._nominations)):
                action = ACTION_BUILD_BASE + card_idx * MAX_NOMINATIONS + nom_idx
                actions.append(action)

        # VERIFY actions: verify a nominated hex (costs the turn but gains info)
        for nom_idx, nom in enumerate(self._nominations):
            hex_coord = nom.get("hex")
            # Can only verify hexes not already verified
            if hex_coord and hex_coord not in self._mayor_verified_hexes:
                action = ACTION_CONTROL_REVEAL_BASE + nom_idx
                actions.append(action)

        return actions

    def chance_outcomes(self) -> list[tuple[int, float]]:
        """Return chance outcomes with probabilities."""
        if self.current_player() != pyspiel.PlayerId.CHANCE:
            return []
        # Equal probability for any card
        actions = self._chance_legal_actions()
        prob = 1.0 / len(actions) if actions else 0.0
        return [(a, prob) for a in actions]

    def _apply_action(self, action: int):
        """Apply an action to the state."""
        player = self.current_player()

        if player == pyspiel.PlayerId.CHANCE:
            self._apply_chance(action)
        elif self._phase == Phase.DRAW:
            self._apply_reveal(action)
        elif self._phase == Phase.CONTROL:
            self._apply_control(action)
        elif self._phase == Phase.NOMINATE:
            self._apply_commit(action, player)
        elif self._phase == Phase.PLACE:
            self._apply_place(action)

    def _apply_chance(self, action: int):
        """Apply chance action (card draw)."""
        card_idx = action - ACTION_CHANCE_BASE
        card = index_to_card(card_idx)
        self._hand.append(card)
        self._pending_draws -= 1

        if self._pending_draws == 0:
            self._sub_phase = "ready"

    def _apply_reveal(self, action: int):
        """Mayor reveals one card from hand. After 2 cards revealed -> CONTROL phase."""
        reveal_idx = action - ACTION_REVEAL_BASE
        if (
            0 <= reveal_idx < len(self._hand)
            and reveal_idx not in self._revealed_indices
        ):
            self._revealed_indices.append(reveal_idx)

            # After 2 cards revealed -> CONTROL phase (NEW)
            if len(self._revealed_indices) >= 2:
                self._phase = Phase.CONTROL
                self._sub_phase = "control"
            self._advisor_commits = {"industry": [], "urbanist": []}

    def _apply_control(self, action: int):
        """Mayor chooses control mode: force suits, force hexes, or REVEAL a hex."""
        frontier = self._get_playable_frontier()

        if action == ACTION_CONTROL_SUIT_A:
            # Urbanist → Diamonds, Industry → Hearts
            self._control_mode = ControlMode.FORCE_SUITS
            self._forced_suit_config = SuitConfig.URB_DIAMOND_IND_HEART
            self._forced_hexes = {}
        elif action == ACTION_CONTROL_SUIT_B:
            # Urbanist → Hearts, Industry → Diamonds
            self._control_mode = ControlMode.FORCE_SUITS
            self._forced_suit_config = SuitConfig.URB_HEART_IND_DIAMOND
            self._forced_hexes = {}
        elif action >= ACTION_CONTROL_HEX_BASE:
            # Force hexes
            hex_action = action - ACTION_CONTROL_HEX_BASE
            urb_hex_idx = hex_action // MAX_FRONTIER_SIZE
            ind_hex_idx = hex_action % MAX_FRONTIER_SIZE

            self._control_mode = ControlMode.FORCE_HEXES
            self._forced_suit_config = None

            # Map indices to actual hex coordinates
            max_frontier = min(len(frontier), self._game.max_frontier)
            if urb_hex_idx < max_frontier and ind_hex_idx < max_frontier:
                self._forced_hexes = {
                    "urbanist": frontier[urb_hex_idx],
                    "industry": frontier[ind_hex_idx],
                }
            else:
                # Fallback if indices invalid
                self._forced_hexes = {}

        # Transition to NOMINATE phase
        self._phase = Phase.NOMINATE
        self._sub_phase = "industry_commit_1"

    def _apply_commit(self, action: int, player: int):
        """Advisor commits a nomination (2 nominations per advisor)."""
        commit_idx = action - ACTION_COMMIT_BASE
        hex_idx = commit_idx // NUM_CARDS
        claim_idx = commit_idx % NUM_CARDS

        frontier = self._get_playable_frontier()
        max_frontier = min(len(frontier), self._game.max_frontier)
        if hex_idx >= max_frontier:
            print(
                f"WARNING: Invalid commit hex_idx={hex_idx}, max_frontier={max_frontier}"
            )
            return

        hex_coord = frontier[hex_idx]
        claim_card = index_to_card(claim_idx)
        role_key = "industry" if player == Role.INDUSTRY else "urbanist"

        # Append to list of nominations for this advisor
        self._advisor_commits[role_key].append(
            {
                "hex": hex_coord,
                "claim": claim_card,
                "advisor": role_key,
            }
        )

        # Remove claim card from tray
        if claim_idx in self._advisor_trays[role_key]:
            self._advisor_trays[role_key].remove(claim_idx)

        # Advance sub-phase through sequential nominations
        # industry_commit_1 -> industry_commit_2 -> urbanist_commit_1 -> urbanist_commit_2 -> PLACE
        sub_phase_transitions = {
            "industry_commit_1": "industry_commit_2",
            "industry_commit_2": "urbanist_commit_1",
            "urbanist_commit_1": "urbanist_commit_2",
            "urbanist_commit_2": "place_ready",
        }

        next_phase = sub_phase_transitions.get(self._sub_phase, "place_ready")

        if next_phase == "place_ready":
            # All 4 nominations committed - build flat list for Mayor
            self._nominations = []
            for advisor_key in ["industry", "urbanist"]:
                for nom in self._advisor_commits[advisor_key]:
                    self._nominations.append(nom)
            self._phase = Phase.PLACE
            self._sub_phase = "ready"
        else:
            self._sub_phase = next_phase

    def _apply_place(self, action: int):
        """Mayor places a card on a nominated hex, OR verifies a hex (no build).

        VERIFY (ACTION_CONTROL_REVEAL_BASE + nom_idx):
        - Mayor sees the nominated hex's TRUE reality
        - Turn ends without building - this is the cost of verification
        - Mayor retains info for future turns to detect liars
        """
        # Check if this is a VERIFY action (in the REVEAL range, not BUILD range)
        # VERIFY actions: ACTION_CONTROL_REVEAL_BASE + nom_idx (2506-2509)
        # BUILD actions: ACTION_BUILD_BASE + ... (4506+)
        if ACTION_CONTROL_REVEAL_BASE <= action < ACTION_COMMIT_BASE:
            nom_idx = action - ACTION_CONTROL_REVEAL_BASE
            if nom_idx < len(self._nominations):
                nom = self._nominations[nom_idx]
                hex_coord = nom.get("hex")
                if hex_coord:
                    # Mayor verifies this hex - now knows its reality
                    self._mayor_verified_hexes.add(hex_coord)
                    self._control_revealed_hex = hex_coord  # For observation

                    # Dense reward: REWARD for gaining information!
                    reality = self._reality.get(hex_coord, {})
                    if reality.get("suit") == Suit.SPADES:
                        # Found a mine! This is VERY valuable info - avoided death
                        self._turn_rewards["mayor"] += 10.0
                    else:
                        # Found safe hex - useful info for building
                        self._turn_rewards["mayor"] += 2.0

            # Turn ends without building - go to next turn
            self._turn += 1
            self._phase = Phase.DRAW
            self._hand = []
            self._revealed_indices = []
            self._pending_draws = 4
            self._control_mode = ControlMode.NONE
            self._forced_suit_config = None
            self._forced_hexes = {}
            self._control_revealed_hex = None
            self._sub_phase = "drawing"
            self._nominations = []
            return

        # BUILD action: place card on nominated hex
        place_idx = action - ACTION_BUILD_BASE
        card_idx = place_idx // MAX_NOMINATIONS
        nom_idx = place_idx % MAX_NOMINATIONS

        if card_idx >= len(self._hand):
            return

        if nom_idx >= len(self._nominations):
            return

        chosen_nomination = self._nominations[nom_idx]
        chosen_hex = chosen_nomination["hex"]
        placed_card = self._hand[card_idx]

        # Build on the hex
        self._built_hexes.append(chosen_hex)
        self._reveal_around(chosen_hex)

        # Calculate scores (pass the chosen nomination for attribution)
        prev_scores = self._scores.copy()
        self._calculate_turn_scores(placed_card, chosen_hex, chosen_nomination)

        # Record turn history for deduction (includes control mode info)
        reality = self._reality.get(chosen_hex, {})
        scores_delta = {k: self._scores[k] - prev_scores[k] for k in self._scores}
        self._turn_history.append(
            {
                "turn": self._turn,
                "revealed_indices": self._revealed_indices.copy(),
                "control_mode": int(self._control_mode),
                "forced_suit_config": (
                    int(self._forced_suit_config)
                    if self._forced_suit_config is not None
                    else None
                ),
                "forced_hexes": self._forced_hexes.copy(),
                "nominations": [n.copy() for n in self._nominations],
                "build": {"hex": chosen_hex, "card": placed_card.copy()},
                "reality": reality.copy(),
                "scores_delta": scores_delta,
            }
        )

        # Check for mine (spade reality) - Mayor LOSES IMMEDIATELY
        reality = self._reality.get(chosen_hex, {})
        reality_suit = reality.get("suit")
        if reality_suit == Suit.SPADES:
            self._mayor_hit_mine = True  # Mayor loses regardless of score
            self._is_terminal = True

            # DEATH REVEAL: When Mayor dies, ALL nominated hexes are revealed
            # and ALL liars are penalized! This is the key accountability mechanic.
            self._apply_death_reveal_penalty()
            return

        # Dense reward shaping: Mine dodge bonus for Mayor
        # Mayor gets bonus for avoiding mines in OTHER nominated hexes
        mine_dodge_bonus = self._compute_mine_dodge_bonus(chosen_hex)
        if mine_dodge_bonus > 0:
            self._turn_rewards["mayor"] += mine_dodge_bonus

        # Track facility builds by reality suit (Mayor's endgame progress)
        if reality_suit == Suit.HEARTS:
            self._facilities["hearts"] += 1
        elif reality_suit == Suit.DIAMONDS:
            self._facilities["diamonds"] += 1

        # Check for city completion (Mayor's endgame: 10♥ + 10♦ ends the game)
        if (
            self._facilities["hearts"] >= FACILITIES_TO_COMPLETE
            and self._facilities["diamonds"] >= FACILITIES_TO_COMPLETE
        ):
            self._city_complete = True
            self._is_terminal = True
            return

        # Discard placed card and prepare next turn
        self._discard.append(placed_card)
        del self._hand[card_idx]

        self._turn += 1
        # No turn limit - game ends via mine hit or city completion only

        # Start new turn
        self._phase = Phase.DRAW
        self._hand = []
        self._revealed_indices = []
        self._pending_draws = 4  # Mayor draws 4 cards
        # Reset control state for new turn
        self._control_mode = ControlMode.NONE
        self._forced_suit_config = None
        self._forced_hexes = {}
        self._control_revealed_hex = None
        self._sub_phase = "drawing"
        self._nominations = []

    def _apply_death_reveal_penalty(self):
        """When Mayor dies, reveal ALL nominated hexes and penalize ALL liars.

        This is the KEY ACCOUNTABILITY MECHANIC:
        - Any advisor who lied about a mine (claimed non-Spade on Spade): -3 penalty
        - Any advisor who cried wolf (claimed Spade on non-Spade): -2 penalty
        - Honest advisors: no penalty

        This makes lying much riskier - even if Mayor picks a different hex,
        your lie will be exposed when Mayor dies!
        """
        for nom in self._nominations:
            hex_coord = nom.get("hex")
            advisor = nom.get("advisor", "")
            claim = nom.get("claim", {})
            claim_suit = claim.get("suit", -1)

            if not hex_coord or not advisor:
                continue

            # Get the true reality of this hex
            reality = self._reality.get(hex_coord, {})
            reality_suit = reality.get("suit", -1)

            # Check for lies
            if reality_suit == Suit.SPADES and claim_suit != Suit.SPADES:
                # Lied about mine: claimed it was safe but it's a mine
                self._scores[advisor] -= 3
            elif reality_suit != Suit.SPADES and claim_suit == Suit.SPADES:
                # Cried wolf: claimed mine but it's safe
                self._scores[advisor] -= 2

    def _compute_mine_dodge_bonus(self, chosen_hex: tuple[int, int, int]) -> float:
        """Compute bonus for avoiding mines in non-chosen nominations.

        Dense reward shaping: Mayor gets bonus for dodging mines they didn't pick.
        - +10.0 if advisor lied about the mine (claimed non-Spade on actual Spade)
        - +2.0 if advisor honestly warned (claimed Spade) but Mayor still dodged

        This helps Mayor learn to detect and avoid deception.
        The bonuses are high because avoiding death is valuable!
        """
        bonus = 0.0
        for nom in self._nominations:
            nom_hex = nom.get("hex")
            if nom_hex == chosen_hex:
                continue  # Skip the chosen hex

            reality = self._reality.get(nom_hex, {})
            if reality.get("suit") != Suit.SPADES:
                continue  # Not a mine, no dodge

            claim_suit = nom.get("claim", {}).get("suit", -1)
            if claim_suit != Suit.SPADES:
                # Detectable lie: advisor lied about this mine - BIG bonus
                bonus += 10.0
            else:
                # Honest warning, but Mayor still dodged
                bonus += 2.0

        return bonus

    def _calculate_turn_scores(
        self,
        placed_card: dict,
        chosen_hex: tuple[int, int, int],
        chosen_nomination: dict,
    ):
        """Calculate scores with bluff detection.

        Bluff Detection Scoring:
        - Mayor TRUSTS (plays same suit as claim): Advisor gets +1 regardless of honesty
        - Mayor CALLS (plays different suit than claim):
          - If claim suit = reality suit (advisor honest): +1
          - If claim suit ≠ reality suit (bluff caught): 0
        - SPADE REALITY: +1 if honestly warned, -2 if lied about mine
        - Mayor scores +1 if placed card suit matches reality tile suit (simple rule)

        Also computes per-turn reward signals for dense reward shaping.
        """
        # Track scores before this turn for reward shaping
        prev_scores = self._scores.copy()

        reality = self._reality.get(chosen_hex, {})
        placed_suit = placed_card.get("suit", -1)
        placed_value = placed_card.get("value", 0)
        reality_suit = reality.get("suit", -1)
        reality_value = reality.get("value", 0)

        is_mine = reality_suit == Suit.SPADES  # Reality is a mine

        # Find all nominations for the chosen hex (could be multiple)
        noms_for_hex = [n for n in self._nominations if n.get("hex") == chosen_hex]

        if not noms_for_hex:
            return

        # SPADE REALITY: Score ALL advisors who nominated this hex
        if is_mine:
            scored_advisors = set()
            for nom in noms_for_hex:
                advisor = nom.get("advisor", "")
                if not advisor or advisor in scored_advisors:
                    continue
                claim = nom.get("claim", {})
                claim_suit = claim.get("suit", -1)
                if claim_suit == Suit.SPADES:
                    self._scores[
                        advisor
                    ] += 1  # Honest warning = +1 for accurate mine detection
                else:
                    self._scores[advisor] -= 3  # Lied about mine, SEVERE penalty
                scored_advisors.add(advisor)
        else:
            # NON-SPADE REALITY: Determine winning advisor via tie-break
            winning_nom = noms_for_hex[0]
            used_domain_affinity_for_spades = False
            if len(noms_for_hex) > 1:
                best_diff = float("inf")
                best_suit_match = False
                best_domain_match = False

                for nom in noms_for_hex:
                    claim = nom.get("claim", {})
                    claim_value = claim.get("value", 0)
                    claim_suit = claim.get("suit", -1)
                    advisor = nom.get("advisor", "")

                    diff = abs(claim_value - placed_value)
                    suit_match = claim_suit == placed_suit
                    # Domain affinity: Hearts→Urbanist, Diamonds/Spades→Industry
                    domain_match = (
                        claim_suit == Suit.HEARTS and advisor == "urbanist"
                    ) or (
                        claim_suit in [Suit.DIAMONDS, Suit.SPADES]
                        and advisor == "industry"
                    )

                    dominated = False
                    if diff < best_diff:
                        dominated = True
                    elif diff == best_diff:
                        if suit_match and not best_suit_match:
                            dominated = True
                        elif suit_match == best_suit_match:
                            if domain_match and not best_domain_match:
                                dominated = True

                    if dominated:
                        best_diff = diff
                        best_suit_match = suit_match
                        best_domain_match = domain_match
                        winning_nom = nom

                # Check if domain affinity was used for Spades (both claimed same Spade card)
                first_claim = noms_for_hex[0].get("claim", {})
                second_claim = (
                    noms_for_hex[1].get("claim", {}) if len(noms_for_hex) > 1 else {}
                )
                if (
                    first_claim.get("suit", -1) == Suit.SPADES
                    and first_claim.get("suit", -1) == second_claim.get("suit", -1)
                    and first_claim.get("value", -1) == second_claim.get("value", -1)
                ):
                    used_domain_affinity_for_spades = True

            # Apply bluff detection scoring to the winning advisor
            advisor = winning_nom.get("advisor", "")
            if advisor:
                claim = winning_nom.get("claim", {})
                claim_suit = claim.get("suit", -1)

                # Spades domain affinity special case: if both advisors claimed
                # identical Spades but reality is NOT Spades, both were lying
                # about a mine - PENALIZE both for false alarm
                if used_domain_affinity_for_spades and reality_suit != Suit.SPADES:
                    # Both advisors falsely claimed mine - penalize both HEAVILY
                    for nom in noms_for_hex:
                        false_advisor = nom.get("advisor", "")
                        if false_advisor:
                            self._scores[
                                false_advisor
                            ] -= 2  # Penalty for false Spade claim
                elif placed_suit == claim_suit:
                    # Mayor TRUSTED (played same suit as claimed)
                    self._scores[advisor] += 1
                else:
                    # Mayor CALLED (played different suit than claimed)
                    if claim_suit == reality_suit:
                        # Advisor was honest but Mayor didn't believe them
                        self._scores[advisor] += 1
                    elif claim_suit == Suit.SPADES:
                        # FALSE MINE CLAIM: Advisor claimed Spade but it's not!
                        # This is crying wolf - PENALIZE HEAVILY to prevent spam
                        self._scores[advisor] -= 2
                    # else: Advisor bluffed non-Spade AND Mayor caught it - 0 points

        # MAYOR SCORING - simple suit match
        # Mayor scores +1 if their placed card's suit matches the reality tile's suit
        if not is_mine:
            if placed_suit == reality_suit:
                self._scores["mayor"] += 1

        # Compute per-turn reward signals for dense reward shaping
        # This is the score change for each role this turn
        new_scores = self._scores.copy()

        # Calculate turn rewards as relative improvement (own delta - avg others delta)
        for role_key in ["mayor", "industry", "urbanist"]:
            own_delta = new_scores[role_key] - prev_scores[role_key]
            others_delta = sum(
                new_scores[k] - prev_scores[k] for k in new_scores if k != role_key
            )
            # Reward = own improvement minus half of opponents' improvement
            # This incentivizes gaining ground relative to opponents
            self._turn_rewards[role_key] = own_delta - (others_delta / 2.0)

        # Dense reward shaping: Survival bonus for Mayor
        # Mayor gets +10.0 for each turn survived without hitting a mine
        # This needs to dominate the -100 terminal penalty so that
        # "surviving longer" is ALWAYS better than "dying sooner"
        # Even if Mayor dies: 5 turns = +50-100=-50, 10 turns = +100-100=0
        # This creates a clear gradient: more turns = better
        if not is_mine:
            self._turn_rewards["mayor"] += 10.0
        else:
            # CRITICAL FIX: When Mayor hits a mine, set explicit negative intermediate reward
            # This ensures the policy learns "this specific action was bad"
            # Without this, Mayor could get POSITIVE intermediate reward even when dying
            # (due to relative score calculation when advisors lose points)
            self._turn_rewards["mayor"] = (
                -10.0
            )  # Strong negative, but less than terminal -100

    # ─────────────────────────────────────────────────────────────────────────
    # Information State / Observation
    # ─────────────────────────────────────────────────────────────────────────

    def information_state_string(self, player: int) -> str:
        """Return information state string for a player."""
        return self._info_string(player)

    def information_state_tensor(self, player: int) -> list[float]:
        """Return information state tensor for a player."""
        return list(self._observation_tensor(player))

    def observation_string(self, player: int) -> str:
        """Return observation string for a player."""
        return self._info_string(player)

    def observation_tensor(self, player: int) -> list[float]:
        """Return observation tensor for a player."""
        return list(self._observation_tensor(player))

    def _info_string(self, player: int) -> str:
        """Build information string for a player."""
        parts = [f"P{player}", f"T{self._turn}", f"Ph{self._phase.name}"]
        parts.append(f"Scores:{self._scores}")

        if player == Role.MAYOR:
            hand_str = ",".join(card_label(c) for c in self._hand)
            parts.append(f"Hand:[{hand_str}]")
            if self._revealed_indices:
                parts.append(f"Revealed:{self._revealed_indices}")
        else:
            # Advisors see revealed cards
            revealed_cards = [
                card_label(self._hand[i])
                for i in self._revealed_indices
                if 0 <= i < len(self._hand)
            ]
            if revealed_cards:
                parts.append(f"Revealed:[{','.join(revealed_cards)}]")

        if self._phase == Phase.PLACE and self._nominations:
            # Format nominations as list
            nom_strs = []
            for nom in self._nominations:
                advisor = nom.get("advisor", "?")
                claim = card_label(nom.get("claim", {}))
                nom_strs.append(f"{advisor}:{claim}")
            parts.append(f"Noms:[{','.join(nom_strs)}]")

        return "|".join(parts)

    def _observation_tensor(self, player: int) -> np.ndarray:
        """Build observation tensor for a player."""
        frontier = self._get_playable_frontier()
        built = list(self._built_hexes)

        # Get revealed cards (up to 2)
        revealed_cards = [
            self._hand[idx]
            for idx in self._revealed_indices
            if 0 <= idx < len(self._hand)
        ]

        if player == Role.MAYOR:
            return self._encoder.encode_mayor_observation(
                self._phase,
                self._turn,
                self._scores,
                built,
                frontier,
                self._hand,
                self._revealed_indices,
                self._nominations,
                self._control_mode,
                self._forced_suit_config,
                self._forced_hexes,
                self._facilities,
            )
        else:
            # Advisor observation
            role_key = "industry" if player == Role.INDUSTRY else "urbanist"
            reality_tiles = {
                h: self._reality.get(h, {}) for h in frontier if h in self._reality
            }
            tray = self._advisor_trays[role_key]

            return self._encoder.encode_advisor_observation(
                Role(player),
                self._phase,
                self._turn,
                self._scores,
                built,
                frontier,
                revealed_cards,
                reality_tiles,
                tray,
                self._nominations,
                self._control_mode,
                self._forced_suit_config,
                self._forced_hexes,
                self._facilities,
            )

    def __str__(self) -> str:
        return f"Turn {self._turn}, Phase {self._phase.name}, Scores {self._scores}"


class CollapsizationObserver:
    """Observer for Collapsization game."""

    def __init__(self, game: CollapsizationGame, iig_obs_type, params):
        self._game = game
        self._encoder = ObservationEncoder(game.max_frontier)

        # Determine observation size based on type
        if iig_obs_type and iig_obs_type.public_info:
            self._size = self._encoder.observation_size
        else:
            self._size = self._encoder.mayor_observation_size  # Use larger size

    def set_from(self, state: CollapsizationState, player: int):
        """Set observation from state for a player."""
        self._tensor = state._observation_tensor(player)

    def string_from(self, state: CollapsizationState, player: int) -> str:
        """Get observation string from state for a player."""
        return state._info_string(player)

    def tensor_size(self) -> int:
        return self._size


# Register the game with OpenSpiel
pyspiel.register_game(_GAME_TYPE, CollapsizationGame)
