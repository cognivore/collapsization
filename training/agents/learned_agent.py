"""Learned agent wrapper for DQN/PPO policies."""

from typing import Optional, Callable
import numpy as np

import pyspiel

try:
    import torch
    import torch.nn as nn

    TORCH_AVAILABLE = True
except ImportError:
    TORCH_AVAILABLE = False


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
        num_actions = self.policy_net.net[-1].out_features
        legal_mask = torch.zeros(1, num_actions, device=self.device)
        for a in legal_actions:
            if a < num_actions:
                legal_mask[0, a] = 1.0

        # Get action from policy
        with torch.no_grad():
            logits = self.policy_net(obs_tensor, legal_mask)
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

        num_actions = self.policy_net.net[-1].out_features
        legal_mask = torch.zeros(1, num_actions, device=self.device)
        for a in legal_actions:
            if a < num_actions:
                legal_mask[0, a] = 1.0

        with torch.no_grad():
            logits = self.policy_net(obs_tensor, legal_mask)
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
