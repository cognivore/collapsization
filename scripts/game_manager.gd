## Manages the game state machine, turn phases, and scoring.
## Action-driven transitions: phases change when players act, not on timers.
extends Node
class_name GameManager

const MapLayers := preload("res://scripts/map_layers.gd")
const GameRules := preload("res://scripts/game_rules.gd")
const GameProtocol := preload("res://scripts/game/game_protocol.gd")

# ─────────────────────────────────────────────────────────────────────────────
# SIGNALS
# ─────────────────────────────────────────────────────────────────────────────

signal phase_changed(phase: int)
signal hand_updated(hand: Array, revealed_index: int)
signal nominations_updated(nominations: Dictionary)
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
	DRAW, # Mayor has 3 cards, must reveal 1
	NOMINATE, # Advisors commit nominations (hidden until both commit)
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

# ─────────────────────────────────────────────────────────────────────────────
# STATE
# ─────────────────────────────────────────────────────────────────────────────

var phase: Phase = Phase.LOBBY
var phase_end_time: float = 0.0 # 0 = no timeout (action-driven)
var turn_index: int = 0

# Mayor's hand and reveal state
var hand: Array[Dictionary] = []
var revealed_index: int = -1

# Advisor nominations: committed (hidden) and revealed (shown)
# Format: {role: {hex: Vector3i, claim: Dictionary}}
var advisor_commits := {"industry": {}, "urbanist": {}}
var nominations := {"industry": {}, "urbanist": {}} # Revealed

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


## Start singleplayer mode (for testing and offline play)
func start_singleplayer() -> void:
	if phase != Phase.LOBBY:
		return
	local_role = Role.MAYOR
	_role_by_peer[1] = Role.MAYOR
	_peer_by_role[Role.MAYOR] = 1
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
		print("GameManager: Center shown as built A♥")

# ─────────────────────────────────────────────────────────────────────────────
# PHASE TRANSITIONS (action-driven)
# ─────────────────────────────────────────────────────────────────────────────

func _transition_to(new_phase: Phase) -> void:
	var old_phase := phase
	phase = new_phase
	phase_end_time = 0.0 # No timeouts - action driven

	match new_phase:
		Phase.DRAW:
			_enter_draw_phase()
		Phase.NOMINATE:
			_enter_nominate_phase()
		Phase.PLACE:
			_enter_place_phase()
		Phase.GAME_OVER:
			pass # Already handled by _finish_game

	print("GameManager: Phase %s -> %s" % [Phase.keys()[old_phase], Phase.keys()[new_phase]])
	phase_changed.emit(phase)
	_broadcast_state()


func _enter_draw_phase() -> void:
	hand = _draw_cards(3)
	revealed_index = -1
	advisor_commits = {"industry": {}, "urbanist": {}}
	nominations = {"industry": {}, "urbanist": {}}
	last_placement.clear()
	hand_updated.emit(hand, revealed_index)
	nominations_updated.emit(nominations) # Notify to clear nomination overlays
	print("GameManager: DRAW - Mayor has %d cards" % hand.size())


func _enter_nominate_phase() -> void:
	advisor_commits = {"industry": {}, "urbanist": {}}
	nominations = {"industry": {}, "urbanist": {}}
	nominations_updated.emit(nominations)
	commits_updated.emit(_get_commit_status())
	print("GameManager: NOMINATE - Advisors choose hexes")


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
	_transition_to(Phase.NOMINATE)


