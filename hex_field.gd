@tool
extends HexagonTileMapLayer

const FIELD_RADIUS: int = 20
const SOURCE_ID: int = 1
const ATLAS_COORDS: Vector2i = Vector2i(0, 0)

const OUTLINE_WIDTH := 6.0
const GLOW_ALPHA := 0.45
const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)

signal hex_clicked(cube: Vector3i)

const PlayerStateScript := preload("res://addons/netcode/player_state.gd")
const MapLayers := preload("res://scripts/map_layers.gd")
const FieldOverlayManager := preload("res://scripts/field/overlay_manager.gd")
const FogController := preload("res://scripts/field/fog_controller.gd")
const HexagonTilemapAdapter := preload("res://addons/hexagon_tilemaplayer/adapter.gd")
const DebugLogger := preload("res://scripts/debug/debug_logger.gd")

# Preload hover shader
var _hover_shader: Shader = preload("res://shaders/hex_hover.gdshader")

var _hovered_hex: Vector3i = INVALID_HEX
var _local_outline: Line2D
var _local_glow: Polygon2D
var _hover_material: ShaderMaterial

# Remote player cursors: player_id -> {outline: Line2D, glow: Polygon2D}
var _remote_highlights: Dictionary = {}

# Reference to cursor sync (set externally or found automatically)
var cursor_sync: Node # CursorSync

# Reference to GameManager for click routing
@export var game_manager_path: NodePath = NodePath("../GameManager")
@export var overlay_debug: bool = false
var _game_manager: Node

# Layered map info (truth and advisor slices)
var map_layers: MapLayers

var _overlay_mgr: FieldOverlayManager
var _fog_controller: FogController

# Colors for different roles
const NOMINATION_COLORS := {
	"industry": Color(0.95, 0.7, 0.2, 0.9), # Gold
	"urbanist": Color(0.9, 0.2, 0.3, 0.9), # Red
}

const BUILT_COLOR := Color(0.3, 0.8, 0.4, 0.9) # Green


func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint():
		return
	generate_field()
	_init_map_layers()
	_bind_game_manager()
	_overlay_mgr = FieldOverlayManager.new()
	_overlay_mgr.outline_width = OUTLINE_WIDTH
	_overlay_mgr.glow_alpha = GLOW_ALPHA
	_overlay_mgr.debug_enabled = overlay_debug
	add_child(_overlay_mgr)
	_fog_controller = FogController.new()
	_fog_controller.outline_width = OUTLINE_WIDTH
	add_child(_fog_controller)
	_build_fog()
	_reveal_initial_fog()
	_setup_local_highlight()
	_find_cursor_sync.call_deferred()


func _reveal_initial_fog() -> void:
	# Always reveal center + 1 ring at start
	var center := Vector3i.ZERO
	var initial_visible: Array = [center]
	for cube in cube_ring(center, 1):
		initial_visible.append(cube)
	reveal_fog(initial_visible)
	DebugLogger.log("HexField: Revealed initial fog for %d hexes" % initial_visible.size())


func _find_cursor_sync() -> void:
	# Look for CursorSync in parent or siblings
	var parent := get_parent()
	if parent:
		for child in parent.get_children():
			if child.get_script() and child.get_script().resource_path.ends_with("cursor_sync.gd"):
				cursor_sync = child
				cursor_sync.hex_field = self
				if cursor_sync.has_signal("remote_cursor_updated"):
					cursor_sync.remote_cursor_updated.connect(_on_remote_cursor_updated)
				if cursor_sync.has_signal("remote_cursor_removed"):
					cursor_sync.remote_cursor_removed.connect(_on_remote_cursor_removed)
				break


func _setup_local_highlight() -> void:
	# Use white color for hover highlighting per user request
	var hover_color := Color.WHITE

	_local_outline = Line2D.new()
	_local_outline.width = OUTLINE_WIDTH
	_local_outline.default_color = hover_color
	_local_outline.closed = true
	_local_outline.z_index = 10
	_local_outline.visible = false
	add_child(_local_outline)

	# Create shader material for radiant glow effect
	_hover_material = ShaderMaterial.new()
	_hover_material.shader = _hover_shader
	_hover_material.set_shader_parameter("base_color", Color(1.0, 1.0, 1.0, 0.5))
	_hover_material.set_shader_parameter("intensity", 1.2)
	_hover_material.set_shader_parameter("pulse_speed", 3.0)
	_hover_material.set_shader_parameter("edge_glow", 0.7)

	_local_glow = Polygon2D.new()
	_local_glow.color = Color.WHITE # Base color, shader handles the effect
	_local_glow.material = _hover_material
	_local_glow.z_index = 5
	_local_glow.visible = false
	add_child(_local_glow)


