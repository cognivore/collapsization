## Handles selection, nomination, visibility, and built overlays for the hex field.
extends Node
class_name FieldOverlayManager

const MapLayers := preload("res://scripts/map_layers.gd")

var outline_width := 6.0
var glow_alpha := 0.45

var _visibility_nodes: Array[Node] = []
var _nomination_overlays: Dictionary = {}
var _persisted_nominations: Dictionary = {} # Nominations that stay forever after build
var _built_overlays: Dictionary = {}
var _selected_overlay: Dictionary = {}
var _reality_overlays: Dictionary = {} # Reality labels shown on game over


func clear_all() -> void:
	_clear_visibility()
	_clear_nominations()
	_clear_built()
	_clear_selected_hex()
	_clear_reality()


# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

## Calculate the center point of a polygon from its vertices
func _calculate_center(points: Array[Vector2]) -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	return sum / points.size()


## Get label position at the CENTER of a triangular section of the hexagon
## Hexagon is split into 6 triangles from center to each edge.
## For POINTY-TOP hex, vertices go COUNTER-CLOCKWISE from lower-right:
##   v0 = lower-right (4 o'clock)
##   v1 = BOTTOM point (6 o'clock)
##   v2 = lower-left (8 o'clock)
##   v3 = upper-left (10 o'clock)
##   v4 = TOP point (12 o'clock)
##   v5 = upper-right (2 o'clock)
##
## Triangle assignments:
##   TOP-LEFT: v3 (upper-left) + v4 (top) → for REALITY
##   TOP-RIGHT: v4 (top) + v5 (upper-right) → for INDUSTRY
##   BOTTOM-LEFT: v1 (bottom) + v2 (lower-left) → for URBANIST
##   CENTER → for BUILT tiles
func _get_label_position(points: Array[Vector2], role_key: String) -> Vector2:
	var center := _calculate_center(points)
	if points.size() < 6:
		return center

	# Vertices go CLOCKWISE from TOP for pointy-top hex:
	#   v0 = TOP (12 o'clock)
	#   v1 = upper-RIGHT (2 o'clock)
	#   v2 = lower-RIGHT (4 o'clock)
	#   v3 = BOTTOM (6 o'clock)
	#   v4 = lower-LEFT (8 o'clock)
	#   v5 = upper-LEFT (10 o'clock)
	match role_key:
		"reality":
			# TOP-LEFT triangle: center + upper-LEFT + TOP
			return (center + points[5] + points[0]) / 3.0
		"industry":
			# TOP-RIGHT triangle: center + TOP + upper-RIGHT
			return (center + points[0] + points[1]) / 3.0
		"urbanist":
			# BOTTOM-LEFT triangle: center + BOTTOM + lower-LEFT
			return (center + points[3] + points[4]) / 3.0
		_:
			return center # center for built tiles


## Create a styled label for hex overlays at specified position
## font_color: the actual text color (advisor's color)
func _create_positioned_label(position: Vector2, text: String, font_color: Color, font_size: int = 22) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	# Create LabelSettings for styling - TEXT is advisor color, outline is dark
	var settings := LabelSettings.new()
	settings.font_size = font_size
	settings.font_color = font_color # Advisor's color for the text itself
	settings.outline_size = 3
	settings.outline_color = Color(0, 0, 0, 0.9) # Dark outline for contrast
	settings.shadow_size = 2
	settings.shadow_color = Color(0, 0, 0, 0.8)
	settings.shadow_offset = Vector2(1, 1)
	label.label_settings = settings

	# Store target position for adjustment after sizing
	label.set_meta("target_pos", position)
	label.resized.connect(_on_positioned_label_resized.bind(label))

	# Initial position
	label.position = position - Vector2(30, 10)

	return label


## Create a styled, centered label for hex overlays (for built tiles)
func _create_centered_label(points: Array[Vector2], text: String, outline_color: Color, font_size: int = 22) -> Label:
	var center := _calculate_center(points)
	var label := _create_positioned_label(center, text, outline_color, font_size)
	return label


func _on_positioned_label_resized(label: Label) -> void:
	if label.has_meta("target_pos"):
		var target: Vector2 = label.get_meta("target_pos")
		label.position = target - label.size / 2


# ─────────────────────────────────────────────────────────────────────────────
# SELECTED HEX
# ─────────────────────────────────────────────────────────────────────────────

