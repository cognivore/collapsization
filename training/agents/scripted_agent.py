"""Scripted baseline agents ported from GDScript game_rules.gd.

These implement the strategic bot logic:
- SPADES revealed: Both nominate best of THEIR suit (Urb->Hearts, Ind->Diamonds)
- HEARTS revealed: Urbanist honest (best heart), Industry LIES (claims urbanist's heart is spade)
- DIAMONDS revealed: Industry honest (best diamond), Urbanist varies (50% warn spade, 25% accuse, 25% medium diamond)
"""

import random
from typing import Optional

import pyspiel

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from collapsization.constants import (
    Suit,
    Role,
    NUM_CARDS,
    NUM_RANKS,
    card_to_index,
    index_to_card,
    make_card,
)
from collapsization.game import (
    ACTION_REVEAL_BASE,
    ACTION_COMMIT_BASE,
    ACTION_BUILD_BASE,
)


class ScriptedAdvisorAgent:
    """Strategic advisor agent ported from GDScript pick_strategic_nomination.

    Strategy Matrix:
    - SPADES revealed: Both nominate best of THEIR suit (Urb->Hearts, Ind->Diamonds)
    - HEARTS revealed: Urbanist honest (best heart), Industry LIES (claims urbanist's heart is spade)
    - DIAMONDS revealed: Industry honest (best diamond), Urbanist varies

    Updated for 2 nominations per advisor: First nomination uses primary strategy,
    second nomination uses secondary/alternative options.
    """

    def __init__(self, player_id: int, seed: Optional[int] = None):
        if player_id not in (Role.INDUSTRY, Role.URBANIST):
            raise ValueError(
                f"ScriptedAdvisorAgent requires advisor role, got {player_id}"
            )
        self.player_id = player_id
        self.role = Role(player_id)
        self._rng = random.Random(seed)

    def _is_second_nomination(self, state) -> bool:
        """Check if this is the second nomination for this advisor."""
        return state._sub_phase in ("industry_commit_2", "urbanist_commit_2")

    def _get_first_nominated_hex(self, state) -> tuple:
        """Get the hex nominated in the first nomination."""
        role_key = "industry" if self.role == Role.INDUSTRY else "urbanist"
        commits = state._advisor_commits.get(role_key, [])
        if commits:
            return commits[0].get("hex")
        return None

    def step(self, state: pyspiel.State) -> int:
        """Select action based on strategic rules."""
        legal_actions = state.legal_actions(self.player_id)
        if not legal_actions:
            raise ValueError(f"No legal actions for player {self.player_id}")

        # Track if this is second nomination (use alternate strategy)
        is_second = self._is_second_nomination(state)
        first_hex = self._get_first_nominated_hex(state) if is_second else None

        # Get game state info
        revealed_card = self._get_revealed_card(state)
        if revealed_card is None:
            return self._rng.choice(legal_actions)

        revealed_suit = revealed_card.get("suit", -1)
        revealed_value = revealed_card.get("value", 7)

        # Get visible reality tiles
        frontier = state._get_playable_frontier()
        reality_tiles = {
            h: state._reality.get(h, {}) for h in frontier if h in state._reality
        }

        # Categorize hexes by suit
        hearts = []
        diamonds = []
        spades = []

        for hex_coord, card in reality_tiles.items():
            suit = card.get("suit", -1)
            value = card.get("value", 0)
            entry = {"hex": hex_coord, "card": card, "value": value}
            if suit == Suit.HEARTS:
                hearts.append(entry)
            elif suit == Suit.DIAMONDS:
                diamonds.append(entry)
            elif suit == Suit.SPADES:
                spades.append(entry)

        # Sort by value (highest first)
        hearts.sort(key=lambda x: -x["value"])
        diamonds.sort(key=lambda x: -x["value"])
        spades.sort(key=lambda x: -x["value"])

        # For second nomination, filter out already-nominated hex
        if first_hex is not None:
            hearts = [h for h in hearts if h["hex"] != first_hex]
            diamonds = [d for d in diamonds if d["hex"] != first_hex]
            spades = [s for s in spades if s["hex"] != first_hex]

        # Get my suit
        my_suit = Suit.DIAMONDS if self.role == Role.INDUSTRY else Suit.HEARTS

        # Apply strategy based on revealed suit and role
        # For second nomination, use secondary options (index 1 or different suit)
        chosen_hex = None
        claim_card = None
        strategy = "fallback"

        # Helper to pick best available from list
        def pick_best(options, idx=0):
            if len(options) > idx:
                return options[idx]
            elif options:
                return options[0]
            return None

        if revealed_suit == Suit.SPADES:
            # Both nominate best of THEIR suit - honest claims
            if self.role == Role.INDUSTRY:
                pick = pick_best(diamonds, 1 if is_second else 0)
                if pick:
                    chosen_hex = pick["hex"]
                    claim_card = pick["card"]
                    strategy = "best_diamond_on_spade"
            else:  # Urbanist
                pick = pick_best(hearts, 1 if is_second else 0)
                if pick:
                    chosen_hex = pick["hex"]
                    claim_card = pick["card"]
                    strategy = "best_heart_on_spade"

        elif revealed_suit == Suit.HEARTS:
            if self.role == Role.URBANIST:
                # Honest - best heart (or second-best for second nom)
                pick = pick_best(hearts, 1 if is_second else 0)
                if pick:
                    chosen_hex = pick["hex"]
                    claim_card = pick["card"]
                    strategy = "honest_heart"
            else:  # Industry
                # LIE: nominate a heart and claim it's spade
                # For second nom, try a different heart or fall back
                pick = pick_best(hearts, 1 if is_second else 0)
                if pick:
                    chosen_hex = pick["hex"]
                    lie_value = pick["value"]
                    claim_card = make_card(Suit.SPADES, self._value_to_rank(lie_value))
                    strategy = "lie_claim_spade"
                elif diamonds:
                    pick = pick_best(diamonds, 0)
                    chosen_hex = pick["hex"]
                    claim_card = pick["card"]
                    strategy = "fallback_diamond"

        elif revealed_suit == Suit.DIAMONDS:
            if self.role == Role.INDUSTRY:
                # Honest - best diamond (or second-best)
                pick = pick_best(diamonds, 1 if is_second else 0)
                if pick:
                    chosen_hex = pick["hex"]
                    claim_card = pick["card"]
                    strategy = "honest_diamond"
            else:  # Urbanist - varied strategy
                roll = self._rng.random()
                if roll < 0.5 and spades:
                    # 50%: Warn about real spade - honest
                    pick = pick_best(spades, 1 if is_second else 0)
                    if pick:
                        chosen_hex = pick["hex"]
                        claim_card = pick["card"]
                        strategy = "warn_spade"
                elif roll < 0.75 and diamonds:
                    # 25%: Accuse industry of lying - claim diamond is spade
                    pick = pick_best(diamonds, 1 if is_second else 0)
                    if pick:
                        chosen_hex = pick["hex"]
                        lie_value = pick["value"]
                        claim_card = make_card(
                            Suit.SPADES, self._value_to_rank(lie_value)
                        )
                        strategy = "accuse_industry"
                elif diamonds:
                    # 25%: Disclose medium diamond honestly
                    mid_idx = len(diamonds) // 2
                    if is_second and len(diamonds) > mid_idx + 1:
                        mid_idx += 1
                    pick = diamonds[mid_idx] if mid_idx < len(diamonds) else diamonds[0]
                    chosen_hex = pick["hex"]
                    claim_card = pick["card"]
                    strategy = "medium_diamond"
                elif hearts:
                    pick = pick_best(hearts, 1 if is_second else 0)
                    if pick:
                        chosen_hex = pick["hex"]
                        claim_card = pick["card"]
                        strategy = "fallback_heart"

        # Fallback if no strategy found
        if chosen_hex is None:
            all_available = hearts + diamonds + spades
            if all_available:
                chosen = all_available[0]
                chosen_hex = chosen["hex"]
                lie_value = revealed_value if revealed_value > 0 else 7
                claim_card = make_card(my_suit, self._value_to_rank(lie_value))
                strategy = "desperate_lie"
            elif frontier:
                chosen_hex = frontier[0]
                lie_value = revealed_value if revealed_value > 0 else 7
                claim_card = make_card(my_suit, self._value_to_rank(lie_value))
                strategy = "blind_fallback"

        # Convert to action
        if chosen_hex is None or claim_card is None:
            return self._rng.choice(legal_actions)

        return self._hex_claim_to_action(
            chosen_hex, claim_card, frontier, legal_actions
        )

    def _get_revealed_card(self, state: pyspiel.State) -> Optional[dict]:
        """Get the mayor's revealed card from state."""
        # Use _revealed_indices (list) instead of _revealed_index
        if hasattr(state, "_revealed_indices") and state._revealed_indices:
            idx = state._revealed_indices[0]
            if 0 <= idx < len(state._hand):
                return state._hand[idx]
        # Fallback to old attribute name for compatibility
        elif hasattr(state, "_revealed_index"):
            if state._revealed_index >= 0 and state._revealed_index < len(state._hand):
                return state._hand[state._revealed_index]
        return None

    def _value_to_rank(self, value: int) -> str:
        """Convert numeric value to rank string."""
        value_to_rank = {
            2: "2",
            3: "3",
            4: "4",
            5: "5",
            6: "6",
            7: "7",
            8: "8",
            9: "9",
            10: "10",
            11: "J",
            12: "K",
            13: "Q",
            14: "A",
        }
        return value_to_rank.get(value, "7")

    def _hex_claim_to_action(
        self,
        hex_coord: tuple,
        claim_card: dict,
        frontier: list,
        legal_actions: list[int],
    ) -> int:
        """Convert hex + claim to action ID."""
        try:
            hex_idx = frontier.index(hex_coord)
        except ValueError:
            # Hex not in frontier, fall back to random
            return random.choice(legal_actions)

        claim_idx = card_to_index(claim_card)
        if claim_idx < 0:
            claim_idx = 0

        action = ACTION_COMMIT_BASE + hex_idx * NUM_CARDS + claim_idx
        if action in legal_actions:
            return action

        # If exact action not legal, find closest
        return min(legal_actions, key=lambda a: abs(a - action))

    def reset(self):
        """Reset agent state."""
        pass


