extends Node3D

## PlayerWorld - owns one player's half of the shared board.
## board_side=0 (LEFT/P1): cols 0-10, base at left edge, mobs enter from right (center).
## board_side=1 (RIGHT/P2): cols 0-10 (local), base at right edge, mobs enter from left (center).

const GRID_COLS: int = 11
const GRID_ROWS: int = 14
const CELL_SIZE: float = 2.0  # world units per cell (X and Z)
const STARTING_HP: int = 20

# Set by Game.gd before adding to tree
var player_index: int = 0
var board_side: int = 0  # 0 = LEFT, 1 = RIGHT

var current_hp: int = STARTING_HP

# Grid state: true = occupied by a tower/wall
var _grid: Array = []  # Array[Array[bool]] - [col][row]

# Placed tower nodes indexed by "col,row" key
var _tower_nodes: Dictionary = {}

# Active mob nodes
var _mob_nodes: Array[Node] = []

# Child nodes
var _nav_region: NavigationRegion3D = null
var _cursor: Node3D = null
var _pathfinding: Node = null

# Cursor grid position (local coords: 0..GRID_COLS-1, 0..GRID_ROWS-1)
var _cursor_col: int = 5
var _cursor_row: int = 7
var _cursor_repeat_timer: float = 0.0
const CURSOR_REPEAT_DELAY: float = 0.15

# Currently selected shop item data (TowerData or MobData or null)
var _selected_item: Resource = null
# Set to true by ShopUI when the shop panel is open - blocks cursor/action input
var shop_open: bool = false

signal hp_changed(new_hp: int)
signal mob_reached_exit(mob: Node)
signal selected_item_changed(item: Resource)
signal mob_queue_changed()
signal tower_changed()

func _ready() -> void:
	add_to_group("nav_geo")  # lets the NavigationMesh bake scan this node + all children
	# Position this half in world space
	# LEFT (side=0): origin at X=0, RIGHT (side=1): origin at X=22 (11 cols * 2 units)
	position.x = board_side * GRID_COLS * CELL_SIZE
	_init_grid()
	_build_ground()
	_build_nav_region()
	_build_cursor()

	_pathfinding = load("res://systems/PathfindingController.gd").new()
	_pathfinding.setup(_nav_region, _spawn_world_pos(), _exit_world_pos())
	add_child(_pathfinding)

	GameManager.state_changed.connect(_on_state_changed)

func _init_grid() -> void:
	_grid = []
	for c in GRID_COLS:
		var col: Array = []
		for r in GRID_ROWS:
			col.append(false)
		_grid.append(col)

# ---------- world positions ----------

func cell_to_world(col: int, row: int) -> Vector3:
	# Cell center in local space; Y=0 is the tile surface
	# col 0..10 maps to X = 0.5*CELL_SIZE .. (10.5)*CELL_SIZE = 1..21
	var x := (col + 0.5) * CELL_SIZE
	var z := (row - GRID_ROWS * 0.5 + 0.5) * CELL_SIZE
	return Vector3(x, 0.0, z)

func _spawn_world_pos() -> Vector3:
	# Mobs enter from the CENTER edge of the board
	if board_side == 0:
		# LEFT side: spawn at right edge (col 10 + 1 cell outside)
		return global_position + Vector3((GRID_COLS + 0.5) * CELL_SIZE, 0.0, 0.0)
	else:
		# RIGHT side: spawn at left edge (col 0 - 1 cell outside)
		return global_position + Vector3(-0.5 * CELL_SIZE, 0.0, 0.0)

func _exit_world_pos() -> Vector3:
	# Base/exit is on the OUTER edge
	if board_side == 0:
		# LEFT side: exit at left edge (col 0 - 1 cell outside)
		return global_position + Vector3(-0.5 * CELL_SIZE, 0.0, 0.0)
	else:
		# RIGHT side: exit at right edge (col 10 + 1 cell outside)
		return global_position + Vector3((GRID_COLS + 0.5) * CELL_SIZE, 0.0, 0.0)

# ---------- scene construction ----------

