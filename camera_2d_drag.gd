extends Camera2D

const TILE_WIDTH := 164.0 # pixels per tile
const TILE_HEIGHT := 190.0 # pixels per tile (hex height)

@export var zoom_min: float = 0.25
@export var zoom_max: float = 4.0
@export var zoom_step: float = 0.1

# Pan settings in tiles/sec (synced from GameMenu settings)
var keyboard_pan_speed: float = 40.0 # tiles/sec
var mouse_pan_speed: float = 40.0 # tiles/sec
var edge_pan_speed: float = 40.0 # tiles/sec
var edge_pan_margin: float = 20.0

var dragging := false
var drag_cam_start := Vector2.ZERO
var drag_mouse_start := Vector2.ZERO

# For demo mode: track last cursor event to follow
var _last_event_hex: Vector3i = Vector3i(0x7FFFFFFF, 0, 0)
var _follow_speed := 5.0 # Smoothing for camera follow


func _ready() -> void:
	make_current()
	_setup_mouse_mode()
	_connect_to_settings.call_deferred()
	# Start at center tile position - set directly
	global_position = Vector2.ZERO
	zoom = Vector2(1.0, 1.0)
	print("Camera: Initialized at origin, zoom 1.0")

	# Diagnostic logging for viewport/camera sanity
	call_deferred("_log_camera_info")


func _log_camera_info() -> void:
	var viewport := get_viewport()
	print("=== Camera/Viewport Diagnostics ===")
	print("  Viewport visible rect: %s" % viewport.get_visible_rect())
	print("  Window size: %s" % DisplayServer.window_get_size())
	print("  Camera position: %s" % global_position)
	print("  Camera zoom: %s" % zoom)
	print("  Is current: %s" % is_current())
	print("  Mouse mode: %d (0=visible, 1=hidden, 2=captured, 3=confined)" % Input.mouse_mode)

	# Calculate where center hex (0,0,0) maps to screen
	var world_pos := Vector2.ZERO # Center hex
	var screen_pos := get_viewport().get_canvas_transform() * world_pos
	print("  Center hex (0,0,0) world: %s -> screen: %s" % [world_pos, screen_pos])


func _setup_mouse_mode() -> void:
	# Never capture mouse - always visible
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _is_demo_mode() -> bool:
	if has_node("/root/DemoLauncher"):
		return get_node("/root/DemoLauncher").is_demo_mode
	# Also check command line args directly
	var args := OS.get_cmdline_args()
	return "--demo" in args or "--debug" in args or "--client" in args


func _connect_to_settings() -> void:
	if has_node("/root/GameMenu"):
		var menu := get_node("/root/GameMenu")
		if menu.settings:
			_sync_settings(menu.settings)
			menu.settings.settings_changed.connect(func(): _sync_settings(menu.settings))


func _sync_settings(settings: Node) -> void:
	keyboard_pan_speed = settings.keyboard_pan_speed
	mouse_pan_speed = settings.mouse_pan_speed
	edge_pan_speed = settings.edge_pan_speed
	edge_pan_margin = settings.edge_pan_margin


func _unhandled_input(event: InputEvent) -> void:
	# Debug: Log ALL mouse button events
	if event is InputEventMouseButton:
		print("Camera: MouseButton event: button=%d, pressed=%s" % [event.button_index, event.pressed])
	if event is InputEventMouseButton:
		# Middle mouse to drag
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				dragging = true
				drag_cam_start = global_position
				drag_mouse_start = get_global_mouse_position()
			else:
				dragging = false

		# Wheel zoom
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply_zoom(1.0 - zoom_step)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply_zoom(1.0 + zoom_step)

	# Trackpad pinch (Mac/Linux/Win)
	if event is InputEventMagnifyGesture:
		_apply_zoom(1.0 / event.factor)

	# SPACEBAR: Reset camera to center
	if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		_reset_view()


func _reset_view() -> void:
	# Center the camera at origin and zoom out to see the whole field
	global_position = Vector2.ZERO
	zoom = Vector2(1.0, 1.0)
	print("Camera: Reset to origin, zoom 1.0")


func _process(dt: float) -> void:
	if get_tree().paused:
		return

	# In multiplayer demo mode as server: follow cursor events
	# In single-player mode: use regular controls
	if _is_demo_mode() and _is_server() and not _is_singleplayer():
		_handle_demo_follow(dt)
	else:
		_handle_drag()
		_handle_edge_pan(dt)
		_handle_arrow_pan(dt)


