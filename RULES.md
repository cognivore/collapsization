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

Each turn has four phases:

1. **Draw Phase**: Mayor draws **four cards** from the Mayor pile into hand. Nominations from the previous turn are cleared. The Draw phase ends when the Mayor reveals exactly **two of their four cards** face-up (revealing them one at a time).

2. **Control Phase** (NEW): Mayor chooses how to constrain the Advisors' nominations. The Mayor must pick ONE of two options:
   - **Option A — Force Suits**: Assign suit constraints to each Advisor. Choose one configuration:
     - Urbanist must claim Diamonds, Industry must claim Hearts; OR
     - Urbanist must claim Hearts, Industry must claim Diamonds
   - **Option B — Force Hexes**: Pick one specific hex per Advisor that they MUST include in their nominations.

3. **Nomination Phase** (Commit → Reveal): Each Advisor secretly commits **two hexes** on the playable frontier, each with an attached claimed card from their tray. Constraints from the Control Phase apply:
   - If suits were forced: at least ONE of the two claims must use the forced suit.
   - If hexes were forced: ONE nomination must be the forced hex (the other is free choice).
   When all four nominations are committed, they reveal simultaneously.

4. **Build Phase** (Choose → Score): Mayor chooses one card from hand and one of the nominated hexes to build there, then scoring occurs.

## Control Phase Details

### Option A — Force Suits

The Mayor picks one of two suit assignments:
- **Configuration 1**: Urbanist → Diamonds, Industry → Hearts
- **Configuration 2**: Urbanist → Hearts, Industry → Diamonds

Each Advisor must claim their assigned suit in **at least one** of their two nominations. The claim can be on any hex—it does not require reality to match. This forces Advisors into predictable suit patterns, giving the Mayor information leverage.

**Risk for Advisors**: If an Advisor claims a non-Spade suit on a hex where reality IS a Spade, they receive the standard **-2 penalty** for lying about a mine. Advisors must carefully balance following the Mayor's suit mandate against the danger of misrepresenting mines.

### Option B — Force Hexes

The Mayor selects one hex from the playable frontier for each Advisor:
- **Forced hex for Urbanist**: Must be included in Urbanist's nominations
- **Forced hex for Industry**: Must be included in Industry's nominations

Each Advisor's second nomination is their free choice. This gives the Mayor geographic control—they can force Advisors to reveal information about specific hexes of interest.

**Strategic Note**: The Mayor can see the fog boundary but not reality. By forcing hexes, the Mayor can probe areas they're curious about while limiting Advisor manipulation of the nomination pool.

## Nominations and Valid Hexes

- A valid nomination is any unbuilt hex on the playable frontier (adjacent to at least one built hex).
- Each Advisor nominates **two distinct hexes** per turn (4 nominations total, though hexes may overlap between Advisors).
- Nominations must respect Control Phase constraints (forced suit or forced hex).
- The nominated hexes (2–4 unique hexes) are the only places the Mayor can build this turn.
- Advisors' claims are informational hints (or bluffs); scoring depends on bluff detection.

## Fog, Visibility, and Reality Tiles

- When a hex is built, fog expands: the built hex and its six adjacent hexes become revealed.
- Revealing fog deals Reality Tiles onto every newly revealed hex from the reality deck. When the reality deck is exhausted, a new deck is opened and shuffled.
- Advisors have full visibility of all revealed Reality Tiles at all times. The Mayor never sees unrevealed reality.

## Law of Similarity and Scoring

### Mayor Scoring

**Mayor** scores 1 point if:
- The placed card's **suit matches** the Reality Tile's suit (Hearts→Hearts, Diamonds→Diamonds), AND
- The Reality Tile is not a Spade (game ends on Spade reality).

This simple rule rewards the Mayor for correctly reading advisor claims and choosing hexes where their card suit aligns with reality. No complex optimal-distance calculation needed—just match the suit!

### Advisor Scoring with Bluff Detection

When the Mayor builds on a nominated hex, scoring depends on whether the Mayor "trusted" or "called" each Advisor's claim:

**Non-Spade Reality** (normal case):
- **Mayor TRUSTS** (placed card suit = claim suit): Advisor gets **+1 point**, regardless of whether they were honest.
- **Mayor CALLS** (placed card suit ≠ claim suit):
  - If claim suit = reality suit (Advisor was honest): Advisor gets **+1 point** (Mayor was wrong to distrust).
  - If claim suit ≠ reality suit (bluff caught): Advisor gets **0 points**.

**Spade Reality** (game ends):
- If the Advisor claimed the hex was a Spade (honest warning): **+1 point** (rewarded for accurate mine detection).
- If the Advisor claimed anything but Spade (lied about mine): **-2 points** (severe penalty).

### Tie-Breaking for Same-Hex Nominations

If both Advisors nominated the same hex, a tie-break determines which Advisor receives the scoring outcome:

1. **Claim value proximity**: The Advisor whose claim value is closest to the Mayor's placed card value wins.
2. **Suit match**: If values are equally close, the Advisor whose claim suit matches the placed card's suit wins.
3. **Domain affinity**: If still tied (same value AND same suit), the Advisor whose domain matches the suit wins:
   - **Hearts** → Urbanist wins (community/people theme)
   - **Diamonds** → Industry wins (resources theme)
   - **Spades** → Nobody wins (both lied about a mine when reality wasn't a Spade)

## Game End Conditions

The game ends when one of these conditions is met:

### 1. Mine Strike (Mayor Loses Immediately)

- **Spades** represent mines in reality.
- If the Mayor builds on a hex whose Reality Tile is a Spade, the game ends immediately and **Mayor LOSES regardless of score**.
- Spade penalty is still applied to Advisors: those who honestly warned about Spades score +1, while those who lied about mines lose 2 points.
- The Advisor with the highest score wins (Industry or Urbanist).

### 2. City Completion (Mayor's Endgame)

- Mayor can end the game by building **10 Hearts facilities** AND **10 Diamonds facilities**.
- Facilities are counted by the **reality tile suit**, not the placed card suit.
- The town center (A♥) counts as the first Hearts facility.
- When Mayor completes 10♥ + 10♦, the game ends and **scores are compared normally**.
- The player with the highest score wins.

### Winner Determination

| Condition | Who Can Win | How |
|-----------|-------------|-----|
| Mine Strike | Industry or Urbanist only | Mayor loses immediately; highest advisor score wins |
| City Complete | Anyone | Highest score wins |

## Strategic Implications

The Control Phase creates a cat-and-mouse dynamic between Mayor and Advisors:

1. **For Mayor (Control Phase)**:
   - Use **Force Suits** when you want to test Advisor honesty in a specific suit domain, or when your revealed cards favor a particular suit.
   - Use **Force Hexes** when you want information about specific map locations, or to prevent Advisors from only nominating "safe" hexes far from danger.

2. **For Advisors**:
   - When suits are forced, you must claim that suit once—but you can still bluff about the hex's reality.
   - When hexes are forced, you lose control of one nomination but gain freedom in your claim suit.
   - The -2 Spade penalty remains dangerous: if Mayor forces you to claim Hearts on a Spade reality, you'll lose points.

3. **Deduction**: With 2 revealed cards, control constraints, and full turn history, the Mayor can track Advisor behavior patterns and make informed decisions.

4. **Balance**: The Control Phase gives Mayor active tools to shape the game, reducing the information asymmetry that previously favored Advisors.
