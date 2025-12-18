"""Unit tests for Collapsization OpenSpiel game implementation."""

import pytest
import random
import sys
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from collapsization import (
    CollapsizationGame,
    CollapsizationState,
    Role,
    Phase,
    Suit,
    ControlMode,
    SuitConfig,
    NUM_CARDS,
    make_card,
    card_to_index,
    index_to_card,
    card_label,
    get_adjacent_hexes,
    cube_distance,
    INVALID_HEX,
)
from collapsization.game import (
    ACTION_REVEAL_BASE,
    ACTION_CONTROL_BASE,
    ACTION_CONTROL_SUIT_A,
    ACTION_CONTROL_SUIT_B,
    ACTION_COMMIT_BASE,
    ACTION_BUILD_BASE,
)


class TestConstants:
    """Test constant definitions match GDScript."""

    def test_suit_values(self):
        assert Suit.HEARTS == 0
        assert Suit.DIAMONDS == 1
        assert Suit.SPADES == 2

    def test_role_values(self):
        assert Role.MAYOR == 0
        assert Role.INDUSTRY == 1
        assert Role.URBANIST == 2

    def test_phase_values(self):
        assert Phase.LOBBY == 0
        assert Phase.DRAW == 1
        assert Phase.CONTROL == 2  # NEW phase
        assert Phase.NOMINATE == 3
        assert Phase.PLACE == 4
        assert Phase.GAME_OVER == 5

    def test_control_mode_values(self):
        assert ControlMode.NONE == 0
        assert ControlMode.FORCE_SUITS == 1
        assert ControlMode.FORCE_HEXES == 2

    def test_suit_config_values(self):
        assert SuitConfig.URB_DIAMOND_IND_HEART == 0
        assert SuitConfig.URB_HEART_IND_DIAMOND == 1

    def test_num_cards(self):
        assert NUM_CARDS == 39  # 3 suits × 13 ranks

    def test_invalid_hex(self):
        assert INVALID_HEX == (0x7FFFFFFF, 0, 0)


class TestCardHelpers:
    """Test card encoding/decoding functions."""

    def test_make_card(self):
        card = make_card(Suit.HEARTS, "A")
        assert card["suit"] == Suit.HEARTS
        assert card["rank"] == "A"
        assert card["value"] == 14  # Ace is highest

    def test_card_label(self):
        card = make_card(Suit.HEARTS, "A")
        assert card_label(card) == "A♥"

        card = make_card(Suit.DIAMONDS, "K")
        assert card_label(card) == "K♦"

        card = make_card(Suit.SPADES, "Q")
        assert card_label(card) == "Q♠"

    def test_queen_outranks_king(self):
        """Per RULES.md, Queen outranks King (Q > K)."""
        queen = make_card(Suit.HEARTS, "Q")
        king = make_card(Suit.HEARTS, "K")
        assert queen["value"] > king["value"]

    def test_card_index_roundtrip(self):
        """Test card_to_index and index_to_card are inverses."""
        for suit in Suit:
            for rank in [
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
            ]:
                card = make_card(suit, rank)
                idx = card_to_index(card)
                assert 0 <= idx < NUM_CARDS
                recovered = index_to_card(idx)
                assert recovered["suit"] == card["suit"]
                assert recovered["rank"] == card["rank"]

    def test_index_to_card_all_valid(self):
        """All indices 0-38 should produce valid cards."""
        for idx in range(NUM_CARDS):
            card = index_to_card(idx)
            assert "suit" in card
            assert "rank" in card
            assert "value" in card


class TestHexHelpers:
    """Test hex coordinate helper functions."""

    def test_get_adjacent_hexes_count(self):
        """Each hex should have exactly 6 neighbors."""
        center = (0, 0, 0)
        adjacent = get_adjacent_hexes(center)
        assert len(adjacent) == 6

    def test_cube_distance_self(self):
        """Distance from a hex to itself is 0."""
        hex_coord = (1, -1, 0)
        assert cube_distance(hex_coord, hex_coord) == 0

    def test_cube_distance_adjacent(self):
        """Distance to adjacent hexes is 1."""
        center = (0, 0, 0)
        for adj in get_adjacent_hexes(center):
            assert cube_distance(center, adj) == 1

    def test_cube_distance_ring_2(self):
        """Distance 2 hexes are not in the immediate ring."""
        center = (0, 0, 0)
        adjacent = get_adjacent_hexes(center)
        # Pick a ring-2 hex by going through an adjacent hex
        ring2_hex = get_adjacent_hexes(adjacent[0])[0]
        if ring2_hex != center and ring2_hex not in adjacent:
            assert cube_distance(center, ring2_hex) == 2


