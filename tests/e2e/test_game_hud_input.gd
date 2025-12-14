## E2E regression tests for GameHud input routing and build workflow.
extends GutTest

const GameHudScene := preload("res://ui/GameHud.tscn")

class MockGameManager:
	extends Node
	signal phase_changed
	signal hand_updated
	signal nominations_updated
	signal commits_updated
	signal scores_updated
	signal visibility_updated
	signal player_count_changed
	signal placement_resolved

	var phase := 3 # PLACE phase
	var local_role := 0 # Mayor
	var revealed_indices := [0, 1] # Mayor reveals 2 cards
	var hand := [{"rank": "A", "suit": 0}, {"rank": "K", "suit": 1}]
	var nominations := [] # Required by _refresh_all
	var scores := {"mayor": 0, "industry": 0, "urbanist": 0} # Required by _refresh_all
	var advisor_visibility := [] # Required by _refresh_all

	var placed_card: Variant = null
	var placed_hex: Variant = null

	func place_card(card_idx: int, cube: Vector3i) -> void:
		placed_card = card_idx
		placed_hex = cube


class MockHexField:
	extends Node
	var external_clicks := 0
	func handle_external_click() -> void:
		external_clicks += 1


var _root: Node
var _hud: Control
var _gm: MockGameManager
var _hex: MockHexField


func before_each() -> void:
	_root = Node.new()
	add_child(_root)

	_gm = MockGameManager.new()
	_gm.name = "GameManager"
	_root.add_child(_gm)

	_hex = MockHexField.new()
	_hex.name = "HexField"
	_root.add_child(_hex)

	_hud = GameHudScene.instantiate()
	_hud.name = "GameHud"
	_hud.set("game_manager_path", NodePath("../GameManager"))
	_hud.set("hex_field_path", NodePath("../HexField"))
	_root.add_child(_hud)

	# Allow layout and onready to run
	await get_tree().process_frame
	await get_tree().process_frame


func after_each() -> void:
	if _root:
		_root.queue_free()
	_root = null
	_hud = null
	_gm = null
	_hex = null
	await get_tree().process_frame


func _make_click(pos: Vector2, pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	return ev


func test_click_outside_ui_routes_to_hex_field() -> void:
	# Click well away from top panel and bottom tray
	var down := _make_click(Vector2(50, 500), true)
	var up := _make_click(Vector2(50, 500), false)

	_hud._input(down)
	_hud._input(up)

	assert_eq(_hex.external_clicks, 1, "HexField.handle_external_click should be called once")


func test_build_button_calls_place_card_when_card_and_hex_selected() -> void:
	# Pre-select card and hex
	_hud.set("_selected_card_index", 0)
	_hud.set("_selected_hex", Vector3i(1, -1, 0))
	await get_tree().process_frame

	# Directly trigger build action via the internal method (pixel coords are fragile)
	# This tests the actual logic path without depending on exact UI layout
	_hud.call("_on_build_pressed")
	await get_tree().process_frame

	assert_eq(_gm.placed_card, 0, "place_card should be invoked with selected card")
	assert_eq(_gm.placed_hex, Vector3i(1, -1, 0), "place_card should receive selected hex")