func _build_ground() -> void:
	# Invisible StaticBody for nav mesh floor (only StaticBodies are scanned)
	# The visual surface comes from tile.glb instances in _build_cell_tiles()
	var body := StaticBody3D.new()
	body.position = Vector3(GRID_COLS * CELL_SIZE * 0.5, 0.0, 0.0)
	var cshape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GRID_COLS * CELL_SIZE + 4.0, 0.1, GRID_ROWS * CELL_SIZE + 4.0)
	cshape.shape = box
	body.add_child(cshape)
	body.collision_layer = 1
	add_child(body)

	_build_cell_tiles()
	_build_border_decorations()

func _build_cell_tiles() -> void:
	# Use actual Kenney 3D tile models for the board surface
	const TILE_PATH := "res://assets/models/tower-defense-kit/tile.glb"
	var tile_scene: PackedScene = null
	if ResourceLoader.exists(TILE_PATH):
		tile_scene = load(TILE_PATH)

	for c in GRID_COLS:
		for r in GRID_ROWS:
			var pos := cell_to_world(c, r)
			if tile_scene:
				var inst := tile_scene.instantiate()
				inst.scale = Vector3.ONE * CELL_SIZE
				inst.position = Vector3(pos.x, 0.0, pos.z)
				add_child(inst)
			else:
				# Fallback: colored plane if GLB missing
				var quad := MeshInstance3D.new()
				var pmesh := PlaneMesh.new()
				pmesh.size = Vector2(CELL_SIZE - 0.06, CELL_SIZE - 0.06)
				quad.mesh = pmesh
				var mat := StandardMaterial3D.new()
				mat.albedo_color = Color(0.22, 0.44, 0.20) if (c + r) % 2 == 0 else Color(0.30, 0.54, 0.26)
				quad.set_surface_override_material(0, mat)
				quad.position = Vector3(pos.x, 0.02, pos.z)
				add_child(quad)

func _build_border_decorations() -> void:
	var base := "res://assets/models/tower-defense-kit/"
	var half_w := GRID_COLS * CELL_SIZE  # 22 units wide
	var half_h := GRID_ROWS * CELL_SIZE * 0.5  # 14 units half-depth
	# Decorations along the top and bottom edges of this player's half
	var decor: Array = [
		# Top edge (Z negative)
		[base + "detail-tree-large.glb", 4.0, -(half_h + 2.0)],
		[base + "detail-tree.glb",       11.0, -(half_h + 1.5)],
		[base + "detail-rocks.glb",      18.0, -(half_h + 2.0)],
		# Bottom edge (Z positive)
		[base + "detail-tree-large.glb", 4.0,  half_h + 2.0],
		[base + "detail-tree.glb",       11.0, half_h + 1.5],
		[base + "detail-rocks.glb",      18.0, half_h + 2.0],
		# Outer edge (base side)
		[base + "detail-crystal.glb",    -1.5, -6.0],
		[base + "detail-crystal-large.glb", -1.5, 6.0],
	]
	for d in decor:
		var path: String = d[0]
		if not ResourceLoader.exists(path):
			continue
		var scene: PackedScene = load(path)
		var inst := scene.instantiate()
		inst.scale = Vector3.ONE * CELL_SIZE
		inst.position = Vector3(d[1], 0.0, d[2])
		add_child(inst)

func _build_nav_region() -> void:
	_nav_region = NavigationRegion3D.new()
	var nav_mesh := NavigationMesh.new()
	# PARSED_GEOMETRY_STATIC_COLLIDERS: only reads StaticBody3D collision shapes.
	# The floor body (PlayerWorld) and tower bodies carve the walkable area cleanly.
	# Decoration GLB meshes (trees, rocks) are ignored, preventing them from
	# creating spurious obstacles in the navmesh.
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav_mesh.geometry_source_group_name = StringName("nav_geo")
	nav_mesh.agent_radius = 0.3
	nav_mesh.agent_height = 1.0
	nav_mesh.cell_size = 0.3
	nav_mesh.filter_walkable_low_height_spans = true
	_nav_region.navigation_mesh = nav_mesh
	add_child(_nav_region)

