## Pure game logic functions - stateless helpers for gameplay rules.
## Designed for testability and clarity.
class_name GameRules
extends RefCounted

const MapLayers := preload("res://scripts/map_layers.gd")

const INVALID_HEX := Vector3i(0x7FFFFFFF, 0, 0)


## Calculate cube distance between two hexes
static func cube_distance(a: Vector3i, b: Vector3i) -> int:
	var dx: int = abs(a.x - b.x)
	var dy: int = abs(a.y - b.y)
	var dz: int = abs(a.z - b.z)
	return (dx + dy + dz) / 2


## Check if a hex is adjacent to the town center (distance = 1)
static func is_adjacent_to_town(town_center: Vector3i, hex: Vector3i) -> bool:
	return cube_distance(town_center, hex) == 1


## Check if a hex is valid for nomination
static func is_valid_nomination(town_center: Vector3i, hex: Vector3i) -> bool:
	if hex == INVALID_HEX:
		return false
	return is_adjacent_to_town(town_center, hex)


## Check if all advisors have committed their nominations
static func all_advisors_committed(commits: Dictionary) -> bool:
	var industry_committed: bool = commits.get("industry", INVALID_HEX) != INVALID_HEX
	var urbanist_committed: bool = commits.get("urbanist", INVALID_HEX) != INVALID_HEX
	return industry_committed and urbanist_committed


## Get all 6 adjacent hexes around a center
static func get_adjacent_hexes(center: Vector3i) -> Array[Vector3i]:
	var directions: Array[Vector3i] = [
		Vector3i(1, -1, 0), Vector3i(1, 0, -1), Vector3i(0, 1, -1),
		Vector3i(-1, 1, 0), Vector3i(-1, 0, 1), Vector3i(0, -1, 1),
	]
	var result: Array[Vector3i] = []
	for d in directions:
		result.append(center + d)
	return result


## Pick best hex for bot based on visible layer
## Returns the hex with highest non-spade value, or fallback to any adjacent
static func pick_bot_nomination(
	visibility: Array,
	town_center: Vector3i,
	prefer_high_value: bool = true
) -> Vector3i:
	var best_hex: Vector3i = INVALID_HEX
	var best_value: int = -1

	for entry in visibility:
		if not entry is Dictionary:
			continue
		if not entry.has("cube") or not entry.has("card"):
			continue

		var cube_arr: Array = entry["cube"]
		if cube_arr.size() != 3:
			continue

		var cube := Vector3i(int(cube_arr[0]), int(cube_arr[1]), int(cube_arr[2]))

		# Must be adjacent to town
		if not is_adjacent_to_town(town_center, cube):
			continue

		var card: Dictionary = entry["card"]
		var suit: int = card.get("suit", -1)

		# Skip spades (bad outcome)
		if suit == MapLayers.Suit.SPADES:
			continue

		var val: int = card.get("value", 0)
		if prefer_high_value and val > best_value:
			best_value = val
			best_hex = cube
		elif not prefer_high_value and (best_hex == INVALID_HEX or val < best_value):
			best_value = val
			best_hex = cube

	# Fallback to first adjacent hex if nothing found
	if best_hex == INVALID_HEX:
		var adjacent := get_adjacent_hexes(town_center)
		if not adjacent.is_empty():
			best_hex = adjacent[0]

	return best_hex


## Calculate scores for a turn placement
## Returns dictionary with score deltas for mayor, industry, urbanist
static func calculate_turn_scores(
	placed_card: Dictionary,
	chosen_hex: Vector3i,
	nominations: Dictionary,
	get_reality: Callable  # func(layer_type: int, hex: Vector3i) -> Dictionary
) -> Dictionary:
	var scores := {"mayor": 0, "industry": 0, "urbanist": 0}

	# No scoring on spades (game ends)
	if placed_card.get("suit", -1) == MapLayers.Suit.SPADES:
		return scores

	# Determine which layer the card corresponds to
	var suit: int = placed_card.get("suit", -1)
	var layer_type: int
	match suit:
		MapLayers.Suit.DIAMONDS:
			layer_type = MapLayers.LayerType.RESOURCES
		MapLayers.Suit.HEARTS:
			layer_type = MapLayers.LayerType.DESIRABILITY
		_:
			return scores

	# Collect candidate hexes (nominated hexes)
	var candidate_hexes: Array[Vector3i] = []
	var industry_hex: Vector3i = nominations.get("industry", INVALID_HEX)
	var urbanist_hex: Vector3i = nominations.get("urbanist", INVALID_HEX)

	if industry_hex != INVALID_HEX:
		candidate_hexes.append(industry_hex)
	if urbanist_hex != INVALID_HEX and urbanist_hex != industry_hex:
		candidate_hexes.append(urbanist_hex)

	if candidate_hexes.is_empty():
		return scores

	# Find best value among candidates (reality)
	var best_value: float = -INF
	for hex in candidate_hexes:
		var reality: Dictionary = get_reality.call(layer_type, hex)
		var val: float = reality.get("value", 0)
		if val > best_value:
			best_value = val

	# Mayor scores if they picked optimally (chose hex with best real value)
	var chosen_reality: Dictionary = get_reality.call(layer_type, chosen_hex)
	if chosen_reality.get("value", 0) >= best_value:
		scores["mayor"] = 1

	# Advisors score if their hex was chosen
	if chosen_hex == industry_hex:
		scores["industry"] = 1
	if chosen_hex == urbanist_hex:
		scores["urbanist"] = 1

	return scores


## Check if a card is a spade (ends the game)
static func is_spade(card: Dictionary) -> bool:
	return card.get("suit", -1) == MapLayers.Suit.SPADES


## Check if a hex was nominated by either advisor
static func is_nominated_hex(hex: Vector3i, nominations: Dictionary) -> bool:
	var industry_hex: Vector3i = nominations.get("industry", INVALID_HEX)
	var urbanist_hex: Vector3i = nominations.get("urbanist", INVALID_HEX)
	return hex == industry_hex or hex == urbanist_hex


## Validate card index is within hand range
static func is_valid_card_index(index: int, hand_size: int) -> bool:
	return index >= 0 and index < hand_size

