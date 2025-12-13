## Main menu for Multiplayer Minesweeper.
## Provides clean entry points for Singleplayer and Multiplayer modes.
## Uses proper Godot Control signals - no manual hit-testing.
extends Control

const PlayerStateScript := preload("res://addons/netcode/player_state.gd")
const SettingsManagerScript := preload("res://addons/elegant_menu/settings_manager.gd")
const LobbyScenePath := "res://ui/LobbyScene.tscn"
const WorldScenePath := "res://World.tscn"

@onready var _menu_panel: PanelContainer = $CenterContainer/MenuPanel
@onready var _settings_panel: PanelContainer = $SettingsPanel
@onready var _color_option: OptionButton = $SettingsPanel/VBox/MarginContainer/SettingsContent/PlayerColor/ColorOption
@onready var _color_preview: ColorRect = $SettingsPanel/VBox/MarginContainer/SettingsContent/PlayerColor/ColorPreview

# Button references (signals connected in .tscn)
@onready var _singleplayer_btn: Button = $CenterContainer/MenuPanel/MarginContainer/VBox/SingleplayerButton
@onready var _multiplayer_btn: Button = $CenterContainer/MenuPanel/MarginContainer/VBox/MultiplayerButton
@onready var _settings_btn: Button = $CenterContainer/MenuPanel/MarginContainer/VBox/SettingsButton
@onready var _quit_btn: Button = $CenterContainer/MenuPanel/MarginContainer/VBox/QuitButton

var settings: Node

# Track which mode to start
enum GameMode { NONE, SINGLEPLAYER, MULTIPLAYER }
var _pending_mode: GameMode = GameMode.NONE

var _lobby_instance: Control = null


func _ready() -> void:
	Log.ui("MainMenu: _ready() called")

	# Initialize settings manager
	settings = SettingsManagerScript.new()
	add_child(settings)

	# Sync color option with saved settings
	_sync_color_to_settings()

	# Explicitly connect button signals (in addition to .tscn connections for redundancy)
	# This ensures buttons work regardless of how the scene is loaded
	if _singleplayer_btn and not _singleplayer_btn.pressed.is_connected(_on_singleplayer_pressed):
		_singleplayer_btn.pressed.connect(_on_singleplayer_pressed)
	if _multiplayer_btn and not _multiplayer_btn.pressed.is_connected(_on_multiplayer_pressed):
		_multiplayer_btn.pressed.connect(_on_multiplayer_pressed)
	if _settings_btn and not _settings_btn.pressed.is_connected(_on_settings_pressed):
		_settings_btn.pressed.connect(_on_settings_pressed)
	if _quit_btn and not _quit_btn.pressed.is_connected(_on_quit_pressed):
		_quit_btn.pressed.connect(_on_quit_pressed)

	# Show main menu
	_show_main_menu()

	Log.ui("MainMenu: Ready and visible")


func _show_main_menu() -> void:
	_menu_panel.visible = true
	_settings_panel.visible = false


func _show_settings() -> void:
	_menu_panel.visible = false
	_settings_panel.visible = true
	_sync_color_to_settings()


func _sync_color_to_settings() -> void:
	var color_index: int = settings.player_color_index
	_color_option.selected = color_index
	_update_color_preview(color_index)


func _update_color_preview(index: int) -> void:
	if _color_preview:
		_color_preview.color = PlayerStateScript.PLAYER_COLORS[index % PlayerStateScript.PLAYER_COLORS.size()]


# ─────────────────────────────────────────────────────────────────────────────
# BUTTON HANDLERS (connected via signals in .tscn)
# ─────────────────────────────────────────────────────────────────────────────

func _on_singleplayer_pressed() -> void:
	Log.ui("MainMenu: SINGLEPLAYER BUTTON PRESSED!")
	_pending_mode = GameMode.SINGLEPLAYER
	_start_game()


func _on_multiplayer_pressed() -> void:
	Log.ui("MainMenu: MULTIPLAYER BUTTON PRESSED!")
	_pending_mode = GameMode.MULTIPLAYER
	_show_lobby()


func _on_settings_pressed() -> void:
	_show_settings()


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_back_pressed() -> void:
	settings.save_settings()
	_show_main_menu()


func _on_color_selected(index: int) -> void:
	settings.player_color_index = index
	_update_color_preview(index)


# ─────────────────────────────────────────────────────────────────────────────
# GAME START (uses GameBus for signaling)
# ─────────────────────────────────────────────────────────────────────────────

