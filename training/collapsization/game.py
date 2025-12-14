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
    "max_turns": 50,
    "max_frontier": MAX_FRONTIER_SIZE,
}

# Action space definitions
# - Mayor reveal: 0-2 (which of 3 cards to reveal)
# - Advisor commit: frontier_hex_idx * NUM_CARDS + claim_card_idx
#   Each advisor commits 2 nominations sequentially (4 sub-phases total)
# - Mayor build: hand_card_idx * MAX_NOMINATIONS + nominated_hex_idx (0-3)
# - Chance actions: 0 to NUM_CARDS-1 for deck draws

MAX_FRONTIER_ACTIONS = MAX_FRONTIER_SIZE * NUM_CARDS
NOMINATIONS_PER_ADVISOR = 2  # Each advisor nominates 2 hexes
MAX_NOMINATIONS = NOMINATIONS_PER_ADVISOR * 2  # 4 total (2 per advisor)

ACTION_REVEAL_BASE = 0
ACTION_REVEAL_COUNT = 4  # Mayor now draws 4 cards
ACTION_COMMIT_BASE = ACTION_REVEAL_COUNT
ACTION_COMMIT_COUNT = MAX_FRONTIER_ACTIONS
ACTION_BUILD_BASE = ACTION_COMMIT_BASE + ACTION_COMMIT_COUNT
# Mayor has 4 cards, reveals 2, so 2 remain for build phase
ACTION_BUILD_COUNT = 4 * MAX_NOMINATIONS  # 4 hand cards × 4 max nominations
ACTION_CHANCE_BASE = ACTION_BUILD_BASE + ACTION_BUILD_COUNT
ACTION_CHANCE_COUNT = NUM_CARDS

TOTAL_ACTIONS = ACTION_CHANCE_BASE + ACTION_CHANCE_COUNT


