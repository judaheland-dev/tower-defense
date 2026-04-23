extends Node3D

## PlayerWorld - owns one player's 3D field including grid, towers, and mobs.
## One instance lives inside each player's SubViewport.

const GRID_COLS: int = 18
const GRID_ROWS: int = 14
const CELL_SIZE: float = 2.0  # world units per cell (X and Z)
const STARTING_HP: int = 20

# Set by Game.gd before adding to tree
var player_index: int = 0

var current_hp: int = STARTING_HP

# Grid state: true = occupied by a tower/wall
var _grid: Array = []  # Array[Array[bool]] - [col][row]

# Placed tower nodes indexed by "col,row" key
var _tower_nodes: Dictionary = {}

# Active mob nodes
var _mob_nodes: Array[Node] = []

# Child nodes
var _camera: Camera3D = null
var _nav_region: NavigationRegion3D = null
var _cursor: Node3D = null
var _pathfinding: Node = null

# Cursor grid position
var _cursor_col: int = 9
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

func _ready() -> void:
	add_to_group("nav_geo")  # lets the NavigationMesh bake scan this node + all children
	_init_grid()
	_build_camera()
	_build_lighting()
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
	# Cell center in world space; Y=0 is the tile surface
	var x := (col - GRID_COLS * 0.5 + 0.5) * CELL_SIZE
	var z := (row - GRID_ROWS * 0.5 + 0.5) * CELL_SIZE
	return Vector3(x, 0.0, z)

func _spawn_world_pos() -> Vector3:
	# Spawn at north edge center - one cell beyond row 0 so mobs enter the grid
	return Vector3(0.0, 0.0, (-(GRID_ROWS * 0.5 + 0.5)) * CELL_SIZE)

func _exit_world_pos() -> Vector3:
	# Exit at south edge center
	return Vector3(0.0, 0.0, ((GRID_ROWS * 0.5 + 0.5)) * CELL_SIZE)

# ---------- scene construction ----------

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 22.0
	_camera.position = Vector3(10.0, 14.0, 10.0)
	add_child(_camera)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

func _build_lighting() -> void:
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.12, 0.14, 0.18)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.55, 0.6)
	environment.ambient_light_energy = 0.6
	env.environment = environment
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, 45.0, 0.0)
	sun.light_energy = 1.2
	add_child(sun)

func _build_ground() -> void:
	# Flat colored plane as ground backdrop
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(GRID_COLS * CELL_SIZE + 4.0, GRID_ROWS * CELL_SIZE + 4.0)
	ground.mesh = plane
	ground.position = Vector3(0.0, -0.05, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.35, 0.2)
	ground.set_surface_override_material(0, mat)

	# StaticBody for nav mesh floor
	var body := StaticBody3D.new()
	var cshape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GRID_COLS * CELL_SIZE + 4.0, 0.1, GRID_ROWS * CELL_SIZE + 4.0)
	cshape.shape = box
	body.add_child(cshape)
	body.collision_layer = 1
	add_child(body)
	add_child(ground)

func _build_nav_region() -> void:
	_nav_region = NavigationRegion3D.new()
	var nav_mesh := NavigationMesh.new()
	# Scan nodes in group "nav_geo" and their children.
	# PlayerWorld adds itself to this group in _ready(), so all ground/tower
	# StaticBodies (which are children of PlayerWorld) will be included in the bake.
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
	box.size = Vector3(CELL_SIZE - 0.1, 0.12, CELL_SIZE - 0.1)
	cursor_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 0.2, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cursor_mesh.set_surface_override_material(0, mat)
	_cursor.add_child(cursor_mesh)

	add_child(_cursor)
	_update_cursor_visual()
	_build_spawn_exit_markers()

func _build_spawn_exit_markers() -> void:
	# Green diamond at spawn, red diamond at exit
	for i in 2:
		var is_exit := i == 1
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
		var p := _exit_world_pos() if is_exit else _spawn_world_pos()
		marker.position = Vector3(p.x, 0.6, p.z)
		add_child(marker)

func _update_cursor_visual() -> void:
	if _cursor == null:
		return
	var pos := cell_to_world(_cursor_col, _cursor_row)
	_cursor.position = Vector3(pos.x, 0.1, pos.z)
	# Tint red if cell is occupied
	var mesh: MeshInstance3D = _cursor.get_child(0)
	if mesh:
		var mat: StandardMaterial3D = mesh.get_surface_override_material(0)
		if mat:
			mat.albedo_color = Color(1.0, 0.2, 0.2, 0.7) if _grid[_cursor_col][_cursor_row] else Color(1.0, 1.0, 0.2, 0.7)

# ---------- input / process ----------

func _process(delta: float) -> void:
	if GameManager.current_state != GameManager.GameState.PREP:
		_cursor.visible = false
		return
	_cursor.visible = true
	if shop_open:
		return
	_handle_cursor_input(delta)

	# Use direct polling - _unhandled_input does not fire inside SubViewport nodes
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
	if _grid[_cursor_col][_cursor_row]:
		return  # already occupied
	# Protect spawn and exit rows
	if _cursor_row == 0 or _cursor_row == GRID_ROWS - 1:
		return

	if _selected_item is TowerData:
		var data: TowerData = _selected_item
		if not EconomyManager.can_afford(player_index, data.cost):
			return
		# Place and pay immediately - validate path async and refund if blocked
		_grid[_cursor_col][_cursor_row] = true
		EconomyManager.spend(player_index, data.cost)
		_spawn_tower(data, _cursor_col, _cursor_row)
	elif _selected_item is MobData:
		var data: MobData = _selected_item
		if not EconomyManager.can_afford(player_index, data.cost):
			return
		EconomyManager.spend(player_index, data.cost)
		_queue_mob(data)

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
	var sfx := "res://assets/audio/sfx_place.ogg"
	if ResourceLoader.exists(sfx):
		AudioManager.play_sfx(load(sfx), -4.0)

# ---------- mob management ----------

var _queued_mobs: Array[MobData] = []

func _queue_mob(data: MobData) -> void:
	_queued_mobs.append(data)
	var sfx := "res://assets/audio/sfx_click.ogg"
	if ResourceLoader.exists(sfx):
		AudioManager.play_sfx(load(sfx), -6.0, 0.9)

func get_queued_mobs() -> Array[MobData]:
	return _queued_mobs

func clear_queued_mobs() -> void:
	_queued_mobs.clear()

func spawn_mob(data: MobData) -> void:
	var mob: Node = load("res://scenes/game/MobNode.gd").new()
	mob.data = data
	mob.field_player_index = player_index
	mob.nav_map = _nav_region.get_navigation_map()
	mob.exit_position = _exit_world_pos()
	mob.reached_exit.connect(_on_mob_reached_exit)
	mob.died.connect(_on_mob_died)
	add_child(mob)
	mob.position = _spawn_world_pos()
	_mob_nodes.append(mob)

func get_active_mob_count() -> int:
	var count := 0
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
			break

func _on_state_changed(new_state: GameManager.GameState) -> void:
	match new_state:
		GameManager.GameState.PLAY:
			_cursor.visible = false
			# Final bake at play start so mobs have an up-to-date nav mesh
			_pathfinding.bake_async()
