## Logging system for network events with timestamped, rotated log files.
## Logs are written to user://logs/ directory.
extends Node

const MAX_LOG_SIZE := 1024 * 1024 # 1MB per log file
const MAX_LOG_FILES := 5 # Keep last 5 log files

var _log_file: FileAccess
var _log_path: String
var _instance_type: String = "unknown"
var _current_log_size := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_logging.call_deferred()


func _setup_logging() -> void:
	# Determine instance type
	if has_node("/root/DemoLauncher"):
		var launcher := get_node("/root/DemoLauncher")
		match launcher.role:
			1: # SERVER
				_instance_type = "server"
			2: # CLIENT
				_instance_type = "client_%d" % launcher.client_index

	# Create logs directory
	var logs_dir := "user://logs"
	if not DirAccess.dir_exists_absolute(logs_dir):
		DirAccess.make_dir_absolute(logs_dir)

	# Rotate logs before opening new one
	_rotate_logs()

	# Open new log file
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	_log_path = "%s/%s_%s.log" % [logs_dir, _instance_type, timestamp]
	_log_file = FileAccess.open(_log_path, FileAccess.WRITE)

	if _log_file:
		log_info("=== Log started for %s ===" % _instance_type)
		log_info("Godot %s" % Engine.get_version_info().string)


func _rotate_logs() -> void:
	var logs_dir := "user://logs"
	var dir := DirAccess.open(logs_dir)
	if dir == null:
		return

	# Find all logs for this instance type
	var log_files: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.begins_with(_instance_type) and file_name.ends_with(".log"):
			log_files.append(logs_dir + "/" + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

	# Sort by modification time (oldest first)
	log_files.sort()

	# Remove oldest files if we have too many
	while log_files.size() >= MAX_LOG_FILES:
		var old_file: String = log_files.pop_front()
		DirAccess.remove_absolute(old_file)


func _exit_tree() -> void:
	if _log_file:
		log_info("=== Log ended ===")
		_log_file.close()


func _get_timestamp() -> String:
	var time := Time.get_time_dict_from_system()
	var msec := Time.get_ticks_msec() % 1000
	return "%02d:%02d:%02d.%03d" % [time.hour, time.minute, time.second, msec]


func _write_log(level: String, message: String) -> void:
	if _log_file == null:
		return

	var line := "[%s] [%s] %s\n" % [_get_timestamp(), level, message]
	_log_file.store_string(line)
	_log_file.flush()

	_current_log_size += line.length()

	# Check if we need to rotate
	if _current_log_size > MAX_LOG_SIZE:
		_log_file.close()
		_rotate_logs()
		var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
		_log_path = "user://logs/%s_%s.log" % [_instance_type, timestamp]
		_log_file = FileAccess.open(_log_path, FileAccess.WRITE)
		_current_log_size = 0


## Log info level message
func log_info(message: String) -> void:
	_write_log("INFO", message)


## Log debug level message
func log_debug(message: String) -> void:
	_write_log("DEBUG", message)


## Log warning level message
func log_warn(message: String) -> void:
	_write_log("WARN", message)


## Log error level message
func log_error(message: String) -> void:
	_write_log("ERROR", message)


## Log cursor update event
func log_cursor_update(player_id: int, hex: Vector3i, is_local: bool) -> void:
	var source := "local" if is_local else "remote"
	log_debug("CURSOR [%s] player=%d hex=(%d,%d,%d)" % [source, player_id, hex.x, hex.y, hex.z])


## Log player connection event
func log_player_joined(player_id: int) -> void:
	log_info("PLAYER_JOINED id=%d" % player_id)


## Log player disconnection event
func log_player_left(player_id: int) -> void:
	log_info("PLAYER_LEFT id=%d" % player_id)


## Log network message
func log_network_message(from_id: int, msg_type: int, data: Dictionary) -> void:
	log_debug("NET_MSG from=%d type=%d data=%s" % [from_id, msg_type, str(data)])
