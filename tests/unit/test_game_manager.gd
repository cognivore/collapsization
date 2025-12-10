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
	add_child(fake_net)
	add_child(fake_field)
	add_child(gm)

	gm._net_mgr = fake_net
	gm._hex_field = fake_field
	gm.phase = GameManager.Phase.PLACE
	gm.hand = [MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")]
	# Use new nomination format: {hex: Vector3i, claim: Dictionary}
	gm.nominations["industry"] = {"hex": Vector3i.ZERO, "claim": MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")}
	gm.nominations["urbanist"] = {"hex": Vector3i(1, -1, 0), "claim": MapLayers.make_card(MapLayers.Suit.HEARTS, "K")}

	gm.place_card(0, Vector3i.ZERO)

	assert_eq(gm.scores["mayor"], 1, "Mayor gets best-guess point")
	assert_eq(gm.scores["industry"], 1, "Industry advisor gets point when chosen")

	gm.queue_free()
	fake_net.queue_free()
	fake_field.queue_free()


func test_draw_phase_resets_nominations() -> void:
	var gm := GameManager.new()
	add_child(gm)
	gm._init_phase_handlers()
	gm._transition_to(GameManager.Phase.DRAW)

	var ind: Dictionary = gm.nominations["industry"]
	var urb: Dictionary = gm.nominations["urbanist"]
	assert_true(ind.get("hex") == GameProtocol.INVALID_HEX, "Industry hex reset to invalid")
	assert_true(urb.get("hex") == GameProtocol.INVALID_HEX, "Urbanist hex reset to invalid")
	assert_false(GameProtocol.is_valid_nomination_entry(ind), "Industry nomination not committed yet")
	assert_false(GameProtocol.is_valid_nomination_entry(urb), "Urbanist nomination not committed yet")
	gm.queue_free()


func test_commit_uses_claim_and_waits_for_both() -> void:
	var gm := GameManager.new()
	add_child(gm)
	gm._init_phase_handlers()
	gm.phase = GameManager.Phase.NOMINATE
	gm.town_center = Vector3i.ZERO
	# Town center must be in built_hexes so adjacent tiles are on the playable frontier
	gm.built_hexes = [Vector3i.ZERO]

	var claim := MapLayers.make_card(MapLayers.Suit.DIAMONDS, "K")
	gm.commit_nomination(GameManager.Role.INDUSTRY, Vector3i(1, 0, -1), claim)
	assert_true(gm.advisor_commits["industry"].get("claim", {}).get("rank") == "K", "Claim stored with nomination")
	assert_false(GameProtocol.is_valid_nomination_entry(gm.nominations["industry"]), "Nominations stay hidden until both commit")

	gm.commit_nomination(GameManager.Role.URBANIST, Vector3i(0, 1, -1), {})
	assert_true(GameProtocol.is_valid_nomination_entry(gm.nominations["industry"]), "Nominations revealed after both commit")
	assert_eq(gm.phase, GameManager.Phase.PLACE, "Transitioned to PLACE")
	gm.queue_free()


func test_place_phase_marks_built_and_scores() -> void:
	var gm := GameManager.new()
	add_child(gm)
	gm._init_phase_handlers()
	gm.phase = GameManager.Phase.PLACE
	gm.hand = [MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")]
	gm.nominations = {
		"industry": {"hex": Vector3i.ONE, "claim": {}},
		"urbanist": GameProtocol.empty_nomination(),
	}

	gm.place_card(0, Vector3i.ONE)

	assert_true(Vector3i.ONE in gm.built_hexes, "Built hex recorded")
	assert_eq(gm.last_placement.get("winning_role", ""), "industry", "Winning role stored on placement")
	assert_eq(gm.phase, GameManager.Phase.DRAW, "Returns to DRAW after placement")
	gm.queue_free()
