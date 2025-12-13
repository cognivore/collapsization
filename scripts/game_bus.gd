## GameBus - Signal bus for scene transitions and game state handshakes.
## Replaces Engine.set_meta() timing hacks with proper signal-based synchronization.
extends Node

## Emitted when a game start is requested (from MainMenu or Lobby).
## Listeners (like DemoLauncher) should prepare for the upcoming scene change.
signal request_start_game(params: Dictionary)

## Emitted when a scene has finished loading and is ready.
## Params: root - the root node of the newly loaded scene.
signal scene_ready(root: Node)

## Stores the last game start parameters for late-connecting listeners.
var last_params: Dictionary = {}


## Request to start a game with the given parameters.
## Call this before changing scenes.
## @param params Dictionary with keys like "mode" ("singleplayer" or "multiplayer"),
##               "player_name", "lobby_addr", "lobby_port", etc.
func start_game(params: Dictionary) -> void:
	last_params = params
	Log.game("GameBus: start_game() with params=%s" % params)
	request_start_game.emit(params)


## Notify that a scene is ready. Call this from the new scene's _ready().
## @param root The root node of the scene (usually `self` or `get_tree().current_scene`).
func notify_scene_ready(root: Node) -> void:
	Log.game("GameBus: scene_ready() for %s" % root.name)
	scene_ready.emit(root)


## Clear stored parameters (e.g., after game ends or returns to menu).
func clear_params() -> void:
	last_params = {}


