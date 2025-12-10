extends RefCounted
class_name PlacePhase

const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)

func enter(_gm) -> void:
	# Placeholder hook for future per-phase setup (animations, timers, etc.)
	pass


func place(gm, card_index: int, hex: Vector3i) -> void:
	if gm.phase != gm.Phase.PLACE:
		return
	if not gm.GameRules.is_valid_card_index(card_index, gm.hand.size()):
		return
	if not gm.GameRules.is_nominated_hex(hex, gm.nominations):
		return

	var card: Dictionary = gm.hand[card_index]
	gm.hand.remove_at(card_index)

	var placement := {"turn": gm.turn_index, "card": card, "cube": hex}
	gm.last_placement = placement
	gm._discard.append(card)

	var score_deltas: Dictionary = gm.GameRules.calculate_turn_scores(
		card, hex, gm.nominations, gm._get_reality
	)
	gm.scores["mayor"] += score_deltas["mayor"]
	gm.scores["industry"] += score_deltas["industry"]
	gm.scores["urbanist"] += score_deltas["urbanist"]

	gm.placement_resolved.emit(gm.turn_index, placement)
	gm.scores_updated.emit(gm.scores)
	gm.hand_updated.emit(gm.hand, gm.revealed_index)
	gm._broadcast_state()

	if gm.GameRules.is_spade(card):
		gm._finish_game("Mayor built on SPADES!")
		return

	gm.turn_index += 1
	gm._transition_to(gm.Phase.DRAW)

