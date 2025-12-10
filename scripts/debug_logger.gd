## Rotating debug log system for input/coordinate debugging.
## Writes timestamped logs to files with automatic rotation.
## Categories: INPUT, COORD, HUD, CAMERA
## Usage: DebugLogger.log_input("Mouse click at %s" % pos)
extends Node

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

const MAX_LOG_FILES := 5
const MAX_LOG_SIZE_BYTES := 1024 * 1024 # 1 MB per file
const LOG_DIR := "user://logs/"
const LOG_PREFIX := "debug_"

enum Category {
	INPUT,
	COORD,
	HUD,
	CAMERA,
	GAME,
	GENERAL,
}

const CATEGORY_NAMES := ["INPUT", "COORD", "HUD", "CAMERA", "GAME", "GENERAL"]

# ─────────────────────────────────────────────────────────────────────────────
# STATE
# ─────────────────────────────────────────────────────────────────────────────

var _enabled := true
var _file: FileAccess
var _current_log_path: String
var _frame_count := 0
var _session_id: String
var _category_filters: Dictionary = {} # Category -> bool (true = enabled)

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_session_id = _generate_session_id()
	_ensure_log_dir()
	_rotate_logs()
	_open_log_file()

	# Enable all categories by default
	for cat in Category.values():
		_category_filters[cat] = true

	_write_header()
	print("DebugLogger: Initialized, logging to %s" % _current_log_path)


func _process(_delta: float) -> void:
	_frame_count += 1


func _exit_tree() -> void:
	_write_footer()
	if _file:
		_file.close()

# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

## Log an input event
func log_input(message: String) -> void:
	_log(Category.INPUT, message)


## Log coordinate transformation info
func log_coord(message: String) -> void:
	_log(Category.COORD, message)


## Log HUD-related info
func log_hud(message: String) -> void:
	_log(Category.HUD, message)


## Log camera-related info
func log_camera(message: String) -> void:
	_log(Category.CAMERA, message)


## Log game state info
func log_game(message: String) -> void:
	_log(Category.GAME, message)


## General log
func log_general(message: String) -> void:
	_log(Category.GENERAL, message)


## Enable or disable a category
func set_category_enabled(category: Category, enabled: bool) -> void:
	_category_filters[category] = enabled


## Enable or disable all logging
func set_enabled(enabled: bool) -> void:
	_enabled = enabled


## Get the current log file path
func get_log_path() -> String:
	return _current_log_path


## Force flush the log buffer
func flush() -> void:
	if _file:
		_file.flush()

# ─────────────────────────────────────────────────────────────────────────────
# INTERNAL
# ─────────────────────────────────────────────────────────────────────────────

func _log(category: Category, message: String) -> void:
	if not _enabled:
		return
	if not _category_filters.get(category, true):
		return

	var timestamp := _get_timestamp()
	var cat_name := CATEGORY_NAMES[category]
	var line := "[%s][F%06d][%s] %s\n" % [timestamp, _frame_count, cat_name, message]

	# Write to file
	if _file:
		_file.store_string(line)
		# Check if we need to rotate
		if _file.get_position() > MAX_LOG_SIZE_BYTES:
			_rotate_current_log()

	# Also print to console in debug builds
	if OS.is_debug_build():
		print(line.strip_edges())


func _ensure_log_dir() -> void:
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("logs"):
		dir.make_dir("logs")


func _rotate_logs() -> void:
	var dir := DirAccess.open(LOG_DIR)
	if dir == null:
		return

	# Get all log files sorted by modification time
	var log_files: Array[String] = []
	dir.list_dir_begin()
	var filename := dir.get_next()
	while filename != "":
		if filename.begins_with(LOG_PREFIX) and filename.ends_with(".log"):
			log_files.append(filename)
		filename = dir.get_next()
	dir.list_dir_end()

	# Sort by name (which includes timestamp, so oldest first)
	log_files.sort()

	# Delete oldest files if we have too many
	while log_files.size() >= MAX_LOG_FILES:
		var oldest := log_files.pop_front()
		var path := LOG_DIR + oldest
		dir.remove(path)
		print("DebugLogger: Removed old log %s" % oldest)


func _open_log_file() -> void:
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var filename := "%s%s_%s.log" % [LOG_PREFIX, timestamp, _session_id]
	_current_log_path = LOG_DIR + filename

	_file = FileAccess.open(_current_log_path, FileAccess.WRITE)
	if _file == null:
		push_error("DebugLogger: Failed to open log file: %s" % _current_log_path)


func _rotate_current_log() -> void:
	_write_footer()
	if _file:
		_file.close()
	_rotate_logs()
	_open_log_file()
	_write_header()


func _write_header() -> void:
	if _file == null:
		return
	var header := """
================================================================================
DEBUG LOG - Session: %s
Started: %s
Godot Version: %s
OS: %s
================================================================================

""" % [
		_session_id,
		Time.get_datetime_string_from_system(),
		Engine.get_version_info().string,
		OS.get_name(),
	]
	_file.store_string(header)


func _write_footer() -> void:
	if _file == null:
		return
	var footer := """
================================================================================
LOG ENDED - Frames: %d
Ended: %s
================================================================================
""" % [_frame_count, Time.get_datetime_string_from_system()]
	_file.store_string(footer)


func _get_timestamp() -> String:
	var time := Time.get_time_dict_from_system()
	var msec := Time.get_ticks_msec() % 1000
	return "%02d:%02d:%02d.%03d" % [time.hour, time.minute, time.second, msec]


func _generate_session_id() -> String:
	var chars := "abcdefghijklmnopqrstuvwxyz0123456789"
	var result := ""
	for i in range(6):
		result += chars[randi() % chars.length()]
	return result
