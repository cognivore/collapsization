# 2025-12-13: Unified Logging System

## The Problem

We had logging chaos:

1. **DebugLogger** — A static class with a global `enabled` toggle, disabled by default. Nobody remembered to enable it.
2. **InputLogger** — An autoload that logged every input event. Always on, no filtering, raw prints everywhere.
3. **NetworkLogger** — Wrote timestamped logs to files, but nobody actually read them.
4. **~115 raw `print()` calls** — Scattered across the codebase for debugging. Some were temporary, some permanent, impossible to tell which.

During the December 12th debugging session (tracking why hex clicks weren't working), we resorted to adding raw `print(">>> ...")` statements because there was no reliable way to see what was happening.

## The Solution: Unified `Log` Autoload

A single logging system with **6 categories** and **command-line control**:

```gdscript
## Categories
enum Category { INPUT, NET, GAME, UI, HEX, DEBUG }

## Usage
Log.input("Mouse clicked at %s" % pos)
Log.net("Player %d connected" % peer_id)
Log.game("Phase changed to %s" % phase_name)
Log.ui("Button pressed: %s" % btn.name)
Log.hex("Hex clicked: %s" % cube)
Log.dbg("Variable x = %d" % x)
```

### Silent by Default

In normal runs, **nothing is logged**. Clean output, no spam. This is critical for production and for multiplayer where you might have 3 instances running.

### Enable via Command Line

```bash
# Enable all categories
godot --debug-log

# Enable specific categories
godot --debug-log=INPUT,HEX

# Also write to file
godot --debug-log --debug-log-file
```

### Auto-Captures Input Events

When the INPUT category is enabled, the Log autoload automatically captures and logs:
- Mouse button events (with position, viewport size, window size)
- Key presses
- Touch events
- Window focus changes
- Viewport resize events

This is what InputLogger used to do, but now it's opt-in.

## File Output

When `--debug-log-file` is passed, logs are written to:

```
user://logs/game_2025-12-13T14-30-00.log
```

Each session gets a new file with a timestamp. **No log rotation** — we just create timestamped files. Clean them up manually if needed.

The file format:

```
=== Log started at 2025-12-13T14-30-00 ===
Godot 4.5.1.stable

[14:30:01.234][INPUT] Viewport size = (1920, 1080), Window size = (1376, 860)
[14:30:02.567][GAME] GameBus: start_game() with params={mode: singleplayer}
[14:30:03.890][NET] ENetTransport: Server started on port 7779
```

## Migration from Old Loggers

### DebugLogger

Still exists as a simple static class for backwards compatibility:

```gdscript
DebugLogger.log("message")  # Only prints if DebugLogger.enabled = true
```

The F3 key in-game still toggles `DebugLogger.enabled` for the visual debug panel. But for serious debugging, use `--debug-log=DEBUG`.

### InputLogger

**Deleted.** Use `Log.input()` or run with `--debug-log=INPUT`.

### NetworkLogger

Simplified to a thin wrapper. The old file rotation code is gone. Use `--debug-log=NET --debug-log-file` instead.

### Raw print() calls

Replaced with appropriate category calls:
- Network stuff → `Log.net()`
- Game logic → `Log.game()`
- UI events → `Log.ui()`
- Hex/map operations → `Log.hex()`

## Developer Scripts Updated

Both restart scripts now support debug flags:

```bash
# Normal run (silent)
./single_player_restart.sh

# With input logging
./single_player_restart.sh --debug-log=INPUT

# Full debug mode
./single_player_restart.sh --debug-log
```

## The Architecture

```
Log (autoload)
  ├── _parse_command_line() — reads --debug-log flags
  ├── _input() — auto-captures input events when INPUT enabled
  ├── _log(category, message) — formats and outputs
  │     ├── print() to console
  │     └── _file_output.store_line() if --debug-log-file
  └── Category methods
        ├── input(msg)
        ├── net(msg)
        ├── game(msg)
        ├── ui(msg)
        ├── hex(msg)
        └── dbg(msg)
```

## Lessons Learned

1. **Silent by default is essential** — Logging should be opt-in for production. The old InputLogger spamming every mouse move was a mistake.

2. **Categories matter** — When debugging networking, you don't want to see input events. When debugging input, you don't want to see game state changes. Filtering is key.

3. **Command-line is better than code toggles** — `DebugLogger.enabled = true` required editing code. `--debug-log=INPUT` works from any terminal.

4. **Timestamped files, not rotation** — Log rotation adds complexity. For a game that runs in sessions, just create a new file per session and let the user clean up old ones.

## Test Results

After the migration, all 93 tests pass. The unified logger doesn't break any existing functionality.

```
Scripts               9
Tests                93
Passing Tests        93
Asserts             357
Time              2.226s
---- All tests passed! ----
```

