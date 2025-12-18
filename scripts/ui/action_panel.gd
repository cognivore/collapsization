## Shared action panel helper to keep mayor/advisor flows consistent.
extends RefCounted
class_name ActionPanel

const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)

## Phase constants (must match GameManager.Phase)
const PHASE_DRAW := 1
const PHASE_CONTROL := 2
const PHASE_NOMINATE := 3
const PHASE_PLACE := 4

## Compute which buttons should be visible/enabled for the given context.
## Returns a dictionary with reveal/commit/build visibility and disabled flags.
func compute_state(role: int, phase: int, selected_card: int, selected_hex: Vector3i, revealed_indices: Array) -> Dictionary:
	var show_reveal := role == 0 and phase == PHASE_DRAW
	var show_build := role == 0 and phase == PHASE_PLACE
	var show_commit := role != 0 and phase == PHASE_NOMINATE and selected_hex != INVALID_HEX
	# Mayor must reveal 2 cards before nominations start
	var can_reveal := selected_card >= 0 and revealed_indices.size() < 2 and selected_card not in revealed_indices

	return {
		"show_reveal": show_reveal,
		"show_build": show_build,
		"show_commit": show_commit,
		"reveal_disabled": not can_reveal,
		"build_disabled": not (selected_card >= 0 and selected_hex != INVALID_HEX),
		"commit_disabled": not show_commit,
		"show_action_card": role == 0 and phase in [PHASE_DRAW, PHASE_PLACE],
		"action_reveal": phase == PHASE_DRAW,
		"action_build": phase == PHASE_PLACE,
	}


## Apply the computed state to a button map.
## Expected keys: reveal, build, commit, action_card, action_reveal, action_build, action_cancel.
func apply_state(buttons: Dictionary, state: Dictionary) -> void:
	if buttons.has("reveal"):
		buttons["reveal"].visible = state.get("show_reveal", false)
		buttons["reveal"].disabled = state.get("reveal_disabled", true)

	if buttons.has("commit"):
		buttons["commit"].visible = state.get("show_commit", false)
		buttons["commit"].disabled = state.get("commit_disabled", true)

	if buttons.has("build"):
		buttons["build"].visible = state.get("show_build", false)
		buttons["build"].disabled = state.get("build_disabled", true)

	if buttons.has("action_card"):
		buttons["action_card"].visible = state.get("show_action_card", false)

	if buttons.has("action_reveal"):
		buttons["action_reveal"].visible = state.get("action_reveal", false)
		buttons["action_reveal"].disabled = state.get("reveal_disabled", true)

	if buttons.has("action_build"):
		buttons["action_build"].visible = state.get("action_build", false)
		buttons["action_build"].disabled = state.get("build_disabled", true)

	if buttons.has("action_cancel"):
		buttons["action_cancel"].visible = state.get("show_action_card", false)


## Create a styled card button with hover glow.
func create_card_button(
	card: Dictionary,
	index: int,
	selected_index: int,
	revealed_indices: Array,
	suit_colors: Dictionary,
	hover_shader: Shader,
	pressed_cb: Callable,
	gui_input_cb: Callable
) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(90, 120)
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.focus_mode = Control.FOCUS_CLICK
	btn.flat = false
	btn.disabled = false

	var suit: int = card.get("suit", 0)
	var rank: String = card.get("rank", "?")
	var suit_symbol := "?"
	match suit:
		0: suit_symbol = "♥"
		1: suit_symbol = "♦"
		2: suit_symbol = "♠"

	btn.text = "%s\n%s" % [rank, suit_symbol]
	btn.set_meta("card_index", index)
	btn.pressed.connect(pressed_cb.bind(index))
	btn.gui_input.connect(gui_input_cb.bind(index))

	var suit_color: Color = suit_colors.get(suit, Color.WHITE)

	var base := StyleBoxFlat.new()
	base.bg_color = Color(0.95, 0.93, 0.88)
	base.corner_radius_top_left = 8
	base.corner_radius_top_right = 8
	base.corner_radius_bottom_left = 8
	base.corner_radius_bottom_right = 8
	base.border_width_left = 3
	base.border_width_right = 3
	base.border_width_top = 3
	base.border_width_bottom = 3
	base.border_color = suit_color

	var hover_style := base.duplicate()
	hover_style.bg_color = Color(1.0, 1.0, 0.98)
	hover_style.border_width_left = 5
	hover_style.border_width_right = 5
	hover_style.border_width_top = 5
	hover_style.border_width_bottom = 5
	hover_style.border_color = Color.WHITE
	hover_style.shadow_color = Color(1.0, 1.0, 1.0, 0.8)
	hover_style.shadow_size = 12
	hover_style.shadow_offset = Vector2.ZERO

	var pressed_style := base.duplicate()
	pressed_style.bg_color = Color(0.85, 0.9, 0.85)

	btn.add_theme_stylebox_override("normal", base)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", pressed_style)
	btn.add_theme_color_override("font_color", suit_color)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", suit_color)
	btn.add_theme_font_size_override("font_size", 24)

	_add_hover_glow(btn, hover_shader)

	if index == selected_index:
		var selected := base.duplicate()
		selected.bg_color = Color(0.9, 1.0, 0.9)
		selected.border_width_left = 5
		selected.border_width_right = 5
		selected.border_width_top = 5
		selected.border_width_bottom = 5
		selected.border_color = Color.WHITE
		selected.shadow_color = Color(1.0, 1.0, 1.0, 0.9)
		selected.shadow_size = 16
		btn.add_theme_stylebox_override("normal", selected)
		btn.add_theme_stylebox_override("hover", selected)

	if index in revealed_indices:
		var revealed := base.duplicate()
		revealed.bg_color = Color(1.0, 0.95, 0.7)
		btn.add_theme_stylebox_override("normal", revealed)
		btn.text = "%s\n%s\n✓" % [rank, suit_symbol]

	return btn


func _add_hover_glow(btn: Button, hover_shader: Shader) -> void:
	var glow := ColorRect.new()
	glow.name = "HoverGlow"
	glow.color = Color(1.0, 1.0, 1.0, 0.0)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow.z_index = -1

	var mat := ShaderMaterial.new()
	mat.shader = hover_shader
	mat.set_shader_parameter("enabled", false)
	mat.set_shader_parameter("intensity", 1.0)
	mat.set_shader_parameter("pulse_speed", 4.0)
	mat.set_shader_parameter("glow_color", Color(1.0, 1.0, 1.0, 1.0))
	glow.material = mat

	btn.add_child(glow)

	btn.mouse_entered.connect(func():
		mat.set_shader_parameter("enabled", true)
		glow.color = Color(1.0, 1.0, 1.0, 0.15)
		var tween := btn.create_tween()
		tween.tween_property(glow, "color:a", 0.25, 0.15)
	)

	btn.mouse_exited.connect(func():
		var tween := btn.create_tween()
		tween.tween_property(glow, "color:a", 0.0, 0.15)
		tween.tween_callback(func(): mat.set_shader_parameter("enabled", false))
	)