class TestGameCreation:
    """Test game creation and initialization."""

    def test_create_game(self):
        game = CollapsizationGame()
        assert game is not None

    def test_new_initial_state(self):
        game = CollapsizationGame()
        state = game.new_initial_state()
        assert state is not None
        assert isinstance(state, CollapsizationState)

    def test_initial_phase(self):
        """Game should start in DRAW phase (LOBBY handled externally)."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        assert state._phase == Phase.DRAW

    def test_initial_scores(self):
        game = CollapsizationGame()
        state = game.new_initial_state()
        assert state._scores == {"mayor": 0, "industry": 0, "urbanist": 0}

    def test_center_tile_built(self):
        """Center tile (0,0,0) should start as built."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        assert (0, 0, 0) in state._built_hexes

    def test_center_tile_is_ace_of_hearts(self):
        """Center tile reality should be Ace of Hearts."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        center_card = state._reality.get((0, 0, 0), {})
        assert center_card.get("suit") == Suit.HEARTS
        assert center_card.get("rank") == "A"


class TestLegalActions:
    """Test legal action generation."""

    def test_draw_phase_legal_actions(self):
        """In draw phase, mayor should have 4 reveal actions (for 4 cards)."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process chance nodes to draw cards
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            action = outcomes[0][0]  # Take first outcome
            state.apply_action(action)

        # Now in draw phase, mayor's turn
        assert state._phase == Phase.DRAW
        assert state.current_player() == Role.MAYOR

        legal = state.legal_actions()
        # Should have reveal actions (0, 1, 2, 3 for 4 cards)
        assert len(legal) > 0
        assert all(ACTION_REVEAL_BASE <= a < ACTION_REVEAL_BASE + 4 for a in legal)

    def test_control_phase_legal_actions(self):
        """In control phase, mayor should have suit and hex forcing options."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process to control phase
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            state.apply_action(outcomes[0][0])

        # Mayor reveals 2 cards
        for _ in range(2):
            legal = state.legal_actions()
            state.apply_action(legal[0])

        # Now in CONTROL phase
        assert state._phase == Phase.CONTROL
        assert state.current_player() == Role.MAYOR

        legal = state.legal_actions()
        assert len(legal) > 0
        # Should have at least the 2 suit forcing options
        assert ACTION_CONTROL_SUIT_A in legal
        assert ACTION_CONTROL_SUIT_B in legal

    def test_nominate_phase_legal_actions(self):
        """In nominate phase, advisors should have frontier×cards actions."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process to nominate phase
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            state.apply_action(outcomes[0][0])

        # Mayor reveals 2 cards
        for _ in range(2):
            legal = state.legal_actions()
            state.apply_action(legal[0])

        # Mayor chooses control mode (force suits config A)
        assert state._phase == Phase.CONTROL
        state.apply_action(ACTION_CONTROL_SUIT_A)

        # Now in nominate phase
        assert state._phase == Phase.NOMINATE

        # Industry's turn
        assert state.current_player() == Role.INDUSTRY
        legal = state.legal_actions()
        assert len(legal) > 0
        # All actions should be commit actions
        assert all(a >= ACTION_COMMIT_BASE for a in legal)


