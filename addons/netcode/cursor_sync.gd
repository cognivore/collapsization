## Synchronizes cursor/hover positions across the network.
## Attach to the hex field to enable multiplayer cursor visibility.
class_name CursorSync
extends Node

## Emitted when a remote player's cursor position changes
signal remote_cursor_updated(player_id: int, hex: Vector3i)

## Emitted when a remote player disconnects
signal remote_cursor_removed(player_id: int)

## How often to send cursor updates (seconds)
@export var sync_rate: float = 0.05 # 20 updates per second

## Reference to the hex tilemap layer
@export var hex_field: HexagonTileMapLayer

var _sync_timer: float = 0.0
var _last_sent_hex: Vector3i = Vector3i(0x7FFFFFFF, 0, 0)


func _ready() -> void:
	# Auto-find hex field if not set
	if hex_field == null:
		hex_field = _find_hex_field()

	# Connect to NetworkManager signals
	_connect_network_signals.call_deferred()


func _connect_network_signals() -> void:
	var net_mgr := _get_network_manager()
	if net_mgr:
		net_mgr.player_left.connect(_on_player_left)


func _get_network_manager() -> Node:
	if has_node("/root/NetworkManager"):
		return get_node("/root/NetworkManager")
	return null


func _process(delta: float) -> void:
	if not _is_networked():
		return

	_sync_timer += delta
	if _sync_timer >= sync_rate:
		_sync_timer = 0.0
		_send_cursor_update()

	# Update remote cursors from player states
	_update_remote_cursors()


func _is_networked() -> bool:
	var net_mgr := _get_network_manager()
	return net_mgr and net_mgr.is_networked()


func _find_hex_field() -> HexagonTileMapLayer:
	# Try to find hex field in parent tree
	var parent := get_parent()
	while parent:
		if parent is HexagonTileMapLayer:
			return parent
		for child in parent.get_children():
			if child is HexagonTileMapLayer:
				return child
		parent = parent.get_parent()
	return null


func _send_cursor_update() -> void:
	if hex_field == null:
		return

	var net_mgr := _get_network_manager()
	if net_mgr == null or net_mgr.local_player == null:
		return

	# Get current hovered hex
	var current_hex := _get_hovered_hex()

	# Only send if changed
	if current_hex != _last_sent_hex:
		_last_sent_hex = current_hex
		net_mgr.local_player.hovered_hex = current_hex

		# Log local cursor update
		_log_cursor_update(net_mgr.local_player.peer_id, current_hex, true)

		var data: Dictionary
		if current_hex.x != 0x7FFFFFFF:
			data = {"hex": [current_hex.x, current_hex.y, current_hex.z]}
		else:
			data = {"hex": null}

		net_mgr.broadcast_message(
			net_mgr.MessageType.CURSOR_UPDATE,
			data,
			false # Unreliable for cursor updates (high frequency)
		)


func _get_hovered_hex() -> Vector3i:
	# In demo mode, cursor is set by CursorSimulator directly into local_player.hovered_hex
	# So we just return what's already there (don't read from real mouse)
	if _is_demo_mode():
		var net_mgr := _get_network_manager()
		if net_mgr and net_mgr.local_player:
			return net_mgr.local_player.hovered_hex
		return Vector3i(0x7FFFFFFF, 0, 0)

	# Normal mode: use real mouse position
	if hex_field == null:
		return Vector3i(0x7FFFFFFF, 0, 0)

	var mouse_pos := hex_field.get_local_mouse_position()
	var hovered := hex_field.get_closest_cell_from_local(mouse_pos)

	# Check if hex exists in the field
	var map_pos := hex_field.cube_to_map(hovered)
	if hex_field.get_cell_source_id(map_pos) == -1:
		return Vector3i(0x7FFFFFFF, 0, 0)

	return hovered


func _is_demo_mode() -> bool:
	if has_node("/root/DemoLauncher"):
		return get_node("/root/DemoLauncher").is_demo_mode
	return false


func _log_cursor_update(player_id: int, hex: Vector3i, is_local: bool) -> void:
	var source := "local" if is_local else "remote"
	Log.net("CURSOR [%s] player=%d hex=(%d,%d,%d)" % [source, player_id, hex.x, hex.y, hex.z])


func _update_remote_cursors() -> void:
	var net_mgr := _get_network_manager()
	if net_mgr == null:
		return

	for player in net_mgr.get_remote_players():
		# Log remote cursor updates (only when hex is valid and changed)
		if player.is_hovering():
			_log_cursor_update(player.peer_id, player.hovered_hex, false)
		remote_cursor_updated.emit(player.peer_id, player.hovered_hex)


func _on_player_left(player_id: int) -> void:
	remote_cursor_removed.emit(player_id)


## Get all remote player cursors for rendering
func get_remote_cursors() -> Array[Dictionary]:
	var cursors: Array[Dictionary] = []

	if not _is_networked():
		return cursors

	var net_mgr := _get_network_manager()
	if net_mgr == null:
		return cursors

	for player in net_mgr.get_remote_players():
		if player.is_hovering():
			cursors.append({
				"hex": player.hovered_hex,
				"color": player.get_color(),
				"player_id": player.peer_id,
			})

	return cursors
