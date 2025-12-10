## Centralized debug logging with global toggle.
## Usage: DebugLogger.log("message") - only prints if enabled.
extends RefCounted
class_name DebugLogger

## Global toggle - set via F3 in game_hud or project settings
static var enabled: bool = false


static func log(msg: String) -> void:
	if enabled:
		print(msg)


static func warn(msg: String) -> void:
	if enabled:
		push_warning(msg)

