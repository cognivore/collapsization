## Stores layered card data for the map and advisors' perimeter knowledge.
extends Resource
class_name MapLayers

enum Suit {HEARTS, DIAMONDS, SPADES}
enum LayerType {RESOURCES, DESIRABILITY}

const BAD_CARD_CHANCE := 0.2
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

var radius: int = 0
var truth: Dictionary = {}           # layer_type -> {cube: card}
var advisor_perimeter: Dictionary = {} # layer_type -> {cube: card}


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


func generate(field: Node, map_radius: int, seed: int = -1) -> void:
	radius = map_radius
	truth.clear()
	advisor_perimeter.clear()

	var rng := RandomNumberGenerator.new()
	if seed >= 0:
		rng.seed = seed
	else:
		rng.randomize()

	for layer_type in LayerType.values():
		truth[layer_type] = {}

		# Use HexagonTileMapLayer helpers directly from the field
		for cube in field.cube_range(Vector3i.ZERO, radius):
			truth[layer_type][cube] = _roll_card(layer_type, rng)

		advisor_perimeter[layer_type] = _slice_perimeter(field, truth[layer_type])

	# Force center to Ace of Hearts for desirability layer for demo readability
	truth[LayerType.DESIRABILITY][Vector3i.ZERO] = make_card(Suit.HEARTS, "A")


func get_card(layer_type: int, cube: Vector3i) -> Dictionary:
	if truth.has(layer_type) and truth[layer_type].has(cube):
		return truth[layer_type][cube]
	return {}


func get_perimeter(layer_type: int) -> Dictionary:
	return advisor_perimeter.get(layer_type, {})


func _roll_card(layer_type: int, rng: RandomNumberGenerator) -> Dictionary:
	var suit: Suit = Suit.DIAMONDS if layer_type == LayerType.RESOURCES else Suit.HEARTS
	if rng.randf() < BAD_CARD_CHANCE:
		suit = Suit.SPADES
	var rank := RANKS[rng.randi_range(0, RANKS.size() - 1)]
	return make_card(suit, rank)


func _slice_perimeter(field: Node, layer_truth: Dictionary) -> Dictionary:
	var view: Dictionary = {}
	for cube in field.cube_ring(Vector3i.ZERO, radius):
		if layer_truth.has(cube):
			view[cube] = layer_truth[cube]
	return view

