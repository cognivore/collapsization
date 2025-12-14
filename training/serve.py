#!/usr/bin/env python3
"""WebSocket inference server for Collapsization RL bots.

Provides real-time action inference for the Godot game client.

Protocol (JSON over WebSocket):

Request:
{
    "type": "get_action",
    "player": 1,  # 0=Mayor, 1=Industry, 2=Urbanist
    "observation": {
        "phase": 2,
        "turn": 5,
        "scores": {"mayor": 2, "industry": 1, "urbanist": 3},
        "built_hexes": [[0,0,0], [1,-1,0]],
        "frontier_hexes": [[1,0,-1], [0,1,-1], ...],
        "revealed_card": {"suit": 0, "rank": "7", "value": 7},
        "hand": [...],  # Mayor only
        "reality_tiles": {...},  # Advisors only
        "nominations": {...}
    }
}

Response:
{
    "type": "action",
    "action": {
        "hex": [1, 0, -1],
        "claim": {"suit": 0, "value": 7, "rank": "7"},
        "card_index": 1
    }
}

Usage:
    python serve.py --checkpoint=checkpoints/best.pt --port=8765
    python serve.py --scripted --port=8765  # Use scripted agents as fallback
"""

import argparse
import asyncio
import json
import logging
import os
import sys
from pathlib import Path
from typing import Optional, Dict, Any

sys.path.insert(0, str(Path(__file__).parent))

from collapsization import (
    Role,
    Phase,
    Suit,
    NUM_CARDS,
    INVALID_HEX,
    make_card,
    card_to_index,
    index_to_card,
    card_label,
)
from collapsization.game import (
    ACTION_REVEAL_BASE,
    ACTION_COMMIT_BASE,
    ACTION_BUILD_BASE,
)
from agents import ScriptedAdvisorAgent, ScriptedMayorAgent

try:
    import websockets

    WEBSOCKETS_AVAILABLE = True
except ImportError:
    WEBSOCKETS_AVAILABLE = False

try:
    import torch
    from agents.learned_agent import LearnedAgent, PolicyNetwork

    TORCH_AVAILABLE = True
except ImportError:
    TORCH_AVAILABLE = False

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("serve")


# #region agent log
DEBUG_LOG_PATH = "/Users/sweater/Github/collapsization/.cursor/debug.log"


def _debug_log(hypothesis: str, message: str, data: dict = None):
    """Write debug log entry to file."""
    import time

    entry = {
        "timestamp": int(time.time() * 1000),
        "location": "serve.py",
        "hypothesisId": hypothesis,
        "message": message,
        "data": data or {},
        "sessionId": "debug-session",
    }
    with open(DEBUG_LOG_PATH, "a") as f:
        f.write(json.dumps(entry) + "\n")


# #endregion


