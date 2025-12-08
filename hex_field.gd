@tool
extends HexagonTileMapLayer

const FIELD_RADIUS: int = 20
const SOURCE_ID: int = 1
const ATLAS_COORDS: Vector2i = Vector2i(0, 0)

const OUTLINE_WIDTH := 6.0
const GLOW_ALPHA := 0.45
const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)

const PlayerStateScript := preload("res://addons/netcode/player_state.gd")

var _hovered_hex: Vector3i = INVALID_HEX
var _local_outline: Line2D
var _local_glow: Polygon2D

# Remote player cursors: player_id -> {outline: Line2D, glow: Polygon2D}
var _remote_highlights: Dictionary = {}

# Reference to cursor sync (set externally or found automatically)
var cursor_sync: Node # CursorSync


func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint():
		return
	generate_field()
	_setup_local_highlight()
	_find_cursor_sync.call_deferred()


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
	var local_color := _get_local_player_color()

	_local_outline = Line2D.new()
	_local_outline.width = OUTLINE_WIDTH
	_local_outline.default_color = local_color
	_local_outline.closed = true
	_local_outline.z_index = 10
	_local_outline.visible = false
	add_child(_local_outline)

	_local_glow = Polygon2D.new()
	_local_glow.color = Color(local_color, GLOW_ALPHA)
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


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return

	var hovered: Vector3i

	# In demo mode, use simulated cursor from local player state
	if _is_demo_mode():
		# Server has no local cursor - it only watches clients
		if _is_server():
			hovered = INVALID_HEX
		else:
			# Client: read cursor from local player state (set by CursorSimulator)
			var net_mgr := _get_network_manager()
			if net_mgr and net_mgr.local_player:
				hovered = net_mgr.local_player.hovered_hex
			else:
				hovered = INVALID_HEX
	else:
		# Normal mode: use real mouse
		var mouse_pos := get_local_mouse_position()
		hovered = get_closest_cell_from_local(mouse_pos)

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


func _is_demo_mode() -> bool:
	if has_node("/root/DemoLauncher"):
		return get_node("/root/DemoLauncher").is_demo_mode
	return false


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

	# Update local player color in case it changed
	var local_color := _get_local_player_color()
	_local_outline.default_color = local_color
	_local_glow.color = Color(local_color, GLOW_ALPHA)

	_local_outline.clear_points()
	for point in points:
		_local_outline.add_point(point)
	_local_outline.visible = true

	_local_glow.polygon = PackedVector2Array(points)
	_local_glow.visible = true


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
	for cube in hexes:
		var color_index := posmod(cube.x - cube.y, 3)
		var map_pos := cube_to_map(cube)
		set_cell(map_pos, SOURCE_ID, ATLAS_COORDS, color_index)
