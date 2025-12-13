# December 11, 2025 — Multiplayer Goes Live (Sort Of)

This entry documents a full-day session deploying a dedicated server to `mines.fere.me` and implementing a lobby-based multiplayer flow. The good news: it works. The bad news: we had to learn the same input handling lessons from December 9th all over again, plus discover new and exciting ways for autoloads to betray us.

## The Goal

The vision was straightforward:

1. Deploy a dedicated lobby server that coordinates matchmaking
2. Create a proper main menu with Singleplayer/Multiplayer/Settings/Quit
3. Build a lobby UI for connecting, creating rooms, and adding bots
4. Let a human player compete against remote bots through the lobby

The reality was considerably more complicated.

## Infrastructure: YSH Deployment Scripts

Before touching any game code, we needed server infrastructure. Following the pattern from the way I recently am deploying my software into cloud and beyond, we built a modular YSH/passveil deployment system:

```
deployment/
├── lib/
│   ├── config.ysh    # Declarative configuration (server IP, ports, paths)
│   ├── logging.ysh   # log(), log_error(), log_success(), log_section()
│   └── ssh.ysh       # SSH/SCP helpers, connection checking
├── dns.ysh           # Porkbun API for DNS A record management
├── build.ysh         # GitHub release download or local Godot export
├── server.ysh        # Remote server preparation, user creation, UFW
├── systemd.ysh       # Service file generation and management
└── deploy.ysh        # Thin orchestration entry point
```

The `deploy.ysh` script runs the full deployment pipeline:

```bash
./deployment/deploy.ysh
```

This idempotently:
- Verifies SSH connectivity and Porkbun credentials
- Creates DNS A record for `mines.fere.me`
- Exports the server binary (headless Linux x86_64)
- Creates the `minesweeper` user on the remote server
- Deploys the binary and systemd service
- Configures UFW firewall rules
- Starts the service

### The UFW Incident

Enabling UFW without thinking nearly took down Zulip running on the same server. The initial script only opened UDP port 7777 for the game server. HTTP (80) and HTTPS (443) were blocked.

**Lesson:** When enabling a firewall on a shared server, enumerate ALL services that need network access, not just your own.

The fix was simple but embarrassing:

```ysh
for port_proto in ("22/tcp", "80/tcp", "443/tcp") {
    ssh_exec "sudo ufw allow $port_proto"
}
```

## The Main Menu

The game previously launched directly into `World.tscn` with demo mode active. We needed a proper entry point.

### MainMenu.tscn

Created a new scene with:
- Dark gradient background
- Centered panel with title and buttons
- Singleplayer / Multiplayer / Settings / Quit options

Changed `project.godot` to launch `MainMenu.tscn` as the main scene.

### The Input Nightmare Returns

Clicking the Multiplayer button did nothing.

Sound familiar? This was the exact same problem from December 9th. CanvasLayer children don't receive GUI events reliably after viewport resize. The buttons were there, visible, clickable in theory—but `pressed` signals never fired.

The solution was the same: manual hit testing in `_input()`.

```gdscript
func _input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
        var click_pos := event.global_position
        if _try_click_button(_multiplayer_btn, click_pos, _on_multiplayer_pressed):
            get_viewport().set_input_as_handled()
            return
        # ... other buttons

func _try_click_button(btn: Button, click_pos: Vector2, callback: Callable) -> bool:
    if btn == null or not btn.visible:
        return false
    var rect := btn.get_global_rect()
    if rect.has_point(click_pos):
        callback.call()
        return true
    return false
```

We wrote this code on December 9th. We wrote it again on December 11th for MainMenu. Then we wrote it a third time for LobbyUI.

**Lesson:** Extract this into a reusable utility. Or accept that Godot's input system and this project are fundamentally incompatible.

### Background Elements Intercepting Clicks

Even with manual hit testing, buttons weren't responding. The culprit: `ColorRect` background elements had `mouse_filter = STOP` (the default), intercepting all clicks before they reached the manual hit test.

**Fix:** Set `mouse_filter = IGNORE` on all decorative background elements.

```
[node name="Background" type="ColorRect" parent="."]
mouse_filter = 2  # IGNORE
```

### LineEdit Focus Issues

Text input fields (player name, server address, port) wouldn't accept keyboard input. Clicking on them did nothing because our manual hit testing consumed the click without giving focus to the LineEdit.

**Fix:** Added explicit focus handling:

