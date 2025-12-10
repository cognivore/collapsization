## Game HUD - displays phase-specific UI for Mayor and Advisors.
extends CanvasLayer

const MapLayers := preload("res://scripts/map_layers.gd")
const GameRules := preload("res://scripts/game_rules.gd")
const ActionPanel := preload("res://scripts/ui/action_panel.gd")
const DebugHUD := preload("res://scripts/debug/debug_hud.gd")
const DebugLogger := preload("res://scripts/debug/debug_logger.gd")

# Hover shader for buttons
var _button_hover_shader: Shader = preload("res://shaders/button_hover.gdshader")

const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)

# Card colors by suit
const SUIT_COLORS := {
	0: Color(0.9, 0.2, 0.3), # HEARTS - red
	1: Color(0.95, 0.7, 0.2), # DIAMONDS - gold
	2: Color(0.3, 0.35, 0.45), # SPADES - dark grey
}

# Phase names for display
const PHASE_NAMES := ["LOBBY", "DRAW", "NOMINATE", "PLACE", "GAME OVER"]
const ROLE_NAMES := ["Mayor", "Industry Advisor", "Urbanist"]

@export var game_manager_path: NodePath = NodePath("../GameManager")
@export var hex_field_path: NodePath = NodePath("../HexField")
@export var debug_logging: bool = false

var _gm: Node # GameManager (duck-typed)
var _hex_field: Node
var _selected_card_index: int = -1
var _selected_hex: Vector3i = INVALID_HEX
var _action_panel := ActionPanel.new()

# UI Root - tracks viewport size for proper resize handling
@onready var _ui_root: Control = $UIRoot

# Top panel
@onready var _role_label: Label = $UIRoot/TopPanel/VBox/Role
@onready var _phase_label: Label = $UIRoot/TopPanel/VBox/Phase
@onready var _timer_label: Label = $UIRoot/TopPanel/VBox/Timer
@onready var _scores_label: Label = $UIRoot/TopPanel/VBox/Scores
@onready var _visibility_label: Label = $UIRoot/TopPanel/VBox/Visibility
@onready var _status_label: Label = $UIRoot/TopPanel/VBox/Status

# Bottom panel
@onready var _top_panel: MarginContainer = $UIRoot/TopPanel
@onready var _bottom_panel: MarginContainer = $UIRoot/BottomPanel
@onready var _hand_label: Label = $UIRoot/BottomPanel/CardPanel/VBox/HandLabel
@onready var _hand_container: HBoxContainer = $UIRoot/BottomPanel/CardPanel/VBox/HandContainer
@onready var _reveal_button: Button = $UIRoot/BottomPanel/CardPanel/VBox/ActionContainer/RevealButton
@onready var _commit_button: Button = $UIRoot/BottomPanel/CardPanel/VBox/ActionContainer/ClaimButton
@onready var _build_button: Button = $UIRoot/BottomPanel/CardPanel/VBox/ActionContainer/BuildButton
@onready var _action_card: PanelContainer = $UIRoot/BottomPanel/CardPanel/VBox/ActionCard
@onready var _action_reveal: Button = $UIRoot/BottomPanel/CardPanel/VBox/ActionCard/ActionButtons/ActionReveal
@onready var _action_build: Button = $UIRoot/BottomPanel/CardPanel/VBox/ActionCard/ActionButtons/ActionBuild
@onready var _action_cancel: Button = $UIRoot/BottomPanel/CardPanel/VBox/ActionCard/ActionButtons/ActionCancel

var _card_buttons: Array[Button] = []
var _click_indicator: ColorRect
var _click_tween: Tween

# Debug overlay
var _debug_panel: Control
var _debug_labels: Dictionary = {}
var _debug_enabled := false
var _last_click_screen: Vector2 = Vector2.ZERO
var _last_click_world: Vector2 = Vector2.ZERO
var _last_click_cube: Vector3i = Vector3i(0x7FFFFFFF, 0, 0)
var _last_input_summary: String = ""

# Dynamic HUD outline (follows actual CardPanel position)
var _hud_outline: Panel

func _debug_log(msg: String) -> void:
	if debug_logging:
		print(msg)


func _debug_warn(msg: String) -> void:
	if debug_logging:
		push_warning(msg)

# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_debug_enabled = debug_logging
	_debug_log("$$$ GameHud._ready() START $$$")
	_bind_manager()
	_bind_hex_field()
	_debug_log("$$$ GameHud._ready() BOUND $$$")

	if _gm:
		_connect_signals()
		_refresh_all()

	_reveal_button.pressed.connect(_on_reveal_pressed)
	_commit_button.pressed.connect(_on_commit_pressed)
	_build_button.pressed.connect(_on_build_pressed)
	_action_reveal.pressed.connect(_on_reveal_pressed)
	_action_build.pressed.connect(_on_build_pressed)
	_action_cancel.pressed.connect(_on_cancel_pressed)

	# Enable input processing
	set_process_input(true)
	_debug_log("GameHud: Input processing enabled: %s" % is_processing_input())

	# Handle viewport resize - UIRoot must track viewport size for proper UI positioning
	get_viewport().size_changed.connect(_on_viewport_resized)
	_on_viewport_resized() # Initialize size

	# Log rects after a frame so layout is complete
	call_deferred("_log_ui_rects")

	_init_click_indicator()
	_init_debug_overlay()
	_init_hud_outline()

	_update_ui()


func _on_viewport_resized() -> void:
	# UIRoot must fill the viewport for anchored children to position correctly
	var vp_size := get_viewport().get_visible_rect().size
	if _ui_root:
		_ui_root.size = vp_size
		_debug_log("GameHud: UIRoot resized to %s" % vp_size)
		# Log UI positions after layout update
		call_deferred("_log_resize_positions")


func _log_resize_positions() -> void:
	# Log positions after layout update for debugging
	var bp := get_node_or_null("UIRoot/BottomPanel")
	if bp:
		_debug_log("GameHud: After resize - BottomPanel global_pos=%s size=%s" % [bp.global_position, bp.size])
		for i in range(_card_buttons.size()):
			var btn: Button = _card_buttons[i]
			_debug_log("GameHud: After resize - CardButton[%d] global_pos=%s size=%s" % [i, btn.global_position, btn.size])


func _init_click_indicator() -> void:
	# Small red rectangle to visualize mouse clicks
	_click_indicator = ColorRect.new()
	_click_indicator.size = Vector2(24, 24)
	_click_indicator.color = Color(1, 0, 0, 0.65)
	_click_indicator.visible = false
	_click_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_click_indicator.z_index = 200
	add_child(_click_indicator)


func _init_debug_overlay() -> void:
	var label_names: Array[String] = [
		"mouse_screen", "mouse_global", "mouse_local",
		"camera_pos", "camera_zoom",
		"hovered_cube", "last_click_cube",
		"last_input", "frame", "focus"
	]
	_debug_panel = DebugHUD.create("DEBUG OVERLAY", label_names)
	add_child(_debug_panel)
	# Cast to access DebugHUD-specific properties
	var debug_hud := _debug_panel as DebugHUD
	if debug_hud:
		_debug_labels = debug_hud._labels
	_debug_panel.visible = _debug_enabled


func _init_hud_outline() -> void:
	# Create a dynamic outline that follows the actual CardPanel position
	_hud_outline = Panel.new()
	_hud_outline.name = "DynamicHudOutline"
	_hud_outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_outline.z_index = 100

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0) # Transparent fill
	style.border_width_left = 3
	style.border_width_top = 3
	style.border_width_right = 3
	style.border_width_bottom = 3
	style.border_color = Color(0.2, 0.8, 0.4, 0.8) # Green debug border
	style.corner_radius_top_left = 14
	style.corner_radius_top_right = 14
	style.corner_radius_bottom_left = 14
	style.corner_radius_bottom_right = 14

	_hud_outline.add_theme_stylebox_override("panel", style)
	add_child(_hud_outline)


func _process(_delta: float) -> void:
	_update_hud_outline()

	if not _debug_enabled or _debug_panel == null:
		return

	_update_debug_overlay()


func _update_hud_outline() -> void:
	if _hud_outline == null:
		return

	# Get the actual CardPanel rect and mirror it on the outline
	var card_panel: Control = $BottomPanel/CardPanel if has_node("BottomPanel/CardPanel") else null
	if card_panel == null:
		_hud_outline.visible = false
		return

	# CardPanel's global_position gives us its actual screen position
	var rect := Rect2(card_panel.global_position, card_panel.size)

	# Add margin for the outline to be slightly larger
	var margin := 10.0
	_hud_outline.position = rect.position - Vector2(margin, margin)
	_hud_outline.size = rect.size + Vector2(margin * 2, margin * 2)
	_hud_outline.visible = true


