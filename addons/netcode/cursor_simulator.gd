## Simulates cursor movement in patterns for demo/testing.
## Attach to a node with access to HexagonTileMapLayer.
extends Node

## Movement patterns available
enum Pattern {CIRCLE, SPIRAL, RANDOM_WALK, FIGURE_EIGHT}

## The pattern this simulator uses
@export var pattern := Pattern.CIRCLE

## Speed of movement (hexes per second)
@export var speed := 3.0

## Radius for circular patterns
@export var radius := 6

## Reference to the hex field
@export var hex_field: HexagonTileMapLayer

## Whether simulation is active
var active := false

## Current logical position in cube coordinates
var _current_hex := Vector3i.ZERO

## Center offset for this client (to separate patterns spatially)
var _center_offset := Vector3i.ZERO

## Time accumulator for pattern calculation
var _time := 0.0

## For random walk: direction change timer
var _walk_timer := 0.0
var _walk_direction := 0


func _ready() -> void:
	# Auto-find hex field
	if hex_field == null:
		hex_field = _find_hex_field()

	# Start simulation after demo is ready
	_connect_demo_launcher.call_deferred()


func _connect_demo_launcher() -> void:
	if has_node("/root/DemoLauncher"):
		var launcher := get_node("/root/DemoLauncher")

		# Server is NOT a player - it just orchestrates. Only clients simulate cursors.
		if launcher.role == 1: # SERVER
			return

		launcher.demo_ready.connect(_on_demo_ready)

		var client_idx: int = launcher.client_index

		# Client 1: SPIRAL on the LEFT side (red)
		# Client 2: RANDOM_WALK on the RIGHT side (blue)
		if client_idx == 1:
			pattern = Pattern.SPIRAL
			_center_offset = Vector3i(-8, 4, 4) # Left side of map
			speed = 4.0 # Faster spiral
		else:
			pattern = Pattern.RANDOM_WALK
			_center_offset = Vector3i(8, -4, -4) # Right side of map
			speed = 5.0 # Faster random walk
			_current_hex = _center_offset # Start at center

		# Offset starting time so updates interleave
		_time = client_idx * 0.5


func _on_demo_ready() -> void:
	active = true


func _process(delta: float) -> void:
	if not active or hex_field == null:
		return

	_time += delta

	var prev_hex := _current_hex
	var target_hex: Vector3i

	match pattern:
		Pattern.CIRCLE:
			target_hex = _calculate_circle()
		Pattern.SPIRAL:
			target_hex = _calculate_spiral()
		Pattern.RANDOM_WALK:
			target_hex = _calculate_random_walk(delta)
		Pattern.FIGURE_EIGHT:
			target_hex = _calculate_figure_eight()

	# For patterns that modify _current_hex internally (random walk), compare with prev
	# For patterns that return calculated value, update _current_hex
	if pattern == Pattern.RANDOM_WALK:
		if target_hex != prev_hex:
			_send_cursor_update(target_hex)
	else:
		if target_hex != _current_hex:
			_current_hex = target_hex
			_send_cursor_update(target_hex)


func _calculate_circle() -> Vector3i:
	var angle := _time * speed * 0.5
	var x := int(round(cos(angle) * radius))
	var y := int(round(sin(angle) * radius))
	var z := -x - y # Cube coordinate constraint
	return Vector3i(x, y, z) + _center_offset


func _calculate_spiral() -> Vector3i:
	var angle := _time * speed * 0.5
	var r := fmod(_time * 0.5, float(radius)) + 2.0 # Oscillating radius
	var x := int(round(cos(angle) * r))
	var y := int(round(sin(angle) * r))
	var z := -x - y
	return Vector3i(x, y, z) + _center_offset


func _calculate_random_walk(delta: float) -> Vector3i:
	_walk_timer += delta

	# Change direction every ~0.5 seconds for faster movement
	if _walk_timer > 0.5:
		_walk_timer = 0.0
		_walk_direction = randi() % 6

	# Move in current direction periodically
	if fmod(_time, 1.0 / speed) < delta:
		_current_hex = _hex_neighbor(_current_hex, _walk_direction)

		# Keep within bounds of center offset
		var dist := _hex_distance(_current_hex, _center_offset)
		if dist > radius:
			# Move back toward center
			_current_hex = _hex_toward(_current_hex, _center_offset)

	return _current_hex


func _calculate_figure_eight() -> Vector3i:
	var angle := _time * speed * 0.3
	var x := int(round(sin(angle) * radius))
	var y := int(round(sin(angle * 2.0) * radius * 0.5))
	var z := -x - y
	return Vector3i(x, y, z) + _center_offset


func _hex_neighbor(hex: Vector3i, direction: int) -> Vector3i:
	# Cube coordinate directions
	const DIRECTIONS: Array[Vector3i] = [
		Vector3i(1, -1, 0), Vector3i(1, 0, -1), Vector3i(0, 1, -1),
		Vector3i(-1, 1, 0), Vector3i(-1, 0, 1), Vector3i(0, -1, 1),
	]
	return hex + DIRECTIONS[direction % 6]


func _hex_distance(a: Vector3i, b: Vector3i) -> int:
	var diff := a - b
	return (abs(diff.x) + abs(diff.y) + abs(diff.z)) / 2


func _hex_toward(hex: Vector3i, target: Vector3i) -> Vector3i:
	# Move one step toward target
	var best_dir := 0
	var best_dist := _hex_distance(_hex_neighbor(hex, 0), target)

	for dir in range(1, 6):
		var neighbor := _hex_neighbor(hex, dir)
		var dist := _hex_distance(neighbor, target)
		if dist < best_dist:
			best_dist = dist
			best_dir = dir

	return _hex_neighbor(hex, best_dir)


func _send_cursor_update(hex: Vector3i) -> void:
	var net_mgr := _get_network_manager()
	if net_mgr == null or net_mgr.local_player == null:
		return

	# Update local player state
	net_mgr.local_player.hovered_hex = hex

	# Broadcast to network
	var data := {"hex": [hex.x, hex.y, hex.z]}
	net_mgr.broadcast_message(
		net_mgr.MessageType.CURSOR_UPDATE,
		data,
		false # Unreliable for frequent updates
	)


func _get_network_manager() -> Node:
	if has_node("/root/NetworkManager"):
		return get_node("/root/NetworkManager")
	return null


func _find_hex_field() -> HexagonTileMapLayer:
	# Try to find in main scene
	var root := get_tree().current_scene
	if root:
		return _find_hex_in_tree(root)
	return null


func _find_hex_in_tree(node: Node) -> HexagonTileMapLayer:
	if node is HexagonTileMapLayer:
		return node
	for child in node.get_children():
		var found := _find_hex_in_tree(child)
		if found:
			return found
	return null
