## E2E test for cursor synchronization between server and clients.
## Tests:
## 1. Server can host
## 2. Two clients can connect
## 3. Cursor positions sync between all participants
## 4. Disconnection handling is graceful
extends GutTest

const TEST_PORT := 17777
const CONNECT_TIMEOUT := 3.0
const SYNC_TIMEOUT := 1.0

var server_transport: ENetTransport
var client1_transport: ENetTransport
var client2_transport: ENetTransport

var server_players: Dictionary[int, PlayerState] = {}
var client1_players: Dictionary[int, PlayerState] = {}
var client2_players: Dictionary[int, PlayerState] = {}


func before_each() -> void:
	server_transport = ENetTransport.new()
	client1_transport = ENetTransport.new()
	client2_transport = ENetTransport.new()

	server_players.clear()
	client1_players.clear()
	client2_players.clear()


func after_each() -> void:
	if server_transport:
		server_transport.disconnect_from_host()
	if client1_transport:
		client1_transport.disconnect_from_host()
	if client2_transport:
		client2_transport.disconnect_from_host()

	# Allow network cleanup
	await get_tree().process_frame
	await get_tree().process_frame


func test_server_can_host() -> void:
	var err := server_transport.host(TEST_PORT)
	assert_eq(err, OK, "Server should start successfully")
	assert_true(server_transport.is_active(), "Server should be active after hosting")
	assert_true(server_transport.is_server(), "Should identify as server")


func test_client_can_connect() -> void:
	# Start server and watch signals
	watch_signals(server_transport)
	watch_signals(client1_transport)
	server_transport.host(TEST_PORT)

	# Connect client
	client1_transport.connect_to_host("127.0.0.1", TEST_PORT)

	# Poll until connected or timeout
	var elapsed := 0.0
	while elapsed < CONNECT_TIMEOUT:
		server_transport.poll()
		client1_transport.poll()
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if server_transport.get_connected_peers().size() > 0 and client1_transport.is_active():
			break

	assert_signal_emitted(server_transport, "peer_connected", "Server should see client connection")
	assert_signal_emitted(client1_transport, "connected", "Client should connect to server")
	assert_true(client1_transport.is_active(), "Client should be active")
	assert_false(client1_transport.is_server(), "Client should not identify as server")


func test_two_clients_can_connect() -> void:
	# Start server and watch signals
	watch_signals(server_transport)
	watch_signals(client1_transport)
	watch_signals(client2_transport)
	server_transport.host(TEST_PORT)

	# Connect both clients
	client1_transport.connect_to_host("127.0.0.1", TEST_PORT)
	client2_transport.connect_to_host("127.0.0.1", TEST_PORT)

	# Poll until both connected or timeout
	var elapsed := 0.0
	while elapsed < CONNECT_TIMEOUT:
		server_transport.poll()
		client1_transport.poll()
		client2_transport.poll()
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if server_transport.get_connected_peers().size() >= 2:
			break

	assert_eq(server_transport.get_connected_peers().size(), 2, "Server should see 2 client connections")
	assert_signal_emitted(client1_transport, "connected", "Client 1 should connect")
	assert_signal_emitted(client2_transport, "connected", "Client 2 should connect")


