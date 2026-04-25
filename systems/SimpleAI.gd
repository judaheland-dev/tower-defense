extends Node

## SimpleAI - strategic PVE opponent (controls P2).
## Builds deliberate maze corridors, picks army compositions that counter the
## opponent's defenses, adapts spending based on game state, and learns from
## round-over-round results. Fair play only - never reads opponent's mob queue
## or economy.

# ---- wired by Game.gd ----
var player_world: Node = null   # P2's PlayerWorld (AI's own board)
var opponent_world: Node = null  # P1's PlayerWorld (human's board - read only)

# ---- constants ----
const GRID_COLS: int = 11
const GRID_ROWS: int = 14
const THINK_INTERVAL: float = 1.2  # seconds between AI decisions during PREP
const PLAYER_INDEX: int = 1        # AI is always P2

# ---- loaded resources ----
var _towers: Dictionary = {}  # id -> TowerData
var _mobs: Dictionary = {}    # id -> MobData
var _traps: Dictionary = {}   # id -> TrapData
var _wall: TowerData = null

# ---- maze state ----
var _maze_plan: Array = []          # ordered [col, row] wall placements
var _maze_index: int = 0            # how far through the plan we've built
var _tower_spots: Array = []        # [col, row, TowerData] planned tower placements

# ---- round memory ----
var _last_opponent_towers: Dictionary = {}  # display_name -> count from previous round
var _opponent_sent_flying: bool = false
var _opponent_sent_armored: bool = false
var _opponent_sent_swarm: bool = false
var _my_leak_rate: float = 0.0        # fraction of mobs that reached exit last round
var _my_damage_dealt: float = 0.0     # HP damage AI dealt to opponent last round
var _opponent_hp_prev: int = 20
var _my_hp_prev: int = 20

# ---- budget ----
var _think_timer: float = 0.0
var _acted_this_prep: bool = false    # has the AI taken its main action this PREP?

func _ready() -> void:
	_load_all_resources()
	GameManager.state_changed.connect(_on_state_changed)

# ---------- resource loading ----------

func _load_all_resources() -> void:
	var tower_paths := [
		"res://resources/towers/wall_basic.tres",
		"res://resources/towers/tower_arrow.tres",
		"res://resources/towers/tower_cannon.tres",
		"res://resources/towers/tower_slow.tres",
		"res://resources/towers/tower_sniper.tres",
		"res://resources/towers/tower_tesla.tres",
		"res://resources/towers/tower_mortar.tres",
		"res://resources/towers/tower_poison.tres",
		"res://resources/towers/tower_buff.tres",
		"res://resources/towers/tower_antiair.tres",
	]
	for path in tower_paths:
		if ResourceLoader.exists(path):
			var data: TowerData = load(path)
			_towers[data.id] = data
			if data.tower_type == TowerData.TowerType.WALL:
				_wall = data

	var mob_paths := [
		"res://resources/mobs/mob_basic.tres",
		"res://resources/mobs/mob_armored.tres",
		"res://resources/mobs/mob_fast.tres",
		"res://resources/mobs/mob_healer.tres",
		"res://resources/mobs/mob_flying.tres",
		"res://resources/mobs/mob_swarm.tres",
		"res://resources/mobs/mob_saboteur.tres",
		"res://resources/mobs/mob_siege.tres",
		"res://resources/mobs/mob_breacher.tres",
	]
	for path in mob_paths:
		if ResourceLoader.exists(path):
			var data: MobData = load(path)
			_mobs[data.id] = data

	var trap_paths := [
		"res://resources/traps/trap_mud.tres",
		"res://resources/traps/trap_spike_pit.tres",
		"res://resources/traps/trap_tar_pit.tres",
		"res://resources/traps/trap_lava.tres",
		"res://resources/traps/trap_poison_bog.tres",
		"res://resources/traps/trap_amplifier.tres",
		"res://resources/traps/trap_gold_mine.tres",
	]
	for path in trap_paths:
		if ResourceLoader.exists(path):
			var data: TrapData = load(path)
			_traps[data.id] = data

# ---------- maze templates ----------
# AI is P2 (board_side=1): spawn at col 0, exit at col 10.
# Mobs travel LEFT to RIGHT. We build a zigzag forcing them up and down.
# Protected zones: col<=1 rows 6-7 (near spawn), col>=9 rows 6-7 (near exit).