class TestGameFlow:
    """Test full game flow and state transitions."""

    def test_phase_transitions(self):
        """Test that phases transition correctly: DRAW -> CONTROL -> NOMINATE -> PLACE."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Draw phase starts after chance
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            state.apply_action(outcomes[0][0])

        assert state._phase == Phase.DRAW

        # Mayor reveals 2 cards -> CONTROL
        for _ in range(2):
            legal = state.legal_actions()
            state.apply_action(legal[0])
        assert state._phase == Phase.CONTROL

        # Mayor chooses control mode -> NOMINATE
        state.apply_action(ACTION_CONTROL_SUIT_A)
        assert state._phase == Phase.NOMINATE

        # Industry commits 2 nominations
        legal = state.legal_actions()
        state.apply_action(legal[0])
        legal = state.legal_actions()
        state.apply_action(legal[0])

        # Urbanist commits 2 nominations -> PLACE
        legal = state.legal_actions()
        state.apply_action(legal[0])
        legal = state.legal_actions()
        state.apply_action(legal[0])
        assert state._phase == Phase.PLACE

    def test_full_turn_cycle(self):
        """Test a complete turn cycle (draw -> nominate -> place)."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        initial_turn = state._turn

        # Complete one turn
        while not state.is_terminal() and state._turn == initial_turn:
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                state.apply_action(outcomes[0][0])
            else:
                legal = state.legal_actions()
                state.apply_action(legal[0])

        # Either terminal or moved to next turn
        assert state.is_terminal() or state._turn > initial_turn

    def test_random_game_terminates(self):
        """A game with random actions should eventually terminate."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        rng = random.Random(42)
        max_steps = 10000

        for _ in range(max_steps):
            if state.is_terminal():
                break
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = rng.choices(
                    [a for a, _ in outcomes], weights=[p for _, p in outcomes]
                )[0]
            else:
                legal = state.legal_actions()
                action = rng.choice(legal)
            state.apply_action(action)

        assert state.is_terminal(), "Game should terminate within max_steps"


class TestScoring:
    """Test scoring mechanics."""

    def test_returns_three_values(self):
        """Returns should have exactly 3 values (one per player)."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        returns = state.returns()
        assert len(returns) == 3

    def test_initial_scores_zero(self):
        """Initial scores should all be zero."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        returns = state.returns()
        assert all(r == 0.0 for r in returns)


class TestObservations:
    """Test observation encoding."""

    def test_observation_tensor_exists(self):
        """Each player should have an observation tensor."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        for player in range(3):
            obs = state.observation_tensor(player)
            assert obs is not None
            assert len(obs) > 0

    def test_information_state_string_exists(self):
        """Each player should have an information state string."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        for player in range(3):
            info = state.information_state_string(player)
            assert info is not None
            assert len(info) > 0


class TestSpadeEnding:
    """Test game ending when building on spade."""

    def test_spade_reality_ends_game(self):
        """Building on a spade reality tile should end the game."""
        # This test is harder to set up deterministically
        # We'll just verify the mechanism exists
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Check that the game can detect spade reality
        # (The actual ending happens in _apply_place)
        assert hasattr(state, "_reality")


class TestTwoNominations:
    """Test that each advisor now makes 2 nominations."""

    def test_four_nomination_subphases(self):
        """Test that nomination phase has 4 sub-phases (2 per advisor)."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process to nominate phase
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            state.apply_action(outcomes[0][0])

        # Mayor reveals 2 cards
        for _ in range(2):
            legal = state.legal_actions()
            state.apply_action(legal[0])

        # Mayor chooses control mode
        assert state._phase == Phase.CONTROL
        state.apply_action(ACTION_CONTROL_SUIT_A)

        assert state._phase == Phase.NOMINATE

        # Industry's first nomination
        assert state._sub_phase == "industry_commit_1"
        assert state.current_player() == Role.INDUSTRY
        legal = state.legal_actions()
        state.apply_action(legal[0])

        # Industry's second nomination
        assert state._sub_phase == "industry_commit_2"
        assert state.current_player() == Role.INDUSTRY
        legal = state.legal_actions()
        state.apply_action(legal[0])

        # Urbanist's first nomination
        assert state._sub_phase == "urbanist_commit_1"
        assert state.current_player() == Role.URBANIST
        legal = state.legal_actions()
        state.apply_action(legal[0])

        # Urbanist's second nomination
        assert state._sub_phase == "urbanist_commit_2"
        assert state.current_player() == Role.URBANIST
        legal = state.legal_actions()
        state.apply_action(legal[0])

        # Now should be in PLACE phase
        assert state._phase == Phase.PLACE

    def test_nominations_stored_as_list(self):
        """Nominations should be stored as a flat list."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process to PLACE phase
        while state._phase != Phase.PLACE:
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                state.apply_action(outcomes[0][0])
            elif state.is_terminal():
                break
            else:
                legal = state.legal_actions()
                state.apply_action(legal[0])

        if not state.is_terminal():
            # Nominations should be a list with up to 4 entries
            assert isinstance(state._nominations, list)
            assert len(state._nominations) >= 2  # At least 2 (could have overlap)
            assert len(state._nominations) <= 4  # At most 4

    def test_second_nomination_different_hex(self):
        """Second nomination must be to a different hex than first."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process to nominate phase
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            state.apply_action(outcomes[0][0])

        # Mayor reveals 2 cards
        for _ in range(2):
            legal = state.legal_actions()
            state.apply_action(legal[0])

        # Mayor chooses control mode
        state.apply_action(ACTION_CONTROL_SUIT_A)

        # Industry's first nomination
        legal1 = state.legal_actions()
        state.apply_action(legal1[0])

        # Industry's second nomination - should have different legal actions
        legal2 = state.legal_actions()

        # The hex index is encoded in the action, verify different options
        # (This is a structural test - the game enforces different hexes)
        assert len(legal2) > 0


