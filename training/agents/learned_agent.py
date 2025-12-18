"""Learned agent wrapper for DQN/PPO policies.

IMPORTANT: Algorithm Choice and Limitations
===========================================

This module provides neural network architectures for policy learning in Collapsization.
The architecture is inspired by AlphaZero's ResNet policy-value network, but there are
critical differences:

1. NO MCTS (Monte Carlo Tree Search)
   AlphaZero's key innovation is MCTS guided by a neural network. We only borrow the
   network architecture and train with PPO (Proximal Policy Optimization).

2. IMPERFECT INFORMATION GAME
   Collapsization is registered as IMPERFECT_INFORMATION in OpenSpiel. This means:
   - Mayor cannot see reality tiles during decision-making
   - Advisors cannot see Mayor's full hand

   Standard MCTS assumes you can simulate the true game state, which is impossible
   here. Even if we implemented MCTS, it would be theoretically incorrect.

3. THEORETICALLY CORRECT ALTERNATIVES
   For imperfect information games, the gold-standard algorithms are:
   - CFR (Counterfactual Regret Minimization) → converges to Nash equilibrium
   - ISMCTS (Information Set MCTS) → adapts tree search to information sets
   - Deep CFR → neural network approximation of CFR

4. WHY PPO?
   We use PPO because it scales to our large state/action space (~4,500 actions).
   However, PPO provides NO CONVERGENCE GUARANTEES to Nash equilibrium. The learned
   policies may be exploitable by adversarial opponents.

5. NAMING CONVENTION
   The class was historically called "AlphaZeroNetwork" but is now renamed to
   "ResNetPolicyValueNetwork" for honesty. An alias is kept for backwards compatibility.
"""

from typing import Optional, Callable
import numpy as np

import pyspiel

try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    TORCH_AVAILABLE = True
except ImportError:
    TORCH_AVAILABLE = False


# ─────────────────────────────────────────────────────────────────────────────
# ResNet Policy-Value Architecture (inspired by AlphaZero, trained with PPO)
# ─────────────────────────────────────────────────────────────────────────────


class ResidualBlock(nn.Module):
    """Residual block with layer normalization for stable training.

    Uses LayerNorm instead of BatchNorm for better stability with small batch sizes
    and varying sequence lengths typical in RL.
    """

    def __init__(self, channels: int):
        super().__init__()
        self.fc1 = nn.Linear(channels, channels)
        self.ln1 = nn.LayerNorm(channels)
        self.fc2 = nn.Linear(channels, channels)
        self.ln2 = nn.LayerNorm(channels)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        residual = x
        x = F.relu(self.ln1(self.fc1(x)))
        x = self.ln2(self.fc2(x))
        return F.relu(x + residual)