func _generate_maze_plan() -> void:
	_maze_plan.clear()
	_tower_spots.clear()

	# Zigzag maze: vertical wall barriers at cols 3, 5, 8 with alternating gaps.
	# Mobs enter at col 0 center, must zigzag to reach col 10.
	# Grid: 11 cols (0-10) x 14 rows (0-13). Center rows = 6,7.
	# Using 3 wall columns keeps wall count manageable (~30 walls = 600 coins)
	# while still forcing a good zigzag path.
	var wall_cols := [3, 5, 8]
	var gap_top := true

	for wc in wall_cols:
		# Leave a gap of 3 rows at top or bottom for mobs to pass through
		var gap_start: int
		var gap_end: int
		if gap_top:
			gap_start = 0
			gap_end = 2
		else:
			gap_start = GRID_ROWS - 3
			gap_end = GRID_ROWS - 1

		for r in range(GRID_ROWS):
			if r >= gap_start and r <= gap_end:
				continue  # this is the gap
			if _is_protected(wc, r):
				continue
			_maze_plan.append([wc, r])

		gap_top = not gap_top

	# Plan tower positions: cols between and beside wall columns
	# These overlook the corridors where mobs are forced to travel
	var tower_cols := [2, 4, 6, 7, 9]
	for tc in tower_cols:
		for r in [2, 5, 8, 11]:
			if r < 0 or r >= GRID_ROWS:
				continue
			if _is_protected(tc, r):
				continue
			_tower_spots.append([tc, r])

	# Place towers adjacent to gap openings (high-traffic chokepoints)
	gap_top = true
	for wc in wall_cols:
		var gap_row: int = 1 if gap_top else GRID_ROWS - 2
		var adj_col: int = wc - 1 if wc > 1 else wc + 1
		if adj_col >= 0 and adj_col < GRID_COLS and not _is_protected(adj_col, gap_row):
			_tower_spots.append([adj_col, gap_row])
		adj_col = wc + 1
		if adj_col >= 0 and adj_col < GRID_COLS and not _is_protected(adj_col, gap_row):
			_tower_spots.append([adj_col, gap_row])
		gap_top = not gap_top

func _is_protected(col: int, row: int) -> bool:
	# P2 (board_side=1): spawn at col<=1 rows 6-7, exit at col>=9 rows 6-7
	var near_spawn: bool = col <= 1 and row >= GRID_ROWS / 2 - 1 and row <= GRID_ROWS / 2
	var near_exit: bool = col >= GRID_COLS - 2 and row >= GRID_ROWS / 2 - 1 and row <= GRID_ROWS / 2
	return near_spawn or near_exit

# ---------- main loop ----------

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
	var coins := EconomyManager.coins[PLAYER_INDEX]
	var round_num := GameManager.round_number

	# First action of each PREP: one-time strategic planning
	if not _acted_this_prep:
		_acted_this_prep = true
		_observe_opponent()
		if _maze_plan.is_empty():
			_generate_maze_plan()

	# Dynamic budget split based on game state
	var mob_ratio := _compute_mob_ratio(round_num)
	var mob_budget: int = int(coins * mob_ratio)
	var tower_budget: int = coins - mob_budget

	# Phase 1: Build maze walls
	var wall_spent := _build_maze_walls(tower_budget)
	tower_budget -= wall_spent

	# Phase 3: Place offensive towers
	var tower_spent := _place_strategic_towers(tower_budget, round_num)
	tower_budget -= tower_spent

	# Place traps in corridors
	_place_traps(tower_budget, round_num)

	# Phase 2: Buy army
	_buy_army(mob_budget, round_num)

	# Upgrade existing towers with leftovers
	_upgrade_towers()

# ---------- Phase 4: Budget strategy ----------

func _compute_mob_ratio(round_num: int) -> float:
	var ratio := 0.35  # base: slightly favor defense

	# Scale toward offense in later rounds (maze is mostly built)
	ratio += round_num * 0.03

	# If our HP is low, invest more in defense
	var my_hp: int = player_world.get("current_hp") if player_world.get("current_hp") != null else 20
	if my_hp <= 10:
		ratio -= 0.15
	elif my_hp <= 5:
		ratio -= 0.25

	# If opponent HP is low, go aggressive to finish them
	if opponent_world != null:
		var opp_hp: int = opponent_world.get("current_hp") if opponent_world.get("current_hp") != null else 20
		if opp_hp <= 8:
			ratio += 0.15
		elif opp_hp <= 4:
			ratio += 0.25

	# If we leaked a lot last round, invest in defense
	if _my_leak_rate > 0.5:
		ratio -= 0.1

	# If our attack dealt little damage, invest more in offense
	if round_num > 1 and _my_damage_dealt < 1.0:
		ratio += 0.1

	return clampf(ratio, 0.15, 0.70)

