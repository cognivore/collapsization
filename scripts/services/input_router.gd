## Centralized click routing between HUD and world nodes.
## Keeps CanvasLayer input from starving gameplay clicks.
extends Node
class_name InputRouter

## Route a mouse button event to HUD or world depending on hit test.
## hud_root: Control defining HUD bounds
## hud_handler/world_handler: Callable
func route_mouse_event(event: InputEvent, hud_root: Control, hud_handler: Callable, world_handler: Callable) -> void:
	if not (event is InputEventMouseButton):
		return

	if hud_root and _is_in_hud(event.position, hud_root):
		if hud_handler:
			hud_handler.call(event)
	else:
		if world_handler:
			world_handler.call(event)


func _is_in_hud(screen_pos: Vector2, hud_root: Control) -> bool:
	if hud_root == null:
		return false
	var rect := hud_root.get_global_rect()
	return rect.has_point(screen_pos)

