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


## Check if a hex is valid for nomination (on the playable frontier and not built)
## The playable frontier = all hexes adjacent to any built hex
static func is_valid_nomination(hex: Vector3i, built_hexes: Array) -> bool:
	if hex == INVALID_HEX:
		return false
	if hex in built_hexes:
		return false
	return is_on_playable_frontier(hex, built_hexes)


## Check if all advisors have committed their nominations (2 each)
## Commits format: {role: Array of {hex: Vector3i, claim: Dictionary}}
static func all_advisors_committed(commits: Dictionary) -> bool:
	var ind_commits: Array = commits.get("industry", [])
	var urb_commits: Array = commits.get("urbanist", [])
	return ind_commits.size() >= 2 and urb_commits.size() >= 2


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


## Get all hexes adjacent to any built hex (the "playable frontier")
## These are the hexes that can be nominated - they neighbor existing buildings
static func get_playable_frontier(built_hexes: Array) -> Array[Vector3i]:
	var frontier: Array[Vector3i] = []
	var seen: Dictionary = {}
	for built in built_hexes:
		for adj in get_adjacent_hexes(built):
			if adj not in built_hexes and not seen.has(adj):
				frontier.append(adj)
				seen[adj] = true
	return frontier


## Check if hex is adjacent to ANY built hex (on the playable frontier)
static func is_on_playable_frontier(hex: Vector3i, built_hexes: Array) -> bool:
	for built in built_hexes:
		if cube_distance(built, hex) == 1:
			return true
	return false


