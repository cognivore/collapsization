extends GutTest

const MapLayers := preload("res://scripts/map_layers.gd")
const GameManager := preload("res://scripts/game_manager.gd")
const GameProtocol := preload("res://scripts/game/game_protocol.gd")


class FakeMessageType:
	const ROLE_ASSIGN := 0
	const GAME_STATE := 1
	const GAME_INTENT := 2


class FakeNet extends Node:
	var players := {1: null}
	var MessageType := FakeMessageType.new()
	func is_server() -> bool:
		return true
	func send_message(_to: int, _type: int, _data: Dictionary, _reliable := true) -> void:
		pass
	func broadcast_message(_type: int, _data: Dictionary, _reliable := true) -> void:
		pass
	func get_local_id() -> int:
		return 1


class FakeField extends Node:
	var map_layers := MapLayers.new()
	func _init():
		# Single layer now - truth maps cube directly to card
		map_layers.truth = {
			Vector3i.ZERO: MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q"),
			Vector3i(1, -1, 0): MapLayers.make_card(MapLayers.Suit.HEARTS, "10"),
			Vector3i(0, 1, -1): MapLayers.make_card(MapLayers.Suit.SPADES, "7"), # Mine for spade penalty test
		}
	func cube_ring(_center: Vector3i, _radius: int) -> Array:
		return [Vector3i(1, -1, 0), Vector3i(0, 1, -1), Vector3i(-1, 1, 0), Vector3i(-1, 0, 1), Vector3i(0, -1, 1), Vector3i(1, 0, -1)]


func test_rank_ordering_prefers_queen_over_king():
	var queen := MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")
	var king := MapLayers.make_card(MapLayers.Suit.HEARTS, "K")
	assert_eq(MapLayers.compare_rank(queen, king), 1, "Queen outranks King")


