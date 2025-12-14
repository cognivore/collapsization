## WebSocket client for RL bot inference server.
## Connects to the Python inference server and requests actions for bot-controlled roles.
## Falls back to scripted bots (GameRules.pick_strategic_nomination) on connection failure.
extends Node
class_name RLClient

const GameRules := preload("res://scripts/game_rules.gd")
const MapLayers := preload("res://scripts/map_layers.gd")
const DebugLogger := preload("res://scripts/debug/debug_logger.gd")

# ─────────────────────────────────────────────────────────────────────────────
# SIGNALS
# ─────────────────────────────────────────────────────────────────────────────

signal connected()
signal disconnected()
signal action_received(role: int, action: Dictionary)
signal error(message: String)

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_SERVER_URL := "ws://localhost:8765"
const RECONNECT_DELAY := 5.0
const REQUEST_TIMEOUT := 3.0

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────

@export var server_url: String = DEFAULT_SERVER_URL
@export var auto_connect: bool = false
@export var auto_reconnect: bool = true

# ─────────────────────────────────────────────────────────────────────────────
# STATE
# ─────────────────────────────────────────────────────────────────────────────

var _socket: WebSocketPeer
var _is_connected: bool = false
var _pending_requests: Dictionary = {} # request_id -> {callback: Callable, timeout: float}
var _request_counter: int = 0
var _reconnect_timer: Timer
var _game_id: String = "" # Unique game session ID for multiplayer support

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_socket = WebSocketPeer.new()

	# Setup reconnect timer
	_reconnect_timer = Timer.new()
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_on_reconnect_timeout)
	add_child(_reconnect_timer)

	if auto_connect:
		connect_to_server()


func _process(_delta: float) -> void:
	if _socket == null:
		return

	_socket.poll()

	var state := _socket.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			if not _is_connected:
				_is_connected = true
				DebugLogger.log("RLClient: Connected to %s" % server_url)
				connected.emit()

			# Process incoming messages
			while _socket.get_available_packet_count() > 0:
				var packet := _socket.get_packet()
				_handle_message(packet.get_string_from_utf8())

		WebSocketPeer.STATE_CLOSING:
			pass # Wait for close

		WebSocketPeer.STATE_CLOSED:
			if _is_connected:
				_is_connected = false
				var code := _socket.get_close_code()
				var reason := _socket.get_close_reason()
				DebugLogger.log("RLClient: Disconnected (code=%d, reason=%s)" % [code, reason])
				disconnected.emit()

				if auto_reconnect:
					_schedule_reconnect()

	# Check for timed out requests
	_check_request_timeouts()


func _exit_tree() -> void:
	disconnect_from_server()

# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

## Connect to the inference server
func connect_to_server(url: String = "") -> void:
	if url != "":
		server_url = url

	if _is_connected:
		disconnect_from_server()

	DebugLogger.log("RLClient: Connecting to %s" % server_url)
	var err := _socket.connect_to_url(server_url)
	if err != OK:
		DebugLogger.log("RLClient: Failed to connect: %d" % err)
		error.emit("Failed to connect: %d" % err)
		if auto_reconnect:
			_schedule_reconnect()


## Disconnect from the server
func disconnect_from_server() -> void:
	if _socket != null:
		_socket.close()
	_is_connected = false
	_pending_requests.clear()


## Check if connected to server
func is_connected_to_server() -> bool:
	return _is_connected


## Start a new game session with the inference server
## Call this when a new game begins to enable per-game tracking
func start_game_session(game_seed: int = -1, metadata: Dictionary = {}) -> void:
	_game_id = _generate_game_id()

	if not _is_connected:
		DebugLogger.log("RLClient: Not connected, game_id set locally: %s" % _game_id)
		return

	var request := {
		"type": "start_game",
		"game_id": _game_id,
		"seed": game_seed,
		"metadata": metadata,
	}

	_socket.send_text(JSON.stringify(request))
	DebugLogger.log("RLClient: Started game session %s" % _game_id)


## End the current game session
## Call this when a game ends to clean up server-side tracking
func end_game_session() -> void:
	if _game_id == "":
		return

	if _is_connected:
		var request := {
			"type": "end_game",
			"game_id": _game_id,
		}
		_socket.send_text(JSON.stringify(request))
		DebugLogger.log("RLClient: Ended game session %s" % _game_id)

	_game_id = ""


## Get the current game session ID
func get_game_id() -> String:
	return _game_id


## Generate a unique game ID
func _generate_game_id() -> String:
	# Format: timestamp-random for uniqueness
	var timestamp := Time.get_unix_time_from_system()
	var random_part := randi() % 10000
	return "%d-%04d" % [int(timestamp), random_part]


