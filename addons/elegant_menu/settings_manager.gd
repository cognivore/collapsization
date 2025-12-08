extends Node
class_name SettingsManager

const SETTINGS_PATH := "user://settings.cfg"
const TILE_WIDTH := 164.0 # pixels per tile

signal settings_changed

var config := ConfigFile.new()

# Camera settings in tiles/sec (converted to pixels in camera)
var keyboard_pan_speed: float = 40.0: # tiles/sec
	set(v):
		keyboard_pan_speed = v
		settings_changed.emit()

var mouse_pan_speed: float = 40.0: # tiles/sec for drag
	set(v):
		mouse_pan_speed = v
		settings_changed.emit()

var edge_pan_speed: float = 40.0: # tiles/sec
	set(v):
		edge_pan_speed = v
		settings_changed.emit()

var edge_pan_margin: float = 20.0:
	set(v):
		edge_pan_margin = v
		settings_changed.emit()

# Player appearance
var player_color_index: int = 0:
	set(v):
		player_color_index = v % 8
		settings_changed.emit()


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	if config.load(SETTINGS_PATH) != OK:
		return

	keyboard_pan_speed = config.get_value("camera", "keyboard_pan_speed", 40.0)
	mouse_pan_speed = config.get_value("camera", "mouse_pan_speed", 40.0)
	edge_pan_speed = config.get_value("camera", "edge_pan_speed", 40.0)
	edge_pan_margin = config.get_value("camera", "edge_pan_margin", 20.0)
	player_color_index = config.get_value("player", "color_index", 0)


func save_settings() -> void:
	config.set_value("camera", "keyboard_pan_speed", keyboard_pan_speed)
	config.set_value("camera", "mouse_pan_speed", mouse_pan_speed)
	config.set_value("camera", "edge_pan_speed", edge_pan_speed)
	config.set_value("camera", "edge_pan_margin", edge_pan_margin)
	config.set_value("player", "color_index", player_color_index)
	config.save(SETTINGS_PATH)


func reset_to_defaults() -> void:
	keyboard_pan_speed = 40.0
	mouse_pan_speed = 40.0
	edge_pan_speed = 40.0
	edge_pan_margin = 20.0
	player_color_index = 0
	save_settings()
