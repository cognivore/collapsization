extends GutTest

const GameProtocol := preload("res://scripts/game/game_protocol.gd")
const MapLayers := preload("res://scripts/map_layers.gd")


func test_serialize_built_hexes() -> void:
	var built := [Vector3i(1, 0, -1), Vector3i.ZERO]
	var serialized := GameProtocol.serialize_built_hexes(built)
	assert_eq(serialized, [[1, 0, -1], [0, 0, 0]], "Built hexes serialize to cube arrays")


func test_serialize_hand_for_role() -> void:
	var hand := [
		MapLayers.make_card(MapLayers.Suit.HEARTS, "A"),
		MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q"),
		MapLayers.make_card(MapLayers.Suit.SPADES, "K"),
		MapLayers.make_card(MapLayers.Suit.HEARTS, "7"),
	]
	var revealed := [0, 1] # Mayor reveals 2 cards
	var mayor := GameProtocol.serialize_hand_for_role(0, hand, revealed)
	assert_true(mayor.has("cards"), "Mayor sees full hand")
	assert_eq(mayor.get("revealed_indices", []), [0, 1], "Revealed indices preserved")

	var advisor_visible := GameProtocol.serialize_hand_for_role(1, hand, revealed)
	assert_true(advisor_visible.has("visible"), "Advisor sees only revealed cards")
	assert_eq(advisor_visible["visible"].size(), 2, "Advisor sees 2 cards when 2 revealed")

	var advisor_hidden := GameProtocol.serialize_hand_for_role(1, hand, [])
	assert_true(advisor_hidden.is_empty(), "Advisor sees nothing when no reveal")


func test_serialize_visibility_entry() -> void:
	var cube := Vector3i(1, -1, 0)
	var card := MapLayers.make_card(MapLayers.Suit.SPADES, "K")
	var entry := GameProtocol.serialize_visibility_entry(cube, card)
	assert_eq(entry.get("cube"), [1, -1, 0], "Cube serialized to array")
	assert_eq(entry.get("card").get("rank"), "K", "Card preserved in visibility entry")


# ─────────────────────────────────────────────────────────────────────────────
# ROUND-TRIP TESTS
# ─────────────────────────────────────────────────────────────────────────────

func test_nominations_round_trip() -> void:
	# Array format: 4 nominations, 2 per advisor
	var nominations := [
		{"hex": Vector3i(1, -1, 0), "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K"), "advisor": "industry"},
		{"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q"), "advisor": "industry"},
		{"hex": Vector3i(-1, 1, 0), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "J"), "advisor": "urbanist"},
		{"hex": Vector3i(-1, 0, 1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "10"), "advisor": "urbanist"},
	]
	var serialized := GameProtocol.serialize_nominations(nominations)
	var deserialized := GameProtocol.deserialize_nominations(serialized)

	assert_eq(deserialized.size(), 4, "All 4 nominations round-trip")

	# Check first industry nomination
	assert_eq(deserialized[0]["hex"], Vector3i(1, -1, 0), "First industry hex round-trips")
	assert_eq(deserialized[0]["claim"]["rank"], "K", "First industry claim round-trips")
	assert_eq(deserialized[0]["advisor"], "industry", "First industry advisor round-trips")

	# Check second industry nomination
	assert_eq(deserialized[1]["hex"], Vector3i(0, 1, -1), "Second industry hex round-trips")
	assert_eq(deserialized[1]["advisor"], "industry", "Second industry advisor round-trips")

	# Check first urbanist nomination
	assert_eq(deserialized[2]["hex"], Vector3i(-1, 1, 0), "First urbanist hex round-trips")
	assert_eq(deserialized[2]["advisor"], "urbanist", "First urbanist advisor round-trips")

	# Check second urbanist nomination
	assert_eq(deserialized[3]["hex"], Vector3i(-1, 0, 1), "Second urbanist hex round-trips")
	assert_eq(deserialized[3]["advisor"], "urbanist", "Second urbanist advisor round-trips")


func test_placement_round_trip() -> void:
	var placement := {
		"turn": 3,
		"card": MapLayers.make_card(MapLayers.Suit.SPADES, "J"),
		"cube": Vector3i(2, -1, -1)
	}
	var serialized := GameProtocol.serialize_placement(placement)
	var deserialized := GameProtocol.deserialize_placement(serialized)

	assert_eq(deserialized["turn"], 3, "Turn round-trips")
	assert_eq(deserialized["cube"], Vector3i(2, -1, -1), "Cube round-trips")
	assert_eq(deserialized["card"]["rank"], "J", "Card rank round-trips")
	assert_eq(deserialized["card"]["suit"], MapLayers.Suit.SPADES, "Card suit round-trips")


func test_built_hexes_round_trip() -> void:
	var built: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, -1, 0), Vector3i(-1, 1, 0)]
	var serialized := GameProtocol.serialize_built_hexes(built)
	var deserialized := GameProtocol.deserialize_built_hexes(serialized)

	assert_eq(deserialized.size(), 3, "Built hex count preserved")
	assert_eq(deserialized[0], Vector3i(0, 0, 0), "First hex round-trips")
	assert_eq(deserialized[1], Vector3i(1, -1, 0), "Second hex round-trips")
	assert_eq(deserialized[2], Vector3i(-1, 1, 0), "Third hex round-trips")


