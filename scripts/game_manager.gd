## Manages the game state machine, turn phases, and scoring.
## Action-driven transitions: phases change when players act, not on timers.
extends Node
class_name GameManager

const MapLayers := preload("res://scripts/map_layers.gd")
const GameRules := preload("res://scripts/game_rules.gd")
const GameProtocol := preload("res://scripts/game/game_protocol.gd")
const DebugLogger := preload("res://scripts/debug/debug_logger.gd")
const RLClientScript := preload("res://scripts/agents/rl_client.gd")

# ─────────────────────────────────────────────────────────────────────────────
# SIGNALS
# ─────────────────────────────────────────────────────────────────────────────

signal phase_changed(phase: int)
signal hand_updated(hand: Array, revealed_indices: Array)
signal nominations_updated(nominations: Array)
signal commits_updated(commits: Dictionary) # For showing commit status without hex
signal placement_resolved(turn_index: int, placement: Dictionary)
signal scores_updated(scores: Dictionary)
signal game_over(reason: String, final_scores: Dictionary)
signal visibility_updated(visibility: Array)
signal fog_updated(fog: Array)
signal player_count_changed(count: int, required: int)

# ─────────────────────────────────────────────────────────────────────────────
# ENUMS
# ─────────────────────────────────────────────────────────────────────────────

enum Phase {
	LOBBY, # Waiting for 3 players
	DRAW, # Mayor has 4 cards, must reveal 2
	NOMINATE, # Advisors commit nominations (hidden until all 4 commit)
	PLACE, # Mayor picks card + nominated hex
	GAME_OVER, # Spade placed or error
}

enum Role {MAYOR, INDUSTRY, URBANIST}

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)
const REQUIRED_PLAYERS := 3

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────

@export var hex_field_path: NodePath = NodePath("../HexField")
@export var town_center: Vector3i = Vector3i.ZERO

## RL Bot configuration
## Set use_rl_bots=true or pass --rl-bots command line flag to enable AI opponents
@export var use_rl_bots: bool = false
@export var rl_server_url: String = "ws://localhost:8765"
@export var bot_action_delay: float = 0.0 # DEBUG: No delay for testing
@export var auto_detect_rl_server: bool = true # Auto-enable if server is reachable

# ─────────────────────────────────────────────────────────────────────────────
# STATE
# ─────────────────────────────────────────────────────────────────────────────

var phase: Phase = Phase.LOBBY
var phase_end_time: float = 0.0 # 0 = no timeout (action-driven)
var turn_index: int = 0

# Mayor's hand and reveal state
var hand: Array[Dictionary] = []
var revealed_indices: Array[int] = [] # Mayor reveals 2 cards

# Turn history for deduction (full game history)
var turn_history: Array = [] # Array of {revealed, nominations, build, reality, scores_delta}

# Advisor nominations: committed (hidden) and revealed (shown)
# Format: advisor_commits = {role: Array of {hex: Vector3i, claim: Dictionary}}
# Format: nominations = Array of {hex: Vector3i, claim: Dictionary, advisor: String}
var advisor_commits := {"industry": [], "urbanist": []} # 2 nominations per advisor
var nominations: Array = [] # Flat list for Mayor (up to 4 entries)
var _sub_phase: String = "industry_commit_1" # Track nomination sub-phase

# Track built hexes to prevent re-nomination
var built_hexes: Array[Vector3i] = []

var last_placement: Dictionary = {}
var scores := {"mayor": 0, "industry": 0, "urbanist": 0}
var advisor_visibility: Array = []
var local_fog: Array = []

# Deck management
var _deck: Array[Dictionary] = []
var _discard: Array[Dictionary] = []

# Node references
var _hex_field: Node
var _net_mgr: Node

# Role mappings
var _role_by_peer: Dictionary = {}
var _peer_by_role: Dictionary = {}
var local_role: Role = Role.MAYOR

# Deterministic seed for deck shuffling (-1 = random)
var game_seed: int = -1
var _rng: RandomNumberGenerator
var _phase_handlers: Dictionary = {}

# RL Bot client (optional, for AI-controlled advisors/mayor)
var _rl_client: Node = null
var _bot_roles: Array[Role] = [] # Roles controlled by bots

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_bind_hex_field()
	_bind_network()
	_init_phase_handlers()
	_init_rl_client()


func _bind_hex_field() -> void:
	if hex_field_path != NodePath():
		_hex_field = get_node_or_null(hex_field_path)
	if _hex_field == null and get_parent():
		_hex_field = get_parent().get_node_or_null("HexField")


func _bind_network() -> void:
	if has_node("/root/NetworkManager"):
		_net_mgr = get_node("/root/NetworkManager")
		if _net_mgr.has_signal("game_message"):
			_net_mgr.game_message.connect(_on_game_message)
		_net_mgr.player_joined.connect(_on_player_joined)
		_net_mgr.player_left.connect(_on_player_left)


func _init_phase_handlers() -> void:
	var draw_script = load("res://scripts/game/phases/draw_phase.gd")
	var nominate_script = load("res://scripts/game/phases/nominate_phase.gd")
	var place_script = load("res://scripts/game/phases/place_phase.gd")

	if draw_script == null or nominate_script == null or place_script == null:
		push_error("GameManager: Failed to load phase handler scripts!")
		return

	_phase_handlers = {
		Phase.DRAW: draw_script.new(),
		Phase.NOMINATE: nominate_script.new(),
		Phase.PLACE: place_script.new(),
	}


