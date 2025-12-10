extends RefCounted
class_name DrawPhase

const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)

## Enter DRAW: deal cards, reset nominations, notify HUD.
func enter(gm) -> void:
	gm.hand = gm._draw_cards(3)
	gm.revealed_index = -1
	gm.advisor_commits = {"industry": INVALID_HEX, "urbanist": INVALID_HEX}
	gm.nominations = {"industry": INVALID_HEX, "urbanist": INVALID_HEX}
	gm.last_placement.clear()
	gm.hand_updated.emit(gm.hand, gm.revealed_index)


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

