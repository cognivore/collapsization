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
## Commits format: {role: {hex: Vector3i, claim: Dictionary}} or {role: Vector3i} (legacy)
static func all_advisors_committed(commits: Dictionary) -> bool:
	var ind_entry = commits.get("industry", {})
	var urb_entry = commits.get("urbanist", {})

	# Handle new format: {hex: Vector3i, claim: Dict}
	var ind_hex: Vector3i = INVALID_HEX
	var urb_hex: Vector3i = INVALID_HEX

	if ind_entry is Dictionary:
		ind_hex = ind_entry.get("hex", INVALID_HEX)
	elif ind_entry is Vector3i:
		ind_hex = ind_entry

	if urb_entry is Dictionary:
		urb_hex = urb_entry.get("hex", INVALID_HEX)
	elif urb_entry is Vector3i:
		urb_hex = urb_entry

	var industry_committed: bool = ind_hex != INVALID_HEX
	var urbanist_committed: bool = urb_hex != INVALID_HEX
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


## Pick best hex for bot based on visible layer (legacy simple behavior)
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


## Strategic bot nomination based on revealed card and role
## Returns {hex: Vector3i, claim: Dictionary, strategy: String} describing what the bot does
##
## Strategy Matrix:
## - SPADES revealed: Both nominate best of THEIR suit (Urb->Hearts, Ind->Diamonds)
## - HEARTS revealed: Urbanist honest (best heart), Industry LIES (claims urbanist's heart is spade)
## - DIAMONDS revealed: Industry honest (best diamond), Urbanist varies (50% warn spade, 25% accuse, 25% medium diamond)
##
## The "claim" is the card the advisor TELLS the Mayor about (may be a lie)
## If no candidates for preferred suit, lie by claiming a card close to revealed but in own suit
static func pick_strategic_nomination(
	my_role: int, # 1=Industry, 2=Urbanist
	revealed_suit: int, # Suit of Mayor's revealed card
	my_visibility: Array, # What this advisor can see
	town_center: Vector3i,
	built_hexes: Array = [], # Hexes that are already built (cannot nominate)
	revealed_value: int = 7 # Value of revealed card for fallback lies
) -> Dictionary:
	var result := {"hex": INVALID_HEX, "claim": {}, "strategy": "fallback"}
	var my_suit: int = MapLayers.Suit.DIAMONDS if my_role == 1 else MapLayers.Suit.HEARTS

	# Collect all visible hexes by suit (excluding already-built hexes)
	var hearts: Array[Dictionary] = []
	var diamonds: Array[Dictionary] = []
	var spades: Array[Dictionary] = []

	for entry in my_visibility:
		if not entry is Dictionary:
			continue
		if not entry.has("cube") or not entry.has("card"):
			continue

		var cube_arr: Array = entry["cube"]
		if cube_arr.size() != 3:
			continue

		var cube := Vector3i(int(cube_arr[0]), int(cube_arr[1]), int(cube_arr[2]))
		if not is_adjacent_to_town(town_center, cube):
			continue

		# Skip already-built hexes
		if cube in built_hexes:
			continue

		var card: Dictionary = entry["card"]
		var suit: int = card.get("suit", -1)
		var info := {"cube": cube, "card": card, "value": card.get("value", 0)}

		match suit:
			MapLayers.Suit.HEARTS:
				hearts.append(info)
			MapLayers.Suit.DIAMONDS:
				diamonds.append(info)
			MapLayers.Suit.SPADES:
				spades.append(info)

	# Sort by value (highest first)
	hearts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["value"] > b["value"])
	diamonds.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["value"] > b["value"])
	spades.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["value"] > b["value"])

	# Apply strategy based on revealed suit and role
	match revealed_suit:
		MapLayers.Suit.SPADES:
			# Both nominate best of THEIR suit - honest claims
			if my_role == 1: # Industry -> Diamonds
				if not diamonds.is_empty():
					var real_card: Dictionary = diamonds[0]["card"]
					result = {
						"hex": diamonds[0]["cube"],
						"claim": real_card.duplicate(), # Honest
						"strategy": "best_diamond_on_spade"
					}
			else: # Urbanist -> Hearts
				if not hearts.is_empty():
					var real_card: Dictionary = hearts[0]["card"]
					result = {
						"hex": hearts[0]["cube"],
						"claim": real_card.duplicate(), # Honest
						"strategy": "best_heart_on_spade"
					}

		MapLayers.Suit.HEARTS:
			if my_role == 2: # Urbanist - honest, best heart
				if not hearts.is_empty():
					var real_card: Dictionary = hearts[0]["card"]
					result = {
						"hex": hearts[0]["cube"],
						"claim": real_card.duplicate(), # Honest
						"strategy": "honest_heart"
					}
			else: # Industry - LIE: nominate a heart and claim it's spade
				if not hearts.is_empty():
					var real_card: Dictionary = hearts[0]["card"]
					# Create a lie - same value but SPADES suit (must include rank for label!)
					var lie_value: int = real_card.get("value", 5)
					var lie_card := {"suit": MapLayers.Suit.SPADES, "value": lie_value, "rank": _value_to_rank(lie_value)}
					result = {
						"hex": hearts[0]["cube"],
						"claim": lie_card,
						"strategy": "lie_claim_spade"
					}
				elif not diamonds.is_empty():
					var real_card: Dictionary = diamonds[0]["card"]
					result = {
						"hex": diamonds[0]["cube"],
						"claim": real_card.duplicate(),
						"strategy": "fallback_diamond"
					}

		MapLayers.Suit.DIAMONDS:
			if my_role == 1: # Industry - honest, best diamond
				if not diamonds.is_empty():
					var real_card: Dictionary = diamonds[0]["card"]
					result = {
						"hex": diamonds[0]["cube"],
						"claim": real_card.duplicate(), # Honest
						"strategy": "honest_diamond"
					}
			else: # Urbanist - varied strategy
				var roll := randf()
				if roll < 0.5 and not spades.is_empty():
					# 50%: Warn about real spade - honest
					var real_card: Dictionary = spades[0]["card"]
					result = {
						"hex": spades[0]["cube"],
						"claim": real_card.duplicate(),
						"strategy": "warn_spade"
					}
				elif roll < 0.75 and not diamonds.is_empty():
					# 25%: Accuse industry of lying - claim the diamond is actually a spade
					var real_card: Dictionary = diamonds[0]["card"]
					var lie_value: int = real_card.get("value", 5)
					var lie_card := {"suit": MapLayers.Suit.SPADES, "value": lie_value, "rank": _value_to_rank(lie_value)}
					result = {
						"hex": diamonds[0]["cube"],
						"claim": lie_card,
						"strategy": "accuse_industry"
					}
				elif not diamonds.is_empty():
					# 25%: Disclose medium diamond honestly
					var mid_idx := diamonds.size() / 2
					var real_card: Dictionary = diamonds[mid_idx]["card"]
					result = {
						"hex": diamonds[mid_idx]["cube"],
						"claim": real_card.duplicate(),
						"strategy": "medium_diamond"
					}
				elif not hearts.is_empty():
					var real_card: Dictionary = hearts[0]["card"]
					result = {
						"hex": hearts[0]["cube"],
						"claim": real_card.duplicate(),
						"strategy": "fallback_heart"
					}

	# Final fallback - if no strategy found a valid hex
	if result["hex"] == INVALID_HEX:
		# Collect ALL visible hexes (any suit) that aren't built
		var all_available: Array[Dictionary] = []
		all_available.append_array(hearts)
		all_available.append_array(diamonds)
		all_available.append_array(spades)

		if not all_available.is_empty():
			# Pick the first available hex and LIE - claim it's our suit with similar value to revealed
			var chosen: Dictionary = all_available[0]
			var lie_value: int = revealed_value if revealed_value > 0 else 7
			result = {
				"hex": chosen["cube"],
				"claim": {"suit": my_suit, "value": lie_value, "rank": _value_to_rank(lie_value)},
				"strategy": "desperate_lie"
			}
		else:
			# Absolute last resort - pick any adjacent hex not in built_hexes
			var adjacent := get_adjacent_hexes(town_center)
			for adj in adjacent:
				if adj not in built_hexes:
					var lie_value: int = revealed_value if revealed_value > 0 else 7
					result = {
						"hex": adj,
						"claim": {"suit": my_suit, "value": lie_value, "rank": _value_to_rank(lie_value)},
						"strategy": "blind_fallback"
					}
					break

	return result


