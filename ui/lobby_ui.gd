## Lobby UI for room creation and joining.
## Handles connection to lobby server and room management.
## Uses proper Godot Control signals - no manual hit-testing.
extends Control

const LobbyClientScript := preload("res://addons/netcode/lobby_client.gd")

signal game_started(room_id: String, players: Array)
signal closed

@export var default_server_address: String = "mines.fere.me"
@export var default_server_port: int = 7777

@onready var _connect_panel: PanelContainer = $ConnectPanel
@onready var _lobby_panel: PanelContainer = $LobbyPanel
@onready var _room_panel: PanelContainer = $RoomPanel

# Connect panel
@onready var _name_input: LineEdit = $ConnectPanel/VBox/NameRow/NameInput
@onready var _address_input: LineEdit = $ConnectPanel/VBox/AddressRow/AddressInput
@onready var _port_input: LineEdit = $ConnectPanel/VBox/PortRow/PortInput
@onready var _connect_button: Button = $ConnectPanel/VBox/ConnectButton
@onready var _connect_status: Label = $ConnectPanel/VBox/Status

# Lobby panel
@onready var _room_list: VBoxContainer = $LobbyPanel/VBox/ScrollContainer/RoomList
@onready var _create_room_button: Button = $LobbyPanel/VBox/ButtonRow/CreateRoomButton
@onready var _refresh_button: Button = $LobbyPanel/VBox/ButtonRow/RefreshButton
@onready var _disconnect_button: Button = $LobbyPanel/VBox/ButtonRow/DisconnectButton
@onready var _lobby_status: Label = $LobbyPanel/VBox/Status

# Room panel
@onready var _room_id_label: Label = $RoomPanel/VBox/RoomIdLabel
@onready var _player_list: VBoxContainer = $RoomPanel/VBox/PlayerList
@onready var _player_count_label: Label = $RoomPanel/VBox/PlayerCountLabel
@onready var _button_row: HBoxContainer = $RoomPanel/VBox/ButtonRow
@onready var _add_bot_button: Button = $RoomPanel/VBox/ButtonRow/AddBotButton
@onready var _start_game_button: Button = $RoomPanel/VBox/ButtonRow/StartGameButton
@onready var _leave_room_button: Button = $RoomPanel/VBox/ButtonRow/LeaveRoomButton
@onready var _room_status: Label = $RoomPanel/VBox/Status

var _player_name: String = "Player"
var _is_host: bool = false

var _lobby_client: LobbyClientScript

const SETTINGS_PATH := "user://player_settings.cfg"


func _ready() -> void:
	_lobby_client = LobbyClientScript.new()
	add_child(_lobby_client)

	# Connect lobby client signals
	_lobby_client.connected_to_lobby.connect(_on_connected_to_lobby)
	_lobby_client.disconnected_from_lobby.connect(_on_disconnected_from_lobby)
	_lobby_client.room_list_updated.connect(_on_room_list_updated)
	_lobby_client.room_joined.connect(_on_room_joined)
	_lobby_client.room_updated.connect(_on_room_updated)
	_lobby_client.room_left.connect(_on_room_left)
	_lobby_client.game_starting.connect(_on_game_starting)
	_lobby_client.lobby_error.connect(_on_lobby_error)

	# Connect button signals (the Godot way - no manual hit testing!)
	_connect_button.pressed.connect(_on_connect_pressed)
	_create_room_button.pressed.connect(_on_create_room_pressed)
	_refresh_button.pressed.connect(_on_refresh_pressed)
	_disconnect_button.pressed.connect(_on_disconnect_pressed)
	_add_bot_button.pressed.connect(_on_add_bot_pressed)
	_start_game_button.pressed.connect(_on_start_game_pressed)
	_leave_room_button.pressed.connect(_on_leave_room_pressed)

	# Set focus mode on LineEdits for proper keyboard navigation
	_name_input.focus_mode = Control.FOCUS_ALL
	_address_input.focus_mode = Control.FOCUS_ALL
	_port_input.focus_mode = Control.FOCUS_ALL

	# Load saved settings or generate new name
	_load_player_settings()

	# Set defaults
	_address_input.text = default_server_address
	_port_input.text = str(default_server_port)

	_show_connect_panel()

	# Give focus to name input for keyboard users
	_name_input.grab_focus()


