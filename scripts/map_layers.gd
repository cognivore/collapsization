## Stores single-layer reality card data for the map.
## Reality is drawn lazily from a deck (reshuffled when exhausted).
## Each tile has ONE card representing its true nature.
extends Resource
class_name MapLayers

const DebugLogger := preload("res://scripts/debug/debug_logger.gd")

enum Suit {HEARTS, DIAMONDS, SPADES}

const RANKS: Array[String] = [
	"2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "K", "Q", "A"
]
const RANK_VALUE := {
	"2": 2,
	"3": 3,
	"4": 4,
	"5": 5,
	"6": 6,
	"7": 7,
	"8": 8,
	"9": 9,
	"10": 10,
	"J": 11,
	"K": 12,
	"Q": 13, # Queen outranks King in this ruleset
	"A": 14,
}

# Single reality layer: {cube: card}
var truth: Dictionary = {}

# Reality deck - 39 cards (13 ranks × 3 suits: Hearts, Diamonds, Spades)
var _reality_deck: Array[Dictionary] = []
var _rng: RandomNumberGenerator


static func make_card(suit: Suit, rank: String) -> Dictionary:
	return {
		"suit": suit,
		"rank": rank,
		"value": RANK_VALUE.get(rank, 0),
	}


static func label(card: Dictionary) -> String:
	if card.is_empty():
		return ""
	var suit_str := ""
	match card["suit"]:
		Suit.HEARTS: suit_str = "♥"
		Suit.DIAMONDS: suit_str = "♦"
		Suit.SPADES: suit_str = "♠"
	return "%s%s" % [card["rank"], suit_str]


static func compare_rank(a: Dictionary, b: Dictionary) -> int:
	var av: int = a.get("value", 0)
	var bv: int = b.get("value", 0)
	if av == bv:
		return 0
	return 1 if av > bv else -1


## Initialize the map layers with a seed for deterministic generation
func init(seed: int = -1) -> void:
	truth.clear()
	_reality_deck.clear()

	_rng = RandomNumberGenerator.new()
	if seed >= 0:
		_rng.seed = seed
	else:
		_rng.randomize()

	# Build and shuffle the initial reality deck
	_build_deck()
	_shuffle_deck()
	DebugLogger.log("MapLayers: Initialized with deck of %d cards" % _reality_deck.size())


## Initialize center tile as Ace of Hearts (the starting built tile)
func init_center() -> void:
	truth[Vector3i.ZERO] = make_card(Suit.HEARTS, "A")
	DebugLogger.log("MapLayers: Center set to A♥")


## Lazily reveal a tile's reality - generates from deck if not yet known
## Returns the card at that tile
func reveal_tile(cube: Vector3i) -> Dictionary:
	if truth.has(cube):
		return truth[cube]

	# Draw a new card for this tile
	var card := _draw_card()
	truth[cube] = card
	DebugLogger.log("MapLayers: Revealed %s at (%d,%d,%d)" % [label(card), cube.x, cube.y, cube.z])
	return card


## Get a tile's reality (returns empty if not yet revealed)
func get_card(cube: Vector3i) -> Dictionary:
	return truth.get(cube, {})


## Get the current deck size (for testing)
func get_deck_size() -> int:
	return _reality_deck.size()


## Get the max deck size (39 cards: 13 ranks × 3 suits)
const MAX_DECK_SIZE := 39


## Build a 39-card deck: 13 cards each of Hearts, Diamonds, Spades
func _build_deck() -> void:
	_reality_deck.clear()
	for suit in [Suit.HEARTS, Suit.DIAMONDS, Suit.SPADES]:
		for rank in RANKS:
			_reality_deck.append(make_card(suit, rank))
	DebugLogger.log("MapLayers: Built reality deck with %d cards" % _reality_deck.size())


## Shuffle the reality deck using Fisher-Yates
func _shuffle_deck() -> void:
	for i in range(_reality_deck.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var temp: Dictionary = _reality_deck[i]
		_reality_deck[i] = _reality_deck[j]
		_reality_deck[j] = temp


## Draw a card from the reality deck, reshuffling if empty
func _draw_card() -> Dictionary:
	if _reality_deck.is_empty():
		_build_deck()
		_shuffle_deck()
		DebugLogger.log("MapLayers: Reality deck exhausted, reshuffled new deck")
	return _reality_deck.pop_back()


# ─────────────────────────────────────────────────────────────────────────────
# LEGACY COMPATIBILITY (deprecated, will be removed)
# ─────────────────────────────────────────────────────────────────────────────

## Legacy: Generate all tiles eagerly (kept for test compatibility)
func generate(field: Node, map_radius: int, seed: int = -1) -> void:
	init(seed)
	init_center()

	# Generate all tiles in radius for backward compatibility with tests
	for cube in field.cube_range(Vector3i.ZERO, map_radius):
		if not truth.has(cube):
			reveal_tile(cube)

	DebugLogger.log("MapLayers: Legacy generate() - %d tiles" % truth.size())