func _update_debug_overlay() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return

	# Get mouse positions
	var screen_mouse := viewport.get_mouse_position()
	var cam := viewport.get_camera_2d()

	var global_mouse := Vector2.ZERO
	var local_mouse := Vector2.ZERO
	var hovered_cube := Vector3i(0x7FFFFFFF, 0, 0)

	if cam:
		global_mouse = cam.get_global_mouse_position()
		_debug_labels["camera_pos"].text = "camera_pos: (%.0f, %.0f)" % [cam.global_position.x, cam.global_position.y]
		_debug_labels["camera_zoom"].text = "camera_zoom: %.2f" % cam.zoom.x
	else:
		_debug_labels["camera_pos"].text = "camera_pos: NO CAMERA"
		_debug_labels["camera_zoom"].text = "camera_zoom: --"

	if _hex_field:
		local_mouse = _hex_field.to_local(global_mouse)
		if _hex_field.has_method("get_closest_cell_from_local"):
			hovered_cube = _hex_field.get_closest_cell_from_local(local_mouse)
			# Check if valid hex
			if _hex_field.has_method("cube_to_map") and _hex_field.has_method("get_cell_source_id"):
				var map_pos = _hex_field.cube_to_map(hovered_cube)
				if _hex_field.get_cell_source_id(map_pos) == -1:
					hovered_cube = Vector3i(0x7FFFFFFF, 0, 0)

	# Update labels
	_debug_labels["mouse_screen"].text = "mouse_screen: (%.0f, %.0f)" % [screen_mouse.x, screen_mouse.y]
	_debug_labels["mouse_global"].text = "mouse_global: (%.0f, %.0f)" % [global_mouse.x, global_mouse.y]
	_debug_labels["mouse_local"].text = "mouse_local: (%.0f, %.0f)" % [local_mouse.x, local_mouse.y]

	if hovered_cube.x != 0x7FFFFFFF:
		_debug_labels["hovered_cube"].text = "hovered_cube: (%d, %d, %d)" % [hovered_cube.x, hovered_cube.y, hovered_cube.z]
	else:
		_debug_labels["hovered_cube"].text = "hovered_cube: INVALID"

	if _last_click_cube.x != 0x7FFFFFFF:
		_debug_labels["last_click_cube"].text = "last_click: (%d, %d, %d)" % [_last_click_cube.x, _last_click_cube.y, _last_click_cube.z]
	else:
		_debug_labels["last_click_cube"].text = "last_click: --"

	_debug_labels["last_input"].text = "input: %s" % _last_input_summary
	_debug_labels["frame"].text = "frame: %d" % Engine.get_process_frames()

	# Show focused control
	var focused := viewport.gui_get_focus_owner()
	if focused:
		_debug_labels["focus"].text = "focus: %s" % focused.name
	else:
		_debug_labels["focus"].text = "focus: NONE"


func _log_ui_rects() -> void:
	_debug_log("=== HUD UI RECTS ===")
	_debug_log("  Viewport: %s" % get_viewport().get_visible_rect())
	_debug_log("  Window: %s" % DisplayServer.window_get_size())
	_debug_log("  UIRoot rect: %s" % _get_global_rect(_ui_root))
	_debug_log("  BottomPanel rect: %s" % _get_global_rect($UIRoot/BottomPanel))
	_debug_log("  CardPanel rect: %s" % _get_global_rect($UIRoot/BottomPanel/CardPanel))
	_debug_log("  HandContainer rect: %s" % _get_global_rect(_hand_container))
	_debug_log("  ActionContainer rect: %s" % _get_global_rect($UIRoot/BottomPanel/CardPanel/VBox/ActionContainer))
	_debug_log("  RevealButton rect: %s, visible=%s" % [_get_global_rect(_reveal_button), _reveal_button.visible])
	_debug_log("  BuildButton rect: %s, visible=%s" % [_get_global_rect(_build_button), _build_button.visible])
	for i in range(_card_buttons.size()):
		var btn: Button = _card_buttons[i]
		_debug_log("  CardButton[%d] rect: %s, visible=%s, disabled=%s" % [
			i, _get_global_rect(btn), btn.visible, btn.disabled
		])


func _get_global_rect(ctrl: Control) -> Rect2:
	if ctrl == null:
		return Rect2()
	return Rect2(ctrl.global_position, ctrl.size)


func _bind_manager() -> void:
	_debug_log("GameHud: _bind_manager called, path=%s, parent=%s" % [game_manager_path, get_parent()])
	if game_manager_path != NodePath():
		_gm = get_node_or_null(game_manager_path)
		_debug_log("GameHud: get_node_or_null(%s) = %s" % [game_manager_path, _gm])
	if _gm == null and get_parent():
		_gm = get_parent().get_node_or_null("GameManager")
		_debug_log("GameHud: fallback get_node_or_null = %s" % _gm)
	if _gm and _gm.has_signal("fog_updated"):
		_gm.fog_updated.connect(_on_fog_updated)
	_debug_log("GameHud: Final _gm = %s" % _gm)


