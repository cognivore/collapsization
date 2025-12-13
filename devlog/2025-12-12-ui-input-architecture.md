# 2025-12-12: UI Architecture Overhaul — The CanvasLayer Conundrum

## Summary

Complete rewrite of the UI rendering and input architecture. Converted GameHud from extending `CanvasLayer` to `Control`, wrapped it in a proper `CanvasLayer` node, added content scaling, created a signal-based scene transition system (`GameBus`), built a full MainMenu and Lobby UI, and discovered a fundamental Godot input propagation bug when Controls are inside CanvasLayers.

## The Problem(s)

After the December 10th refactoring and December 11th multiplayer implementation, we had a mess:

1. **UI was positioned in world space** — GameHud as a direct child of World (Node2D) meant it moved with the camera
2. **Button clicks weren't registering** — Manual hit-testing code was brittle and broke with content scaling
3. **Scene transitions were hacky** — `Engine.set_meta("game_mode", ...)` and frame delays everywhere
4. **No content scaling** — UI broke at different window sizes

## The Plan

Follow the "proper Godot way":
1. Add content scaling (`canvas_items` mode, 1920x1080, `keep` aspect)
2. Convert GameHud from `extends CanvasLayer` to `extends Control`
3. Remove all manual hit-testing, use Godot's native signal system
4. Create `GameBus` autoload for signal-based scene handshakes
5. Wrap GameHud in a `CanvasLayer` node to keep it fixed to screen

## What We Built

### GameBus — Signal-Based Scene Transitions

```gdscript
## GameBus - Signal bus for scene transitions and game state handshakes.
extends Node

signal request_start_game(params: Dictionary)
signal scene_ready(root: Node)

var last_params: Dictionary = {}

func start_game(params: Dictionary) -> void:
    last_params = params
    request_start_game.emit(params)

func notify_scene_ready(root: Node) -> void:
    scene_ready.emit(root)
```

No more `Engine.set_meta()` timing hacks. MainMenu calls `GameBus.start_game()`, DemoLauncher listens for the signal, World.gd calls `GameBus.notify_scene_ready()` in its `_ready()`, and everything synchronizes cleanly.

### New Scene Structure

```
World (Node2D)
  ├── HexField (TileMapLayer)
  ├── CursorSync (Node)
  ├── GameManager (Node)
  ├── HudLayer (CanvasLayer, layer=10)  # NEW
  │   └── GameHud (Control)             # Changed from CanvasLayer
  └── Camera2D
```

### Content Scaling

```ini
[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/stretch/mode="canvas_items"
window/stretch/aspect="keep"
```

This ensures the UI scales correctly and maintains 16:9 with letterboxing.

### MainMenu and Lobby UI

Built a complete MainMenu (`ui/MainMenu.tscn`, `ui/main_menu.gd`) and Lobby system (`ui/LobbyScene.tscn`, `ui/lobby_ui.gd`) with:
- Proper `mouse_filter` settings (PASS for containers, STOP for buttons, IGNORE for decorative elements)
- Direct signal connections in `_ready()`
- Integration with GameBus for scene transitions

## The Bug We Discovered

After implementing everything "the Godot way," **BUILD phase hex clicks didn't work**.

### Symptoms
- Card button clicks worked fine ✓
- Menu button clicks worked fine ✓
- Clicking on hexes in the game world → nothing happened ✗
- Pressing B key to build → nothing happened ✗

### Debugging Session

Added instrumentation to trace input events:

```
GameHud._input: click at pos=(992, 540), card_buttons=3
  card[0] hit_test: ... hit=false
  card[1] hit_test: ... hit=false
  card[2] hit_test: ... hit=false
INPUT[443]: MouseButton button=1 pressed=true pos=(992, 540)
INPUT[445]: MouseButton button=1 pressed=false pos=(992, 540)
>>> HexField._unhandled_input: LEFT click pressed=false pos=(992, 540)
```

Notice: **`pressed=true` never reaches `_unhandled_input`!** Only `pressed=false` propagates.