func _build_cursor() -> void:
	_cursor = Node3D.new()
	_cursor.name = "GridCursor"

	var cursor_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	# Tall enough (0.4) to be clearly visible above the cell quads at Y=0.02
	box.size = Vector3(CELL_SIZE - 0.1, 0.4, CELL_SIZE - 0.1)
	cursor_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	# P1 = blue/cyan cursor, P2 = orange/red cursor
	if board_side == 0:
		mat.albedo_color = Color(0.3, 0.8, 1.0, 0.75)
	else:
		mat.albedo_color = Color(1.0, 0.6, 0.2, 0.75)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cursor_mesh.set_surface_override_material(0, mat)
	_cursor.add_child(cursor_mesh)

	add_child(_cursor)
	_update_cursor_visual()
	_build_spawn_exit_markers()

func _build_spawn_exit_markers() -> void:
	# Convert global spawn/exit to local space for child positioning
	var spawn_pos := _spawn_world_pos() - global_position
	var exit_pos  := _exit_world_pos() - global_position

	const SPAWN_PATH := "res://assets/models/tower-defense-kit/tile-spawn-round.glb"
	if ResourceLoader.exists(SPAWN_PATH):
		var scene: PackedScene = load(SPAWN_PATH)
		var inst := scene.instantiate()
		inst.scale = Vector3.ONE * CELL_SIZE
		inst.position = Vector3(spawn_pos.x, 0.0, spawn_pos.z)
		add_child(inst)
	else:
		_add_fallback_marker(spawn_pos, false)

	const EXIT_PATH := "res://assets/models/tower-defense-kit/tile-end-round.glb"
	if ResourceLoader.exists(EXIT_PATH):
		var scene: PackedScene = load(EXIT_PATH)
		var inst := scene.instantiate()
		inst.scale = Vector3.ONE * CELL_SIZE
		inst.position = Vector3(exit_pos.x, 0.0, exit_pos.z)
		add_child(inst)
	else:
		_add_fallback_marker(exit_pos, true)

func _add_fallback_marker(world_pos: Vector3, is_exit: bool) -> void:
	var marker := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	marker.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.25, 0.25) if is_exit else Color(0.25, 1.0, 0.4)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color
	mat.emission_energy_multiplier = 0.8
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.set_surface_override_material(0, mat)
	marker.position = Vector3(world_pos.x, 0.6, world_pos.z)
	add_child(marker)

func _update_cursor_visual() -> void:
	if _cursor == null:
		return
	var pos := cell_to_world(_cursor_col, _cursor_row)
	_cursor.position = Vector3(pos.x, 0.55, pos.z)
	# Tint red if cell is occupied, otherwise use player color
	var mesh: MeshInstance3D = _cursor.get_child(0)
	if mesh:
		var mat: StandardMaterial3D = mesh.get_surface_override_material(0)
		if mat:
			if _grid[_cursor_col][_cursor_row]:
				mat.albedo_color = Color(1.0, 0.2, 0.2, 0.7)
			elif board_side == 0:
				mat.albedo_color = Color(0.3, 0.8, 1.0, 0.75)
			else:
				mat.albedo_color = Color(1.0, 0.6, 0.2, 0.75)

# ---------- input / process ----------

func _process(delta: float) -> void:
	if GameManager.current_state == GameManager.GameState.PLAY:
		_process_pending_spawns(delta)

	if GameManager.current_state != GameManager.GameState.PREP:
		_cursor.visible = false
		return
	_cursor.visible = true
	if shop_open:
		return
	_handle_cursor_input(delta)

	# Direct polling for actions
	var pfx := "p1_" if player_index == 0 else "p2_"
	if Input.is_action_just_pressed(pfx + "confirm"):
		_try_place()
	elif Input.is_action_just_pressed(pfx + "cancel"):
		if _selected_item != null:
			set_selected_item(null)
			# don't fall through to ready-up; that's handled in Game.gd
	elif Input.is_action_just_pressed(pfx + "sell"):
		_try_sell()

