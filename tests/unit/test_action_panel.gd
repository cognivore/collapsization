## Unit tests for ActionPanel.compute_state() button visibility logic.
extends GutTest

const ActionPanel := preload("res://scripts/ui/action_panel.gd")

const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)
const VALID_HEX := Vector3i(1, -1, 0)

# Phase constants (matching GameManager)
const LOBBY := 0
const DRAW := 1
const NOMINATE := 2
const PLACE := 3
const GAME_OVER := 4

# Role constants
const MAYOR := 0
const INDUSTRY := 1
const URBANIST := 2

var _panel: ActionPanel


func before_each() -> void:
	_panel = ActionPanel.new()


func after_each() -> void:
	_panel = null


## Test: Mayor in DRAW phase sees REVEAL button
func test_mayor_draw_phase_shows_reveal() -> void:
	var state := _panel.compute_state(MAYOR, DRAW, -1, INVALID_HEX, -1)
	assert_true(state.show_reveal, "Mayor sees REVEAL in DRAW")
	assert_false(state.show_build, "Mayor does NOT see BUILD in DRAW")
	assert_false(state.show_commit, "Mayor does NOT see COMMIT")


## Test: Mayor in DRAW with card selected - REVEAL enabled
func test_mayor_draw_reveal_enabled_with_card() -> void:
	var state := _panel.compute_state(MAYOR, DRAW, 0, INVALID_HEX, -1)
	assert_false(state.reveal_disabled, "REVEAL enabled when card selected")


## Test: Mayor in DRAW without card selected - REVEAL disabled
func test_mayor_draw_reveal_disabled_without_card() -> void:
	var state := _panel.compute_state(MAYOR, DRAW, -1, INVALID_HEX, -1)
	assert_true(state.reveal_disabled, "REVEAL disabled when no card selected")


## Test: Mayor in DRAW after reveal - REVEAL disabled
func test_mayor_draw_reveal_disabled_after_reveal() -> void:
	var state := _panel.compute_state(MAYOR, DRAW, 0, INVALID_HEX, 0)
	assert_true(state.reveal_disabled, "REVEAL disabled after card already revealed")


## Test: Mayor in PLACE phase sees BUILD button
func test_mayor_place_phase_shows_build() -> void:
	var state := _panel.compute_state(MAYOR, PLACE, 0, VALID_HEX, 0)
	assert_true(state.show_build, "Mayor sees BUILD in PLACE")
	assert_false(state.show_reveal, "Mayor does NOT see REVEAL in PLACE")


## Test: Mayor in PLACE with card and hex selected - BUILD enabled
func test_mayor_place_build_enabled_with_selection() -> void:
	var state := _panel.compute_state(MAYOR, PLACE, 0, VALID_HEX, 0)
	assert_false(state.build_disabled, "BUILD enabled with card and hex")


## Test: Mayor in PLACE without hex - BUILD disabled
func test_mayor_place_build_disabled_without_hex() -> void:
	var state := _panel.compute_state(MAYOR, PLACE, 0, INVALID_HEX, 0)
	assert_true(state.build_disabled, "BUILD disabled without hex selection")


## Test: Mayor in PLACE without card - BUILD disabled
func test_mayor_place_build_disabled_without_card() -> void:
	var state := _panel.compute_state(MAYOR, PLACE, -1, VALID_HEX, 0)
	assert_true(state.build_disabled, "BUILD disabled without card selection")


## Test: Advisor in NOMINATE phase with hex sees COMMIT button
func test_advisor_nominate_shows_commit() -> void:
	var state := _panel.compute_state(INDUSTRY, NOMINATE, 0, VALID_HEX, 0)
	assert_true(state.show_commit, "Advisor sees COMMIT in NOMINATE with hex")
	assert_false(state.show_reveal, "Advisor does NOT see REVEAL")
	assert_false(state.show_build, "Advisor does NOT see BUILD")


## Test: Advisor in NOMINATE without hex - COMMIT hidden
func test_advisor_nominate_no_commit_without_hex() -> void:
	var state := _panel.compute_state(URBANIST, NOMINATE, 0, INVALID_HEX, 0)
	assert_false(state.show_commit, "COMMIT hidden without hex selection")


## Test: Advisor in DRAW phase - all buttons hidden
func test_advisor_draw_all_hidden() -> void:
	var state := _panel.compute_state(INDUSTRY, DRAW, 0, VALID_HEX, 0)
	assert_false(state.show_reveal, "Advisor no REVEAL in DRAW")
	assert_false(state.show_build, "Advisor no BUILD in DRAW")
	assert_false(state.show_commit, "Advisor no COMMIT in DRAW")


## Test: Advisor in PLACE phase - all buttons hidden
func test_advisor_place_all_hidden() -> void:
	var state := _panel.compute_state(URBANIST, PLACE, 0, VALID_HEX, 0)
	assert_false(state.show_reveal, "Advisor no REVEAL in PLACE")
	assert_false(state.show_build, "Advisor no BUILD in PLACE")
	assert_false(state.show_commit, "Advisor no COMMIT in PLACE")


## Test: Action card panel visibility - Mayor in DRAW/PLACE
func test_action_card_visibility_mayor() -> void:
	var draw_state := _panel.compute_state(MAYOR, DRAW, 0, INVALID_HEX, -1)
	assert_true(draw_state.show_action_card, "Action card shown for Mayor in DRAW")

	var place_state := _panel.compute_state(MAYOR, PLACE, 0, VALID_HEX, 0)
	assert_true(place_state.show_action_card, "Action card shown for Mayor in PLACE")


## Test: Action card hidden for advisors
func test_action_card_hidden_for_advisors() -> void:
	var state := _panel.compute_state(INDUSTRY, NOMINATE, 0, VALID_HEX, 0)
	assert_false(state.show_action_card, "Action card hidden for advisors")