func _load_player_settings() -> void:
	var config := ConfigFile.new()
	var err := config.load(SETTINGS_PATH)
	if err == OK:
		var saved_name: String = config.get_value("player", "name", "")
		if not saved_name.is_empty():
			_player_name = saved_name
			_name_input.text = saved_name
			Log.ui("LobbyUI: Loaded saved player name: %s" % saved_name)
			return

	# Generate cute random name if no saved name
	_player_name = _generate_player_name()
	_name_input.text = _player_name
	Log.ui("LobbyUI: Generated new player name: %s" % _player_name)


func _save_player_name(name: String) -> void:
	var config := ConfigFile.new()
	config.set_value("player", "name", name)
	var err := config.save(SETTINGS_PATH)
	if err == OK:
		Log.ui("LobbyUI: Saved player name: %s" % name)
	else:
		push_error("LobbyUI: Failed to save player name: %s" % error_string(err))


func _generate_player_name() -> String:
	# Generate a cute random name
	var adjectives := [
		"Tiny", "Fuzzy", "Sparkly", "Bouncy", "Fluffy", "Cosmic", "Mystic", "Zippy",
		"Cozy", "Snowy", "Starry", "Sunny", "Lucky", "Happy", "Sleepy", "Dizzy",
		"Twinkle", "Bubble", "Rainbow", "Velvet", "Crystal", "Golden", "Silver", "Midnight"
	]
	var nouns := [
		"Bunny", "Fox", "Owl", "Bear", "Panda", "Kitten", "Otter", "Hedgehog",
		"Penguin", "Koala", "Deer", "Squirrel", "Raccoon", "Wolf", "Dragon", "Phoenix",
		"Moth", "Bee", "Frog", "Seal", "Sloth", "Badger", "Ferret", "Mole"
	]
	return adjectives[randi() % adjectives.size()] + nouns[randi() % nouns.size()]


func _show_connect_panel() -> void:
	_connect_panel.visible = true
	_lobby_panel.visible = false
	_room_panel.visible = false


func _show_lobby_panel() -> void:
	_connect_panel.visible = false
	_lobby_panel.visible = true
	_room_panel.visible = false


func _show_room_panel() -> void:
	_connect_panel.visible = false
	_lobby_panel.visible = false
	_room_panel.visible = true


# ─────────────────────────────────────────────────────────────────────────────
# BUTTON HANDLERS (connected via signals)
# ─────────────────────────────────────────────────────────────────────────────

func _on_connect_pressed() -> void:
	Log.ui("LobbyUI: Connect button pressed")
	var address := _address_input.text.strip_edges()
	var port := int(_port_input.text.strip_edges())
	_player_name = _name_input.text.strip_edges()

	if _player_name.is_empty():
		_player_name = _generate_player_name()
		_name_input.text = _player_name

	# Save player name for next time
	_save_player_name(_player_name)

	if address.is_empty():
		_connect_status.text = "Enter server address"
		return

	if port <= 0 or port > 65535:
		_connect_status.text = "Invalid port"
		return

	_connect_status.text = "Connecting..."
	_connect_button.disabled = true

	var err := _lobby_client.connect_to_lobby(address, port)
	if err != OK:
		_connect_status.text = "Connection failed: %s" % error_string(err)
		_connect_button.disabled = false


func _on_create_room_pressed() -> void:
	_lobby_status.text = "Creating room..."
	_lobby_client.create_room()


func _on_refresh_pressed() -> void:
	_lobby_status.text = "Refreshing..."
	_lobby_client.request_room_list()


func _on_disconnect_pressed() -> void:
	_lobby_client.disconnect_from_lobby()


func _on_add_bot_pressed() -> void:
	_room_status.text = "Adding bot..."
	_lobby_client.add_bot()


func _on_start_game_pressed() -> void:
	_room_status.text = "Starting game..."
	_start_game_button.disabled = true
	_lobby_client.request_start_game()


func _on_leave_room_pressed() -> void:
	_is_host = false
	_lobby_client.leave_room()


# ─────────────────────────────────────────────────────────────────────────────
# LOBBY CLIENT SIGNALS
# ─────────────────────────────────────────────────────────────────────────────

func _on_connected_to_lobby() -> void:
	_connect_button.disabled = false
	_show_lobby_panel()
	_lobby_status.text = "Connected to lobby"


func _on_disconnected_from_lobby() -> void:
	_connect_button.disabled = false
	_show_connect_panel()
	_connect_status.text = "Disconnected"


