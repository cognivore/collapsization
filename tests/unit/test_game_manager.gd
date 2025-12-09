extends "res://addons/gut/test.gd"

const MapLayers := preload("res://scripts/map_layers.gd")
const GameManager := preload("res://scripts/game_manager.gd")

class FakeMessageType:
	const ROLE_ASSIGN := 0
	const GAME_STATE := 1
	const GAME_INTENT := 2


class FakeNet:
	var players := {1: null}
	var MessageType := FakeMessageType
	func is_server() -> bool:
		return true
	func send_message(_to: int, _type: int, _data: Dictionary, _reliable := true) -> void:
		pass
	func broadcast_message(_type: int, _data: Dictionary, _reliable := true) -> void:
		pass
	func get_local_id() -> int:
		return 1


class FakeField:
	var map_layers := MapLayers.new()
	func _init():
		map_layers.truth = {
			MapLayers.LayerType.RESOURCES: {Vector3i.ZERO: MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")},
			MapLayers.LayerType.DESIRABILITY: {Vector3i.ZERO: MapLayers.make_card(MapLayers.Suit.HEARTS, "10")},
		}


func test_rank_ordering_prefers_queen_over_king():
	var queen := MapLayers.make_card(MapLayers.Suit.HEARTS, "Q")
	var king := MapLayers.make_card(MapLayers.Suit.HEARTS, "K")
	assert_eq(MapLayers.compare_rank(queen, king), 1, "Queen outranks King")


func test_best_guess_scores_mayor_and_advisor():
	var gm := GameManager.new()
	gm._net_mgr = FakeNet.new()
	gm._hex_field = FakeField.new()
	gm.phase = GameManager.Phase.PLACE
	gm.hand = [MapLayers.make_card(MapLayers.Suit.DIAMONDS, "Q")]
	gm.nominations["industry"] = Vector3i.ZERO
	gm.nominations["urbanist"] = Vector3i(1, -1, 0)

	gm.mayor_place(0, Vector3i.ZERO)

	assert_eq(gm.scores["mayor"], 1, "Mayor gets best-guess point")
	assert_eq(gm.scores["industry"], 1, "Industry advisor gets point when chosen")

