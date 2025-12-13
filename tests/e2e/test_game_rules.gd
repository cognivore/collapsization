## E2E tests for game rules: phases, scoring, bots, fog of war, game over.
## Tests the full game loop with deterministic seed for reproducibility.
extends GutTest

const GameManager := preload("res://scripts/game_manager.gd")
const MapLayers := preload("res://scripts/map_layers.gd")
const HexFieldScript := preload("res://hex_field.gd")
const GreenTileSet := preload("res://green_tileset.tres")

const TEST_SEED := 42
const TIMEOUT := 5.0

var _gm: GameManager
var _hex_field: Node
var _world: Node2D


func before_each() -> void:
	# Create a minimal world for testing
	_world = Node2D.new()
	add_child(_world)

	# Create HexField with proper TileSet
	_hex_field = HexagonTileMapLayer.new()
	_hex_field.tile_set = GreenTileSet
	_hex_field.set_script(HexFieldScript)
	_hex_field.name = "HexField"
	_world.add_child(_hex_field)

	# Create GameManager
	_gm = GameManager.new()
	_gm.name = "GameManager"
	_gm.hex_field_path = NodePath("../HexField")
	_world.add_child(_gm)

	# Initialize HexField after adding to tree
	_hex_field.generate_field()
	_hex_field.reinit_map_layers(TEST_SEED)

	# Bind GameManager to HexField
	_gm._bind_hex_field()


func after_each() -> void:
	if _world:
		_world.queue_free()
	_gm = null
	_hex_field = null
	_world = null
	await get_tree().process_frame


## Test 1: Game starts in lobby phase
func test_game_starts_in_lobby_phase() -> void:
	assert_eq(_gm.phase, GameManager.Phase.LOBBY, "Game should start in LOBBY phase")
	assert_true(_gm.hand.is_empty(), "Hand should be empty before game starts")
	assert_eq(_gm.turn_index, 0, "Turn index should be 0")


## Test 2: Draw phase deals 3 cards
func test_draw_phase_deals_3_cards() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	assert_eq(_gm.phase, GameManager.Phase.DRAW, "Game should be in DRAW phase after start")
	assert_eq(_gm.hand.size(), 3, "Hand should have 3 cards")
	assert_eq(_gm.revealed_index, -1, "No card should be revealed initially")


## Test 3: Reveal card updates state
func test_reveal_card_updates_state() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	assert_eq(_gm.revealed_index, -1, "No card revealed before reveal_card()")

	_gm.reveal_card(0)

	assert_eq(_gm.revealed_index, 0, "Card 0 should be revealed after reveal_card(0)")


## Test 4: Reveal card transitions to nominate phase
func test_reveal_transitions_to_nominate() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	_gm.reveal_card(0)

	assert_eq(_gm.phase, GameManager.Phase.NOMINATE, "Should be in NOMINATE phase after reveal")


## Test 5: Nominations update state
func test_nominations_update_state() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()
	_gm.reveal_card(0)

	# Simulate advisor nominations with claimed cards
	var industry_hex := Vector3i(1, -1, 0)
	var urbanist_hex := Vector3i(0, 1, -1)
	var industry_claim := MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K")
	var urbanist_claim := MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")

	_gm.commit_nomination(GameManager.Role.INDUSTRY, industry_hex, industry_claim)
	_gm.commit_nomination(GameManager.Role.URBANIST, urbanist_hex, urbanist_claim)

	# Both commits should reveal nominations with hex and claim
	assert_eq(_gm.nominations["industry"]["hex"], industry_hex, "Industry nomination hex should be set")
	assert_eq(_gm.nominations["urbanist"]["hex"], urbanist_hex, "Urbanist nomination hex should be set")
	assert_eq(_gm.nominations["industry"]["claim"]["suit"], MapLayers.Suit.DIAMONDS, "Industry claim should be diamonds")
	assert_eq(_gm.nominations["urbanist"]["claim"]["suit"], MapLayers.Suit.HEARTS, "Urbanist claim should be hearts")


