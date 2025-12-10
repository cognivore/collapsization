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
	]
	var mayor := GameProtocol.serialize_hand_for_role(0, hand, 1)
	assert_true(mayor.has("cards"), "Mayor sees full hand")
	assert_eq(mayor.get("revealed_index", -1), 1, "Revealed index preserved")

	var advisor_visible := GameProtocol.serialize_hand_for_role(1, hand, 1)
	assert_true(advisor_visible.has("visible"), "Advisor sees only revealed card")
	assert_eq(advisor_visible["visible"].size(), 1, "Advisor sees one card when revealed")

	var advisor_hidden := GameProtocol.serialize_hand_for_role(1, hand, -1)
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
	var nominations := {
		"industry": {
			"hex": Vector3i(1, -1, 0),
			"claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K")
		},
		"urbanist": {
			"hex": Vector3i(0, 1, -1),
			"claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")
		}
	}
	var serialized := GameProtocol.serialize_nominations(nominations)
	var deserialized := GameProtocol.deserialize_nominations(serialized)

	# Check industry
	assert_eq(deserialized["industry"]["hex"], Vector3i(1, -1, 0), "Industry hex round-trips")
	assert_eq(deserialized["industry"]["claim"]["rank"], "K", "Industry claim round-trips")
	assert_eq(deserialized["industry"]["claim"]["suit"], MapLayers.Suit.DIAMONDS, "Industry suit round-trips")

	# Check urbanist
	assert_eq(deserialized["urbanist"]["hex"], Vector3i(0, 1, -1), "Urbanist hex round-trips")
	assert_eq(deserialized["urbanist"]["claim"]["rank"], "Q", "Urbanist claim round-trips")


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


func test_empty_nomination_round_trip() -> void:
	var nominations := {
		"industry": {},
		"urbanist": GameProtocol.empty_nomination()
	}
	var serialized := GameProtocol.serialize_nominations(nominations)
	var deserialized := GameProtocol.deserialize_nominations(serialized)

	assert_true(deserialized["industry"].is_empty(), "Empty industry preserved")
	# empty_nomination() creates {hex: INVALID_HEX, claim: {}} which serializes then deserializes
	assert_eq(deserialized["urbanist"]["hex"], GameProtocol.INVALID_HEX, "INVALID_HEX preserved")


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