## Advisor commits their nomination with a claimed card (hidden until both commit)
func commit_nomination(role: Role, hex: Vector3i, claimed_card: Dictionary = {}) -> void:
	if not _is_server():
		_send_intent("commit", {
			"role": int(role),
			"cube": [hex.x, hex.y, hex.z],
			"claim": claimed_card
		})
		return

	if phase != Phase.NOMINATE:
		print("GameManager: Cannot commit - not in NOMINATE phase")
		return
	if not GameRules.is_valid_nomination(town_center, hex):
		print("GameManager: Invalid nomination hex")
		return
	if hex in built_hexes:
		print("GameManager: Cannot nominate already-built hex")
		return

	var role_key: String = _role_to_key(role)
	if role_key.is_empty():
		print("GameManager: Invalid role for nomination")
		return

	advisor_commits[role_key] = {"hex": hex, "claim": claimed_card}
	print("GameManager: %s committed nomination - %s at %s" % [
		role_key.capitalize(),
		MapLayers.label(claimed_card) if not claimed_card.is_empty() else "no claim",
		_hex_to_string(hex)
	])
	commits_updated.emit(_get_commit_status())
	_broadcast_state()

	if _all_advisors_committed():
		_reveal_nominations()


func _all_advisors_committed() -> bool:
	var ind: Dictionary = advisor_commits.get("industry", {})
	var urb: Dictionary = advisor_commits.get("urbanist", {})
	return not ind.is_empty() and not urb.is_empty()


