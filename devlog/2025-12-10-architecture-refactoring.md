# Architecture Refactoring: From Monoliths to Modules

**Date:** December 10, 2025
**Initial Commit:** e8a73aa
**Files changed:** 18 (+2142 / -783 lines)

**Follow-up Session:** Same day
**Additional changes:** 17 files (+544 / -314 lines)
**Test coverage:** 76 tests across 7 test scripts

## The Problem

We had reached a critical inflection point. Three scripts had grown into unmanageable monoliths:

- `game_manager.gd` — 870+ lines handling phases, scoring, networking, fog, and state
- `game_hud.gd` — 800+ lines mixing input routing, UI updates, and debug overlays
- `hex_field.gd` — 700+ lines combining tile rendering, overlays, fog, and click handling

Every attempt to implement new game rules resulted in a debugging nightmare. Want to add advisor claims to nominations? Touch 5 different sections of `game_manager.gd`. Want to fix a button state bug? Navigate through 400 lines of interleaved UI logic. The architecture had become the bottleneck.

## The Decomposition

### Phase Handlers

The game has four phases: DRAW, NOMINATE, PLACE, GAME_OVER. Each phase has distinct logic that was scattered across `_transition_to()`, signal handlers, and validation functions. We extracted:

```
scripts/game/phases/
├── draw_phase.gd      # Card dealing, reveal action
├── nominate_phase.gd  # Advisor commits, transition logic
└── place_phase.gd     # Mayor placement, scoring trigger
```

Each phase handler encapsulates entry conditions, valid actions, and exit transitions. The main `GameManager` now delegates to these handlers rather than containing massive switch statements.

**Addressed:** Phase handlers are now wired in. `GameManager._init_phase_handlers()` instantiates `DrawPhase`, `NominatePhase`, and `PlacePhase` into a `_phase_handlers` dictionary. The `_transition_to()` method calls `_phase_handlers[phase].enter(self)` for phase entry. Public action methods (`reveal_card`, `commit_nomination`, `place_card`) delegate to the respective handler's methods. Unit tests (`test_draw_phase_resets_nominations`, `test_commit_uses_claim_and_waits_for_both`, `test_place_phase_marks_built_and_scores`) verify that phase transitions and state mutations work through the handlers.

**Accepted trade-off:** The phase handlers receive the full `GameManager` reference and call back into it (`gm._reset_nominations_state()`, `gm._transition_to()`, etc.), creating bidirectional coupling. A cleaner design would have handlers return commands/events that `GameManager` interprets, but that's a larger refactor. The current approach works and is tested—we're accepting pragmatic coupling over architectural purity.

### Field Overlay Manager

Hex overlays were the messiest part of `hex_field.gd`. Selection highlights, nomination borders, built tile markers, fog meshes, and reality labels all competed for the same rendering code. We created:

```
scripts/field/
├── overlay_manager.gd  # All hex visual overlays
└── fog_controller.gd   # Fog-of-war mesh generation/reveal
```

The overlay manager now owns:
- Selection highlights (local and remote players)
- Nomination overlays with claim labels
- Built tile markers with card display
- Reality labels (revealed at game over)
- Proper z-index layering for all elements

**Addressed:** We added `show_nomination_for_cube()` which accepts a cube coordinate and `Callable` references for color and outline computation. This shifts responsibility: `hex_field.gd` passes `_nomination_color` and `cube_outlines` callables, and `FieldOverlayManager` calls them internally. The coupling is now via interface (callables) rather than precomputed data.

A subtle bug was caught here: GDScript's typed arrays are strict, so passing `[cube]` (untyped `Array`) to a callable expecting `Array[Vector3i]` caused runtime errors. Fixed by explicitly typing: `var cube_arr: Array[Vector3i] = [cube]`. Regression test `test_nomination_overlay_renders_without_type_error` exercises this path.

**Now tested:** Triangle math and label positioning now have unit tests in `tests/unit/test_overlay_manager.gd`:
- `test_calculate_center_regular_hex` — verifies center calculation
- `test_get_label_position_industry/urbanist/reality` — verifies triangle centroids for each role
- `test_label_positions_are_distinct` — ensures labels don't overlap

The `calculate_center()` and `get_label_position()` methods were made public for testability. Total: 8 overlay tests.

### Service Layer

Input handling was a disaster. Mouse clicks could target the HUD or the game world, but the routing logic was duplicated and buggy.

```
scripts/ui/
└── action_panel.gd  # Button state management
```

**Addressed:** Input routing is now functional via a simpler inline solution. The root bug was that `_ui_root.size = vp_size` made `UIRoot` cover the entire viewport, so every click was swallowed by the HUD handler, preventing hex selection entirely.

