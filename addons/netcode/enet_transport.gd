## ENet-based network transport implementation.
## Provides reliable UDP networking with robust disconnect handling.
class_name ENetTransport
extends NetworkTransport

var _peer: ENetMultiplayerPeer
var _is_server := false
var _connected_peers: Array[int] = []


func is_active() -> bool:
	return _peer != null and _peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED


func is_server() -> bool:
	return _is_server


func get_local_peer_id() -> int:
	if _peer == null:
		return 0
	return _peer.get_unique_id()


func get_connected_peers() -> Array[int]:
	return _connected_peers.duplicate()


func host(port: int, max_clients: int = 32) -> Error:
	if is_active():
		push_warning("ENetTransport: Already active, disconnecting first")
		disconnect_from_host()

	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, max_clients)

	if err != OK:
		push_error("ENetTransport: Failed to create server on port %d: %s" % [port, error_string(err)])
		_peer = null
		connection_failed.emit("Failed to create server: " + error_string(err))
		return err

	_is_server = true
	_connected_peers.clear()

	# Connect internal signals
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)

	Log.net("ENetTransport: Server started on port %d" % port)
	connected.emit()
	return OK


func connect_to_host(address: String, port: int) -> Error:
	if is_active():
		push_warning("ENetTransport: Already active, disconnecting first")
		disconnect_from_host()

	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)

	if err != OK:
		push_error("ENetTransport: Failed to connect to %s:%d: %s" % [address, port, error_string(err)])
		_peer = null
		connection_failed.emit("Failed to connect: " + error_string(err))
		return err

	_is_server = false
	_connected_peers.clear()
	_client_connected_emitted = false

	# Connect internal signals
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)

	Log.net("ENetTransport: Connecting to %s:%d..." % [address, port])
	return OK


func disconnect_from_host() -> void:
	if _peer == null:
		return

	# Disconnect signals safely
	if _peer.peer_connected.is_connected(_on_peer_connected):
		_peer.peer_connected.disconnect(_on_peer_connected)
	if _peer.peer_disconnected.is_connected(_on_peer_disconnected):
		_peer.peer_disconnected.disconnect(_on_peer_disconnected)

	_peer.close()
	_peer = null
	_is_server = false
	_connected_peers.clear()

	Log.net("ENetTransport: Disconnected")
	disconnected.emit()


func send(peer_id: int, data: PackedByteArray, reliable: bool = true) -> Error:
	if not is_active():
		return ERR_UNCONFIGURED

	# Set transfer mode
	if reliable:
		_peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	else:
		_peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_UNRELIABLE

	_peer.set_target_peer(peer_id)
	return _peer.put_packet(data)


func poll() -> void:
	if _peer == null:
		return

	_peer.poll()

	# Check connection status for clients
	if not _is_server:
		var status := _peer.get_connection_status()
		match status:
			MultiplayerPeer.CONNECTION_CONNECTED:
				if _connected_peers.is_empty():
					# Just connected to server
					_connected_peers.append(1) # Server is always peer 1
					connected.emit()
			MultiplayerPeer.CONNECTION_DISCONNECTED:
				if not _connected_peers.is_empty():
					_connected_peers.clear()
					disconnected.emit()

	# Process incoming packets
	while _peer.get_available_packet_count() > 0:
		var sender := _peer.get_packet_peer()
		var packet := _peer.get_packet()
		data_received.emit(sender, packet)


var _client_connected_emitted := false

func _on_peer_connected(id: int) -> void:
	var was_empty := _connected_peers.is_empty()
	if not id in _connected_peers:
		_connected_peers.append(id)
	Log.net("ENetTransport: Peer %d connected" % id)

	# For clients: emit connected when we first connect to server (peer 1)
	if not _is_server and id == 1 and not _client_connected_emitted:
		_client_connected_emitted = true
		Log.net("ENetTransport: Client connected to server")
		connected.emit()

	peer_connected.emit(id)


func _on_peer_disconnected(id: int) -> void:
	_connected_peers.erase(id)
	Log.net("ENetTransport: Peer %d disconnected" % id)
	peer_disconnected.emit(id)
