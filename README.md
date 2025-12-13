# Multiplayer Minesweeper

A strategic 3-player game on a hexagonal grid where information asymmetry drives gameplay. One player (the Mayor) builds the city while two advisors compete to influence decisions—sometimes through deception.

## Game Overview

**Players:** 3 (Mayor + 2 Advisors: Industry and Urbanist)

**Goal:** The Mayor must expand the city without building on dangerous tiles (Spades). Advisors earn points by having the Mayor follow their recommendations.

### Roles

- **Mayor (Player 1):** Draws cards and builds on the map. Can only see revealed tiles and advisor nominations.
- **Industry Advisor (Player 2):** Sees all tiles and can recommend safe spots—or lie strategically.
- **Urbanist Advisor (Player 3):** Also sees all tiles and competes with Industry for the Mayor's trust.

### Game Flow

1. **DRAW Phase:** Mayor draws 3 cards and reveals 1 to the advisors
2. **NOMINATE Phase:** Both advisors secretly nominate a tile and claim what card is there (can lie!)
3. **PLACE Phase:** Mayor sees both nominations and places one of their remaining cards on a nominated tile
4. **Scoring:** Points are awarded based on how close the placed card matches reality

### Winning Conditions

- **Game Over:** If the Mayor builds on a tile where the reality is SPADES
- **Final Score:** Highest score among the three players wins

## Installation

### Pre-built Releases

Download the latest release for your platform from the [Releases page](../../releases):

- `multiplayer-minesweeper-linux.zip` - Linux x86_64
- `multiplayer-minesweeper-windows.zip` - Windows x86_64
- `multiplayer-minesweeper-macos.zip` - macOS Universal (Intel + Apple Silicon)

### Running the Game

1. Extract the downloaded archive
2. Run the executable:
   - **Linux:** `./multiplayer-minesweeper.x86_64`
   - **Windows:** Double-click `multiplayer-minesweeper.exe`
   - **macOS:** Open `Multiplayer Minesweeper.app`

## Multiplayer Setup

### Joining a Lobby Server

1. Launch the game
2. Enter the lobby server address and port
3. Click "Connect"
4. Create a room or join an existing one
5. Game starts automatically when 3 players are in a room

### Hosting Your Own Lobby Server

See [HOSTING.md](HOSTING.md) for detailed server deployment instructions.

**Quick Start:**

```bash
# Download the server build
wget https://github.com/YOUR_ORG/multiplayer-minesweeper/releases/latest/download/multiplayer-minesweeper-server-linux.zip
unzip multiplayer-minesweeper-server-linux.zip

# Run the server
./multiplayer-minesweeper-server.x86_64 --server --port 7777
```

## Controls

### Gameplay

- **Mouse:** Hover and click hexes to select
- **1/2/3:** Select cards in hand
- **R:** Reveal selected card (Mayor, DRAW phase)
- **C:** Commit nomination (Advisors, NOMINATE phase)
- **B:** Build on selected hex (Mayor, PLACE phase)
- **Right-click:** Cancel selection

### Camera

- **WASD / Arrow Keys:** Pan the camera
- **Mouse Wheel:** Zoom in/out
- **Middle Mouse Drag:** Pan the camera

### Other

- **ESC:** Open menu
- **F3:** Toggle debug overlay (development only)

## Development

### Requirements

- [Godot 4.5](https://godotengine.org/download) or later
- Nix (optional, for reproducible dev environment)

### Building from Source

```bash
# Clone the repository
git clone https://github.com/YOUR_ORG/multiplayer-minesweeper.git
cd multiplayer-minesweeper

# If using Nix
nix develop

# Open in Godot Editor
godot --editor project.godot

# Run tests
godot --headless -s addons/gut/gut_cmdln.gd
```

### Project Structure

```
├── addons/
│   ├── elegant_menu/     # In-game settings menu
│   ├── gut/              # Unit testing framework
│   ├── hexagon_tilemaplayer/  # Hex grid implementation
│   └── netcode/          # Networking layer
│       ├── lobby_server.gd    # Room management
│       ├── lobby_client.gd    # Client lobby protocol
│       └── network_manager.gd # Core networking
├── scripts/
│   ├── game/             # Game logic
│   │   ├── phases/       # Phase handlers (draw, nominate, place)
│   │   └── game_protocol.gd
│   ├── field/            # Map rendering
│   └── ui/               # UI components
├── ui/                   # Scene files
└── tests/                # Unit and E2E tests
```

## Architecture

The game uses a client-server model with the following components:

1. **Lobby Server:** Manages room creation and matchmaking
2. **Game Server:** One of the 3 players hosts the game session
3. **Game Manager:** Handles phase transitions and state synchronization
4. **Network Manager:** Reliable ENet transport layer

All game state is validated on the server to prevent cheating.

## License

This project is released under the MIT License. See [LICENSE](LICENSE) for details.

## Credits

- Hexagon TileMap Layer addon by the Godot community
- GUT testing framework by bitwes

