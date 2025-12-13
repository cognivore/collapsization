## Client-side lobby protocol handler.
## Connects to lobby server, manages room state, and handles transitions.
extends Node
class_name LobbyClient

signal connected_to_lobby
signal disconnected_from_lobby
signal room_list_updated(rooms: Array)
signal room_joined(room_id: String, players: Array, bots: Array)
signal room_updated(room_id: String, player_count: int, required: int, bots: Array)
signal room_left
signal game_starting(room_id: String, players: Array, bots: Array, host: int)
signal lobby_error(message: String)

## Lobby message types (must match LobbyServer)
enum LobbyMessageType {
	CREATE_ROOM = 100,
	JOIN_ROOM = 101,
	LEAVE_ROOM = 102,
	LIST_ROOMS = 103,
	ROOM_UPDATE = 104,
	GAME_START = 105,
	LOBBY_ERROR = 106,
	ADD_BOT = 107,
	REMOVE_BOT = 108,
	REQUEST_START = 109,
}

## Current state
enum State {
	DISCONNECTED,
	CONNECTING,
	IN_LOBBY,
	IN_ROOM,
	STARTING_GAME,
}

var state: State = State.DISCONNECTED
var current_room_id: String = ""
var current_room_players: Array = []
var current_room_bots: Array = []
var available_rooms: Array = []

var _net_mgr: Node


func _ready() -> void:
	_bind_network()


func _bind_network() -> void:
	if has_node("/root/NetworkManager"):
		_net_mgr = get_node("/root/NetworkManager")
		if _net_mgr.has_signal("connected_to_server"):
			_net_mgr.connected_to_server.connect(_on_connected)
		if _net_mgr.has_signal("disconnected_from_server"):
			_net_mgr.disconnected_from_server.connect(_on_disconnected)
		if _net_mgr.has_signal("message_received"):
			_net_mgr.message_received.connect(_on_message_received)


func _on_connected() -> void:
	state = State.IN_LOBBY
	current_room_id = ""
	current_room_players.clear()
	current_room_bots.clear()
	Log.net("LobbyClient: Connected to lobby server")
	connected_to_lobby.emit()
	# Request room list
	request_room_list()


func _on_disconnected() -> void:
	state = State.DISCONNECTED
	current_room_id = ""
	current_room_players.clear()
	current_room_bots.clear()
	available_rooms.clear()
	Log.net("LobbyClient: Disconnected from lobby server")
	disconnected_from_lobby.emit()


func _on_message_received(from_id: int, message: Dictionary) -> void:
	var msg_type: int = message.get("type", -1)
	var data: Dictionary = message.get("data", {})

	match msg_type:
		LobbyMessageType.LIST_ROOMS:
			_handle_room_list(data)
		LobbyMessageType.ROOM_UPDATE:
			_handle_room_update(data)
		LobbyMessageType.GAME_START:
			_handle_game_start(data)
		LobbyMessageType.LOBBY_ERROR:
			_handle_error(data)


func _handle_room_list(data: Dictionary) -> void:
	available_rooms = data.get("rooms", [])
	Log.net("LobbyClient: Received room list with %d rooms" % available_rooms.size())
	room_list_updated.emit(available_rooms)


func _handle_room_update(data: Dictionary) -> void:
	var room_id: String = data.get("room_id", "")
	var players: Array = data.get("players", [])
	var bots: Array = data.get("bots", [])
	var player_count: int = data.get("player_count", 0)
	var required: int = data.get("required", 3)

	if current_room_id.is_empty() and not room_id.is_empty():
		# Just joined a room
		current_room_id = room_id
		current_room_players = players
		current_room_bots = bots
		state = State.IN_ROOM
		Log.net("LobbyClient: Joined room %s (%d/%d slots)" % [room_id, player_count, required])
		room_joined.emit(room_id, players, bots)
	elif room_id == current_room_id:
		# Room update
		current_room_players = players
		current_room_bots = bots
		Log.net("LobbyClient: Room %s updated (%d/%d slots, %d bots)" % [room_id, player_count, required, bots.size()])
		room_updated.emit(room_id, player_count, required, bots)


