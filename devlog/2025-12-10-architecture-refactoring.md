# Architecture Refactoring: From Monoliths to Modules

**Date:** December 10, 2025  
**Commit:** e8a73aa  
**Files changed:** 18 (+2142 / -783 lines)

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

### Service Layer

Input handling was a disaster. Mouse clicks could target the HUD or the game world, but the routing logic was duplicated and buggy. We introduced:

```
scripts/services/
└── input_router.gd  # Mediates HUD vs world clicks
```

Similarly, UI button visibility depended on complex state checks scattered across `game_hud.gd`:

```
scripts/ui/
└── action_panel.gd  # Button state management
```

### Debug Infrastructure

Debug overlays were hardcoded into `game_hud.gd`. We extracted a reusable component:

```
scripts/debug/
└── debug_hud.gd  # Configurable debug overlay panel
```

### Network Protocol

Serialization for nominations and placements was inline in `GameManager`. We created:

```
scripts/game/
└── game_protocol.gd  # Network serialization helpers
```

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

## Lessons Learned

1. **Extract early, extract often.** The 800-line files should have been split at 400 lines.

2. **Data model changes cascade.** Changing `nominations` from `Vector3i` to `{hex, claim}` touched 8 files. Plan these changes upfront.

3. **Test the visual layer.** Our automated tests caught logic bugs but not rendering issues. The triangle positioning bug survived several test runs.

4. **Debug logging is not optional.** The hex vertex ordering was only discoverable by printing actual coordinates at runtime.

5. **Scoring rules are subtle.** "Mayor scores if they picked optimally" sounds simple, but defining "optimal" requires careful thought about ties, suit matching, and edge cases.

## What's Next

- Multiplayer testing with the new nomination/claim system
- UI polish for claim display (colors, animations)
- Balance tuning for bot AI strategies
- Sound effects for game events

The codebase is now structured to support these changes without architectural surgery.

