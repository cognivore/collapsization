# December 9, 2025 — Input Debugging: A Cautionary Tale

This entry documents a multi-hour debugging session that exposed fundamental problems with Godot's input event propagation when CanvasLayer UI overlays interact with TileMap-based game content. It was a frustrating experience where nothing worked until we bypassed the expected architecture entirely.

## The symptoms

In single-player mode (Mayor vs. 2 bot advisors), several critical features broke simultaneously:

- HUD debug outline showed the wrong rectangle around the card panel
- Mouse clicks on the hex field weren't registering
- SPACE key stopped centering the camera view
- Card selection worked via keyboard but not mouse
- The REVEAL, BUILD, and tile selection workflows were completely non-functional

## What we discovered

### Problem 1: Aerospace window manager resizes

The tiling window manager (Aerospace on macOS) resizes the game window after Godot initializes. The viewport started at `(1152, 648)` but was immediately resized to `(3440, 2772)`. UI elements positioned with anchors inside a CanvasLayer did not reposition correctly because:

- CanvasLayer children don't automatically track viewport size
- Control nodes inside CanvasLayer need a parent Control that fills the viewport
- Anchors are relative to parent size, which was `(0, 0)` for direct CanvasLayer children

**Fix**: Added a `UIRoot` Control node as a direct child of the CanvasLayer, then connected to `viewport.size_changed` to manually resize `UIRoot` to match the viewport. All UI elements are now children of UIRoot and anchor correctly.

### Problem 2: Mouse coordinates in physical pixels

On Retina displays, mouse event positions are reported in physical pixels while the viewport operates in logical pixels. Clicks at position `(1783, 2731)` were way outside the logical viewport bounds of `(1152, 648)`. After the resize fix, coordinates aligned but a new problem emerged.

### Problem 3: GUI events not reaching buttons

Even with correct coordinates, Button nodes inside the CanvasLayer weren't receiving `gui_input` events. The `pressed` signal never fired. We confirmed:

- Buttons had `mouse_filter = MOUSE_FILTER_STOP`
- Buttons were visible and not disabled
- Click positions were geometrically within button bounds

The root cause remains unclear—likely a quirk of how CanvasLayer interacts with the GUI event system when the viewport has been resized dynamically.

**Fix**: Implemented manual hit testing in `_input()`. Instead of relying on Godot's GUI event propagation, we check if click positions fall within button rectangles and call the handlers directly.

```gdscript
func _try_click_card_button(click_pos: Vector2) -> bool:
    for i in range(_card_buttons.size()):
        var btn: Button = _card_buttons[i]
        var rect := Rect2(btn.global_position, btn.size)
        if rect.has_point(click_pos):
            _on_card_button_pressed(i)
            return true
    # ... also check action buttons (REVEAL, COMMIT, BUILD)
    return false
```

### Problem 4: Tile clicks not reaching HexField

`_unhandled_input` on HexField received `pressed=false` events but never `pressed=true`. Despite not calling `set_input_as_handled()` when no button was hit, the press events vanished somewhere in the event chain.

**Fix**: Bypassed `_unhandled_input` entirely. When a click is outside the HUD area, GameHud now calls `HexField.handle_external_click()` directly:

```gdscript
if not _is_click_in_hud_area(mb.position):
    if _hex_field and _hex_field.has_method("handle_external_click"):
        _hex_field.handle_external_click()
```

### Problem 5: Card button focus stealing SPACE key

Card buttons had `focus_mode = FOCUS_ALL`, so when focused, pressing SPACE activated the button instead of resetting the camera.

**Fix**: Changed to `focus_mode = FOCUS_CLICK` so buttons only receive focus from explicit mouse clicks, not keyboard navigation.

## Files changed