func _bind_hex_field() -> void:
	if hex_field_path != NodePath():
		_hex_field = get_node_or_null(hex_field_path)
	if _hex_field == null and get_parent():
		_hex_field = get_parent().get_node_or_null("HexField")
	if _hex_field and _hex_field.has_signal("hex_clicked"):
		_hex_field.hex_clicked.connect(_on_hex_clicked)


func _connect_signals() -> void:
	_debug_log("GameHud: Connecting signals to GameManager")
	if _gm.has_signal("phase_changed"):
		_gm.phase_changed.connect(_on_phase_changed)
		_debug_log("GameHud: Connected phase_changed")
	if _gm.has_signal("hand_updated"):
		_gm.hand_updated.connect(_on_hand_updated)
		_debug_log("GameHud: Connected hand_updated")
	if _gm.has_signal("nominations_updated"):
		_gm.nominations_updated.connect(_on_nominations_updated)
		_debug_log("GameHud: Connected nominations_updated")
	if _gm.has_signal("commits_updated"):
		_gm.commits_updated.connect(_on_commits_updated)
	if _gm.has_signal("scores_updated"):
		_gm.scores_updated.connect(_on_scores_updated)
	if _gm.has_signal("game_over"):
		_gm.game_over.connect(_on_game_over)
	if _gm.has_signal("visibility_updated"):
		_gm.visibility_updated.connect(_on_visibility_updated)
	if _gm.has_signal("player_count_changed"):
		_gm.player_count_changed.connect(_on_player_count_changed)
	if _gm.has_signal("placement_resolved"):
		_gm.placement_resolved.connect(_on_placement_resolved)
		_debug_log("GameHud: Connected placement_resolved")


func _refresh_all() -> void:
	_on_phase_changed(_gm.phase)
	_on_hand_updated(_gm.hand, _gm.revealed_index)
	_on_nominations_updated(_gm.nominations)
	_on_scores_updated(_gm.scores)
	_on_visibility_updated(_gm.advisor_visibility)

# ─────────────────────────────────────────────────────────────────────────────
# SIGNAL HANDLERS
# ─────────────────────────────────────────────────────────────────────────────

func _on_phase_changed(phase: int) -> void:
	_debug_log("GameHud: Phase changed to %d" % phase)
	var phase_name: String = PHASE_NAMES[phase] if phase < PHASE_NAMES.size() else "?"
	_phase_label.text = "Phase: %s" % phase_name

	# Update timer label based on phase
	match phase:
		0: # LOBBY
			_timer_label.text = "Waiting for players..."
		1, 2, 3: # DRAW, NOMINATE, PLACE - no time limit
			_timer_label.text = "Take your time"
		4: # GAME_OVER
			_timer_label.text = "Game Over"

	# Clear selections on phase change
	_selected_card_index = -1
	_selected_hex = INVALID_HEX

	_update_role_label()
	_update_status_for_phase(phase)
	_update_ui()


func _on_hand_updated(hand: Array, revealed_index: int) -> void:
	_rebuild_card_buttons(hand, revealed_index)
	_update_ui()


func _on_nominations_updated(nominations: Dictionary) -> void:
	_debug_log("GameHud: Nominations updated - %s" % nominations)

	# New format: {role: {hex: Vector3i, claim: Dictionary}}
	var entries: Array[String] = []
	for key in nominations.keys():
		var nom_data: Dictionary = nominations[key]
		if nom_data.is_empty():
			continue
		var cube: Vector3i = nom_data.get("hex", INVALID_HEX)
		var claim: Dictionary = nom_data.get("claim", {})
		if cube != INVALID_HEX:
			var claim_str := MapLayers.label(claim) if not claim.is_empty() else "?"
			entries.append("%s: %s" % [key.capitalize(), claim_str])

	if not entries.is_empty():
		_status_label.text = "Nominated: " + ", ".join(entries)

	# Always call show_nominations - it clears first, then shows valid ones
	# This ensures nomination overlays are cleared when all nominations are INVALID_HEX
	if _hex_field and _hex_field.has_method("show_nominations"):
		_hex_field.show_nominations(nominations)

	_update_ui()


func _on_commits_updated(commits: Dictionary) -> void:
	var industry_done: bool = commits.get("industry", false)
	var urbanist_done: bool = commits.get("urbanist", false)

	if industry_done and urbanist_done:
		_status_label.text = "Both advisors committed!"
	elif industry_done:
		_status_label.text = "Industry committed. Waiting for Urbanist..."
	elif urbanist_done:
		_status_label.text = "Urbanist committed. Waiting for Industry..."
	else:
		_status_label.text = "Waiting for advisors to commit..."


