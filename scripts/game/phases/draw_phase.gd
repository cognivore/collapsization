extends RefCounted
class_name DrawPhase

## Enter DRAW: deal cards, reset nominations, notify HUD.
## Note: last_placement is NOT cleared here - it persists so UI can show previous turn info
func enter(gm) -> void:
	# #region agent log
	var _old_hand_size: int = gm.hand.size()
	var _deck_before: int = gm._deck.size()
	var _discard_before: int = gm._discard.size()
	# #endregion
	# Discard old hand cards before drawing new ones (keeps all cards in circulation)
	for card in gm.hand:
		gm._discard.append(card)
	gm.hand = gm._draw_cards(4) # Mayor now draws 4 cards
	# #region agent log
	gm._debug_log("H_CARDS", "draw_phase_enter", {"turn": gm.turn_index, "old_hand_size": _old_hand_size, "deck_before": _deck_before, "discard_before": _discard_before, "deck_after": gm._deck.size(), "discard_after": gm._discard.size(), "new_hand_size": gm.hand.size()})
	# #endregion
	gm.revealed_indices.clear() # Reset revealed cards
	gm._reset_nominations_state()
	gm.hand_updated.emit(gm.hand, gm.revealed_indices)
	gm.nominations_updated.emit(gm.nominations) # Clear nomination overlays


## Mayor reveals one card. After 2 cards revealed -> transitions to NOMINATE.
func reveal(gm, index: int) -> void:
	if gm.phase != gm.Phase.DRAW:
		return
	if not gm.GameRules.is_valid_card_index(index, gm.hand.size()):
		return
	if index in gm.revealed_indices:
		return # Already revealed this card
	if gm.revealed_indices.size() >= 2:
		return # Already revealed 2 cards

	gm.revealed_indices.append(index)
	gm.hand_updated.emit(gm.hand, gm.revealed_indices)

	# Transition to NOMINATE only after both cards revealed
	if gm.revealed_indices.size() >= 2:
		gm._transition_to(gm.Phase.NOMINATE)