- `scripts/game_hud.gd`: Added UIRoot resize handling, manual hit testing, HUD bounds checking, direct HexField click forwarding
- `hex_field.gd`: Added `handle_external_click()` public method, fixed nomination marker z-index
- `ui/GameHud.tscn`: Added UIRoot Control node as parent for all UI elements
- `scripts/input_logger.gd`: Enhanced logging with viewport size tracking
- `single_player_restart.sh`: Created for quick game restarts during debugging

## What we tried that didn't work

1. **Trusting Godot's event propagation**: GUI events simply don't reach CanvasLayer children reliably after dynamic viewport resizes.

2. **Setting `mouse_filter` correctly**: Even with proper values, events weren't delivered.

3. **Relying on `_unhandled_input`**: Press events disappeared before reaching it.

4. **Debugging with logs alone**: We needed visual debug overlays showing actual button positions and click coordinates to understand the mismatch.

5. **Assuming coordinate systems match**: Physical vs. logical pixels, screen vs. viewport vs. world coordinates—every conversion was a potential bug.

## Lessons learned

### 1. Don't trust implicit behavior with CanvasLayer

CanvasLayer is an overlay, not a proper scene tree participant for GUI purposes. If you need reliable input handling for UI that floats over game content, consider:

- Manual hit testing (what we did)
- SubViewport with its own input handling
- Moving UI to the main scene tree with z-index layering

### 2. Window manager integration breaks assumptions

Tiling window managers resize windows after Godot initializes. Always:

- Connect to `viewport.size_changed`
- Test with window resizing during gameplay
- Log viewport dimensions alongside mouse coordinates

### 3. Visual debugging is essential

Text logs weren't enough. We added:

- Click position indicators (red squares)
- Debug overlay with real-time coordinate display
- Button position logging after layout updates

Without these, we couldn't correlate click positions with UI element bounds.

### 4. Bypass broken abstractions

When the engine's event system fails, don't fight it. Direct function calls are:

- More predictable
- Easier to debug
- Less dependent on undocumented behavior

We wasted hours trying to make `_unhandled_input` work when a two-line direct call solved the problem instantly.

### 5. Retina/HiDPI is a coordinate nightmare

Mouse positions, viewport sizes, window sizes, and content scale can all use different units. Test on high-DPI displays early and log everything with context.

### 6. Test incrementally with visual feedback

The breakthrough came when we added logging like:

```
CardButton[0] global_pos=(1569.0, 2606.0) size=(90.0, 120.0)
Click at (1609.0, 2591.0) -> hit CardButton[0]
```

This immediately showed whether clicks were in bounds.

## Architecture takeaways

For future projects with floating HUD over game content:

1. Create a full-viewport Control as the HUD root
2. Resize it explicitly on viewport changes
3. Implement manual hit testing as the primary input path
4. Use `_input()` not `_unhandled_input()` for UI
5. Forward non-UI clicks explicitly to game objects
6. Add comprehensive visual debugging from day one

## The cost

This debugging session took approximately 4+ hours and involved:

- ~30 game restarts
- Multiple failed hypotheses about coordinate systems
- Extensive logging infrastructure that should have existed from the start
- Final solution that completely bypasses Godot's recommended input architecture

The lesson is stark: Godot's input system works well for standard scenes, but CanvasLayer + dynamic viewports + external window management creates a pathological case. When you hit that wall, stop trying to fix the engine and route around it.

## What finally worked

The complete solution:

1. UIRoot Control fills viewport, resizes on `size_changed`
2. Manual hit testing for all buttons in `_input()`
3. `_is_click_in_hud_area()` determines if click is in UI region
4. Direct `handle_external_click()` call for tile selection
5. Consume events explicitly after handling

The game flow now works: card selection, REVEAL, tile selection, BUILD all function correctly. The fix is ugly but reliable.

## Closing

Sometimes the "right" architecture isn't the one the engine suggests. When input events vanish into the void, extensive debugging infrastructure and willingness to bypass broken systems is the only path forward. Document what failed, implement what works, and move on.

The hex grid still looks pretty, though.

