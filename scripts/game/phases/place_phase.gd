extends RefCounted
class_name PlacePhase

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

	# Track built hex to prevent re-nomination
	gm.built_hexes.append(hex)

	# Expand fog around newly built hex - reveals adjacent tiles for future nominations
	gm._expand_fog_around(hex)

	# Determine winning advisor (whose nomination was chosen)
	# If both nominated same hex, winner is determined by placed card suit
	var winning_role: String = gm._get_nominating_role(hex, card)
	var winning_claim: Dictionary = {}
	if not winning_role.is_empty():
		winning_claim = gm.nominations[winning_role].get("claim", {})

	var placement: Dictionary = {
		"turn": gm.turn_index,
		"card": card,
		"cube": hex,
		"winning_role": winning_role,
		"winning_claim": winning_claim
	}
	gm.last_placement = placement
	gm._discard.append(card)

	var score_deltas: Dictionary = gm._calculate_scores_with_claims(card, hex, gm.nominations)
	gm.scores["mayor"] += score_deltas["mayor"]
	gm.scores["industry"] += score_deltas["industry"]
	gm.scores["urbanist"] += score_deltas["urbanist"]

	gm.placement_resolved.emit(gm.turn_index, placement)
	gm.scores_updated.emit(gm.scores)
	gm.hand_updated.emit(gm.hand, gm.revealed_index)
	gm._broadcast_state()

	# Check if the REALITY at this hex is SPADES (not the placed card!)
	# Game ends when Mayor builds on a tile that is actually a spade in reality
	var reality_is_spade: bool = gm._check_reality_is_spade(hex, card)
	if reality_is_spade:
		gm._finish_game("Mayor built on a SPADE tile! (Advisor may have lied)")
		return

	gm.turn_index += 1
	gm._transition_to(gm.Phase.DRAW)

