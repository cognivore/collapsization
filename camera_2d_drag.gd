extends Camera2D

const TILE_WIDTH := 164.0  # pixels per tile

@export var zoom_min: float = 0.25
@export var zoom_max: float = 4.0
@export var zoom_step: float = 0.1

# Pan settings in tiles/sec (synced from GameMenu settings)
var keyboard_pan_speed: float = 40.0  # tiles/sec
var mouse_pan_speed: float = 40.0  # tiles/sec
var edge_pan_speed: float = 40.0  # tiles/sec
var edge_pan_margin: float = 20.0

var dragging := false
var drag_cam_start := Vector2.ZERO
var drag_mouse_start := Vector2.ZERO


func _ready() -> void:
	make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CONFINED
	_connect_to_settings.call_deferred()


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


func _process(dt: float) -> void:
	if get_tree().paused:
		return
	_handle_drag()
	_handle_edge_pan(dt)
	_handle_arrow_pan(dt)


func _handle_drag() -> void:
	if dragging:
		var mouse_delta := get_global_mouse_position() - drag_mouse_start
		# Convert tiles/sec to pixels for drag sensitivity
		var speed_px := mouse_pan_speed * TILE_WIDTH / 40.0  # normalize so 40 t/s = 1x
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