func _start_game() -> void:
	# Use GameBus to signal the game start
	var game_bus := _get_game_bus()
	if game_bus:
		var params := {
			"mode": "singleplayer" if _pending_mode == GameMode.SINGLEPLAYER else "multiplayer"
		}
		game_bus.start_game(params)

	# Change to the game scene
	var err := get_tree().change_scene_to_file(WorldScenePath)
	if err != OK:
		push_error("MainMenu: Failed to load World scene: %s" % error_string(err))


func _get_game_bus() -> Node:
	return get_node_or_null("/root/GameBus")


func _get_demo_launcher() -> Node:
	return get_node_or_null("/root/DemoLauncher")


func _show_lobby() -> void:
	Log.ui("MainMenu: Opening lobby...")

	# Load lobby UI as a child (stay on main menu background)
	var lobby_scene := load(LobbyScenePath) as PackedScene
	if lobby_scene == null:
		push_error("MainMenu: Failed to load lobby scene: %s" % LobbyScenePath)
		return

	_lobby_instance = lobby_scene.instantiate() as Control
	if _lobby_instance == null:
		push_error("MainMenu: Failed to instantiate lobby scene")
		return

	add_child(_lobby_instance)

	# Make sure lobby is on top and visible
	_lobby_instance.z_index = 10
	_lobby_instance.visible = true

	# Hide main menu panel while lobby is shown
	_menu_panel.visible = false
	_settings_panel.visible = false

	# Connect to lobby signals
	if _lobby_instance.has_signal("game_started"):
		_lobby_instance.game_started.connect(_on_lobby_game_started)
	if _lobby_instance.has_signal("closed"):
		_lobby_instance.closed.connect(_on_lobby_closed)

	Log.ui("MainMenu: Lobby opened successfully")


func _on_lobby_game_started(room_id: String, _players: Array) -> void:
	Log.ui("MainMenu: Game starting from lobby, room=%s" % room_id)
	_pending_mode = GameMode.MULTIPLAYER

	# Use GameBus to signal the game start
	var game_bus := _get_game_bus()
	if game_bus:
		var params := {"mode": "multiplayer", "room_id": room_id}
		game_bus.start_game(params)

	# Change to game scene
	var err := get_tree().change_scene_to_file(WorldScenePath)
	if err != OK:
		push_error("MainMenu: Failed to load World scene: %s" % error_string(err))


func _on_lobby_closed() -> void:
	# Show main menu again when lobby is closed
	if _lobby_instance and is_instance_valid(_lobby_instance):
		_lobby_instance.queue_free()
		_lobby_instance = null
	_show_main_menu()


# ─────────────────────────────────────────────────────────────────────────────
# DEBUG INPUT (check click positions)
# ─────────────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	# Workaround: Godot 4.5 content scaling may break button hit detection
	# Manually check if clicks fall within button rects and trigger handlers
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		var pos: Vector2 = mb.position

		# Check each visible button
		if _menu_panel and _menu_panel.visible:
			if _singleplayer_btn and _singleplayer_btn.get_global_rect().has_point(pos):
				Log.ui("MainMenu: Manual click on Singleplayer button")
				_on_singleplayer_pressed()
				return  # Scene changes, don't try to handle further
			elif _multiplayer_btn and _multiplayer_btn.get_global_rect().has_point(pos):
				Log.ui("MainMenu: Manual click on Multiplayer button")
				_on_multiplayer_pressed()
				return
			elif _settings_btn and _settings_btn.get_global_rect().has_point(pos):
				Log.ui("MainMenu: Manual click on Settings button")
				_on_settings_pressed()
				return
			elif _quit_btn and _quit_btn.get_global_rect().has_point(pos):
				Log.ui("MainMenu: Manual click on Quit button")
				_on_quit_pressed()
				return

		if _settings_panel and _settings_panel.visible:
			var back_btn := get_node_or_null("SettingsPanel/VBox/MarginContainer/SettingsContent/BackButton")
			if back_btn and back_btn.get_global_rect().has_point(pos):
				Log.ui("MainMenu: Manual click on Back button")
				_on_back_pressed()
				return


# ─────────────────────────────────────────────────────────────────────────────
# KEYBOARD INPUT (ESC to close lobby)
# ─────────────────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	# Allow ESC to close lobby and go back to main menu
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _lobby_instance and is_instance_valid(_lobby_instance):
			_on_lobby_closed()
			get_viewport().set_input_as_handled()
		elif _settings_panel.visible:
			_on_back_pressed()
			get_viewport().set_input_as_handled()