func _get_local_player_color() -> Color:
	var net_mgr := _get_network_manager()
	if net_mgr and net_mgr.local_player:
		return net_mgr.local_player.get_color()
	# Default to first color if not connected
	return PlayerStateScript.PLAYER_COLORS[0]


func _get_network_manager() -> Node:
	if has_node("/root/NetworkManager"):
		return get_node("/root/NetworkManager")
	return null


func _bind_game_manager() -> void:
	if game_manager_path != NodePath():
		_game_manager = get_node_or_null(game_manager_path)


func apply_fog(fog: Array) -> void:
	if fog.is_empty():
		return
	reveal_fog(fog)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return

	var hovered: Vector3i

	# Always use real mouse position for hover detection in single player
	# The get_local_mouse_position() handles camera transforms correctly
	var mouse_pos := get_local_mouse_position()
	hovered = get_closest_cell_from_local(mouse_pos)

	# Debug: print hover info every 2 seconds
	if Engine.get_process_frames() % 120 == 0:
		var map_pos := cube_to_map(hovered) if hovered != INVALID_HEX else Vector2i(-1, -1)
		var source_id := get_cell_source_id(map_pos) if hovered != INVALID_HEX else -1
		DebugLogger.log("HexField: mouse_local=%s -> cube=%s, map=%s, source=%d" % [mouse_pos, hovered, map_pos, source_id])

	# Check if hex exists in our field
	if hovered != INVALID_HEX:
		var map_pos := cube_to_map(hovered)
		if get_cell_source_id(map_pos) == -1:
			hovered = INVALID_HEX

	if hovered == INVALID_HEX:
		_clear_local_highlight()
		return

	if hovered != _hovered_hex:
		_hovered_hex = hovered
		_update_local_highlight(hovered)


## Handle hex clicks only in _unhandled_input so HUD controls get priority.
## Previously both _input and _unhandled_input handled clicks, causing duplicates.
func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		DebugLogger.log("HexField: _unhandled_input MouseButton LEFT pressed=%s" % event.is_pressed())
		if event.is_pressed():
			_handle_hex_click()


## Public method for external click handling - called by GameHud when click
## is outside HUD area (bypasses broken CanvasLayer event propagation)
func handle_external_click() -> void:
	DebugLogger.log("HexField: handle_external_click called")
	_handle_hex_click()


func _handle_hex_click() -> void:
	var viewport_pos := get_viewport().get_mouse_position()
	var cam := get_viewport().get_camera_2d()
	var global_mouse: Vector2 = cam.get_global_mouse_position() if cam else get_global_mouse_position()
	var mouse_pos := to_local(global_mouse)
	var cube := get_closest_cell_from_local(mouse_pos)
	var is_fogged: bool = false
	if _fog_controller and _fog_controller.fog.has(cube):
		var poly: Polygon2D = _fog_controller.fog[cube] as Polygon2D
		if poly != null:
			is_fogged = poly.visible

	DebugLogger.log("=== HexField Click ===")
	DebugLogger.log("  Viewport mouse: %s" % viewport_pos)
	DebugLogger.log("  Local mouse: %s" % mouse_pos)
	DebugLogger.log("  Cube: %s" % cube)
	DebugLogger.log("  Fogged: %s" % is_fogged)
	DebugLogger.log("  Source ID: %d" % get_cell_source_id(cube_to_map(cube)))

	# Draw a debug marker at the clicked location (only in debug mode)
	if DebugLogger.enabled:
		_draw_click_marker(mouse_pos)

	if cube != INVALID_HEX and get_cell_source_id(cube_to_map(cube)) != -1:
		DebugLogger.log("HexField: Emitting hex_clicked for cube (%d,%d,%d)" % [cube.x, cube.y, cube.z])
		if _game_manager and _game_manager.has_method("on_hex_clicked"):
			_game_manager.on_hex_clicked(cube)
		hex_clicked.emit(cube)
	else:
		DebugLogger.log("HexField: Invalid hex or outside field")