class ResNetPolicyValueNetwork(nn.Module):
    """Combined policy-value network with shared ResNet trunk.

    Architecture borrowed from AlphaZero, but trained with PPO (not MCTS).

    Architecture:
    - Input projection layer
    - Stack of residual blocks (shared trunk)
    - Separate policy head (action logits)
    - Separate value head (state value)

    This shared trunk approach allows the network to learn features useful
    for both policy and value estimation, improving sample efficiency.

    NOTE: This is NOT a full AlphaZero implementation!
    - No MCTS tree search
    - Trained with policy gradient (PPO), not MCTS self-play
    - Does NOT guarantee convergence to Nash equilibrium
    - For imperfect information games like Collapsization, CFR-based
      algorithms would be theoretically more appropriate
    """

    def __init__(
        self,
        obs_size: int,
        num_actions: int,
        hidden_dim: int = 512,
        num_blocks: int = 8,
    ):
        super().__init__()
        self.obs_size = obs_size
        self.num_actions = num_actions
        self.hidden_dim = hidden_dim

        # Input projection: map observation to hidden dimension
        self.input_proj = nn.Sequential(
            nn.Linear(obs_size, hidden_dim),
            nn.LayerNorm(hidden_dim),
            nn.ReLU(),
        )

        # Shared residual trunk
        self.trunk = nn.Sequential(
            *[ResidualBlock(hidden_dim) for _ in range(num_blocks)]
        )

        # Policy head: outputs action logits
        self.policy_head = nn.Sequential(
            nn.Linear(hidden_dim, 256),
            nn.ReLU(),
            nn.Linear(256, num_actions),
        )

        # Value head: outputs scalar value estimate
        self.value_head = nn.Sequential(
            nn.Linear(hidden_dim, 128),
            nn.ReLU(),
            nn.Linear(128, 1),
            nn.Tanh(),  # Value in [-1, 1] for normalization
        )

    def forward(
        self, obs: torch.Tensor, legal_mask: Optional[torch.Tensor] = None
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Forward pass returning both policy logits and value.

        Args:
            obs: Observation tensor [batch, obs_size]
            legal_mask: Optional legal action mask [batch, num_actions]

        Returns:
            logits: Action logits [batch, num_actions]
            value: Value estimate [batch]
        """
        # Shared trunk
        x = self.input_proj(obs)
        x = self.trunk(x)

        # Policy head with optional masking
        logits = self.policy_head(x)
        if legal_mask is not None:
            # Mask out illegal actions with large negative value
            logits = logits + (1 - legal_mask) * (-1e9)

        # Value head
        value = self.value_head(x).squeeze(-1)

        return logits, value

    def policy_forward(
        self, obs: torch.Tensor, legal_mask: Optional[torch.Tensor] = None
    ) -> torch.Tensor:
        """Forward pass returning only policy logits (for compatibility)."""
        logits, _ = self.forward(obs, legal_mask)
        return logits

    def value_forward(self, obs: torch.Tensor) -> torch.Tensor:
        """Forward pass returning only value (for compatibility)."""
        _, value = self.forward(obs)
        return value


# Backwards compatibility alias (deprecated, use ResNetPolicyValueNetwork)
AlphaZeroNetwork = ResNetPolicyValueNetwork


# ─────────────────────────────────────────────────────────────────────────────
# Legacy MLP Architecture (kept for backward compatibility)
# ─────────────────────────────────────────────────────────────────────────────


class PolicyNetwork(nn.Module):
    """Simple MLP policy network with legal action masking."""

    def __init__(
        self, obs_size: int, num_actions: int, hidden_sizes: tuple = (256, 256)
    ):
        super().__init__()
        layers = []
        prev_size = obs_size
        for hidden_size in hidden_sizes:
            layers.extend(
                [
                    nn.Linear(prev_size, hidden_size),
                    nn.ReLU(),
                ]
            )
            prev_size = hidden_size
        layers.append(nn.Linear(prev_size, num_actions))
        self.net = nn.Sequential(*layers)

    def forward(
        self, obs: torch.Tensor, legal_mask: Optional[torch.Tensor] = None
    ) -> torch.Tensor:
        """Forward pass with optional legal action masking."""
        logits = self.net(obs)
        if legal_mask is not None:
            # Mask out illegal actions with large negative value
            logits = logits + (1 - legal_mask) * (-1e9)
        return logits


class LearnedAgent:
    """Agent that uses a learned policy network for action selection."""

    def __init__(
        self,
        player_id: int,
        policy_net: Optional["PolicyNetwork"] = None,
        obs_size: int = 0,
        num_actions: int = 0,
        epsilon: float = 0.0,  # Exploration rate
        device: str = "cpu",
    ):
        if not TORCH_AVAILABLE:
            raise ImportError("PyTorch is required for LearnedAgent")

        self.player_id = player_id
        self.device = torch.device(device)
        self.epsilon = epsilon

        if policy_net is not None:
            self.policy_net = policy_net.to(self.device)
        elif obs_size > 0 and num_actions > 0:
            self.policy_net = PolicyNetwork(obs_size, num_actions).to(self.device)
        else:
            raise ValueError(
                "Either policy_net or (obs_size, num_actions) must be provided"
            )

        self.policy_net.eval()

    def _get_num_actions(self) -> int:
        """Get number of actions from policy network."""
        if hasattr(self.policy_net, "num_actions"):
            return self.policy_net.num_actions  # ResNetPolicyValueNetwork
        elif hasattr(self.policy_net, "net"):
            return self.policy_net.net[-1].out_features  # PolicyNetwork
        else:
            raise ValueError("Cannot determine num_actions from policy_net")

    def step(self, state: pyspiel.State) -> int:
        """Select action using the policy network."""
        legal_actions = state.legal_actions(self.player_id)
        if not legal_actions:
            raise ValueError(f"No legal actions for player {self.player_id}")

        # Epsilon-greedy exploration
        if np.random.random() < self.epsilon:
            return np.random.choice(legal_actions)

        # Get observation
        obs = state.observation_tensor(self.player_id)
        obs_tensor = torch.tensor(
            obs, dtype=torch.float32, device=self.device
        ).unsqueeze(0)

        # Create legal action mask
        num_actions = self._get_num_actions()
        legal_mask = torch.zeros(1, num_actions, device=self.device)
        for a in legal_actions:
            if a < num_actions:
                legal_mask[0, a] = 1.0

        # Get action from policy
        with torch.no_grad():
            output = self.policy_net(obs_tensor, legal_mask)
            # Handle both PolicyNetwork (returns logits) and ResNetPolicyValueNetwork (returns logits, value)
            if isinstance(output, tuple):
                logits = output[0]  # ResNetPolicyValueNetwork returns (logits, value)
            else:
                logits = output
            probs = torch.softmax(logits, dim=-1)
            action = torch.argmax(probs, dim=-1).item()

        # Ensure action is legal
        if action not in legal_actions:
            action = legal_actions[0]

        return action

    def get_action_probs(self, state: pyspiel.State) -> np.ndarray:
        """Get action probabilities for all actions."""
        legal_actions = state.legal_actions(self.player_id)

        obs = state.observation_tensor(self.player_id)
        obs_tensor = torch.tensor(
            obs, dtype=torch.float32, device=self.device
        ).unsqueeze(0)

        num_actions = self._get_num_actions()
        legal_mask = torch.zeros(1, num_actions, device=self.device)
        for a in legal_actions:
            if a < num_actions:
                legal_mask[0, a] = 1.0

        with torch.no_grad():
            output = self.policy_net(obs_tensor, legal_mask)
            if isinstance(output, tuple):
                logits = output[0]
            else:
                logits = output
            probs = torch.softmax(logits, dim=-1).squeeze(0).cpu().numpy()

        return probs

    def load_checkpoint(self, path: str):
        """Load policy network weights from checkpoint."""
        checkpoint = torch.load(path, map_location=self.device)
        if "policy_net" in checkpoint:
            self.policy_net.load_state_dict(checkpoint["policy_net"])
        else:
            self.policy_net.load_state_dict(checkpoint)
        self.policy_net.eval()

    def save_checkpoint(self, path: str):
        """Save policy network weights to checkpoint."""
        torch.save({"policy_net": self.policy_net.state_dict()}, path)

    def train_mode(self):
        """Set network to training mode."""
        self.policy_net.train()

    def eval_mode(self):
        """Set network to evaluation mode."""
        self.policy_net.eval()

    def reset(self):
        """Reset agent state (no-op for learned agent)."""
        pass


class ValueNetwork(nn.Module):
    """Value network for critic in actor-critic methods."""

    def __init__(self, obs_size: int, hidden_sizes: tuple = (256, 256)):
        super().__init__()
        layers = []
        prev_size = obs_size
        for hidden_size in hidden_sizes:
            layers.extend(
                [
                    nn.Linear(prev_size, hidden_size),
                    nn.ReLU(),
                ]
            )
            prev_size = hidden_size
        layers.append(nn.Linear(prev_size, 1))
        self.net = nn.Sequential(*layers)

    def forward(self, obs: torch.Tensor) -> torch.Tensor:
        """Forward pass returning value estimate."""
        return self.net(obs).squeeze(-1)