func _on_scores_updated(scores: Dictionary) -> void:
	_scores_label.text = "Scores - Mayor: %d | Industry: %d | Urbanist: %d" % [
		scores.get("mayor", 0),
		scores.get("industry", 0),
		scores.get("urbanist", 0),
	]


func _on_visibility_updated(perimeter: Array) -> void:
	if perimeter.is_empty():
		_visibility_label.text = ""
		if _hex_field and _hex_field.has_method("show_visibility"):
			_hex_field.show_visibility([])
		return

	var items: Array[String] = []
	for entry in perimeter:
		if not entry.has("cube") or not entry.has("card"):
			continue
		var cube: Array = entry["cube"]
		var card: Dictionary = entry["card"]
		items.append("(%d,%d,%d): %s" % [cube[0], cube[1], cube[2], MapLayers.label(card)])

	_visibility_label.text = "Visible: " + "; ".join(items)

	if _hex_field and _hex_field.has_method("show_visibility"):
		_hex_field.show_visibility(perimeter)


func _on_fog_updated(fog: Array) -> void:
	if _hex_field and _hex_field.has_method("reveal_fog"):
		_hex_field.reveal_fog(fog)


func _on_placement_resolved(_turn_idx: int, placement: Dictionary) -> void:
	if placement.is_empty():
		return

	var card: Dictionary = placement.get("card", {})
	if card.is_empty():
		return

	var cube_data = placement.get("cube", null)
	var cube: Vector3i = INVALID_HEX

	if cube_data is Vector3i:
		cube = cube_data
	elif cube_data is Array and cube_data.size() == 3:
		cube = Vector3i(cube_data[0], cube_data[1], cube_data[2])

	if cube == INVALID_HEX:
		return

	# Get which advisor's nomination was chosen
	var winning_role: String = placement.get("winning_role", "")

	# Show built tile on map (winning advisor's claim persists)
	if _hex_field and _hex_field.has_method("show_built_tile"):
		_hex_field.show_built_tile(cube, card, winning_role)
		_debug_log("GameHud: Showing built tile at (%d,%d,%d) by %s" % [
			cube.x, cube.y, cube.z, winning_role if not winning_role.is_empty() else "unknown"
		])


func _on_game_over(reason: String, final_scores: Dictionary) -> void:
	_status_label.text = "GAME OVER: %s" % reason
	_phase_label.text = "Phase: GAME OVER"
	_hand_label.text = "GAME ENDED"
	_on_scores_updated(final_scores)
	_update_ui()


func _on_player_count_changed(count: int, required: int) -> void:
	if _gm and _gm.phase == 0: # LOBBY
		_status_label.text = "Waiting for players... (%d/%d)" % [count, required]

# ─────────────────────────────────────────────────────────────────────────────
# HEX SELECTION
# ─────────────────────────────────────────────────────────────────────────────

func _on_hex_clicked(cube: Vector3i) -> void:
	if _gm == null:
		return

	var phase: int = _gm.phase
	var role: int = _gm.local_role

	# Only allow hex selection in certain phases
	# NOMINATE phase: Advisors select hex
	# PLACE phase: Mayor selects hex
	if phase == 2 and role in [1, 2]: # NOMINATE, INDUSTRY/URBANIST
		_selected_hex = INVALID_HEX if cube == _selected_hex else cube
		if _selected_hex != INVALID_HEX:
			_status_label.text = "Selected hex: (%d,%d,%d) - Click COMMIT" % [_selected_hex.x, _selected_hex.y, _selected_hex.z]
		else:
			_status_label.text = "Selection cleared"
	elif phase == 3 and role == 0: # PLACE, MAYOR
		_selected_hex = INVALID_HEX if cube == _selected_hex else cube
		if _selected_hex != INVALID_HEX:
			_status_label.text = "Selected hex: (%d,%d,%d) - Click BUILD" % [_selected_hex.x, _selected_hex.y, _selected_hex.z]
		else:
			_status_label.text = "Selection cleared"

	# tell field to show selected hex highlight
	if _hex_field and _hex_field.has_method("show_selected_hex"):
		_hex_field.show_selected_hex(_selected_hex)

	_update_ui()

# ─────────────────────────────────────────────────────────────────────────────
# CARD UI
# ─────────────────────────────────────────────────────────────────────────────

func _rebuild_card_buttons(hand: Array, revealed_index: int) -> void:
	# Clear existing buttons
	for child in _hand_container.get_children():
		child.queue_free()
	_card_buttons.clear()

	if hand.is_empty():
		_hand_label.text = "NO CARDS"
		return

	_hand_label.text = _get_hand_instruction()

	for i in range(hand.size()):
		var card: Dictionary = hand[i]
		var btn := _create_card_button(card, i, revealed_index)
		_hand_container.add_child(btn)
		_card_buttons.append(btn)

	# Log button positions after they're added to scene
	call_deferred("_log_card_button_positions")


