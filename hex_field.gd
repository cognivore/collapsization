@tool
extends HexagonTileMapLayer

const FIELD_RADIUS: int = 20
const SOURCE_ID: int = 1
const ATLAS_COORDS: Vector2i = Vector2i(0, 0)

func _ready() -> void:
	super._ready()
	if Engine.is_editor_hint():
		return
	generate_field()


func generate_field() -> void:
	clear()
	var hexes := cube_range(Vector3i.ZERO, FIELD_RADIUS)
	for cube in hexes:
		var color_index := posmod(cube.x - cube.y, 3)
		var map_pos := cube_to_map(cube)
		set_cell(map_pos, SOURCE_ID, ATLAS_COORDS, color_index)