# ---------- Phase 5: Observe opponent (fair play) ----------

func _observe_opponent() -> void:
	if opponent_world == null:
		return

	# Read opponent's tower composition (publicly visible on the board)
	_last_opponent_towers.clear()
	var tower_counts: Dictionary = opponent_world.call("get_tower_counts")
	for tower_name in tower_counts:
		_last_opponent_towers[tower_name] = tower_counts[tower_name]["count"]

	# Track HP changes to measure our attack effectiveness
	var opp_hp: int = opponent_world.get("current_hp") if opponent_world.get("current_hp") != null else 20
	_my_damage_dealt = maxf(0.0, _opponent_hp_prev - opp_hp)
	_opponent_hp_prev = opp_hp

	var my_hp: int = player_world.get("current_hp") if player_world.get("current_hp") != null else 20
	_my_hp_prev = my_hp

	# Detect what mob types are on OUR field (= what opponent sent us last round)
	# We can see active mobs on our own board
	_opponent_sent_flying = false
	_opponent_sent_armored = false
	_opponent_sent_swarm = false
	var mob_nodes: Array = player_world.get("_mob_nodes") if player_world.get("_mob_nodes") != null else []
	for mob_node in mob_nodes:
		if not is_instance_valid(mob_node):
			continue
		var data: MobData = mob_node.get("data") if mob_node.get("data") != null else null
		if data == null:
			continue
		if data.is_flying:
			_opponent_sent_flying = true
		if data.armor > 5:
			_opponent_sent_armored = true
		if data.spawn_count > 1:
			_opponent_sent_swarm = true

# ---------- Phase 1: Maze building ----------

func _build_maze_walls(budget: int) -> int:
	if _wall == null or _maze_index >= _maze_plan.size():
		return 0

	var spent := 0
	var grid: Array = player_world.get("_grid")
	if grid == null:
		return 0

	# Reserve at least enough for one tower so we don't spend everything on walls
	var min_tower_cost := 60  # arrow tower cost
	var wall_budget: int = maxi(0, budget - min_tower_cost)

	# Place walls from the plan, capped by budget and per-tick limit
	var walls_this_tick := 0
	var max_walls := 4  # limit per think tick to spread across PREP phase
	while _maze_index < _maze_plan.size() and spent + _wall.cost <= wall_budget and walls_this_tick < max_walls:
		var cell: Array = _maze_plan[_maze_index]
		var col: int = cell[0]
		var row: int = cell[1]
		_maze_index += 1

		# Skip if occupied
		if grid[col][row]:
			continue

		if not EconomyManager.can_afford(PLAYER_INDEX, _wall.cost):
			break

		_place_item_at(_wall, col, row)
		spent += _wall.cost
		walls_this_tick += 1

	return spent

# ---------- Phase 3: Strategic tower placement ----------