func _get_hand_instruction() -> String:
	if _gm == null:
		return "YOUR HAND"

	var phase: int = _gm.phase
	var role: int = _gm.local_role

	if role != 0: # Not Mayor
		return "REVEALED CARD"

	match phase:
		1: # DRAW
			return "Select a card to REVEAL"
		3: # PLACE
			return "Select a card to BUILD"
		_:
			return "YOUR HAND"


func _create_card_button(card: Dictionary, index: int, revealed_index: int) -> Button:
	return _action_panel.create_card_button(
		card,
		index,
		_selected_card_index,
		revealed_index,
		SUIT_COLORS,
		_button_hover_shader,
		_on_card_button_pressed,
		_on_card_gui_input
	)


func _add_hover_glow_overlay(btn: Button, _index: int) -> void:
	# Create a ColorRect overlay for the radiant glow effect
	var glow := ColorRect.new()
	glow.name = "HoverGlow"
	glow.color = Color(1.0, 1.0, 1.0, 0.0) # Start invisible
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow.z_index = -1 # Behind button content

	# Create shader material for animated glow
	var mat := ShaderMaterial.new()
	mat.shader = _button_hover_shader
	mat.set_shader_parameter("enabled", false)
	mat.set_shader_parameter("intensity", 1.0)
	mat.set_shader_parameter("pulse_speed", 4.0)
	mat.set_shader_parameter("glow_color", Color(1.0, 1.0, 1.0, 1.0))
	glow.material = mat

	btn.add_child(glow)

	# Connect hover signals
	btn.mouse_entered.connect(_on_card_hover_entered.bind(btn, glow, mat))
	btn.mouse_exited.connect(_on_card_hover_exited.bind(btn, glow, mat))


func _on_card_hover_entered(btn: Button, glow: ColorRect, mat: ShaderMaterial) -> void:
	_debug_log("GameHud: Card hover ENTERED - %s" % btn.name)
	mat.set_shader_parameter("enabled", true)
	glow.color = Color(1.0, 1.0, 1.0, 0.15)

	# Animate glow in
	var tween := create_tween()
	tween.tween_property(glow, "color:a", 0.25, 0.15)


func _on_card_hover_exited(btn: Button, glow: ColorRect, mat: ShaderMaterial) -> void:
	_debug_log("GameHud: Card hover EXITED - %s" % btn.name)

	# Animate glow out
	var tween := create_tween()
	tween.tween_property(glow, "color:a", 0.0, 0.15)
	tween.tween_callback(func(): mat.set_shader_parameter("enabled", false))


func _on_card_gui_input(event: InputEvent, index: int) -> void:
	_debug_log("GameHud: Card %d gui_input event: %s" % [index, event])
	if event is InputEventMouseButton:
		_debug_log("GameHud: Card %d MouseButton: pressed=%s, button=%d" % [index, event.pressed, event.button_index])
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_debug_log("GameHud: Card %d LEFT CLICK DETECTED!" % index)
			_on_card_button_pressed(index)


func _on_card_button_pressed(index: int) -> void:
	_debug_log("GameHud: Card %d button pressed!" % index)
	if _selected_card_index == index:
		_selected_card_index = -1
		_debug_log("GameHud: Deselected card")
	else:
		_selected_card_index = index
		_debug_log("GameHud: Selected card %d" % index)

	if _gm:
		_rebuild_card_buttons(_gm.hand, _gm.revealed_index)
		if _gm.phase == 1 and _gm.revealed_index < 0:
			_status_label.text = "Card %d selected - click REVEAL" % index
		elif _gm.phase == 3:
			_status_label.text = "Card %d selected - pick hex + BUILD" % index
	_update_ui()

# ─────────────────────────────────────────────────────────────────────────────
# ACTION BUTTONS
# ─────────────────────────────────────────────────────────────────────────────

func _on_reveal_pressed() -> void:
	if _gm == null:
		return
	if _selected_card_index >= 0:
		_gm.reveal_card(_selected_card_index)
		_selected_card_index = -1
		_update_ui()


func _on_commit_pressed() -> void:
	if _gm == null:
		return
	if _selected_hex != INVALID_HEX:
		var role: int = _gm.local_role
		_gm.commit_nomination(role, _selected_hex)
		_clear_hex_selection()
		_update_ui()


func _on_build_pressed() -> void:
	if _gm == null:
		return
	if _selected_hex != INVALID_HEX and _selected_card_index >= 0:
		_gm.place_card(_selected_card_index, _selected_hex)
		_selected_card_index = -1
		_clear_hex_selection()
		_update_ui()


