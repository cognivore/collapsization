extends CanvasLayer

signal menu_opened
signal menu_closed

const PlayerStateScript := preload("res://addons/netcode/player_state.gd")

@onready var menu_panel: PanelContainer = $MenuPanel
@onready var main_menu: VBoxContainer = $MenuPanel/MarginContainer/MainMenu
@onready var settings_menu: VBoxContainer = $MenuPanel/MarginContainer/SettingsMenu

@onready var color_option: OptionButton = $MenuPanel/MarginContainer/SettingsMenu/PlayerColor/ColorOption
@onready var color_preview: ColorRect = $MenuPanel/MarginContainer/SettingsMenu/PlayerColor/ColorPreview

@onready var keyboard_speed_slider: HSlider = $MenuPanel/MarginContainer/SettingsMenu/KeyboardSpeed/HSlider
@onready var keyboard_speed_value: Label = $MenuPanel/MarginContainer/SettingsMenu/KeyboardSpeed/Value
@onready var mouse_speed_slider: HSlider = $MenuPanel/MarginContainer/SettingsMenu/MouseSpeed/HSlider
@onready var mouse_speed_value: Label = $MenuPanel/MarginContainer/SettingsMenu/MouseSpeed/Value
@onready var edge_speed_slider: HSlider = $MenuPanel/MarginContainer/SettingsMenu/EdgeSpeed/HSlider
@onready var edge_speed_value: Label = $MenuPanel/MarginContainer/SettingsMenu/EdgeSpeed/Value

var settings: Node # SettingsManager
var is_open := false


const SettingsManagerScript := preload("res://addons/elegant_menu/settings_manager.gd")

func _ready() -> void:
	settings = SettingsManagerScript.new()
	add_child(settings)

	menu_panel.visible = false
	_show_main_menu()
	_sync_sliders_to_settings()
	_sync_color_to_settings()

	# Connect sliders
	keyboard_speed_slider.value_changed.connect(_on_keyboard_speed_changed)
	mouse_speed_slider.value_changed.connect(_on_mouse_speed_changed)
	edge_speed_slider.value_changed.connect(_on_edge_speed_changed)


func _get_network_manager() -> Node:
	if has_node("/root/NetworkManager"):
		return get_node("/root/NetworkManager")
	return null


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
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE # Keep mouse visible
	settings.save_settings()
	menu_closed.emit()


func _show_main_menu() -> void:
	main_menu.visible = true
	settings_menu.visible = false


func _show_settings_menu() -> void:
	main_menu.visible = false
	settings_menu.visible = true
	_sync_color_to_settings()


func _sync_sliders_to_settings() -> void:
	keyboard_speed_slider.value = settings.keyboard_pan_speed
	mouse_speed_slider.value = settings.mouse_pan_speed
	edge_speed_slider.value = settings.edge_pan_speed
	_update_value_labels()


func _sync_color_to_settings() -> void:
	var color_index: int = settings.player_color_index
	color_option.selected = color_index
	_update_color_preview(color_index)


func _update_value_labels() -> void:
	keyboard_speed_value.text = "%d t/s" % int(keyboard_speed_slider.value)
	mouse_speed_value.text = "%d t/s" % int(mouse_speed_slider.value)
	edge_speed_value.text = "%d t/s" % int(edge_speed_slider.value)


func _update_color_preview(index: int) -> void:
	if color_preview:
		color_preview.color = PlayerStateScript.PLAYER_COLORS[index % PlayerStateScript.PLAYER_COLORS.size()]


func _on_keyboard_speed_changed(value: float) -> void:
	settings.keyboard_pan_speed = value
	_update_value_labels()


func _on_mouse_speed_changed(value: float) -> void:
	settings.mouse_pan_speed = value
	_update_value_labels()


func _on_edge_speed_changed(value: float) -> void:
	settings.edge_pan_speed = value
	_update_value_labels()


func _on_color_selected(index: int) -> void:
	settings.player_color_index = index
	_update_color_preview(index)

	# Update local player color if networked
	var net_mgr := _get_network_manager()
	if net_mgr and net_mgr.local_player:
		net_mgr.local_player.set_color_index(index)
		# Broadcast color change
		net_mgr.broadcast_message(
			net_mgr.MessageType.PLAYER_STATE,
			net_mgr.local_player.to_dict(),
			true
		)

	# Find hex field and update color
	var hex_field := _find_hex_field()
	if hex_field:
		hex_field.set_local_color_index(index)


func _find_hex_field() -> Node:
	var root := get_tree().root
	return _find_node_by_script(root, "hex_field.gd")


func _find_node_by_script(node: Node, script_name: String) -> Node:
	if node.get_script() and node.get_script().resource_path.ends_with(script_name):
		return node
	for child in node.get_children():
		var result := _find_node_by_script(child, script_name)
		if result:
			return result
	return null


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
	_sync_color_to_settings()