class CollapsizationGame(pyspiel.Game):
    """Collapsization game for OpenSpiel."""

    def __init__(self, params: Optional[dict] = None):
        params = params or {}
        self.max_turns = params.get("max_turns", _DEFAULT_PARAMS["max_turns"])
        self.max_frontier = params.get("max_frontier", _DEFAULT_PARAMS["max_frontier"])

        game_info = pyspiel.GameInfo(
            num_distinct_actions=TOTAL_ACTIONS,
            max_chance_outcomes=NUM_CARDS,
            num_players=NUM_PLAYERS,
            min_utility=-20.0,
            max_utility=50.0,
            utility_sum=None,  # General sum game
            max_game_length=self.max_turns * 10,  # Rough upper bound
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

        # Revealed hexes (fog cleared)
        self._revealed_hexes: set[tuple[int, int, int]] = set()
        self._reveal_around(self._town_center)

        # Track which draws are pending (for chance nodes)
        # Start with 4 pending draws - Mayor needs 4 cards before revealing
        self._pending_draws = 4
        # Sub-phases for sequential nominations:
        # "drawing", "reveal_1", "reveal_2", "industry_commit_1", "industry_commit_2",
        # "urbanist_commit_1", "urbanist_commit_2", "ready"
        self._sub_phase = "ready"

        # Turn history for deduction (full game history)
        # Each entry: {turn, revealed_indices, nominations, build, reality, scores_delta}
        self._turn_history: list[dict] = []

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
        """Return final scores for each player."""
        return [
            float(self._scores["mayor"]),
            float(self._scores["industry"]),
            float(self._scores["urbanist"]),
        ]

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

    def _nominate_legal_actions(self, player: int) -> list[int]:
        """Legal actions in nominate phase - Advisor commits hex + claim.

        For second nomination, the hex must be different from the first.
        """
        frontier = self._get_playable_frontier()
        if not frontier:
            print(f"WARNING: No frontier in nominate phase for player {player}")
            return []

        role_key = "industry" if player == Role.INDUSTRY else "urbanist"
        tray = self._advisor_trays[role_key]

        if not tray:
            print(f"WARNING: Empty tray for {role_key} in nominate phase")
            return []

        # Check if this is the second nomination (must be different hex)
        is_second_nom = self._sub_phase in ("industry_commit_2", "urbanist_commit_2")
        first_hex = None
        if is_second_nom and self._advisor_commits[role_key]:
            first_hex = self._advisor_commits[role_key][0].get("hex")

        actions = []
        for hex_idx, hex_coord in enumerate(frontier):
            if hex_idx >= self._game.max_frontier:
                break
            # Skip first hex for second nomination
            if is_second_nom and hex_coord == first_hex:
                continue
            # Register hex in encoder for consistent indexing
            self._encoder.get_hex_index(hex_coord)
            for claim_idx in tray:
                action = ACTION_COMMIT_BASE + hex_idx * NUM_CARDS + claim_idx
                actions.append(action)
        return actions

    def _place_legal_actions(self) -> list[int]:
        """Legal actions in place phase - Mayor picks card + nominated hex.

        With 2 nominations per advisor, there can be up to 4 nominations.
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

        for card_idx in range(len(self._hand)):
            for nom_idx in range(len(self._nominations)):
                action = ACTION_BUILD_BASE + card_idx * MAX_NOMINATIONS + nom_idx
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
        """Mayor reveals one card from hand. After 2 cards revealed -> NOMINATE phase."""
        reveal_idx = action - ACTION_REVEAL_BASE
        if (
            0 <= reveal_idx < len(self._hand)
            and reveal_idx not in self._revealed_indices
        ):
            self._revealed_indices.append(reveal_idx)

            # Only transition to NOMINATE after 2 cards revealed
            if len(self._revealed_indices) >= 2:
                self._phase = Phase.NOMINATE
                self._sub_phase = (
                    "industry_commit_1"  # Start with industry's first nomination
                )
            self._advisor_commits = {"industry": [], "urbanist": []}

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
        """Mayor places a card on a nominated hex (up to 4 nominations)."""
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

        # Record turn history for deduction
        reality = self._reality.get(chosen_hex, {})
        scores_delta = {k: self._scores[k] - prev_scores[k] for k in self._scores}
        self._turn_history.append(
            {
                "turn": self._turn,
                "revealed_indices": self._revealed_indices.copy(),
                "nominations": [n.copy() for n in self._nominations],
                "build": {"hex": chosen_hex, "card": placed_card.copy()},
                "reality": reality.copy(),
                "scores_delta": scores_delta,
            }
        )

        # Check for mine (spade reality)
        reality = self._reality.get(chosen_hex, {})
        if reality.get("suit") == Suit.SPADES:
            self._is_terminal = True
            return

        # Discard placed card and prepare next turn
        self._discard.append(placed_card)
        del self._hand[card_idx]

        self._turn += 1
        if self._turn >= self._game.max_turns:
            self._is_terminal = True
            return

        # Start new turn
        self._phase = Phase.DRAW
        self._hand = []
        self._revealed_indices = []
        self._pending_draws = 4  # Mayor draws 4 cards
        self._sub_phase = "drawing"
        self._nominations = []

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
        - Mayor scores 1 if placed suit matches reality suit AND best distance choice

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
                    pass  # Honest warning = 0 points (no reward for finding mines)
                else:
                    self._scores[advisor] -= 2  # Lied about mine, severe penalty
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
                # about a mine - nobody scores (skip advisor scoring entirely)
                if used_domain_affinity_for_spades and reality_suit != Suit.SPADES:
                    pass  # No winner - both lied about mine
                elif placed_suit == claim_suit:
                    # Mayor TRUSTED (played same suit as claimed)
                    self._scores[advisor] += 1
                else:
                    # Mayor CALLED (played different suit than claimed)
                    if claim_suit == reality_suit:
                        # Advisor was honest but Mayor didn't believe them
                        self._scores[advisor] += 1
                    # else: Advisor bluffed AND Mayor caught it - 0 points

        # MAYOR SCORING - optimal distance calculation
        # Mayor scores only if they found the optimal build among ALL hand cards
        if not is_mine:
            # Calculate the distance the Mayor actually achieved
            chosen_distance = float("inf")
            if placed_suit == reality_suit:
                chosen_distance = abs(placed_value - reality_value)

            # Find the global minimum distance across ALL hand cards × ALL nominations
            global_best_distance = float("inf")
            for hand_card in self._hand:
                hand_suit = hand_card.get("suit", -1)
                hand_value = hand_card.get("value", 0)
                for nom in self._nominations:
                    if not nom or nom.get("hex") == INVALID_HEX:
                        continue
                    nom_hex = nom["hex"]
                    nom_reality = self._reality.get(nom_hex, {})
                    # Skip spade realities (game-ending)
                    if nom_reality.get("suit") == Suit.SPADES:
                        continue
                    if nom_reality.get("suit") == hand_suit:
                        dist = abs(hand_value - nom_reality.get("value", 0))
                        global_best_distance = min(global_best_distance, dist)

            # Mayor scores only if their choice equals the best possible
            # AND they actually had a valid suit match (chosen_distance < inf)
            if (
                chosen_distance < float("inf")
                and chosen_distance <= global_best_distance
            ):
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