func show_selected_hex(owner: Node2D, cube: Vector3i, outlines: Array) -> void:
	_clear_selected_hex()
	if outlines.is_empty():
		return
	var points: Array[Vector2] = []
	for p in outlines[0]:
		points.append(p)

	var color := Color(0.2, 0.7, 1.0, 0.9)

	var outline := Line2D.new()
	outline.width = outline_width * 1.4
	outline.default_color = color
	outline.closed = true
	outline.z_index = 18
	for p in points:
		outline.add_point(p)
	owner.add_child(outline)

	var glow := Polygon2D.new()
	glow.color = Color(color, 0.25)
	glow.z_index = 17
	glow.polygon = PackedVector2Array(points)
	owner.add_child(glow)

	_selected_overlay = {"outline": outline, "glow": glow, "cube": cube}


func clear_selected_hex() -> void:
	_clear_selected_hex()


# ─────────────────────────────────────────────────────────────────────────────
# VISIBILITY
# ─────────────────────────────────────────────────────────────────────────────

func show_visibility(owner: Node2D, entries: Array, outlines_fn: Callable, color_fn: Callable, reveal_fn: Callable) -> void:
	_clear_visibility()
	if entries.is_empty():
		return
	for entry in entries:
		if not entry.has("cube"):
			continue
		var cube_arr: Array = entry["cube"]
		if cube_arr.size() != 3:
			continue
		var cube := Vector3i(cube_arr[0], cube_arr[1], cube_arr[2])
		var cube_typed: Array[Vector3i] = [cube]
		reveal_fn.call(cube_typed)
		if not entry.has("card"):
			continue

		var outlines: Array = outlines_fn.call(cube_typed)
		if outlines.is_empty():
			continue
		var points: Array[Vector2] = []
		for point in outlines[0]:
			points.append(point)

		var color: Color = color_fn.call(entry["card"])

		var outline := Line2D.new()
		outline.width = outline_width * 0.6
		outline.default_color = color
		outline.closed = true
		outline.z_index = 8
		for point in points:
			outline.add_point(point)
		owner.add_child(outline)

		var glow := Polygon2D.new()
		glow.color = Color(color, glow_alpha * 0.8)
		glow.z_index = 3
		glow.polygon = PackedVector2Array(points)
		owner.add_child(glow)

		_visibility_nodes.append(outline)
		_visibility_nodes.append(glow)


func clear_visibility() -> void:
	_clear_visibility()


# ─────────────────────────────────────────────────────────────────────────────
# NOMINATIONS
# ─────────────────────────────────────────────────────────────────────────────

func show_nomination(owner: Node2D, role_key: String, cube: Vector3i, color: Color, outlines: Array, claimed_card: Dictionary = {}) -> void:
	_clear_nomination(role_key)
	if outlines.is_empty():
		return

	var points: Array[Vector2] = []
	for p in outlines[0]:
		points.append(p)

	# Thicker outline for nominations
	var outline := Line2D.new()
	outline.width = outline_width * 1.2
	outline.default_color = color
	outline.closed = true
	outline.z_index = 12
	for p in points:
		outline.add_point(p)
	owner.add_child(outline)

	# Glow fill
	var glow := Polygon2D.new()
	glow.color = Color(color, glow_alpha * 0.7)
	glow.z_index = 6
	glow.polygon = PackedVector2Array(points)
	owner.add_child(glow)

	# Positioned label - Industry top-right, Urbanist bottom-left
	# Show the CLAIMED card (e.g., "5♥") instead of "Industry"/"Urbanist"
	var display_text := "?"
	if not claimed_card.is_empty():
		display_text = MapLayers.label(claimed_card)
	var label_pos := _get_label_position(points, role_key)
	var label := _create_positioned_label(label_pos, display_text, color, 18)
	label.z_index = 13
	owner.add_child(label)

	_nomination_overlays[role_key] = {"cube": cube, "outline": outline, "glow": glow, "label": label}


func clear_nominations() -> void:
	_clear_nominations()


func clear_nomination(role_key: String) -> void:
	_clear_nomination(role_key)


## Persist a nomination so it won't be cleared by future show_nominations calls
## Called when Mayor builds on that tile - the winning advisor's claim stays forever
func persist_nomination(role_key: String) -> void:
	if role_key in _nomination_overlays:
		# Move from temporary to permanent storage
		_persisted_nominations[role_key + "_" + str(_nomination_overlays[role_key]["cube"])] = _nomination_overlays[role_key]
		_nomination_overlays.erase(role_key)
		print("OverlayManager: Persisted %s nomination" % role_key)


# ─────────────────────────────────────────────────────────────────────────────
# BUILT TILES
# ─────────────────────────────────────────────────────────────────────────────

