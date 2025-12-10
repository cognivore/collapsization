extends RefCounted
class_name NominatePhase

const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)

## Reset commits and emit updates.
func enter(gm) -> void:
	gm.advisor_commits = {"industry": INVALID_HEX, "urbanist": INVALID_HEX}
	gm.nominations = {"industry": INVALID_HEX, "urbanist": INVALID_HEX}
	gm.nominations_updated.emit(gm.nominations)
	gm.commits_updated.emit(gm._get_commit_status())


func commit(gm, role: int, hex: Vector3i) -> void:
	if gm.phase != gm.Phase.NOMINATE:
		return
	if not gm.GameRules.is_valid_nomination(gm.town_center, hex):
		return

	var role_key := gm._protocol.role_to_key(role)
	if role_key.is_empty():
		return

	gm.advisor_commits[role_key] = hex
	gm.commits_updated.emit(gm._get_commit_status())
	gm._broadcast_state()

	if gm.GameRules.all_advisors_committed(gm.advisor_commits):
		_reveal_and_transition(gm)


func _reveal_and_transition(gm) -> void:
	gm.nominations["industry"] = gm.advisor_commits["industry"]
	gm.nominations["urbanist"] = gm.advisor_commits["urbanist"]
	gm.nominations_updated.emit(gm.nominations)
	gm._transition_to(gm.Phase.PLACE)


func reveal_and_transition(gm) -> void:
	_reveal_and_transition(gm)

