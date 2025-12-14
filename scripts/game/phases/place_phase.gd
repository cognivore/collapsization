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

	# Capture full hand BEFORE modifying (needed for optimal build scoring)
	var full_hand: Array = gm.hand.duplicate(true)

	var card: Dictionary = gm.hand[card_index]
	gm.hand.remove_at(card_index)

	# Track built hex to prevent re-nomination
	gm.built_hexes.append(hex)

	# Expand fog around newly built hex - reveals adjacent tiles for future nominations
	gm._expand_fog_around(hex)

	# Determine winning advisor (whose nomination was chosen)
	# If both nominated same hex, winner is determined by claim proximity
	var winning_role: String = gm._get_nominating_role(hex, card)
	var winning_claim: Dictionary = {}
	if not winning_role.is_empty():
		# Find the winning nomination's claim from the array
		for nom in gm.nominations:
			if nom.get("hex") == hex and nom.get("advisor") == winning_role:
				winning_claim = nom.get("claim", {})
				break

	var placement: Dictionary = {
		"turn": gm.turn_index,
		"card": card,
		"cube": hex,
		"winning_role": winning_role,
		"winning_claim": winning_claim
	}
	gm.last_placement = placement
	gm._discard.append(card)

	var score_deltas: Dictionary = gm._calculate_scores_with_claims(card, hex, gm.nominations, full_hand)
	gm.scores["mayor"] += score_deltas["mayor"]
	gm.scores["industry"] += score_deltas["industry"]
	gm.scores["urbanist"] += score_deltas["urbanist"]

	# Record turn history for deduction
	var reality: Dictionary = gm._get_reality(hex)
	gm.turn_history.append({
		"turn": gm.turn_index,
		"revealed_indices": gm.revealed_indices.duplicate(),
		"nominations": gm.nominations.duplicate(true),
		"build": {"hex": hex, "card": card.duplicate()},
		"reality": reality.duplicate(),
		"scores_delta": score_deltas.duplicate(),
	})

	gm.placement_resolved.emit(gm.turn_index, placement)
	gm.scores_updated.emit(gm.scores)
	gm.hand_updated.emit(gm.hand, gm.revealed_indices)
	gm._broadcast_state()

	# Check if the REALITY at this hex is SPADES (not the placed card!)
	# Game ends when Mayor builds on a tile that is actually a spade in reality
	var reality_is_spade: bool = gm._check_reality_is_spade(hex, card)
	if reality_is_spade:
		gm._finish_game("Mayor built on a SPADE tile! (Advisor may have lied)")
		return

	gm.turn_index += 1
	gm._transition_to(gm.Phase.DRAW)
