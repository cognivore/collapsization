## Represents a player's networked state.
## Contains identity, appearance, and cursor position.
class_name PlayerState
extends RefCounted

## Color palette for players - ordered for maximum contrast between adjacent indices
## Index 0 = server (unused), 1 = client 1, 2 = client 2, etc.
const PLAYER_COLORS: Array[Color] = [
	Color("#888888"),  # grey (server/unused)
	Color("#e74c3c"),  # RED - client 1
	Color("#4a9eff"),  # BLUE - client 2
	Color("#5cb85c"),  # green - client 3
	Color("#ff8c42"),  # orange - client 4
	Color("#9b59b6"),  # purple - client 5
	Color("#f1c40f"),  # yellow - client 6
	Color("#1abc9c"),  # teal - client 7
]

## Network peer ID
var peer_id: int = 0

## Whether this is the local player
var is_local: bool = false

## Player display name
var display_name: String = ""

## Player color index (into PLAYER_COLORS)
var color_index: int = 0

## Currently hovered hex in cube coordinates (invalid if no hex hovered)
var hovered_hex: Vector3i = Vector3i(0x7FFFFFFF, 0, 0)

## Signal emitted when any state changes
signal state_changed


func _init() -> void:
	# Auto-assign color based on a simple hash of time
	color_index = randi() % PLAYER_COLORS.size()


## Get the player's display color
func get_color() -> Color:
	return PLAYER_COLORS[color_index % PLAYER_COLORS.size()]


## Set color by index
func set_color_index(index: int) -> void:
	color_index = index % PLAYER_COLORS.size()
	state_changed.emit()


## Check if player is hovering a valid hex
func is_hovering() -> bool:
	return hovered_hex.x != 0x7FFFFFFF


## Set hovered hex
func set_hovered_hex(hex: Vector3i) -> void:
	if hovered_hex != hex:
		hovered_hex = hex
		state_changed.emit()


## Clear hovered hex
func clear_hovered_hex() -> void:
	hovered_hex = Vector3i(0x7FFFFFFF, 0, 0)
	state_changed.emit()


## Serialize to dictionary for network transmission
func to_dict() -> Dictionary:
	return {
		"peer_id": peer_id,
		"name": display_name,
		"color": color_index,
		"hex": [hovered_hex.x, hovered_hex.y, hovered_hex.z] if is_hovering() else null,
	}


## Update from dictionary received over network
func update_from_dict(data: Dictionary) -> void:
	if data.has("name"):
		display_name = data["name"]
	if data.has("color"):
		color_index = data["color"]
	if data.has("hex") and data["hex"] != null:
		var h: Array = data["hex"]
		hovered_hex = Vector3i(h[0], h[1], h[2])
	else:
		clear_hovered_hex()
	state_changed.emit()


## Get a descriptive string for debugging
func _to_string() -> String:
	var name_str := display_name if display_name else "Player %d" % peer_id
	var local_str := " (local)" if is_local else ""
	return "%s%s [color %d]" % [name_str, local_str, color_index]

