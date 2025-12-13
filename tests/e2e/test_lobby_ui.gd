## E2E regression tests for Lobby UI wiring (signals, focus, layout).
extends GutTest

const LobbyScene := preload("res://ui/LobbyScene.tscn")

var _lobby: Control


func before_each() -> void:
	_lobby = LobbyScene.instantiate()
	add_child(_lobby)
	# Allow onready + layout to settle
	await get_tree().process_frame
	await get_tree().process_frame


func after_each() -> void:
	if _lobby and is_instance_valid(_lobby):
		_lobby.queue_free()
	_lobby = null
	await get_tree().process_frame


func test_connect_panel_buttons_exist() -> void:
	var connect_btn: Button = _lobby.get_node("ConnectPanel/VBox/ConnectButton")
	var status: Label = _lobby.get_node("ConnectPanel/VBox/Status")
	assert_not_null(connect_btn, "Connect button should exist")
	assert_true(connect_btn.visible, "Connect button should be visible")
	assert_not_null(status, "Status label should exist")


func test_connect_button_signal_connected() -> void:
	var connect_btn: Button = _lobby.get_node("ConnectPanel/VBox/ConnectButton")
	assert_gt(connect_btn.pressed.get_connections().size(), 0, "Connect pressed signal should be connected")


func test_line_edits_focus_mode_all() -> void:
	var name_input: LineEdit = _lobby.get_node("ConnectPanel/VBox/NameRow/NameInput")
	var addr_input: LineEdit = _lobby.get_node("ConnectPanel/VBox/AddressRow/AddressInput")
	var port_input: LineEdit = _lobby.get_node("ConnectPanel/VBox/PortRow/PortInput")
	assert_eq(name_input.focus_mode, Control.FOCUS_ALL, "Name input focus mode")
	assert_eq(addr_input.focus_mode, Control.FOCUS_ALL, "Address input focus mode")
	assert_eq(port_input.focus_mode, Control.FOCUS_ALL, "Port input focus mode")


func test_room_buttons_exist_and_connected() -> void:
	var create_btn: Button = _lobby.get_node("LobbyPanel/VBox/ButtonRow/CreateRoomButton")
	var refresh_btn: Button = _lobby.get_node("LobbyPanel/VBox/ButtonRow/RefreshButton")
	var disconnect_btn: Button = _lobby.get_node("LobbyPanel/VBox/ButtonRow/DisconnectButton")
	assert_not_null(create_btn, "Create Room button exists")
	assert_not_null(refresh_btn, "Refresh button exists")
	assert_not_null(disconnect_btn, "Disconnect button exists")
	assert_gt(create_btn.pressed.get_connections().size(), 0, "CreateRoom signal connected")
	assert_gt(refresh_btn.pressed.get_connections().size(), 0, "Refresh signal connected")
	assert_gt(disconnect_btn.pressed.get_connections().size(), 0, "Disconnect signal connected")


func test_room_panel_buttons_exist_and_connected() -> void:
	var add_bot_btn: Button = _lobby.get_node("RoomPanel/VBox/ButtonRow/AddBotButton")
	var start_btn: Button = _lobby.get_node("RoomPanel/VBox/ButtonRow/StartGameButton")
	var leave_btn: Button = _lobby.get_node("RoomPanel/VBox/ButtonRow/LeaveRoomButton")
	assert_not_null(add_bot_btn, "Add Bot button exists")
	assert_not_null(start_btn, "Start Game button exists")
	assert_not_null(leave_btn, "Leave Room button exists")
	assert_gt(add_bot_btn.pressed.get_connections().size(), 0, "AddBot signal connected")
	assert_gt(start_btn.pressed.get_connections().size(), 0, "StartGame signal connected")
	assert_gt(leave_btn.pressed.get_connections().size(), 0, "LeaveRoom signal connected")

