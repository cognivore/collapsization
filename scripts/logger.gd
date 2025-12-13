## Unified logging system with category-based filtering and command-line control.
##
## Usage (accessed via autoload singleton "Log"):
##   Log.input("Mouse clicked at %s" % pos)
##   Log.net("Player %d connected" % id)
##   Log.game("Phase changed to %s" % phase_name)
##   Log.ui("Button pressed: %s" % btn.name)
##   Log.hex("Hex clicked: %s" % cube)
##   Log.dbg("Variable x = %d" % x)
##
## Command-line flags:
##   --debug-log           Enable all categories
##   --debug-log=CAT,CAT   Enable specific categories (INPUT,NET,GAME,UI,HEX,DEBUG)
##   --debug-log-file      Also write logs to user://logs/
##
## In normal runs (no flags), logging is silent for clean output.
## When INPUT category is enabled, all input events are automatically captured.
extends Node

## Log categories
enum Category { INPUT, NET, GAME, UI, HEX, DEBUG }

## Category names for parsing and output
const CATEGORY_NAMES := {
	Category.INPUT: "INPUT",
	Category.NET: "NET",
	Category.GAME: "GAME",
	Category.UI: "UI",
	Category.HEX: "HEX",
	Category.DEBUG: "DEBUG",
}

## Reverse lookup: name -> category
const NAME_TO_CATEGORY := {
	"INPUT": Category.INPUT,
	"NET": Category.NET,
	"GAME": Category.GAME,
	"UI": Category.UI,
	"HEX": Category.HEX,
	"DEBUG": Category.DEBUG,
}

## Which categories are enabled (empty = all disabled, unless _all_enabled)
var _enabled_categories: Dictionary = {}
var _all_enabled: bool = false
var _file_output: FileAccess = null
var _log_path: String = ""

# Input capture state
var _frame_count: int = 0
var _last_logged_vp_size: Vector2 = Vector2.ZERO


func _ready() -> void:
	_parse_command_line()

	# Log viewport info if INPUT is enabled
	if _is_enabled(Category.INPUT):
		_log_viewport_size()
		get_viewport().size_changed.connect(_on_viewport_size_changed)


func _log_viewport_size() -> void:
	var vp_size := get_viewport().get_visible_rect().size
	var win_size := DisplayServer.window_get_size()
	var screen_scale: float = DisplayServer.screen_get_scale()
	input("Viewport size = %s, Window size = %s, Screen scale = %.2f" % [vp_size, win_size, screen_scale])
	_last_logged_vp_size = vp_size


func _on_viewport_size_changed() -> void:
	if not _is_enabled(Category.INPUT):
		return
	var new_size := get_viewport().get_visible_rect().size
	if new_size != _last_logged_vp_size:
		input("VIEWPORT RESIZED from %s to %s" % [_last_logged_vp_size, new_size])
		input("Window size now = %s" % DisplayServer.window_get_size())
		_last_logged_vp_size = new_size


## Automatic input event capture when INPUT category is enabled
func _input(event: InputEvent) -> void:
	if not _is_enabled(Category.INPUT):
		return

	_frame_count += 1

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var vp_size := get_viewport().get_visible_rect().size
		var win_size := DisplayServer.window_get_size()
		input("[%d] MouseButton button=%d pressed=%s pos=%s global=%s (vp=%s, win=%s)" % [
			_frame_count, mb.button_index, mb.pressed, mb.position, mb.global_position, vp_size, win_size
		])
	elif event is InputEventMouseMotion:
		# Only log motion every 30 frames to avoid spam
		if _frame_count % 30 == 0:
			var mm := event as InputEventMouseMotion
			input("[%d] MouseMotion pos=%s" % [_frame_count, mm.position])
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed:
			input("[%d] Key pressed=%s keycode=%d scancode=%d" % [
				_frame_count, k.as_text(), k.keycode, k.physical_keycode
			])
	elif event is InputEventScreenTouch:
		input("[%d] ScreenTouch index=%d pressed=%s pos=%s" % [
			_frame_count, event.index, event.pressed, event.position
		])


