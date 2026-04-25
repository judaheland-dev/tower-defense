extends Node

## SimpleAI - controls P2 in PVE mode during the PREP phase.
## Makes heuristic-based decisions: buys a mix of mobs and places towers.

var player_world: Node = null  # P2's PlayerWorld

const THINK_INTERVAL: float = 2.0  # seconds between AI decisions
var _think_timer: float = 0.0

# Preloaded item data
var _tower_items: Array[TowerData] = []
var _mob_items: Array[MobData] = []

func _ready() -> void:
	_load_items()
	GameManager.state_changed.connect(_on_state_changed)

func _load_items() -> void:
	var tower_paths := [
		"res://resources/towers/wall_basic.tres",
		"res://resources/towers/tower_arrow.tres",
		"res://resources/towers/tower_cannon.tres",
		"res://resources/towers/tower_slow.tres",
		"res://resources/towers/tower_sniper.tres",
		"res://resources/towers/tower_tesla.tres",
		"res://resources/towers/tower_poison.tres",
		"res://resources/towers/tower_antiair.tres",
	]
	for path in tower_paths:
		if ResourceLoader.exists(path):
			_tower_items.append(load(path))

	var mob_paths := [
		"res://resources/mobs/mob_basic.tres",
		"res://resources/mobs/mob_armored.tres",
		"res://resources/mobs/mob_fast.tres",
		"res://resources/mobs/mob_healer.tres",
		"res://resources/mobs/mob_siege.tres",
		"res://resources/mobs/mob_breacher.tres",
	]
	for path in mob_paths:
		if ResourceLoader.exists(path):
			_mob_items.append(load(path))

func _process(delta: float) -> void:
	if GameManager.current_state != GameManager.GameState.PREP:
		return
	if player_world == null:
		return

	_think_timer -= delta
	if _think_timer > 0.0:
		return
	_think_timer = THINK_INTERVAL

	_take_action()

func _take_action() -> void:
	var coins := EconomyManager.coins[1]  # P2 index
	var round_num := GameManager.round_number

	# Spend ~40% of budget on mobs, 60% on towers (ratio shifts each round)
	var mob_budget: int = int(coins * 0.4)
	var tower_budget: int = coins - mob_budget

	# Buy mobs
	_buy_mobs(mob_budget, round_num)

	# Place towers
	_place_towers(tower_budget, round_num)

	# Try upgrading existing towers with leftover coins
	_upgrade_towers()

func _buy_mobs(budget: int, round_num: int) -> void:
	if _mob_items.is_empty():
		return
	# Army persists across rounds - only buy a few new mobs each PREP
	# Cap new purchases to avoid runaway army growth
	var max_new_mobs := 3 + round_num  # scales mildly with round
	var purchased := 0
	var remaining := budget
	# Higher rounds unlock better mobs
	var max_tier := mini(round_num, _mob_items.size() - 1)
	while remaining > 0 and purchased < max_new_mobs:
		var tier := randi() % (max_tier + 1)
		var mob_data: MobData = _mob_items[tier]
		if mob_data.cost <= remaining and EconomyManager.can_afford(1, mob_data.cost):
			EconomyManager.spend(1, mob_data.cost)
			player_world.call("_queue_mob", mob_data)
			remaining -= mob_data.cost
			purchased += 1
		else:
			break  # can't afford anything more

func _place_towers(budget: int, round_num: int) -> void:
	if _tower_items.is_empty() or player_world == null:
		return

	var grid_cols: int = player_world.get("GRID_COLS") if player_world.get("GRID_COLS") != null else 11
	var grid_rows: int = player_world.get("GRID_ROWS") if player_world.get("GRID_ROWS") != null else 14

	var attempts := 0
	var remaining := budget
	while remaining > 0 and attempts < 20:
		attempts += 1
		# Prefer walls early, towers later
		var item_index: int
		if round_num <= 2:
			item_index = 0  # wall
		else:
			item_index = randi() % mini(round_num, _tower_items.size())
		var tower_data: TowerData = _tower_items[item_index]

		if tower_data.cost > remaining or not EconomyManager.can_afford(1, tower_data.cost):
			continue

		# Pick a random non-border cell not on spawn/exit rows
		var col := randi_range(1, grid_cols - 2)
		var row := randi_range(1, grid_rows - 2)

		var grid: Array = player_world.get("_grid")
		if grid == null or grid[col][row]:
			continue  # occupied

		# Attempt placement via PlayerWorld
		player_world.call("set_selected_item", tower_data)
		player_world.set("_cursor_col", col)
		player_world.set("_cursor_row", row)
		player_world.call("_try_place")
		remaining -= tower_data.cost

func _upgrade_towers() -> void:
	if player_world == null:
		return
	var tower_nodes: Dictionary = player_world.get("_tower_nodes")
	if tower_nodes == null or tower_nodes.is_empty():
		return
	# Shuffle keys to avoid always upgrading the same tower first
	var keys: Array = tower_nodes.keys()
	keys.shuffle()
	for key in keys:
		var tower_node: Node = tower_nodes[key]
		if not is_instance_valid(tower_node):
			continue
		var tower_data: TowerData = tower_node.get("data")
		if tower_data == null or tower_data.upgrade_ids.is_empty():
			continue
		var upgrade_id: StringName = tower_data.upgrade_ids[0]
		var upgrade_path := "res://resources/towers/%s.tres" % upgrade_id
		if not ResourceLoader.exists(upgrade_path):
			continue
		var upgrade_data: TowerData = load(upgrade_path)
		if upgrade_data == null:
			continue
		if not EconomyManager.can_afford(1, upgrade_data.cost):
			continue
		EconomyManager.spend(1, upgrade_data.cost)
		tower_node.call("upgrade", upgrade_data)

func _on_state_changed(new_state: GameManager.GameState) -> void:
	if new_state == GameManager.GameState.PREP:
		_think_timer = 0.5  # short delay before first AI action each round
