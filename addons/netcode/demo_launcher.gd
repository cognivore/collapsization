## Autoload that handles demo/singleplayer mode: spawns bot clients that auto-play.
## Human plays as Mayor, 2 headless bot processes play as Industry and Urbanist advisors.
## Also supports dedicated lobby server mode via --server flag.
## Uses GameBus for proper signal-based scene transition handshakes.
extends Node

const GameRules := preload("res://scripts/game_rules.gd")
const MapLayers := preload("res://scripts/map_layers.gd")
const LobbyServerScript := preload("res://addons/netcode/lobby_server.gd")

signal demo_ready

# ─────────────────────────────────────────────────────────────────────────────
# ENUMS & CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

enum Role {NONE, SERVER, CLIENT, BOT, LOBBY_SERVER}

const PORT := 7779
const DEFAULT_LOBBY_PORT := 7777
const SPAWN_DELAY := 0.3
const DEMO_SEED := 42
const REQUIRED_PLAYERS := 3

# ─────────────────────────────────────────────────────────────────────────────
# STATE
# ─────────────────────────────────────────────────────────────────────────────

var role := Role.NONE
var client_index := 0
var is_bot := false
var is_demo_mode := true
var is_singleplayer := true
var lobby_port := DEFAULT_LOBBY_PORT

var _spawned_pids: Array[int] = []
var _lobby_server: Node
var _pending_params: Dictionary = {}

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_args()

	# Connect to GameBus for signal-based scene transitions
	var game_bus := _get_game_bus()
	if game_bus:
		game_bus.request_start_game.connect(_on_request_start_game)
		game_bus.scene_ready.connect(_on_scene_ready)
		Log.game("DemoLauncher: Connected to GameBus")

	_start_role.call_deferred()


func _parse_args() -> void:
	var args := OS.get_cmdline_args()

	# Skip if running tests
	for arg in args:
		if arg == "-s" or arg.ends_with("gut_cmdln.gd"):
			role = Role.NONE
			return

	# Parse command-line args (for dedicated server, bots, etc.)
	for i in range(args.size()):
		var arg := args[i]

		if arg == "--server" or arg == "--lobby-server":
			# Dedicated lobby server mode (headless)
			role = Role.LOBBY_SERVER
			is_demo_mode = false
			is_singleplayer = false
		elif arg == "--demo-server":
			# Legacy: start as demo server (for local testing with bots)
			role = Role.SERVER
		elif arg == "--client":
			role = Role.CLIENT
			if i + 1 < args.size() and args[i + 1].is_valid_int():
				client_index = args[i + 1].to_int()
		elif arg == "--bot":
			role = Role.BOT
			is_bot = true
			if i + 1 < args.size() and args[i + 1].is_valid_int():
				client_index = args[i + 1].to_int()
		elif arg == "--port":
			if i + 1 < args.size() and args[i + 1].is_valid_int():
				lobby_port = args[i + 1].to_int()

	# Default behavior based on context
	if role == Role.NONE:
		if DisplayServer.get_name() == "headless":
			# Headless = dedicated lobby server
			role = Role.LOBBY_SERVER
		else:
			# GUI but no hint = likely launched from editor or main menu
			# Wait for GameBus signal to choose mode
			role = Role.NONE
			Log.game("DemoLauncher: No mode specified, waiting for GameBus signal")


func _start_role() -> void:
	# If no role, do nothing (wait for GameBus signal)
	if role == Role.NONE:
		Log.game("DemoLauncher: No role assigned, waiting...")
		return

	var net_mgr := _get_network_manager()
	if net_mgr == null:
		push_error("DemoLauncher: NetworkManager not found!")
		return

	match role:
		Role.LOBBY_SERVER:
			_start_lobby_server(net_mgr)
		Role.SERVER:
			_start_server(net_mgr)
		Role.CLIENT:
			_start_client(net_mgr)
		Role.BOT:
			_start_bot(net_mgr)


# ─────────────────────────────────────────────────────────────────────────────
# GAMEBUS SIGNAL HANDLERS
# ─────────────────────────────────────────────────────────────────────────────

func _on_request_start_game(params: Dictionary) -> void:
	Log.game("DemoLauncher: Received request_start_game with params=%s" % params)
	_pending_params = params

	# Set up role based on params
	var mode: String = params.get("mode", "singleplayer")
	match mode:
		"singleplayer":
			role = Role.SERVER
			is_demo_mode = true
			is_singleplayer = true
		"multiplayer":
			role = Role.SERVER
			is_demo_mode = true
			is_singleplayer = false
		_:
			role = Role.SERVER
			is_demo_mode = true
			is_singleplayer = true