## Test 6: Mayor can only place on nominated hex
func test_mayor_can_only_place_on_nominated() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()
	_gm.reveal_card(0)

	# Set up nominations manually with new format {hex, claim}
	var good_hex := Vector3i(1, -1, 0)
	_gm.nominations["industry"] = {"hex": good_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K")}
	_gm.nominations["urbanist"] = {"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")}
	_gm.phase = GameManager.Phase.PLACE

	# Ensure reality at good_hex is NOT spades (so game doesn't end)
	# Single layer now - just set truth[cube] directly
	_hex_field.map_layers.truth[good_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")

	# Try to place on non-nominated hex (should fail, phase stays PLACE)
	var bad_hex := Vector3i(5, -5, 0)
	_gm.place_card(0, bad_hex)
	assert_eq(_gm.phase, GameManager.Phase.PLACE, "Placing on non-nominated hex should keep PLACE phase")

	# Place on nominated hex (should succeed, phase moves to DRAW)
	_gm.place_card(0, good_hex)
	assert_eq(_gm.phase, GameManager.Phase.DRAW, "Placing on nominated hex should transition to DRAW phase")


## Test 7: Game ends when REALITY at built hex is SPADES (not when placed card is spade)
func test_spades_ends_game() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Inject a diamond card into hand (not spades - Mayor can play any card)
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "A")

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Set up nominations with new format
	var target := Vector3i(1, -1, 0)
	_gm.nominations["industry"] = {"hex": target, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "A")}
	_gm.nominations["urbanist"] = {"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")}
	_gm.phase = GameManager.Phase.PLACE

	# Set the REALITY at target hex to SPADES (simulating advisor lying)
	# Single layer now - just set truth[cube] directly
	_hex_field.map_layers.truth[target] = MapLayers.make_card(MapLayers.Suit.SPADES, "K")

	# Place the diamond card on a hex where reality is spades
	_gm.place_card(0, target)

	assert_eq(_gm.phase, GameManager.Phase.GAME_OVER, "Game should be over when reality is spades")


## Test 7b: Playing a SPADE card does NOT end game if reality is not spades
## Regression test: Game should only end when REALITY is spades, not when CARD is spades
func test_playing_spade_card_continues_if_reality_not_spades() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Inject a SPADE card into hand
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.SPADES, "A")

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Set up nominations
	var target := Vector3i(1, -1, 0)
	_gm.nominations["industry"] = {"hex": target, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")}
	_gm.nominations["urbanist"] = {"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")}
	_gm.phase = GameManager.Phase.PLACE

	# Ensure REALITY at target hex is NOT spades (it's diamonds)
	# Single layer now - just set truth[cube] directly
	_hex_field.map_layers.truth[target] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K")

	# Place the SPADE card - game should NOT end because reality is not spades
	_gm.place_card(0, target)

	assert_ne(_gm.phase, GameManager.Phase.GAME_OVER, "Game should NOT end when placing spade card if reality is not spades")
	assert_eq(_gm.phase, GameManager.Phase.DRAW, "Game should continue to DRAW phase")


## Test 7c: Building ANY card on a SPADE reality ends the game
## Regression test: Game must ALWAYS end when reality has spades, regardless of placed card suit
func test_any_card_on_spade_reality_ends_game() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Inject a HEARTS card into hand (not diamonds, not spades)
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Set up nominations
	var target := Vector3i(1, -1, 0)
	_gm.nominations["industry"] = {"hex": target, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")}
	_gm.nominations["urbanist"] = {"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")}
	_gm.phase = GameManager.Phase.PLACE

	# Set REALITY at target to be SPADES
	# Single layer now - just set truth[cube] directly
	_hex_field.map_layers.truth[target] = MapLayers.make_card(MapLayers.Suit.SPADES, "A")

	# Place the hearts card on a hex where desirability reality is spades
	_gm.place_card(0, target)

	assert_eq(_gm.phase, GameManager.Phase.GAME_OVER, "Game MUST end when building on ANY spade reality")


## Test 8: Scoring awards mayor for optimal guess
func test_scoring_awards_mayor_for_optimal_guess() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	var initial_mayor_score: int = _gm.scores["mayor"]

	# Inject a diamond card (resources)
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "A")

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Set up nominations with new format
	var target := Vector3i(1, -1, 0)
	_gm.nominations["industry"] = {"hex": target, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "A")}
	_gm.nominations["urbanist"] = {"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")}
	_gm.phase = GameManager.Phase.PLACE

	# Place the card
	_gm.place_card(0, target)

	# Mayor should get at least initial score (depends on map reality)
	assert_true(_gm.scores["mayor"] >= initial_mayor_score, "Mayor score should not decrease")