func test_cursor_data_syncs_between_clients() -> void:
	# Setup server with data forwarding
	var received_on_server: Array[Dictionary] = []
	var received_on_client2: Array[Dictionary] = []

	server_transport.data_received.connect(func(from_id, data):
		var msg = bytes_to_var(data)
		received_on_server.append({"from": from_id, "msg": msg})
		# Forward to all other clients
		for peer in server_transport.get_connected_peers():
			if peer != from_id:
				server_transport.send(peer, data)
	)

	client2_transport.data_received.connect(func(from_id, data):
		var msg = bytes_to_var(data)
		received_on_client2.append({"from": from_id, "msg": msg})
	)

	# Start server and connect clients
	server_transport.host(TEST_PORT)
	client1_transport.connect_to_host("127.0.0.1", TEST_PORT)
	client2_transport.connect_to_host("127.0.0.1", TEST_PORT)

	# Wait for connections
	var elapsed := 0.0
	while elapsed < CONNECT_TIMEOUT:
		server_transport.poll()
		client1_transport.poll()
		client2_transport.poll()
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if server_transport.get_connected_peers().size() >= 2:
			break

	assert_eq(server_transport.get_connected_peers().size(), 2, "Should have 2 clients connected")

	# Client 1 sends cursor update
	var cursor_msg := {
		"type": NetworkManager.MessageType.CURSOR_UPDATE,
		"data": {"hex": [1, 2, -3]},
		"from": client1_transport.get_local_peer_id(),
	}
	client1_transport.broadcast(var_to_bytes(cursor_msg))

	# Poll until received or timeout
	elapsed = 0.0
	while elapsed < SYNC_TIMEOUT:
		server_transport.poll()
		client1_transport.poll()
		client2_transport.poll()
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if received_on_client2.size() > 0:
			break

	assert_gt(received_on_server.size(), 0, "Server should receive cursor update")
	assert_gt(received_on_client2.size(), 0, "Client 2 should receive forwarded cursor update")

	if received_on_client2.size() > 0:
		var msg = received_on_client2[0]["msg"]
		assert_eq(msg["type"], NetworkManager.MessageType.CURSOR_UPDATE, "Message type should be CURSOR_UPDATE")
		assert_eq(msg["data"]["hex"], [1, 2, -3], "Hex coordinates should match")


func test_disconnect_is_graceful() -> void:
	# Start server and watch signals
	watch_signals(server_transport)
	server_transport.host(TEST_PORT)
	client1_transport.connect_to_host("127.0.0.1", TEST_PORT)

	# Wait for connection
	var elapsed := 0.0
	while elapsed < CONNECT_TIMEOUT:
		server_transport.poll()
		client1_transport.poll()
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if server_transport.get_connected_peers().size() >= 1:
			break

	var client_id := client1_transport.get_local_peer_id()
	assert_gt(client_id, 0, "Client should have valid ID")

	# Disconnect client
	client1_transport.disconnect_from_host()

	# Poll until disconnect detected or timeout
	elapsed = 0.0
	while elapsed < CONNECT_TIMEOUT:
		server_transport.poll()
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		if server_transport.get_connected_peers().size() == 0:
			break

	assert_signal_emitted(server_transport, "peer_disconnected", "Server should detect client disconnect")
	assert_eq(server_transport.get_connected_peers().size(), 0, "No peers should remain")


func test_player_colors_are_unique() -> void:
	# Create players with auto-assigned colors
	var player1 := PlayerState.new()
	var player2 := PlayerState.new()
	var player3 := PlayerState.new()

	# Manually set different colors to simulate real scenario
	player1.set_color_index(0)
	player2.set_color_index(1)
	player3.set_color_index(2)

	assert_ne(player1.get_color(), player2.get_color(), "Player 1 and 2 should have different colors")
	assert_ne(player2.get_color(), player3.get_color(), "Player 2 and 3 should have different colors")
	assert_ne(player1.get_color(), player3.get_color(), "Player 1 and 3 should have different colors")


func test_player_state_serialization() -> void:
	var player := PlayerState.new()
	player.peer_id = 42
	player.display_name = "TestPlayer"
	player.set_color_index(3)
	player.set_hovered_hex(Vector3i(5, -2, -3))

	# Serialize
	var data := player.to_dict()

	# Deserialize into new player
	var player2 := PlayerState.new()
	player2.update_from_dict(data)

	assert_eq(player2.display_name, "TestPlayer", "Name should serialize")
	assert_eq(player2.color_index, 3, "Color should serialize")
	assert_eq(player2.hovered_hex, Vector3i(5, -2, -3), "Hovered hex should serialize")
