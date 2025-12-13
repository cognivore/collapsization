## Lobby server managing rooms and player routing.
## Handles room creation, joining, and game session spawning.
extends Node
class_name LobbyServer

signal room_created(room_id: String)
signal room_updated(room_id: String, player_count: int)
signal room_destroyed(room_id: String)
signal player_joined_room(peer_id: int, room_id: String)
signal player_left_room(peer_id: int, room_id: String)
signal game_starting(room_id: String)

## Lobby message types (extend NetworkManager.MessageType)
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

const REQUIRED_PLAYERS := 3
const MAX_ROOMS := 50
const ROOM_ID_LENGTH := 6

## Room data structure
## {room_id: {players: [peer_ids], bots: [bot_ids], host: peer_id, created_at: timestamp}}
var rooms: Dictionary = {}

## Maps peer_id -> room_id for quick lookup
var player_rooms: Dictionary = {}

## Bot ID counter (negative IDs to differentiate from real peers)
var _next_bot_id: int = -1

var _net_mgr: Node
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_bind_network()


func _bind_network() -> void:
	if has_node("/root/NetworkManager"):
		_net_mgr = get_node("/root/NetworkManager")
		if _net_mgr.has_signal("message_received"):
			_net_mgr.message_received.connect(_on_message_received)
		if _net_mgr.has_signal("player_left"):
			_net_mgr.player_left.connect(_on_player_left)


func _on_message_received(from_id: int, message: Dictionary) -> void:
	var msg_type: int = message.get("type", -1)
	var data: Dictionary = message.get("data", {})

	match msg_type:
		LobbyMessageType.CREATE_ROOM:
			_handle_create_room(from_id)
		LobbyMessageType.JOIN_ROOM:
			_handle_join_room(from_id, data.get("room_id", ""))
		LobbyMessageType.LEAVE_ROOM:
			_handle_leave_room(from_id)
		LobbyMessageType.LIST_ROOMS:
			_send_room_list(from_id)
		LobbyMessageType.ADD_BOT:
			_handle_add_bot(from_id)
		LobbyMessageType.REMOVE_BOT:
			_handle_remove_bot(from_id, data.get("bot_id", 0))
		LobbyMessageType.REQUEST_START:
			_handle_request_start(from_id)


func _on_player_left(peer_id: int) -> void:
	_handle_leave_room(peer_id)


## Create a new room with the requesting player as host
func _handle_create_room(peer_id: int) -> void:
	# Check if player is already in a room
	if player_rooms.has(peer_id):
		_send_error(peer_id, "Already in a room")
		return

	# Check room limit
	if rooms.size() >= MAX_ROOMS:
		_send_error(peer_id, "Server full - too many rooms")
		return

	var room_id := _generate_room_id()
	rooms[room_id] = {
		"players": [peer_id],
		"bots": [],
		"host": peer_id,
		"created_at": Time.get_unix_time_from_system(),
	}
	player_rooms[peer_id] = room_id

	Log.net("LobbyServer: Room %s created by peer %d" % [room_id, peer_id])
	room_created.emit(room_id)

	_send_room_update(room_id)
	_broadcast_room_list_update()


## Join an existing room
func _handle_join_room(peer_id: int, room_id: String) -> void:
	# Check if player is already in a room
	if player_rooms.has(peer_id):
		_send_error(peer_id, "Already in a room")
		return

	# Check if room exists
	if not rooms.has(room_id):
		_send_error(peer_id, "Room not found")
		return

	var room: Dictionary = rooms[room_id]
	var players: Array = room["players"]
	var bots: Array = room.get("bots", [])
	var total_count: int = players.size() + bots.size()

	# Check if room is full
	if total_count >= REQUIRED_PLAYERS:
		_send_error(peer_id, "Room is full")
		return

	# Add player to room
	players.append(peer_id)
	player_rooms[peer_id] = room_id
	total_count = players.size() + bots.size()

	Log.net("LobbyServer: Peer %d joined room %s (%d/%d)" % [
		peer_id, room_id, total_count, REQUIRED_PLAYERS
	])

	player_joined_room.emit(peer_id, room_id)
	_send_room_update(room_id)
	_broadcast_room_list_update()

	# Start game if room is full
	if total_count >= REQUIRED_PLAYERS:
		_start_game(room_id)


## Remove player from their current room
func _handle_leave_room(peer_id: int) -> void:
	if not player_rooms.has(peer_id):
		return

	var room_id: String = player_rooms[peer_id]
	player_rooms.erase(peer_id)

	if not rooms.has(room_id):
		return

	var room: Dictionary = rooms[room_id]
	var players: Array = room["players"]
	players.erase(peer_id)

	Log.net("LobbyServer: Peer %d left room %s" % [peer_id, room_id])
	player_left_room.emit(peer_id, room_id)

	# Destroy room if empty
	if players.is_empty():
		rooms.erase(room_id)
		Log.net("LobbyServer: Room %s destroyed (empty)" % room_id)
		room_destroyed.emit(room_id)
	else:
		# Transfer host if needed
		if room["host"] == peer_id:
			room["host"] = players[0]
			Log.net("LobbyServer: Host transferred to peer %d" % players[0])
		_send_room_update(room_id)

	_broadcast_room_list_update()