func _on_scene_ready(root: Node) -> void:
	Log.game("DemoLauncher: Scene ready: %s" % root.name)

	# Only start the game if we have pending params and the scene is World
	if _pending_params.is_empty():
		return

	if root.name == "World":
		Log.game("DemoLauncher: World scene ready, starting game with pending params")
		_start_role()
		_pending_params = {}


# ─────────────────────────────────────────────────────────────────────────────
# LOBBY SERVER (Dedicated headless server for matchmaking)
# ─────────────────────────────────────────────────────────────────────────────

func _start_lobby_server(net_mgr: Node) -> void:
	Log.net("═══════════════════════════════════════════════════════════════")
	Log.net("  MULTIPLAYER MINESWEEPER - LOBBY SERVER")
	Log.net("  Port: %d" % lobby_port)
	Log.net("═══════════════════════════════════════════════════════════════")

	var err: Error = net_mgr.host_server(lobby_port)
	if err != OK:
		push_error("DemoLauncher: Failed to start lobby server: %s" % error_string(err))
		return

	# Create and add lobby server component
	_lobby_server = LobbyServerScript.new()
	add_child(_lobby_server)

	# Connect lobby signals for logging
	_lobby_server.room_created.connect(_on_lobby_room_created)
	_lobby_server.room_destroyed.connect(_on_lobby_room_destroyed)
	_lobby_server.game_starting.connect(_on_lobby_game_starting)

	Log.net("Lobby server running. Waiting for connections...")
	Log.net("Usage: Players connect and create/join rooms.")
	Log.net("Press Ctrl+C to stop the server.")


func _on_lobby_room_created(room_id: String) -> void:
	Log.net("[LOBBY] Room created: %s" % room_id)


func _on_lobby_room_destroyed(room_id: String) -> void:
	Log.net("[LOBBY] Room destroyed: %s" % room_id)


func _on_lobby_game_starting(room_id: String) -> void:
	Log.net("[LOBBY] Game starting in room: %s" % room_id)


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API (legacy - kept for compatibility, prefer GameBus)
# ─────────────────────────────────────────────────────────────────────────────

## Start a multiplayer game (called from lobby when game starts)
## Prefer using GameBus.start_game() instead
func start_multiplayer_game(deferred: bool = false) -> void:
	Log.game("DemoLauncher: start_multiplayer_game() called (deferred=%s)" % deferred)
	role = Role.SERVER
	is_demo_mode = true
	is_singleplayer = false
	if deferred:
		# Wait for scene to load, then start
		call_deferred("_deferred_start_role")
	else:
		_start_role()


## Start a singleplayer game (called from main menu)
## Prefer using GameBus.start_game() instead
func start_singleplayer_game(deferred: bool = false) -> void:
	Log.game("DemoLauncher: start_singleplayer_game() called (deferred=%s)" % deferred)
	role = Role.SERVER
	is_demo_mode = true
	is_singleplayer = true
	if deferred:
		call_deferred("_deferred_start_role")
	else:
		_start_role()


func _deferred_start_role() -> void:
	# Wait a frame for scene to be fully loaded
	await get_tree().process_frame
	await get_tree().process_frame
	Log.game("DemoLauncher: _deferred_start_role() - starting game")
	_start_role()


# ─────────────────────────────────────────────────────────────────────────────
# SERVER (Human Mayor)
# ─────────────────────────────────────────────────────────────────────────────

func _start_server(net_mgr: Node) -> void:
	Log.game("DemoLauncher: Starting SERVER (Human Mayor)")

	var err: Error = net_mgr.host_server(PORT)
	if err != OK:
		push_error("DemoLauncher: Failed to start server: %s" % error_string(err))
		return

	if net_mgr.local_player:
		net_mgr.local_player.set_color_index(0)

	# Configure game manager
	var gm := _get_game_manager()
	if gm:
		# Use random seed for multiplayer, fixed seed only for singleplayer testing
		if is_singleplayer:
			gm.game_seed = DEMO_SEED
			Log.game("DemoLauncher: Using fixed seed %d (singleplayer)" % DEMO_SEED)
		else:
			gm.game_seed = randi()
			Log.game("DemoLauncher: Using random seed %d (multiplayer)" % gm.game_seed)
		net_mgr.player_joined.connect(_on_player_joined_server)

	# Spawn bot clients
	await get_tree().create_timer(SPAWN_DELAY).timeout
	_spawn_bots()

	demo_ready.emit()