var _click_marker: Polygon2D = null

func _draw_click_marker(local_pos: Vector2) -> void:
	# Create a small red circle at the click location for debugging
	if _click_marker == null:
		_click_marker = Polygon2D.new()
		_click_marker.z_index = 100
		add_child(_click_marker)

	# Small circle of radius 8
	var points: PackedVector2Array = []
	for i in range(12):
		var angle := i * TAU / 12.0
		points.append(local_pos + Vector2(8, 0).rotated(angle))
	_click_marker.polygon = points
	_click_marker.color = Color.RED
	_click_marker.visible = true

	# Hide after 0.5 seconds
	var tween := create_tween()
	tween.tween_property(_click_marker, "modulate:a", 0.0, 0.5)
	tween.tween_callback(func(): _click_marker.visible = false)


# ─────────────────────────────────────────────────────────────────────────────
# SELECTED HEX OVERLAY
# ─────────────────────────────────────────────────────────────────────────────

func show_selected_hex(cube: Vector3i) -> void:
	if _overlay_mgr == null:
		return
	_clear_selected_hex()
	if cube == INVALID_HEX:
		return
	var outlines := cube_outlines([cube])
	_overlay_mgr.show_selected_hex(self, cube, outlines)


func _clear_selected_hex() -> void:
	if _overlay_mgr:
		_overlay_mgr.clear_selected_hex()


func _is_demo_mode() -> bool:
	if has_node("/root/DemoLauncher"):
		return get_node("/root/DemoLauncher").is_demo_mode
	return false


func _is_singleplayer() -> bool:
	if has_node("/root/DemoLauncher"):
		return get_node("/root/DemoLauncher").is_singleplayer
	return true # Default to singleplayer if no launcher


func _is_server() -> bool:
	var net_mgr := _get_network_manager()
	return net_mgr and net_mgr.is_server()


func _clear_local_highlight() -> void:
	_hovered_hex = INVALID_HEX
	if _local_outline:
		_local_outline.visible = false
	if _local_glow:
		_local_glow.visible = false


func _update_local_highlight(hex: Vector3i) -> void:
	var outlines := cube_outlines([hex])
	if outlines.is_empty():
		_clear_local_highlight()
		return

	var points: Array[Vector2] = []
	for point in outlines[0]:
		points.append(point)

	# Use white for hover highlighting
	_local_outline.default_color = Color.WHITE

	_local_outline.clear_points()
	for point in points:
		_local_outline.add_point(point)
	_local_outline.visible = true

	_local_glow.polygon = PackedVector2Array(points)
	_local_glow.visible = true

	# Ensure shader is enabled
	if _hover_material:
		_hover_material.set_shader_parameter("enabled", true)


func _on_remote_cursor_updated(player_id: int, hex: Vector3i) -> void:
	if hex == INVALID_HEX:
		_clear_remote_highlight(player_id)
		return

	# Get or create highlight for this player
	if player_id not in _remote_highlights:
		_create_remote_highlight(player_id)

	var highlight: Dictionary = _remote_highlights[player_id]
	var outline: Line2D = highlight["outline"]
	var glow: Polygon2D = highlight["glow"]

	# Check if hex is valid on the field
	var map_pos := cube_to_map(hex)
	if get_cell_source_id(map_pos) == -1:
		outline.visible = false
		glow.visible = false
		return

	var outlines := cube_outlines([hex])
	if outlines.is_empty():
		outline.visible = false
		glow.visible = false
		return

	var points: Array[Vector2] = []
	for point in outlines[0]:
		points.append(point)

	outline.clear_points()
	for point in points:
		outline.add_point(point)
	outline.visible = true

	glow.polygon = PackedVector2Array(points)
	glow.visible = true


func _on_remote_cursor_removed(player_id: int) -> void:
	if player_id in _remote_highlights:
		var highlight: Dictionary = _remote_highlights[player_id]
		highlight["outline"].queue_free()
		highlight["glow"].queue_free()
		_remote_highlights.erase(player_id)


func _create_remote_highlight(player_id: int) -> void:
	var player_color := _get_player_color(player_id)

	var outline := Line2D.new()
	outline.width = OUTLINE_WIDTH
	outline.default_color = player_color
	outline.closed = true
	outline.z_index = 9 # Slightly below local player
	outline.visible = false
	add_child(outline)

	var glow := Polygon2D.new()
	glow.color = Color(player_color, GLOW_ALPHA)
	glow.z_index = 4
	glow.visible = false
	add_child(glow)

	_remote_highlights[player_id] = {
		"outline": outline,
		"glow": glow,
	}


