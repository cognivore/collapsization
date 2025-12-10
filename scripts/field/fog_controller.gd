## Encapsulates fog of war mesh creation and reveal.
extends Node
class_name FogController

var fog: Dictionary = {}
var outline_width := 6.0

func build(owner: Node2D, cubes: Array, outlines_fn: Callable) -> void:
	for node in fog.values():
		if node:
			node.queue_free()
	fog.clear()

	for cube in cubes:
		var cube_arr: Array[Vector3i] = [cube]
		var outlines: Array = outlines_fn.call(cube_arr)
		if outlines.is_empty():
			continue
		var points: Array[Vector2] = []
		for point in outlines[0]:
			points.append(point)
		var poly := Polygon2D.new()
		poly.color = Color(0, 0, 0, 0.65)
		poly.polygon = PackedVector2Array(points)
		poly.z_index = 20
		owner.add_child(poly)
		fog[cube] = poly


func reveal(cubes: Array) -> int:
	var revealed := 0
	for cube in cubes:
		var key: Vector3i = cube if cube is Vector3i else Vector3i(cube[0], cube[1], cube[2])
		if key in fog:
			fog[key].visible = false
			revealed += 1
	return revealed


## Clear all fog (used when game ends to reveal entire map)
func clear_all() -> void:
	for node in fog.values():
		if node:
			node.queue_free()
	fog.clear()
