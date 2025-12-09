## Manages the game state machine, turn phases, and scoring.
## Action-driven transitions: phases change when players act, not on timers.
extends Node
class_name GameManager

const MapLayers := preload("res://scripts/map_layers.gd")
const GameRules := preload("res://scripts/game_rules.gd")

# ─────────────────────────────────────────────────────────────────────────────
# SIGNALS
# ─────────────────────────────────────────────────────────────────────────────

signal phase_changed(phase: int)
signal hand_updated(hand: Array, revealed_index: int)
signal nominations_updated(nominations: Dictionary)
signal commits_updated(commits: Dictionary)  # For showing commit status without hex
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
	LOBBY,      # Waiting for 3 players
	DRAW,       # Mayor has 3 cards, must reveal 1
	NOMINATE,   # Advisors commit nominations (hidden until both commit)
	PLACE,      # Mayor picks card + nominated hex
	GAME_OVER,  # Spade placed or error
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

# ─────────────────────────────────────────────────────────────────────────────
# STATE
# ─────────────────────────────────────────────────────────────────────────────

var phase: Phase = Phase.LOBBY
var phase_end_time: float = 0.0  # 0 = no timeout (action-driven)
var turn_index: int = 0

# Mayor's hand and reveal state
var hand: Array[Dictionary] = []
var revealed_index: int = -1

# Advisor nominations: committed (hidden) and revealed (shown)
var advisor_commits := {"industry": INVALID_HEX, "urbanist": INVALID_HEX}
var nominations := {"industry": INVALID_HEX, "urbanist": INVALID_HEX}  # Revealed

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

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_bind_hex_field()
	_bind_network()


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


func _initialize_game() -> void:
	_rng = RandomNumberGenerator.new()
	if game_seed >= 0:
		_rng.seed = game_seed
	else:
		_rng.randomize()
	print("GameManager: Starting game with seed=%d" % _rng.seed)

	_build_deck()
	_discard.clear()
	turn_index = 0
	scores = {"mayor": 0, "industry": 0, "urbanist": 0}

	_emit_initial_fog()
	_transition_to(Phase.DRAW)

# ─────────────────────────────────────────────────────────────────────────────
# PHASE TRANSITIONS (action-driven)
# ─────────────────────────────────────────────────────────────────────────────

func _transition_to(new_phase: Phase) -> void:
	var old_phase := phase
	phase = new_phase
	phase_end_time = 0.0  # No timeouts - action driven

	match new_phase:
		Phase.DRAW:
			_enter_draw_phase()
		Phase.NOMINATE:
			_enter_nominate_phase()
		Phase.PLACE:
			_enter_place_phase()
		Phase.GAME_OVER:
			pass  # Already handled by _finish_game

	print("GameManager: Phase %s -> %s" % [Phase.keys()[old_phase], Phase.keys()[new_phase]])
	phase_changed.emit(phase)
	_broadcast_state()


func _enter_draw_phase() -> void:
	hand = _draw_cards(3)
	revealed_index = -1
	advisor_commits = {"industry": INVALID_HEX, "urbanist": INVALID_HEX}
	nominations = {"industry": INVALID_HEX, "urbanist": INVALID_HEX}
	last_placement.clear()
	print("GameManager: DRAW - Mayor has %d cards" % hand.size())
	hand_updated.emit(hand, revealed_index)


func _enter_nominate_phase() -> void:
	advisor_commits = {"industry": INVALID_HEX, "urbanist": INVALID_HEX}
	nominations = {"industry": INVALID_HEX, "urbanist": INVALID_HEX}
	print("GameManager: NOMINATE - Advisors choose hexes")
	nominations_updated.emit(nominations)
	commits_updated.emit(_get_commit_status())


func _enter_place_phase() -> void:
	print("GameManager: PLACE - Mayor chooses where to build")

# ─────────────────────────────────────────────────────────────────────────────
# PLAYER ACTIONS
# ─────────────────────────────────────────────────────────────────────────────

## Mayor reveals one of their 3 cards -> transitions to NOMINATE
func reveal_card(index: int) -> void:
	if not _is_server():
		_send_intent("reveal", {"index": index})
		return

	if phase != Phase.DRAW:
		print("GameManager: Cannot reveal - not in DRAW phase")
		return
	if not GameRules.is_valid_card_index(index, hand.size()):
		print("GameManager: Invalid card index %d" % index)
		return
	if revealed_index >= 0:
		print("GameManager: Card already revealed")
		return

	revealed_index = index
	var card: Dictionary = hand[index]
	print("GameManager: Mayor revealed card %d: %s" % [index, MapLayers.label(card)])
	hand_updated.emit(hand, revealed_index)

	# Transition to NOMINATE phase
	_transition_to(Phase.NOMINATE)