## Add a bot to a room
func _handle_add_bot(peer_id: int) -> void:
	# Check if player is in a room
	if not player_rooms.has(peer_id):
		_send_error(peer_id, "Not in a room")
		return

	var room_id: String = player_rooms[peer_id]
	if not rooms.has(room_id):
		return

	var room: Dictionary = rooms[room_id]
	var players: Array = room["players"]
	var bots: Array = room.get("bots", [])
	var total_count: int = players.size() + bots.size()

	# Check if room is full
	if total_count >= REQUIRED_PLAYERS:
		_send_error(peer_id, "Room is full")
		return

	# Add bot with negative ID
	var bot_id: int = _next_bot_id
	_next_bot_id -= 1
	bots.append(bot_id)
	room["bots"] = bots
	total_count = players.size() + bots.size()

	Log.net("LobbyServer: Bot %d added to room %s (%d/%d)" % [
		bot_id, room_id, total_count, REQUIRED_PLAYERS
	])

	_send_room_update(room_id)
	_broadcast_room_list_update()

	# Start game if room is full
	if total_count >= REQUIRED_PLAYERS:
		_start_game(room_id)


## Remove a bot from a room
func _handle_remove_bot(peer_id: int, bot_id: int) -> void:
	# Check if player is in a room
	if not player_rooms.has(peer_id):
		_send_error(peer_id, "Not in a room")
		return

	var room_id: String = player_rooms[peer_id]
	if not rooms.has(room_id):
		return

	var room: Dictionary = rooms[room_id]
	var bots: Array = room.get("bots", [])

	if bot_id in bots:
		bots.erase(bot_id)
		room["bots"] = bots
		Log.net("LobbyServer: Bot %d removed from room %s" % [bot_id, room_id])
		_send_room_update(room_id)
		_broadcast_room_list_update()


## Handle host requesting game start
func _handle_request_start(peer_id: int) -> void:
	# Check if player is in a room
	if not player_rooms.has(peer_id):
		_send_error(peer_id, "Not in a room")
		return

	var room_id: String = player_rooms[peer_id]
	if not rooms.has(room_id):
		return

	var room: Dictionary = rooms[room_id]

	# Check if requester is the host
	if room["host"] != peer_id:
		_send_error(peer_id, "Only the host can start the game")
		return

	var players: Array = room["players"]
	var bots: Array = room.get("bots", [])
	var total_count: int = players.size() + bots.size()

	# Need at least 2 players/bots to start (for testing, normally 3)
	if total_count < 2:
		_send_error(peer_id, "Need at least 2 players to start")
		return

	Log.net("LobbyServer: Host %d requested game start for room %s" % [peer_id, room_id])
	_start_game(room_id)


## Start game for a full room
func _start_game(room_id: String) -> void:
	if not rooms.has(room_id):
		return

	var room: Dictionary = rooms[room_id]
	var players: Array = room["players"]
	var bots: Array = room.get("bots", [])

	Log.net("LobbyServer: Starting game for room %s with players %s and bots %s" % [room_id, players, bots])
	game_starting.emit(room_id)

	# Notify all players in room
	var start_msg := {
		"room_id": room_id,
		"players": players,
		"bots": bots,
		"host": room["host"],
	}

	for peer_id: int in players:
		_send_message(peer_id, LobbyMessageType.GAME_START, start_msg)


## Send room update to all players in a room
func _send_room_update(room_id: String) -> void:
	if not rooms.has(room_id):
		return

	var room: Dictionary = rooms[room_id]
	var players: Array = room["players"]
	var bots: Array = room.get("bots", [])
	var total_count: int = players.size() + bots.size()

	var update := {
		"room_id": room_id,
		"players": players,
		"bots": bots,
		"player_count": total_count,
		"required": REQUIRED_PLAYERS,
		"host": room["host"],
	}

	for peer_id: int in players:
		_send_message(peer_id, LobbyMessageType.ROOM_UPDATE, update)

	room_updated.emit(room_id, total_count)


## Send room list to a specific player
func _send_room_list(peer_id: int) -> void:
	var room_list: Array = []

	for room_id: String in rooms.keys():
		var room: Dictionary = rooms[room_id]
		var total_count: int = room["players"].size() + room.get("bots", []).size()
		room_list.append({
			"room_id": room_id,
			"player_count": total_count,
			"required": REQUIRED_PLAYERS,
		})

	_send_message(peer_id, LobbyMessageType.LIST_ROOMS, {"rooms": room_list})


## Broadcast room list to all connected players (not in rooms)
func _broadcast_room_list_update() -> void:
	if _net_mgr == null:
		return

	var room_list: Array = []
	for room_id: String in rooms.keys():
		var room: Dictionary = rooms[room_id]
		var total_count: int = room["players"].size() + room.get("bots", []).size()
		room_list.append({
			"room_id": room_id,
			"player_count": total_count,
			"required": REQUIRED_PLAYERS,
		})

	# Send to players not in a room
	for peer_id: int in _net_mgr.players.keys():
		if not player_rooms.has(peer_id):
			_send_message(peer_id, LobbyMessageType.LIST_ROOMS, {"rooms": room_list})


func _send_error(peer_id: int, message: String) -> void:
	_send_message(peer_id, LobbyMessageType.LOBBY_ERROR, {"error": message})


func _send_message(peer_id: int, msg_type: int, data: Dictionary) -> void:
	if _net_mgr == null:
		return

	var message := {
		"type": msg_type,
		"data": data,
	}
	var bytes := var_to_bytes(message)
	_net_mgr.transport.send(peer_id, bytes, true)


func _generate_room_id() -> String:
	const CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" # No I, O, 0, 1 for clarity
	var id := ""
	for i in range(ROOM_ID_LENGTH):
		id += CHARS[_rng.randi_range(0, CHARS.length() - 1)]

	# Ensure uniqueness
	if rooms.has(id):
		return _generate_room_id()
	return id


## Get room info by ID
func get_room(room_id: String) -> Dictionary:
	return rooms.get(room_id, {})


## Get all active rooms
func get_all_rooms() -> Dictionary:
	return rooms.duplicate()


## Get the room a player is in
func get_player_room(peer_id: int) -> String:
	return player_rooms.get(peer_id, "")