func _clear_remote_highlight(player_id: int) -> void:
	if player_id in _remote_highlights:
		var highlight: Dictionary = _remote_highlights[player_id]
		highlight["outline"].visible = false
		highlight["glow"].visible = false


func _get_player_color(player_id: int) -> Color:
	var net_mgr := _get_network_manager()
	if net_mgr:
		var player = net_mgr.get_player(player_id)
		if player:
			return player.get_color()
	return PlayerStateScript.PLAYER_COLORS[player_id % PlayerStateScript.PLAYER_COLORS.size()]


## Update local player's color index and refresh display.
func set_local_color_index(color_index: int) -> void:
	var net_mgr := _get_network_manager()
	if net_mgr and net_mgr.local_player:
		net_mgr.local_player.set_color_index(color_index)
		# Broadcast color change
		net_mgr.broadcast_message(
			net_mgr.MessageType.PLAYER_STATE,
			net_mgr.local_player.to_dict(),
			true
		)

	# Refresh local highlight color
	if _local_outline and _local_glow:
		var color: Color = PlayerStateScript.PLAYER_COLORS[color_index % PlayerStateScript.PLAYER_COLORS.size()]
		_local_outline.default_color = color
		_local_glow.color = Color(color, GLOW_ALPHA)


func generate_field() -> void:
	clear()
	var hexes := cube_range(Vector3i.ZERO, FIELD_RADIUS)
	DebugLogger.log("HexField: Generating %d hexes" % hexes.size())
	for cube in hexes:
		var color_index := posmod(cube.x - cube.y, 3)
		var map_pos := cube_to_map(cube)
		set_cell(map_pos, SOURCE_ID, ATLAS_COORDS, color_index)
	DebugLogger.log("HexField: Field generated, used_cells=%d" % get_used_cells().size())

	# Debug: Verify center tile exists
	var center_map := cube_to_map(Vector3i.ZERO)
	var center_source := get_cell_source_id(center_map)
	DebugLogger.log("HexField: Center tile at map=%s, source_id=%d" % [center_map, center_source])
	DebugLogger.log("HexField: TileMapLayer visible=%s, z_index=%d" % [visible, z_index])


func _build_fog() -> void:
	var hexes := cube_range(Vector3i.ZERO, FIELD_RADIUS)
	_fog_controller.build(self, hexes, Callable(self, "cube_outlines"))


func reveal_fog(cubes: Array) -> void:
	if _fog_controller == null:
		return
	var revealed := _fog_controller.reveal(cubes)

	# Lazily generate reality for newly revealed tiles
	if map_layers:
		for cube in cubes:
			var c: Vector3i = cube if cube is Vector3i else Vector3i(cube[0], cube[1], cube[2])
			map_layers.reveal_tile(c)

	DebugLogger.log("HexField: Revealing fog for %d cubes, fog dict size=%d" % [cubes.size(), _fog_controller.fog.size()])
	DebugLogger.log("HexField: Revealed %d fog polygons" % revealed)


func show_visibility(entries: Array) -> void:
	_overlay_mgr.clear_visibility()
	if entries.is_empty():
		return
	_overlay_mgr.show_visibility(
		self,
		entries,
		Callable(self, "cube_outlines"),
		Callable(self, "_color_for_card"),
		Callable(self, "reveal_fog")
	)


func _clear_visibility() -> void:
	_overlay_mgr.clear_visibility()


func _color_for_card(card: Dictionary) -> Color:
	match card.get("suit", -1):
		MapLayers.Suit.HEARTS:
			return Color("#e74c3c")
		MapLayers.Suit.DIAMONDS:
			return Color("#f39c12")
		MapLayers.Suit.SPADES:
			return Color("#2c3e50")
		_:
			return PlayerStateScript.PLAYER_COLORS[0]


func _nomination_color(role_key: String, _claim := {}) -> Color:
	return NOMINATION_COLORS.get(role_key, Color.WHITE)


# ─────────────────────────────────────────────────────────────────────────────
# NOMINATION OVERLAYS
# ─────────────────────────────────────────────────────────────────────────────

