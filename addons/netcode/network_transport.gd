## Abstract base class for network transports.
## Implementations: ENetTransport, (future: WebSocketTransport)
class_name NetworkTransport
extends RefCounted

## Emitted when successfully connected to server (client) or started hosting (server)
signal connected

## Emitted when disconnected from server or server stopped
signal disconnected

## Emitted when a peer connects (server only)
signal peer_connected(peer_id: int)

## Emitted when a peer disconnects (server only)
signal peer_disconnected(peer_id: int)

## Emitted when data is received from a peer
signal data_received(peer_id: int, data: PackedByteArray)

## Emitted on connection failure
signal connection_failed(reason: String)


## Returns true if currently connected/hosting
func is_active() -> bool:
	return false


## Returns true if this is the server/host
func is_server() -> bool:
	return false


## Returns the local peer ID (1 for server, assigned ID for clients)
func get_local_peer_id() -> int:
	return 0


## Returns list of connected peer IDs
func get_connected_peers() -> Array[int]:
	return []


## Host a server on the given port
func host(port: int, max_clients: int = 32) -> Error:
	return ERR_UNAVAILABLE


## Connect to a server at address:port
func connect_to_host(address: String, port: int) -> Error:
	return ERR_UNAVAILABLE


## Disconnect from server or stop hosting
func disconnect_from_host() -> void:
	pass


## Send data to a specific peer (0 = broadcast to all)
func send(peer_id: int, data: PackedByteArray, reliable: bool = true) -> Error:
	return ERR_UNAVAILABLE


## Send data to all connected peers
func broadcast(data: PackedByteArray, reliable: bool = true) -> Error:
	for peer in get_connected_peers():
		var err := send(peer, data, reliable)
		if err != OK:
			return err
	return OK


## Must be called each frame to process network events
func poll() -> void:
	pass
