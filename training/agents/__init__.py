"""Agent implementations for Collapsization training."""

from .random_agent import RandomAgent, play_random_game
from .scripted_agent import ScriptedAdvisorAgent, ScriptedMayorAgent

__all__ = [
    "RandomAgent",
    "play_random_game",
    "ScriptedAdvisorAgent",
    "ScriptedMayorAgent",
]

# Conditional import for learned agent (requires PyTorch)
try:
    from .learned_agent import LearnedAgent, PolicyNetwork, ValueNetwork

    __all__.extend(["LearnedAgent", "PolicyNetwork", "ValueNetwork"])
except ImportError:
    pass  # PyTorch not available
