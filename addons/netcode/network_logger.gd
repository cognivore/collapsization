## Thin wrapper for backwards compatibility.
## Delegates all logging to the unified Logger system.
##
## NOTE: This is no longer an autoload. Use Log.net() directly instead.
extends Node

## Log info level message
func log_info(message: String) -> void:
	Log.net(message)


## Log debug level message
func log_debug(message: String) -> void:
	Log.net(message)


## Log warning level message
func log_warn(message: String) -> void:
	Log.net("WARN: %s" % message)


## Log error level message
func log_error(message: String) -> void:
	Log.net("ERROR: %s" % message)


## Log cursor update event
func log_cursor_update(player_id: int, hex: Vector3i, is_local: bool) -> void:
	var source := "local" if is_local else "remote"
	Log.net("CURSOR [%s] player=%d hex=(%d,%d,%d)" % [source, player_id, hex.x, hex.y, hex.z])


## Log player connection event
func log_player_joined(player_id: int) -> void:
	Log.net("PLAYER_JOINED id=%d" % player_id)


## Log player disconnection event
func log_player_left(player_id: int) -> void:
	Log.net("PLAYER_LEFT id=%d" % player_id)


## Log network message
func log_network_message(from_id: int, msg_type: int, data: Dictionary) -> void:
	Log.net("NET_MSG from=%d type=%d data=%s" % [from_id, msg_type, str(data)])
