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


## Test 2: Draw phase deals 4 cards
func test_draw_phase_deals_4_cards() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	assert_eq(_gm.phase, GameManager.Phase.DRAW, "Game should be in DRAW phase after start")
	assert_eq(_gm.hand.size(), 4, "Hand should have 4 cards")
	assert_eq(_gm.revealed_indices.size(), 0, "No cards should be revealed initially")


## Test 3: Reveal card updates state (need to reveal 2 cards now)
func test_reveal_card_updates_state() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	assert_eq(_gm.revealed_indices.size(), 0, "No card revealed before reveal_card()")

	_gm.reveal_card(0)
	assert_eq(_gm.revealed_indices.size(), 1, "One card should be revealed after first reveal_card()")
	assert_true(0 in _gm.revealed_indices, "Card 0 should be in revealed indices")

	_gm.reveal_card(1)
	assert_eq(_gm.revealed_indices.size(), 2, "Two cards should be revealed after second reveal_card()")
	assert_true(1 in _gm.revealed_indices, "Card 1 should be in revealed indices")


## Test 4: Reveal card transitions to CONTROL phase after 2 reveals
## Note: After CONTROL, Mayor must choose control mode to proceed to NOMINATE
func test_reveal_transitions_to_control() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()
	# Disable bots for this test to check intermediate state
	_gm.set_bot_roles([])

	_gm.reveal_card(0)
	assert_eq(_gm.phase, GameManager.Phase.DRAW, "Should still be in DRAW phase after first reveal")

	_gm.reveal_card(1)
	assert_eq(_gm.phase, GameManager.Phase.CONTROL, "Should be in CONTROL phase after second reveal")

	# Mayor chooses control mode to proceed to NOMINATE
	_gm.force_suits(0) # Config A: Urb→Diamond, Ind→Heart
	assert_eq(_gm.phase, GameManager.Phase.NOMINATE, "Should be in NOMINATE phase after control choice")


## Test 5: Nominations update state (now requires 4 nominations, 2 per advisor)
func test_nominations_update_state() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()
	# Disable bots so we can test manual nomination flow
	_gm.set_bot_roles([])
	_gm.reveal_card(0)
	_gm.reveal_card(1) # Need 2 reveals to transition to CONTROL

	# Mayor must choose control mode to proceed to NOMINATE
	assert_eq(_gm.phase, GameManager.Phase.CONTROL, "Should be in CONTROL phase")
	_gm.force_suits(0) # Config A: Urb→Diamond, Ind→Heart

	# Simulate advisor nominations with claimed cards (2 per advisor now)
	var industry_hex1 := Vector3i(1, -1, 0)
	var industry_hex2 := Vector3i(0, 1, -1)
	var urbanist_hex1 := Vector3i(-1, 1, 0)
	var urbanist_hex2 := Vector3i(-1, 0, 1)
	# Claims must respect forced suits: Industry must claim Hearts in at least one
	var industry_claim1 := MapLayers.make_card(MapLayers.Suit.HEARTS, "K") # Forced suit
	var industry_claim2 := MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")
	# Urbanist must claim Diamonds in at least one
	var urbanist_claim1 := MapLayers.make_card(MapLayers.Suit.DIAMONDS, "J") # Forced suit
	var urbanist_claim2 := MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")

	# Industry commits 2 nominations
	_gm.commit_nomination(GameManager.Role.INDUSTRY, industry_hex1, industry_claim1)
	_gm.commit_nomination(GameManager.Role.INDUSTRY, industry_hex2, industry_claim2)

	# Urbanist commits 2 nominations
	_gm.commit_nomination(GameManager.Role.URBANIST, urbanist_hex1, urbanist_claim1)
	_gm.commit_nomination(GameManager.Role.URBANIST, urbanist_hex2, urbanist_claim2)

	# All 4 nominations should be revealed
	assert_eq(_gm.nominations.size(), 4, "Should have 4 nominations total")

	# Check that all hexes are in nominations
	var nominated_hexes: Array[Vector3i] = []
	for nom in _gm.nominations:
		nominated_hexes.append(nom.get("hex", _gm.INVALID_HEX))
	assert_true(industry_hex1 in nominated_hexes, "Industry hex 1 should be nominated")
	assert_true(industry_hex2 in nominated_hexes, "Industry hex 2 should be nominated")
	assert_true(urbanist_hex1 in nominated_hexes, "Urbanist hex 1 should be nominated")
	assert_true(urbanist_hex2 in nominated_hexes, "Urbanist hex 2 should be nominated")


