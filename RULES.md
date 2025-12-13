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

1. **Draw Phase**: Mayor draws three cards from the Mayor pile into hand. Nominations from the previous turn are cleared. The Draw phase ends when the Mayor reveals exactly one of their three cards face-up.

2. **Nomination Phase** (Commit → Reveal): Advisors secretly commit one hex each on the playable frontier (any hex adjacent to a built hex and not already built) and attach a claimed card from their tray (truthful or a bluff). When both Advisors have committed, nominations reveal simultaneously.

3. **Build Phase** (Choose → Score): Mayor chooses one card from hand (not limited to the revealed one) and one of the nominated hexes to build there, then scoring occurs.

## Nominations and Valid Hexes

- A valid nomination is any unbuilt hex on the playable frontier (adjacent to at least one built hex).
- Both Advisors may nominate the same hex. The nominated hexes are the only places the Mayor can build this turn.
- Advisors' claims are informational hints (or bluffs); scoring compares the Mayor's placed card to the hidden Reality Tile.

## Fog, Visibility, and Reality Tiles

- When a hex is built, fog expands: the built hex and its six adjacent hexes become revealed.
- Revealing fog deals Reality Tiles onto every newly revealed hex from the reality deck. When the reality deck is exhausted, a new deck is opened and shuffled.
- Advisors have full visibility of all revealed Reality Tiles at all times. The Mayor never sees unrevealed reality.

## Law of Similarity and Scoring

**Distance-to-reality** determines the Mayor's score:

- If the placed card's suit matches the Reality Tile's suit: distance = |placed value − reality value|
- If suits do not match: distance = 0 (Mayor cannot score)

**Mayor** scores 1 point if:
- The built hex has the minimum distance-to-reality among this turn's nominated hexes (ties still reward the Mayor), AND
- The placed card is not a Spade.

**Advisors** score 1 point if the Mayor builds on their nominated hex:
- If only one Advisor nominated the chosen hex, that Advisor scores.
- If both Advisors nominated the same hex, the Advisor whose claim value is closest to the Mayor's placed card value wins the point.
- If both claims are equally close to the placed value, the Advisor whose claim suit matches the placed card's suit wins.

**Spade placement**: When the Mayor places a Spade card, the Mayor does not score, but the Advisor whose claim value is closest to the Mayor's placed Spade value still scores 1 point.

## Spades as Mines and Game End

- Spades represent mines in reality.
- If the Mayor builds on a hex whose Reality Tile is a Spade, the game ends immediately after placement and all reality is revealed.
- Final scores are tallied; the player with the most points wins.
