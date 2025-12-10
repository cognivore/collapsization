## Unit tests for FieldOverlayManager geometry helpers.
extends GutTest

const OverlayManager := preload("res://scripts/field/overlay_manager.gd")

var _mgr: OverlayManager


func before_each() -> void:
	_mgr = OverlayManager.new()


func after_each() -> void:
	_mgr.free()


## Create a regular hexagon with pointy-top orientation
## Vertices go CLOCKWISE from TOP (12 o'clock):
##   v0 = TOP, v1 = upper-RIGHT, v2 = lower-RIGHT,
##   v3 = BOTTOM, v4 = lower-LEFT, v5 = upper-LEFT
func _make_hex_vertices(center: Vector2, radius: float) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for i in range(6):
		# Start from TOP (-90°) and go clockwise
		var angle := deg_to_rad(-90 + i * 60)
		points.append(center + Vector2(radius, 0).rotated(angle))
	return points


## Test: calculate_center returns average of all points
func test_calculate_center_regular_hex() -> void:
	var center := Vector2(100, 100)
	var points := _make_hex_vertices(center, 50.0)
	var computed_center := _mgr.calculate_center(points)

	# For a regular polygon, center should be very close to the input center
	assert_almost_eq(computed_center.x, center.x, 0.1, "Center X")
	assert_almost_eq(computed_center.y, center.y, 0.1, "Center Y")


func test_calculate_center_empty_array() -> void:
	var empty: Array[Vector2] = []
	var result := _mgr.calculate_center(empty)
	assert_eq(result, Vector2.ZERO, "Empty array returns ZERO")


## Test: get_label_position with fewer than 6 vertices returns center
func test_get_label_position_insufficient_vertices() -> void:
	var few: Array[Vector2] = [Vector2(0, 0), Vector2(10, 0), Vector2(5, 10)]
	var center := _mgr.calculate_center(few)
	var result := _mgr.get_label_position(few, "industry")
	assert_eq(result, center, "Fewer than 6 vertices returns center")


## Test: get_label_position for "industry" returns TOP-RIGHT triangle centroid
func test_get_label_position_industry() -> void:
	var center := Vector2(100, 100)
	var points := _make_hex_vertices(center, 50.0)
	var result := _mgr.get_label_position(points, "industry")

	# Industry: center + v0 (TOP) + v1 (upper-RIGHT) / 3
	var expected := (center + points[0] + points[1]) / 3.0
	assert_almost_eq(result.x, expected.x, 0.1, "Industry X matches expected centroid")
	assert_almost_eq(result.y, expected.y, 0.1, "Industry Y matches expected centroid")

	# Should be in upper-right quadrant relative to hex center
	assert_true(result.x > center.x, "Industry label is to the right of center")
	assert_true(result.y < center.y, "Industry label is above center")


## Test: get_label_position for "urbanist" returns BOTTOM-LEFT triangle centroid
func test_get_label_position_urbanist() -> void:
	var center := Vector2(100, 100)
	var points := _make_hex_vertices(center, 50.0)
	var result := _mgr.get_label_position(points, "urbanist")

	# Urbanist: center + v3 (BOTTOM) + v4 (lower-LEFT) / 3
	var expected := (center + points[3] + points[4]) / 3.0
	assert_almost_eq(result.x, expected.x, 0.1, "Urbanist X matches expected centroid")
	assert_almost_eq(result.y, expected.y, 0.1, "Urbanist Y matches expected centroid")

	# Should be in lower-left quadrant relative to hex center
	assert_true(result.x < center.x, "Urbanist label is to the left of center")
	assert_true(result.y > center.y, "Urbanist label is below center")


## Test: get_label_position for "reality" returns TOP-LEFT triangle centroid
func test_get_label_position_reality() -> void:
	var center := Vector2(100, 100)
	var points := _make_hex_vertices(center, 50.0)
	var result := _mgr.get_label_position(points, "reality")

	# Reality: center + v5 (upper-LEFT) + v0 (TOP) / 3
	var expected := (center + points[5] + points[0]) / 3.0
	assert_almost_eq(result.x, expected.x, 0.1, "Reality X matches expected centroid")
	assert_almost_eq(result.y, expected.y, 0.1, "Reality Y matches expected centroid")

	# Should be in upper-left quadrant relative to hex center
	assert_true(result.x < center.x, "Reality label is to the left of center")
	assert_true(result.y < center.y, "Reality label is above center")


## Test: get_label_position for unknown role returns center
func test_get_label_position_default_center() -> void:
	var center := Vector2(100, 100)
	var points := _make_hex_vertices(center, 50.0)
	var result := _mgr.get_label_position(points, "built")

	# Default case returns hex center
	assert_almost_eq(result.x, center.x, 0.1, "Built label X at center")
	assert_almost_eq(result.y, center.y, 0.1, "Built label Y at center")


## Test: triangles don't overlap - industry, urbanist, reality positions are distinct
func test_label_positions_are_distinct() -> void:
	var center := Vector2(100, 100)
	var points := _make_hex_vertices(center, 50.0)

	var industry := _mgr.get_label_position(points, "industry")
	var urbanist := _mgr.get_label_position(points, "urbanist")
	var reality := _mgr.get_label_position(points, "reality")

	# All three should be different
	assert_ne(industry, urbanist, "Industry != Urbanist")
	assert_ne(industry, reality, "Industry != Reality")
	assert_ne(urbanist, reality, "Urbanist != Reality")

	# And none at center
	assert_ne(industry, center, "Industry != Center")
	assert_ne(urbanist, center, "Urbanist != Center")
	assert_ne(reality, center, "Reality != Center")