func _handle_game_start(data: Dictionary) -> void:
	var room_id: String = data.get("room_id", "")
	var players: Array = data.get("players", [])
	var bots: Array = data.get("bots", [])
	var host: int = data.get("host", 0)

	state = State.STARTING_GAME
	Log.net("LobbyClient: Game starting in room %s with players %s and bots %s" % [room_id, players, bots])
	game_starting.emit(room_id, players, bots, host)


func _handle_error(data: Dictionary) -> void:
	var error_msg: String = data.get("error", "Unknown error")
	Log.net("LobbyClient: Error - %s" % error_msg)
	lobby_error.emit(error_msg)


## Connect to a lobby server
func connect_to_lobby(address: String, port: int = 7777) -> Error:
	if _net_mgr == null:
		push_error("LobbyClient: NetworkManager not found")
		return ERR_UNCONFIGURED

	state = State.CONNECTING
	Log.net("LobbyClient: Connecting to lobby at %s:%d" % [address, port])
	return _net_mgr.join_server(address, port)


## Disconnect from lobby
func disconnect_from_lobby() -> void:
	if _net_mgr:
		_net_mgr.leave()
	state = State.DISCONNECTED


## Create a new room
func create_room() -> void:
	if state != State.IN_LOBBY:
		lobby_error.emit("Must be in lobby to create a room")
		return

	Log.net("LobbyClient: Requesting room creation")
	_send_message(LobbyMessageType.CREATE_ROOM, {})


## Join an existing room
func join_room(room_id: String) -> void:
	if state != State.IN_LOBBY:
		lobby_error.emit("Must be in lobby to join a room")
		return

	Log.net("LobbyClient: Requesting to join room %s" % room_id)
	_send_message(LobbyMessageType.JOIN_ROOM, {"room_id": room_id})


## Leave current room
func leave_room() -> void:
	if state != State.IN_ROOM:
		return

	Log.net("LobbyClient: Leaving room %s" % current_room_id)
	_send_message(LobbyMessageType.LEAVE_ROOM, {})

	current_room_id = ""
	current_room_players.clear()
	current_room_bots.clear()
	state = State.IN_LOBBY
	room_left.emit()

	# Refresh room list
	request_room_list()


## Add a bot to the current room
func add_bot() -> void:
	if state != State.IN_ROOM:
		lobby_error.emit("Must be in a room to add a bot")
		return

	Log.net("LobbyClient: Requesting to add bot to room %s" % current_room_id)
	_send_message(LobbyMessageType.ADD_BOT, {})


## Remove a bot from the current room
func remove_bot(bot_id: int) -> void:
	if state != State.IN_ROOM:
		lobby_error.emit("Must be in a room to remove a bot")
		return

	Log.net("LobbyClient: Requesting to remove bot %d from room %s" % [bot_id, current_room_id])
	_send_message(LobbyMessageType.REMOVE_BOT, {"bot_id": bot_id})


## Request to start the game (host only)
func request_start_game() -> void:
	if state != State.IN_ROOM:
		lobby_error.emit("Must be in a room to start a game")
		return

	Log.net("LobbyClient: Requesting game start for room %s" % current_room_id)
	_send_message(LobbyMessageType.REQUEST_START, {})


## Request updated room list
func request_room_list() -> void:
	_send_message(LobbyMessageType.LIST_ROOMS, {})


func _send_message(msg_type: int, data: Dictionary) -> void:
	if _net_mgr == null or not _net_mgr.is_networked():
		return

	var message := {
		"type": msg_type,
		"data": data,
	}
	var bytes := var_to_bytes(message)

	# Send to server (peer 1)
	_net_mgr.transport.send(1, bytes, true)


## Check if connected to lobby
func is_lobby_connected() -> bool:
	return state != State.DISCONNECTED and state != State.CONNECTING


## Check if in a room
func is_in_room() -> bool:
	return state == State.IN_ROOM


## Get current room player count
func get_player_count() -> int:
	return current_room_players.size()

