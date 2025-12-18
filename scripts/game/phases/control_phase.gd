extends RefCounted
class_name ControlPhase

## CONTROL Phase: Mayor chooses how to constrain Advisors
## Options:
##   A. Force Suits: Urbanist→Diamond or Heart, Industry→Heart or Diamond
##   B. Force Hexes: Mayor picks one hex per advisor that they MUST nominate

const DEBUG_LOG_PATH := "/Users/sweater/Github/collapsization-red/.cursor/debug.log"

func _debug_log(hypothesis: String, message: String, data: Dictionary = {}) -> void:
	var log_entry := {
		"timestamp": Time.get_unix_time_from_system() * 1000,
		"location": "control_phase.gd",
		"hypothesisId": hypothesis,
		"message": message,
		"data": data,
		"sessionId": "debug-session"
	}
	var file := FileAccess.open(DEBUG_LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(DEBUG_LOG_PATH, FileAccess.WRITE)
	if file:
		file.seek_end()
		file.store_line(JSON.stringify(log_entry))
		file.close()

## Enter CONTROL: notify UI that Mayor needs to make a choice
func enter(gm) -> void:
	# #region agent log
	_debug_log("H_CTRL", "control_phase_enter", {"turn": gm.turn_index})
	# #endregion
	# Reset control state from previous turn
	gm.control_mode = gm.ControlMode.NONE
	gm.forced_suit_config = gm.SuitConfig.URB_DIAMOND_IND_HEART
	gm.forced_hexes = {}

	# Emit signal for UI to show control options
	# (This will be handled by GameHUD)
	gm.phase_changed.emit(gm.phase)


## Mayor chooses to force suit assignments
## config: 0 = Urb→Diamond, Ind→Heart; 1 = Urb→Heart, Ind→Diamond
func force_suits(gm, config: int) -> void:
	# #region agent log
	_debug_log("H_CTRL", "force_suits_called", {"config": config, "current_phase": gm.Phase.keys()[gm.phase]})
	# #endregion
	if gm.phase != gm.Phase.CONTROL:
		# #region agent log
		_debug_log("H_CTRL", "force_suits_wrong_phase", {"current_phase": gm.Phase.keys()[gm.phase]})
		# #endregion
		return

	gm.control_mode = gm.ControlMode.FORCE_SUITS
	gm.forced_suit_config = config # SuitConfig enum value
	gm.forced_hexes = {}

	print("[CONTROL] Mayor forced suits: config=%d" % config)
	# #region agent log
	_debug_log("H_CTRL", "force_suits_transitioning", {"control_mode": "FORCE_SUITS", "config": config})
	# #endregion
	_transition_to_nominate(gm)


## Mayor chooses to force hex assignments
## urbanist_hex: The hex Urbanist MUST include in their nominations
## industry_hex: The hex Industry MUST include in their nominations
func force_hexes(gm, urbanist_hex: Vector3i, industry_hex: Vector3i) -> void:
	if gm.phase != gm.Phase.CONTROL:
		return

	gm.control_mode = gm.ControlMode.FORCE_HEXES
	gm.forced_suit_config = gm.SuitConfig.URB_DIAMOND_IND_HEART # Not used
	gm.forced_hexes = {
		"urbanist": urbanist_hex,
		"industry": industry_hex,
	}

	print("[CONTROL] Mayor forced hexes: urb=%v, ind=%v" % [urbanist_hex, industry_hex])
	_transition_to_nominate(gm)


func _transition_to_nominate(gm) -> void:
	gm._transition_to(gm.Phase.NOMINATE)