func _on_room_list_updated(rooms: Array) -> void:
	_clear_room_list()

	if rooms.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No rooms available. Create one!"
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_room_list.add_child(empty_label)
	else:
		for room_data: Dictionary in rooms:
			_add_room_entry(room_data)

	_lobby_status.text = "%d room(s) available" % rooms.size()


func _on_room_joined(room_id: String, players: Array, bots: Array) -> void:
	_room_id_label.text = "Room: %s" % room_id
	_update_player_list(players, bots)
	_show_room_panel()

	# Check if we're the host (first player in the room)
	var net_mgr = _get_network_manager()
	var local_id: int = net_mgr.get_local_id() if net_mgr else 0
	_is_host = players.size() > 0 and players[0] == local_id

	_update_buttons(players.size() + bots.size())
	_room_status.text = "Waiting for players..."

	# Set player name on local player
	if net_mgr and net_mgr.local_player:
		net_mgr.local_player.display_name = _player_name


func _on_room_updated(_room_id: String, player_count: int, required: int, bots: Array) -> void:
	_player_count_label.text = "Slots: %d / %d" % [player_count, required]
	_update_player_list(_lobby_client.current_room_players, bots)
	_update_buttons(player_count)

	if player_count >= required:
		_room_status.text = "Ready to start! (Host can start game)"
	else:
		_room_status.text = "Waiting for %d more slot(s)..." % (required - player_count)


func _on_room_left() -> void:
	_show_lobby_panel()
	_lobby_status.text = "Left room"


func _on_game_starting(room_id: String, players: Array, _bots: Array, _host: int) -> void:
	_room_status.text = "Game starting!"
	game_started.emit(room_id, players)


func _on_lobby_error(message: String) -> void:
	if _connect_panel.visible:
		_connect_status.text = "Error: %s" % message
	elif _lobby_panel.visible:
		_lobby_status.text = "Error: %s" % message
	elif _room_panel.visible:
		_room_status.text = "Error: %s" % message


# ─────────────────────────────────────────────────────────────────────────────
# UI HELPERS
# ─────────────────────────────────────────────────────────────────────────────

func _clear_room_list() -> void:
	for child in _room_list.get_children():
		child.queue_free()


func _add_room_entry(room_data: Dictionary) -> void:
	var room_id: String = room_data.get("room_id", "???")
	var player_count: int = room_data.get("player_count", 0)
	var required: int = room_data.get("required", 3)

	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var id_label := Label.new()
	id_label.text = room_id
	id_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(id_label)

	var count_label := Label.new()
	count_label.text = "%d/%d" % [player_count, required]
	count_label.custom_minimum_size = Vector2(60, 0)
	hbox.add_child(count_label)

	var join_button := Button.new()
	join_button.text = "Join"
	join_button.custom_minimum_size = Vector2(80, 0)
	join_button.disabled = player_count >= required
	join_button.pressed.connect(_on_join_room_pressed.bind(room_id))
	hbox.add_child(join_button)

	_room_list.add_child(hbox)


func _update_player_list(players: Array, bots: Array = []) -> void:
	for child in _player_list.get_children():
		child.queue_free()

	var net_mgr = _get_network_manager()
	var local_id: int = net_mgr.get_local_id() if net_mgr else 0
	var slot_index: int = 1

	# Show human players first
	for i in range(players.size()):
		var peer_id: int = players[i]
		var hbox := HBoxContainer.new()
		hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var label := Label.new()
		var player_name := "Player %d" % slot_index
		if peer_id == local_id:
			player_name += " (You)"
		label.text = player_name
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(label)

		_player_list.add_child(hbox)
		slot_index += 1

	# Show bots
	for bot_id: int in bots:
		var hbox := HBoxContainer.new()
		hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var label := Label.new()
		label.text = "Bot %d" % slot_index
		label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(label)

		var remove_btn := Button.new()
		remove_btn.text = "X"
		remove_btn.custom_minimum_size = Vector2(30, 0)
		remove_btn.pressed.connect(_on_remove_bot_pressed.bind(bot_id))
		hbox.add_child(remove_btn)

		_player_list.add_child(hbox)
		slot_index += 1

	var total := players.size() + bots.size()
	_player_count_label.text = "Slots: %d / 3" % total


func _update_add_bot_button(current_count: int) -> void:
	_add_bot_button.disabled = current_count >= 3


