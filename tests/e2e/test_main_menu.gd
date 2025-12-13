## E2E tests for MainMenu button functionality
## Regression tests for menu button clicks working correctly
extends GutTest

const MainMenuScene := preload("res://ui/MainMenu.tscn")

var _main_menu: Control


func before_each() -> void:
	_main_menu = MainMenuScene.instantiate()
	add_child(_main_menu)
	await get_tree().process_frame
	await get_tree().process_frame


func after_each() -> void:
	if _main_menu and is_instance_valid(_main_menu):
		_main_menu.queue_free()
	_main_menu = null
	await get_tree().process_frame


func test_main_menu_loads() -> void:
	assert_not_null(_main_menu, "MainMenu should load")
	assert_true(_main_menu.visible, "MainMenu should be visible")


func test_singleplayer_button_exists_and_visible() -> void:
	var btn := _main_menu.get_node_or_null("CenterContainer/MenuPanel/MarginContainer/VBox/SingleplayerButton")
	assert_not_null(btn, "Singleplayer button should exist")
	assert_true(btn is Button, "Should be a Button")
	assert_true(btn.visible, "Button should be visible")


func test_multiplayer_button_exists_and_visible() -> void:
	var btn := _main_menu.get_node_or_null("CenterContainer/MenuPanel/MarginContainer/VBox/MultiplayerButton")
	assert_not_null(btn, "Multiplayer button should exist")
	assert_true(btn is Button, "Should be a Button")
	assert_true(btn.visible, "Button should be visible")


func test_buttons_have_valid_nonzero_rect() -> void:
	var sp_btn: Button = _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox/SingleplayerButton")
	var mp_btn: Button = _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox/MultiplayerButton")
	await get_tree().process_frame

	var sp_rect := sp_btn.get_global_rect()
	var mp_rect := mp_btn.get_global_rect()

	gut.p("Singleplayer button rect: %s" % sp_rect)
	gut.p("Multiplayer button rect: %s" % mp_rect)

	assert_true(sp_rect.size.x > 0, "Singleplayer button should have width > 0")
	assert_true(sp_rect.size.y > 0, "Singleplayer button should have height > 0")
	assert_true(mp_rect.size.x > 0, "Multiplayer button should have width > 0")
	assert_true(mp_rect.size.y > 0, "Multiplayer button should have height > 0")


func test_button_signals_are_connected() -> void:
	var sp_btn: Button = _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox/SingleplayerButton")
	var mp_btn: Button = _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox/MultiplayerButton")

	var sp_connections := sp_btn.pressed.get_connections()
	var mp_connections := mp_btn.pressed.get_connections()

	gut.p("Singleplayer button connections: %d" % sp_connections.size())
	gut.p("Multiplayer button connections: %d" % mp_connections.size())

	assert_gt(sp_connections.size(), 0, "Singleplayer button should have pressed signal connected")
	assert_gt(mp_connections.size(), 0, "Multiplayer button should have pressed signal connected")


func test_buttons_within_viewport() -> void:
	var sp_btn: Button = _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox/SingleplayerButton")
	await get_tree().process_frame

	var rect := sp_btn.get_global_rect()
	var vp_size := get_viewport().get_visible_rect().size

	gut.p("Button rect: %s, Viewport: %s" % [rect, vp_size])

	assert_true(rect.position.x >= 0, "Button x should be >= 0")
	assert_true(rect.position.y >= 0, "Button y should be >= 0")
	assert_true(rect.end.x <= vp_size.x, "Button should be within viewport width")
	assert_true(rect.end.y <= vp_size.y, "Button should be within viewport height")


func test_containers_have_mouse_filter_pass() -> void:
	# Regression test: containers should pass mouse events to allow children to receive them
	var center := _main_menu.get_node("CenterContainer")
	var panel := _main_menu.get_node("CenterContainer/MenuPanel")
	var margin := _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer")
	var vbox := _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox")

	assert_eq(center.mouse_filter, Control.MOUSE_FILTER_PASS, "CenterContainer should have MOUSE_FILTER_PASS")
	assert_eq(panel.mouse_filter, Control.MOUSE_FILTER_PASS, "MenuPanel should have MOUSE_FILTER_PASS")
	assert_eq(margin.mouse_filter, Control.MOUSE_FILTER_PASS, "MarginContainer should have MOUSE_FILTER_PASS")
	assert_eq(vbox.mouse_filter, Control.MOUSE_FILTER_PASS, "VBox should have MOUSE_FILTER_PASS")


func test_main_menu_root_has_mouse_filter_pass() -> void:
	# Regression test: root Control should pass mouse events
	assert_eq(_main_menu.mouse_filter, Control.MOUSE_FILTER_PASS, "MainMenu root should have MOUSE_FILTER_PASS")


func test_background_has_mouse_filter_ignore() -> void:
	var bg := _main_menu.get_node("Background")
	var hex := _main_menu.get_node("HexPattern")

	assert_eq(bg.mouse_filter, Control.MOUSE_FILTER_IGNORE, "Background should have MOUSE_FILTER_IGNORE")
	assert_eq(hex.mouse_filter, Control.MOUSE_FILTER_IGNORE, "HexPattern should have MOUSE_FILTER_IGNORE")


func test_buttons_have_default_mouse_filter() -> void:
	# Buttons should have default MOUSE_FILTER_STOP to receive events
	var sp_btn: Button = _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox/SingleplayerButton")
	var mp_btn: Button = _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox/MultiplayerButton")

	assert_eq(sp_btn.mouse_filter, Control.MOUSE_FILTER_STOP, "Singleplayer button should have MOUSE_FILTER_STOP")
	assert_eq(mp_btn.mouse_filter, Control.MOUSE_FILTER_STOP, "Multiplayer button should have MOUSE_FILTER_STOP")


func test_button_pressed_signal_fires_handler() -> void:
	# Verify the signal is connected and GameBus receives the params
	# NOTE: We can't fully test button press because it triggers scene change
	# which causes errors in test environment (no NetworkManager, etc.)
	var sp_btn: Button = _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox/SingleplayerButton")

	var game_bus := get_node_or_null("/root/GameBus")
	assert_not_null(game_bus, "GameBus autoload should exist")

	# Verify button has connected signal
	assert_gt(sp_btn.pressed.get_connections().size(), 0,
		"Singleplayer button should have pressed signal connected")

	# Verify GameBus.start_game works directly (bypassing scene change)
	game_bus.last_params = {}
	game_bus.start_game({"mode": "singleplayer"})
	assert_eq(game_bus.last_params.get("mode"), "singleplayer",
		"GameBus.start_game should set last_params")


func test_button_is_not_disabled() -> void:
	var sp_btn: Button = _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox/SingleplayerButton")
	var mp_btn: Button = _main_menu.get_node("CenterContainer/MenuPanel/MarginContainer/VBox/MultiplayerButton")

	assert_false(sp_btn.disabled, "Singleplayer button should not be disabled")
	assert_false(mp_btn.disabled, "Multiplayer button should not be disabled")