## Show nominated hexes on the map (called when nominations are revealed)
## Nominations format: Array of {hex: Vector3i, claim: Dictionary, advisor: String}
func show_nominations(nominations: Array) -> void:
	_clear_nominations()

	var idx := 0
	for nom_data in nominations:
		if not (nom_data is Dictionary):
			continue

		var cube: Vector3i = nom_data.get("hex", INVALID_HEX)
		if cube == INVALID_HEX:
			continue

		var advisor: String = nom_data.get("advisor", "")
		var claimed_card: Dictionary = nom_data.get("claim", {})
		# Use unique key per nomination (advisor + index) to support multiple per advisor
		var overlay_key: String = "%s_%d" % [advisor, idx]
		_overlay_mgr.show_nomination_for_cube(
			self,
			overlay_key,
			cube,
			Callable(self, "_nomination_color_by_key").bind(advisor),
			Callable(self, "cube_outlines"),
			claimed_card
		)
		idx += 1

	DebugLogger.log("HexField: Showing %d nominations" % nominations.size())


## Color helper for array-based nominations (takes advisor from bound arg)
func _nomination_color_by_key(key: String, _claim := {}, advisor: String = "") -> Color:
	# Extract advisor from key (format: "advisor_index")
	var actual_advisor := advisor
	if actual_advisor.is_empty():
		actual_advisor = key.split("_")[0] if "_" in key else key
	return NOMINATION_COLORS.get(actual_advisor, Color.WHITE)


func _clear_nominations() -> void:
	_overlay_mgr.clear_nominations()


# ─────────────────────────────────────────────────────────────────────────────
# BUILT TILE OVERLAYS
# ─────────────────────────────────────────────────────────────────────────────

## Show a built card on the map
## winning_role: which advisor's nomination was chosen (their claim persists forever)
func show_built_tile(cube: Vector3i, card: Dictionary, winning_role: String = "") -> void:
	if cube == INVALID_HEX:
		return

	# Only persist the winning nomination ON THIS HEX, clear all others
	if not winning_role.is_empty():
		_overlay_mgr.persist_nomination_at_hex(winning_role, cube)
	# Clear ALL remaining nominations (including winner's other nomination)
	_clear_nominations()

	var outlines := cube_outlines([cube])
	if outlines.is_empty():
		return
	var card_color := _color_for_card(card)
	_overlay_mgr.show_built(self, cube, card_color, outlines, card)
	DebugLogger.log("HexField: Built at (%d,%d,%d) - %s (by %s)" % [
		cube.x, cube.y, cube.z, MapLayers.label(card),
		winning_role.capitalize() if not winning_role.is_empty() else "unknown"
	])


# ─────────────────────────────────────────────────────────────────────────────
# GAME OVER - REVEAL ALL REALITY
# ─────────────────────────────────────────────────────────────────────────────

## Reveal the TRUE cards on ALL tiles (called when game is over)
## This shows what was actually hidden under each tile, exposing all lies
func reveal_all_reality() -> void:
	if map_layers == null:
		DebugLogger.log("HexField: No map_layers to reveal")
		return

	# Clear fog entirely
	if _fog_controller:
		_fog_controller.clear_all()

	# Get all reality tiles (single layer now)
	_overlay_mgr.reveal_all_reality(self, map_layers.truth, Callable(self, "cube_outlines"))
	DebugLogger.log("HexField: Revealed all reality - %d tiles" % map_layers.truth.size())


## Initialize map layers with optional deterministic seed.
func _init_map_layers(seed: int = -1) -> void:
	map_layers = MapLayers.new()
	var actual_seed := seed if seed >= 0 else int(Time.get_ticks_msec())
	map_layers.init(actual_seed)
	map_layers.init_center() # Center starts as A♥
	DebugLogger.log("HexField: map_layers initialized with seed=%d" % actual_seed)


## Re-init map layers with a specific seed (used by demo for determinism).
## For tests, this still uses legacy generate() to populate all tiles eagerly.
func reinit_map_layers(seed: int) -> void:
	map_layers = MapLayers.new()
	map_layers.generate(self, FIELD_RADIUS, seed)
	DebugLogger.log("HexField: map_layers regenerated with seed=%d" % seed)


## Get a tile's reality card (simplified - no layer type needed)
func get_reality_card(cube: Vector3i) -> Dictionary:
	if map_layers:
		return map_layers.get_card(cube)
	return {}
