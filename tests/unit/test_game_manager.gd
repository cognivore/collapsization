extends GutTest

const MapLayers := preload("res://scripts/map_layers.gd")
const GameManager := preload("res://scripts/game_manager.gd")


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
