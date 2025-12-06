extends Node
class_name SettingsManager

const SETTINGS_PATH := "user://settings.cfg"

signal settings_changed

var config := ConfigFile.new()

# Camera settings with defaults
var keyboard_pan_speed: float = 800.0:
	set(v):
		keyboard_pan_speed = v
		settings_changed.emit()

var mouse_pan_speed: float = 1.0:
	set(v):
		mouse_pan_speed = v
		settings_changed.emit()

var edge_pan_speed: float = 600.0:
	set(v):
		edge_pan_speed = v
		settings_changed.emit()

var edge_pan_margin: float = 20.0:
	set(v):
		edge_pan_margin = v
		settings_changed.emit()


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	if config.load(SETTINGS_PATH) != OK:
		return

	keyboard_pan_speed = config.get_value("camera", "keyboard_pan_speed", 800.0)
	mouse_pan_speed = config.get_value("camera", "mouse_pan_speed", 1.0)
	edge_pan_speed = config.get_value("camera", "edge_pan_speed", 600.0)
	edge_pan_margin = config.get_value("camera", "edge_pan_margin", 20.0)


func save_settings() -> void:
	config.set_value("camera", "keyboard_pan_speed", keyboard_pan_speed)
	config.set_value("camera", "mouse_pan_speed", mouse_pan_speed)
	config.set_value("camera", "edge_pan_speed", edge_pan_speed)
	config.set_value("camera", "edge_pan_margin", edge_pan_margin)
	config.save(SETTINGS_PATH)


func reset_to_defaults() -> void:
	keyboard_pan_speed = 800.0
	mouse_pan_speed = 1.0
	edge_pan_speed = 600.0
	edge_pan_margin = 20.0
	save_settings()


