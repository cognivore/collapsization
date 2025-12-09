# December 8, 2025 — Cubical Hexes, Explained for Beginners

This post is a gentle primer on “cube coordinates” for hex grids. If you’re new to hex math, start here before diving into our networked hex field. The goal: understand why we do hex math in 3D cube space (x + y + z = 0) and how that makes hover detection, highlighting, and networking simpler.

## Why hexes need a different coordinate system

Squares are easy: (row, column). Hexes aren’t, because each cell has six neighbors and offset rows/columns get messy. Cube coordinates solve that by embedding the hex grid in 3D with a constraint:

- Each hex has coordinates (x, y, z).
- Constraint: x + y + z = 0 (only two degrees of freedom, but expressed in three axes).

Thinking in 3D simplifies distance, neighbors, and movement while still mapping cleanly to a 2D tilemap.

## Core ideas in cube space

- **Neighbors**: Six fixed direction vectors, e.g. `(1, -1, 0)`, `(1, 0, -1)`, `(0, 1, -1)`, `(-1, 1, 0)`, `(-1, 0, 1)`, `(0, -1, 1)`.
- **Distance**: Manhattan distance in cube space divided by 2: `dist = (abs(dx) + abs(dy) + abs(dz)) / 2`. No trigonometry needed.
- **Rings and ranges**: `cube_range(center, radius)` just walks cube space with the distance formula above. Great for selecting zones or generating maps.
- **Validity**: Because the constraint is baked in, illegal positions stand out immediately (they won’t satisfy x + y + z = 0).

## How we use cube coordinates in the project

- **Grid generation**: `hex_field.gd` calls `cube_range(Vector3i.ZERO, FIELD_RADIUS)` to lay out every hex. No syncing of terrain is needed because the math is deterministic.
- **Hover detection**: When the mouse moves, we find the closest cube cell, then convert to tilemap indices for Godot rendering. Staying in cube space keeps hover math and validation consistent.
- **Outlines and highlights**: The outline polygons come from cube-derived geometry. Keeping cube coords as the source of truth prevents rounding drift.
- **Networking**: Cursor updates broadcast cube coordinates `[x, y, z]`. Every peer applies the same cube math locally, so highlights appear on the same cells without extra reconciliation.

## Converting cube to the tilemap (and back)

Renderers and tilemaps usually want 2D indices. Common patterns:

- **Axial projection**: store (q, r) where q = x and r = z (or y), then derive the third axis as `-q - r` when needed.
- **Tilemap index**: `cube_to_map(cube)` computes the 2D index Godot’s `TileMap` expects. We only drop to 2D at the edge of the system—rendering. All logic stays in cube space.

## Benefits you feel immediately

- Simpler neighbor lookups (just pick a direction vector).
- Straightforward distance checks for ranges, movement limits, and area queries.
- Deterministic generation and validation: the math is pure, so client/server stay in lockstep.
- Clean separation: cube for logic, map indices for drawing.

## Minimal checklist for your own hex feature

1) Store positions as cube coords `(x, y, z)` with the zero-sum constraint.
2) Define the six neighbor vectors once; reuse everywhere.
3) Use cube Manhattan/2 for distances and range queries.
4) Keep logic in cube space; convert to map indices only when talking to the renderer.
5) When syncing over the network, send cube coords—small, lossless, and deterministic.

## Quick mental model

Picture a flat hex grid. Now imagine lifting it into 3D where each step along one hex edge increments one axis and decrements another. The third axis moves to keep the sum at zero. That’s cube space: it trades a small amount of abstraction for a big gain in clarity and composability.

## Where to look in the codebase

- `hex_field.gd` — generates the grid, validates hovered cells, and draws highlights.
- `addons/netcode/cursor_sync.gd` — sends hovered cube coords to peers.
- `addons/netcode/network_manager.gd` — receives cursor updates and stores cube coords per player.
- `addons/netcode/cursor_simulator.gd` — produces cube-coordinate patterns (spiral, random walk) for demo cursors.

With cube coordinates as the backbone, every higher-level feature—hover highlights, cursor syncing, future pathing—stays predictable and composable.