func _handle_cursor_input(delta: float) -> void:
	var dir := InputManager.get_cursor_dir(player_index)
	if dir == Vector2.ZERO:
		_cursor_repeat_timer = 0.0
		return

	_cursor_repeat_timer -= delta
	if _cursor_repeat_timer > 0.0:
		return
	_cursor_repeat_timer = CURSOR_REPEAT_DELAY

	var new_col := clampi(_cursor_col + int(sign(dir.x)), 0, GRID_COLS - 1)
	var new_row := clampi(_cursor_row + int(sign(dir.y)), 0, GRID_ROWS - 1)
	_cursor_col = new_col
	_cursor_row = new_row
	_update_cursor_visual()

# ---------- placement / selling ----------

func set_selected_item(item: Resource) -> void:
	_selected_item = item
	selected_item_changed.emit(item)

func get_selected_item_name() -> String:
	if _selected_item == null:
		return ""
	var n: Variant = _selected_item.get("display_name")
	return n if n is String else ""

func _try_place() -> void:
	if _selected_item == null:
		return
	# Mob purchases don't need a grid cell - handle before any grid checks
	if _selected_item is MobData:
		var data: MobData = _selected_item
		if not EconomyManager.can_afford(player_index, data.cost):
			return
		EconomyManager.spend(player_index, data.cost)
		_queue_mob(data)
		return
	if _grid[_cursor_col][_cursor_row]:
		return  # already occupied
	# Protect cells near spawn (center edge) and exit (outer edge)
	var near_spawn: bool
	var near_exit: bool
	if board_side == 0:
		# LEFT: spawn at col 10 (right edge), exit at col 0 (left edge)
		near_spawn = _cursor_col >= GRID_COLS - 2 and _cursor_row >= GRID_ROWS / 2 - 1 and _cursor_row <= GRID_ROWS / 2
		near_exit = _cursor_col <= 1 and _cursor_row >= GRID_ROWS / 2 - 1 and _cursor_row <= GRID_ROWS / 2
	else:
		# RIGHT: spawn at col 0 (left edge), exit at col 10 (right edge)
		near_spawn = _cursor_col <= 1 and _cursor_row >= GRID_ROWS / 2 - 1 and _cursor_row <= GRID_ROWS / 2
		near_exit = _cursor_col >= GRID_COLS - 2 and _cursor_row >= GRID_ROWS / 2 - 1 and _cursor_row <= GRID_ROWS / 2
	if near_spawn or near_exit:
		return

	if _selected_item is TowerData:
		var data: TowerData = _selected_item
		if not EconomyManager.can_afford(player_index, data.cost):
			return
		# Place and pay immediately - validate path async and refund if blocked
		_grid[_cursor_col][_cursor_row] = true
		EconomyManager.spend(player_index, data.cost)
		_spawn_tower(data, _cursor_col, _cursor_row)

func _try_sell() -> void:
	var key := "%d,%d" % [_cursor_col, _cursor_row]
	if not _tower_nodes.has(key):
		return
	var tower_node: Node = _tower_nodes[key]
	var data: TowerData = tower_node.get("data")
	if data:
		EconomyManager.add_coins(player_index, data.sell_value)
	tower_node.queue_free()
	_tower_nodes.erase(key)
	_grid[_cursor_col][_cursor_row] = false
	_pathfinding.bake_async()
	tower_changed.emit()

# ---------- tower spawning ----------

func _spawn_tower(data: TowerData, col: int, row: int) -> void:
	var tower: Node = load("res://scenes/game/TowerNode.gd").new()
	tower.data = data
	tower.field_player_index = player_index
	add_child(tower)
	var world_pos := cell_to_world(col, row)
	tower.position = Vector3(world_pos.x, 0.0, world_pos.z)
	var key := "%d,%d" % [col, row]
	_tower_nodes[key] = tower
	_pathfinding.bake_async()
	tower_changed.emit()
	AudioManager.play_sfx_path("res://assets/audio/sfx_place.ogg", -4.0)

# ---------- mob management ----------

const SPAWN_INTERVAL: float = 0.35

var _queued_mobs: Array[MobData] = []
var _pending_spawns: Array[MobData] = []
var _spawn_timer: float = 0.0

func _queue_mob(data: MobData) -> void:
	_queued_mobs.append(data)
	mob_queue_changed.emit()
	AudioManager.play_sfx_path("res://assets/audio/sfx_click.ogg", -6.0, 0.9)