func _choose_tower(round_num: int) -> TowerData:
	# Build a weighted pool based on round and game state
	var pool: Array = []  # [TowerData, weight] pairs

	# Arrow: always useful, cheap
	if _towers.has(&"tower_arrow"):
		pool.append([_towers[&"tower_arrow"], 10])

	# Cannon: good vs groups, available from round 2+
	if _towers.has(&"tower_cannon") and round_num >= 2:
		var w := 8
		if _opponent_sent_swarm:
			w += 6  # counter swarms
		pool.append([_towers[&"tower_cannon"], w])

	# Frost: slows mobs in kill zone
	if _towers.has(&"tower_slow") and round_num >= 2:
		# Check if we already have enough slows
		var existing := _count_my_towers("Frost Tower")
		var w := 6 if existing < 3 else 1
		pool.append([_towers[&"tower_slow"], w])

	# Tesla: chain damage, great vs groups
	if _towers.has(&"tower_tesla") and round_num >= 3:
		var w := 7
		if _opponent_sent_swarm:
			w += 5
		pool.append([_towers[&"tower_tesla"], w])

	# Mortar: long range AoE
	if _towers.has(&"tower_mortar") and round_num >= 3:
		var w := 6
		if _opponent_sent_swarm:
			w += 4
		pool.append([_towers[&"tower_mortar"], w])

	# Sniper: high single-target, good vs tanks
	if _towers.has(&"tower_sniper") and round_num >= 3:
		var w := 5
		if _opponent_sent_armored:
			w += 4
		pool.append([_towers[&"tower_sniper"], w])

	# Poison: DoT + heal reduction, counters healers
	if _towers.has(&"tower_poison") and round_num >= 2:
		pool.append([_towers[&"tower_poison"], 5])

	# Anti-air: essential if opponent sends flying
	if _towers.has(&"tower_antiair"):
		var w := 3
		if _opponent_sent_flying:
			w += 12  # strongly prioritize
		# Also build some anti-air proactively in later rounds
		elif round_num >= 4:
			w += 3
		pool.append([_towers[&"tower_antiair"], w])

	# War Banner: buff aura, place near tower clusters in late game
	if _towers.has(&"tower_buff") and round_num >= 4:
		var existing := _count_my_towers("War Banner")
		if existing < 2:
			pool.append([_towers[&"tower_buff"], 4])

	if pool.is_empty():
		return _towers.values()[0] if not _towers.is_empty() else null

	# Weighted random selection
	var total_weight := 0.0
	for entry in pool:
		total_weight += entry[1]
	var roll := randf() * total_weight
	var cumulative := 0.0
	for entry in pool:
		cumulative += entry[1]
		if roll <= cumulative:
			return entry[0]
	return pool[pool.size() - 1][0]

func _count_my_towers(display_name: String) -> int:
	var tower_counts: Dictionary = player_world.call("get_tower_counts")
	if tower_counts.has(display_name):
		return tower_counts[display_name]["count"]
	return 0

func _place_strategic_towers(budget: int, round_num: int) -> int:
	if player_world == null:
		return 0

	var spent := 0
	var grid: Array = player_world.get("_grid")
	if grid == null:
		return 0

	var towers_placed := 0
	var max_towers := 3  # per think tick

	# First try planned tower spots
	var spot_idx := 0
	while spot_idx < _tower_spots.size() and towers_placed < max_towers:
		var spot: Array = _tower_spots[spot_idx]
		var col: int = spot[0]
		var row: int = spot[1]

		if grid[col][row]:
			# Spot taken (probably by a wall - that's fine), skip
			spot_idx += 1
			continue

		var tower_data := _choose_tower(round_num)
		if tower_data == null:
			break
		if tower_data.cost > budget - spent or not EconomyManager.can_afford(PLAYER_INDEX, tower_data.cost):
			spot_idx += 1
			continue

		_place_item_at(tower_data, col, row)
		spent += tower_data.cost
		towers_placed += 1
		_tower_spots.remove_at(spot_idx)  # consumed this spot
		# don't increment spot_idx since we removed

	# If no planned spots left, find good positions near existing corridors
	if towers_placed < max_towers and _tower_spots.is_empty():
		var candidates := _find_corridor_adjacent_cells(grid)
		candidates.shuffle()
		for candidate in candidates:
			if towers_placed >= max_towers:
				break
			var col: int = candidate[0]
			var row: int = candidate[1]

			var tower_data := _choose_tower(round_num)
			if tower_data == null:
				break
			if tower_data.cost > budget - spent or not EconomyManager.can_afford(PLAYER_INDEX, tower_data.cost):
				continue
			_place_item_at(tower_data, col, row)
			spent += tower_data.cost
			towers_placed += 1

	return spent

func _find_corridor_adjacent_cells(grid: Array) -> Array:
	# Find empty cells adjacent to walls (good tower positions overlooking corridors)
	var results: Array = []
	for c in range(GRID_COLS):
		for r in range(GRID_ROWS):
			if grid[c][r]:
				continue  # occupied
			if _is_protected(c, r):
				continue
			# Check if adjacent to at least one wall
			var adj_wall := false
			for offset in [[-1, 0], [1, 0], [0, -1], [0, 1]]:
				var nc: int = c + offset[0]
				var nr: int = r + offset[1]
				if nc >= 0 and nc < GRID_COLS and nr >= 0 and nr < GRID_ROWS:
					if grid[nc][nr]:
						adj_wall = true
						break
			if adj_wall:
				results.append([c, r])
	return results

# ---------- Trap placement ----------