func _on_cancel_pressed() -> void:
	_selected_card_index = -1
	_clear_hex_selection()
	_update_ui()

# ─────────────────────────────────────────────────────────────────────────────
# UI STATE UPDATE
# ─────────────────────────────────────────────────────────────────────────────

func _update_ui() -> void:
	if _gm == null:
		_reveal_button.visible = false
		_commit_button.visible = false
		_build_button.visible = false
		_action_card.visible = false
		return

	var role: int = _gm.local_role
	var phase: int = _gm.phase

	var state := _action_panel.compute_state(role, phase, _selected_card_index, _selected_hex, _gm.revealed_index)
	_action_panel.apply_state({
		"reveal": _reveal_button,
		"commit": _commit_button,
		"build": _build_button,
		"action_card": _action_card,
		"action_reveal": _action_reveal,
		"action_build": _action_build,
		"action_cancel": _action_cancel,
	}, state)


func _update_role_label() -> void:
	if _gm == null:
		return
	var role_idx: int = _gm.local_role
	var role_name: String = ROLE_NAMES[role_idx] if role_idx < ROLE_NAMES.size() else "Unknown"
	_role_label.text = "You are the %s" % role_name


func _update_status_for_phase(phase: int) -> void:
	if _gm == null:
		_debug_log("GameHud: _gm is null in _update_status_for_phase")
		return

	var role: int = _gm.local_role
	_debug_log("GameHud: Updating status for phase=%d, role=%d" % [phase, role])

	match phase:
		0: # LOBBY
			_status_label.text = "Waiting for players..."
		1: # DRAW
			if role == 0: # Mayor
				_status_label.text = "Select a card and click REVEAL"
			else:
				_status_label.text = "Mayor is drawing cards..."
		2: # NOMINATE
			if role in [1, 2]: # Advisors
				_status_label.text = "Click a hex to nominate, then COMMIT"
			else:
				_status_label.text = "Advisors are deciding..."
		3: # PLACE
			if role == 0: # Mayor
				_status_label.text = "Select card + nominated hex, then BUILD"
			else:
				_status_label.text = "Mayor is placing a card..."
		4: # GAME_OVER
			pass # Handled by _on_game_over


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		_last_input_summary = "MB%d %s" % [mb.button_index, "DOWN" if mb.pressed else "UP"]
		# Check against actual visible panels, not full-screen UIRoot
		if _is_click_on_hud_panels(mb.position):
			_handle_hud_mouse_button(event)
		else:
			_handle_world_mouse_button(event)

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_selected_card_index = -1
		_clear_hex_selection()
		_update_ui()

	if event is InputEventKey and event.pressed:
		var ke := event as InputEventKey
		_debug_log("GameHud: Key pressed: %s" % ke.as_text())
		_last_input_summary = "KEY %s" % ke.as_text()

		match ke.keycode:
			KEY_1:
				_select_card(0)
			KEY_2:
				_select_card(1)
			KEY_3:
				_select_card(2)
			KEY_R:
				_on_reveal_pressed()
			KEY_B:
				_on_build_pressed()
			KEY_C:
				_on_commit_pressed()
			KEY_ESCAPE:
				_on_cancel_pressed()
			KEY_F3:
				_debug_enabled = not _debug_enabled
				DebugLogger.enabled = _debug_enabled
				if _debug_panel:
					_debug_panel.visible = _debug_enabled


## Check if click position is within any visible HUD panel
func _is_click_on_hud_panels(screen_pos: Vector2) -> bool:
	if _top_panel and _top_panel.get_global_rect().has_point(screen_pos):
		return true
	if _bottom_panel and _bottom_panel.get_global_rect().has_point(screen_pos):
		return true
	return false