func get_queued_mobs() -> Array[MobData]:
	return _queued_mobs

func clear_queued_mobs() -> void:
	_queued_mobs.clear()
	mob_queue_changed.emit()

func get_queued_mob_counts() -> Dictionary:
	# Returns {display_name: {"count": int, "color": Color, "model_path": String}}
	var counts := {}
	for mob_data in _queued_mobs:
		var n: String = mob_data.display_name
		if not counts.has(n):
			counts[n] = {"count": 0, "color": mob_data.icon_color, "model_path": mob_data.model_path}
		counts[n]["count"] += 1
	return counts

func get_tower_counts() -> Dictionary:
	# Returns {display_name: {"count": int, "color": Color, "model_path": String}}
	var counts := {}
	for tower_node in _tower_nodes.values():
		var data: TowerData = tower_node.get("data")
		if data:
			var n: String = data.display_name
			if not counts.has(n):
				counts[n] = {"count": 0, "color": data.icon_color, "model_path": data.model_path}
			counts[n]["count"] += 1
	return counts

func spawn_mob(data: MobData) -> void:
	var mob: Node = load("res://scenes/game/MobNode.gd").new()
	mob.data = data
	mob.field_player_index = player_index
	mob.nav_map = _nav_region.get_navigation_map()
	mob.exit_position = _exit_world_pos()
	mob.reached_exit.connect(_on_mob_reached_exit)
	mob.died.connect(_on_mob_died)
	add_child(mob)
	# Position at spawn with slight jitter so mobs don't stack on the same pixel
	var jitter := Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3))
	mob.global_position = _spawn_world_pos() + jitter
	_mob_nodes.append(mob)

func queue_mob_spawns(mobs: Array) -> void:
	for m in mobs:
		var count: int = m.get("spawn_count") if m.get("spawn_count") != null else 1
		for _j in maxi(count, 1):
			_pending_spawns.append(m)
	_spawn_timer = 0.0  # first mob spawns immediately

func _process_pending_spawns(delta: float) -> void:
	if _pending_spawns.is_empty():
		return
	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		var data: MobData = _pending_spawns.pop_front()
		spawn_mob(data)
		_spawn_timer = SPAWN_INTERVAL

func get_active_mob_count() -> int:
	var count := _pending_spawns.size()  # include mobs waiting to spawn
	for m in _mob_nodes:
		if is_instance_valid(m) and not m.is_queued_for_deletion():
			count += 1
	return count

func _on_mob_reached_exit(mob: Node) -> void:
	var data: MobData = mob.get("data")
	if data:
		take_damage(int(data.base_damage))
	mob_reached_exit.emit(mob)
	_mob_nodes.erase(mob)

func _on_mob_died(mob: Node) -> void:
	_mob_nodes.erase(mob)
	# Award bounty to this player (defender)
	var data: MobData = mob.get("data")
	if data:
		EconomyManager.add_coins(player_index, data.bounty)

# ---------- HP ----------

func take_damage(amount: int) -> void:
	current_hp -= amount
	hp_changed.emit(current_hp)
	if current_hp <= 0:
		GameManager.set_state(GameManager.GameState.GAME_OVER)

# ---------- state transitions ----------

func on_tower_destroyed(tower: Node) -> void:
	# Find and free the grid cell occupied by this tower
	for key in _tower_nodes.keys():
		if _tower_nodes[key] == tower:
			_tower_nodes.erase(key)
			var parts: PackedStringArray = key.split(",")
			if parts.size() == 2:
				_grid[int(parts[0])][int(parts[1])] = false
			_pathfinding.bake_async()
			tower_changed.emit()
			break

func _on_state_changed(new_state: GameManager.GameState) -> void:
	match new_state:
		GameManager.GameState.PREP:
			# Free any mobs left over from last round (e.g. stuck mobs)
			for m in _mob_nodes:
				if is_instance_valid(m) and not m.is_queued_for_deletion():
					m.queue_free()
			_mob_nodes.clear()
			_pending_spawns.clear()
		GameManager.GameState.PLAY:
			_cursor.visible = false
			# Final bake at play start so mobs have an up-to-date nav mesh
			_pathfinding.bake_async()
