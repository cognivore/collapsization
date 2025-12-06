extends Camera2D

@export var zoom_min: float = 0.25
@export var zoom_max: float = 4.0
@export var zoom_step: float = 0.1     # wheel step

var dragging := false
var drag_cam_start := Vector2.ZERO
var drag_mouse_start := Vector2.ZERO

func _ready() -> void:
	make_current()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		# middle (or right) mouse to drag
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				dragging = true
				drag_cam_start = global_position
				drag_mouse_start = get_global_mouse_position()
			else:
				dragging = false

		# wheel zoom
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply_zoom(1.0 - zoom_step)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply_zoom(1.0 + zoom_step)

	# Trackpad pinch (Mac/Linux/Win)
	if event is InputEventMagnifyGesture:
		# factor > 1 means "zoom in"
		_apply_zoom(1.0 / event.factor)

func _process(_dt: float) -> void:
	if dragging:
		var mouse_delta = get_global_mouse_position() - drag_mouse_start
		# divide by zoom so drag speed feels consistent at any zoom level
		global_position = drag_cam_start - mouse_delta / zoom

func _apply_zoom(mult: float) -> void:
	var z := float(clamp(zoom.x * mult, zoom_min, zoom_max))
	zoom = Vector2(z, z)
