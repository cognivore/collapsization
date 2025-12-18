"""Unit tests for Collapsization agents."""

import pytest
import random
import sys
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from collapsization import CollapsizationGame, Role, Phase
from collapsization.game import ACTION_CONTROL_SUIT_A
from agents import (
    RandomAgent,
    ScriptedAdvisorAgent,
    ScriptedMayorAgent,
    play_random_game,
)


class TestRandomAgent:
    """Test random agent implementation."""

    def test_create_random_agent(self):
        agent = RandomAgent(Role.MAYOR)
        assert agent is not None
        assert agent.player_id == Role.MAYOR

    def test_random_agent_returns_legal_action(self):
        """Random agent should always return a legal action."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process chance nodes
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            state.apply_action(outcomes[0][0])

        agent = RandomAgent(Role.MAYOR, seed=42)
        action = agent.step(state)

        legal = state.legal_actions()
        assert action in legal

    def test_play_random_game_returns_scores(self):
        """play_random_game should return a list of 3 scores."""
        game = CollapsizationGame()
        scores = play_random_game(game, seed=42)

        assert len(scores) == 3
        assert all(isinstance(s, float) for s in scores)


class TestScriptedMayorAgent:
    """Test scripted mayor agent."""

    def test_create_scripted_mayor(self):
        agent = ScriptedMayorAgent(Role.MAYOR)
        assert agent is not None

    def test_scripted_mayor_wrong_role_raises(self):
        """ScriptedMayorAgent should raise for non-mayor role."""
        with pytest.raises(ValueError):
            ScriptedMayorAgent(Role.INDUSTRY)

    def test_scripted_mayor_returns_legal_action(self):
        """Scripted mayor should return a legal action."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process chance nodes
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            state.apply_action(outcomes[0][0])

        agent = ScriptedMayorAgent(Role.MAYOR, seed=42)
        action = agent.step(state)

        legal = state.legal_actions()
        assert action in legal


class TestScriptedAdvisorAgent:
    """Test scripted advisor agent."""

    def test_create_scripted_industry(self):
        agent = ScriptedAdvisorAgent(Role.INDUSTRY)
        assert agent is not None
        assert agent.role == Role.INDUSTRY

    def test_create_scripted_urbanist(self):
        agent = ScriptedAdvisorAgent(Role.URBANIST)
        assert agent is not None
        assert agent.role == Role.URBANIST

    def test_scripted_advisor_wrong_role_raises(self):
        """ScriptedAdvisorAgent should raise for mayor role."""
        with pytest.raises(ValueError):
            ScriptedAdvisorAgent(Role.MAYOR)

    def test_scripted_advisor_returns_legal_action(self):
        """Scripted advisor should return a legal action in nominate phase."""
        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process chance nodes (deal cards)
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            state.apply_action(outcomes[0][0])

        # Mayor reveals 2 cards
        for _ in range(2):
            legal = state.legal_actions()
            state.apply_action(legal[0])

        # Mayor chooses control mode (transitions to NOMINATE)
        assert state._phase == Phase.CONTROL
        state.apply_action(ACTION_CONTROL_SUIT_A)

        # Now industry's turn in nominate phase
        assert state._phase == Phase.NOMINATE
        assert state.current_player() == Role.INDUSTRY

        agent = ScriptedAdvisorAgent(Role.INDUSTRY, seed=42)
        action = agent.step(state)

        legal = state.legal_actions()
        assert action in legal


class TestAgentGameplay:
    """Test full games with agents."""

    def test_scripted_vs_scripted_game(self):
        """Run a full game with scripted agents."""
        game = CollapsizationGame()
        state = game.new_initial_state()
        rng = random.Random(42)

        agents = {
            Role.MAYOR: ScriptedMayorAgent(Role.MAYOR, seed=42),
            Role.INDUSTRY: ScriptedAdvisorAgent(Role.INDUSTRY, seed=42),
            Role.URBANIST: ScriptedAdvisorAgent(Role.URBANIST, seed=42),
        }

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
                player = state.current_player()
                agent = agents.get(Role(player))
                if agent:
                    action = agent.step(state)
                else:
                    action = rng.choice(state.legal_actions())
            state.apply_action(action)

        assert state.is_terminal()
        returns = state.returns()
        assert len(returns) == 3

    def test_multiple_random_games(self):
        """Run multiple random games to check stability."""
        game = CollapsizationGame()

        for seed in range(10):
            scores = play_random_game(game, seed=seed)
            assert len(scores) == 3


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