## Request an action for a bot-controlled role
## Returns a Promise-like pattern via signals, or use await with get_action_async
func request_action(role: int, observation: Dictionary) -> void:
	if not _is_connected:
		DebugLogger.log("RLClient: Not connected, cannot request action")
		error.emit("Not connected to inference server")
		return

	_request_counter += 1
	var request_id := _request_counter

	var request := {
		"type": "get_action",
		"request_id": request_id,
		"game_id": _game_id if _game_id != "" else "default",
		"player": role,
		"observation": observation,
	}

	_pending_requests[request_id] = {
		"role": role,
		"timestamp": Time.get_ticks_msec(),
	}

	var json_str := JSON.stringify(request)
	_socket.send_text(json_str)
	DebugLogger.log("RLClient: Sent action request for role %d (id=%d, game=%s)" % [role, request_id, _game_id])


## Async version of request_action - returns the action directly
func get_action_async(role: int, observation: Dictionary) -> Dictionary:
	if not _is_connected:
		DebugLogger.log("RLClient: Not connected, using fallback")
		return _get_fallback_action(role, observation)

	_request_counter += 1
	var request_id := _request_counter

	var request := {
		"type": "get_action",
		"request_id": request_id,
		"game_id": _game_id if _game_id != "" else "default",
		"player": role,
		"observation": observation,
	}

	# Setup pending request with a signal to await
	var result_signal := Signal()
	_pending_requests[request_id] = {
		"role": role,
		"timestamp": Time.get_ticks_msec(),
		"result": null,
	}

	var json_str := JSON.stringify(request)
	_socket.send_text(json_str)

	# Wait for response with timeout
	var start_time := Time.get_ticks_msec()
	while true:
		await get_tree().process_frame

		# Check if result arrived
		if _pending_requests.has(request_id):
			var pending: Dictionary = _pending_requests[request_id]
			if pending.has("result") and pending["result"] != null:
				var result: Dictionary = pending["result"]
				_pending_requests.erase(request_id)
				return result
		else:
			# Request was cleared (shouldn't happen normally)
			break

		# Check timeout
		if Time.get_ticks_msec() - start_time > REQUEST_TIMEOUT * 1000:
			DebugLogger.log("RLClient: Request timed out, using fallback")
			_pending_requests.erase(request_id)
			return _get_fallback_action(role, observation)

	# Fallback if loop exited unexpectedly
	return _get_fallback_action(role, observation)


## Build observation dictionary from game state
func build_observation(
	game_manager: Node,
	role: int,
) -> Dictionary:
	var frontier := GameRules.get_playable_frontier(game_manager.built_hexes)

	var observation := {
		"phase": game_manager.phase,
		"turn": game_manager.turn_index,
		"scores": game_manager.scores.duplicate(),
		"built_hexes": _serialize_hex_array(game_manager.built_hexes),
		"frontier_hexes": _serialize_hex_array(frontier),
	}

	# Add revealed cards (uses revealed_indices array, take first for compatibility)
	if game_manager.revealed_indices.size() > 0:
		var first_idx: int = game_manager.revealed_indices[0]
		if first_idx >= 0 and first_idx < game_manager.hand.size():
			observation["revealed_card"] = game_manager.hand[first_idx].duplicate()

	# Role-specific observations
	if role == 0: # Mayor
		observation["hand"] = game_manager.hand.duplicate(true)
		observation["nominations"] = _serialize_nominations(game_manager.nominations)
	else: # Advisors
		observation["nominations"] = _serialize_nominations(game_manager.nominations)

		# Get hexes already nominated by this advisor (to filter frontier)
		var role_key: String = "industry" if role == 1 else "urbanist"
		var already_nominated: Array[Vector3i] = []
		for nom in game_manager.advisor_commits.get(role_key, []):
			var hex: Vector3i = nom.get("hex", GameRules.INVALID_HEX)
			if hex != GameRules.INVALID_HEX:
				already_nominated.append(hex)

		# Filter frontier to exclude already-nominated hexes
		var filtered_frontier: Array[Vector3i] = []
		for hex in frontier:
			if hex not in already_nominated:
				filtered_frontier.append(hex)
		observation["frontier_hexes"] = _serialize_hex_array(filtered_frontier)
		observation["already_nominated"] = _serialize_hex_array(already_nominated)

		# Advisors see reality tiles - need access to HexField
		if game_manager._hex_field and game_manager._hex_field.map_layers:
			observation["reality_tiles"] = _get_visible_reality(
				game_manager._hex_field.map_layers,
				filtered_frontier # Only tiles for available hexes
			)

	return observation

# ─────────────────────────────────────────────────────────────────────────────
# PRIVATE HELPERS
# ─────────────────────────────────────────────────────────────────────────────