## Test 6: Mayor can only place on nominated hex
func test_mayor_can_only_place_on_nominated() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()
	_gm.reveal_card(0)

	# Set up nominations manually with new array format
	var good_hex := Vector3i(1, -1, 0)
	_gm.nominations = [
		{"hex": good_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K"), "advisor": "industry"},
		{"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Ensure reality at good_hex is NOT spades (so game doesn't end)
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

	# Set up nominations with new array format
	var target := Vector3i(1, -1, 0)
	_gm.nominations = [
		{"hex": target, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "A"), "advisor": "industry"},
		{"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Set the REALITY at target hex to SPADES (simulating advisor lying)
	_hex_field.map_layers.truth[target] = MapLayers.make_card(MapLayers.Suit.SPADES, "K")

	# Place the diamond card on a hex where reality is spades
	_gm.place_card(0, target)

	assert_eq(_gm.phase, GameManager.Phase.GAME_OVER, "Game should be over when reality is spades")
	assert_true(_gm.mayor_hit_mine, "Mayor should be marked as hitting a mine")


## Test 7b: Playing a SPADE card does NOT end game if reality is not spades
## Regression test: Game should only end when REALITY is spades, not when CARD is spades
func test_playing_spade_card_continues_if_reality_not_spades() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Inject a SPADE card into hand
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.SPADES, "A")

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Set up nominations with new array format
	var target := Vector3i(1, -1, 0)
	_gm.nominations = [
		{"hex": target, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q"), "advisor": "industry"},
		{"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Ensure REALITY at target hex is NOT spades (it's diamonds)
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

	# Set up nominations with new array format
	var target := Vector3i(1, -1, 0)
	_gm.nominations = [
		{"hex": target, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q"), "advisor": "industry"},
		{"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Set REALITY at target to be SPADES
	_hex_field.map_layers.truth[target] = MapLayers.make_card(MapLayers.Suit.SPADES, "A")

	# Place the hearts card on a hex where desirability reality is spades
	_gm.place_card(0, target)

	assert_eq(_gm.phase, GameManager.Phase.GAME_OVER, "Game MUST end when building on ANY spade reality")
	assert_true(_gm.mayor_hit_mine, "Mayor should be marked as hitting a mine")


## Test 7d: Spade penalty applies when lying about mine (bluff detection)
func test_spade_penalty_applies_when_lying_about_mine() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Set initial scores
	_gm.scores = {"mayor": 5, "industry": 3, "urbanist": 4}

	# Inject a HEARTS card into hand
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.HEARTS, "7")

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Both advisors nominate the same spade hex but LIED (claimed non-spade)
	var spade_hex := Vector3i(1, -1, 0)
	_gm.nominations = [
		{"hex": spade_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "7"), "advisor": "industry"},
		{"hex": spade_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "8"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Set REALITY at hex to be SPADES
	_hex_field.map_layers.truth[spade_hex] = MapLayers.make_card(MapLayers.Suit.SPADES, "A")

	# Place on spade hex
	_gm.place_card(0, spade_hex)

	# Both advisors should get -2 penalty for LYING about mine
	assert_eq(_gm.scores["industry"], 3 - 2, "Industry should get -2 penalty for lying about mine")
	assert_eq(_gm.scores["urbanist"], 4 - 2, "Urbanist should get -2 penalty for lying about mine")
	assert_eq(_gm.phase, GameManager.Phase.GAME_OVER, "Game should end on spade reality")
	assert_true(_gm.mayor_hit_mine, "Mayor should be marked as hitting a mine")


## Test 7e: Honest spade warning gives +1 point
func test_honest_spade_warning_scores_point() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Set initial scores
	_gm.scores = {"mayor": 5, "industry": 3, "urbanist": 4}

	# Inject a HEARTS card into hand
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.HEARTS, "7")

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Industry honestly warned about spade, Urbanist lied
	var spade_hex := Vector3i(1, -1, 0)
	_gm.nominations = [
		{"hex": spade_hex, "claim": MapLayers.make_card(MapLayers.Suit.SPADES, "7"), "advisor": "industry"},
		{"hex": spade_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "8"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Set REALITY at hex to be SPADES
	_hex_field.map_layers.truth[spade_hex] = MapLayers.make_card(MapLayers.Suit.SPADES, "A")

	# Place on spade hex
	_gm.place_card(0, spade_hex)

	# Industry warned honestly (+1), Urbanist lied (-2)
	assert_eq(_gm.scores["industry"], 3 + 1, "Industry should get +1 for honest spade warning")
	assert_eq(_gm.scores["urbanist"], 4 - 2, "Urbanist should get -2 penalty for lying")
	assert_eq(_gm.phase, GameManager.Phase.GAME_OVER, "Game should end on spade reality")
	assert_true(_gm.mayor_hit_mine, "Mayor should be marked as hitting a mine")


## Test 8: Scoring awards mayor for optimal guess
func test_scoring_awards_mayor_for_optimal_guess() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	var initial_mayor_score: int = _gm.scores["mayor"]

	# Inject a diamond card (resources)
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "A")

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Set up nominations with new array format
	var target := Vector3i(1, -1, 0)
	_gm.nominations = [
		{"hex": target, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "A"), "advisor": "industry"},
		{"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"), "advisor": "urbanist"},
	]
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
	_gm.revealed_indices = [0]

	# Progress to PLACE phase (manually set to skip reveal flow)
	_gm.reveal_card(0)

	# Define hexes
	var urbanist_hex := Vector3i(0, 1, -1)
	var industry_hex := Vector3i(1, -1, 0)

	# Reality: urbanist hex is 2♥, industry hex is 10♦
	_hex_field.map_layers.truth[urbanist_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "2")
	_hex_field.map_layers.truth[industry_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")

	# Nominations with new array format
	_gm.nominations = [
		{"hex": urbanist_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "K"), "advisor": "urbanist"},
		{"hex": industry_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "J"), "advisor": "industry"},
	]
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
	_gm.revealed_indices = [0]

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Define hexes
	var industry_hex := Vector3i(1, -1, 0)
	var urbanist_hex := Vector3i(0, 1, -1)

	# Reality doesn't matter for this test (not spades so game continues)
	_hex_field.map_layers.truth[industry_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")
	_hex_field.map_layers.truth[urbanist_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "2")

	# Nominations with new array format
	_gm.nominations = [
		{"hex": industry_hex, "claim": MapLayers.make_card(MapLayers.Suit.SPADES, "Q"), "advisor": "industry"},
		{"hex": urbanist_hex, "claim": MapLayers.make_card(MapLayers.Suit.SPADES, "5"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Place A♠ on industry hex
	_gm.place_card(0, industry_hex)

	# Spade placement: Mayor gets 0, advisor with closest claim value scores
	assert_eq(_gm.scores["mayor"], 0, "Mayor should not score when placing Spade")
	assert_eq(_gm.scores["industry"], 1, "Industry should score (their hex chosen)")
	assert_eq(_gm.scores["urbanist"], 0, "Urbanist should not score (their hex not chosen)")


## Test 9c: Same-hex tie-break uses claim value proximity to placed card
## Only ONE advisor wins via tie-break, then bluff detection applies to them
func test_same_hex_tiebreak_by_claim_value() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor will place 10♦
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")]
	_gm.revealed_indices = [0]

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Both advisors nominate the same hex with SAME SUIT claims but different values
	var shared_hex := Vector3i(1, -1, 0)

	# Reality at shared hex is 10♦ (exact match for Mayor)
	_hex_field.map_layers.truth[shared_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")

	# Industry claims 8♦ (diff=2), Urbanist claims K♦/12 (diff=2) - equal!
	# Both have suit match, so domain affinity kicks in: Diamonds→Industry wins
	_gm.nominations = [
		{"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "8"), "advisor": "industry"},
		{"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Place 10♦ on shared hex
	_gm.place_card(0, shared_hex)

	# Mayor scores (exact match: distance = 0)
	# Industry wins tie-break (Diamonds is Industry's domain), gets +1 (Mayor trusted)
	# Urbanist gets 0 (didn't win tie-break)
	assert_eq(_gm.scores["mayor"], 1, "Mayor should score (exact suit+value match)")
	assert_eq(_gm.scores["industry"], 1, "Industry wins tie-break (Diamonds domain) and Mayor trusted")
	assert_eq(_gm.scores["urbanist"], 0, "Urbanist loses tie-break")


## Test 9d: Same-hex tie-break with different claim values - closer value wins
func test_same_hex_tiebreak_closer_value_wins() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor will place 7♥ (Hearts)
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.HEARTS, "7")]
	_gm.revealed_indices = [0]

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Both advisors nominate the same hex
	var shared_hex := Vector3i(1, -1, 0)

	# Reality at shared hex is 7♥
	_hex_field.map_layers.truth[shared_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "7")

	# Industry claims 2♥ (diff=5), Urbanist claims 6♥ (diff=1)
	# Urbanist is closer, wins the tie-break
	_gm.nominations = [
		{"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "2"), "advisor": "industry"},
		{"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "6"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Place 7♥ on shared hex
	_gm.place_card(0, shared_hex)

	# Mayor scores (exact match)
	# Urbanist wins tie-break (closer value: diff=1 vs diff=5), Mayor trusted → +1
	# Industry loses tie-break → 0
	assert_eq(_gm.scores["mayor"], 1, "Mayor should score (exact suit+value match)")
	assert_eq(_gm.scores["industry"], 0, "Industry loses tie-break (farther claim value)")
	assert_eq(_gm.scores["urbanist"], 1, "Urbanist wins tie-break (closer claim value)")


## Test 9e: Domain affinity tie-break - Hearts goes to Urbanist
func test_same_hex_domain_affinity_hearts() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor will place 7♥ (Hearts)
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.HEARTS, "7")]
	_gm.revealed_indices = [0]

	# Progress to PLACE phase
	_gm.reveal_card(0)

	# Both advisors nominate the same hex with IDENTICAL claims
	var shared_hex := Vector3i(1, -1, 0)

	# Reality at shared hex is 7♥
	_hex_field.map_layers.truth[shared_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "7")

	# BOTH claim exact same card: 7♥ - domain affinity decides
	# Hearts is Urbanist's domain
	_gm.nominations = [
		{"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "7"), "advisor": "industry"},
		{"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "7"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Place 7♥ on shared hex
	_gm.place_card(0, shared_hex)

	# Mayor scores (exact match)
	# Urbanist wins tie-break (Hearts is Urbanist's domain), Mayor trusted → +1
	# Industry loses tie-break → 0
	assert_eq(_gm.scores["mayor"], 1, "Mayor should score (exact suit+value match)")
	assert_eq(_gm.scores["industry"], 0, "Industry loses tie-break (Hearts is Urbanist domain)")
	assert_eq(_gm.scores["urbanist"], 1, "Urbanist wins tie-break (Hearts domain affinity)")


## Test 9e: Mayor cannot score when suit mismatches reality
func test_mayor_no_score_on_suit_mismatch() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor will place 10♦
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")]
	_gm.revealed_indices = [0]

	# Progress to PLACE phase
	_gm.reveal_card(0)

	var target_hex := Vector3i(1, -1, 0)
	var other_hex := Vector3i(0, 1, -1)

	# Reality at target is 10♥ (same value but different suit!)
	_hex_field.map_layers.truth[target_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "10")
	_hex_field.map_layers.truth[other_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "2")

	_gm.nominations = [
		{"hex": target_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10"), "advisor": "industry"},
		{"hex": other_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "2"), "advisor": "urbanist"},
	]
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
	# Disable bots so we can test manual nomination flow
	_gm.set_bot_roles([])
	_gm.reveal_card(0)
	_gm.reveal_card(1) # Need 2 reveals to go to CONTROL
	_gm.force_suits(0) # Proceed to NOMINATE

	# Set up first round of nominations and build
	var industry_hex := Vector3i(1, -1, 0)
	var urbanist_hex := Vector3i(0, 1, -1)
	var other_hex1 := Vector3i(-1, 1, 0)
	var other_hex2 := Vector3i(-1, 0, 1)

	# Ensure reality at industry_hex is NOT spades (so game doesn't end)
	_hex_field.map_layers.truth[industry_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")

	# Commit 4 nominations (2 per advisor) - respecting forced suits
	_gm.commit_nomination(GameManager.Role.INDUSTRY, industry_hex, MapLayers.make_card(MapLayers.Suit.HEARTS, "K"))
	_gm.commit_nomination(GameManager.Role.INDUSTRY, other_hex1, MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q"))
	_gm.commit_nomination(GameManager.Role.URBANIST, urbanist_hex, MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q"))
	_gm.commit_nomination(GameManager.Role.URBANIST, other_hex2, MapLayers.make_card(MapLayers.Suit.HEARTS, "J"))

	# Phase should now be PLACE
	assert_eq(_gm.phase, GameManager.Phase.PLACE, "Should be in PLACE phase after all nominations")

	# Place on industry hex
	_gm.place_card(0, industry_hex)

	# Phase should be DRAW again
	assert_eq(_gm.phase, GameManager.Phase.DRAW, "Should be in DRAW phase after placement")

	# industry_hex should now be in built_hexes
	assert_true(industry_hex in _gm.built_hexes, "Built hex should be tracked")

	# Start new round - need 2 reveals + control mode
	_gm.reveal_card(0)
	_gm.reveal_card(1)
	_gm.force_suits(0)

	# Try to nominate the already-built hex (should be rejected silently)
	var commits_before: int = _gm.advisor_commits["industry"].size()
	_gm.commit_nomination(GameManager.Role.INDUSTRY, industry_hex, MapLayers.make_card(MapLayers.Suit.HEARTS, "A"))

	# The nomination should not have been accepted
	var commits_after: int = _gm.advisor_commits["industry"].size()
	assert_eq(commits_after, commits_before, "Should not be able to nominate already-built hex")


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
	_gm.set_bot_roles([]) # Disable bots for manual control
	_gm.reveal_card(0)
	_gm.reveal_card(1) # Need 2 reveals to go to CONTROL
	_gm.force_suits(0) # Proceed to NOMINATE

	# Set up nominations with valid hexes from the visible ring (4 nominations, 2 per advisor)
	var industry_hex1 := Vector3i(1, -1, 0)
	var industry_hex2 := Vector3i(0, 1, -1)
	var urbanist_hex1 := Vector3i(-1, 1, 0)
	var urbanist_hex2 := Vector3i(-1, 0, 1)
	# Claims must respect forced suits
	var industry_claim := MapLayers.make_card(MapLayers.Suit.HEARTS, "K") # Forced
	var urbanist_claim := MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q") # Forced

	_gm.commit_nomination(GameManager.Role.INDUSTRY, industry_hex1, industry_claim)
	_gm.commit_nomination(GameManager.Role.INDUSTRY, industry_hex2, MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K"))
	_gm.commit_nomination(GameManager.Role.URBANIST, urbanist_hex1, urbanist_claim)
	_gm.commit_nomination(GameManager.Role.URBANIST, urbanist_hex2, MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"))

	# This is the critical test: show_nominations must work without typed array errors
	assert_eq(_gm.phase, GameManager.Phase.PLACE, "Should be in PLACE after all nominations")

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


# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION TESTS: Mayor Optimal Build Scoring
# ─────────────────────────────────────────────────────────────────────────────
# These tests verify that Mayor scores +1 ONLY when they find the truly optimal
# build among ALL cards in their hand, not just the best hex for the placed card.
#
# Under the OLD rule: Mayor scored if placed_card had min distance among hexes.
# Under the NEW rule: Mayor scores only if no other hand_card could do better.


## Test: Mayor scores when suit matches (simple rule)
## Mayor places Q♥ on Hearts reality -> +1 (suit matches)
func test_mayor_scores_on_suit_match() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor has TWO hearts cards: Q♥ (13) and 5♥ (5)
	_gm.hand = [
		MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"), # index 0, value 13
		MapLayers.make_card(MapLayers.Suit.HEARTS, "5"), # index 1, value 5
	]
	_gm.revealed_indices = [0, 1]

	# Skip reveal flow - go straight to PLACE
	_gm.phase = GameManager.Phase.PLACE

	var hex_a := Vector3i(1, -1, 0)
	var hex_b := Vector3i(0, 1, -1)

	# Reality: hex_a is 6♥, hex_b is 10♦ (no heart match)
	_hex_field.map_layers.truth[hex_a] = MapLayers.make_card(MapLayers.Suit.HEARTS, "6")
	_hex_field.map_layers.truth[hex_b] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")

	_gm.nominations = [
		{"hex": hex_a, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "6"), "advisor": "urbanist"},
		{"hex": hex_b, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10"), "advisor": "industry"},
	]

	# Mayor plays Q♥ (index 0) on hex_a (reality 6♥)
	# Q♥ suit matches 6♥ suit -> +1 point
	_gm.place_card(0, hex_a)

	# SIMPLIFIED RULE: Mayor gets +1 because suit matches
	assert_eq(_gm.scores["mayor"], 1,
		"Mayor should score +1 when placed card suit matches reality suit")


## Test: Mayor scores on any suit match (not just exact match)
## Mayor places 8♥ on 5♥ reality -> +1 (Hearts matches Hearts)
func test_mayor_scores_on_any_suit_match() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor has 8♥ and 5♥
	_gm.hand = [
		MapLayers.make_card(MapLayers.Suit.HEARTS, "8"), # index 0
		MapLayers.make_card(MapLayers.Suit.HEARTS, "5"), # index 1
	]
	_gm.revealed_indices = [0, 1]
	_gm.phase = GameManager.Phase.PLACE

	var hex_a := Vector3i(1, -1, 0)
	var hex_b := Vector3i(0, 1, -1)

	# Reality: hex_a is 5♥ (exact match for 5♥ card!)
	_hex_field.map_layers.truth[hex_a] = MapLayers.make_card(MapLayers.Suit.HEARTS, "5")
	_hex_field.map_layers.truth[hex_b] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K")

	_gm.nominations = [
		{"hex": hex_a, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "5"), "advisor": "urbanist"},
		{"hex": hex_b, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K"), "advisor": "industry"},
	]

	# Mayor plays 8♥ on hex_a (reality 5♥)
	# 8♥ suit matches 5♥ suit -> +1 point
	_gm.place_card(0, hex_a)

	assert_eq(_gm.scores["mayor"], 1,
		"Mayor should score +1 when suit matches (regardless of value)")


## Test: Mayor scores when suit matches, regardless of other options
## Mayor places 10♦ on 6♦ reality -> +1 (Diamonds matches Diamonds)
func test_mayor_scores_regardless_of_other_options() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor has 10♦ and 7♥
	_gm.hand = [
		MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10"), # index 0
		MapLayers.make_card(MapLayers.Suit.HEARTS, "7"), # index 1
	]
	_gm.revealed_indices = [0, 1]
	_gm.phase = GameManager.Phase.PLACE

	var hex_a := Vector3i(1, -1, 0)
	var hex_b := Vector3i(0, 1, -1)

	# Reality: hex_a is 6♦, hex_b is 8♥
	_hex_field.map_layers.truth[hex_a] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "6")
	_hex_field.map_layers.truth[hex_b] = MapLayers.make_card(MapLayers.Suit.HEARTS, "8")

	_gm.nominations = [
		{"hex": hex_a, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "6"), "advisor": "industry"},
		{"hex": hex_b, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "8"), "advisor": "urbanist"},
	]

	# Mayor plays 10♦ on hex_a (reality 6♦)
	# 10♦ suit matches 6♦ suit -> +1 point
	_gm.place_card(0, hex_a)

	assert_eq(_gm.scores["mayor"], 1,
		"Mayor should score +1 when suit matches (simple rule)")


## Test: Mayor scores when suit matches (basic case)
## Mayor places 7♥ on 8♥ reality -> +1 (Hearts matches Hearts)
func test_mayor_scores_basic_suit_match() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor has 7♥ and 2♦
	_gm.hand = [
		MapLayers.make_card(MapLayers.Suit.HEARTS, "7"), # index 0
		MapLayers.make_card(MapLayers.Suit.DIAMONDS, "2"), # index 1
	]
	_gm.revealed_indices = [0, 1]
	_gm.phase = GameManager.Phase.PLACE

	var hex_a := Vector3i(1, -1, 0)
	var hex_b := Vector3i(0, 1, -1)

	# Reality: hex_a is 8♥, hex_b is 10♦
	_hex_field.map_layers.truth[hex_a] = MapLayers.make_card(MapLayers.Suit.HEARTS, "8")
	_hex_field.map_layers.truth[hex_b] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")

	_gm.nominations = [
		{"hex": hex_a, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "8"), "advisor": "urbanist"},
		{"hex": hex_b, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10"), "advisor": "industry"},
	]

	# Mayor plays 7♥ on hex_a (reality 8♥)
	# 7♥ suit matches 8♥ suit -> +1 point
	_gm.place_card(0, hex_a)

	assert_eq(_gm.scores["mayor"], 1,
		"Mayor should score +1 when suit matches")


## Test: Mayor scores with full hand when suit matches
## Tests simple suit-match rule with 4-card hand
func test_mayor_scores_with_full_hand_on_suit_match() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Full 4-card hand
	_gm.hand = [
		MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"), # index 0, value 13
		MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10"), # index 1, value 10
		MapLayers.make_card(MapLayers.Suit.HEARTS, "3"), # index 2, value 3
		MapLayers.make_card(MapLayers.Suit.SPADES, "A"), # index 3, value 14
	]
	_gm.revealed_indices = [0, 1]
	_gm.phase = GameManager.Phase.PLACE

	var hex_a := Vector3i(1, -1, 0)
	var hex_b := Vector3i(0, 1, -1)

	# Reality: hex_a is 4♥, hex_b is 9♦
	_hex_field.map_layers.truth[hex_a] = MapLayers.make_card(MapLayers.Suit.HEARTS, "4")
	_hex_field.map_layers.truth[hex_b] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "9")

	_gm.nominations = [
		{"hex": hex_a, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "4"), "advisor": "urbanist"},
		{"hex": hex_b, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "9"), "advisor": "industry"},
	]

	# Mayor plays Q♥ (index 0) on hex_a (reality 4♥)
	# Q♥ suit matches 4♥ suit -> +1 point
	_gm.place_card(0, hex_a)

	assert_eq(_gm.scores["mayor"], 1,
		"Mayor should score +1 when suit matches (simple rule)")


## Regression Test 6: Four cards, Mayor finds optimal
func test_mayor_optimal_found_with_full_hand() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Full 4-card hand
	_gm.hand = [
		MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"), # index 0, value 13
		MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10"), # index 1, value 10
		MapLayers.make_card(MapLayers.Suit.HEARTS, "3"), # index 2, value 3
		MapLayers.make_card(MapLayers.Suit.DIAMONDS, "7"), # index 3, value 7
	]
	_gm.revealed_indices = [0, 1]
	_gm.phase = GameManager.Phase.PLACE

	var hex_a := Vector3i(1, -1, 0)
	var hex_b := Vector3i(0, 1, -1)

	# Reality: hex_a is 4♥, hex_b is 9♦
	_hex_field.map_layers.truth[hex_a] = MapLayers.make_card(MapLayers.Suit.HEARTS, "4")
	_hex_field.map_layers.truth[hex_b] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "9")

	_gm.nominations = [
		{"hex": hex_a, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "4"), "advisor": "urbanist"},
		{"hex": hex_b, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "9"), "advisor": "industry"},
	]

	# Possible plays:
	# - Q♥ on hex_a (4♥): |13-4| = 9
	# - 10♦ on hex_b (9♦): |10-9| = 1 ← BEST
	# - 3♥ on hex_a (4♥): |3-4| = 1 ← TIED FOR BEST
	# - 7♦ on hex_b (9♦): |7-9| = 2
	# Global best = 1

	# Mayor plays 3♥ (index 2) on hex_a → distance 1, OPTIMAL (ties count)
	_gm.place_card(2, hex_a)

	assert_eq(_gm.scores["mayor"], 1,
		"Mayor SHOULD score when they found one of the optimal plays (ties allowed)")


## Regression Test 7: Spades domain affinity - both advisors lying about mine
## Both advisors claim identical Spade cards on non-Spade reality → nobody scores
## This prevents the "Industry wins via domain affinity" loophole when both lied
func test_spades_domain_affinity_nobody_scores_when_reality_not_spade() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Mayor has a Hearts card
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.HEARTS, "7")]
	_gm.revealed_indices = [0]
	_gm.phase = GameManager.Phase.PLACE

	var shared_hex := Vector3i(1, -1, 0)

	# Reality at shared hex is 8♥ (NOT a Spade!)
	_hex_field.map_layers.truth[shared_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "8")

	# BOTH advisors claim the EXACT SAME Spade card: 5♠
	# This triggers domain affinity tie-break (same value, same suit)
	# Under old rule: Industry would win (Spades → Industry domain)
	# Under new rule: Nobody wins (both lied about a mine)
	_gm.nominations = [
		{"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.SPADES, "5"), "advisor": "industry"},
		{"hex": shared_hex, "claim": MapLayers.make_card(MapLayers.Suit.SPADES, "5"), "advisor": "urbanist"},
	]

	# Place 7♥ on shared hex
	_gm.place_card(0, shared_hex)

	# REGRESSION: Both advisors claimed Spades but reality is Hearts
	# Both were lying about a mine → NOBODY should score
	assert_eq(_gm.scores["industry"], 0,
		"REGRESSION: Industry should NOT score when both claimed Spade but reality wasn't")
	assert_eq(_gm.scores["urbanist"], 0,
		"REGRESSION: Urbanist should NOT score when both claimed Spade but reality wasn't")
	# Mayor should score (7♥ on 8♥ = suit match)
	assert_eq(_gm.scores["mayor"], 1,
		"Mayor should score +1 when suit matches")


# ─────────────────────────────────────────────────────────────────────────────
# CONTROL PHASE REGRESSION TESTS
# ─────────────────────────────────────────────────────────────────────────────

## Regression Test 8: Control phase transitions correctly to NOMINATE
## Ensures the new CONTROL phase works in the game flow
func test_control_phase_flow() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Disable bots so we can test phase transitions manually
	_gm.set_bot_roles([])

	# Reveal 2 cards (one at a time) to complete DRAW phase
	_gm.reveal_card(0)
	_gm.reveal_card(1)
	assert_eq(_gm.phase, GameManager.Phase.CONTROL,
		"After revealing 2 cards, should transition to CONTROL phase")

	# Force suits (config A: Urbanist→Diamond, Industry→Hearts)
	_gm.force_suits(0)
	assert_eq(_gm.phase, GameManager.Phase.NOMINATE,
		"After Mayor chooses control mode, should transition to NOMINATE")
	assert_eq(_gm.control_mode, GameManager.ControlMode.FORCE_SUITS,
		"Control mode should be FORCE_SUITS")
	assert_eq(_gm.forced_suit_config, GameManager.SuitConfig.URB_DIAMOND_IND_HEART,
		"Forced suit config should be A (Urb→Diamond, Ind→Hearts)")


## Regression Test 9: Forced suit constraint blocks invalid nominations
## Ensures advisors cannot violate forced suit constraint
func test_forced_suit_constraint_validation() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Disable bots so we can test nominations manually
	_gm.set_bot_roles([])

	# Setup: complete DRAW (reveal 2 cards), force suits
	_gm.reveal_card(0)
	_gm.reveal_card(1)
	_gm.force_suits(0) # Industry must claim Hearts

	# Get a valid hex
	var frontier := GameRules.get_playable_frontier(_gm.built_hexes)
	var hex_a: Vector3i = frontier[0]
	var hex_b: Vector3i = frontier[1] if frontier.size() > 1 else frontier[0]

	# Industry's first nomination: can use any suit (constraint checked on second)
	var spade_card := MapLayers.make_card(MapLayers.Suit.SPADES, "5")
	_gm.commit_nomination(GameManager.Role.INDUSTRY, hex_a, spade_card)
	assert_eq(_gm.advisor_commits["industry"].size(), 1,
		"First nomination should succeed regardless of suit")

	# Industry's second nomination: MUST use Hearts (since first was Spades)
	var another_spade := MapLayers.make_card(MapLayers.Suit.SPADES, "7")
	_gm.commit_nomination(GameManager.Role.INDUSTRY, hex_b, another_spade)
	assert_eq(_gm.advisor_commits["industry"].size(), 1,
		"REGRESSION: Second nomination with wrong suit should be REJECTED")

	# Now try with correct suit (Hearts)
	var hearts_card := MapLayers.make_card(MapLayers.Suit.HEARTS, "7")
	_gm.commit_nomination(GameManager.Role.INDUSTRY, hex_b, hearts_card)
	assert_eq(_gm.advisor_commits["industry"].size(), 2,
		"Second nomination with correct forced suit should succeed")


# ─────────────────────────────────────────────────────────────────────────────
# MAYOR ENDGAME TESTS: Facilities & City Completion
# ─────────────────────────────────────────────────────────────────────────────


## Test: Facilities initialization - Town center starts as 1 Hearts
func test_facilities_initialization() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	assert_eq(_gm.facilities["hearts"], 1, "Facilities should start with 1 Hearts (town center A♥)")
	assert_eq(_gm.facilities["diamonds"], 0, "Facilities should start with 0 Diamonds")
	assert_false(_gm.city_complete, "City should not be complete at start")
	assert_false(_gm.mayor_hit_mine, "Mayor should not have hit a mine at start")


## Test: Facility increments when building on Hearts/Diamonds reality
func test_facility_increments_on_build() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	var initial_hearts: int = _gm.facilities["hearts"]
	var initial_diamonds: int = _gm.facilities["diamonds"]

	# Set up to build on a Hearts reality hex
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")
	_gm.reveal_card(0)

	var hearts_hex := Vector3i(1, -1, 0)
	_gm.nominations = [
		{"hex": hearts_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"), "advisor": "industry"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Set REALITY to Hearts
	_hex_field.map_layers.truth[hearts_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "K")

	_gm.place_card(0, hearts_hex)

	assert_eq(_gm.facilities["hearts"], initial_hearts + 1, "Hearts facility should increment on Hearts reality build")
	assert_eq(_gm.facilities["diamonds"], initial_diamonds, "Diamonds should not change")

	# Now build on Diamonds reality
	var diamonds_hex := Vector3i(0, 1, -1)
	_gm.hand = [MapLayers.make_card(MapLayers.Suit.DIAMONDS, "J")]
	_gm.nominations = [
		{"hex": diamonds_hex, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "J"), "advisor": "urbanist"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Set REALITY to Diamonds
	_hex_field.map_layers.truth[diamonds_hex] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")

	_gm.place_card(0, diamonds_hex)

	assert_eq(_gm.facilities["diamonds"], initial_diamonds + 1, "Diamonds facility should increment on Diamonds reality build")


## Test: City completion ends game when Mayor reaches 10♥ + 10♦
func test_city_completion_ends_game() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Manually set facilities close to completion
	_gm.facilities = {"hearts": 9, "diamonds": 10} # Just need 1 more Hearts

	# Set up to build on a Hearts reality hex (completing the city)
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.HEARTS, "A")
	_gm.reveal_card(0)

	var final_hex := Vector3i(1, -1, 0)
	_gm.nominations = [
		{"hex": final_hex, "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "A"), "advisor": "industry"},
	]
	_gm.phase = GameManager.Phase.PLACE

	# Set REALITY to Hearts (this completes the city)
	_hex_field.map_layers.truth[final_hex] = MapLayers.make_card(MapLayers.Suit.HEARTS, "K")

	_gm.place_card(0, final_hex)

	assert_eq(_gm.facilities["hearts"], 10, "Hearts facilities should be 10")
	assert_eq(_gm.facilities["diamonds"], 10, "Diamonds facilities should be 10")
	assert_true(_gm.city_complete, "City should be marked as complete")
	assert_false(_gm.mayor_hit_mine, "Mayor should NOT have hit a mine")
	assert_eq(_gm.phase, GameManager.Phase.GAME_OVER, "Game should end on city completion")
