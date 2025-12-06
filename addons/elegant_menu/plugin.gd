@tool
extends EditorPlugin


func _enter_tree() -> void:
	add_autoload_singleton("GameMenu", "res://addons/elegant_menu/game_menu.tscn")


func _exit_tree() -> void:
	remove_autoload_singleton("GameMenu")

