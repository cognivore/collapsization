## Singleton managing network state, player registry, and message routing.
## Access via NetworkManager autoload.
extends Node

signal server_started
signal server_stopped
signal connected_to_server
signal disconnected_from_server
signal player_joined(player_id: int)
signal player_left(player_id: int)
signal message_received(from_id: int, message: Dictionary)

## Message types for the protocol
enum MessageType {
	PLAYER_STATE,
	CURSOR_UPDATE,
	CHAT,
	CUSTOM,
}

const DEFAULT_PORT := 7777

var transport: NetworkTransport
var players: Dictionary[int, PlayerState] = {}  # peer_id -> PlayerState
var local_player: PlayerState


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if transport:
		transport.poll()


## Initialize with a specific transport (default: ENet)
func init_transport(custom_transport: NetworkTransport = null) -> void:
	if transport:
		transport.disconnect_from_host()

	transport = custom_transport if custom_transport else ENetTransport.new()

	# Connect transport signals
	transport.connected.connect(_on_transport_connected)
	transport.disconnected.connect(_on_transport_disconnected)
	transport.peer_connected.connect(_on_peer_connected)
	transport.peer_disconnected.connect(_on_peer_disconnected)
	transport.data_received.connect(_on_data_received)
	transport.connection_failed.connect(_on_connection_failed)


## Host a game server
func host_server(port: int = DEFAULT_PORT, max_players: int = 8) -> Error:
	if transport == null:
		init_transport()

	var err := transport.host(port, max_players)
	if err == OK:
		# Create local player for server
		local_player = PlayerState.new()
		local_player.peer_id = 1
		local_player.is_local = true
		players[1] = local_player
	return err


## Connect to a server
func join_server(address: String, port: int = DEFAULT_PORT) -> Error:
	if transport == null:
		init_transport()

	return transport.connect_to_host(address, port)


## Disconnect from network
func leave() -> void:
	if transport:
		transport.disconnect_from_host()
	players.clear()
	local_player = null


## Check if currently networked
func is_networked() -> bool:
	return transport != null and transport.is_active()


## Check if we're the server
func is_server() -> bool:
	return transport != null and transport.is_server()


## Get local peer ID
func get_local_id() -> int:
	return transport.get_local_peer_id() if transport else 0


## Send a message to a specific peer (0 = broadcast)
func send_message(to_peer: int, type: MessageType, data: Dictionary, reliable: bool = true) -> void:
	if not is_networked():
		return

	var message := {
		"type": type,
		"data": data,
		"from": get_local_id(),
	}

	var bytes := var_to_bytes(message)

	if to_peer == 0:
		transport.broadcast(bytes, reliable)
	else:
		transport.send(to_peer, bytes, reliable)


## Broadcast a message to all peers
func broadcast_message(type: MessageType, data: Dictionary, reliable: bool = true) -> void:
	send_message(0, type, data, reliable)


## Get a player by ID
func get_player(peer_id: int) -> PlayerState:
	return players.get(peer_id)


## Get all players
func get_all_players() -> Array[PlayerState]:
	var result: Array[PlayerState] = []
	for player in players.values():
		result.append(player)
	return result


## Get all remote players (excluding local)
func get_remote_players() -> Array[PlayerState]:
	var result: Array[PlayerState] = []
	for player in players.values():
		if not player.is_local:
			result.append(player)
	return result


func _on_transport_connected() -> void:
	if transport.is_server():
		print("NetworkManager: Server started")
		server_started.emit()
	else:
		print("NetworkManager: Connected to server")
		# Create local player for client
		local_player = PlayerState.new()
		local_player.peer_id = transport.get_local_peer_id()
		local_player.is_local = true
		players[local_player.peer_id] = local_player
		connected_to_server.emit()


func _on_transport_disconnected() -> void:
	if transport and transport.is_server():
		print("NetworkManager: Server stopped")
		server_stopped.emit()
	else:
		print("NetworkManager: Disconnected from server")
		disconnected_from_server.emit()

	players.clear()
	local_player = null


func _on_peer_connected(peer_id: int) -> void:
	# Create player state for new peer
	var player := PlayerState.new()
	player.peer_id = peer_id
	player.is_local = false
	players[peer_id] = player

	print("NetworkManager: Player %d joined" % peer_id)
	_log_player_joined(peer_id)
	player_joined.emit(peer_id)

	# If server, send current player list to new peer
	if is_server():
		_sync_players_to_peer(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	players.erase(peer_id)
	print("NetworkManager: Player %d left" % peer_id)
	_log_player_left(peer_id)
	player_left.emit(peer_id)


func _on_data_received(from_id: int, data: PackedByteArray) -> void:
	var message = bytes_to_var(data)
	if message is Dictionary and message.has("type") and message.has("data"):
		# Use the original sender from message data if available (for forwarded messages)
		var original_from: int = message.get("from", from_id)
		_handle_message(original_from, message)


func _on_connection_failed(reason: String) -> void:
	push_error("NetworkManager: Connection failed - %s" % reason)


func _handle_message(from_id: int, message: Dictionary) -> void:
	var type: MessageType = message.get("type", MessageType.CUSTOM)
	var data: Dictionary = message.get("data", {})

	match type:
		MessageType.PLAYER_STATE:
			_handle_player_state(from_id, data)
		MessageType.CURSOR_UPDATE:
			_handle_cursor_update(from_id, data)
		_:
			message_received.emit(from_id, message)

	# Forward to other clients if server
	if is_server() and from_id != 1:
		for peer_id in players.keys():
			if peer_id != from_id and peer_id != 1:
				transport.send(peer_id, var_to_bytes(message), true)


func _handle_player_state(from_id: int, data: Dictionary) -> void:
	var player := get_player(from_id)
	if player:
		player.update_from_dict(data)


func _handle_cursor_update(from_id: int, data: Dictionary) -> void:
	var player := get_player(from_id)
	if player and data.has("hex"):
		var hex_data: Array = data["hex"]
		player.hovered_hex = Vector3i(hex_data[0], hex_data[1], hex_data[2])


func _sync_players_to_peer(peer_id: int) -> void:
	# Send all existing players to the new peer
	for player in players.values():
		if player.peer_id != peer_id:
			var state_data: Dictionary = player.to_dict()
			send_message(peer_id, MessageType.PLAYER_STATE, state_data)


## Logging helpers
func _get_logger() -> Node:
	if has_node("/root/NetworkLogger"):
		return get_node("/root/NetworkLogger")
	return null


func _log_player_joined(peer_id: int) -> void:
	var logger := _get_logger()
	if logger:
		logger.log_player_joined(peer_id)


func _log_player_left(peer_id: int) -> void:
	var logger := _get_logger()
	if logger:
		logger.log_player_left(peer_id)


func _log_message(from_id: int, msg_type: int, data: Dictionary) -> void:
	var logger := _get_logger()
	if logger:
		logger.log_network_message(from_id, msg_type, data)