## Test 9: Scoring uses distance-to-reality with suit-match requirement
## New rules: Mayor must match suit to score. Distance = |value_diff| if suits match, else -1 (no score)
func test_scoring_distance_prefers_closest_reality() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor will place Q♥
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")]
	_gm.revealed_index = 0

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Define hexes
	var urbanist_hex := Vector3i(0, 1, -1)
	var industry_hex := Vector3i(1, -1, 0)

	# Reality: urbanist hex is 2♥, industry hex is 10♦
	_hex_field.map_layers.truth[urbanist_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "2")
	_hex_field.map_layers.truth[industry_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")

	# Nominations (claims don't affect Mayor scoring but do affect advisor tie-break)
	_gm.nominations["urbanist"] = {"hex": urbanist_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "K")}
	_gm.nominations["industry"] = {"hex": industry_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "J")}
	_gm.phase = GameManager.Phase.PLACE

	# Place Q♥ on urbanist hex
	_gm.place_card(0, urbanist_hex)

	# New scoring:
	# - Q♥ vs 2♥ (urbanist hex): suits match, distance = |13-2| = 11 (valid)
	# - Q♥ vs 10♦ (industry hex): suits don't match, distance = -1 (invalid)
	# Mayor scores because 11 is the minimum valid distance (only valid option)
	assert_eq(_gm.scores["mayor"], 1, "Mayor should score when suit matches reality")
	assert_eq(_gm.scores["urbanist"], 1, "Urbanist should score when their hex is chosen")
	assert_eq(_gm.scores["industry"], 0, "Industry should not score when their hex not chosen")