The fix: `game_hud.gd` now holds explicit references to `_top_panel` and `_bottom_panel`, and `_is_click_on_hud_panels()` checks whether the click falls within either panel's `get_global_rect()`. Clicks outside these regions route to `_handle_world_mouse_button()`, which calls `_hex_field.handle_external_click()`. Regression test `test_hud_click_routing_allows_world_clicks` verifies that center-screen clicks are NOT captured by HUD panels.

**Cleaned up:** The `InputRouter` class was deleted entirely. It was instantiated but never called—dead code from an abandoned approach. The inline `_is_click_on_hud_panels()` is simpler and actually works.

**Now tested:** `ActionPanel.compute_state()` has 14 unit tests in `tests/unit/test_action_panel.gd`:
- Mayor DRAW phase: REVEAL visible, BUILD hidden
- Mayor PLACE phase: BUILD enabled with card+hex selected
- Advisor NOMINATE phase: COMMIT visible with hex selected
- Edge cases: disabled states, action card visibility

### Debug Infrastructure

Debug overlays were hardcoded into `game_hud.gd`. We extracted a reusable component:

```
scripts/debug/
├── debug_hud.gd     # Configurable debug overlay panel
└── debug_logger.gd  # Centralized logging with global toggle
```

**Fully addressed:** A new `DebugLogger` singleton provides project-wide log control:

```gdscript
class_name DebugLogger
static var enabled: bool = false

static func log(msg: String) -> void:
    if enabled: print(msg)
```

All verbose output now routes through `DebugLogger.log()`:
- `hex_field.gd` — 24 print statements converted
- `game_manager.gd` — 13 print statements converted

The F3 key toggles `DebugLogger.enabled` alongside the debug panel visibility. Production builds are now silent by default.

### Network Protocol

Serialization for nominations and placements was inline in `GameManager`. We created:

```
scripts/game/
└── game_protocol.gd  # Network serialization helpers
```

**Fully addressed:** `GameProtocol` now provides comprehensive serialization AND validation:

Serialization helpers:
- `serialize_nominations()` / `deserialize_nominations()`
- `serialize_placement()` / `deserialize_placement()`
- `serialize_built_hexes()` / `deserialize_built_hexes()`
- `serialize_hand_for_role()`, `serialize_visibility_entry()`

Validation helpers (new):
- `validate_card()` — checks suit and rank fields
- `validate_serialized_nomination()` — validates hex array and claim
- `validate_serialized_placement()` — validates cube array and card
- `validate_role()` — checks role is 0/1/2

**Now tested:** 16 protocol tests including round-trip verification:
- `test_nominations_round_trip` — serialize → deserialize → compare
- `test_placement_round_trip` — full cycle with turn, card, cube
- `test_built_hexes_round_trip` — Array[Vector3i] preservation
- Validation tests for malformed payloads

## The Bug Hunt

The initial refactoring introduced two critical bugs that broke the game entirely:

### Bug 1: Typed Array Mismatch

**Symptom:** Nomination overlays disappeared. No visual feedback when advisors committed.

**Root cause:** `show_nomination_for_cube()` passed `[cube]` to a callable expecting `Array[Vector3i]`. GDScript's typed arrays are strict—the untyped `Array` literal failed at runtime.

**Fix:** Explicit typing: `var cube_arr: Array[Vector3i] = [cube]`

**Test:** `test_nomination_overlay_renders_without_type_error`

### Bug 2: Full-Screen HUD Capture

**Symptom:** Clicking hexes did nothing. BUILD phase completely broken.

**Root cause:** `_ui_root.size = vp_size` made the Control cover the entire viewport. The `_is_in_hud()` check always returned true, so every click was captured by the HUD handler and never reached `handle_external_click()`.

**Fix:** Check against actual visible panels (`_top_panel`, `_bottom_panel`) instead of the full-screen UIRoot.

**Test:** `test_hud_click_routing_allows_world_clicks`

These bugs highlighted a critical gap: our unit tests created `GameManager` with minimal stubs, never exercising the real `HexField` overlay code or HUD click routing. The E2E tests now include regression coverage for these integration points.

## The Nomination Data Model

The old model stored nominations as simple hex coordinates:

```gdscript
# Old
nominations = {"industry": Vector3i(1, -1, 0), "urbanist": Vector3i(0, 1, -1)}
```

This couldn't represent what advisors *claimed* about tiles. The new model:

```gdscript
# New
nominations = {
    "industry": {
        "hex": Vector3i(1, -1, 0),
        "claim": {"suit": 2, "value": 11, "rank": "J"}  # "J♠"
    },
    "urbanist": {
        "hex": Vector3i(0, 1, -1),
        "claim": {"suit": 0, "value": 13, "rank": "Q"}  # "Q♥"
    }
}
```

This enables the core gameplay mechanic: advisors can *lie* about what's on a tile. The claim is what they tell the Mayor; the reality may be different.

## The Scoring Algorithm

The original scoring was broken — it gave points based on card values without considering suit matching or advisor honesty. The correct algorithm:

