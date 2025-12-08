## Autoload that handles demo mode: spawns client windows and auto-connects.
## Parses command-line args to determine role (server/client).
extends Node

signal demo_ready

## Whether we're running in demo/debug mode
var is_demo_mode := false

## Role for this instance
enum Role { NONE, SERVER, CLIENT }
var role := Role.NONE

## Client index (for color assignment)
var client_index := 0

## Number of client windows to spawn
@export var num_clients := 2

## Port for networking
const PORT := 7777

## Delay before spawning clients (let server start)
const SPAWN_DELAY := 0.5

## Spawned process IDs (to clean up on exit)
var _spawned_pids: Array[int] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_args()
	_start_role.call_deferred()


func _parse_args() -> void:
	var args := OS.get_cmdline_args()

	# Check if running tests (GUT) - skip demo mode entirely
	for arg in args:
		if arg == "-s" or arg.ends_with("gut_cmdln.gd"):
			is_demo_mode = false
			role = Role.NONE
			return

	for i in range(args.size()):
		var arg := args[i]

		if arg == "--demo" or arg == "--debug":
			is_demo_mode = true
			role = Role.SERVER  # Default to server in demo mode

		elif arg == "--server":
			role = Role.SERVER

		elif arg == "--client":
			role = Role.CLIENT
			is_demo_mode = true  # Clients spawned for demo are also in demo mode
			# Check for client index
			if i + 1 < args.size() and args[i + 1].is_valid_int():
				client_index = args[i + 1].to_int()

	# If no args, default to demo mode
	if role == Role.NONE:
		is_demo_mode = true
		role = Role.SERVER


func _start_role() -> void:
	var net_mgr := _get_network_manager()
	if net_mgr == null:
		push_error("DemoLauncher: NetworkManager not found!")
		return

	match role:
		Role.SERVER:
			_start_server(net_mgr)
		Role.CLIENT:
			_start_client(net_mgr)


func _start_server(net_mgr: Node) -> void:
	print("DemoLauncher: Starting as SERVER (demo_mode=%s)" % is_demo_mode)

	var err: Error = net_mgr.host_server(PORT)
	if err != OK:
		push_error("DemoLauncher: Failed to start server: %s" % error_string(err))
		return

	# Set server's color to index 0
	if net_mgr.local_player:
		net_mgr.local_player.set_color_index(0)

	# In demo mode, spawn client windows
	if is_demo_mode:
		await get_tree().create_timer(SPAWN_DELAY).timeout
		_spawn_clients()

	demo_ready.emit()


func _start_client(net_mgr: Node) -> void:
	print("DemoLauncher: Starting as CLIENT (index=%d)" % client_index)

	# Connect signals for when we successfully connect
	net_mgr.connected_to_server.connect(_on_connected_to_server)

	var err: Error = net_mgr.join_server("127.0.0.1", PORT)
	if err != OK:
		push_error("DemoLauncher: Failed to join server: %s" % error_string(err))
		return


func _on_connected_to_server() -> void:
	var net_mgr := _get_network_manager()
	if net_mgr and net_mgr.local_player:
		# Set color based on client index (palette: 1=RED, 2=BLUE)
		net_mgr.local_player.set_color_index(client_index)

		# Broadcast our state to others
		net_mgr.broadcast_message(
			net_mgr.MessageType.PLAYER_STATE,
			net_mgr.local_player.to_dict(),
			true
		)

	demo_ready.emit()


func _spawn_clients() -> void:
	var exe_path := OS.get_executable_path()
	var project_path := ProjectSettings.globalize_path("res://")

	for i in range(num_clients):
		var args: Array[String] = [
			"--path", project_path,
			"--client", str(i + 1),  # Client indices start at 1
		]

		# Position windows side by side
		var window_x := 100 + (i + 1) * 420
		var window_y := 100
		args.append_array(["--position", "%d,%d" % [window_x, window_y]])

		print("DemoLauncher: Spawning client %d with args: %s" % [i + 1, args])

		var pid := OS.create_process(exe_path, args)
		if pid > 0:
			_spawned_pids.append(pid)
			print("DemoLauncher: Spawned client %d (PID: %d)" % [i + 1, pid])
		else:
			push_error("DemoLauncher: Failed to spawn client %d" % [i + 1])


func _get_network_manager() -> Node:
	if has_node("/root/NetworkManager"):
		return get_node("/root/NetworkManager")
	return null


func _exit_tree() -> void:
	# Clean up spawned processes when server exits
	if role == Role.SERVER:
		for pid in _spawned_pids:
			OS.kill(pid)
		_spawned_pids.clear()

