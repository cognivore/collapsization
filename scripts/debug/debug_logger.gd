## Simple debug logger with global toggle.
## Usage: DebugLogger.log("message")
##
## For more advanced logging with categories, use the Log autoload directly:
##   Log.dbg("message")
##   Log.game("message")
##   etc.
extends RefCounted
class_name DebugLogger

## Global toggle - can be enabled via F3 in game_hud or code
static var enabled: bool = false


## Log a debug message (only prints if enabled)
static func log(msg: String) -> void:
	if enabled:
		print("[DEBUG] %s" % msg)


## Log a warning (only prints if enabled)
static func warn(msg: String) -> void:
	if enabled:
		push_warning("[DEBUG] %s" % msg)
