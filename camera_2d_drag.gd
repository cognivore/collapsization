extends Camera2D

@export var zoom_min: float = 0.25
@export var zoom_max: float = 4.0
@export var zoom_step: float = 0.1

## Pan speed in pixels per second (at zoom 1.0)
@export var pan_speed: float = 800.0
## Edge pan margin in pixels from screen edge
@export var edge_margin: float = 20.0
## Seconds to hold Esc to quit
@export var esc_hold_duration: float = 5.0

var dragging := false
var drag_cam_start := Vector2.ZERO
var drag_mouse_start := Vector2.ZERO
var esc_held_time := 0.0


func _ready() -> void:
	make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CONFINED
	print("RTS Camera ready - Controls:")
	print("  - Edge pan: move mouse to screen edges")
	print("  - Arrow keys: pan camera")
	print("  - Middle-mouse drag: pan camera")
	print("  - Scroll wheel: zoom")
	print("  - Hold Esc 5s: quit")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit_game()


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
	_handle_drag()
	_handle_edge_pan(dt)
	_handle_arrow_pan(dt)
	_handle_esc_quit(dt)


func _handle_drag() -> void:
	if dragging:
		var mouse_delta := get_global_mouse_position() - drag_mouse_start
		global_position = drag_cam_start - mouse_delta / zoom


func _handle_edge_pan(dt: float) -> void:
	if dragging:
		return

	var viewport := get_viewport()
	var screen_size := viewport.get_visible_rect().size
	var mouse_pos := viewport.get_mouse_position()

	var pan_dir := Vector2.ZERO

	if mouse_pos.x < edge_margin:
		pan_dir.x -= 1.0
	elif mouse_pos.x > screen_size.x - edge_margin:
		pan_dir.x += 1.0

	if mouse_pos.y < edge_margin:
		pan_dir.y -= 1.0
	elif mouse_pos.y > screen_size.y - edge_margin:
		pan_dir.y += 1.0

	if pan_dir != Vector2.ZERO:
		global_position += pan_dir.normalized() * pan_speed * dt / zoom.x


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
		global_position += pan_dir.normalized() * pan_speed * dt / zoom.x


var _last_esc_print := 0.0

func _handle_esc_quit(dt: float) -> void:
	if Input.is_action_pressed("ui_cancel"):
		esc_held_time += dt
		# Print countdown every second
		var secs_left := esc_hold_duration - esc_held_time
		if int(secs_left) != int(_last_esc_print) and secs_left > 0:
			print("Quitting in %.0f..." % ceilf(secs_left))
		_last_esc_print = secs_left
		if esc_held_time >= esc_hold_duration:
			_quit_game()
	else:
		if esc_held_time > 0.5:
			print("Esc released - quit cancelled")
		esc_held_time = 0.0
		_last_esc_print = 0.0


func _apply_zoom(mult: float) -> void:
	var z := clampf(zoom.x * mult, zoom_min, zoom_max)
	zoom = Vector2(z, z)


func _quit_game() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().quit()