## Pick best hex for bot based on visible layer (legacy simple behavior)
## Returns the hex with highest non-spade value, or fallback to any on frontier
static func pick_bot_nomination(
	visibility: Array,
	built_hexes: Array,
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

		# Must be on playable frontier (adjacent to any built hex, not built)
		if not is_valid_nomination(cube, built_hexes):
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

	# Fallback to first hex on frontier if nothing found
	if best_hex == INVALID_HEX:
		var frontier := get_playable_frontier(built_hexes)
		if not frontier.is_empty():
			best_hex = frontier[0]

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
	built_hexes: Array, # Hexes that are already built (playable frontier is derived from this)
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

		# Must be on playable frontier (adjacent to any built hex) and not built
		if not is_valid_nomination(cube, built_hexes):
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
			# Absolute last resort - pick any hex on the playable frontier
			var frontier := get_playable_frontier(built_hexes)
			if not frontier.is_empty():
				var lie_value: int = revealed_value if revealed_value > 0 else 7
				result = {
					"hex": frontier[0],
					"claim": {"suit": my_suit, "value": lie_value, "rank": _value_to_rank(lie_value)},
					"strategy": "blind_fallback"
				}

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


## Calculate scores for a turn placement with bluff detection.
## Nominations: Array of {hex: Vector3i, claim: Dictionary, advisor: String}
##
## Scoring process:
## 1. Determine which advisor "owns" the chosen hex via tie-break (claim proximity)
## 2. Apply bluff detection to that advisor:
##    - Mayor TRUSTS (plays same suit as claim): +1
##    - Mayor CALLS (plays different suit): +1 if honest, 0 if bluff caught
## 3. SPADE REALITY: ALL nominators scored (+1 if warned, -2 if lied)
## 4. Mayor scores 1 only if their choice achieves the minimum possible distance
##    across ALL hand cards × ALL nominated hexes (truly optimal build)
static func calculate_turn_scores(
	placed_card: Dictionary,
	chosen_hex: Vector3i,
	nominations: Array, # Array of {hex, claim, advisor}
	get_reality: Callable, # func(hex: Vector3i) -> Dictionary
	mayor_hand: Array = [] # All 4 cards Mayor had this turn (for optimal build check)
) -> Dictionary:
	var scores := {"mayor": 0, "industry": 0, "urbanist": 0}

	if nominations.is_empty():
		return scores

	# Collect unique hexes from all nominations
	var candidate_hexes: Array[Vector3i] = []
	for nom in nominations:
		var hex: Vector3i = nom.get("hex", INVALID_HEX)
		if hex != INVALID_HEX and hex not in candidate_hexes:
			candidate_hexes.append(hex)

	if candidate_hexes.is_empty():
		return scores

	var placed_suit: int = placed_card.get("suit", -1)
	var placed_value: int = placed_card.get("value", 0)

	# Get reality at chosen hex
	var reality: Dictionary = get_reality.call(chosen_hex)
	var reality_suit: int = reality.get("suit", -1)
	var reality_is_spade: bool = is_spade(reality)

	# Find nominations for the chosen hex
	var noms_for_hex: Array[Dictionary] = []
	for nom in nominations:
		if nom.get("hex", INVALID_HEX) == chosen_hex:
			noms_for_hex.append(nom)

	if noms_for_hex.is_empty():
		return scores

	# SPADE REALITY: Score ALL advisors who nominated this hex
	if reality_is_spade:
		var scored_advisors: Dictionary = {}
		for nom in noms_for_hex:
			var advisor: String = nom.get("advisor", "")
			if advisor.is_empty() or scored_advisors.has(advisor):
				continue
			var claim: Dictionary = nom.get("claim", {})
			var claim_suit: int = claim.get("suit", -1)
			if claim_suit == MapLayers.Suit.SPADES:
				pass # Honest warning = 0 points (no reward for finding mines)
			else:
				scores[advisor] -= 2 # Lied about mine, severe penalty
			scored_advisors[advisor] = true
		return scores

	# NON-SPADE REALITY: Determine winning advisor via tie-break
	var winning_nom: Dictionary = noms_for_hex[0]
	var used_domain_affinity_for_spades: bool = false
	if noms_for_hex.size() > 1:
		# Tie-break: closest claim value, then suit match, then domain affinity
		var best_diff: int = 999999
		var best_suit_match: bool = false
		var best_domain_match: bool = false
		for nom in noms_for_hex:
			var claim: Dictionary = nom.get("claim", {})
			var claim_value: int = claim.get("value", 0)
			var claim_suit: int = claim.get("suit", -1)
			var advisor: String = nom.get("advisor", "")
			var diff: int = abs(claim_value - placed_value)
			var suit_match: bool = (claim_suit == placed_suit)
			# Domain affinity: Hearts→Urbanist, Diamonds/Spades→Industry
			var domain_match: bool = (
				(claim_suit == MapLayers.Suit.HEARTS and advisor == "urbanist") or
				(claim_suit in [MapLayers.Suit.DIAMONDS, MapLayers.Suit.SPADES] and advisor == "industry")
			)

			var dominated: bool = false
			if diff < best_diff:
				dominated = true
			elif diff == best_diff:
				if suit_match and not best_suit_match:
					dominated = true
				elif suit_match == best_suit_match:
					if domain_match and not best_domain_match:
						dominated = true

			if dominated:
				best_diff = diff
				best_suit_match = suit_match
				best_domain_match = domain_match
				winning_nom = nom

		# Check if domain affinity was used for Spades (both claimed same Spade card)
		# This happens when both have same diff and same suit match status
		var first_claim: Dictionary = noms_for_hex[0].get("claim", {})
		var second_claim: Dictionary = noms_for_hex[1].get("claim", {}) if noms_for_hex.size() > 1 else {}
		if first_claim.get("suit", -1) == MapLayers.Suit.SPADES and \
		   first_claim.get("suit", -1) == second_claim.get("suit", -1) and \
		   first_claim.get("value", -1) == second_claim.get("value", -1):
			used_domain_affinity_for_spades = true

	# Apply bluff detection scoring to the winning advisor
	var advisor: String = winning_nom.get("advisor", "")
	if not advisor.is_empty():
		var claim: Dictionary = winning_nom.get("claim", {})
		var claim_suit: int = claim.get("suit", -1)

		# Spades domain affinity special case: if both advisors claimed
		# identical Spades but reality is NOT Spades, both were lying
		# about a mine - nobody scores (skip advisor scoring entirely)
		if used_domain_affinity_for_spades and reality_suit != MapLayers.Suit.SPADES:
			pass # No winner - both lied about mine
		elif placed_suit == claim_suit:
			# Mayor TRUSTED (played same suit as claimed)
			scores[advisor] += 1
		else:
			# Mayor CALLED (played different suit than claimed)
			if claim_suit == reality_suit:
				# Advisor was honest but Mayor didn't believe them
				scores[advisor] += 1
			# else: Advisor bluffed AND Mayor caught it - 0 points

	# MAYOR SCORING - optimal distance calculation
	# Mayor scores only if they found the optimal build among ALL hand cards
	if not reality_is_spade:
		# Calculate the distance the Mayor actually achieved
		var chosen_distance: int = _card_distance(placed_card, reality)

		# Find the global minimum distance across ALL hand cards × ALL nominated hexes
		# If mayor_hand is empty (legacy call), fall back to checking only placed_card
		var cards_to_check: Array = mayor_hand if not mayor_hand.is_empty() else [placed_card]
		var global_best_distance: int = 999999

		for hand_card in cards_to_check:
			var hand_suit: int = hand_card.get("suit", -1)
			var hand_value: int = hand_card.get("value", 0)
			for nom_hex in candidate_hexes:
				var hex_reality: Dictionary = get_reality.call(nom_hex)
				if hex_reality.is_empty():
					continue
				# Skip spade realities (game-ending)
				if hex_reality.get("suit", -1) == MapLayers.Suit.SPADES:
					continue
				if hex_reality.get("suit", -1) == hand_suit:
					var dist: int = abs(hand_value - hex_reality.get("value", 0))
					if dist < global_best_distance:
						global_best_distance = dist

		# Mayor scores only if their choice equals the best possible
		if chosen_distance >= 0 and chosen_distance <= global_best_distance:
			scores["mayor"] = 1

	return scores


## Calculate similarity distance between two cards.
## Returns |value_diff| if suits match (lower is better, 0 = exact match).
## Returns -1 if suits do not match (Mayor cannot score).
static func _card_distance(a: Dictionary, b: Dictionary) -> int:
	if a.get("suit", -1) != b.get("suit", -1):
		return -1 # Suit mismatch: Mayor cannot score
	var va: int = a.get("value", 0)
	var vb: int = b.get("value", 0)
	return abs(va - vb)


## Check if a card is a spade (ends the game)
static func is_spade(card: Dictionary) -> bool:
	return card.get("suit", -1) == MapLayers.Suit.SPADES


## Check if a hex was nominated by any advisor
## Nominations: Array of {hex: Vector3i, claim: Dictionary, advisor: String}
static func is_nominated_hex(hex: Vector3i, nominations: Array) -> bool:
	for nom in nominations:
		if nom.get("hex", INVALID_HEX) == hex:
			return true
	return false


## Validate card index is within hand range
static func is_valid_card_index(index: int, hand_size: int) -> bool:
	return index >= 0 and index < hand_size


## Check if a hex can be nominated (not already built)
static func can_nominate_hex(hex: Vector3i, built_hexes: Array) -> bool:
	return hex not in built_hexes
