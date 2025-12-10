extends RefCounted
class_name NominatePhase

## Reset commits and emit updates.
func enter(gm) -> void:
	gm._reset_nominations_state()
	gm.nominations_updated.emit(gm.nominations)
	gm.commits_updated.emit(gm._get_commit_status())


func commit(gm, role: int, hex: Vector3i, claimed_card: Dictionary = {}) -> void:
	if gm.phase != gm.Phase.NOMINATE:
		return
	# is_valid_nomination checks: not invalid, not built, adjacent to any built hex
	if not gm.GameRules.is_valid_nomination(hex, gm.built_hexes):
		return

	var role_key: String = gm._role_to_key(role)
	if role_key.is_empty():
		return

	gm.advisor_commits[role_key] = {"hex": hex, "claim": claimed_card}
	gm.commits_updated.emit(gm._get_commit_status())
	gm._broadcast_state()

	if gm._all_advisors_committed():
		_reveal_and_transition(gm)


func _reveal_and_transition(gm) -> void:
	gm._reveal_nominations()


func reveal_and_transition(gm) -> void:
	_reveal_and_transition(gm)