func _notification(what: int) -> void:
	if not _is_enabled(Category.INPUT):
		return
	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		input("Window FOCUS IN")
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		input("Window FOCUS OUT")
	elif what == NOTIFICATION_WM_MOUSE_ENTER:
		input("Mouse ENTERED window")
	elif what == NOTIFICATION_WM_MOUSE_EXIT:
		input("Mouse EXITED window")


func _exit_tree() -> void:
	if _file_output:
		_file_output.close()
		_file_output = null


func _parse_command_line() -> void:
	var args := OS.get_cmdline_args()
	var user_args := OS.get_cmdline_user_args()
	var all_args := args + user_args

	for arg in all_args:
		if arg == "--debug-log":
			_all_enabled = true
		elif arg.begins_with("--debug-log="):
			var categories_str := arg.substr(12)  # len("--debug-log=")
			var category_names := categories_str.split(",")
			for cat_name in category_names:
				var upper_name := cat_name.strip_edges().to_upper()
				if NAME_TO_CATEGORY.has(upper_name):
					_enabled_categories[NAME_TO_CATEGORY[upper_name]] = true
		elif arg == "--debug-log-file":
			_setup_file_output()

	# Log initialization status
	if _all_enabled or not _enabled_categories.is_empty():
		var enabled_list: Array[String] = []
		if _all_enabled:
			enabled_list.append("ALL")
		else:
			for cat in _enabled_categories.keys():
				enabled_list.append(CATEGORY_NAMES[cat])
		print("[Log] Enabled categories: %s" % ", ".join(enabled_list))
		if _file_output:
			print("[Log] File output: %s" % _log_path)


func _setup_file_output() -> void:
	var logs_dir := "user://logs"
	if not DirAccess.dir_exists_absolute(logs_dir):
		DirAccess.make_dir_absolute(logs_dir)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	_log_path = "%s/game_%s.log" % [logs_dir, timestamp]
	_file_output = FileAccess.open(_log_path, FileAccess.WRITE)

	if _file_output:
		_file_output.store_line("=== Log started at %s ===" % timestamp)
		_file_output.store_line("Godot %s" % Engine.get_version_info().string)
		_file_output.store_line("")
		_file_output.flush()


func _is_enabled(category: Category) -> bool:
	if _all_enabled:
		return true
	return _enabled_categories.get(category, false)


func _get_timestamp() -> String:
	var time := Time.get_time_dict_from_system()
	var msec := Time.get_ticks_msec() % 1000
	return "%02d:%02d:%02d.%03d" % [time.hour, time.minute, time.second, msec]


func _log(category: Category, message: String) -> void:
	if not _is_enabled(category):
		return

	var cat_name: String = CATEGORY_NAMES.get(category, "???")
	var timestamp := _get_timestamp()
	var line := "[%s][%s] %s" % [timestamp, cat_name, message]

	print(line)

	if _file_output:
		_file_output.store_line(line)
		_file_output.flush()


## Log input events (mouse, keyboard, touch)
func input(message: String) -> void:
	_log(Category.INPUT, message)


## Log network events (connections, messages, lobby)
func net(message: String) -> void:
	_log(Category.NET, message)


## Log game logic (phases, actions, state changes)
func game(message: String) -> void:
	_log(Category.GAME, message)


## Log UI events (button presses, panel visibility)
func ui(message: String) -> void:
	_log(Category.UI, message)


## Log hex/map events (clicks, selections, overlays)
func hex(message: String) -> void:
	_log(Category.HEX, message)


## Log debug/development messages (renamed from debug() to avoid conflicts)
func dbg(message: String) -> void:
	_log(Category.DEBUG, message)


## Check if a category is currently enabled
func is_enabled(category: Category) -> bool:
	return _is_enabled(category)


## Programmatically enable a category (for runtime toggling)
func enable(category: Category) -> void:
	_enabled_categories[category] = true


## Programmatically disable a category
func disable(category: Category) -> void:
	_enabled_categories.erase(category)


## Enable all categories
func enable_all() -> void:
	_all_enabled = true


## Disable all categories
func disable_all() -> void:
	_all_enabled = false
	_enabled_categories.clear()