func test_best_guess_scores_mayor_and_advisor():
	var gm := GameManager.new()
	var fake_net := FakeNet.new()
	var fake_field := FakeField.new()
	add_child_autofree(fake_net)
	add_child_autofree(fake_field)
	add_child_autofree(gm)

	gm._net_mgr = fake_net
	gm._hex_field = fake_field
	gm.phase = GameManager.Phase.PLACE
	gm.hand = [MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")]
	# New format: Array of {hex, claim, advisor}
	gm.nominations = [
		{"hex": Vector3i.ZERO, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q"), "advisor": "industry"},
		{"hex": Vector3i(1, -1, 0), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "K"), "advisor": "urbanist"},
	]

	gm.place_card(0, Vector3i.ZERO)

	assert_eq(gm.scores["mayor"], 1, "Mayor gets best-guess point")
	assert_eq(gm.scores["industry"], 1, "Industry advisor gets point when chosen")


func test_draw_phase_resets_nominations() -> void:
	var gm := GameManager.new()
	add_child_autofree(gm)
	gm._init_phase_handlers()
	gm._transition_to(GameManager.Phase.DRAW)

	# New format: nominations should be empty array
	assert_eq(gm.nominations.size(), 0, "Nominations array is empty")
	assert_eq(gm._sub_phase, "industry_commit_1", "Sub-phase reset to first")


func test_commit_requires_two_nominations_per_advisor() -> void:
	var gm := GameManager.new()
	add_child_autofree(gm)
	gm._init_phase_handlers()
	gm.phase = GameManager.Phase.NOMINATE
	gm._sub_phase = "industry_commit_1"
	gm.town_center = Vector3i.ZERO
	gm.built_hexes = [Vector3i.ZERO]

	# First industry nomination
	var claim1 := MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K")
	gm.commit_nomination(GameManager.Role.INDUSTRY, Vector3i(1, 0, -1), claim1)
	assert_eq(gm.advisor_commits["industry"].size(), 1, "First industry nomination stored")
	assert_eq(gm._sub_phase, "industry_commit_2", "Sub-phase advances to second")
	assert_eq(gm.nominations.size(), 0, "Nominations not revealed yet")

	# Second industry nomination (different hex)
	var claim2 := MapLayers.make_card(MapLayers.Suit.DIAMONDS, "J")
	gm.commit_nomination(GameManager.Role.INDUSTRY, Vector3i(0, 1, -1), claim2)
	assert_eq(gm.advisor_commits["industry"].size(), 2, "Both industry nominations stored")
	assert_eq(gm._sub_phase, "urbanist_commit_1", "Sub-phase advances to urbanist")

	# First urbanist nomination
	gm.commit_nomination(GameManager.Role.URBANIST, Vector3i(-1, 1, 0), {})
	assert_eq(gm._sub_phase, "urbanist_commit_2", "Sub-phase advances")

	# Second urbanist nomination
	gm.commit_nomination(GameManager.Role.URBANIST, Vector3i(-1, 0, 1), {})
	assert_eq(gm.nominations.size(), 4, "All 4 nominations revealed")
	assert_eq(gm.phase, GameManager.Phase.PLACE, "Transitioned to PLACE")


func test_cannot_nominate_same_hex_twice() -> void:
	var gm := GameManager.new()
	add_child_autofree(gm)
	gm._init_phase_handlers()
	gm.phase = GameManager.Phase.NOMINATE
	gm._sub_phase = "industry_commit_1"
	gm.town_center = Vector3i.ZERO
	gm.built_hexes = [Vector3i.ZERO]

	# First nomination
	gm.commit_nomination(GameManager.Role.INDUSTRY, Vector3i(1, 0, -1), {})
	assert_eq(gm.advisor_commits["industry"].size(), 1, "First nomination accepted")

	# Try to nominate same hex again
	gm.commit_nomination(GameManager.Role.INDUSTRY, Vector3i(1, 0, -1), {})
	assert_eq(gm.advisor_commits["industry"].size(), 1, "Duplicate nomination rejected")


func test_place_phase_marks_built_and_scores() -> void:
	var gm := GameManager.new()
	add_child_autofree(gm)
	gm._init_phase_handlers()
	gm.phase = GameManager.Phase.PLACE
	gm.hand = [MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")]
	# New format: Array
	gm.nominations = [
		{"hex": Vector3i.ONE, "claim": {}, "advisor": "industry"},
	]

	gm.place_card(0, Vector3i.ONE)

	assert_true(Vector3i.ONE in gm.built_hexes, "Built hex recorded")
	assert_eq(gm.last_placement.get("winning_role", ""), "industry", "Winning role stored on placement")
	assert_eq(gm.phase, GameManager.Phase.DRAW, "Returns to DRAW after placement")


func test_spade_penalty_applied_when_lied_about_mine() -> void:
	var gm := GameManager.new()
	var fake_net := FakeNet.new()
	var fake_field := FakeField.new()
	add_child_autofree(fake_net)
	add_child_autofree(fake_field)
	add_child_autofree(gm)

	gm._net_mgr = fake_net
	gm._hex_field = fake_field
	gm.phase = GameManager.Phase.PLACE
	gm.hand = [MapLayers.make_card(MapLayers.Suit.HEARTS, "7")]
	gm.scores = {"mayor": 5, "industry": 3, "urbanist": 4}

	# Both advisors nominated the spade hex but LIED about it (claimed non-spade)
	gm.nominations = [
		{"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "7"), "advisor": "industry"},
		{"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "7"), "advisor": "urbanist"},
	]

	# Place on the spade hex
	gm.place_card(0, Vector3i(0, 1, -1))

	# Game should end (reality is spade)
	# Both advisors should get -2 penalty for LYING about mine
	assert_eq(gm.scores["industry"], 3 - 2, "Industry gets -2 penalty for lying about spade")
	assert_eq(gm.scores["urbanist"], 4 - 2, "Urbanist gets -2 penalty for lying about spade")
	assert_true(gm.mayor_hit_mine, "Mayor should be marked as hitting a mine")


func test_spade_honest_warning_scores_point() -> void:
	var gm := GameManager.new()
	var fake_net := FakeNet.new()
	var fake_field := FakeField.new()
	add_child_autofree(fake_net)
	add_child_autofree(fake_field)
	add_child_autofree(gm)

	gm._net_mgr = fake_net
	gm._hex_field = fake_field
	gm.phase = GameManager.Phase.PLACE
	gm.hand = [MapLayers.make_card(MapLayers.Suit.HEARTS, "7")]
	gm.scores = {"mayor": 5, "industry": 3, "urbanist": 4}

	# Industry honestly warned about spade, Urbanist lied
	gm.nominations = [
		{"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.SPADES, "7"), "advisor": "industry"},
		{"hex": Vector3i(0, 1, -1), "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "7"), "advisor": "urbanist"},
	]

	# Place on the spade hex
	gm.place_card(0, Vector3i(0, 1, -1))

	# Industry warned honestly (+1), Urbanist lied (-2)
	assert_eq(gm.scores["industry"], 3 + 1, "Industry gets +1 for honest spade warning")
	assert_eq(gm.scores["urbanist"], 4 - 2, "Urbanist gets -2 penalty for lying about spade")
	assert_true(gm.mayor_hit_mine, "Mayor should be marked as hitting a mine")


func test_bluff_detection_mayor_trusts() -> void:
	var gm := GameManager.new()
	var fake_net := FakeNet.new()
	var fake_field := FakeField.new()
	add_child_autofree(fake_net)
	add_child_autofree(fake_field)
	add_child_autofree(gm)

	gm._net_mgr = fake_net
	gm._hex_field = fake_field
	gm.phase = GameManager.Phase.PLACE
	# Mayor places a DIAMONDS card
	gm.hand = [MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")]
	gm.scores = {"mayor": 0, "industry": 0, "urbanist": 0}

	# Industry claimed DIAMONDS (Mayor will trust)
	gm.nominations = [
		{"hex": Vector3i.ZERO, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q"), "advisor": "industry"},
	]

	gm.place_card(0, Vector3i.ZERO)

	# Mayor trusted (placed suit = claim suit), so advisor gets +1 regardless of reality
	assert_eq(gm.scores["industry"], 1, "Industry gets +1 when Mayor trusts (placed suit = claim suit)")


func test_bluff_detection_mayor_calls_catches_bluff() -> void:
	var gm := GameManager.new()
	var fake_net := FakeNet.new()
	var fake_field := FakeField.new()
	add_child_autofree(fake_net)
	add_child_autofree(fake_field)
	add_child_autofree(gm)

	# Add Hearts reality at (1,-1,0) for testing
	fake_field.map_layers.truth[Vector3i(1, -1, 0)] = MapLayers.make_card(MapLayers.Suit.HEARTS, "10")

	gm._net_mgr = fake_net
	gm._hex_field = fake_field
	gm.phase = GameManager.Phase.PLACE
	# Mayor places a HEARTS card
	gm.hand = [MapLayers.make_card(MapLayers.Suit.HEARTS, "10")]
	gm.scores = {"mayor": 0, "industry": 0, "urbanist": 0}

	# Industry claimed DIAMONDS (a bluff - reality is HEARTS)
	gm.nominations = [
		{"hex": Vector3i(1, -1, 0), "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q"), "advisor": "industry"},
	]

	gm.place_card(0, Vector3i(1, -1, 0))

	# Mayor called (placed HEARTS != claimed DIAMONDS), bluff caught (claim != reality)
	assert_eq(gm.scores["industry"], 0, "Industry gets 0 when bluff caught")
	# Mayor scores because suit matches reality
	assert_eq(gm.scores["mayor"], 1, "Mayor scores when suit matches reality")


func test_bluff_detection_mayor_calls_but_advisor_honest() -> void:
	var gm := GameManager.new()
	var fake_net := FakeNet.new()
	var fake_field := FakeField.new()
	add_child_autofree(fake_net)
	add_child_autofree(fake_field)
	add_child_autofree(gm)

	# Add Hearts reality at (1,-1,0)
	fake_field.map_layers.truth[Vector3i(1, -1, 0)] = MapLayers.make_card(MapLayers.Suit.HEARTS, "10")

	gm._net_mgr = fake_net
	gm._hex_field = fake_field
	gm.phase = GameManager.Phase.PLACE
	# Mayor places a DIAMONDS card (calling the bluff)
	gm.hand = [MapLayers.make_card(MapLayers.Suit.DIAMONDS, "10")]
	gm.scores = {"mayor": 0, "industry": 0, "urbanist": 0}

	# Industry claimed HEARTS (honest - reality is HEARTS)
	gm.nominations = [
		{"hex": Vector3i(1, -1, 0), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "Q"), "advisor": "industry"},
	]

	gm.place_card(0, Vector3i(1, -1, 0))

	# Mayor called (placed DIAMONDS != claimed HEARTS), but advisor was honest
	assert_eq(gm.scores["industry"], 1, "Industry gets +1 when honest but Mayor didn't believe them")
	# Mayor doesn't score because suit doesn't match reality
	assert_eq(gm.scores["mayor"], 0, "Mayor doesn't score when suit mismatches reality")


func test_sub_phase_order() -> void:
	var gm := GameManager.new()
	add_child_autofree(gm)
	gm._init_phase_handlers()
	gm.phase = GameManager.Phase.NOMINATE
	gm._sub_phase = "industry_commit_1"

	assert_eq(gm._get_expected_role_for_sub_phase(), int(GameManager.Role.INDUSTRY), "Industry expected for industry_commit_1")

	gm._sub_phase = "industry_commit_2"
	assert_eq(gm._get_expected_role_for_sub_phase(), int(GameManager.Role.INDUSTRY), "Industry expected for industry_commit_2")

	gm._sub_phase = "urbanist_commit_1"
	assert_eq(gm._get_expected_role_for_sub_phase(), int(GameManager.Role.URBANIST), "Urbanist expected for urbanist_commit_1")

	gm._sub_phase = "urbanist_commit_2"
	assert_eq(gm._get_expected_role_for_sub_phase(), int(GameManager.Role.URBANIST), "Urbanist expected for urbanist_commit_2")


# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION TESTS: Card Circulation
# ─────────────────────────────────────────────────────────────────────────────

func test_card_circulation_total_cards_constant() -> void:
	# Regression test: Old hand cards must be discarded before drawing new ones.
	# Without this, cards are lost and deck eventually runs out.
	var gm := GameManager.new()
	add_child_autofree(gm)
	gm._rng = RandomNumberGenerator.new()
	gm._rng.seed = 12345
	gm._init_phase_handlers()
	gm._build_deck()
	gm._discard.clear()

	var total_cards := gm._deck.size()
	assert_eq(total_cards, 39, "Deck starts with 39 cards (3 suits × 13 ranks)")

	# Simulate entering DRAW phase multiple times
	for turn in range(20):
		gm._transition_to(GameManager.Phase.DRAW)
		var cards_in_circulation := gm._deck.size() + gm._discard.size() + gm.hand.size()
		assert_eq(cards_in_circulation, total_cards, "Total cards in circulation must stay constant (turn %d)" % turn)
		assert_eq(gm.hand.size(), 4, "Mayor must always get 4 cards (turn %d)" % turn)


func test_card_circulation_after_many_builds() -> void:
	# Regression test: Verify card circulation works correctly through full game cycle
	# including builds (which also discard cards)
	var gm := GameManager.new()
	var fake_net := FakeNet.new()
	var fake_field := FakeField.new()
	add_child_autofree(fake_net)
	add_child_autofree(fake_field)
	add_child_autofree(gm)

	gm._net_mgr = fake_net
	gm._hex_field = fake_field
	gm._rng = RandomNumberGenerator.new()
	gm._rng.seed = 12345
	gm._init_phase_handlers()
	gm._build_deck()
	gm._discard.clear()
	gm.built_hexes = [Vector3i.ZERO]

	var total_cards := gm._deck.size()

	# Simulate 15 full turns (draw -> nominate -> place)
	for turn in range(15):
		# DRAW phase: Mayor gets 4 cards
		gm._transition_to(GameManager.Phase.DRAW)
		assert_eq(gm.hand.size(), 4, "Mayor must get 4 cards on turn %d" % turn)

		# Setup for PLACE phase
		gm.phase = GameManager.Phase.PLACE
		var hex := Vector3i(turn + 1, - (turn + 1), 0)
		gm.nominations = [ {"hex": hex, "claim": {}, "advisor": "industry"}]

		# Place a card (this also discards 1 card)
		gm.place_card(0, hex)

		# Verify total cards stay constant
		var cards_in_circulation := gm._deck.size() + gm._discard.size() + gm.hand.size()
		assert_eq(cards_in_circulation, total_cards, "Cards must not be lost after turn %d" % turn)


func test_draw_cards_recycles_mid_draw() -> void:
	# Regression test: _draw_cards should recycle discard pile if deck runs out mid-draw
	var gm := GameManager.new()
	add_child_autofree(gm)
	gm._rng = RandomNumberGenerator.new()
	gm._rng.seed = 12345
	gm._init_phase_handlers()

	# Setup: deck has only 2 cards, discard has 10
	gm._deck = [
		MapLayers.make_card(MapLayers.Suit.HEARTS, "A"),
		MapLayers.make_card(MapLayers.Suit.HEARTS, "K"),
	]
	gm._discard = []
	for i in range(10):
		gm._discard.append(MapLayers.make_card(MapLayers.Suit.DIAMONDS, str(i + 2)))

	# Request 4 cards - should get 2 from deck, then recycle and get 2 more
	var drawn := gm._draw_cards(4)

	assert_eq(drawn.size(), 4, "Should draw 4 cards even when deck had only 2")
	assert_eq(gm._discard.size(), 0, "Discard should be empty after recycling")