func _handle_hud_mouse_button(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_show_click_indicator(mb.position)
		_record_click_coordinates(mb.position)
		if _try_click_card_button(mb.position):
			get_viewport().set_input_as_handled()


func _handle_world_mouse_button(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_show_click_indicator(mb.position)
		_record_click_coordinates(mb.position)
		if _hex_field and _hex_field.has_method("handle_external_click"):
			_hex_field.handle_external_click()
			get_viewport().set_input_as_handled()


func _record_click_coordinates(screen_pos: Vector2) -> void:
	_last_click_screen = screen_pos
	var viewport := get_viewport()
	var cam := viewport.get_camera_2d() if viewport else null

	if cam:
		_last_click_world = cam.get_global_mouse_position()
	else:
		_last_click_world = screen_pos

	if _hex_field and _hex_field.has_method("to_local") and _hex_field.has_method("get_closest_cell_from_local"):
		var local_pos: Vector2 = _hex_field.to_local(_last_click_world)
		_last_click_cube = _hex_field.get_closest_cell_from_local(local_pos)
		# Verify it's a valid hex
		if _hex_field.has_method("cube_to_map") and _hex_field.has_method("get_cell_source_id"):
			var map_pos = _hex_field.cube_to_map(_last_click_cube)
			if _hex_field.get_cell_source_id(map_pos) == -1:
				_last_click_cube = Vector3i(0x7FFFFFFF, 0, 0)


func _log_card_button_positions() -> void:
	_debug_log("=== Card Button Positions ===")
	for i in range(_card_buttons.size()):
		var btn: Button = _card_buttons[i]
		var rect := Rect2(btn.global_position, btn.size)
		_debug_log("  CardButton[%d] global_pos=%s size=%s rect=%s" % [i, btn.global_position, btn.size, rect])
	# Also log action buttons
	_debug_log("=== Action Button Positions ===")
	_debug_log("  RevealButton: global_pos=%s size=%s visible=%s" % [_reveal_button.global_position, _reveal_button.size, _reveal_button.visible])
	_debug_log("  CommitButton: global_pos=%s size=%s visible=%s" % [_commit_button.global_position, _commit_button.size, _commit_button.visible])
	_debug_log("  BuildButton: global_pos=%s size=%s visible=%s" % [_build_button.global_position, _build_button.size, _build_button.visible])


func _try_click_card_button(click_pos: Vector2) -> bool:
	# Manual hit testing for card buttons since CanvasLayer GUI events are unreliable
	# Returns true if a button was hit (to allow consuming the event)
	for i in range(_card_buttons.size()):
		var btn: Button = _card_buttons[i]
		var rect := Rect2(btn.global_position, btn.size)
		if rect.has_point(click_pos):
			_debug_log("GameHud: Manual hit test - click at %s hit CardButton[%d] rect=%s" % [click_pos, i, rect])
			_on_card_button_pressed(i)
			return true

	# Check action buttons (REVEAL, COMMIT, BUILD)
	var action_buttons: Array[Array] = [
		[_reveal_button, "_on_reveal_pressed"],
		[_commit_button, "_on_commit_pressed"],
		[_build_button, "_on_build_pressed"],
		[_action_reveal, "_on_reveal_pressed"],
		[_action_build, "_on_build_pressed"],
		[_action_cancel, "_on_cancel_pressed"],
	]
	for entry in action_buttons:
		var btn: Button = entry[0]
		var method: String = entry[1]
		if btn and btn.visible and not btn.disabled:
			var rect := Rect2(btn.global_position, btn.size)
			if rect.has_point(click_pos):
				_debug_log("GameHud: Manual hit test - click at %s hit %s rect=%s" % [click_pos, btn.text, rect])
				call(method)
				return true

	# No button hit - this click should pass through to HexField
	return false


func _select_card(index: int) -> void:
	if _gm == null:
		return
	if index < 0 or index >= _gm.hand.size():
		return
	_debug_log("GameHud: Keyboard selected card %d" % index)
	_selected_card_index = index
	_rebuild_card_buttons(_gm.hand, _gm.revealed_index)
	_update_ui()


func _clear_hex_selection() -> void:
	_selected_hex = INVALID_HEX
	if _hex_field and _hex_field.has_method("show_selected_hex"):
		_hex_field.show_selected_hex(INVALID_HEX)


func _is_click_in_hud_area(click_pos: Vector2) -> bool:
	# Check if click is within the BottomPanel bounds
	var bottom_panel := get_node_or_null("UIRoot/BottomPanel")
	if bottom_panel:
		var rect := Rect2(bottom_panel.global_position, bottom_panel.size)
		if rect.has_point(click_pos):
			return true
	# Also check TopPanel for debug overlay clicks
	var top_panel := get_node_or_null("UIRoot/TopPanel")
	if top_panel:
		var rect := Rect2(top_panel.global_position, top_panel.size)
		if rect.has_point(click_pos):
			return true
	return false


func _show_click_indicator(pos: Vector2) -> void:
	if _click_indicator == null:
		return

	_click_indicator.position = pos - _click_indicator.size * 0.5
	_click_indicator.visible = true
	_click_indicator.modulate = Color(1, 0, 0, 0.65)

	if _click_tween and _click_tween.is_running():
		_click_tween.kill()

	_click_tween = create_tween()
	_click_tween.tween_property(_click_indicator, "modulate:a", 0.0, 0.35)
	_click_tween.tween_callback(func(): _click_indicator.visible = false)