func show_built(owner: Node2D, cube: Vector3i, color: Color, outlines: Array, card: Dictionary) -> void:
	_clear_built_for(cube)
	if outlines.is_empty():
		return
	var points: Array[Vector2] = []
	for p in outlines[0]:
		points.append(p)

	# Thick outline for built tiles
	var outline := Line2D.new()
	outline.width = outline_width * 1.3
	outline.default_color = color
	outline.closed = true
	outline.z_index = 14
	for p in points:
		outline.add_point(p)
	owner.add_child(outline)

	# Glow fill (more opaque than nominations to show it's permanent)
	var glow := Polygon2D.new()
	glow.color = Color(color, glow_alpha * 0.6)
	glow.z_index = 10
	glow.polygon = PackedVector2Array(points)
	owner.add_child(glow)

	# Centered label showing card info (e.g., "K♠", "Q♥")
	var card_text := MapLayers.label(card) if not card.is_empty() else "?"
	var label := _create_centered_label(points, card_text, color, 26)
	label.z_index = 15
	owner.add_child(label)

	_built_overlays[cube] = {"outline": outline, "glow": glow, "label": label}


func clear_built() -> void:
	_clear_built()


# ─────────────────────────────────────────────────────────────────────────────
# PRIVATE CLEAR FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

func _clear_selected_hex() -> void:
	if _selected_overlay.has("outline"):
		_selected_overlay["outline"].queue_free()
	if _selected_overlay.has("glow"):
		_selected_overlay["glow"].queue_free()
	_selected_overlay.clear()


func _clear_visibility() -> void:
	for node in _visibility_nodes:
		if node:
			node.queue_free()
	_visibility_nodes.clear()


func _clear_nomination(role_key: String) -> void:
	if role_key in _nomination_overlays:
		var data: Dictionary = _nomination_overlays[role_key]
		for key in ["outline", "glow", "label"]:
			if data.has(key) and data[key]:
				data[key].queue_free()
		_nomination_overlays.erase(role_key)


func _clear_nominations() -> void:
	for role_key in _nomination_overlays.keys():
		_clear_nomination(role_key)
	_nomination_overlays.clear()


func _clear_built_for(cube: Vector3i) -> void:
	if cube in _built_overlays:
		var data: Dictionary = _built_overlays[cube]
		for key in ["outline", "glow", "label"]:
			if data.has(key) and data[key]:
				data[key].queue_free()
		_built_overlays.erase(cube)


func _clear_built() -> void:
	for cube in _built_overlays.keys():
		_clear_built_for(cube)


func _clear_reality() -> void:
	for cube in _reality_overlays.keys():
		var data: Dictionary = _reality_overlays[cube]
		if data.has("label") and data["label"]:
			data["label"].queue_free()
	_reality_overlays.clear()


# ─────────────────────────────────────────────────────────────────────────────
# REALITY OVERLAY (Game Over)
# ─────────────────────────────────────────────────────────────────────────────

## Show the REALITY of a tile (actual hidden card) - displayed in top-left triangle
## Called when game ends to reveal all tiles
func show_reality(owner: Node2D, cube: Vector3i, outlines: Array, card: Dictionary) -> void:
	if cube in _reality_overlays:
		return # Already showing reality for this tile
	if outlines.is_empty() or card.is_empty():
		return

	var points: Array[Vector2] = []
	for p in outlines[0]:
		points.append(p)

	# Get color based on suit - SPADES are red (danger!), others are white
	var suit: int = card.get("suit", -1)
	var label_color := Color.WHITE
	match suit:
		MapLayers.Suit.SPADES:
			label_color = Color(1.0, 0.3, 0.3, 1.0) # Red for spades (danger)
		MapLayers.Suit.HEARTS:
			label_color = Color(1.0, 0.6, 0.8, 1.0) # Pink for hearts
		MapLayers.Suit.DIAMONDS:
			label_color = Color(0.6, 0.9, 1.0, 1.0) # Cyan for diamonds

	var label_pos := _get_label_position(points, "reality")
	var label := _create_positioned_label(label_pos, MapLayers.label(card), label_color, 16)
	label.z_index = 25 # Above everything
	owner.add_child(label)

	_reality_overlays[cube] = {"label": label}


## Show reality for all tiles (called on game over)
func reveal_all_reality(owner: Node2D, truth_layer: Dictionary, outlines_fn: Callable) -> void:
	_clear_reality()
	for cube: Vector3i in truth_layer.keys():
		var card: Dictionary = truth_layer[cube]
		if card.is_empty():
			continue
		var cube_arr: Array[Vector3i] = [cube]
		var outlines: Array = outlines_fn.call(cube_arr)
		show_reality(owner, cube, outlines, card)
	print("OverlayManager: Revealed reality for %d tiles" % truth_layer.size())
