extends RefCounted
class_name DrawPhase

## Enter DRAW: deal cards, reset nominations, notify HUD.
## Note: last_placement is NOT cleared here - it persists so UI can show previous turn info
func enter(gm) -> void:
	gm.hand = gm._draw_cards(3)
	gm.revealed_index = -1
	gm._reset_nominations_state()
	gm.hand_updated.emit(gm.hand, gm.revealed_index)
	gm.nominations_updated.emit(gm.nominations) # Clear nomination overlays


## Mayor reveals one card -> transitions to NOMINATE.
func reveal(gm, index: int) -> void:
	if gm.phase != gm.Phase.DRAW:
		return
	if not gm.GameRules.is_valid_card_index(index, gm.hand.size()):
		return
	if gm.revealed_index >= 0:
		return

	gm.revealed_index = index
	gm.hand_updated.emit(gm.hand, gm.revealed_index)
	gm._transition_to(gm.Phase.NOMINATE)
