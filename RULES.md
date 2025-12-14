# Collapsization — Rules

## Components and Decks

- **Roles**: one Mayor, two Advisors (Industry and Urbanist).
- **Mayor draw pile**: three-suit deck (Hearts, Diamonds, Spades), ranks 2–A with Queen outranking King (Q > K). When exhausted, the discard is reshuffled into a new draw pile.
- **Advisor tile trays**: each Advisor starts the game with a full three-suit deck (same ranks and suits). When an Advisor's claimed card is chosen by the Mayor, that card remains on the board and is no longer available in the Advisor's tray.
- **Reality Tiles**: independent three-suit deck, ranks 2–A (Q > K), dealt onto the map when fog is revealed. When exhausted, a new deck is opened and shuffled.
- **Spades** represent mines; building on a Spade reality ends the game.

## Setup and Fog

- Center tile starts built as Ace of Hearts.
- Fog of war begins cleared on the center and its surrounding ring (7 hexes total).
- Whenever fog is revealed, each newly revealed hex is immediately assigned a Reality Tile from the reality deck. Advisors see all revealed Reality Tiles; the Mayor sees only the fog boundary.

## Turn Structure

Each turn has three phases:

1. **Draw Phase**: Mayor draws **four cards** from the Mayor pile into hand. Nominations from the previous turn are cleared. The Draw phase ends when the Mayor reveals exactly **two of their four cards** face-up (revealing them one at a time).

2. **Nomination Phase** (Commit → Reveal): Each Advisor secretly commits **two hexes** on the playable frontier (any hex adjacent to a built hex and not already built), each with an attached claimed card from their tray (truthful or a bluff). An Advisor cannot nominate the same hex twice. When all four nominations are committed, they reveal simultaneously.

3. **Build Phase** (Choose → Score): Mayor chooses one card from hand and one of the nominated hexes to build there, then scoring occurs.

## Nominations and Valid Hexes

- A valid nomination is any unbuilt hex on the playable frontier (adjacent to at least one built hex).
- Each Advisor nominates **two distinct hexes** per turn (4 nominations total, though hexes may overlap between Advisors).
- The nominated hexes (2–4 unique hexes) are the only places the Mayor can build this turn.
- Advisors' claims are informational hints (or bluffs); scoring depends on bluff detection.

## Fog, Visibility, and Reality Tiles

- When a hex is built, fog expands: the built hex and its six adjacent hexes become revealed.
- Revealing fog deals Reality Tiles onto every newly revealed hex from the reality deck. When the reality deck is exhausted, a new deck is opened and shuffled.
- Advisors have full visibility of all revealed Reality Tiles at all times. The Mayor never sees unrevealed reality.

## Law of Similarity and Scoring

### Mayor Scoring

**Distance-to-reality** determines the Mayor's score:

- If the placed card's suit matches the Reality Tile's suit: distance = |placed value − reality value|
- If suits do not match: distance is undefined (Mayor cannot score from that hex)

**Mayor** scores 1 point if:
- The placed card + chosen hex achieves the minimum possible distance-to-reality across ALL combinations of the Mayor's 4 hand cards and all nominated hexes (ties still reward the Mayor), AND
- The Reality Tile is not a Spade (game ends on Spade reality).

In other words, the Mayor only earns a point if they found the optimal build among their entire hand—not just the best hex for the card they happened to play.

### Advisor Scoring with Bluff Detection

When the Mayor builds on a nominated hex, scoring depends on whether the Mayor "trusted" or "called" each Advisor's claim:

**Non-Spade Reality** (normal case):
- **Mayor TRUSTS** (placed card suit = claim suit): Advisor gets **+1 point**, regardless of whether they were honest.
- **Mayor CALLS** (placed card suit ≠ claim suit):
  - If claim suit = reality suit (Advisor was honest): Advisor gets **+1 point** (Mayor was wrong to distrust).
  - If claim suit ≠ reality suit (bluff caught): Advisor gets **0 points**.

**Spade Reality** (game ends):
- If the Advisor claimed the hex was a Spade (honest warning): **0 points** (no reward for finding mines).
- If the Advisor claimed anything but Spade (lied about mine): **-2 points** (severe penalty).

### Tie-Breaking for Same-Hex Nominations

If both Advisors nominated the same hex, a tie-break determines which Advisor receives the scoring outcome:

1. **Claim value proximity**: The Advisor whose claim value is closest to the Mayor's placed card value wins.
2. **Suit match**: If values are equally close, the Advisor whose claim suit matches the placed card's suit wins.
3. **Domain affinity**: If still tied (same value AND same suit), the Advisor whose domain matches the suit wins:
   - **Hearts** → Urbanist wins (community/people theme)
   - **Diamonds** → Industry wins (resources theme)
   - **Spades** → Nobody wins (both lied about a mine when reality wasn't a Spade)

## Spades as Mines and Game End

- Spades represent mines in reality.
- If the Mayor builds on a hex whose Reality Tile is a Spade, the game ends immediately after placement and all reality is revealed.
- Spade penalty is built into the bluff detection scoring: Advisors who honestly warned about Spades score +1, while those who lied about mines lose 2 points.
- Final scores are tallied; the player with the most points wins.

## Strategic Implications

The bluff detection mechanic creates interesting strategic tension:

1. **For Advisors**: Lying is risky—if the Mayor doesn't play the suit you claimed, you get 0 points. Telling the truth earns +1 if the Mayor builds on your hex (for non-Spade hexes).

2. **For Mayor**: You can test Advisor honesty by playing a different suit than claimed. If the Advisor was bluffing, they score nothing. However, if they were honest, they still score.

3. **Deduction**: With 2 revealed cards and full turn history, the Mayor can track which Advisors tend to bluff and make informed trust decisions.

4. **Spade strategy**: Honestly warning about Spades yields 0 points (no free reward for finding mines), while lying about mines risks -2 penalty. This means Advisors must weigh: nominate safe hexes for points, or risk a spade bluff to end the game early.
