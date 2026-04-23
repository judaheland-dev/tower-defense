extends Node

## EconomyManager - tracks coins per player and round income.

const STARTING_COINS: int = 150
const BASE_INCOME: int = 100
const INCOME_PER_ROUND: int = 10
const SPEED_BONUS_BASE: int = 50
const SPEED_BONUS_PER_ROUND: int = 5

# Indexed by player index (0 = P1, 1 = P2)
var coins: Array[int] = [STARTING_COINS, STARTING_COINS]

signal coins_changed(player_index: int, new_amount: int)

func reset() -> void:
	coins[0] = STARTING_COINS
	coins[1] = STARTING_COINS
	coins_changed.emit(0, coins[0])
	coins_changed.emit(1, coins[1])

# Returns true if player can afford cost.
func can_afford(player_index: int, cost: int) -> bool:
	return coins[player_index] >= cost

# Deducts cost from player. Returns false if insufficient funds.
func spend(player_index: int, cost: int) -> bool:
	if not can_afford(player_index, cost):
		return false
	coins[player_index] -= cost
	coins_changed.emit(player_index, coins[player_index])
	return true

func add_coins(player_index: int, amount: int) -> void:
	coins[player_index] += amount
	coins_changed.emit(player_index, coins[player_index])

# Calculate and award round-end income.
# time_remaining: seconds left when the last mob on that player's side died (0 if timer ran out)
# play_time_limit: total play phase duration in seconds
func award_round_income(player_index: int, time_remaining: float, play_time_limit: float) -> int:
	var round_num := GameManager.round_number
	var base := BASE_INCOME + round_num * INCOME_PER_ROUND
	var bonus_pool := SPEED_BONUS_BASE + round_num * SPEED_BONUS_PER_ROUND
	var speed_bonus := int(floor((time_remaining / play_time_limit) * bonus_pool))
	var total := base + speed_bonus
	add_coins(player_index, total)
	return total

# Returns the base income amount for the current round (for UI preview).
func get_base_income() -> int:
	return BASE_INCOME + GameManager.round_number * INCOME_PER_ROUND

func get_speed_bonus_pool() -> int:
	return SPEED_BONUS_BASE + GameManager.round_number * SPEED_BONUS_PER_ROUND
