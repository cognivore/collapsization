## Pure helpers for serializing roles, hexes, and placements for network sync.
extends RefCounted
class_name GameProtocol

const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)

static func role_to_key(role: int) -> String:
	match role:
		0: return "mayor"
		1: return "industry"
		2: return "urbanist"
		_: return ""


static func hex_to_string(hex: Vector3i) -> String:
	return "(%d,%d,%d)" % [hex.x, hex.y, hex.z]


static func serialize_hex_dict(dict: Dictionary) -> Dictionary:
	var result := {}
	for k in dict.keys():
		var v: Vector3i = dict[k]
		result[k] = [v.x, v.y, v.z]
	return result


static func deserialize_hex_dict(data: Dictionary) -> Dictionary:
	var result := {}
	for k in data.keys():
		var arr: Array = data[k]
		if arr.size() == 3:
			result[k] = Vector3i(arr[0], arr[1], arr[2])
	return result


## Serialize nominations: Array of {hex: Vector3i, claim: Dict, advisor: String} -> network format
static func serialize_nominations(nominations: Array) -> Array:
	var result: Array = []
	for nom in nominations:
		var hex: Vector3i = nom.get("hex", INVALID_HEX)
		result.append({
			"hex": [hex.x, hex.y, hex.z],
			"claim": nom.get("claim", {}),
			"advisor": nom.get("advisor", "")
		})
	return result


## Deserialize nominations: network format -> Array of {hex: Vector3i, claim: Dict, advisor: String}
static func deserialize_nominations(data: Array) -> Array:
	var result: Array = []
	for nom_data in data:
		if not (nom_data is Dictionary):
			continue
		var arr: Array = nom_data.get("hex", [])
		var hex := INVALID_HEX
		if arr.size() == 3:
			hex = Vector3i(arr[0], arr[1], arr[2])
		result.append({
			"hex": hex,
			"claim": nom_data.get("claim", {}),
			"advisor": nom_data.get("advisor", "")
		})
	return result


static func serialize_placement(p: Dictionary) -> Dictionary:
	if p.is_empty():
		return {}
	return {
		"turn": p.get("turn", 0),
		"card": p.get("card", {}),
		"cube": _serialize_hex(p.get("cube", INVALID_HEX)),
	}


static func deserialize_placement(data: Dictionary) -> Dictionary:
	if data.is_empty():
		return {}
	var arr: Array = data.get("cube", [])
	var cube := INVALID_HEX
	if arr.size() == 3:
		cube = Vector3i(arr[0], arr[1], arr[2])
	return {
		"turn": data.get("turn", 0),
		"card": data.get("card", {}),
		"cube": cube,
	}


static func _serialize_hex(hex: Vector3i) -> Array:
	return [hex.x, hex.y, hex.z]


static func serialize_built_hexes(built_hexes: Array) -> Array:
	var result: Array = []
	for h in built_hexes:
		if h is Vector3i:
			result.append(_serialize_hex(h))
	return result


static func serialize_town_center(hex: Vector3i) -> Array:
	return _serialize_hex(hex)


static func serialize_hand_for_role(role: int, hand: Array, revealed_indices: Array) -> Dictionary:
	if role == 0:
		return {"cards": hand, "revealed_indices": revealed_indices}
	# Advisors see only the revealed cards
	var visible: Array = []
	for idx in revealed_indices:
		if idx >= 0 and idx < hand.size():
			visible.append(hand[idx])
	if not visible.is_empty():
		return {"visible": visible, "revealed_indices": revealed_indices}
	return {}


static func serialize_visibility_entry(cube: Vector3i, card: Dictionary) -> Dictionary:
	return {"cube": _serialize_hex(cube), "card": card}


## Deserialize built_hexes array from network format
static func deserialize_built_hexes(data: Array) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for arr in data:
		if arr is Array and arr.size() == 3:
			result.append(Vector3i(arr[0], arr[1], arr[2]))
	return result


## Serialize turn history for network sync
## Each entry: {turn, revealed_indices, nominations, build, reality, scores_delta}
static func serialize_turn_history(history: Array) -> Array:
	var result: Array = []
	for entry in history:
		var hex: Vector3i = entry.get("build", {}).get("hex", INVALID_HEX)
		result.append({
			"turn": entry.get("turn", 0),
			"revealed_indices": entry.get("revealed_indices", []),
			"nominations": serialize_nominations(entry.get("nominations", [])),
			"build": {
				"hex": _serialize_hex(hex),
				"card": entry.get("build", {}).get("card", {}),
			},
			"reality": entry.get("reality", {}),
			"scores_delta": entry.get("scores_delta", {}),
		})
	return result


## Deserialize turn history from network format
static func deserialize_turn_history(data: Array) -> Array:
	var result: Array = []
	for entry in data:
		if not (entry is Dictionary):
			continue
		var hex_arr: Array = entry.get("build", {}).get("hex", [])
		var hex := INVALID_HEX
		if hex_arr.size() == 3:
			hex = Vector3i(hex_arr[0], hex_arr[1], hex_arr[2])
		result.append({
			"turn": entry.get("turn", 0),
			"revealed_indices": entry.get("revealed_indices", []),
			"nominations": deserialize_nominations(entry.get("nominations", [])),
			"build": {
				"hex": hex,
				"card": entry.get("build", {}).get("card", {}),
			},
			"reality": entry.get("reality", {}),
			"scores_delta": entry.get("scores_delta", {}),
		})
	return result


# ─────────────────────────────────────────────────────────────────────────────
# VALIDATION HELPERS
# ─────────────────────────────────────────────────────────────────────────────

## Validate a card dictionary has required fields and valid suit
static func validate_card(card: Dictionary) -> bool:
	if not card.has("suit") or not card.has("rank"):
		return false
	var suit: int = card.get("suit", -1)
	return suit in [0, 1, 2] # HEARTS, DIAMONDS, SPADES


## Validate a serialized nomination entry from network
static func validate_serialized_nomination(nom: Dictionary) -> bool:
	if nom.is_empty():
		return true # Empty nomination is valid (no commit yet)
	if not nom.has("hex"):
		return false
	var hex_arr: Variant = nom.get("hex")
	if not (hex_arr is Array) or hex_arr.size() != 3:
		return false
	# claim is optional but if present should be valid
	var claim: Variant = nom.get("claim", {})
	if not (claim is Dictionary):
		return false
	if not claim.is_empty() and not validate_card(claim):
		return false
	return true


## Validate a serialized placement from network
static func validate_serialized_placement(p: Dictionary) -> bool:
	if p.is_empty():
		return true
	if not p.has("cube") or not p.has("card"):
		return false
	var cube_arr: Variant = p.get("cube")
	if not (cube_arr is Array) or cube_arr.size() != 3:
		return false
	var card: Variant = p.get("card")
	if not (card is Dictionary) or not validate_card(card):
		return false
	return true


## Validate role is in valid range
static func validate_role(role: int) -> bool:
	return role in [0, 1, 2] # MAYOR, INDUSTRY, URBANIST
