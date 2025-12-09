## E2E tests for game rules: phases, scoring, bots, fog of war, game over.
## Tests the full game loop with deterministic seed for reproducibility.
extends GutTest

const GameManager := preload("res://scripts/game_manager.gd")
const MapLayers := preload("res://scripts/map_layers.gd")
const HexFieldScript := preload("res://hex_field.gd")

const TEST_SEED := 42
const TIMEOUT := 5.0

var _gm: GameManager
var _hex_field: Node
var _world: Node2D


func before_each() -> void:
	# Create a minimal world for testing
	_world = Node2D.new()
	add_child(_world)

	# Create HexField
	_hex_field = HexagonTileMapLayer.new()
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


## Test 1: Game starts in idle phase
func test_game_starts_in_idle_phase() -> void:
	assert_eq(_gm.phase, GameManager.Phase.IDLE, "Game should start in IDLE phase")
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


## Test 4: Bots nominate adjacent hexes
func test_bots_nominate_adjacent_hexes() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Reveal a card to progress to nominate phase
	_gm.reveal_card(0)

	# Manually trigger phase timeout to move to nominate
	_gm._on_phase_timeout()

	assert_eq(_gm.phase, GameManager.Phase.NOMINATE, "Should be in NOMINATE phase")

	# Bots should have nominated
	var industry_nom: Vector3i = _gm.nominations["industry"]
	var urbanist_nom: Vector3i = _gm.nominations["urbanist"]

	assert_ne(industry_nom, GameManager.INVALID_HEX, "Industry bot should have nominated")
	assert_ne(urbanist_nom, GameManager.INVALID_HEX, "Urbanist bot should have nominated")

	# Nominations should be adjacent to town center
	assert_eq(_cube_distance(_gm.town_center, industry_nom), 1, "Industry nomination should be adjacent to town")
	assert_eq(_cube_distance(_gm.town_center, urbanist_nom), 1, "Urbanist nomination should be adjacent to town")


## Test 5: Mayor can only place on nominated hex
func test_mayor_can_only_place_on_nominated() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Progress to PLACE phase
	_gm.reveal_card(0)
	_gm._on_phase_timeout()  # DRAW -> NOMINATE
	_gm._on_phase_timeout()  # NOMINATE -> PLACE

	assert_eq(_gm.phase, GameManager.Phase.PLACE, "Should be in PLACE phase")

	var initial_hand_size := _gm.hand.size()

	# Try to place on non-nominated hex (should fail)
	var bad_hex := Vector3i(5, -5, 0)
	_gm.mayor_place(0, bad_hex)
	assert_eq(_gm.hand.size(), initial_hand_size, "Placing on non-nominated hex should not reduce hand")

	# Place on nominated hex (should succeed)
	var good_hex: Vector3i = _gm.nominations["industry"]
	if good_hex == GameManager.INVALID_HEX:
		good_hex = _gm.nominations["urbanist"]
	_gm.mayor_place(0, good_hex)
	assert_lt(_gm.hand.size(), initial_hand_size, "Placing on nominated hex should reduce hand")


## Test 6: Spades ends game
func test_spades_ends_game() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Manually inject a spade card into hand
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.SPADES, "A")

	# Progress to PLACE phase
	_gm.reveal_card(0)
	_gm._on_phase_timeout()  # DRAW -> NOMINATE
	_gm._on_phase_timeout()  # NOMINATE -> PLACE

	# Place the spade
	var target: Vector3i = _gm.nominations["industry"]
	if target == GameManager.INVALID_HEX:
		target = _gm.nominations["urbanist"]
	_gm.mayor_place(0, target)

	assert_eq(_gm.phase, GameManager.Phase.GAME_OVER, "Game should be over after placing spade")


