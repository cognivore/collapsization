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


## Serialize nominations: {role: {hex: Vector3i, claim: Dictionary}} -> network format
static func serialize_nominations(nominations: Dictionary) -> Dictionary:
	var result := {}
	for role_key in nominations.keys():
		var nom: Dictionary = nominations[role_key]
		if nom.is_empty():
			result[role_key] = {}
		else:
			var hex: Vector3i = nom.get("hex", INVALID_HEX)
			result[role_key] = {
				"hex": [hex.x, hex.y, hex.z],
				"claim": nom.get("claim", {})
			}
	return result


## Deserialize nominations: network format -> {role: {hex: Vector3i, claim: Dictionary}}
static func deserialize_nominations(data: Dictionary) -> Dictionary:
	var result := {}
	for role_key in data.keys():
		var nom_data: Dictionary = data[role_key]
		if nom_data.is_empty():
			result[role_key] = {}
		else:
			var arr: Array = nom_data.get("hex", [])
			var hex := INVALID_HEX
			if arr.size() == 3:
				hex = Vector3i(arr[0], arr[1], arr[2])
			result[role_key] = {
				"hex": hex,
				"claim": nom_data.get("claim", {})
			}
	return result


## Create an empty nomination entry
static func empty_nomination() -> Dictionary:
	return {"hex": INVALID_HEX, "claim": {}}


## Check if a nomination is valid (has a real hex)
static func is_valid_nomination_entry(nom: Dictionary) -> bool:
	return nom.get("hex", INVALID_HEX) != INVALID_HEX


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