func _update_buttons(current_count: int) -> void:
	_update_add_bot_button(current_count)
	# Start button: enabled if host and room has enough players (at least 2 for testing, 3 for full game)
	_start_game_button.disabled = not _is_host or current_count < 2
	_start_game_button.text = "Start Game" if _is_host else "(Host Only)"


func _on_remove_bot_pressed(bot_id: int) -> void:
	_room_status.text = "Removing bot..."
	_lobby_client.remove_bot(bot_id)


func _on_join_room_pressed(room_id: String) -> void:
	_lobby_status.text = "Joining room %s..." % room_id
	_lobby_client.join_room(room_id)


func _get_network_manager() -> Node:
	if has_node("/root/NetworkManager"):
		return get_node("/root/NetworkManager")
	return null


# ─────────────────────────────────────────────────────────────────────────────
# MANUAL CLICK DETECTION (workaround for Godot 4.5 content scaling bug)
# ─────────────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		var pos: Vector2 = mb.position

		# Check connect panel buttons
		if _connect_panel and _connect_panel.visible:
			if _connect_button and _connect_button.get_global_rect().has_point(pos):
				Log.ui("LobbyUI: Manual click on Connect button")
				_on_connect_pressed()
				return
			# Check if clicking on LineEdits to focus them
			if _name_input and _name_input.get_global_rect().has_point(pos):
				_name_input.grab_focus()
				return
			if _address_input and _address_input.get_global_rect().has_point(pos):
				_address_input.grab_focus()
				return
			if _port_input and _port_input.get_global_rect().has_point(pos):
				_port_input.grab_focus()
				return

		# Check lobby panel buttons
		if _lobby_panel and _lobby_panel.visible:
			if _create_room_button and _create_room_button.get_global_rect().has_point(pos):
				Log.ui("LobbyUI: Manual click on Create Room button")
				_on_create_room_pressed()
				return
			if _refresh_button and _refresh_button.get_global_rect().has_point(pos):
				Log.ui("LobbyUI: Manual click on Refresh button")
				_on_refresh_pressed()
				return
			if _disconnect_button and _disconnect_button.get_global_rect().has_point(pos):
				Log.ui("LobbyUI: Manual click on Disconnect button")
				_on_disconnect_pressed()
				return
			# Check room list join buttons
			_try_click_room_list_buttons(pos)

		# Check room panel buttons
		if _room_panel and _room_panel.visible:
			if _add_bot_button and not _add_bot_button.disabled and _add_bot_button.get_global_rect().has_point(pos):
				Log.ui("LobbyUI: Manual click on Add Bot button")
				_on_add_bot_pressed()
				return
			if _start_game_button and not _start_game_button.disabled and _start_game_button.get_global_rect().has_point(pos):
				Log.ui("LobbyUI: Manual click on Start Game button")
				_on_start_game_pressed()
				return
			if _leave_room_button and _leave_room_button.get_global_rect().has_point(pos):
				Log.ui("LobbyUI: Manual click on Leave Room button")
				_on_leave_room_pressed()
				return
			# Check remove bot buttons in player list
			_try_click_player_list_buttons(pos)


func _try_click_room_list_buttons(pos: Vector2) -> void:
	if not _room_list:
		return
	for child in _room_list.get_children():
		if child is HBoxContainer:
			for subchild in child.get_children():
				if subchild is Button and subchild.get_global_rect().has_point(pos):
					Log.ui("LobbyUI: Manual click on room Join button")
					subchild.pressed.emit()
					return


func _try_click_player_list_buttons(pos: Vector2) -> void:
	if not _player_list:
		return
	for child in _player_list.get_children():
		if child is HBoxContainer:
			for subchild in child.get_children():
				if subchild is Button and subchild.get_global_rect().has_point(pos):
					Log.ui("LobbyUI: Manual click on player list button")
					subchild.pressed.emit()
					return


# ─────────────────────────────────────────────────────────────────────────────
# KEYBOARD INPUT (ESC to go back)
# ─────────────────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _room_panel.visible:
			_on_leave_room_pressed()
			get_viewport().set_input_as_handled()
		elif _lobby_panel.visible:
			_on_disconnect_pressed()
			get_viewport().set_input_as_handled()
		elif _connect_panel.visible:
			closed.emit()
			get_viewport().set_input_as_handled()
