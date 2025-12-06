@tool
extends HexagonTileMapLayer

const FIELD_RADIUS: int = 20
const SOURCE_ID: int = 1
const ATLAS_COORDS: Vector2i = Vector2i(0, 0)

const OUTLINE_COLOR := Color(1.0, 1.0, 0.8, 0.9)
const OUTLINE_WIDTH := 4.0
const GLOW_COLOR := Color(1.0, 1.0, 0.7, 0.25)

var _hovered_hex: Vector3i = Vector3i(0x7FFFFFFF, 0, 0)  # Invalid sentinel
var _outline: Line2D
var _glow: Polygon2D


func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint():
		return
	generate_field()
	_setup_highlight_nodes()


func _setup_highlight_nodes() -> void:
	# Outline
	_outline = Line2D.new()
	_outline.width = OUTLINE_WIDTH
	_outline.default_color = OUTLINE_COLOR
	_outline.closed = true
	_outline.z_index = 10
	_outline.visible = false
	add_child(_outline)
	
	# Glow polygon
	_glow = Polygon2D.new()
	_glow.color = GLOW_COLOR
	_glow.z_index = 5
	_glow.visible = false
	add_child(_glow)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	
	var mouse_pos := get_local_mouse_position()
	var hovered := get_closest_cell_from_local(mouse_pos)
	
	# Check if hex exists in our field
	var map_pos := cube_to_map(hovered)
	if get_cell_source_id(map_pos) == -1:
		_clear_highlight()
		return
	
	if hovered != _hovered_hex:
		_hovered_hex = hovered
		_update_highlight(hovered)


func _clear_highlight() -> void:
	_hovered_hex = Vector3i(0x7FFFFFFF, 0, 0)
	_outline.visible = false
	_glow.visible = false


func _update_highlight(hex: Vector3i) -> void:
	var outlines := cube_outlines([hex])
	if outlines.is_empty():
		_clear_highlight()
		return
	
	var points: Array[Vector2] = []
	for point in outlines[0]:
		points.append(point)
	
	_outline.clear_points()
	for point in points:
		_outline.add_point(point)
	_outline.visible = true
	
	_glow.polygon = PackedVector2Array(points)
	_glow.visible = true


func generate_field() -> void:
	clear()
	var hexes := cube_range(Vector3i.ZERO, FIELD_RADIUS)
	for cube in hexes:
		var color_index := posmod(cube.x - cube.y, 3)
		var map_pos := cube_to_map(cube)
		set_cell(map_pos, SOURCE_ID, ATLAS_COORDS, color_index)