func _reveal_nominations() -> void:
	nominations["industry"] = advisor_commits["industry"].duplicate(true)
	nominations["urbanist"] = advisor_commits["urbanist"].duplicate(true)

	var ind_hex: Vector3i = nominations["industry"].get("hex", INVALID_HEX)
	var urb_hex: Vector3i = nominations["urbanist"].get("hex", INVALID_HEX)
	var ind_claim: Dictionary = nominations["industry"].get("claim", {})
	var urb_claim: Dictionary = nominations["urbanist"].get("claim", {})

	print("GameManager: Nominations revealed - Industry: %s (%s), Urbanist: %s (%s)" % [
		_hex_to_string(ind_hex),
		MapLayers.label(ind_claim) if not ind_claim.is_empty() else "?",
		_hex_to_string(urb_hex),
		MapLayers.label(urb_claim) if not urb_claim.is_empty() else "?",
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
	if not _is_nominated_hex(hex):
		print("GameManager: Hex not nominated")
		return

	var card: Dictionary = hand[card_index]
	hand.remove_at(card_index)

	# Track built hex to prevent re-nomination
	built_hexes.append(hex)

	# Determine winning advisor (whose nomination was chosen)
	# If both nominated same hex, winner is determined by placed card suit
	var winning_role := _get_nominating_role(hex, card)
	var winning_claim: Dictionary = {}
	if not winning_role.is_empty():
		winning_claim = nominations[winning_role].get("claim", {})

	var placement := {
		"turn": turn_index,
		"card": card,
		"cube": hex,
		"winning_role": winning_role,
		"winning_claim": winning_claim
	}
	last_placement = placement
	_discard.append(card)

	print("GameManager: Mayor placed %s at %s (chosen by %s)" % [
		MapLayers.label(card), _hex_to_string(hex), winning_role.capitalize()
	])

	var score_deltas: Dictionary = _calculate_scores_with_claims(card, hex, nominations)
	scores["mayor"] += score_deltas["mayor"]
	scores["industry"] += score_deltas["industry"]
	scores["urbanist"] += score_deltas["urbanist"]

	placement_resolved.emit(turn_index, placement)
	scores_updated.emit(scores)
	hand_updated.emit(hand, revealed_index)
	_broadcast_state()

	# Check if the REALITY at this hex is SPADES (not the placed card!)
	# Game ends when Mayor builds on a tile that is actually a spade in reality
	var reality_is_spade := _check_reality_is_spade(hex, card)
	if reality_is_spade:
		_finish_game("Mayor built on a SPADE tile! (Advisor may have lied)")
		return

	turn_index += 1
	_transition_to(Phase.DRAW)


func _finish_game(reason: String) -> void:
	print("GameManager: GAME OVER - %s" % reason)
	print("GameManager: Final scores - Mayor: %d, Industry: %d, Urbanist: %d" % [
		scores["mayor"], scores["industry"], scores["urbanist"]
	])
	phase = Phase.GAME_OVER
	phase_end_time = 0.0

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
		print("GameManager: Reality at %s is SPADES! (%s)" % [
			_hex_to_string(hex),
			MapLayers.label(reality)
		])
	return has_spade


## Calculate scores for a placement using the new nomination format
## Nominations format: {role: {hex: Vector3i, claim: Dictionary}}
func _calculate_scores_with_claims(card: Dictionary, hex: Vector3i, noms: Dictionary) -> Dictionary:
	return GameRules.calculate_turn_scores(
		card,
		hex,
		noms,
		Callable(self, "_get_reality")
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
		"nominations": GameProtocol.serialize_nominations(nominations),
		"commits": _get_commit_status(),
		"scores": scores,
		"phase_deadline": phase_end_time,
		"last_placement": _serialize_placement(last_placement),
		"town_center": [town_center.x, town_center.y, town_center.z],
		"built_hexes": _serialize_built_hexes(),
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

	# Advisors don't see visibility (Mayor doesn't get visibility at all)
	if role == Role.MAYOR:
		return []

	# Advisors (Industry and Urbanist) see the single reality layer
	var result: Array = []
	for cube in _hex_field.cube_ring(town_center, 1):
		var card: Dictionary = _hex_field.map_layers.get_card(cube)
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
	var ind: Dictionary = advisor_commits.get("industry", {})
	var urb: Dictionary = advisor_commits.get("urbanist", {})
	return {
		"industry": not ind.is_empty(),
		"urbanist": not urb.is_empty(),
	}


## Check if a hex was nominated by either advisor
func _is_nominated_hex(hex: Vector3i) -> bool:
	var ind: Dictionary = nominations.get("industry", {})
	var urb: Dictionary = nominations.get("urbanist", {})
	return ind.get("hex", INVALID_HEX) == hex or urb.get("hex", INVALID_HEX) == hex


## Get which role nominated the given hex
## If both nominated the same hex, winner is determined by placed card suit:
## - DIAMONDS → Industry wins (their suit)
## - HEARTS → Urbanist wins (their suit)
func _get_nominating_role(hex: Vector3i, placed_card: Dictionary = {}) -> String:
	var ind: Dictionary = nominations.get("industry", {})
	var urb: Dictionary = nominations.get("urbanist", {})
	var ind_hex: Vector3i = ind.get("hex", INVALID_HEX)
	var urb_hex: Vector3i = urb.get("hex", INVALID_HEX)
	var ind_nominated: bool = (ind_hex == hex)
	var urb_nominated: bool = (urb_hex == hex)

	# If both nominated the same hex, determine winner by placed card suit
	if ind_nominated and urb_nominated:
		var suit: int = placed_card.get("suit", -1)
		match suit:
			MapLayers.Suit.DIAMONDS:
				return "industry" # Industry's suit
			MapLayers.Suit.HEARTS:
				return "urbanist" # Urbanist's suit
			_:
				# Spades or unknown - no clear winner, default to industry
				return "industry"

	# Only one nominated this hex
	if ind_nominated:
		return "industry"
	if urb_nominated:
		return "urbanist"
	return ""


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
		print("GameManager: My role is %s (peer %d)" % [Role.keys()[local_role], my_id])


func _apply_game_state(data: Dictionary) -> void:
	var old_phase: int = phase
	phase = data.get("phase", phase)
	phase_end_time = data.get("phase_deadline", 0)
	turn_index = data.get("turn", turn_index)
	revealed_index = data.get("revealed_index", revealed_index)
	nominations = GameProtocol.deserialize_nominations(data.get("nominations", {}))
	scores = data.get("scores", scores)
	last_placement = _deserialize_placement(data.get("last_placement", {}))

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
	var result: Array = []
	for h in built_hexes:
		result.append([h.x, h.y, h.z])
	return result


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
