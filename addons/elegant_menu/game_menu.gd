extends CanvasLayer

signal menu_opened
signal menu_closed

@onready var menu_panel: PanelContainer = $MenuPanel
@onready var main_menu: VBoxContainer = $MenuPanel/MarginContainer/MainMenu
@onready var settings_menu: VBoxContainer = $MenuPanel/MarginContainer/SettingsMenu

@onready var keyboard_speed_slider: HSlider = $MenuPanel/MarginContainer/SettingsMenu/KeyboardSpeed/HSlider
@onready var keyboard_speed_value: Label = $MenuPanel/MarginContainer/SettingsMenu/KeyboardSpeed/Value
@onready var mouse_speed_slider: HSlider = $MenuPanel/MarginContainer/SettingsMenu/MouseSpeed/HSlider
@onready var mouse_speed_value: Label = $MenuPanel/MarginContainer/SettingsMenu/MouseSpeed/Value
@onready var edge_speed_slider: HSlider = $MenuPanel/MarginContainer/SettingsMenu/EdgeSpeed/HSlider
@onready var edge_speed_value: Label = $MenuPanel/MarginContainer/SettingsMenu/EdgeSpeed/Value

var settings: Node  # SettingsManager
var is_open := false


const SettingsManagerScript := preload("res://addons/elegant_menu/settings_manager.gd")

func _ready() -> void:
	settings = SettingsManagerScript.new()
	add_child(settings)

	menu_panel.visible = false
	_show_main_menu()
	_sync_sliders_to_settings()

	# Connect sliders
	keyboard_speed_slider.value_changed.connect(_on_keyboard_speed_changed)
	mouse_speed_slider.value_changed.connect(_on_mouse_speed_changed)
	edge_speed_slider.value_changed.connect(_on_edge_speed_changed)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_menu"):
		toggle_menu()
		get_viewport().set_input_as_handled()


func toggle_menu() -> void:
	if is_open:
		close_menu()
	else:
		open_menu()


func open_menu() -> void:
	is_open = true
	menu_panel.visible = true
	_show_main_menu()
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	menu_opened.emit()


func close_menu() -> void:
	is_open = false
	menu_panel.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CONFINED
	settings.save_settings()
	menu_closed.emit()


func _show_main_menu() -> void:
	main_menu.visible = true
	settings_menu.visible = false


func _show_settings_menu() -> void:
	main_menu.visible = false
	settings_menu.visible = true


func _sync_sliders_to_settings() -> void:
	keyboard_speed_slider.value = settings.keyboard_pan_speed
	mouse_speed_slider.value = settings.mouse_pan_speed
	edge_speed_slider.value = settings.edge_pan_speed
	_update_value_labels()


func _update_value_labels() -> void:
	keyboard_speed_value.text = "%d t/s" % int(keyboard_speed_slider.value)
	mouse_speed_value.text = "%d t/s" % int(mouse_speed_slider.value)
	edge_speed_value.text = "%d t/s" % int(edge_speed_slider.value)


func _on_keyboard_speed_changed(value: float) -> void:
	settings.keyboard_pan_speed = value
	_update_value_labels()


func _on_mouse_speed_changed(value: float) -> void:
	settings.mouse_pan_speed = value
	_update_value_labels()


func _on_edge_speed_changed(value: float) -> void:
	settings.edge_pan_speed = value
	_update_value_labels()


# Button callbacks
func _on_settings_pressed() -> void:
	_show_settings_menu()


func _on_resume_pressed() -> void:
	close_menu()


func _on_exit_pressed() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().quit()


func _on_back_pressed() -> void:
	_show_main_menu()


func _on_reset_pressed() -> void:
	settings.reset_to_defaults()
	_sync_sliders_to_settings()

