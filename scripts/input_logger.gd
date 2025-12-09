## Global input logger - prints every InputEvent for debugging.
## Add as autoload to capture all input before any other node.
extends Node

var _last_mouse_pos: Vector2 = Vector2.ZERO
var _frame_count: int = 0
var _last_logged_size: Vector2 = Vector2.ZERO

func _ready() -> void:
	print("InputLogger: Ready - will log all input events")
	_log_viewport_size()
	# Connect to viewport size changes
	get_viewport().size_changed.connect(_on_viewport_size_changed)


func _log_viewport_size() -> void:
	var vp_size := get_viewport().get_visible_rect().size
	var win_size := DisplayServer.window_get_size()
	var screen_scale: float = DisplayServer.screen_get_scale()
	print("InputLogger: Viewport size = %s, Window size = %s, Screen scale = %.2f" % [vp_size, win_size, screen_scale])
	_last_logged_size = vp_size


func _on_viewport_size_changed() -> void:
	var new_size := get_viewport().get_visible_rect().size
	if new_size != _last_logged_size:
		print("InputLogger: VIEWPORT RESIZED from %s to %s" % [_last_logged_size, new_size])
		print("InputLogger: Window size now = %s" % DisplayServer.window_get_size())
		_last_logged_size = new_size


func _input(event: InputEvent) -> void:
	_frame_count += 1

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var vp_size := get_viewport().get_visible_rect().size
		var win_size := DisplayServer.window_get_size()
		print("INPUT[%d]: MouseButton button=%d pressed=%s pos=%s global=%s (vp=%s, win=%s)" % [
			_frame_count, mb.button_index, mb.pressed, mb.position, mb.global_position, vp_size, win_size
		])

	elif event is InputEventMouseMotion:
		# Only log motion every 30 frames to avoid spam
		if _frame_count % 30 == 0:
			var mm := event as InputEventMouseMotion
			print("INPUT[%d]: MouseMotion pos=%s" % [_frame_count, mm.position])
		_last_mouse_pos = event.position

	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed:
			print("INPUT[%d]: Key pressed=%s keycode=%d scancode=%d" % [
				_frame_count, k.as_text(), k.keycode, k.physical_keycode
			])

	elif event is InputEventScreenTouch:
		print("INPUT[%d]: ScreenTouch index=%d pressed=%s pos=%s" % [
			_frame_count, event.index, event.pressed, event.position
		])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		print("InputLogger: Window FOCUS IN")
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		print("InputLogger: Window FOCUS OUT")
	elif what == NOTIFICATION_WM_MOUSE_ENTER:
		print("InputLogger: Mouse ENTERED window")
	elif what == NOTIFICATION_WM_MOUSE_EXIT:
		print("InputLogger: Mouse EXITED window")