## Advisor commits their nomination (hidden until both commit)
func commit_nomination(role: Role, hex: Vector3i) -> void:
	if not _is_server():
		_send_intent("commit", {"role": int(role), "cube": [hex.x, hex.y, hex.z]})
		return

	if phase != Phase.NOMINATE:
		print("GameManager: Cannot commit - not in NOMINATE phase")
		return
	if not GameRules.is_valid_nomination(town_center, hex):
		print("GameManager: Invalid nomination hex")
		return

	var role_key: String = _role_to_key(role)
	if role_key.is_empty():
		print("GameManager: Invalid role for nomination")
		return

	advisor_commits[role_key] = hex
	print("GameManager: %s committed nomination" % role_key.capitalize())
	commits_updated.emit(_get_commit_status())
	_broadcast_state()

	# Check if both advisors have committed
	if GameRules.all_advisors_committed(advisor_commits):
		_reveal_nominations()


func _reveal_nominations() -> void:
	# Copy commits to revealed nominations
	nominations["industry"] = advisor_commits["industry"]
	nominations["urbanist"] = advisor_commits["urbanist"]

	print("GameManager: Nominations revealed - Industry: %s, Urbanist: %s" % [
		_hex_to_string(nominations["industry"]),
		_hex_to_string(nominations["urbanist"]),
	])

	nominations_updated.emit(nominations)
	_transition_to(Phase.PLACE)


## Mayor places a card on a nominated hex
func place_card(card_index: int, hex: Vector3i) -> void:
	if not _is_server():
		_send_intent("place", {"card_index": card_index, "cube": [hex.x, hex.y, hex.z]})
		return

	if phase != Phase.PLACE:
		print("GameManager: Cannot place - not in PLACE phase")
		return
	if not GameRules.is_valid_card_index(card_index, hand.size()):
		print("GameManager: Invalid card index")
		return
	if not GameRules.is_nominated_hex(hex, nominations):
		print("GameManager: Hex not nominated")
		return

	var card: Dictionary = hand[card_index]
	hand.remove_at(card_index)

	var placement := {"turn": turn_index, "card": card, "cube": hex}
	last_placement = placement
	_discard.append(card)

	print("GameManager: Mayor placed %s at %s" % [MapLayers.label(card), _hex_to_string(hex)])

	# Calculate scores
	var score_deltas: Dictionary = GameRules.calculate_turn_scores(
		card, hex, nominations, _get_reality
	)
	scores["mayor"] += score_deltas["mayor"]
	scores["industry"] += score_deltas["industry"]
	scores["urbanist"] += score_deltas["urbanist"]

	placement_resolved.emit(turn_index, placement)
	scores_updated.emit(scores)
	hand_updated.emit(hand, revealed_index)
	_broadcast_state()

	# Check if game ends (spade)
	if GameRules.is_spade(card):
		_finish_game("Mayor built on SPADES!")
		return

	# Next turn
	turn_index += 1
	_transition_to(Phase.DRAW)


func _finish_game(reason: String) -> void:
	print("GameManager: GAME OVER - %s" % reason)
	print("GameManager: Final scores - Mayor: %d, Industry: %d, Urbanist: %d" % [
		scores["mayor"], scores["industry"], scores["urbanist"]
	])
	phase = Phase.GAME_OVER
	phase_end_time = 0.0
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
	while count > 0 and not _deck.is_empty():
		drawn.append(_deck.pop_back())
		count -= 1
	if _deck.is_empty():
		_recycle_discard()
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
	print("GameManager: Initial fog revealed for %d hexes" % visible_cubes.size())