func _init_rl_client() -> void:
	# #region agent log
	var _dbg_args := OS.get_cmdline_args()
	var _dbg_user_args := OS.get_cmdline_user_args()
	_debug_log("A", "_init_rl_client", {"args": _dbg_args, "user_args": _dbg_user_args, "use_rl_bots_before": use_rl_bots})
	# #endregion
	# Check command line for --rl-bots flag (user args are after -- separator)
	if "--rl-bots" in OS.get_cmdline_user_args() or "--rl-bots" in OS.get_cmdline_args():
		use_rl_bots = true
		DebugLogger.log("GameManager: RL bots enabled via command line")

	# #region agent log
	_debug_log("A", "_init_rl_client_after_check", {"use_rl_bots": use_rl_bots, "instance_id": get_instance_id()})
	# #endregion
	if not use_rl_bots:
		# #region agent log
		_debug_log("A", "_init_rl_client_skipped", {"reason": "use_rl_bots is false"})
		# #endregion
		return

	# #region agent log
	_debug_log("A", "_init_rl_client_creating", {"instance_id": get_instance_id()})
	# #endregion
	_rl_client = RLClientScript.new()
	_rl_client.name = "RLClient"
	_rl_client.server_url = rl_server_url
	_rl_client.auto_reconnect = true
	add_child(_rl_client)

	_rl_client.connected.connect(_on_rl_connected)
	_rl_client.disconnected.connect(_on_rl_disconnected)
	_rl_client.action_received.connect(_on_rl_action_received)
	_rl_client.error.connect(_on_rl_error)

	_rl_client.connect_to_server()
	# #region agent log
	_debug_log("A", "_init_rl_client_created", {"server_url": rl_server_url, "instance_id": get_instance_id(), "rl_client_valid": _rl_client != null})
	# #endregion
	DebugLogger.log("GameManager: RL client initialized, connecting to %s" % rl_server_url)


func _on_rl_connected() -> void:
	DebugLogger.log("GameManager: RL server connected")


func _on_rl_disconnected() -> void:
	DebugLogger.log("GameManager: RL server disconnected, using scripted fallback")


func _on_rl_action_received(role: int, action: Dictionary) -> void:
	DebugLogger.log("GameManager: RL action for role %d: %s" % [role, action])
	_apply_bot_action(Role.values()[role], action)


func _on_rl_error(message: String) -> void:
	DebugLogger.log("GameManager: RL error: %s" % message)


func _get_phase_handler(phase_key: Phase):
	if _phase_handlers.is_empty():
		_init_phase_handlers()
	return _phase_handlers.get(phase_key, null)


func _empty_commits_map() -> Dictionary:
	return {"industry": [], "urbanist": []}


func _reset_nominations_state() -> void:
	advisor_commits = _empty_commits_map()
	nominations = []
	_sub_phase = "industry_commit_1"

# ─────────────────────────────────────────────────────────────────────────────
# GAME START
# ─────────────────────────────────────────────────────────────────────────────

## Called externally when all players have joined
func start_game() -> void:
	if not _is_server():
		return
	if phase != Phase.LOBBY:
		return

	_assign_roles()
	_broadcast_roles()
	_initialize_game()


## Start singleplayer mode (for testing and offline play)
## In singleplayer, the local player is Mayor and advisors are bots
func start_singleplayer() -> void:
	# #region agent log
	_debug_log("C", "start_singleplayer_called", {"phase": Phase.keys()[phase], "rl_client_exists": _rl_client != null, "instance_id": get_instance_id(), "use_rl_bots": use_rl_bots})
	# #endregion
	if phase != Phase.LOBBY:
		return
	local_role = Role.MAYOR
	_role_by_peer[1] = Role.MAYOR
	_peer_by_role[Role.MAYOR] = 1

	# Set advisors as bot-controlled
	set_bot_roles([Role.INDUSTRY, Role.URBANIST])
	# #region agent log
	_debug_log("C", "start_singleplayer_bot_roles_set", {"bot_roles": _bot_roles.map(func(r): return Role.keys()[r])})
	# #endregion

	_initialize_game()


func _initialize_game() -> void:
	_rng = RandomNumberGenerator.new()
	if game_seed >= 0:
		_rng.seed = game_seed
	else:
		_rng.randomize()
	DebugLogger.log("GameManager: Starting game with seed=%d" % _rng.seed)

	# Start RL game session for bot tracking
	if _rl_client:
		_rl_client.start_game_session(_rng.seed, {"local_role": Role.keys()[local_role]})

	_build_deck()
	_discard.clear()
	turn_index = 0
	scores = {"mayor": 0, "industry": 0, "urbanist": 0}
	_reset_nominations_state()
	last_placement.clear()
	turn_history.clear()

	# Center tile starts as built (A♥)
	built_hexes.clear()
	built_hexes.append(town_center)

	# Show center as built visually
	_show_initial_built_center()

	_emit_initial_fog()
	_transition_to(Phase.DRAW)


func _show_initial_built_center() -> void:
	if _hex_field == null:
		return
	var center_card := MapLayers.make_card(MapLayers.Suit.HEARTS, "A")
	if _hex_field.has_method("show_built_tile"):
		_hex_field.show_built_tile(town_center, center_card, "")
		DebugLogger.log("GameManager: Center shown as built A♥")

# ─────────────────────────────────────────────────────────────────────────────
# PHASE TRANSITIONS (action-driven)
# ─────────────────────────────────────────────────────────────────────────────