func test_empty_nominations_round_trip() -> void:
	var nominations: Array = []
	var serialized := GameProtocol.serialize_nominations(nominations)
	var deserialized := GameProtocol.deserialize_nominations(serialized)

	assert_eq(deserialized.size(), 0, "Empty nominations array preserved")


func test_turn_history_round_trip() -> void:
	var history := [
		{
			"turn": 0,
			"revealed_indices": [0, 1],
			"nominations": [
				{"hex": Vector3i(1, -1, 0), "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K"), "advisor": "industry"},
			],
			"build": {"hex": Vector3i(1, -1, 0), "card": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")},
			"reality": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10"),
			"scores_delta": {"mayor": 1, "industry": 1, "urbanist": 0},
		},
		{
			"turn": 1,
			"revealed_indices": [0, 2],
			"nominations": [
				{"hex": Vector3i(-1, 1, 0), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "J"), "advisor": "urbanist"},
			],
			"build": {"hex": Vector3i(-1, 1, 0), "card": MapLayers.make_card(MapLayers.Suit.HEARTS, "10")},
			"reality": MapLayers.make_card(MapLayers.Suit.HEARTS, "8"),
			"scores_delta": {"mayor": 1, "industry": 0, "urbanist": 1},
		},
	]
	var serialized := GameProtocol.serialize_turn_history(history)
	var deserialized := GameProtocol.deserialize_turn_history(serialized)

	assert_eq(deserialized.size(), 2, "Both turns round-trip")

	# Check first turn
	assert_eq(deserialized[0]["turn"], 0, "Turn 0 round-trips")
	assert_eq(deserialized[0]["revealed_indices"], [0, 1], "Revealed indices round-trip")
	assert_eq(deserialized[0]["build"]["hex"], Vector3i(1, -1, 0), "Build hex round-trips")
	assert_eq(deserialized[0]["scores_delta"]["mayor"], 1, "Score delta round-trips")

	# Check second turn
	assert_eq(deserialized[1]["turn"], 1, "Turn 1 round-trips")
	assert_eq(deserialized[1]["nominations"].size(), 1, "Nominations preserved")


# ─────────────────────────────────────────────────────────────────────────────
# VALIDATION TESTS
# ─────────────────────────────────────────────────────────────────────────────

func test_validate_card_valid() -> void:
	var card := MapLayers.make_card(MapLayers.Suit.HEARTS, "A")
	assert_true(GameProtocol.validate_card(card), "Valid card passes validation")


func test_validate_card_invalid_suit() -> void:
	var bad_card := {"suit": 5, "rank": "K"}
	assert_false(GameProtocol.validate_card(bad_card), "Invalid suit fails validation")


func test_validate_card_missing_fields() -> void:
	assert_false(GameProtocol.validate_card({}), "Empty card fails validation")
	assert_false(GameProtocol.validate_card({"suit": 0}), "Missing rank fails")
	assert_false(GameProtocol.validate_card({"rank": "K"}), "Missing suit fails")


func test_validate_serialized_nomination_valid() -> void:
	var nom := {"hex": [1, -1, 0], "claim": {"suit": 0, "rank": "K"}}
	assert_true(GameProtocol.validate_serialized_nomination(nom), "Valid nomination passes")


func test_validate_serialized_nomination_empty() -> void:
	assert_true(GameProtocol.validate_serialized_nomination({}), "Empty nomination is valid")


func test_validate_serialized_nomination_invalid() -> void:
	assert_false(GameProtocol.validate_serialized_nomination({"hex": "bad"}), "Non-array hex fails")
	assert_false(GameProtocol.validate_serialized_nomination({"hex": [1, 2]}), "Short hex fails")
	assert_false(GameProtocol.validate_serialized_nomination({"hex": [1, 2, 3], "claim": "bad"}), "Non-dict claim fails")


func test_validate_serialized_placement_valid() -> void:
	var p := {"cube": [1, -1, 0], "card": {"suit": 2, "rank": "J"}}
	assert_true(GameProtocol.validate_serialized_placement(p), "Valid placement passes")


func test_validate_serialized_placement_invalid() -> void:
	assert_false(GameProtocol.validate_serialized_placement({"cube": [1]}), "Short cube fails")
	assert_false(GameProtocol.validate_serialized_placement({"cube": [1, 2, 3]}), "Missing card fails")


func test_validate_role() -> void:
	assert_true(GameProtocol.validate_role(0), "Mayor valid")
	assert_true(GameProtocol.validate_role(1), "Industry valid")
	assert_true(GameProtocol.validate_role(2), "Urbanist valid")
	assert_false(GameProtocol.validate_role(-1), "Negative invalid")
	assert_false(GameProtocol.validate_role(3), "Out of range invalid")