func _handle_message(json_str: String) -> void:
	var json := JSON.new()
	var parse_result := json.parse(json_str)
	if parse_result != OK:
		DebugLogger.log("RLClient: Failed to parse response: %s" % json_str)
		return

	var data: Dictionary = json.get_data()
	var msg_type: String = data.get("type", "")

	match msg_type:
		"action":
			var request_id: int = data.get("request_id", -1)
			var action: Dictionary = data.get("action", {})
			# #region agent log
			_debug_log("G", "_handle_message_action", {"request_id": request_id, "action": action, "pending_keys": _pending_requests.keys()})
			# #endregion

			if _pending_requests.has(request_id):
				var pending: Dictionary = _pending_requests[request_id]
				var role: int = pending.get("role", 0)
				# Store result BEFORE erasing so get_action_async can retrieve it
				pending["result"] = action
				_pending_requests[request_id] = pending
				# #region agent log
				_debug_log("G", "_handle_message_result_stored", {"request_id": request_id, "role": role})
				# #endregion
				DebugLogger.log("RLClient: Received action for role %d: %s" % [role, action])
				action_received.emit(role, action)
			else:
				# #region agent log
				_debug_log("G", "_handle_message_no_pending", {"request_id": request_id})
				# #endregion
				pass

		"error":
			var message: String = data.get("message", "Unknown error")
			DebugLogger.log("RLClient: Server error: %s" % message)
			error.emit(message)

		"pong":
			DebugLogger.log("RLClient: Pong received")

		_:
			DebugLogger.log("RLClient: Unknown message type: %s" % msg_type)


func _check_request_timeouts() -> void:
	var current_time := Time.get_ticks_msec()
	var timed_out: Array[int] = []

	for request_id in _pending_requests:
		var pending: Dictionary = _pending_requests[request_id]
		var timestamp: int = pending.get("timestamp", 0)
		if current_time - timestamp > REQUEST_TIMEOUT * 1000:
			timed_out.append(request_id)

	for request_id in timed_out:
		DebugLogger.log("RLClient: Request %d timed out" % request_id)
		_pending_requests.erase(request_id)


func _schedule_reconnect() -> void:
	if not _reconnect_timer.is_stopped():
		return
	DebugLogger.log("RLClient: Scheduling reconnect in %.1f seconds" % RECONNECT_DELAY)
	_reconnect_timer.start(RECONNECT_DELAY)


func _on_reconnect_timeout() -> void:
	connect_to_server()


func _get_fallback_action(role: int, observation: Dictionary) -> Dictionary:
	"""Get action from scripted bot when server unavailable."""
	var phase: int = observation.get("phase", 1)
	var frontier: Array = observation.get("frontier_hexes", [])
	var built: Array = observation.get("built_hexes", [])
	var revealed_card: Dictionary = observation.get("revealed_card", {})
	var hand: Array = observation.get("hand", [])
	var nominations: Array = observation.get("nominations", [])

	# Convert frontier to Vector3i array
	var built_hexes: Array[Vector3i] = []
	for h in built:
		if h is Array and h.size() == 3:
			built_hexes.append(Vector3i(h[0], h[1], h[2]))

	if role == 0: # Mayor
		if phase == 1: # DRAW
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

		elif phase == 3: # PLACE
			# Simple placement heuristic
			return {"card_index": 0, "hex": frontier[0] if frontier.size() > 0 else [0, 0, 0], "action_type": "place"}

	else: # Advisors
		var revealed_suit: int = revealed_card.get("suit", -1)
		var revealed_value: int = revealed_card.get("value", 7)

		# Build visibility array for strategic nomination
		var visibility: Array = []
		var reality_tiles: Dictionary = observation.get("reality_tiles", {})
		for hex_key in reality_tiles:
			var hex_arr: Array = hex_key if hex_key is Array else [0, 0, 0]
			visibility.append({
				"cube": hex_arr,
				"card": reality_tiles[hex_key],
			})

		var result := GameRules.pick_strategic_nomination(
			role,
			revealed_suit,
			visibility,
			built_hexes,
			revealed_value
		)

		return {
			"hex": [result.hex.x, result.hex.y, result.hex.z] if result.hex != GameRules.INVALID_HEX else [0, 0, 0],
			"claim": result.get("claim", {}),
			"action_type": "nominate",
		}

	return {}


func _serialize_hex_array(hexes: Array) -> Array:
	var result: Array = []
	for h in hexes:
		if h is Vector3i:
			result.append([h.x, h.y, h.z])
	return result


func _serialize_nominations(nominations: Array) -> Array:
	var result: Array = []
	for nom in nominations:
		var hex: Vector3i = nom.get("hex", GameRules.INVALID_HEX)
		result.append({
			"hex": [hex.x, hex.y, hex.z],
			"claim": nom.get("claim", {}),
			"advisor": nom.get("advisor", ""),
		})
	return result


func _get_visible_reality(map_layers: Resource, frontier: Array) -> Dictionary:
	var result := {}
	for hex in frontier:
		if hex is Vector3i:
			var card: Dictionary = map_layers.get_card(hex)
			if not card.is_empty():
				result[[hex.x, hex.y, hex.z]] = card
	return result


# #region agent log
const DEBUG_LOG_PATH := "/Users/sweater/Github/collapsization/.cursor/debug.log"

func _debug_log(hypothesis: String, message: String, data: Dictionary = {}) -> void:
	var log_entry := {
		"timestamp": Time.get_unix_time_from_system() * 1000,
		"location": "rl_client.gd",
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