func _place_traps(budget: int, round_num: int) -> int:
	if player_world == null or round_num < 3:
		return 0

	var spent := 0
	var grid: Array = player_world.get("_grid")
	if grid == null:
		return 0
	var trap_nodes: Dictionary = player_world.get("_trap_nodes") if player_world.get("_trap_nodes") != null else {}

	# Find corridor cells (empty cells between walls) for trap placement
	var corridor_cells: Array = []
	for c in range(GRID_COLS):
		for r in range(GRID_ROWS):
			if grid[c][r]:
				continue  # wall/tower here
			if _is_protected(c, r):
				continue
			var key := "%d,%d" % [c, r]
			if trap_nodes.has(key):
				continue  # trap already here
			# Prefer cells adjacent to walls (actual corridor tiles)
			var adj_count := 0
			for offset in [[-1, 0], [1, 0], [0, -1], [0, 1]]:
				var nc: int = c + offset[0]
				var nr: int = r + offset[1]
				if nc >= 0 and nc < GRID_COLS and nr >= 0 and nr < GRID_ROWS and grid[nc][nr]:
					adj_count += 1
			if adj_count >= 1:
				corridor_cells.append([c, r])

	corridor_cells.shuffle()

	var traps_placed := 0
	var max_traps := 2  # per think tick
	for cell in corridor_cells:
		if traps_placed >= max_traps:
			break
		var trap_data := _choose_trap(round_num)
		if trap_data == null:
			break
		if trap_data.cost > budget - spent or not EconomyManager.can_afford(PLAYER_INDEX, trap_data.cost):
			continue
		var col: int = cell[0]
		var row: int = cell[1]
		_place_item_at(trap_data, col, row)
		spent += trap_data.cost
		traps_placed += 1

	return spent

func _choose_trap(round_num: int) -> TrapData:
	var pool: Array = []

	# Mud: cheap slow
	if _traps.has(&"trap_mud"):
		pool.append([_traps[&"trap_mud"], 6])

	# Tar pit: heavy slow
	if _traps.has(&"trap_tar_pit"):
		pool.append([_traps[&"trap_tar_pit"], 5])

	# Spike pit: burst damage
	if _traps.has(&"trap_spike_pit"):
		pool.append([_traps[&"trap_spike_pit"], 4])

	# Amplifier: makes tower cluster deadlier
	if _traps.has(&"trap_amplifier") and round_num >= 4:
		pool.append([_traps[&"trap_amplifier"], 5])

	# Lava: high DPS
	if _traps.has(&"trap_lava") and round_num >= 4:
		pool.append([_traps[&"trap_lava"], 4])

	# Gold mine: economy investment early-mid game
	if _traps.has(&"trap_gold_mine") and round_num <= 5:
		pool.append([_traps[&"trap_gold_mine"], 3])

	if pool.is_empty():
		return null

	return _weighted_pick(pool)

# ---------- Phase 2: Reactive army composition ----------

func _buy_army(budget: int, round_num: int) -> void:
	if _mobs.is_empty():
		return

	# Cap new purchases per round
	var max_new := 3 + round_num
	var purchased := 0
	var remaining := budget

	# Choose a squad composition based on opponent's defenses
	var squads := _build_squad_options(round_num)
	if squads.is_empty():
		return

	# Buy squads until budget or cap runs out
	while remaining > 0 and purchased < max_new:
		# Pick best affordable squad
		var best_squad: Array = []
		var best_score := -1.0
		for squad in squads:
			var cost := _squad_cost(squad)
			var count := _squad_mob_count(squad)
			if cost <= remaining and purchased + count <= max_new:
				var score: float = squad[squad.size() - 1] if squad[squad.size() - 1] is float else 0.0
				if score > best_score:
					best_score = score
					best_squad = squad

		if best_squad.is_empty():
			# Try individual cheap mobs
			var cheapest := _find_cheapest_mob()
			if cheapest != null and cheapest.cost <= remaining and EconomyManager.can_afford(PLAYER_INDEX, cheapest.cost):
				EconomyManager.spend(PLAYER_INDEX, cheapest.cost)
				player_world.call("queue_mob", cheapest)
				remaining -= cheapest.cost
				purchased += 1
			else:
				break
			continue

		# Buy the squad (last element is the score float, skip it)
		var bought_any := false
		for i in range(best_squad.size() - 1):
			var mob_data: MobData = best_squad[i]
			if mob_data == null:
				continue
			if not EconomyManager.can_afford(PLAYER_INDEX, mob_data.cost):
				break
			EconomyManager.spend(PLAYER_INDEX, mob_data.cost)
			player_world.call("queue_mob", mob_data)
			remaining -= mob_data.cost
			purchased += 1
			bought_any = true

		if not bought_any:
			break