func _is_singleplayer() -> bool:
	if has_node("/root/DemoLauncher"):
		return get_node("/root/DemoLauncher").is_singleplayer
	return false


## Tracks which player's cursor we're following and their last hex
var _followed_player_id: int = 0
var _player_last_hex: Dictionary = {} # player_id -> last known hex

func _handle_demo_follow(dt: float) -> void:
	var net_mgr := _get_network_manager()
	if net_mgr == null:
		return

	# Server watches REMOTE players only (clients), not itself
	var latest_hex := Vector3i(0x7FFFFFFF, 0, 0)
	var latest_player_id: int = 0

	for player in net_mgr.get_remote_players():
		if player.is_hovering():
			var player_id: int = player.peer_id
			var current_hex: Vector3i = player.hovered_hex

			# Check if this player's cursor moved (new event)
			var prev_hex: Vector3i = _player_last_hex.get(player_id, Vector3i(0x7FFFFFFF, 0, 0))
			if current_hex != prev_hex:
				# This player moved! Follow them
				_player_last_hex[player_id] = current_hex
				latest_hex = current_hex
				latest_player_id = player_id

	# Update target if we found a new event
	if latest_hex.x != 0x7FFFFFFF:
		_last_event_hex = latest_hex
		_followed_player_id = latest_player_id

	# Smoothly move camera to follow
	if _last_event_hex.x != 0x7FFFFFFF:
		var target_pos := _hex_to_world(_last_event_hex)
		global_position = global_position.lerp(target_pos, _follow_speed * dt)


func _hex_to_world(hex: Vector3i) -> Vector2:
	# Convert cube coordinates to pixel position
	# Using pointy-top hex layout
	var x := TILE_WIDTH * (sqrt(3.0) * hex.x + sqrt(3.0) / 2.0 * hex.y) / 2.0
	var y := TILE_HEIGHT * (3.0 / 4.0 * hex.y)
	return Vector2(x, y)


func _get_network_manager() -> Node:
	if has_node("/root/NetworkManager"):
		return get_node("/root/NetworkManager")
	return null


func _is_server() -> bool:
	var net_mgr := _get_network_manager()
	return net_mgr and net_mgr.is_server()


func _handle_drag() -> void:
	if dragging:
		var mouse_delta := get_global_mouse_position() - drag_mouse_start
		# Convert tiles/sec to pixels for drag sensitivity
		var speed_px := mouse_pan_speed * TILE_WIDTH / 40.0 # normalize so 40 t/s = 1x
		global_position = drag_cam_start - mouse_delta * speed_px / zoom


func _handle_edge_pan(dt: float) -> void:
	if dragging:
		return

	var viewport := get_viewport()
	var screen_size := viewport.get_visible_rect().size
	var mouse_pos := viewport.get_mouse_position()

	var pan_dir := Vector2.ZERO

	if mouse_pos.x < edge_pan_margin:
		pan_dir.x -= 1.0
	elif mouse_pos.x > screen_size.x - edge_pan_margin:
		pan_dir.x += 1.0

	if mouse_pos.y < edge_pan_margin:
		pan_dir.y -= 1.0
	elif mouse_pos.y > screen_size.y - edge_pan_margin:
		pan_dir.y += 1.0

	if pan_dir != Vector2.ZERO:
		var speed_px := edge_pan_speed * TILE_WIDTH
		global_position += pan_dir.normalized() * speed_px * dt / zoom.x


func _handle_arrow_pan(dt: float) -> void:
	var pan_dir := Vector2.ZERO

	if Input.is_action_pressed("ui_left"):
		pan_dir.x -= 1.0
	if Input.is_action_pressed("ui_right"):
		pan_dir.x += 1.0
	if Input.is_action_pressed("ui_up"):
		pan_dir.y -= 1.0
	if Input.is_action_pressed("ui_down"):
		pan_dir.y += 1.0

	if pan_dir != Vector2.ZERO:
		var speed_px := keyboard_pan_speed * TILE_WIDTH
		global_position += pan_dir.normalized() * speed_px * dt / zoom.x


func _apply_zoom(mult: float) -> void:
	var z := clampf(zoom.x * mult, zoom_min, zoom_max)
	zoom = Vector2(z, z)
