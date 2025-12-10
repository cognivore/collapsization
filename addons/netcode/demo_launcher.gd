## Autoload that handles demo/singleplayer mode: spawns bot clients that auto-play.
## Human plays as Mayor, 2 headless bot processes play as Industry and Urbanist advisors.
extends Node

const GameRules := preload("res://scripts/game_rules.gd")
const MapLayers := preload("res://scripts/map_layers.gd")

signal demo_ready

# ─────────────────────────────────────────────────────────────────────────────
# ENUMS & CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

enum Role {NONE, SERVER, CLIENT, BOT}

const PORT := 7779
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

var _spawned_pids: Array[int] = []

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_args()
	_start_role.call_deferred()


func _parse_args() -> void:
	var args := OS.get_cmdline_args()

	# Skip if running tests
	for arg in args:
		if arg == "-s" or arg.ends_with("gut_cmdln.gd"):
			role = Role.NONE
			return

	for i in range(args.size()):
		var arg := args[i]

		if arg == "--server":
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

	# Default: start as server (singleplayer host)
	if role == Role.NONE:
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
		Role.BOT:
			_start_bot(net_mgr)

# ─────────────────────────────────────────────────────────────────────────────
# SERVER (Human Mayor)
# ─────────────────────────────────────────────────────────────────────────────

func _start_server(net_mgr: Node) -> void:
	print("DemoLauncher: Starting SERVER (Human Mayor)")

	var err: Error = net_mgr.host_server(PORT)
	if err != OK:
		push_error("DemoLauncher: Failed to start server: %s" % error_string(err))
		return

	if net_mgr.local_player:
		net_mgr.local_player.set_color_index(0)

	# Configure game manager
	var gm := _get_game_manager()
	if gm:
		gm.game_seed = DEMO_SEED
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
	print("DemoLauncher: Player %d joined (%d/%d)" % [peer_id, player_count, REQUIRED_PLAYERS])

	# Start game when all players joined and still in LOBBY
	if player_count >= REQUIRED_PLAYERS and gm.phase == 0: # LOBBY
		print("DemoLauncher: All players joined! Starting game...")
		await get_tree().create_timer(0.5).timeout
		_start_game()


func _start_game() -> void:
	var gm := _get_game_manager()
	var hex_field := _get_hex_field()

	if hex_field and hex_field.has_method("reinit_map_layers"):
		hex_field.reinit_map_layers(DEMO_SEED)

	if gm:
		gm.start_game()
		print("DemoLauncher: Game started!")

# ─────────────────────────────────────────────────────────────────────────────
# CLIENT (Manual testing)
# ─────────────────────────────────────────────────────────────────────────────

func _start_client(net_mgr: Node) -> void:
	print("DemoLauncher: Starting CLIENT (index=%d)" % client_index)
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
	print("DemoLauncher: Starting BOT (index=%d)" % client_index)
	net_mgr.connected_to_server.connect(_on_connected_as_bot)

	var err: Error = net_mgr.join_server("127.0.0.1", PORT)
	if err != OK:
		push_error("DemoLauncher: Failed to join server as bot: %s" % error_string(err))


func _on_connected_as_bot() -> void:
	var net_mgr := _get_network_manager()
	if net_mgr and net_mgr.local_player:
		net_mgr.local_player.set_color_index(client_index)
		net_mgr.local_player.display_name = "Bot %d" % client_index
		net_mgr.broadcast_message(net_mgr.MessageType.PLAYER_STATE, net_mgr.local_player.to_dict(), true)

	print("DemoLauncher: Bot %d connected, setting up automation" % client_index)

	# Connect to phase changes
	var gm := _get_game_manager()
	if gm:
		gm.phase_changed.connect(_on_bot_phase_changed)

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
	print("DemoLauncher: Bot trying to commit, role=%d, visibility=%d items" % [my_role, gm.advisor_visibility.size()])

	# Only advisors commit nominations (role 1=INDUSTRY, 2=URBANIST)
	if my_role != 1 and my_role != 2:
		print("DemoLauncher: Bot role %d is not an advisor, skipping" % my_role)
		return

	var role_name := "Industry" if my_role == 1 else "Urbanist"

	# Get revealed card suit for strategic decision
	var revealed_suit: int = -1
	print("DemoLauncher: Bot %s hand.size=%d, revealed_index=%d" % [role_name, gm.hand.size(), gm.revealed_index])
	if gm.hand.size() > 0:
		# Advisors receive the revealed card in hand[0]
		var revealed_card: Dictionary = gm.hand[0]
		revealed_suit = revealed_card.get("suit", -1)
		print("DemoLauncher: Bot %s sees revealed card suit=%d (%s)" % [role_name, revealed_suit, MapLayers.label(revealed_card)])
	else:
		print("DemoLauncher: Bot %s has no hand data, using fallback strategy" % role_name)

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
		gm.town_center,
		built,
		revealed_value
	)

	var chosen_hex: Vector3i = result.get("hex", GameRules.INVALID_HEX)
	var claimed_card: Dictionary = result.get("claim", {})
	var strategy: String = result.get("strategy", "unknown")

	if chosen_hex != GameRules.INVALID_HEX:
		print("DemoLauncher: Bot %s using strategy '%s' -> hex (%d,%d,%d), claim: %s" % [
			role_name, strategy, chosen_hex.x, chosen_hex.y, chosen_hex.z,
			MapLayers.label(claimed_card) if not claimed_card.is_empty() else "none"
		])
		gm.commit_nomination(my_role, chosen_hex, claimed_card)
	else:
		# Ultimate fallback - should rarely happen now with improved GameRules fallback
		var fallback: Vector3i = gm.town_center + Vector3i(1, -1, 0)
		var fallback_suit: int = MapLayers.Suit.DIAMONDS if my_role == 1 else MapLayers.Suit.HEARTS
		var fallback_claim := {"suit": fallback_suit, "value": revealed_value, "rank": "7"}
		print("DemoLauncher: Bot %s using EMERGENCY fallback hex (%d,%d,%d)" % [role_name, fallback.x, fallback.y, fallback.z])
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

		print("DemoLauncher: Spawning bot %d" % bot_index)

		var pid := OS.create_process(exe_path, args)
		if pid > 0:
			_spawned_pids.append(pid)
			print("DemoLauncher: Spawned bot %d (PID: %d)" % [bot_index, pid])
		else:
			push_error("DemoLauncher: Failed to spawn bot %d" % bot_index)

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

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