func _build_squad_options(round_num: int) -> Array:
	# Score each squad type based on opponent's tower composition
	var squads: Array = []  # each entry: [MobData, MobData, ..., score_float]

	var has_antiair: bool = _last_opponent_towers.get("Sky Piercer", 0) > 0
	var has_aoe: int = _last_opponent_towers.get("Cannon Tower", 0) + _last_opponent_towers.get("Mortar", 0) + _last_opponent_towers.get("Tesla Coil", 0)
	var has_slow: bool = _last_opponent_towers.get("Frost Tower", 0) > 0
	var total_towers: int = 0
	for count in _last_opponent_towers.values():
		total_towers += count
	var tower_density_low: bool = total_towers < 4 + round_num

	# -- Cheap early-game options (cost 20-60) --

	# Scout pair: fast harassment (60 coins)
	if _mobs.has(&"mob_fast"):
		var score := 5.0
		if tower_density_low:
			score += 3.0
		if has_slow:
			score -= 2.0
		squads.append([_mobs[&"mob_fast"], _mobs[&"mob_fast"], score])

	# Single ratling swarm (40 coins for 4 units - great value)
	if _mobs.has(&"mob_swarm"):
		var score := 6.0
		if has_aoe > 1:
			score -= 3.0
		else:
			score += 2.0
		squads.append([_mobs[&"mob_swarm"], score])

	# Basic + scout mix (50 coins)
	if _mobs.has(&"mob_basic") and _mobs.has(&"mob_fast"):
		squads.append([_mobs[&"mob_basic"], _mobs[&"mob_fast"], 4.0])

	# Single gargoyle probe (55 coins - test for anti-air)
	if _mobs.has(&"mob_flying") and not has_antiair:
		squads.append([_mobs[&"mob_flying"], 7.0])

	# -- Medium squads (cost 80-130) --

	# Rush squad: fast scouts overwhelm weak defenses
	if _mobs.has(&"mob_fast"):
		var score := 5.0
		if tower_density_low:
			score += 5.0
		if has_slow:
			score -= 3.0
		var squad: Array = []
		for _i in range(3):
			squad.append(_mobs[&"mob_fast"])
		if _mobs.has(&"mob_saboteur"):
			squad.append(_mobs[&"mob_saboteur"])
			score += 1.0
		squad.append(score)
		squads.append(squad)

	# Tank squad: armored + healer sustain
	if _mobs.has(&"mob_armored"):
		var score := 6.0
		if has_aoe > 0:
			score -= 1.0
		else:
			score += 3.0
		var squad: Array = []
		squad.append(_mobs[&"mob_armored"])
		squad.append(_mobs[&"mob_armored"])
		if _mobs.has(&"mob_healer"):
			squad.append(_mobs[&"mob_healer"])
			score += 2.0
		squad.append(score)
		squads.append(squad)

	# Siege squad: siege golems to destroy walls/towers
	if _mobs.has(&"mob_siege") and round_num >= 3:
		var score := 5.0
		# Good vs heavy wall mazes
		var wall_count: int = _last_opponent_towers.get("Stone Wall", 0)
		if wall_count > 8:
			score += 4.0
		var squad: Array = []
		squad.append(_mobs[&"mob_siege"])
		if _mobs.has(&"mob_healer"):
			squad.append(_mobs[&"mob_healer"])
		squad.append(score)
		squads.append(squad)

	# Breacher squad: wall-targeting + support
	if _mobs.has(&"mob_breacher") and round_num >= 2:
		var score := 4.0
		var wall_count: int = _last_opponent_towers.get("Stone Wall", 0)
		if wall_count > 6:
			score += 3.0
		var squad: Array = []
		for _i in range(2):
			squad.append(_mobs[&"mob_breacher"])
		squad.append(_mobs.get(&"mob_basic", null))
		squad.append(score)
		squads.append(squad)

	# Air squad: bypass maze entirely
	if _mobs.has(&"mob_flying") and not has_antiair:
		var score := 8.0  # very strong when no anti-air
		var squad: Array = []
		for _i in range(3):
			squad.append(_mobs[&"mob_flying"])
		squad.append(score)
		squads.append(squad)
	elif _mobs.has(&"mob_flying") and has_antiair:
		# Still send a few to force anti-air commitment, low priority
		var score := 2.0
		var squad: Array = [_mobs[&"mob_flying"]]
		squad.append(score)
		squads.append(squad)

	# Swarm squad: overwhelm with numbers
	if _mobs.has(&"mob_swarm"):
		var score := 5.0
		if has_aoe > 2:
			score -= 3.0  # AoE destroys swarms
		else:
			score += 3.0  # single-target can't handle mass
		var squad: Array = []
		for _i in range(3):
			squad.append(_mobs[&"mob_swarm"])
		squad.append(score)
		squads.append(squad)

	# Saboteur squad: debuff + damage dealers
	if _mobs.has(&"mob_saboteur") and total_towers > 5:
		var score := 6.0
		var squad: Array = []
		squad.append(_mobs[&"mob_saboteur"])
		squad.append(_mobs[&"mob_saboteur"])
		if _mobs.has(&"mob_armored"):
			squad.append(_mobs[&"mob_armored"])
		squad.append(score)
		squads.append(squad)

	# Mixed squad: balanced composition (fallback)
	if _mobs.has(&"mob_basic"):
		var score := 4.0
		var squad: Array = []
		squad.append(_mobs[&"mob_basic"])
		squad.append(_mobs[&"mob_basic"])
		if _mobs.has(&"mob_armored"):
			squad.append(_mobs[&"mob_armored"])
		if _mobs.has(&"mob_healer"):
			squad.append(_mobs[&"mob_healer"])
		squad.append(score)
		squads.append(squad)

	return squads