```gdscript
func _try_focus_line_edit(line_edit: LineEdit, click_pos: Vector2) -> bool:
    if line_edit == null or not line_edit.visible:
        return false
    var rect: Rect2 = line_edit.get_global_rect()
    if rect.has_point(click_pos):
        line_edit.grab_focus()
        return true  # Don't consume - let LineEdit handle cursor positioning
    return false
```

## The Autoload Timing Trap

With the UI working, clicking Multiplayer → Connect → Create Room → Add Bot × 2 would start the game. The scene transitioned to `World.tscn`. The hex grid loaded. And then... nothing. The game sat frozen on "Phase: LOBBY, Waiting for players..."

### The Problem

`DemoLauncher` is an autoload. Its `_ready()` function runs once when the game first starts—at `MainMenu.tscn`. It checks for game mode hints via `Engine.get_meta("game_mode")` and sets up accordingly.

When MainMenu calls `get_tree().change_scene_to_file("res://world.tscn")`, DemoLauncher doesn't re-initialize. It's the same instance, already past `_ready()`. The metadata we set before the scene change is never read.

### The Fix

Added public methods to DemoLauncher that MainMenu can call directly:

```gdscript
func start_multiplayer_game(deferred: bool = false) -> void:
    print("DemoLauncher: start_multiplayer_game() called (deferred=%s)" % deferred)
    role = Role.SERVER
    is_demo_mode = true
    is_singleplayer = false
    if deferred:
        call_deferred("_deferred_start_role")
    else:
        _start_role()

func _deferred_start_role() -> void:
    await get_tree().process_frame
    await get_tree().process_frame
    _start_role()
```

MainMenu now calls `demo_launcher.start_multiplayer_game(true)` before changing scenes. The `deferred=true` parameter waits two frames for the new scene to load before actually starting the game.

**Lesson:** Autoloads persist across scene changes but don't re-run initialization. If you need to trigger behavior after a scene change, provide explicit public methods and call them before/after the transition.

## Bot Timing Issues

The game would start, transition to DRAW phase, the human would reveal a card... and the bots would do nothing. Stuck on "Advisors are deciding..." forever.

### Problem 1: Signal Connection Timing

Bots connect their `phase_changed` signal handler in `_on_connected_as_bot()`:

```gdscript
gm.phase_changed.connect(_on_bot_phase_changed)
```

But by the time the bot connects and sets up this handler, the phase might have already transitioned to NOMINATE. The bot never receives the signal because it wasn't listening yet.

**Fix:** Check current phase immediately after connecting:

```gdscript
if gm:
    gm.phase_changed.connect(_on_bot_phase_changed)
    if gm.phase == 2:  # NOMINATE
        _bot_commit_nomination(gm)
```

### Problem 2: Bots Had No GameManager