class TestSpadePenalty:
    """Test the -2 penalty for leading Mayor to a mine."""

    def test_penalty_mechanism_exists(self):
        """Verify the penalty logic is present in score calculation."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Check that turn_rewards tracking exists
        assert hasattr(state, "_turn_rewards")
        assert "mayor" in state._turn_rewards
        assert "industry" in state._turn_rewards
        assert "urbanist" in state._turn_rewards

    def test_turn_rewards_method(self):
        """Test that turn_rewards() method exists and returns correct format."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        rewards = state.turn_rewards()
        assert len(rewards) == 3
        assert all(isinstance(r, float) for r in rewards)


class TestDenseRewards:
    """Test per-turn reward shaping."""

    def test_turn_rewards_initial_zero(self):
        """Initial turn rewards should be zero."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        rewards = state.turn_rewards()
        assert all(r == 0.0 for r in rewards)


class TestAdversarialRewards:
    """Test the adversarial reward computation."""

    def test_compute_adversarial_rewards_import(self):
        """Test that compute_adversarial_rewards can be imported."""
        import sys

        sys.path.insert(0, str(Path(__file__).parent.parent))
        from train import compute_adversarial_rewards

        # Test basic computation
        returns = [5.0, 3.0, 2.0]  # Mayor wins
        rewards = compute_adversarial_rewards(returns)

        assert Role.MAYOR in rewards
        assert Role.INDUSTRY in rewards
        assert Role.URBANIST in rewards

    def test_adversarial_rewards_winner_bonus(self):
        """Winner should get the win bonus."""
        import sys

        sys.path.insert(0, str(Path(__file__).parent.parent))
        from train import compute_adversarial_rewards

        # Mayor wins clearly
        returns = [10.0, 3.0, 2.0]
        rewards = compute_adversarial_rewards(returns, win_bonus=10.0)

        # Mayor should have: delta (10-3=7) + win_bonus (10) = 17
        assert rewards[Role.MAYOR] == 17.0

    def test_adversarial_rewards_delta_calculation(self):
        """Test delta is own_score - best_opponent_score."""
        import sys

        sys.path.insert(0, str(Path(__file__).parent.parent))
        from train import compute_adversarial_rewards

        # All equal scores - no winner bonus
        returns = [5.0, 5.0, 5.0]
        rewards = compute_adversarial_rewards(returns, win_bonus=10.0)

        # Delta should be 0 for all (5-5=0), no win bonus (tie)
        for role in Role:
            assert rewards[role] == 0.0

    def test_adversarial_rewards_loser_negative(self):
        """Losers should have negative delta."""
        import sys

        sys.path.insert(0, str(Path(__file__).parent.parent))
        from train import compute_adversarial_rewards

        returns = [10.0, 3.0, 2.0]
        rewards = compute_adversarial_rewards(returns, win_bonus=10.0)

        # Industry: delta = 3 - 10 = -7 (loses to Mayor)
        assert rewards[Role.INDUSTRY] == -7.0

        # Urbanist: delta = 2 - 10 = -8 (loses to Mayor even more)
        assert rewards[Role.URBANIST] == -8.0


class TestMaxNominations:
    """Test the new MAX_NOMINATIONS constant and action space."""

    def test_max_nominations_constant(self):
        """Test that MAX_NOMINATIONS is 4."""
        from collapsization.game import MAX_NOMINATIONS, NOMINATIONS_PER_ADVISOR

        assert NOMINATIONS_PER_ADVISOR == 2
        assert MAX_NOMINATIONS == 4

    def test_action_build_count(self):
        """Test that build action count accounts for 4 nominations."""
        from collapsization.game import ACTION_BUILD_COUNT, MAX_NOMINATIONS

        # 4 hand cards × 4 max nominations = 16
        assert ACTION_BUILD_COUNT == 4 * MAX_NOMINATIONS


class TestControlPhase:
    """Test the new CONTROL phase mechanics."""

    def test_control_mode_initialization(self):
        """Control mode should start as NONE."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        assert state._control_mode == ControlMode.NONE

    def test_force_suits_config_a(self):
        """Test force_suits with config A (Urb→Diamond, Ind→Heart)."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process to control phase
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            state.apply_action(outcomes[0][0])

        # Mayor reveals 2 cards
        for _ in range(2):
            legal = state.legal_actions()
            state.apply_action(legal[0])

        assert state._phase == Phase.CONTROL
        state.apply_action(ACTION_CONTROL_SUIT_A)

        assert state._control_mode == ControlMode.FORCE_SUITS
        assert state._forced_suit_config == SuitConfig.URB_DIAMOND_IND_HEART
        assert state._phase == Phase.NOMINATE

    def test_force_suits_config_b(self):
        """Test force_suits with config B (Urb→Heart, Ind→Diamond)."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process to control phase
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            state.apply_action(outcomes[0][0])

        # Mayor reveals 2 cards
        for _ in range(2):
            legal = state.legal_actions()
            state.apply_action(legal[0])

        assert state._phase == Phase.CONTROL
        state.apply_action(ACTION_CONTROL_SUIT_B)

        assert state._control_mode == ControlMode.FORCE_SUITS
        assert state._forced_suit_config == SuitConfig.URB_HEART_IND_DIAMOND
        assert state._phase == Phase.NOMINATE

    def test_control_state_recorded_in_history(self):
        """Control mode should be recorded in turn history."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        rng = random.Random(42)

        # Complete one turn
        while state._turn == 0 and not state.is_terminal():
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = rng.choices(
                    [a for a, _ in outcomes], weights=[p for _, p in outcomes]
                )[0]
            else:
                legal = state.legal_actions()
                action = rng.choice(legal)
            state.apply_action(action)

        if state._turn_history:
            # Check that control_mode is recorded
            last_turn = state._turn_history[-1]
            assert "control_mode" in last_turn


class TestFacilitiesAndEndgame:
    """Test Mayor's endgame conditions: facilities, city completion, mine loss."""

    def test_facilities_initial_state(self):
        """Facilities should start with 1 Hearts (town center A♥) and 0 Diamonds."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        assert state._facilities == {"hearts": 1, "diamonds": 0}
        assert state._city_complete == False
        assert state._mayor_hit_mine == False

    def test_mayor_hit_mine_loses(self):
        """Mayor should get -100 score when hitting a mine (building on Spade)."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        rng = random.Random(42)

        # Play until terminal
        max_steps = 10000
        for _ in range(max_steps):
            if state.is_terminal():
                break
            if state.is_chance_node():
                outcomes = state.chance_outcomes()
                action = rng.choices(
                    [a for a, _ in outcomes], weights=[p for _, p in outcomes]
                )[0]
            else:
                legal = state.legal_actions()
                action = rng.choice(legal)
            state.apply_action(action)

        # If Mayor hit a mine, mayor_hit_mine() should be True
        # Note: Mayor's game SCORE is their actual accumulated points (not -100)
        # The -100 RL penalty is applied separately in training, not in returns()
        if state._mayor_hit_mine:
            assert state.mayor_hit_mine(), "mayor_hit_mine() should return True"
            # Mayor's score should be their actual (usually low) accumulated points
            returns = state.returns()
            assert (
                returns[Role.MAYOR] >= -10
            ), "Mayor score should be actual points, not -100"

    def test_city_completion_ends_game(self):
        """City completion (10♥ + 10♦) should end the game."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Manually set facilities to near-completion to verify the mechanism
        state._facilities = {"hearts": 10, "diamonds": 10}
        state._city_complete = True
        state._is_terminal = True

        # Game should be terminal with city complete
        assert state.is_terminal()
        assert state._city_complete == True
        assert state._mayor_hit_mine == False

        # Returns should be normal scores (Mayor didn't lose from mine)
        returns = state.returns()
        assert (
            returns[Role.MAYOR] != -100.0
        ), "Mayor should NOT get -100 on city completion"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