## Helper to convert value back to rank string
static func _value_to_rank(value: int) -> String:
	match value:
		2: return "2"
		3: return "3"
		4: return "4"
		5: return "5"
		6: return "6"
		7: return "7"
		8: return "8"
		9: return "9"
		10: return "10"
		11: return "J"
		12: return "K"
		13: return "Q"
		14: return "A"
		_: return "7"


## Calculate scores for a turn placement using distance-to-reality
## Nominations: {role: {hex: Vector3i, claim: Dictionary}} (legacy Vector3i also supported)
## Distance = abs(value_diff) + (suit mismatch ? 1 : 0)
## Mayor scores only if chosen hex has the minimal distance (ties favor mayor)
## Advisors score only if their nominated hex was chosen
static func calculate_turn_scores(
	placed_card: Dictionary,
	chosen_hex: Vector3i,
	nominations: Dictionary,
	get_reality: Callable # func(hex: Vector3i) -> Dictionary
) -> Dictionary:
	var scores := {"mayor": 0, "industry": 0, "urbanist": 0}

	# No scoring on spades (game ends separately)
	if placed_card.get("suit", -1) == MapLayers.Suit.SPADES:
		return scores

	# Extract hexes from new/legacy nomination formats
	var ind_entry = nominations.get("industry", {})
	var urb_entry = nominations.get("urbanist", {})
	var industry_hex: Vector3i = INVALID_HEX
	var urbanist_hex: Vector3i = INVALID_HEX

	if ind_entry is Dictionary:
		industry_hex = ind_entry.get("hex", INVALID_HEX)
	elif ind_entry is Vector3i:
		industry_hex = ind_entry

	if urb_entry is Dictionary:
		urbanist_hex = urb_entry.get("hex", INVALID_HEX)
	elif urb_entry is Vector3i:
		urbanist_hex = urb_entry

	var candidate_hexes: Array[Vector3i] = []
	if industry_hex != INVALID_HEX:
		candidate_hexes.append(industry_hex)
	if urbanist_hex != INVALID_HEX and urbanist_hex != industry_hex:
		candidate_hexes.append(urbanist_hex)

	if candidate_hexes.is_empty():
		return scores

	# Compute distances to reality for each nominated hex
	var min_distance: int = INF
	var chosen_distance: int = INF

	for nom_hex in candidate_hexes:
		var reality: Dictionary = get_reality.call(nom_hex)
		if reality.is_empty():
			continue

		var dist := _card_distance(placed_card, reality)
		if dist < min_distance:
			min_distance = dist

		if nom_hex == chosen_hex:
			chosen_distance = dist

	# Mayor scores if they picked any hex with minimal distance (ties okay)
	if chosen_distance <= min_distance:
		scores["mayor"] = 1

	# Advisors score only if their nominated hex was chosen
	# When both nominate the same hex, winner is determined by placed card suit
	var ind_nominated: bool = (chosen_hex == industry_hex)
	var urb_nominated: bool = (chosen_hex == urbanist_hex)

	if ind_nominated and urb_nominated:
		# Both nominated same hex - winner depends on placed card suit
		var placed_suit: int = placed_card.get("suit", -1)
		match placed_suit:
			MapLayers.Suit.DIAMONDS:
				scores["industry"] = 1 # Industry's domain
			MapLayers.Suit.HEARTS:
				scores["urbanist"] = 1 # Urbanist's domain
			_:
				# Spades or unknown - default to industry (arbitrary)
				scores["industry"] = 1
	else:
		# Only one advisor nominated this hex
		if ind_nominated:
			scores["industry"] = 1
		if urb_nominated:
			scores["urbanist"] = 1

	return scores