func _on_player_joined_server(peer_id: int) -> void:
	var net_mgr := _get_network_manager()
	var gm := _get_game_manager()
	if net_mgr == null or gm == null:
		return

	var player_count: int = net_mgr.players.size()
	Log.game("DemoLauncher: Player %d joined (%d/%d)" % [peer_id, player_count, REQUIRED_PLAYERS])

	# Start game when all players joined and still in LOBBY
	if player_count >= REQUIRED_PLAYERS and gm.phase == 0: # LOBBY
		Log.game("DemoLauncher: All players joined! Starting game...")
		await get_tree().create_timer(0.5).timeout
		_start_game()


func _start_game() -> void:
	var gm := _get_game_manager()
	var hex_field := _get_hex_field()

	# Use the seed that was set earlier (random for multiplayer, fixed for singleplayer)
	var seed_to_use: int = gm.game_seed if gm and gm.game_seed >= 0 else randi()

	if hex_field and hex_field.has_method("reinit_map_layers"):
		hex_field.reinit_map_layers(seed_to_use)

	if gm:
		gm.start_game()
		Log.game("DemoLauncher: Game started with seed %d!" % seed_to_use)

# ─────────────────────────────────────────────────────────────────────────────
# CLIENT (Manual testing)
# ─────────────────────────────────────────────────────────────────────────────

func _start_client(net_mgr: Node) -> void:
	Log.game("DemoLauncher: Starting CLIENT (index=%d)" % client_index)
	net_mgr.connected_to_server.connect(_on_connected_as_client)

	var err: Error = net_mgr.join_server("127.0.0.1", PORT)
	if err != OK:
		push_error("DemoLauncher: Failed to join server: %s" % error_string(err))


func _on_connected_as_client() -> void:
	var net_mgr := _get_network_manager()
	if net_mgr and net_mgr.local_player:
		net_mgr.local_player.set_color_index(client_index)
		net_mgr.broadcast_message(net_mgr.MessageType.PLAYER_STATE, net_mgr.local_player.to_dict(), true)
	demo_ready.emit()

# ─────────────────────────────────────────────────────────────────────────────
# BOT (Automated Advisor)
# ─────────────────────────────────────────────────────────────────────────────

func _start_bot(net_mgr: Node) -> void:
	Log.game("DemoLauncher: Starting BOT (index=%d)" % client_index)

	# First, load the World scene so we have a GameManager
	var world_scene := load("res://World.tscn")
	if world_scene:
		get_tree().change_scene_to_packed(world_scene)
		await get_tree().process_frame
		await get_tree().process_frame
		Log.game("DemoLauncher: Bot loaded World scene")
	else:
		push_error("DemoLauncher: Bot failed to load World scene")
		return

	net_mgr.connected_to_server.connect(_on_connected_as_bot, CONNECT_DEFERRED)

	var err: Error = net_mgr.join_server("127.0.0.1", PORT)
	if err != OK:
		push_error("DemoLauncher: Failed to join server as bot: %s" % error_string(err))


func _on_connected_as_bot() -> void:
	var net_mgr := _get_network_manager()
	if net_mgr and net_mgr.local_player:
		net_mgr.local_player.set_color_index(client_index)
		net_mgr.local_player.display_name = "Bot %d" % client_index
		net_mgr.broadcast_message(net_mgr.MessageType.PLAYER_STATE, net_mgr.local_player.to_dict(), true)

	Log.game("DemoLauncher: Bot %d connected, setting up automation" % client_index)

	# Connect to phase changes with CONNECT_DEFERRED to avoid races
	var gm := _get_game_manager()
	if gm:
		gm.phase_changed.connect(_on_bot_phase_changed, CONNECT_DEFERRED)
		# Check current phase immediately after connecting
		Log.game("DemoLauncher: Bot checking current phase: %d" % gm.phase)
		_on_bot_phase_changed(gm.phase)

	demo_ready.emit()


func _on_bot_phase_changed(phase: int) -> void:
	var gm := _get_game_manager()
	if gm == null:
		return

	# Small delay for network sync
	await get_tree().create_timer(0.3).timeout

	# Only act in NOMINATE phase (bots are advisors)
	# Phase: 0=LOBBY, 1=DRAW, 2=NOMINATE, 3=PLACE, 4=GAME_OVER
	if phase == 2: # NOMINATE
		_bot_commit_nomination(gm)


