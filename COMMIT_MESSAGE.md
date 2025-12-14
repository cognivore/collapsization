Problem: Game lacks strategic depth and bot support

The original design limited strategic play: single-card reveals reduced information
asymmetry, single nominations per advisor eliminated tactical choices, and scoring
failed to reward bluffing or penalize deception. The Dictionary-based nomination
structure couldn't represent multiple nominations, card circulation bugs caused
deck exhaustion, and no bot framework blocked RL training integration.

---

Solution: Overhaul game mechanics for strategic depth and bot integration

**Dual reveal and nomination systems**: Mayor now reveals two cards instead of one,
creating richer information asymmetry that enables meaningful bluffing strategies.
Advisors commit two nominations each (four total per turn), expanding the decision
space from binary choices to tactical positioning. This transforms the game from
simple card-matching into a strategic deception game where advisors must balance
multiple options and the Mayor must evaluate competing claims.

**Bluff detection scoring**: Replaced distance-only scoring with a system that
rewards successful deception and penalizes caught bluffs. When the Mayor trusts
an advisor's claim (plays matching suit), the advisor scores regardless of reality,
rewarding skillful bluffing. When the Mayor calls a bluff (plays different suit),
the advisor only scores if they were honest, creating a risk/reward dynamic.
Spade (mine) realities now properly penalize advisors who lied about mines (-2)
while rewarding honest warnings (+1). Mayor scoring requires true optimization
across all hand cards and nominated hexes, not just matching a single nomination.

**Bot action framework**: Added automated bot player system to enable RL training
pipelines and single-player testing. Bots receive full game state observations
with filtered information appropriate to their role (advisors see reality tiles,
Mayor sees only revealed cards). The system falls back to scripted behavior when
RL servers are unavailable, ensuring the game remains playable without external
dependencies.

**Data structure migration**: Migrated nominations from Dictionary to Array format
to support multiple nominations per advisor and same-hex nominations from different
advisors. This enables proper tie-breaking and cleaner serialization for network
sync and replay analysis.

**Card circulation fixes**: Fixed deck recycling to prevent card loss when the
deck exhausts mid-draw, eliminating game-breaking deck exhaustion bugs that occurred
during multi-card draws.

**Turn history and serialization**: Added complete turn history capture for replay
analysis and training data collection, enabling post-game analysis and RL dataset
generation.

These changes transform Collapsization from a deterministic card-matching game
into a strategic bluffing game with rich decision spaces suitable for both human
play and reinforcement learning. The expanded action spaces and bluff detection
mechanisms create meaningful strategic depth while the bot framework enables
automated playtesting and RL training pipelines.