func _squad_cost(squad: Array) -> int:
	var total := 0
	for i in range(squad.size() - 1):  # last element is score
		var mob: MobData = squad[i] if squad[i] is MobData else null
		if mob != null:
			total += mob.cost
	return total

func _squad_mob_count(squad: Array) -> int:
	var count := 0
	for i in range(squad.size() - 1):
		if squad[i] is MobData:
			count += 1
	return count

func _find_cheapest_mob() -> MobData:
	var cheapest: MobData = null
	for mob_data in _mobs.values():
		if cheapest == null or mob_data.cost < cheapest.cost:
			cheapest = mob_data
	return cheapest

# ---------- Tower upgrades ----------

func _upgrade_towers() -> void:
	if player_world == null:
		return
	var tower_nodes: Dictionary = player_world.get("_tower_nodes")
	if tower_nodes == null or tower_nodes.is_empty():
		return
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
		if not EconomyManager.can_afford(PLAYER_INDEX, upgrade_data.cost):
			continue
		EconomyManager.spend(PLAYER_INDEX, upgrade_data.cost)
		tower_node.call("upgrade", upgrade_data)

# ---------- Placement helper ----------

func _place_item_at(item: Resource, col: int, row: int) -> void:
	player_world.call("set_selected_item", item)
	player_world.set("_cursor_col", col)
	player_world.set("_cursor_row", row)
	player_world.call("_try_place")

# ---------- Utility ----------

func _weighted_pick(pool: Array) -> Variant:
	# pool = [[item, weight], ...]
	var total := 0.0
	for entry in pool:
		total += entry[1]
	if total <= 0.0:
		return pool[0][0]
	var roll := randf() * total
	var cum := 0.0
	for entry in pool:
		cum += entry[1]
		if roll <= cum:
			return entry[0]
	return pool[pool.size() - 1][0]

# ---------- State transitions ----------

func _on_state_changed(new_state: GameManager.GameState) -> void:
	if new_state == GameManager.GameState.PREP:
		_think_timer = 0.5
		_acted_this_prep = false
	elif new_state == GameManager.GameState.PLAY:
		# Snapshot for next round's analysis
		_record_round_start()

func _record_round_start() -> void:
	# Track leak rate from previous round by comparing mob counts
	# (simplified: track HP delta as proxy for leaks)
	var my_hp: int = player_world.get("current_hp") if player_world.get("current_hp") != null else 20
	var hp_lost := _my_hp_prev - my_hp
	# Rough leak rate: each leaked mob does 1-4 damage; estimate
	_my_leak_rate = clampf(float(hp_lost) / 5.0, 0.0, 1.0)
	_my_hp_prev = my_hp