func _bot_commit_nomination(gm: Node) -> void:
	var my_role: int = gm.local_role
	Log.game("DemoLauncher: Bot trying to commit, role=%d, visibility=%d items" % [my_role, gm.advisor_visibility.size()])

	# Only advisors commit nominations (role 1=INDUSTRY, 2=URBANIST)
	if my_role != 1 and my_role != 2:
		Log.game("DemoLauncher: Bot role %d is not an advisor, skipping" % my_role)
		return

	var role_name := "Industry" if my_role == 1 else "Urbanist"

	# Get revealed card suit for strategic decision
	var revealed_suit: int = -1
	Log.game("DemoLauncher: Bot %s hand.size=%d, revealed_index=%d" % [role_name, gm.hand.size(), gm.revealed_index])
	if gm.hand.size() > 0:
		# Advisors receive the revealed card in hand[0]
		var revealed_card: Dictionary = gm.hand[0]
		revealed_suit = revealed_card.get("suit", -1)
		Log.game("DemoLauncher: Bot %s sees revealed card suit=%d (%s)" % [role_name, revealed_suit, MapLayers.label(revealed_card)])
	else:
		Log.game("DemoLauncher: Bot %s has no hand data, using fallback strategy" % role_name)

	# Use strategic nomination based on revealed suit
	# Pass built_hexes to avoid nominating already-built tiles
	# Pass revealed_value so fallback lies are close to the revealed card
	var built: Array = gm.built_hexes if "built_hexes" in gm else []
	var revealed_value: int = 7 # Default
	if gm.hand.size() > 0:
		revealed_value = gm.hand[0].get("value", 7)

	var result: Dictionary = GameRules.pick_strategic_nomination(
		my_role,
		revealed_suit,
		gm.advisor_visibility,
		built,
		revealed_value
	)

	var chosen_hex: Vector3i = result.get("hex", GameRules.INVALID_HEX)
	var claimed_card: Dictionary = result.get("claim", {})
	var strategy: String = result.get("strategy", "unknown")

	if chosen_hex != GameRules.INVALID_HEX:
		Log.game("DemoLauncher: Bot %s using strategy '%s' -> hex (%d,%d,%d), claim: %s" % [
			role_name, strategy, chosen_hex.x, chosen_hex.y, chosen_hex.z,
			MapLayers.label(claimed_card) if not claimed_card.is_empty() else "none"
		])
		gm.commit_nomination(my_role, chosen_hex, claimed_card)
	else:
		# Ultimate fallback - should rarely happen now with improved GameRules fallback
		var fallback: Vector3i = gm.town_center + Vector3i(1, -1, 0)
		var fallback_suit: int = MapLayers.Suit.DIAMONDS if my_role == 1 else MapLayers.Suit.HEARTS
		var fallback_claim := {"suit": fallback_suit, "value": revealed_value, "rank": "7"}
		Log.game("DemoLauncher: Bot %s using EMERGENCY fallback hex (%d,%d,%d)" % [role_name, fallback.x, fallback.y, fallback.z])
		gm.commit_nomination(my_role, fallback, fallback_claim)

# ─────────────────────────────────────────────────────────────────────────────
# BOT SPAWNING
# ─────────────────────────────────────────────────────────────────────────────

func _spawn_bots() -> void:
	var exe_path := OS.get_executable_path()
	var project_path := ProjectSettings.globalize_path("res://")

	# Spawn 2 bots (Industry=1, Urbanist=2)
	for i in range(2):
		var bot_index := i + 1
		var args: Array[String] = [
			"--path", project_path,
			"--bot", str(bot_index),
			"--headless",
		]

		Log.game("DemoLauncher: Spawning bot %d" % bot_index)

		var pid := OS.create_process(exe_path, args)
		if pid > 0:
			_spawned_pids.append(pid)
			Log.game("DemoLauncher: Spawned bot %d (PID: %d)" % [bot_index, pid])
		else:
			push_error("DemoLauncher: Failed to spawn bot %d" % bot_index)

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

func _get_game_bus() -> Node:
	if has_node("/root/GameBus"):
		return get_node("/root/GameBus")
	return null


func _get_network_manager() -> Node:
	if has_node("/root/NetworkManager"):
		return get_node("/root/NetworkManager")
	return null


func _get_game_manager() -> Node:
	if get_tree().current_scene and get_tree().current_scene.has_node("GameManager"):
		return get_tree().current_scene.get_node("GameManager")
	return null


func _get_hex_field() -> Node:
	if get_tree().current_scene and get_tree().current_scene.has_node("HexField"):
		return get_tree().current_scene.get_node("HexField")
	return null


func _exit_tree() -> void:
	# Clean up spawned bots when server exits
	if role == Role.SERVER:
		for pid in _spawned_pids:
			OS.kill(pid)
		_spawned_pids.clear()