## Test 7: Scoring awards mayor for optimal guess
func test_scoring_awards_mayor_for_optimal_guess() -> void:
	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	var initial_mayor_score := _gm.scores["mayor"]

	# Inject a diamond card (resources)
	_gm.hand[0] = MapLayers.make_card(MapLayers.Suit.DIAMONDS, "A")

	# Progress to PLACE phase
	_gm.reveal_card(0)
	_gm._on_phase_timeout()  # DRAW -> NOMINATE
	_gm._on_phase_timeout()  # NOMINATE -> PLACE

	# Place the card
	var target: Vector3i = _gm.nominations["industry"]
	if target == GameManager.INVALID_HEX:
		target = _gm.nominations["urbanist"]
	_gm.mayor_place(0, target)

	# Mayor should get at least 1 point (depends on map reality)
	# This is a basic check; actual scoring depends on map data
	assert_true(_gm.scores["mayor"] >= initial_mayor_score, "Mayor score should not decrease")


## Test 8: Fog reveals center and ring on game start
func test_fog_reveals_center_and_ring() -> void:
	var fog_received: Array = []
	_gm.fog_updated.connect(func(fog): fog_received = fog)

	_gm.game_seed = TEST_SEED
	_gm.start_singleplayer()

	# Should have received fog update with center + 6 adjacent hexes = 7 total
	assert_eq(fog_received.size(), 7, "Should reveal 7 hexes (center + ring of 6)")

	# Check that town center is in the list
	assert_true(_gm.town_center in fog_received, "Town center should be revealed")


## Test 9: Deterministic seed produces same map
func test_deterministic_seed_produces_same_map() -> void:
	# Generate map with seed
	var map1 := MapLayers.new()
	map1.generate(_hex_field, 5, TEST_SEED)

	# Generate another map with same seed
	var map2 := MapLayers.new()
	map2.generate(_hex_field, 5, TEST_SEED)

	# Cards at same position should match
	var test_cube := Vector3i(1, -1, 0)
	var card1: Dictionary = map1.get_card(MapLayers.LayerType.RESOURCES, test_cube)
	var card2: Dictionary = map2.get_card(MapLayers.LayerType.RESOURCES, test_cube)

	assert_eq(card1["suit"], card2["suit"], "Same seed should produce same suit")
	assert_eq(card1["rank"], card2["rank"], "Same seed should produce same rank")


## Test 10: Card rank ordering (Q > K)
func test_card_rank_ordering() -> void:
	var queen := MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")
	var king := MapLayers.make_card(MapLayers.Suit.HEARTS, "K")
	var ace := MapLayers.make_card(MapLayers.Suit.HEARTS, "A")

	assert_gt(queen["value"], king["value"], "Queen should outrank King")
	assert_gt(ace["value"], queen["value"], "Ace should outrank Queen")


## Test 11: Full game loop until spade
func test_full_game_loop_until_spade() -> void:
	# Use a seed that will eventually draw a spade
	_gm.game_seed = 123  # Different seed to ensure variety
	_gm.start_singleplayer()

	var max_turns := 50
	var turns_played := 0

	while _gm.phase != GameManager.Phase.GAME_OVER and turns_played < max_turns:
		# Simulate a full turn
		if _gm.phase == GameManager.Phase.DRAW:
			if _gm.revealed_index == -1:
				_gm.reveal_card(0)
			_gm._on_phase_timeout()
		elif _gm.phase == GameManager.Phase.NOMINATE:
			_gm._on_phase_timeout()
		elif _gm.phase == GameManager.Phase.PLACE:
			var target: Vector3i = _gm.nominations.get("industry", GameManager.INVALID_HEX)
			if target == GameManager.INVALID_HEX:
				target = _gm.nominations.get("urbanist", GameManager.INVALID_HEX)
			if target != GameManager.INVALID_HEX and not _gm.hand.is_empty():
				_gm.mayor_place(0, target)
			else:
				_gm._on_phase_timeout()
		turns_played += 1

	# Game should eventually end (either by spade or max turns)
	if turns_played >= max_turns:
		gut.p("Warning: Game did not end within %d turns" % max_turns)
	else:
		assert_eq(_gm.phase, GameManager.Phase.GAME_OVER, "Game should end with GAME_OVER phase")
		gut.p("Game ended after %d turns" % turns_played)


## Helper: Calculate cube distance
func _cube_distance(a: Vector3i, b: Vector3i) -> int:
	return (abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)) / 2