```
distance(placed_card, reality) = |value_diff| + (suit_mismatch ? 1 : 0)
```

Where:
- `value_diff` is the absolute difference between the placed card's value and the tile's reality
- `suit_mismatch` adds 1 if the suits differ
- Queen (13) outranks King (12) in our game

The Mayor scores only if they chose the hex with minimal distance. When both advisors nominate the same hex, the winner is determined by the placed card's suit (Diamonds → Industry wins, Hearts → Urbanist wins).

## The Bot AI Matrix

Bots needed to make strategic decisions based on what card the Mayor revealed:

| Revealed Suit | Urbanist Strategy | Industry Strategy |
|--------------|------------------|-------------------|
| SPADES | Best heart (honest) | Best diamond (honest) |
| HEARTS | Best heart (honest) | **LIE** — claim a heart is spades |
| DIAMONDS | Varies (see below) | Best diamond (honest) |

When Mayor reveals DIAMONDS, Urbanist uses weighted randomness:
- 50%: Warn about a real spade (honest)
- 25%: Accuse Industry of lying (claim their diamond is spades)
- 25%: Disclose a medium diamond (honest, helps Mayor next round)

Fallback logic ensures bots always nominate something, even if their preferred suit isn't visible.

## Single-Layer Reality

The original design had two reality layers per tile: Resources and Desirability. This was overengineered. We simplified to a single card per tile:

```gdscript
# Old
truth = {
    LayerType.RESOURCES: {cube: card, ...},
    LayerType.DESIRABILITY: {cube: card, ...}
}

# New
truth = {cube: card, ...}
```

Reality is now generated lazily — tiles get their card only when fog is revealed. This uses a 39-card deck (13 ranks × 3 suits: Hearts, Diamonds, Spades). When the deck empties, it reshuffles, creating potential duplicates.

The game ends when the Mayor builds on a tile where the *reality* is spades — not when they play a spade card. This is crucial: advisors can lie about a tile being safe when it's actually spades.

## Hex Triangle Positioning

The hardest bug to fix was label positioning. Each hex is divided into 6 triangles:

```
          v0 (TOP)
         /    \
    v5  /      \  v1
       |   C   |
    v4  \      /  v2
         \    /
          v3 (BOTTOM)
```

We needed labels in specific triangles:
- **Industry claims** → TOP-RIGHT (v0 + v1)
- **Urbanist claims** → BOTTOM-LEFT (v3 + v4)
- **Reality** → TOP-LEFT (v5 + v0)
- **Built cards** → CENTER

The addon returns vertices clockwise from TOP, which we discovered through debug logging after multiple failed attempts assuming counter-clockwise or starting from RIGHT.

## Test Coverage Summary

| Test File | Tests | Purpose |
|-----------|-------|---------|
| `test_game_rules.gd` | 17 | E2E game loop, scoring, phases |
| `test_game_manager.gd` | 5 | Phase transitions, nominations |
| `test_game_protocol.gd` | 16 | Serialization, validation, round-trips |
| `test_action_panel.gd` | 14 | Button state logic |
| `test_overlay_manager.gd` | 8 | Triangle math, label positioning |
| `test_hex_coordinate.gd` | 8 | Hex grid math |
| `test_input_coordinates.gd` | 8 | Click coordinate transforms |
| **Total** | **76** | |

## Lessons Learned

1. **Extract early, extract often.** The 800-line files should have been split at 400 lines.

2. **Data model changes cascade.** Changing `nominations` from `Vector3i` to `{hex, claim}` touched 8 files. Plan these changes upfront.

3. **Test the visual layer.** Our automated tests caught logic bugs but not rendering issues. The triangle positioning bug survived several test runs.

4. **Debug logging is not optional.** The hex vertex ordering was only discoverable by printing actual coordinates at runtime.

5. **Scoring rules are subtle.** "Mayor scores if they picked optimally" sounds simple, but defining "optimal" requires careful thought about ties, suit matching, and edge cases.

6. **Typed arrays are strict.** GDScript won't coerce `[x]` to `Array[T]`. Always explicitly type array literals when passing to typed parameters.

7. **Full-screen Controls are traps.** A Control with `size = viewport_size` captures ALL clicks. Always check against actual visible UI bounds.

8. **Dead code rots.** The `InputRouter` class was "ready for later" but never used. Delete it or use it—don't let it linger.

## What's Done

- Phase delegation with unit tests
- Overlay manager with callable interface and geometry tests
- Input routing that actually works (with regression test)
- Centralized debug logging via `DebugLogger`
- Protocol validation helpers with round-trip tests
- ActionPanel button state tests
- 76 tests total, all passing

## What's Next

- Multiplayer testing with the new nomination/claim system
- UI polish for claim display (colors, animations)
- Balance tuning for bot AI strategies
- Sound effects for game events

The codebase is now structured to support these changes without architectural surgery. More importantly, it has tests to catch regressions when we inevitably break something.