### Root Cause

When a `Control` node is inside a `CanvasLayer`, Godot's input event propagation breaks:

1. `_input()` callbacks run on all nodes (including GameHud)
2. If no node calls `set_input_as_handled()`, events should propagate to `_unhandled_input()`
3. **BUT** — `pressed=true` events are being consumed somewhere in Godot's GUI system
4. `pressed=false` events propagate normally

This appears to be a bug or undocumented behavior in Godot 4.5 when using Controls inside CanvasLayers with content scaling.

### The Fix

Instead of relying on `_unhandled_input()` to receive hex clicks, GameHud now routes clicks directly:

```gdscript
func _input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
        # ... check UI elements ...

        # No UI element hit - route click to hex field directly
        # (Godot's _unhandled_input doesn't receive pressed=true events reliably
        # when GameHud is inside a CanvasLayer)
        if _hex_field and _hex_field.has_method("handle_external_click"):
            _hex_field.handle_external_click()
            get_viewport().set_input_as_handled()
```

This is essentially what the pre-refactor architecture did, but now it's intentional and documented.

## Files Changed

| File | Change |
|------|--------|
| `project.godot` | Added content scaling, GameBus autoload |
| `scripts/game_bus.gd` | **NEW** — Signal bus for scene transitions |
| `scripts/world.gd` | **NEW** — Notifies GameBus when World ready |
| `World.tscn` | Wrapped GameHud in HudLayer CanvasLayer |
| `scripts/game_hud.gd` | Changed from CanvasLayer to Control, added direct hex click routing |
| `ui/GameHud.tscn` | Restructured for Control-based layout |
| `ui/MainMenu.tscn` | **NEW** — Main menu scene |
| `ui/main_menu.gd` | **NEW** — Main menu script with manual click detection |
| `ui/LobbyScene.tscn` | **NEW** — Multiplayer lobby scene |
| `ui/lobby_ui.gd` | **NEW** — Lobby UI with room management |
| `tests/e2e/test_main_menu.gd` | **NEW** — 12 regression tests for menu buttons |

## Lessons Learned

1. **Godot's input system has edge cases** — Don't assume `_unhandled_input` will receive events just because no one called `set_input_as_handled()`. CanvasLayers complicate things.

2. **The "Godot way" doesn't always work** — We tried to do everything properly (signals, mouse_filter, no manual hit-testing), but had to fall back to manual click routing for hex clicks.

3. **Content scaling affects everything** — When viewport coordinates don't match window coordinates, every piece of input handling needs to account for the transform.

4. **Instrumentation is essential** — We would never have found the `pressed=true` vs `pressed=false` discrepancy without logging every input event and comparing what reached different handlers.

5. **Test the happy path thoroughly** — Our automated tests caught signal connections and rect validity, but not the actual click→hex selection flow.

## Test Results

```
Scripts               8
Tests                88
Passing Tests        88
Asserts             337
Time              2.125s
---- All tests passed! ----
```

## What Works Now

- ✓ Main Menu buttons (Singleplayer, Multiplayer, Settings, Quit)
- ✓ Lobby UI (Connect, Create Room, Add Bot, Start Game)
- ✓ Card selection in all phases
- ✓ Hex selection in BUILD phase
- ✓ Build action (click card + click hex + press B or click BUILD)
- ✓ Window resizing with proper scaling
- ✓ Multiplayer with remote lobby server

## The Architecture After

```
MainMenu (Control)
    ↓ button press
GameBus.start_game({mode: "multiplayer"})
    ↓ signal
DemoLauncher receives request_start_game
    ↓ change scene
World._ready() → GameBus.notify_scene_ready(self)
    ↓ signal
DemoLauncher receives scene_ready
    ↓ start game logic
GameManager starts, GameHud updates
    ↓ click on hex
GameHud._input() → HexField.handle_external_click()
    ↓ hex_clicked signal
GameHud._on_hex_clicked(cube)
    ↓ select hex, enable BUILD
```

Clean signal chains, no timing hacks, predictable behavior.

