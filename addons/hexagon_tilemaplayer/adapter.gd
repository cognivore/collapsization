## Slim adapter to isolate our code from the upstream hexagon_tilemaplayer API surface.
extends RefCounted
class_name HexagonTilemapAdapter

## Wrap cube outline generation for reuse/testing.
static func outlines(layer: TileMapLayer, cubes: Array) -> Array:
	if layer == null:
		return []
	if not layer.has_method("cube_outlines"):
		return []
	return layer.cube_outlines(cubes)


static func ring(layer: TileMapLayer, center: Vector3i, radius: int) -> Array:
	if layer == null or not layer.has_method("cube_ring"):
		return []
	return layer.cube_ring(center, radius)


static func range(layer: TileMapLayer, center: Vector3i, radius: int) -> Array:
	if layer == null or not layer.has_method("cube_range"):
		return []
	return layer.cube_range(center, radius)