func _get_reality(layer_type: int, cube: Vector3i) -> Dictionary:
	if _hex_field and _hex_field.map_layers:
		return _hex_field.map_layers.get_card(layer_type, cube)
	return {}

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

	print("GameManager: Roles - Mayor=%d, Industry=%d, Urbanist=%d" % [
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
		"revealed_index": revealed_index,
		"nominations": _serialize_hex_dict(nominations),
		"commits": _get_commit_status(),
		"scores": scores,
		"phase_deadline": phase_end_time,
		"last_placement": _serialize_placement(last_placement),
		"town_center": [town_center.x, town_center.y, town_center.z],
	}

	# Hand depends on role
	var role: Role = _role_by_peer.get(peer_id, Role.MAYOR)
	if role == Role.MAYOR:
		payload["hand"] = {"cards": hand, "revealed_index": revealed_index}
	elif revealed_index >= 0 and revealed_index < hand.size():
		payload["hand"] = {"visible": [hand[revealed_index]], "revealed_index": revealed_index}

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

	var layer_type: int = -1
	match role:
		Role.INDUSTRY:
			layer_type = MapLayers.LayerType.RESOURCES
		Role.URBANIST:
			layer_type = MapLayers.LayerType.DESIRABILITY
		_:
			return []

	var result: Array = []
	for cube in _hex_field.cube_ring(town_center, 1):
		var card: Dictionary = _hex_field.map_layers.get_card(layer_type, cube)
		result.append({"cube": [cube.x, cube.y, cube.z], "card": card})
	return result


func _fog_payload() -> Array:
	if _hex_field == null:
		return []
	var visible: Array = [town_center]
	for cube in _hex_field.cube_ring(town_center, 1):
		visible.append(cube)
	return visible


func _get_commit_status() -> Dictionary:
	# Returns which advisors have committed (true/false), not the actual hexes
	return {
		"industry": advisor_commits["industry"] != INVALID_HEX,
		"urbanist": advisor_commits["urbanist"] != INVALID_HEX,
	}

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
			if intent_role == int(role):  # Verify sender matches claimed role
				var cube_arr: Array = data.get("cube", [])
				if cube_arr.size() == 3:
					var cube := Vector3i(cube_arr[0], cube_arr[1], cube_arr[2])
					commit_nomination(role, cube)
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
		print("GameManager: My role is %s (peer %d)" % [Role.keys()[local_role], my_id])


func _apply_game_state(data: Dictionary) -> void:
	var old_phase: int = phase
	phase = data.get("phase", phase)
	phase_end_time = data.get("phase_deadline", 0)
	turn_index = data.get("turn", turn_index)
	revealed_index = data.get("revealed_index", revealed_index)
	nominations = _deserialize_hex_dict(data.get("nominations", {}))
	scores = data.get("scores", scores)
	last_placement = _deserialize_placement(data.get("last_placement", {}))

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

	hand_updated.emit(hand, revealed_index)
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
	print("GameManager: Hex clicked (%d,%d,%d) in phase %s, role %s" % [
		cube.x, cube.y, cube.z, Phase.keys()[phase], Role.keys()[local_role]
	])
	# This is just a passthrough - the HUD handles selection state
	# and calls commit_nomination or place_card when buttons are clicked


func _on_player_joined(peer_id: int) -> void:
	print("GameManager: Player %d joined" % peer_id)

	if _is_server():
		var count: int = _net_mgr.players.size() if _net_mgr else 1
		player_count_changed.emit(count, REQUIRED_PLAYERS)

		if phase != Phase.LOBBY:
			_assign_roles()
			_broadcast_roles()
			_broadcast_state()


func _on_player_left(peer_id: int) -> void:
	print("GameManager: Player %d left" % peer_id)

	if _is_server():
		var count: int = _net_mgr.players.size() if _net_mgr else 1
		player_count_changed.emit(count, REQUIRED_PLAYERS)
		_assign_roles()
		_broadcast_roles()

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

func _is_server() -> bool:
	if _net_mgr == null:
		return true
	return _net_mgr.is_server()


func _send_intent(action: String, payload: Dictionary) -> void:
	if _net_mgr == null:
		return
	var msg := payload.duplicate(true)
	msg["action"] = action
	_net_mgr.send_message(1, _net_mgr.MessageType.GAME_INTENT, msg, true)


func _role_to_key(role: Role) -> String:
	match role:
		Role.INDUSTRY: return "industry"
		Role.URBANIST: return "urbanist"
		_: return ""


func _hex_to_string(hex: Vector3i) -> String:
	if hex == INVALID_HEX:
		return "none"
	return "(%d,%d,%d)" % [hex.x, hex.y, hex.z]


func _serialize_hex_dict(dict: Dictionary) -> Dictionary:
	var result := {}
	for key in dict.keys():
		var cube: Vector3i = dict[key]
		result[key] = [cube.x, cube.y, cube.z]
	return result


func _deserialize_hex_dict(data: Dictionary) -> Dictionary:
	var result := {}
	for key in data.keys():
		var arr: Array = data[key]
		if arr.size() == 3:
			result[key] = Vector3i(arr[0], arr[1], arr[2])
		else:
			result[key] = INVALID_HEX
	return result


func _serialize_placement(p: Dictionary) -> Dictionary:
	if p.is_empty():
		return {}
	var cube: Vector3i = p.get("cube", INVALID_HEX)
	return {
		"turn": p.get("turn", 0),
		"card": p.get("card", {}),
		"cube": [cube.x, cube.y, cube.z],
	}


func _deserialize_placement(data: Dictionary) -> Dictionary:
	if data.is_empty():
		return {}
	var arr: Array = data.get("cube", [])
	var cube: Vector3i = INVALID_HEX
	if arr.size() == 3:
		cube = Vector3i(arr[0], arr[1], arr[2])
	return {
		"turn": data.get("turn", 0),
		"card": data.get("card", {}),
		"cube": cube,
	}


## Legacy compatibility: advisor_nominate calls commit_nomination
func advisor_nominate(role: int, cube: Vector3i) -> void:
	commit_nomination(role as Role, cube)


## Legacy compatibility: mayor_place calls place_card
func mayor_place(card_index: int, cube: Vector3i) -> void:
	place_card(card_index, cube)