`_get_game_manager()` returns `null` because bot processes are headless instances that loaded `MainMenu.tscn` (the project's main scene), not `World.tscn`. There's no GameManager in MainMenu.

**Fix:** Bots load World.tscn before connecting to the server:

```gdscript
func _start_bot(net_mgr: Node) -> void:
    var world_scene := load("res://world.tscn")
    if world_scene:
        get_tree().change_scene_to_packed(world_scene)
        await get_tree().process_frame
        await get_tree().process_frame

    net_mgr.connected_to_server.connect(_on_connected_as_bot)
    net_mgr.join_server("127.0.0.1", PORT)
```

**Lesson:** Headless bot processes are full Godot instances. They load the main scene, run autoloads, and need to be in the right scene to access game objects. Don't assume they start in a useful state.

## Camera Following the Wrong Player

The game finally started. Cards appeared. Bots committed nominations. But clicking hexes was impossible—the camera kept jumping around.

### The Problem

A debug feature in `camera_2d_drag.gd` was designed to follow remote players' cursors for spectating:

```gdscript
if _is_demo_mode() and _is_server() and not _is_singleplayer():
    _handle_demo_follow(dt)  # Follow bot cursors
```

In multiplayer mode, this was active. Every time a bot moved its simulated cursor, the Mayor's camera would lerp toward that position. Trying to click a specific hex was like trying to thread a needle on a moving train.

### The Fix

Disabled follow mode entirely for gameplay:

```gdscript
func _process(dt: float) -> void:
    if get_tree().paused:
        return
    # Always give players independent camera control
    _handle_drag()
    _handle_edge_pan(dt)
    _handle_arrow_pan(dt)
```

**Lesson:** Debug features become production bugs. If you add spectator/follow modes, gate them behind an explicit flag, not implicit mode detection.

## Random Seed

Every multiplayer game had the exact same card layout. The tiles were always revealed in the same order with the same values.

### The Problem

The server was using `DEMO_SEED = 42` for "consistency during development." Except development was over, and players were noticing that game #1 and game #47 were identical.

### The Fix

Use random seed for multiplayer, keep fixed seed only for singleplayer testing:

```gdscript
if is_singleplayer:
    gm.game_seed = DEMO_SEED
else:
    gm.game_seed = randi()
```

**Lesson:** Fixed seeds are invaluable for debugging and testing. They're terrible for actual gameplay. Switch to random seeds before anyone plays more than twice.

## The Architecture Reality Check

What we built isn't true peer-to-peer multiplayer. The architecture is:

```
┌─────────────────┐         ┌──────────────────────┐
│  Lobby Server   │◄───────►│  Client (Human)      │
│  mines.fere.me  │         │  - Connects to lobby │
│  Port 7777      │         │  - Creates room      │
└─────────────────┘         │  - Adds bots         │
                            │  - Game starts       │
                            │                      │
                            │  Local Game Server   │
                            │  Port 7779           │
                            │  ┌────────┐          │
                            │  │ Bot 1  │          │
                            │  └────────┘          │
                            │  ┌────────┐          │
                            │  │ Bot 2  │          │
                            │  └────────┘          │
                            └──────────────────────┘
```

The lobby server (`mines.fere.me:7777`) handles matchmaking only. When a game starts, the human client disconnects from the lobby, starts its own local game server on port 7779, and spawns local bot processes that connect to it.

This means:
- No actual remote players yet (just local bots)
- The "multiplayer" is really "lobby-coordinated singleplayer with extra steps"
- True P2P would require significant additional work

But it works. You can connect to a remote server, create a room, add bots, and play a game. That's more than we had this morning.

## Files Changed

| File | Purpose |
|------|---------|
| `deployment/*.ysh` | Server deployment infrastructure |
| `ui/MainMenu.tscn` | New main scene with menu buttons |
| `ui/main_menu.gd` | Manual hit testing, scene transitions |
| `ui/LobbyScene.tscn` | Lobby UI with connection/room controls |
| `ui/lobby_ui.gd` | More manual hit testing, lobby logic |
| `addons/netcode/demo_launcher.gd` | Public start methods, bot fixes |
| `addons/netcode/lobby_client.gd` | Renamed `is_connected()` to avoid conflict |
| `camera_2d_drag.gd` | Disabled spectator follow mode |
| `project.godot` | Changed main scene to MainMenu |

## What Didn't Work

1. **Trusting Godot's button signals in CanvasLayer:** Three scenes, three manual hit test implementations.

2. **Assuming autoloads re-initialize:** They don't. Scene changes keep the same instances.

3. **Implicit mode detection for camera behavior:** Debug features leaked into production.

4. **Fixed seeds for all modes:** Great for testing, terrible for replayability.

5. **Assuming bots start in the right scene:** Headless processes load the main scene like any other instance.

## Lessons Learned

### 1. Manual hit testing is not a workaround—it's the architecture

After implementing the same pattern three times, it's clear this isn't a bug to fix but a design decision to embrace. Create a utility class and use it everywhere.

### 2. Autoloads are persistent singletons

They survive scene changes. Their `_ready()` runs once. If you need per-scene initialization, use signals or explicit method calls.

### 3. Bot processes are full game instances

They have autoloads, load scenes, and need to be guided to the right state. Don't treat them as lightweight workers.

### 4. Debug features need explicit activation

A debug flag that's `true` whenever you're "not in singleplayer mode" will be true in production multiplayer. Gate debug behavior behind explicit toggles.

### 5. Random seeds should be the default

Only use fixed seeds for specific test scenarios. Real gameplay needs real randomness.

### 6. UFW on shared servers requires a full service inventory

Before enabling a firewall, list every port every service needs. Don't discover Zulip is down because you forgot 443.

## What's Next

- Implement actual remote players (P2P connections between clients)
- Persistent player names across sessions
- Room browser showing available games
- Reconnection handling for dropped connections
- UI polish for the lobby flow

The foundation is there. Players can connect to a central server, coordinate matchmaking, and play games. The fact that those games run locally with bots is an implementation detail we can fix later.

For now, `mines.fere.me` is live, the lobby works, and the hex grid is playable. That's progress.

## Closing

This session repeated the December 9th input debugging experience, added autoload timing traps, and threw in some infrastructure surprises. The pattern is clear: Godot's high-level abstractions work great until they don't, and then you're writing everything manually anyway.

But the game runs. You can invite friends to connect to your lobby, create a room, and play against bots. Is it "real" multiplayer? Architecturally, no. Experientially, close enough.

Sometimes "sort of" is good enough to ship.