class ScriptedMayorAgent:
    """Simple mayor agent that tries to match suits and avoid mines."""

    def __init__(self, player_id: int = Role.MAYOR, seed: Optional[int] = None):
        if player_id != Role.MAYOR:
            raise ValueError(f"ScriptedMayorAgent requires mayor role, got {player_id}")
        self.player_id = player_id
        self._rng = random.Random(seed)

    def step(self, state: pyspiel.State) -> int:
        """Select action based on simple heuristics."""
        legal_actions = state.legal_actions(self.player_id)
        if not legal_actions:
            raise ValueError(f"No legal actions for player {self.player_id}")

        # In reveal phase, prefer revealing a non-spade card
        if state._phase.value == 1:  # DRAW phase
            return self._handle_reveal(state, legal_actions)

        # In place phase, prefer non-spade cards and trust advisor claims
        if state._phase.value == 3:  # PLACE phase
            return self._handle_place(state, legal_actions)

        return self._rng.choice(legal_actions)

    def _handle_reveal(self, state: pyspiel.State, legal_actions: list[int]) -> int:
        """Choose which card to reveal."""
        # Prefer revealing a non-spade, high-value card
        best_action = None
        best_score = -1

        for action in legal_actions:
            card_idx = action - ACTION_REVEAL_BASE
            if 0 <= card_idx < len(state._hand):
                card = state._hand[card_idx]
                suit = card.get("suit", -1)
                value = card.get("value", 0)

                # Score: avoid spades, prefer high values
                score = value if suit != Suit.SPADES else -10
                if score > best_score:
                    best_score = score
                    best_action = action

        return (
            best_action if best_action is not None else self._rng.choice(legal_actions)
        )

    def _handle_place(self, state: pyspiel.State, legal_actions: list[int]) -> int:
        """Choose which card to place and where."""
        # Simple heuristic: trust advisor claims, avoid placing spades
        best_action = None
        best_score = -100

        for action in legal_actions:
            place_idx = action - ACTION_BUILD_BASE
            card_idx = place_idx // 2
            nom_idx = place_idx % 2

            if card_idx >= len(state._hand):
                continue

            card = state._hand[card_idx]
            card_suit = card.get("suit", -1)
            card_value = card.get("value", 0)

            # Get nomination info
            nominations = list(state._nominations.values())
            if nom_idx >= len(nominations):
                continue

            nom = nominations[nom_idx]
            claim = nom.get("claim", {})
            claim_suit = claim.get("suit", -1)
            claim_value = claim.get("value", 0)

            # Score calculation
            score = 0

            # Heavily penalize placing spades
            if card_suit == Suit.SPADES:
                score -= 50

            # Bonus for matching claim suit
            if card_suit == claim_suit:
                score += 10
                # Extra bonus for close value match
                score += max(0, 15 - abs(card_value - claim_value))

            # Trust claims that match card suit
            if card_suit != Suit.SPADES and claim_suit == card_suit:
                score += 5

            if score > best_score:
                best_score = score
                best_action = action

        return (
            best_action if best_action is not None else self._rng.choice(legal_actions)
        )

    def reset(self):
        """Reset agent state."""
        pass