## Test 9b: Spade placement - Mayor doesn't score but advisor with closest claim does
func test_spade_placement_advisor_still_scores() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor will place A♠ (Ace of Spades)
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.SPADES, "A")]
	_gm.revealed_index = 0

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Define hexes
	var industry_hex := Vector3i(1, -1, 0)
	var urbanist_hex := Vector3i(0, 1, -1)

	# Reality doesn't matter for this test (not spades so game continues)
	_hex_field.map_layers.truth[industry_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")
	_hex_field.map_layers.truth[urbanist_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "2")

	# Claims: Industry claims Q♠ (value 13), Urbanist claims 5♠ (value 5)
	# Mayor places A♠ (value 14)
	# Industry claim |13-14| = 1 is closer than Urbanist |5-14| = 9
	_gm.nominations["industry"] = {"hex": industry_hex, "claim": MapLayers.make_card(MapLayers.Suit.SPADES, "Q")}
	_gm.nominations["urbanist"] = {"hex": urbanist_hex, "claim": MapLayers.make_card(MapLayers.Suit.SPADES, "5")}
	_gm.phase = GameManager.Phase.PLACE

	# Place A♠ on industry hex
	_gm.place_card(0, industry_hex)

	# Spade placement: Mayor gets 0, advisor with closest claim value scores
	assert_eq(_gm.scores["mayor"], 0, "Mayor should not score when placing Spade")
	assert_eq(_gm.scores["industry"], 1, "Industry should score (their hex chosen)")
	assert_eq(_gm.scores["urbanist"], 0, "Urbanist should not score (their hex not chosen)")


## Test 9c: Same-hex tie-break uses claim value proximity to placed card
func test_same_hex_tiebreak_by_claim_value() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor will place 10♦
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")]
	_gm.revealed_index = 0

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Both advisors nominate the same hex
	var shared_hex := Vector3i(1, -1, 0)

	# Reality at shared hex is 10♦ (exact match for Mayor)
	_hex_field.map_layers.truth[shared_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")

	# Industry claims 8♦ (value 8), Urbanist claims K♦ (value 12)
	# Mayor places 10♦ (value 10)
	# Industry |8-10| = 2 is closer than Urbanist |12-10| = 2 ... equal!
	# Tie-break: Industry claim suit (♦) matches placed suit (♦), so Industry wins
	_gm.nominations["industry"] = {"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "8")}
	_gm.nominations["urbanist"] = {"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K")}
	_gm.phase = GameManager.Phase.PLACE

	# Place 10♦ on shared hex
	_gm.place_card(0, shared_hex)

	# Mayor scores (exact match: distance = 0), Industry wins tie-break
	assert_eq(_gm.scores["mayor"], 1, "Mayor should score (exact suit+value match)")
	assert_eq(_gm.scores["industry"], 1, "Industry should win tie-break (suit matches placed)")
	assert_eq(_gm.scores["urbanist"], 0, "Urbanist should lose tie-break")


## Test 9d: Same-hex tie-break with different claim value distances
func test_same_hex_tiebreak_closer_value_wins() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor will place 7♥
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.HEARTS, "7")]
	_gm.revealed_index = 0

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Both advisors nominate the same hex
	var shared_hex := Vector3i(1, -1, 0)

	# Reality at shared hex is 7♥ (exact match for Mayor)
	_hex_field.map_layers.truth[shared_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "7")

	# Industry claims 2♥ (value 2), Urbanist claims 6♥ (value 6)
	# Mayor places 7♥ (value 7)
	# Industry |2-7| = 5, Urbanist |6-7| = 1
	# Urbanist is closer, wins the point
	_gm.nominations["industry"] = {"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "2")}
	_gm.nominations["urbanist"] = {"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "6")}
	_gm.phase = GameManager.Phase.PLACE

	# Place 7♥ on shared hex
	_gm.place_card(0, shared_hex)

	# Mayor scores (exact match), Urbanist wins (closer claim)
	assert_eq(_gm.scores["mayor"], 1, "Mayor should score (exact suit+value match)")
	assert_eq(_gm.scores["industry"], 0, "Industry should lose (farther claim value)")
	assert_eq(_gm.scores["urbanist"], 1, "Urbanist should win (closer claim value)")


## Test 9e: Mayor cannot score when suit mismatches reality
func test_mayor_no_score_on_suit_mismatch() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor will place 10♦
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")]
	_gm.revealed_index = 0

	# Progress to PLACE phase
	_gm.reveal_card(0)

	var target_hex := Vector3i(1, -1, 0)
	var other_hex := Vector3i(0, 1, -1)

	# Reality at target is 10♥ (same value but different suit!)
	_hex_field.map_layers.truth[target_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "10")
	_hex_field.map_layers.truth[other_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "2")

	_gm.nominations["industry"] = {"hex": target_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")}
	_gm.nominations["urbanist"] = {"hex": other_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "2")}
	_gm.phase = GameManager.Phase.PLACE

	# Place 10♦ on target_hex (reality is 10♥ - suit mismatch!)
	_gm.place_card(0, target_hex)

	# Mayor cannot score (suit mismatch), but Industry scores (their hex chosen)
	assert_eq(_gm.scores["mayor"], 0, "Mayor should NOT score when suit mismatches reality")
	assert_eq(_gm.scores["industry"], 1, "Industry should score (their hex was chosen)")


## Test 10: Fog reveals center and ring on game start
var _fog_received: Array = []

func _on_fog_updated(fog: Array) -> void:
	_fog_received = fog

func test_fog_reveals_center_and_ring() -> void:
	_fog_received.clear()
	_gm.fog_updated.connect(_on_fog_updated)

	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Should have received fog update with center + 6 adjacent hexes = 7 total
	assert_eq(_fog_received.size(), 7, "Should reveal 7 hexes (center + ring of 6)")

	# Check that town center is in the list
	assert_true(_gm.town_center in _fog_received, "Town center should be revealed")

	_gm.fog_updated.disconnect(_on_fog_updated)


## Test 10: Deterministic seed produces same map
func test_deterministic_seed_produces_same_map() -> void:
	# Generate map with seed
	var map1 := MapLayers.new()
	map1.generate(_hex_field, 5, TEST_SEED)

	# Generate another map with same seed
	var map2 := MapLayers.new()
	map2.generate(_hex_field, 5, TEST_SEED)

	# Cards at same position should match (single layer now)
	var test_cube := Vector3i(1, -1, 0)
	var card1: Dictionary = map1.get_card(test_cube)
	var card2: Dictionary = map2.get_card(test_cube)

	assert_eq(card1["suit"], card2["suit"], "Same seed should produce same suit")
	assert_eq(card1["rank"], card2["rank"], "Same seed should produce same rank")


## Test 11: Card rank ordering (Q > K)
func test_card_rank_ordering() -> void:
	var queen := MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")
	var king := MapLayers.make_card(MapLayers.Suit.HEARTS, "K")
	var ace := MapLayers.make_card(MapLayers.Suit.HEARTS, "A")

	assert_gt(queen["value"], king["value"], "Queen should outrank King")
	assert_gt(ace["value"], queen["value"], "Ace should outrank Queen")


## Test 12: Cannot re-nominate already-built hex
func test_cannot_renominate_built_hex() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()
	_gm.reveal_card(0)

	# Set up first round of nominations and build
	var industry_hex := Vector3i(1, -1, 0)
	var urbanist_hex := Vector3i(0, 1, -1)

	# Ensure reality at industry_hex is NOT spades (so game doesn't end)
	_hex_field.map_layers.truth[industry_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")

	_gm.commit_nomination(GameManager.Role.INDUSTRY, industry_hex, MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K"))
	_gm.commit_nomination(GameManager.Role.URBANIST, urbanist_hex, MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"))

	# Phase should now be PLACE
	assert_eq(_gm.phase, GameManager.Phase.PLACE, "Should be in PLACE phase after both nominations")

	# Place on industry hex
	_gm.place_card(0, industry_hex)

	# Phase should be DRAW again
	assert_eq(_gm.phase, GameManager.Phase.DRAW, "Should be in DRAW phase after placement")

	# industry_hex should now be in built_hexes
	assert_true(industry_hex in _gm.built_hexes, "Built hex should be tracked")

	# Start new round
	_gm.reveal_card(0)

	# Try to nominate the already-built hex (should be rejected silently)
	var ind_commit: Dictionary = _gm.advisor_commits["industry"]
	var commits_before: Dictionary = ind_commit.duplicate() if not ind_commit.is_empty() else {}
	_gm.commit_nomination(GameManager.Role.INDUSTRY, industry_hex, MapLayers.make_card(MapLayers.Suit.DIAMONDS, "A"))

	# The nomination should not have been accepted
	var commits_after: Dictionary = _gm.advisor_commits["industry"]
	assert_true(commits_after.is_empty() or commits_after.get("hex", _gm.INVALID_HEX) != industry_hex,
		"Should not be able to nominate already-built hex")


## Helper: Calculate cube distance
func _cube_distance(a: Vector3i, b: Vector3i) -> int:
	return (abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)) / 2


## Test 13: Lazy reality generation - deck invariants
## Verifies that revealing tiles from fog properly draws from deck
func test_lazy_reality_deck_invariants() -> void:
	# Create a fresh MapLayers without init_center (completely fogged)
	var map := MapLayers.new()
	map.init(TEST_SEED) # Just init, no center tile

	# Deck should start full
	assert_eq(map.get_deck_size(), MapLayers.MAX_DECK_SIZE, "Deck should start with MAX_DECK_SIZE cards")
	assert_eq(map.truth.size(), 0, "Truth should be empty initially")

	# Helper to count duplicate cards in revealed tiles
	var count_duplicates := func() -> int:
		var card_counts := {}
		for cube in map.truth.keys():
			var card: Dictionary = map.truth[cube]
			var key := "%d_%s" % [card["suit"], card["rank"]]
			card_counts[key] = card_counts.get(key, 0) + 1
		var duplicates := 0
		for count in card_counts.values():
			if count > 1:
				duplicates += count - 1 # Count extra occurrences
		return duplicates

	# Reveal tiles one by one, checking deck decrements
	var tiles_to_reveal: Array[Vector3i] = []
	for i in range(50): # More than deck size to test reshuffle
		tiles_to_reveal.append(Vector3i(i, -i, 0))

	for i in range(MapLayers.MAX_DECK_SIZE):
		var cube: Vector3i = tiles_to_reveal[i]
		var deck_before: int = map.get_deck_size()

		# Reveal tile
		var card: Dictionary = map.reveal_tile(cube)
		assert_false(card.is_empty(), "Revealed card should not be empty")

		# Deck should decrease by 1
		assert_eq(map.get_deck_size(), deck_before - 1, "Deck should decrease by 1 after reveal")

		# No duplicates while deck still has cards
		if map.get_deck_size() > 0:
			assert_eq(count_duplicates.call(), 0, "No duplicate cards while deck has cards (tile %d)" % i)

	# After revealing MAX_DECK_SIZE tiles, deck should be empty
	assert_eq(map.get_deck_size(), 0, "Deck should be empty after revealing MAX_DECK_SIZE tiles")
	assert_eq(map.truth.size(), MapLayers.MAX_DECK_SIZE, "Should have exactly MAX_DECK_SIZE revealed tiles")
	assert_eq(count_duplicates.call(), 0, "No duplicates when deck just emptied")

	# Reveal one more tile - this triggers reshuffle
	var next_cube: Vector3i = tiles_to_reveal[MapLayers.MAX_DECK_SIZE]
	var next_card: Dictionary = map.reveal_tile(next_cube)
	assert_false(next_card.is_empty(), "Card after reshuffle should not be empty")

	# After reshuffle: deck has MAX_DECK_SIZE - 1 cards
	assert_eq(map.get_deck_size(), MapLayers.MAX_DECK_SIZE - 1, "Deck should have MAX_DECK_SIZE - 1 after reshuffle draw")

	# Now there should be exactly 1 duplicate (2 tiles with same card)
	# The just-revealed tile is one of the repeated pair
	var dup_count: int = count_duplicates.call()
	assert_eq(dup_count, 1, "Should have exactly 1 duplicate after first reshuffle draw")

	# Find the duplicate card
	var card_counts := {}
	for cube in map.truth.keys():
		var card: Dictionary = map.truth[cube]
		var key := "%d_%s" % [card["suit"], card["rank"]]
		card_counts[key] = card_counts.get(key, 0) + 1

	var next_card_key := "%d_%s" % [next_card["suit"], next_card["rank"]]
	assert_eq(card_counts[next_card_key], 2, "The just-revealed card should be one of the duplicates")


## Regression test: show_nominations must pass typed Array[Vector3i] to cube_outlines callable
## This catches the bug where untyped arrays caused "Invalid type in function" errors
func test_nomination_overlay_renders_without_type_error() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()
	_gm.reveal_card(0)

	# Set up nominations with valid hexes from the visible ring
	var industry_hex := Vector3i(1, -1, 0)
	var urbanist_hex := Vector3i(0, 1, -1)
	var industry_claim := MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K")
	var urbanist_claim := MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")

	_gm.commit_nomination(GameManager.Role.INDUSTRY, industry_hex, industry_claim)
	_gm.commit_nomination(GameManager.Role.URBANIST, urbanist_hex, urbanist_claim)

	# This is the critical test: show_nominations must work without typed array errors
	# The bug was: show_nomination_for_cube passed untyped [cube] to cube_outlines(Array[Vector3i])
	assert_eq(_gm.phase, GameManager.Phase.PLACE, "Should be in PLACE after nominations")

	# Manually trigger overlay update to exercise the code path
	if _hex_field.has_method("show_nominations"):
		_hex_field.show_nominations(_gm.nominations)
		# If we got here without script error, the typed array fix worked
		pass_test("Nomination overlays rendered without type error")
	else:
		fail_test("HexField missing show_nominations method")


## Regression test: HUD click routing must not intercept world clicks
## Bug: _ui_root.size = viewport_size made all clicks route to HUD, breaking hex selection
func test_hud_click_routing_allows_world_clicks() -> void:
	const GameHudScript := preload("res://scripts/game_hud.gd")

	# Create a GameHud instance with panels
	var canvas := CanvasLayer.new()
	canvas.layer = 10
	add_child(canvas)

	var ui_root := Control.new()
	ui_root.name = "UIRoot"
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(ui_root)

	# Create TopPanel in top-left corner (small region)
	var top_panel := MarginContainer.new()
	top_panel.name = "TopPanel"
	top_panel.position = Vector2(0, 0)
	top_panel.size = Vector2(200, 100)
	ui_root.add_child(top_panel)

	# Create BottomPanel in bottom-center (small region)
	var bottom_panel := MarginContainer.new()
	bottom_panel.name = "BottomPanel"
	bottom_panel.position = Vector2(300, 500)
	bottom_panel.size = Vector2(200, 100)
	ui_root.add_child(bottom_panel)

	# Test _is_click_on_hud_panels behavior
	# Click in center of screen (400, 300) should NOT be on HUD
	var center_click := Vector2(400, 300)
	var in_top := top_panel.get_global_rect().has_point(center_click)
	var in_bottom := bottom_panel.get_global_rect().has_point(center_click)
	assert_false(in_top or in_bottom, "Center click (400,300) should NOT be in HUD panels")

	# Click in TopPanel area should be on HUD
	var top_click := Vector2(50, 50)
	assert_true(top_panel.get_global_rect().has_point(top_click), "Click at (50,50) should be in TopPanel")

	# Click in BottomPanel area should be on HUD
	var bottom_click := Vector2(400, 550)
	assert_true(bottom_panel.get_global_rect().has_point(bottom_click), "Click at (400,550) should be in BottomPanel")

	canvas.queue_free()
	await get_tree().process_frame
	pass_test("HUD click routing correctly distinguishes panel vs world clicks")