func _transition_to(new_phase: Phase) -> void:
	var old_phase := phase
	phase = new_phase
	phase_end_time = 0.0 # No timeouts - action driven

	var handler = _get_phase_handler(new_phase)
	if handler:
		handler.enter(self)

	DebugLogger.log("GameManager: Phase %s -> %s" % [Phase.keys()[old_phase], Phase.keys()[new_phase]])
	phase_changed.emit(phase)
	_broadcast_state()

	# Trigger bot actions after phase change
	_trigger_bot_actions_if_needed()


func _enter_draw_phase() -> void:
	var handler = _get_phase_handler(Phase.DRAW)
	if handler:
		handler.enter(self)


func _enter_nominate_phase() -> void:
	var handler = _get_phase_handler(Phase.NOMINATE)
	if handler:
		handler.enter(self)


func _enter_place_phase() -> void:
	var handler = _get_phase_handler(Phase.PLACE)
	if handler:
		handler.enter(self)

# ─────────────────────────────────────────────────────────────────────────────
# PLAYER ACTIONS
# ─────────────────────────────────────────────────────────────────────────────

## Mayor reveals one of their 4 cards. After 2 cards revealed -> transitions to NOMINATE
func reveal_card(index: int) -> void:
	if not _is_server():
		_send_intent("reveal", {"index": index})
		return

	var handler = _get_phase_handler(Phase.DRAW)
	if handler:
		handler.reveal(self, index)


## Advisor commits their nomination with a claimed card (hidden until both commit)
func commit_nomination(role: Role, hex: Vector3i, claimed_card: Dictionary = {}) -> void:
	if not _is_server():
		_send_intent("commit", {
			"role": int(role),
			"cube": [hex.x, hex.y, hex.z],
			"claim": claimed_card
		})
		return

	var handler = _get_phase_handler(Phase.NOMINATE)
	if handler:
		handler.commit(self, role, hex, claimed_card)


func _all_advisors_committed() -> bool:
	# Each advisor needs 2 nominations
	var ind: Array = advisor_commits.get("industry", [])
	var urb: Array = advisor_commits.get("urbanist", [])
	return ind.size() >= 2 and urb.size() >= 2


func _reveal_nominations() -> void:
	# Build flat array of nominations with advisor tag
	nominations = []
	for nom in advisor_commits.get("industry", []):
		var entry: Dictionary = nom.duplicate(true)
		entry["advisor"] = "industry"
		nominations.append(entry)
	for nom in advisor_commits.get("urbanist", []):
		var entry: Dictionary = nom.duplicate(true)
		entry["advisor"] = "urbanist"
		nominations.append(entry)

	var log_entries: Array[String] = []
	for nom in nominations:
		var hex: Vector3i = nom.get("hex", INVALID_HEX)
		var claim: Dictionary = nom.get("claim", {})
		var advisor: String = nom.get("advisor", "?")
		log_entries.append("%s: %s (%s)" % [
			advisor,
			_hex_to_string(hex),
			MapLayers.label(claim) if not claim.is_empty() else "?"
		])

	DebugLogger.log("GameManager: Nominations revealed - %s" % ", ".join(log_entries))
	nominations_updated.emit(nominations)
	_transition_to(Phase.PLACE)


## Mayor places a card on a nominated hex
func place_card(card_index: int, hex: Vector3i) -> void:
	if not _is_server():
		_send_intent("place", {"card_index": card_index, "cube": [hex.x, hex.y, hex.z]})
		return

	var handler = _get_phase_handler(Phase.PLACE)
	if handler:
		handler.place(self, card_index, hex)


func _finish_game(reason: String) -> void:
	DebugLogger.log("GameManager: GAME OVER - %s" % reason)
	DebugLogger.log("GameManager: Final scores - Mayor: %d, Industry: %d, Urbanist: %d" % [
		scores["mayor"], scores["industry"], scores["urbanist"]
	])
	phase = Phase.GAME_OVER
	phase_end_time = 0.0

	# End RL game session for bot tracking
	if _rl_client:
		_rl_client.end_game_session()

	# Reveal all hidden tiles on the map (show reality)
	if _hex_field and _hex_field.has_method("reveal_all_reality"):
		_hex_field.reveal_all_reality()

	phase_changed.emit(phase)
	game_over.emit(reason, scores)
	_broadcast_state()

# ─────────────────────────────────────────────────────────────────────────────
# DECK MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

func _build_deck() -> void:
	_deck.clear()
	for suit in MapLayers.Suit.values():
		for rank in MapLayers.RANKS:
			_deck.append(MapLayers.make_card(suit, rank))
	_shuffle(_deck)


