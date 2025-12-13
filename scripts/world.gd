## World scene root - notifies GameBus when ready for proper scene transition handshakes.
extends Node2D


func _ready() -> void:
	# Notify GameBus that the World scene is ready
	var game_bus := _get_game_bus()
	if game_bus:
		game_bus.notify_scene_ready(self)
		Log.game("World: Notified GameBus that scene is ready")


func _get_game_bus() -> Node:
	if has_node("/root/GameBus"):
		return get_node("/root/GameBus")
	return null