static func _card_distance(a: Dictionary, b: Dictionary) -> int:
	var va: int = a.get("value", 0)
	var vb: int = b.get("value", 0)
	var dist: int = abs(va - vb)
	if a.get("suit", -1) != b.get("suit", -1):
		dist += 1
	return dist


## Check if a card is a spade (ends the game)
static func is_spade(card: Dictionary) -> bool:
	return card.get("suit", -1) == MapLayers.Suit.SPADES


## Check if a hex was nominated by either advisor
static func is_nominated_hex(hex: Vector3i, nominations: Dictionary) -> bool:
	var industry_entry: Dictionary = nominations.get("industry", {})
	var urbanist_entry: Dictionary = nominations.get("urbanist", {})
	var industry_hex: Vector3i = industry_entry.get("hex", INVALID_HEX) if not industry_entry.is_empty() else INVALID_HEX
	var urbanist_hex: Vector3i = urbanist_entry.get("hex", INVALID_HEX) if not urbanist_entry.is_empty() else INVALID_HEX
	return hex == industry_hex or hex == urbanist_hex


## Validate card index is within hand range
static func is_valid_card_index(index: int, hand_size: int) -> bool:
	return index >= 0 and index < hand_size


## Check if a hex can be nominated (not already built)
static func can_nominate_hex(hex: Vector3i, built_hexes: Array) -> bool:
	return hex not in built_hexes
