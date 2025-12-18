extends RefCounted
class_name NominatePhase

## Sub-phase order: industry_commit_1 -> industry_commit_2 -> urbanist_commit_1 -> urbanist_commit_2 -> place_ready
const SUB_PHASE_ORDER := ["industry_commit_1", "industry_commit_2", "urbanist_commit_1", "urbanist_commit_2", "place_ready"]

## Reset commits and emit updates.
func enter(gm) -> void:
	gm._reset_nominations_state()
	gm.nominations_updated.emit(gm.nominations)
	gm.commits_updated.emit(gm._get_commit_status())


func commit(gm, role: int, hex: Vector3i, claimed_card: Dictionary = {}) -> void:
	# #region agent log
	gm._debug_log("H_C", "nominate_commit_entry", {"role": role, "hex": [hex.x, hex.y, hex.z], "claim": claimed_card, "sub_phase": gm._sub_phase, "phase": gm.Phase.keys()[gm.phase]})
	# #endregion
	if gm.phase != gm.Phase.NOMINATE:
		# #region agent log
		gm._debug_log("H_C", "nominate_commit_wrong_phase", {"current_phase": gm.Phase.keys()[gm.phase]})
		# #endregion
		return

	# Validate sub-phase matches expected role
	var expected_role := _get_expected_role(gm._sub_phase)
	if role != expected_role:
		# #region agent log
		gm._debug_log("H_C", "nominate_commit_wrong_role", {"role": role, "expected": expected_role})
		# #endregion
		return

	# is_valid_nomination checks: not invalid, not built, adjacent to any built hex
	if not gm.GameRules.is_valid_nomination(hex, gm.built_hexes):
		# #region agent log
		gm._debug_log("H_C", "nominate_commit_invalid_hex", {"hex": [hex.x, hex.y, hex.z], "built_hexes": gm.built_hexes.map(func(h): return [h.x, h.y, h.z])})
		# #endregion
		return

	var role_key: String = gm._role_to_key(role)
	if role_key.is_empty():
		return

	# Check if this is first or second nomination
	var commits_array: Array = gm.advisor_commits[role_key]
	var is_first_nom: bool = commits_array.size() == 0
	var first_claim_suit: int = -1
	if not is_first_nom and commits_array.size() > 0:
		var first_claim: Dictionary = commits_array[0].get("claim", {})
		first_claim_suit = first_claim.get("suit", -1)

	# Validate forced hex constraint (if FORCE_HEXES mode)
	var forced_hex: Vector3i = gm.get_forced_hex_for_role(role_key)
	if not gm.GameRules.satisfies_forced_hex(hex, forced_hex, is_first_nom):
		# #region agent log
		gm._debug_log("H_C", "nominate_commit_forced_hex_fail", {"hex": [hex.x, hex.y, hex.z], "forced_hex": [forced_hex.x, forced_hex.y, forced_hex.z], "is_first": is_first_nom})
		# #endregion
		return

	# Validate forced suit constraint (if FORCE_SUITS mode)
	var forced_suit: int = gm.get_forced_suit_for_role(role_key)
	if not gm.GameRules.satisfies_forced_suit(claimed_card, forced_suit, is_first_nom, first_claim_suit):
		# #region agent log
		gm._debug_log("H_C", "nominate_commit_forced_suit_fail", {"claim_suit": claimed_card.get("suit", -1), "forced_suit": forced_suit, "is_first": is_first_nom, "first_claim_suit": first_claim_suit})
		# #endregion
		return

	# Prevent same hex twice for same advisor
	for existing in gm.advisor_commits[role_key]:
		if existing.get("hex") == hex:
			# #region agent log
			gm._debug_log("H_A", "nominate_commit_duplicate_hex", {"role": role_key, "hex": [hex.x, hex.y, hex.z], "existing_commits": gm.advisor_commits[role_key].map(func(c): return [c.hex.x, c.hex.y, c.hex.z])})
			# #endregion
			return # Already nominated this hex

	# Append to array of nominations for this role
	gm.advisor_commits[role_key].append({"hex": hex, "claim": claimed_card})
	# #region agent log
	gm._debug_log("H_C", "nominate_commit_success", {"role": role_key, "hex": [hex.x, hex.y, hex.z], "new_sub_phase": _next_sub_phase(gm._sub_phase), "total_commits": gm.advisor_commits[role_key].size()})
	# #endregion

	# Advance to next sub-phase
	gm._sub_phase = _next_sub_phase(gm._sub_phase)

	gm.commits_updated.emit(gm._get_commit_status())
	gm._broadcast_state()

	# Check if all nominations complete
	if gm._sub_phase == "place_ready":
		_reveal_and_transition(gm)
	else:
		# Trigger bot action for next advisor if needed
		gm._trigger_bot_actions_if_needed()


func _get_expected_role(sub_phase: String) -> int:
	match sub_phase:
		"industry_commit_1", "industry_commit_2":
			return 1 # Role.INDUSTRY
		"urbanist_commit_1", "urbanist_commit_2":
			return 2 # Role.URBANIST
		_:
			return -1


func _next_sub_phase(current: String) -> String:
	var idx := SUB_PHASE_ORDER.find(current)
	if idx >= 0 and idx < SUB_PHASE_ORDER.size() - 1:
		return SUB_PHASE_ORDER[idx + 1]
	return "place_ready"


func _reveal_and_transition(gm) -> void:
	gm._reveal_nominations()


func reveal_and_transition(gm) -> void:
	_reveal_and_transition(gm)


## Get current nomination count for a role
func get_nomination_count(gm, role_key: String) -> int:
	return gm.advisor_commits.get(role_key, []).size()


## Check if it's a specific role's turn to nominate
func is_role_turn(gm, role: int) -> bool:
	return _get_expected_role(gm._sub_phase) == role