func _shuffle(array: Array) -> void:
	for i in range(array.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp = array[i]
		array[i] = array[j]
		array[j] = tmp


func _draw_cards(count: int) -> Array[Dictionary]:
	var drawn: Array[Dictionary] = []
	while count > 0:
		if _deck.is_empty():
			_recycle_discard()
		if _deck.is_empty():
			# No more cards available anywhere
			break
		drawn.append(_deck.pop_back())
		count -= 1
	return drawn


func _recycle_discard() -> void:
	if _discard.is_empty():
		return
	_deck.append_array(_discard)
	_discard.clear()
	_shuffle(_deck)

# ─────────────────────────────────────────────────────────────────────────────
# FOG & VISIBILITY
# ─────────────────────────────────────────────────────────────────────────────

func _emit_initial_fog() -> void:
	if _hex_field == null:
		return
	var visible_cubes: Array = [town_center]
	for cube in _hex_field.cube_ring(town_center, 1):
		visible_cubes.append(cube)
	fog_updated.emit(visible_cubes)
	DebugLogger.log("GameManager: Initial fog revealed for %d hexes" % visible_cubes.size())


## Expand fog around a newly built hex - reveals the hex and all adjacent tiles
func _expand_fog_around(hex: Vector3i) -> void:
	var to_reveal: Array = [hex]
	for adj in GameRules.get_adjacent_hexes(hex):
		to_reveal.append(adj)
	fog_updated.emit(to_reveal)
	DebugLogger.log("GameManager: Fog expanded around %s (%d tiles)" % [_hex_to_string(hex), to_reveal.size()])


func _get_reality(cube: Vector3i) -> Dictionary:
	if _hex_field and _hex_field.map_layers:
		return _hex_field.map_layers.get_card(cube)
	return {}


## Check if the REALITY at a hex is SPADES
## Game ends if Mayor builds on a tile that has spades as its reality
func _check_reality_is_spade(hex: Vector3i, _placed_card: Dictionary) -> bool:
	var reality := _get_reality(hex)
	var has_spade := GameRules.is_spade(reality)
	if has_spade:
		DebugLogger.log("GameManager: Reality at %s is SPADES! (%s)" % [
			_hex_to_string(hex),
			MapLayers.label(reality)
		])
	return has_spade


## Calculate scores for a placement using the new nomination format
## Nominations format: {role: {hex: Vector3i, claim: Dictionary}}
## mayor_hand: All 4 cards Mayor had this turn (for optimal build check)
func _calculate_scores_with_claims(card: Dictionary, hex: Vector3i, noms: Array, mayor_hand: Array = []) -> Dictionary:
	return GameRules.calculate_turn_scores(
		card,
		hex,
		noms,
		Callable(self, "_get_reality"),
		mayor_hand
	)


# ─────────────────────────────────────────────────────────────────────────────
# ROLE MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

func _assign_roles() -> void:
	_role_by_peer.clear()
	_peer_by_role.clear()

	if _net_mgr == null:
		local_role = Role.MAYOR
		return

	var peers: Array = _net_mgr.players.keys()
	peers.sort()

	var roles := [Role.MAYOR, Role.INDUSTRY, Role.URBANIST]
	for i in range(mini(roles.size(), peers.size())):
		var peer_id: int = peers[i]
		var role: Role = roles[i]
		_role_by_peer[peer_id] = role
		_peer_by_role[role] = peer_id
		if peer_id == _net_mgr.get_local_id():
			local_role = role

	DebugLogger.log("GameManager: Roles - Mayor=%d, Industry=%d, Urbanist=%d" % [
		_peer_by_role.get(Role.MAYOR, -1),
		_peer_by_role.get(Role.INDUSTRY, -1),
		_peer_by_role.get(Role.URBANIST, -1),
	])


func _broadcast_roles() -> void:
	if _net_mgr == null:
		return
	var payload := {
		"roles": {
			"mayor": _peer_by_role.get(Role.MAYOR, 0),
			"industry": _peer_by_role.get(Role.INDUSTRY, 0),
			"urbanist": _peer_by_role.get(Role.URBANIST, 0),
		}
	}
	for peer_id in _net_mgr.players.keys():
		if peer_id != _net_mgr.get_local_id():
			_net_mgr.send_message(peer_id, _net_mgr.MessageType.ROLE_ASSIGN, payload, true)

# ─────────────────────────────────────────────────────────────────────────────
# NETWORK STATE SYNC
# ─────────────────────────────────────────────────────────────────────────────

func _broadcast_state() -> void:
	if not _is_server() or _net_mgr == null:
		return

	var server_id: int = _net_mgr.get_local_id()

	for peer_id in _net_mgr.players.keys():
		if peer_id == server_id:
			continue

		var payload := _build_state_payload(peer_id)
		_net_mgr.send_message(peer_id, _net_mgr.MessageType.GAME_STATE, payload, true)


func _build_state_payload(peer_id: int) -> Dictionary:
	var payload := {
		"phase": int(phase),
		"turn": turn_index,
		"revealed_indices": revealed_indices,
		"nominations": GameProtocol.serialize_nominations(nominations),
		"sub_phase": _sub_phase,
		"commits": _get_commit_status(),
		"scores": scores,
		"phase_deadline": phase_end_time,
		"last_placement": _serialize_placement(last_placement),
		"town_center": GameProtocol.serialize_town_center(town_center),
		"built_hexes": _serialize_built_hexes(),
		"turn_history": GameProtocol.serialize_turn_history(turn_history),
	}

	# Hand depends on role
	var role: Role = _role_by_peer.get(peer_id, Role.MAYOR)
	var hand_payload := GameProtocol.serialize_hand_for_role(int(role), hand, revealed_indices)
	if not hand_payload.is_empty():
		payload["hand"] = hand_payload

	# Visibility for advisors
	var vis_data: Array = _visibility_payload_for_role(role)
	if not vis_data.is_empty():
		payload["visibility"] = vis_data

	# Fog
	var fog_data: Array = _fog_payload()
	if not fog_data.is_empty():
		payload["fog"] = fog_data

	return payload


func _visibility_payload_for_role(role: Role) -> Array:
	if _hex_field == null or _hex_field.map_layers == null:
		return []

	# Mayor doesn't see reality at all
	if role == Role.MAYOR:
		return []

	# Advisors see all tiles on the playable frontier
	# The frontier = all hexes adjacent to any built hex
	var result: Array = []
	var frontier: Array[Vector3i] = GameRules.get_playable_frontier(built_hexes)
	for cube in frontier:
		var card: Dictionary = _hex_field.map_layers.get_card(cube)
		result.append(GameProtocol.serialize_visibility_entry(cube, card))
	return result


func _fog_payload() -> Array:
	if _hex_field == null:
		return []
	# Return all revealed hexes: each built hex and its surrounding ring
	var visible: Array = []
	var seen: Dictionary = {}
	for built in built_hexes:
		if not seen.has(built):
			visible.append(built)
			seen[built] = true
		for adj in GameRules.get_adjacent_hexes(built):
			if not seen.has(adj):
				visible.append(adj)
				seen[adj] = true
	return visible


func _get_commit_status() -> Dictionary:
	# Returns commit progress for each advisor (count/2) and current sub-phase
	var ind: Array = advisor_commits.get("industry", [])
	var urb: Array = advisor_commits.get("urbanist", [])
	return {
		"industry": ind.size(), # 0, 1, or 2
		"urbanist": urb.size(), # 0, 1, or 2
		"industry_done": ind.size() >= 2,
		"urbanist_done": urb.size() >= 2,
		"sub_phase": _sub_phase,
	}


## Check if a hex was nominated by either advisor
func _is_nominated_hex(hex: Vector3i) -> bool:
	for nom in nominations:
		if nom.get("hex", INVALID_HEX) == hex:
			return true
	return false


## Get which role nominated the given hex
## If both nominated the same hex, winner is determined by claim value proximity
## to placed card value, with suit as tiebreaker
func _get_nominating_role(hex: Vector3i, placed_card: Dictionary = {}) -> String:
	var nominators: Array[String] = []
	var nominations_for_hex: Array[Dictionary] = []

	for nom in nominations:
		if nom.get("hex", INVALID_HEX) == hex:
			var advisor: String = nom.get("advisor", "")
			if advisor and advisor not in nominators:
				nominators.append(advisor)
				nominations_for_hex.append(nom)

	if nominators.is_empty():
		return ""

	if nominators.size() == 1:
		return nominators[0]

	# Both nominated same hex - determine winner by claim proximity
	var placed_value: int = placed_card.get("value", 0)
	var placed_suit: int = placed_card.get("suit", -1)
	var best_advisor: String = ""
	var best_diff: int = 999
	var best_suit_match: bool = false

	for nom in nominations_for_hex:
		var claim: Dictionary = nom.get("claim", {})
		var claim_value: int = claim.get("value", 0)
		var claim_suit: int = claim.get("suit", -1)
		var diff: int = abs(claim_value - placed_value)
		var suit_match: bool = (claim_suit == placed_suit)

		if diff < best_diff or (diff == best_diff and suit_match and not best_suit_match):
			best_diff = diff
			best_advisor = nom.get("advisor", "")
			best_suit_match = suit_match

	return best_advisor if best_advisor else nominators[0]


# ─────────────────────────────────────────────────────────────────────────────
# NETWORK MESSAGE HANDLING
# ─────────────────────────────────────────────────────────────────────────────

func _on_game_message(type: int, from_id: int, data: Dictionary) -> void:
	if _is_server():
		if type == _net_mgr.MessageType.GAME_INTENT:
			_handle_intent(from_id, data)
		return

	match type:
		_net_mgr.MessageType.ROLE_ASSIGN:
			_apply_roles(data)
		_net_mgr.MessageType.GAME_STATE:
			_apply_game_state(data)


func _handle_intent(from_id: int, data: Dictionary) -> void:
	var action: String = data.get("action", "")
	var role: Role = _role_by_peer.get(from_id, Role.MAYOR)

	match action:
		"reveal":
			if role == Role.MAYOR:
				reveal_card(data.get("index", 0))
		"commit":
			var intent_role: int = data.get("role", -1)
			if intent_role == int(role): # Verify sender matches claimed role
				var cube_arr: Array = data.get("cube", [])
				if cube_arr.size() == 3:
					var cube := Vector3i(cube_arr[0], cube_arr[1], cube_arr[2])
					var claim: Dictionary = data.get("claim", {})
					commit_nomination(role, cube, claim)
		"place":
			if role == Role.MAYOR:
				var cube_arr: Array = data.get("cube", [])
				if cube_arr.size() == 3:
					var cube := Vector3i(cube_arr[0], cube_arr[1], cube_arr[2])
					place_card(data.get("card_index", 0), cube)


func _apply_roles(data: Dictionary) -> void:
	if not data.has("roles"):
		return
	var roles: Dictionary = data["roles"]
	_role_by_peer.clear()
	_peer_by_role.clear()

	for role_name in roles.keys():
		var peer_id: int = roles[role_name]
		var role: Role
		match role_name:
			"mayor": role = Role.MAYOR
			"industry": role = Role.INDUSTRY
			"urbanist": role = Role.URBANIST
			_: continue
		_peer_by_role[role] = peer_id
		_role_by_peer[peer_id] = role

	if _net_mgr:
		var my_id: int = _net_mgr.get_local_id()
		local_role = _role_by_peer.get(my_id, Role.MAYOR)
		DebugLogger.log("GameManager: My role is %s (peer %d)" % [Role.keys()[local_role], my_id])


func _apply_game_state(data: Dictionary) -> void:
	var old_phase: int = phase
	phase = data.get("phase", phase)
	phase_end_time = data.get("phase_deadline", 0)
	turn_index = data.get("turn", turn_index)
	revealed_indices = data.get("revealed_indices", revealed_indices)
	nominations = GameProtocol.deserialize_nominations(data.get("nominations", []))
	_sub_phase = data.get("sub_phase", "industry_commit_1")
	scores = data.get("scores", scores)
	last_placement = _deserialize_placement(data.get("last_placement", {}))

	if data.has("turn_history"):
		turn_history = GameProtocol.deserialize_turn_history(data.get("turn_history", []))

	if data.has("built_hexes"):
		built_hexes.clear()
		for h in data["built_hexes"]:
			if h.size() == 3:
				built_hexes.append(Vector3i(h[0], h[1], h[2]))

	if data.has("town_center"):
		var tc: Array = data["town_center"]
		if tc.size() == 3:
			town_center = Vector3i(tc[0], tc[1], tc[2])

	if data.has("hand"):
		var hp: Dictionary = data["hand"]
		hand.clear()
		var cards: Array = hp.get("cards", hp.get("visible", []))
		for c in cards:
			hand.append(c)

	if data.has("visibility"):
		advisor_visibility.clear()
		for v in data["visibility"]:
			advisor_visibility.append(v)
		visibility_updated.emit(advisor_visibility)

	if data.has("fog"):
		local_fog.clear()
		for f in data["fog"]:
			local_fog.append(f)
		fog_updated.emit(local_fog)

	hand_updated.emit(hand, revealed_indices)
	nominations_updated.emit(nominations)
	scores_updated.emit(scores)

	if data.has("commits"):
		commits_updated.emit(data["commits"])

	if phase != old_phase:
		phase_changed.emit(phase)

# ─────────────────────────────────────────────────────────────────────────────
# PLAYER JOIN/LEAVE
# ─────────────────────────────────────────────────────────────────────────────

## Called when a hex is clicked on the map (from HexField)
func on_hex_clicked(cube: Vector3i) -> void:
	DebugLogger.log("GameManager: Hex clicked (%d,%d,%d) in phase %s, role %s" % [
		cube.x, cube.y, cube.z, Phase.keys()[phase], Role.keys()[local_role]
	])
	# This is just a passthrough - the HUD handles selection state
	# and calls commit_nomination or place_card when buttons are clicked


func _on_player_joined(peer_id: int) -> void:
	DebugLogger.log("GameManager: Player %d joined" % peer_id)

	if _is_server():
		var count: int = _net_mgr.players.size() if _net_mgr else 1
		player_count_changed.emit(count, REQUIRED_PLAYERS)

		if phase != Phase.LOBBY:
			_assign_roles()
			_broadcast_roles()
			_broadcast_state()


func _on_player_left(peer_id: int) -> void:
	DebugLogger.log("GameManager: Player %d left" % peer_id)

	if _is_server():
		var count: int = _net_mgr.players.size() if _net_mgr else 1
		player_count_changed.emit(count, REQUIRED_PLAYERS)
		_assign_roles()
		_broadcast_roles()

# ─────────────────────────────────────────────────────────────────────────────
# BOT ACTIONS
# ─────────────────────────────────────────────────────────────────────────────

## Check if a role is controlled by a bot
func is_bot_role(role: Role) -> bool:
	return role in _bot_roles


## Set which roles are controlled by bots
func set_bot_roles(roles: Array[Role]) -> void:
	_bot_roles = roles
	DebugLogger.log("GameManager: Bot roles set to %s" % [roles.map(func(r): return Role.keys()[r])])


## Request bot action for a role (called by phase handlers or externally)
func request_bot_action(role: Role) -> void:
	# #region agent log
	_debug_log("B", "request_bot_action_entry", {"role": Role.keys()[role], "is_bot": is_bot_role(role), "rl_client_exists": _rl_client != null, "bot_roles": _bot_roles.map(func(r): return Role.keys()[r])})
	# #endregion
	if not is_bot_role(role):
		return

	DebugLogger.log("GameManager: Requesting bot action for %s" % Role.keys()[role])

	# Add delay for visual feedback
	if bot_action_delay > 0:
		await get_tree().create_timer(bot_action_delay).timeout

	# Build observation
	var observation := _build_bot_observation(role)

	# #region agent log
	var _rl_connected: bool = false
	if _rl_client:
		_rl_connected = _rl_client.is_connected_to_server()
	var _frontier_count: int = observation.get("frontier_hexes", []).size()
	var _already_nom: Array = observation.get("already_nominated", [])
	_debug_log("H_D", "request_bot_action_observation", {"role": Role.keys()[role], "frontier_count": _frontier_count, "already_nominated_count": _already_nom.size(), "already_nominated": _already_nom, "sub_phase": _sub_phase})
	_debug_log("B", "request_bot_action_branch", {"role": Role.keys()[role], "rl_client_exists": _rl_client != null, "rl_connected": _rl_connected})
	# #endregion
	# Try RL client first, fall back to scripted
	if _rl_client and _rl_client.is_connected_to_server():
		# #region agent log
		_debug_log("B", "using_rl_client", {"role": Role.keys()[role]})
		# #endregion
		var action: Dictionary = await _rl_client.get_action_async(int(role), observation)
		_apply_bot_action(role, action)
	else:
		# #region agent log
		_debug_log("B", "using_scripted_fallback", {"role": Role.keys()[role], "reason": "no_rl_client" if not _rl_client else "not_connected"})
		# #endregion
		var action: Dictionary = _get_scripted_bot_action(role, observation)
		_apply_bot_action(role, action)


## Build observation dictionary for bot
func _build_bot_observation(role: Role) -> Dictionary:
	var full_frontier := GameRules.get_playable_frontier(built_hexes)

	var observation := {
		"phase": int(phase),
		"turn": turn_index,
		"scores": scores.duplicate(),
		"built_hexes": _serialize_built_hexes(),
		"frontier_hexes": GameProtocol.serialize_built_hexes(full_frontier),
	}

	# Add revealed cards (now 2 cards)
	var revealed_cards: Array = []
	for idx in revealed_indices:
		if idx >= 0 and idx < hand.size():
			revealed_cards.append(hand[idx].duplicate())
	if not revealed_cards.is_empty():
		observation["revealed_cards"] = revealed_cards
		# Also add singular revealed_card for Python server compatibility
		observation["revealed_card"] = revealed_cards[0]

	if role == Role.MAYOR:
		observation["hand"] = hand.duplicate(true)
		observation["nominations"] = GameProtocol.serialize_nominations(nominations)
	else:
		observation["nominations"] = GameProtocol.serialize_nominations(nominations)
		observation["sub_phase"] = _sub_phase

		# Get hexes already nominated by this advisor (to filter frontier)
		var role_key: String = _role_to_key(role)
		var already_nominated: Array[Vector3i] = []
		for nom in advisor_commits.get(role_key, []):
			var hex: Vector3i = nom.get("hex", GameRules.INVALID_HEX)
			if hex != GameRules.INVALID_HEX:
				already_nominated.append(hex)

		# Filter frontier to exclude already-nominated hexes
		var filtered_frontier: Array[Vector3i] = []
		for hex in full_frontier:
			if hex not in already_nominated:
				filtered_frontier.append(hex)

		# Override frontier_hexes with filtered version for advisors
		observation["frontier_hexes"] = GameProtocol.serialize_built_hexes(filtered_frontier)
		observation["already_nominated"] = GameProtocol.serialize_built_hexes(already_nominated)

		# Advisors see reality tiles (only for available hexes)
		if _hex_field and _hex_field.map_layers:
			var reality_tiles := {}
			for hex in filtered_frontier:
				var card: Dictionary = _hex_field.map_layers.get_card(hex)
				if not card.is_empty():
					reality_tiles[[hex.x, hex.y, hex.z]] = card
			observation["reality_tiles"] = reality_tiles

	return observation


## Get scripted bot action (fallback when RL server unavailable)
func _get_scripted_bot_action(role: Role, observation: Dictionary) -> Dictionary:
	var frontier: Array = observation.get("frontier_hexes", [])
	# Use revealed_cards (plural array) - bots use first revealed card for strategy
	var revealed_cards: Array = observation.get("revealed_cards", [])
	var revealed_card: Dictionary = revealed_cards[0] if not revealed_cards.is_empty() else {}

	if role == Role.MAYOR:
		if phase == Phase.DRAW:
			# Reveal a non-spade card
			var best_idx := 0
			var best_score := -100
			for i in range(hand.size()):
				var card: Dictionary = hand[i]
				var suit: int = card.get("suit", -1)
				var value: int = card.get("value", 0)
				var score: int = value if suit != MapLayers.Suit.SPADES else -10
				if score > best_score:
					best_score = score
					best_idx = i
			return {"card_index": best_idx, "action_type": "reveal"}

		elif phase == Phase.PLACE:
			# Simple: pick first card and first nomination from the array
			var nom_hexes: Array = []
			for nom in nominations:
				var hex: Vector3i = nom.get("hex", INVALID_HEX)
				if hex != INVALID_HEX and hex not in nom_hexes:
					nom_hexes.append(hex)

			if nom_hexes.is_empty():
				return {}

			return {
				"card_index": 0,
				"hex": [nom_hexes[0].x, nom_hexes[0].y, nom_hexes[0].z],
				"action_type": "place"
			}
	else:
		# Advisor: use strategic nomination
		# Need to exclude hexes already nominated by this advisor
		var revealed_suit: int = revealed_card.get("suit", -1)
		var revealed_value: int = revealed_card.get("value", 7)

		var visibility: Array = []
		var reality_tiles: Dictionary = observation.get("reality_tiles", {})
		for hex_key in reality_tiles:
			visibility.append({
				"cube": hex_key if hex_key is Array else [0, 0, 0],
				"card": reality_tiles[hex_key],
			})

		# Get hexes already nominated by this advisor (to avoid duplicates)
		var role_key: String = _role_to_key(role)
		var already_nominated: Array[Vector3i] = []
		for nom in advisor_commits.get(role_key, []):
			var hex: Vector3i = nom.get("hex", INVALID_HEX)
			if hex != INVALID_HEX:
				already_nominated.append(hex)

		# Filter visibility to exclude already nominated hexes
		var filtered_visibility: Array = []
		for entry in visibility:
			var cube_arr: Array = entry.get("cube", [])
			if cube_arr.size() != 3:
				continue
			var cube := Vector3i(cube_arr[0], cube_arr[1], cube_arr[2])
			if cube not in already_nominated:
				filtered_visibility.append(entry)

		# Determine which nomination this is (1st or 2nd)
		var is_second_nomination: bool = already_nominated.size() > 0

		var result := GameRules.pick_strategic_nomination(
			int(role),
			revealed_suit,
			filtered_visibility if is_second_nomination else visibility,
			built_hexes,
			revealed_value
		)

		return {
			"hex": [result.hex.x, result.hex.y, result.hex.z] if result.hex != INVALID_HEX else [0, 0, 0],
			"claim": result.get("claim", {}),
			"action_type": "nominate",
		}

	return {}


## Apply a bot action to the game
func _apply_bot_action(role: Role, action: Dictionary) -> void:
	# #region agent log
	_debug_log("F", "_apply_bot_action", {"role": Role.keys()[role], "action": action, "phase": Phase.keys()[phase]})
	# #endregion
	var action_type: String = action.get("action_type", "")

	if role == Role.MAYOR:
		if action_type == "reveal" or phase == Phase.DRAW:
			var card_index: int = action.get("card_index", 0)
			reveal_card(card_index)
		elif action_type == "place" or phase == Phase.PLACE:
			var card_index: int = action.get("card_index", 0)
			var hex_arr: Array = action.get("hex", [0, 0, 0])
			var hex := Vector3i(hex_arr[0], hex_arr[1], hex_arr[2])
			place_card(card_index, hex)
	else:
		# Advisor nomination
		if phase == Phase.NOMINATE:
			var hex_arr: Array = action.get("hex", [0, 0, 0])
			var hex := Vector3i(hex_arr[0], hex_arr[1], hex_arr[2])
			var claim: Dictionary = action.get("claim", {})
			# #region agent log
			_debug_log("F", "_apply_bot_action_commit", {"role": Role.keys()[role], "hex": [hex.x, hex.y, hex.z], "claim": claim})
			# #endregion
			commit_nomination(role, hex, claim)


## Trigger bot actions for the current phase (called after phase transitions)
func _trigger_bot_actions_if_needed() -> void:
	# #region agent log
	_debug_log("H_B", "_trigger_bot_actions_if_needed_entry", {"phase": Phase.keys()[phase], "sub_phase": _sub_phase, "bot_roles_empty": _bot_roles.is_empty()})
	# #endregion
	if _bot_roles.is_empty():
		return

	match phase:
		Phase.DRAW:
			if is_bot_role(Role.MAYOR):
				request_bot_action(Role.MAYOR)
		Phase.NOMINATE:
			# Use sub-phase to determine which advisor should act
			var expected_role := _get_expected_role_for_sub_phase()
			# #region agent log
			_debug_log("H_B", "_trigger_bot_actions_nominate", {"sub_phase": _sub_phase, "expected_role": expected_role, "is_bot": is_bot_role(expected_role as Role) if expected_role >= 0 else false})
			# #endregion
			if expected_role >= 0 and is_bot_role(expected_role as Role):
				request_bot_action(expected_role as Role)
		Phase.PLACE:
			if is_bot_role(Role.MAYOR):
				request_bot_action(Role.MAYOR)


## Get expected role for current sub-phase
func _get_expected_role_for_sub_phase() -> int:
	match _sub_phase:
		"industry_commit_1", "industry_commit_2":
			return int(Role.INDUSTRY)
		"urbanist_commit_1", "urbanist_commit_2":
			return int(Role.URBANIST)
		_:
			return -1


# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

func _is_server() -> bool:
	if _net_mgr == null:
		return true
	# If no active network connection, we're in local/singleplayer mode
	if _net_mgr.has_method("is_networked") and not _net_mgr.is_networked():
		return true
	return _net_mgr.is_server()


func _send_intent(action: String, payload: Dictionary) -> void:
	if _net_mgr == null:
		return
	var msg := payload.duplicate(true)
	msg["action"] = action
	_net_mgr.send_message(1, _net_mgr.MessageType.GAME_INTENT, msg, true)


func _role_to_key(role: Role) -> String:
	return GameProtocol.role_to_key(int(role))


func _hex_to_string(hex: Vector3i) -> String:
	return GameProtocol.hex_to_string(hex)


func _serialize_hex_dict(dict: Dictionary) -> Dictionary:
	return GameProtocol.serialize_hex_dict(dict)


func _deserialize_hex_dict(data: Dictionary) -> Dictionary:
	return GameProtocol.deserialize_hex_dict(data)


func _serialize_built_hexes() -> Array:
	return GameProtocol.serialize_built_hexes(built_hexes)


func _serialize_placement(p: Dictionary) -> Dictionary:
	return GameProtocol.serialize_placement(p)


func _deserialize_placement(data: Dictionary) -> Dictionary:
	return GameProtocol.deserialize_placement(data)


## Legacy compatibility: advisor_nominate calls commit_nomination
func advisor_nominate(role: int, cube: Vector3i, claimed_card: Dictionary = {}) -> void:
	commit_nomination(role as Role, cube, claimed_card)


## Legacy compatibility: mayor_place calls place_card
func mayor_place(card_index: int, cube: Vector3i) -> void:
	place_card(card_index, cube)


# #region agent log
const DEBUG_LOG_PATH := "/Users/sweater/Github/collapsization/.cursor/debug.log"

func _debug_log(hypothesis: String, message: String, data: Dictionary = {}) -> void:
	var log_entry := {
		"timestamp": Time.get_unix_time_from_system() * 1000,
		"location": "game_manager.gd",
		"hypothesisId": hypothesis,
		"message": message,
		"data": data,
		"sessionId": "debug-session"
	}
	var file := FileAccess.open(DEBUG_LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(DEBUG_LOG_PATH, FileAccess.WRITE)
	if file:
		file.seek_end()
		file.store_line(JSON.stringify(log_entry))
		file.close()
# #endregion