class InferenceServer:
    """WebSocket server for RL bot inference."""

    def __init__(
        self,
        checkpoint_paths: Optional[Dict[str, str]] = None,
        use_scripted_fallback: bool = True,
        device: str = "cpu",
    ):
        self.device = device
        self.use_scripted_fallback = use_scripted_fallback

        # Learned agents (one per role)
        self.learned_agents: Dict[Role, Any] = {}

        # Scripted fallback agents
        self.scripted_agents: Dict[Role, Any] = {
            Role.MAYOR: ScriptedMayorAgent(Role.MAYOR),
            Role.INDUSTRY: ScriptedAdvisorAgent(Role.INDUSTRY),
            Role.URBANIST: ScriptedAdvisorAgent(Role.URBANIST),
        }

        # Load checkpoints if provided
        if checkpoint_paths:
            self._load_checkpoints(checkpoint_paths)

        # Global statistics
        self.stats = {
            "requests": 0,
            "errors": 0,
            "learned_actions": 0,
            "fallback_actions": 0,
            "active_games": 0,
            "total_games": 0,
        }

        # Per-game session tracking for multiplayer support
        # game_id -> session data
        self.game_sessions: Dict[str, Dict[str, Any]] = {}

    def _load_checkpoints(self, paths: Dict[str, str]):
        """Load model checkpoints for each role."""
        if not TORCH_AVAILABLE:
            logger.warning("PyTorch not available, using scripted agents only")
            return

        # Determine observation/action sizes (need to create a dummy game)
        from collapsization import CollapsizationGame

        game = CollapsizationGame()
        state = game.new_initial_state()

        # Process chance nodes to get proper state for observation
        while state.is_chance_node():
            outcomes = state.chance_outcomes()
            action = outcomes[0][0]
            state.apply_action(action)

        # Get role-specific observation sizes (Mayor differs from Advisors)
        obs_sizes = {
            Role.MAYOR: len(state.observation_tensor(int(Role.MAYOR))),
            Role.INDUSTRY: len(state.observation_tensor(int(Role.INDUSTRY))),
            Role.URBANIST: len(state.observation_tensor(int(Role.URBANIST))),
        }
        num_actions = game.num_distinct_actions()

        logger.info(
            f"Observation sizes: Mayor={obs_sizes[Role.MAYOR]}, "
            f"Industry={obs_sizes[Role.INDUSTRY]}, Urbanist={obs_sizes[Role.URBANIST]}"
        )

        for role_name, path in paths.items():
            if not os.path.exists(path):
                logger.warning(f"Checkpoint not found: {path}")
                continue

            role = Role[role_name.upper()]
            try:
                agent = LearnedAgent(
                    int(role),
                    obs_size=obs_sizes[role],
                    num_actions=num_actions,
                    device=self.device,
                )
                agent.load_checkpoint(path)
                self.learned_agents[role] = agent
                logger.info(f"Loaded checkpoint for {role.name}: {path}")
            except Exception as e:
                logger.error(f"Failed to load checkpoint {path}: {e}")

    def reload_checkpoint(self, role: Role, path: str) -> bool:
        """Hot-reload a checkpoint for a specific role."""
        if role not in self.learned_agents:
            logger.warning(f"No agent initialized for {role.name}")
            return False

        try:
            self.learned_agents[role].load_checkpoint(path)
            logger.info(f"Reloaded checkpoint for {role.name}: {path}")
            return True
        except Exception as e:
            logger.error(f"Failed to reload checkpoint: {e}")
            return False

    async def handle_request(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """Handle an inference request."""
        self.stats["requests"] += 1

        # Extract game_id for session tracking (optional, defaults to "default")
        game_id = request.get("game_id", "default")
        request_type = request.get("type", "")

        if request_type == "get_action":
            return await self._handle_get_action(request, game_id)
        elif request_type == "start_game":
            return self._handle_start_game(game_id, request)
        elif request_type == "end_game":
            return self._handle_end_game(game_id)
        elif request_type == "ping":
            return {"type": "pong", "game_id": game_id}
        elif request_type == "stats":
            return {"type": "stats", "data": self.stats, "game_id": game_id}
        elif request_type == "game_stats":
            return self._handle_game_stats(game_id)
        elif request_type == "reload":
            role = Role[request.get("role", "MAYOR").upper()]
            path = request.get("path", "")
            success = self.reload_checkpoint(role, path)
            return {"type": "reload_result", "success": success}
        else:
            return {"type": "error", "message": f"Unknown request type: {request_type}"}

    def _handle_start_game(
        self, game_id: str, request: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Initialize a new game session."""
        import time

        if game_id in self.game_sessions:
            logger.warning(f"Game {game_id} already exists, resetting")

        self.game_sessions[game_id] = {
            "start_time": time.time(),
            "requests": 0,
            "actions": {"mayor": 0, "industry": 0, "urbanist": 0},
            "errors": 0,
            "seed": request.get("seed"),
            "metadata": request.get("metadata", {}),
        }
        self.stats["active_games"] += 1
        self.stats["total_games"] += 1

        logger.info(f"Game {game_id} started (active: {self.stats['active_games']})")
        return {"type": "game_started", "game_id": game_id}

    def _handle_end_game(self, game_id: str) -> Dict[str, Any]:
        """End a game session and return session stats."""
        import time

        if game_id not in self.game_sessions:
            return {"type": "error", "message": f"Game {game_id} not found"}

        session = self.game_sessions.pop(game_id)
        session["end_time"] = time.time()
        session["duration"] = session["end_time"] - session["start_time"]
        self.stats["active_games"] -= 1

        logger.info(
            f"Game {game_id} ended (duration: {session['duration']:.1f}s, "
            f"requests: {session['requests']}, active: {self.stats['active_games']})"
        )
        return {"type": "game_ended", "game_id": game_id, "session": session}

    def _handle_game_stats(self, game_id: str) -> Dict[str, Any]:
        """Get stats for a specific game session."""
        if game_id not in self.game_sessions:
            return {"type": "error", "message": f"Game {game_id} not found"}
        return {
            "type": "game_stats",
            "game_id": game_id,
            "session": self.game_sessions[game_id],
        }

    def _track_action(self, game_id: str, role: "Role"):
        """Track an action for a game session."""
        if game_id in self.game_sessions:
            session = self.game_sessions[game_id]
            session["requests"] += 1
            role_name = role.name.lower()
            if role_name in session["actions"]:
                session["actions"][role_name] += 1

    async def _handle_get_action(
        self, request: Dict[str, Any], game_id: str = "default"
    ) -> Dict[str, Any]:
        """Handle a get_action request."""
        player = request.get("player", 0)
        observation = request.get("observation", {})

        # #region agent log
        _debug_log(
            "D",
            "_handle_get_action_entry",
            {
                "player": player,
                "game_id": game_id,
                "has_learned_agents": list(self.learned_agents.keys()),
            },
        )
        # #endregion

        try:
            role = Role(player)
        except ValueError:
            return {
                "type": "error",
                "message": f"Invalid player: {player}",
                "game_id": game_id,
            }

        try:
            # Track this action for the game session
            self._track_action(game_id, role)

            # Try learned agent first
            if role in self.learned_agents:
                action = await self._get_learned_action(role, observation)
                self.stats["learned_actions"] += 1
            elif self.use_scripted_fallback:
                action = await self._get_scripted_action(role, observation)
                self.stats["fallback_actions"] += 1
            else:
                return {
                    "type": "error",
                    "message": f"No agent available for {role.name}",
                    "game_id": game_id,
                }

            # Echo back request_id so client can match response to pending request
            request_id = request.get("request_id")
            return {
                "type": "action",
                "action": action,
                "game_id": game_id,
                "request_id": request_id,
            }

        except Exception as e:
            self.stats["errors"] += 1
            if game_id in self.game_sessions:
                self.game_sessions[game_id]["errors"] += 1
            logger.error(f"Error getting action for game {game_id}: {e}")
            return {"type": "error", "message": str(e)}

    async def _get_learned_action(
        self, role: Role, observation: Dict
    ) -> Dict[str, Any]:
        """Get action from learned agent using the observation tensor."""
        import torch
        import numpy as np
        from collapsization.observation import ObservationEncoder
        from collapsization.constants import (
            Phase,
            NUM_CARDS,
            card_to_index,
            index_to_card,
        )

        # #region agent log
        _debug_log(
            "D",
            "_get_learned_action_entry",
            {"role": role.name, "has_agent": role in self.learned_agents},
        )
        # #endregion
        agent = self.learned_agents.get(role)
        if agent is None:
            # #region agent log
            _debug_log("D", "_get_learned_action_no_agent", {"role": role.name})
            # #endregion
            logger.warning(f"No learned agent for {role.name}, using scripted")
            return await self._get_scripted_action(role, observation)

        try:
            # Parse observation
            phase = Phase(observation.get("phase", 1))
            turn = observation.get("turn", 0)
            scores = observation.get(
                "scores", {"mayor": 0, "industry": 0, "urbanist": 0}
            )
            built_hexes = [tuple(h) for h in observation.get("built_hexes", [])]
            frontier_hexes = [tuple(h) for h in observation.get("frontier_hexes", [])]
            revealed_card = observation.get("revealed_card", {})
            hand = observation.get("hand", [])
            nominations = observation.get("nominations", {})
            reality_tiles = observation.get("reality_tiles", {})

            # Convert reality_tiles keys
            if reality_tiles:
                reality_tiles = {
                    tuple(k) if isinstance(k, list) else k: v
                    for k, v in reality_tiles.items()
                }

            # Create observation encoder and encode
            encoder = ObservationEncoder()

            # Register frontier hexes first for consistent indexing
            for h in frontier_hexes:
                encoder.get_hex_index(h)

            if role == Role.MAYOR:
                # Find revealed_index from hand and revealed_card
                revealed_index = -1
                if revealed_card and hand:
                    for i, card in enumerate(hand):
                        if card.get("suit") == revealed_card.get("suit") and card.get(
                            "value"
                        ) == revealed_card.get("value"):
                            revealed_index = i
                            break

                obs_tensor = encoder.encode_mayor_observation(
                    phase,
                    turn,
                    scores,
                    built_hexes,
                    frontier_hexes,
                    hand,
                    revealed_index,
                    nominations,
                )
            else:
                # Get tray (all cards for now - we don't track what's been used)
                tray_remaining = list(range(NUM_CARDS))
                # Wrap revealed_card in a list - encoder expects list[dict]
                revealed_cards_list = [revealed_card] if revealed_card else []
                obs_tensor = encoder.encode_advisor_observation(
                    role,
                    phase,
                    turn,
                    scores,
                    built_hexes,
                    frontier_hexes,
                    revealed_cards_list,
                    reality_tiles,
                    tray_remaining,
                    nominations,
                )

            # Convert to torch tensor
            obs = torch.tensor(
                obs_tensor, dtype=torch.float32, device=agent.device
            ).unsqueeze(0)

            # Get action from network
            with torch.no_grad():
                logits = agent.policy_net(obs)
                probs = torch.softmax(logits, dim=-1)
                action_idx = torch.argmax(probs, dim=-1).item()

            # #region agent log
            _debug_log(
                "D",
                "_get_learned_action_success",
                {
                    "role": role.name,
                    "action_idx": action_idx,
                    "obs_shape": list(obs.shape),
                },
            )
            # #endregion
            # Convert action index back to game action
            return self._decode_action(
                role, action_idx, phase, frontier_hexes, hand, nominations
            )

        except Exception as e:
            # #region agent log
            _debug_log(
                "E",
                "_get_learned_action_exception",
                {"role": role.name, "error": str(e)},
            )
            # #endregion
            logger.error(f"Error in learned action for {role.name}: {e}")
            import traceback

            traceback.print_exc()
            return await self._get_scripted_action(role, observation)

    def _decode_action(
        self,
        role: Role,
        action_idx: int,
        phase: Phase,
        frontier: list,
        hand: list,
        nominations: dict,
    ) -> Dict[str, Any]:
        """Decode action index to game action format."""
        from collapsization.game import (
            ACTION_REVEAL_BASE,
            ACTION_COMMIT_BASE,
            ACTION_BUILD_BASE,
        )
        from collapsization.constants import NUM_CARDS, index_to_card

        if role == Role.MAYOR:
            if phase == Phase.DRAW:
                # Reveal action: action_idx = REVEAL_BASE + card_index
                card_idx = action_idx - ACTION_REVEAL_BASE
                return {
                    "card_index": max(0, min(card_idx, len(hand) - 1)),
                    "action_type": "reveal",
                }

            elif phase == Phase.PLACE:
                # Build action: action_idx = BUILD_BASE + card_idx * 2 + nom_idx
                place_idx = action_idx - ACTION_BUILD_BASE
                card_idx = place_idx // 2
                nom_idx = place_idx % 2

                # Get nominated hex
                nominated_hexes = []
                ind_nom = nominations.get("industry", {})
                urb_nom = nominations.get("urbanist", {})
                if ind_nom and ind_nom.get("hex"):
                    nominated_hexes.append(ind_nom["hex"])
                if urb_nom and urb_nom.get("hex"):
                    nominated_hexes.append(urb_nom["hex"])

                hex_coord = (
                    nominated_hexes[min(nom_idx, len(nominated_hexes) - 1)]
                    if nominated_hexes
                    else [0, 0, 0]
                )

                return {
                    "card_index": max(0, min(card_idx, len(hand) - 1)),
                    "hex": (
                        list(hex_coord) if isinstance(hex_coord, tuple) else hex_coord
                    ),
                    "action_type": "place",
                }

        else:  # Advisor
            if phase == Phase.NOMINATE:
                # Commit action: action_idx = COMMIT_BASE + hex_idx * NUM_CARDS + claim_idx
                commit_idx = action_idx - ACTION_COMMIT_BASE
                hex_idx = commit_idx // NUM_CARDS
                claim_idx = commit_idx % NUM_CARDS

                hex_coord = (
                    frontier[min(hex_idx, len(frontier) - 1)] if frontier else (0, 0, 0)
                )
                claim_card = index_to_card(claim_idx)

                # #region agent log
                _debug_log(
                    "F",
                    "_decode_action_advisor",
                    {
                        "role": role.name,
                        "action_idx": action_idx,
                        "commit_idx": commit_idx,
                        "hex_idx": hex_idx,
                        "claim_idx": claim_idx,
                        "frontier_len": len(frontier),
                        "hex_coord": (
                            list(hex_coord)
                            if isinstance(hex_coord, tuple)
                            else hex_coord
                        ),
                        "claim_card": claim_card,
                    },
                )
                # #endregion
                return {
                    "hex": list(hex_coord),
                    "claim": claim_card,
                    "action_type": "nominate",
                }

        return {"action_type": "unknown"}

    async def _get_scripted_action(
        self, role: Role, observation: Dict
    ) -> Dict[str, Any]:
        """Get action from scripted agent based on observation."""
        phase = Phase(observation.get("phase", 1))
        frontier = [tuple(h) for h in observation.get("frontier_hexes", [])]
        revealed_card = observation.get("revealed_card", {})
        hand = observation.get("hand", [])
        nominations = observation.get("nominations", {})
        reality_tiles = observation.get("reality_tiles", {})

        # Convert reality_tiles keys to tuples (keys may be lists, strings, or tuples)
        if reality_tiles:
            converted = {}
            for k, v in reality_tiles.items():
                if isinstance(k, (list, tuple)):
                    converted[tuple(k)] = v
                elif isinstance(k, str):
                    # Parse string like "[-1, 0, 1]" or "(-1, 0, 1)"
                    import ast

                    try:
                        parsed = ast.literal_eval(k)
                        converted[tuple(parsed)] = v
                    except (ValueError, SyntaxError):
                        converted[k] = v
                else:
                    converted[k] = v
            reality_tiles = converted

        if role == Role.MAYOR:
            return self._get_mayor_action(
                phase, hand, revealed_card, nominations, frontier
            )
        else:
            return self._get_advisor_action(
                role, phase, revealed_card, frontier, reality_tiles
            )

    def _get_mayor_action(
        self,
        phase: Phase,
        hand: list,
        revealed_card: dict,
        nominations: dict,
        frontier: list,
    ) -> Dict[str, Any]:
        """Get mayor action based on observation."""
        if phase == Phase.DRAW:
            # Reveal phase: choose a non-spade card to reveal
            best_idx = 0
            best_score = -100
            for i, card in enumerate(hand):
                suit = card.get("suit", -1)
                value = card.get("value", 0)
                score = value if suit != Suit.SPADES else -10
                if score > best_score:
                    best_score = score
                    best_idx = i
            return {"card_index": best_idx, "action_type": "reveal"}

        elif phase == Phase.PLACE:
            # Place phase: choose card and hex
            # Simple heuristic: match suit with claims, avoid spades
            nom_list = []
            for role_key in ["industry", "urbanist"]:
                nom = nominations.get(role_key, {})
                if nom and nom.get("hex") and nom.get("hex") != list(INVALID_HEX):
                    nom_list.append(nom)

            best_card_idx = 0
            best_nom_idx = 0
            best_score = -100

            for card_idx, card in enumerate(hand):
                card_suit = card.get("suit", -1)
                card_value = card.get("value", 0)

                for nom_idx, nom in enumerate(nom_list):
                    claim = nom.get("claim", {})
                    claim_suit = claim.get("suit", -1)
                    claim_value = claim.get("value", 0)

                    score = 0
                    if card_suit == Suit.SPADES:
                        score -= 50
                    if card_suit == claim_suit:
                        score += 10 + max(0, 15 - abs(card_value - claim_value))

                    if score > best_score:
                        best_score = score
                        best_card_idx = card_idx
                        best_nom_idx = nom_idx

            hex_coord = nom_list[best_nom_idx]["hex"] if nom_list else [0, 0, 0]
            return {
                "card_index": best_card_idx,
                "hex": hex_coord,
                "action_type": "place",
            }

        return {"card_index": 0, "action_type": "unknown"}

    def _get_advisor_action(
        self,
        role: Role,
        phase: Phase,
        revealed_card: dict,
        frontier: list,
        reality_tiles: dict,
    ) -> Dict[str, Any]:
        """Get advisor action based on observation."""
        # #region agent log
        _debug_log(
            "H_A",
            "_get_advisor_action_entry",
            {
                "role": role.name,
                "phase": phase.name,
                "frontier_count": len(frontier),
                "reality_tiles_count": len(reality_tiles),
                "revealed_card": revealed_card,
                "reality_tiles_keys_sample": (
                    list(reality_tiles.keys())[:3] if reality_tiles else []
                ),
            },
        )
        # #endregion
        if phase != Phase.NOMINATE:
            return {"hex": [0, 0, 0], "claim": {}, "action_type": "wait"}

        revealed_suit = revealed_card.get("suit", -1)
        revealed_value = revealed_card.get("value", 7)
        my_suit = Suit.DIAMONDS if role == Role.INDUSTRY else Suit.HEARTS

        # Categorize frontier hexes by suit
        # Note: reality_tiles keys may be strings like "[-1, 0, 1]" from JSON
        hearts, diamonds, spades = [], [], []
        for hex_coord in frontier:
            # Try multiple key formats: tuple, list, and string representation
            hex_list = list(hex_coord) if isinstance(hex_coord, tuple) else hex_coord
            hex_tuple = tuple(hex_coord) if isinstance(hex_coord, list) else hex_coord
            hex_str = str(hex_list)

            card = (
                reality_tiles.get(hex_tuple)
                or reality_tiles.get(hex_list)
                or reality_tiles.get(hex_str)
                or {}
            )
            if not card:
                continue
            suit = card.get("suit", -1)
            entry = {
                "hex": list(hex_coord) if isinstance(hex_coord, tuple) else hex_coord,
                "card": card,
                "value": card.get("value", 0),
            }
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

        # Apply strategic rules
        chosen_hex = None
        claim_card = None

        if revealed_suit == Suit.SPADES:
            # Nominate best of own suit
            if role == Role.INDUSTRY and diamonds:
                chosen_hex = diamonds[0]["hex"]
                claim_card = diamonds[0]["card"]
            elif role == Role.URBANIST and hearts:
                chosen_hex = hearts[0]["hex"]
                claim_card = hearts[0]["card"]

        elif revealed_suit == Suit.HEARTS:
            if role == Role.URBANIST and hearts:
                chosen_hex = hearts[0]["hex"]
                claim_card = hearts[0]["card"]
            elif role == Role.INDUSTRY and hearts:
                # Lie: claim heart is spade
                chosen_hex = hearts[0]["hex"]
                claim_card = make_card(
                    Suit.SPADES, self._value_to_rank(hearts[0]["value"])
                )

        elif revealed_suit == Suit.DIAMONDS:
            if role == Role.INDUSTRY and diamonds:
                chosen_hex = diamonds[0]["hex"]
                claim_card = diamonds[0]["card"]
            elif role == Role.URBANIST:
                import random

                roll = random.random()
                if roll < 0.5 and spades:
                    chosen_hex = spades[0]["hex"]
                    claim_card = spades[0]["card"]
                elif roll < 0.75 and diamonds:
                    chosen_hex = diamonds[0]["hex"]
                    claim_card = make_card(
                        Suit.SPADES, self._value_to_rank(diamonds[0]["value"])
                    )
                elif diamonds:
                    mid_idx = len(diamonds) // 2
                    chosen_hex = diamonds[mid_idx]["hex"]
                    claim_card = diamonds[mid_idx]["card"]

        # Fallback
        if chosen_hex is None:
            all_available = hearts + diamonds + spades
            # #region agent log
            _debug_log(
                "H_A",
                "_get_advisor_action_fallback",
                {
                    "role": role.name,
                    "all_available_count": len(all_available),
                    "frontier_count": len(frontier),
                    "hearts_count": len(hearts),
                    "diamonds_count": len(diamonds),
                    "spades_count": len(spades),
                },
            )
            # #endregion
            if all_available:
                chosen_hex = all_available[0]["hex"]
                claim_card = make_card(my_suit, self._value_to_rank(revealed_value))
            elif frontier:
                chosen_hex = list(frontier[0])
                claim_card = make_card(my_suit, "7")

        # #region agent log
        _debug_log(
            "H_A",
            "_get_advisor_action_result",
            {
                "role": role.name,
                "chosen_hex": chosen_hex,
                "claim_card": claim_card,
            },
        )
        # #endregion
        return {
            "hex": chosen_hex or [0, 0, 0],
            "claim": claim_card or {},
            "action_type": "nominate",
        }

    def _value_to_rank(self, value: int) -> str:
        """Convert numeric value to rank string."""
        mapping = {
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
        return mapping.get(value, "7")


async def handle_connection(websocket, server: InferenceServer):
    """Handle a WebSocket connection."""
    client_addr = websocket.remote_address
    logger.info(f"Client connected: {client_addr}")

    try:
        async for message in websocket:
            try:
                request = json.loads(message)
                logger.debug(f"Request: {request}")

                response = await server.handle_request(request)

                await websocket.send(json.dumps(response))
                logger.debug(f"Response: {response}")

            except json.JSONDecodeError as e:
                error_response = {"type": "error", "message": f"Invalid JSON: {e}"}
                await websocket.send(json.dumps(error_response))

    except websockets.exceptions.ConnectionClosed:
        logger.info(f"Client disconnected: {client_addr}")
    except Exception as e:
        logger.error(f"Error handling connection: {e}")


async def run_server(host: str, port: int, server: InferenceServer):
    """Run the WebSocket server."""
    logger.info(f"Starting inference server on {host}:{port}")

    async with websockets.serve(
        lambda ws: handle_connection(ws, server),
        host,
        port,
    ):
        logger.info("Server ready, waiting for connections...")
        await asyncio.Future()  # Run forever


def main():
    if not WEBSOCKETS_AVAILABLE:
        print(
            "Error: websockets library required. Install with: pip install websockets"
        )
        sys.exit(1)

    parser = argparse.ArgumentParser(description="Collapsization RL Inference Server")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="Host to bind to")
    parser.add_argument("--port", type=int, default=8765, help="Port to bind to")
    parser.add_argument(
        "--checkpoint",
        type=str,
        default=None,
        help="Path to checkpoint file (or pattern like checkpoints/best_*.pt)",
    )
    parser.add_argument(
        "--mayor-checkpoint", type=str, default=None, help="Checkpoint for Mayor"
    )
    parser.add_argument(
        "--industry-checkpoint", type=str, default=None, help="Checkpoint for Industry"
    )
    parser.add_argument(
        "--urbanist-checkpoint", type=str, default=None, help="Checkpoint for Urbanist"
    )
    parser.add_argument(
        "--scripted",
        action="store_true",
        help="Use only scripted agents (no learned models)",
    )
    parser.add_argument(
        "--device", type=str, default="cpu", help="Device for neural networks"
    )
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")

    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    # Build checkpoint paths
    checkpoint_paths = {}
    if args.checkpoint:
        # Single checkpoint for all roles (or detect per-role files)
        for role in ["mayor", "industry", "urbanist"]:
            path = args.checkpoint.replace("*", role)
            if os.path.exists(path):
                checkpoint_paths[role] = path
    if args.mayor_checkpoint:
        checkpoint_paths["mayor"] = args.mayor_checkpoint
    if args.industry_checkpoint:
        checkpoint_paths["industry"] = args.industry_checkpoint
    if args.urbanist_checkpoint:
        checkpoint_paths["urbanist"] = args.urbanist_checkpoint

    server = InferenceServer(
        checkpoint_paths=checkpoint_paths if not args.scripted else None,
        use_scripted_fallback=True,
        device=args.device,
    )

    try:
        asyncio.run(run_server(args.host, args.port, server))
    except KeyboardInterrupt:
        logger.info("Server stopped")


if __name__ == "__main__":
    main()
