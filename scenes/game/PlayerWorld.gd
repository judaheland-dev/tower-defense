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

# Placed trap nodes indexed by "col,row" key
var _trap_nodes: Dictionary = {}

# Active mob nodes
var _mob_nodes: Array[Node] = []

# Child nodes
var _nav_region: NavigationRegion3D = null
var _cursor: Node3D = null
var _pathfinding: Node = null

# Gate structure (destructible base)
var _gate_root: Node3D = null
var _gate_center: Node3D = null  # gate.glb instance
var _gate_walls: Array[Node3D] = []  # flanking wall instances
var _gate_materials: Array[StandardMaterial3D] = []  # override mats for damage tinting
var _gate_rubble: Array[Node3D] = []  # rubble spawned at low HP
var _gate_original_transforms: Array[Transform3D] = []  # initial transforms for damage offsets
var _gate_destroyed: bool = false

# Cursor grid position (local coords: 0..GRID_COLS-1, 0..GRID_ROWS-1)
var _cursor_col: int = 5
var _cursor_row: int = 7
var _cursor_repeat_timer: float = 0.0
const CURSOR_REPEAT_DELAY: float = 0.15

# Currently selected shop item data (TowerData or MobData or TrapData or null)
var _selected_item: Resource = null
# Set to true by ShopUI when the shop panel is open - blocks cursor/action input
var shop_open: bool = false

signal hp_changed(new_hp: int)
signal mob_reached_exit(mob: Node)
signal selected_item_changed(item: Resource)
signal mob_queue_changed()
signal tower_changed()
signal trap_changed()

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
	hp_changed.connect(_on_hp_changed_gate)

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

	_build_gate(exit_pos)

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

func _build_gate(exit_local_pos: Vector3) -> void:
	_gate_root = Node3D.new()
	_gate_root.name = "GateStructure"
	_gate_root.position = Vector3(exit_local_pos.x, 0.0, exit_local_pos.z)
	add_child(_gate_root)

	# Gate faces toward the play field along X axis.
	# gate.glb opening faces along Z by default; rotate 90 deg to face along X.
	var facing := PI * 0.5 if board_side == 0 else -PI * 0.5
	var outward := -1.0 if board_side == 0 else 1.0

	const GATE_PATH := "res://assets/models/mini-dungeon/Models/GLB format/gate.glb"
	const WALL_PATH := "res://assets/models/mini-dungeon/Models/GLB format/wall.glb"

	# Double gate back-to-back so doors are visible from both sides
	if ResourceLoader.exists(GATE_PATH):
		var scene: PackedScene = load(GATE_PATH)
		_gate_center = scene.instantiate()
		_gate_center.scale = Vector3.ONE * CELL_SIZE * 1.5
		_gate_center.rotation.y = facing
		_gate_root.add_child(_gate_center)
		_gate_original_transforms.append(_gate_center.transform)
		_apply_gate_material_override(_gate_center)

		var gate_back := scene.instantiate()
		gate_back.scale = Vector3.ONE * CELL_SIZE * 1.5
		gate_back.rotation.y = facing + PI
		gate_back.position.x = outward * 0.05  # tiny offset to avoid z-fighting
		_gate_root.add_child(gate_back)

		# Wooden door panels inside the gate archway
		_build_gate_doors(outward)
	else:
		_add_fallback_marker(exit_local_pos, true)
		return

	if not ResourceLoader.exists(WALL_PATH):
		return

	var wall_scene: PackedScene = load(WALL_PATH)
	var ws := CELL_SIZE  # wall scale and spacing -- 1:1 means seamless
	var town_depth := CELL_SIZE * 4.0  # 8 units outward
	var town_half_z := CELL_SIZE * 6.0  # 12 units from center to edge

	# --- Front wall line (flanking the gate, along Z) ---
	# Gate at scale 1.5 occupies ~3 units; first wall at ±ws clears it
	var z := ws
	while z <= town_half_z + 0.1:
		for s in [-1.0, 1.0]:
			var wall := wall_scene.instantiate()
			wall.scale = Vector3.ONE * ws
			wall.rotation.y = facing
			wall.position.z = s * z
			_gate_root.add_child(wall)
			# Track 4 closest walls for damage animation
			if z <= ws * 2:
				_gate_walls.append(wall)
				_gate_original_transforms.append(wall.transform)
				_apply_gate_material_override(wall)
		z += ws

	# --- Back wall (along Z, at far edge of town) ---
	z = -town_half_z
	while z <= town_half_z + 0.1:
		var wall := wall_scene.instantiate()
		wall.scale = Vector3.ONE * ws
		wall.rotation.y = facing
		wall.position = Vector3(outward * town_depth, 0.0, z)
		_gate_root.add_child(wall)
		z += ws

	# --- Side walls (north + south edges, running outward along X) ---
	var x := 0.0
	while x <= town_depth + 0.1:
		for side_z in [-town_half_z, town_half_z]:
			var wall := wall_scene.instantiate()
			wall.scale = Vector3.ONE * ws
			wall.rotation.y = 0.0  # perpendicular to front wall
			wall.position = Vector3(outward * x, 0.0, side_z)
			_gate_root.add_child(wall)
		x += ws

	# --- Dirt/stone floor inside the enclosure ---
	_build_town_floor(outward, town_depth, town_half_z)
	# --- Buildings and props inside ---
	_build_town_interiors(outward, town_depth, town_half_z)

func _build_town_floor(outward: float, depth: float, half_z: float) -> void:
	const DIRT_PATH := "res://assets/models/tower-defense-kit/tile-dirt.glb"
	const ROCK_PATH := "res://assets/models/tower-defense-kit/tile-rock.glb"
	var dirt_scene: PackedScene = null
	var rock_scene: PackedScene = null
	if ResourceLoader.exists(DIRT_PATH):
		dirt_scene = load(DIRT_PATH)
	if ResourceLoader.exists(ROCK_PATH):
		rock_scene = load(ROCK_PATH)
	if dirt_scene == null:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = 99 + player_index
	var step := CELL_SIZE
	# Fill interior rectangle with floor tiles
	var x := step  # start one step inward to avoid overlapping front wall
	while x < depth:
		var z := -half_z + step
		while z < half_z:
			var scene: PackedScene = dirt_scene
			if rock_scene and rng.randf() < 0.15:
				scene = rock_scene
			var inst := scene.instantiate()
			inst.scale = Vector3.ONE * step
			inst.position = Vector3(outward * x, 0.01, z)
			inst.rotation.y = rng.randi_range(0, 3) * PI * 0.5
			_gate_root.add_child(inst)
			z += step
		x += step

func _build_town_interiors(outward: float, depth: float, half_z: float) -> void:
	const TD_BASE := "res://assets/models/tower-defense-kit/"
	const MD_BASE := "res://assets/models/mini-dungeon/Models/GLB format/"
	var facing := PI * 0.5 if board_side == 0 else -PI * 0.5

	# Buildings using tower build phases as medieval structures
	var buildings: Array = [
		# [model_path, x_offset_fraction, z_offset, scale_mult, y_rotation]
		[TD_BASE + "tower-round-build-e.glb",  0.35, -8.0, 1.0, 0.0],
		[TD_BASE + "tower-square-build-d.glb", 0.65, -4.0, 0.9, PI * 0.25],
		[TD_BASE + "tower-round-build-c.glb",  0.35,  4.0, 0.85, PI * 0.5],
		[TD_BASE + "tower-square-build-e.glb", 0.75, -8.0, 0.8, PI * 0.75],
		[TD_BASE + "tower-round-build-d.glb",  0.85,  4.0, 0.75, PI],
		[TD_BASE + "tower-square-build-c.glb", 0.55,  8.0, 0.7, 0.3],
		[TD_BASE + "tower-round-build-f.glb",  0.50,  0.0, 1.0, PI * 1.5],
		[TD_BASE + "wood-structure.glb",       0.40, -1.5, 0.8, PI * 0.5],
		[TD_BASE + "wood-structure.glb",       0.80,  7.5, 0.75, 0.0],
	]

	# Props
	var props: Array = [
		[MD_BASE + "barrel.glb",  0.25, -2.5, 0.6, 0.0],
		[MD_BASE + "barrel.glb",  0.28, -1.8, 0.55, 0.8],
		[MD_BASE + "chest.glb",   0.50,  2.5, 0.6, PI * 0.3],
		[MD_BASE + "banner.glb",  0.20,  0.0, 0.9, facing],
		[MD_BASE + "banner.glb",  0.20, -6.0, 0.85, facing],
		[MD_BASE + "barrel.glb",  0.70,  5.0, 0.55, 1.2],
		[MD_BASE + "stairs.glb",  0.60, -5.0, 0.7, facing],
	]

	for def in buildings:
		var x_off := outward * depth * float(def[1])
		_place_town_piece(_gate_root, def[0], x_off, def[2], def[3], def[4])

	for def in props:
		var x_off := outward * depth * float(def[1])
		_place_town_piece(_gate_root, def[0], x_off, def[2], def[3], def[4])

func _place_town_piece(parent: Node3D, model_path: String, x_off: float, z_off: float, scale_mult: float, y_rot: float) -> void:
	if not ResourceLoader.exists(model_path):
		return
	var scene: PackedScene = load(model_path)
	var inst := scene.instantiate()
	inst.scale = Vector3.ONE * CELL_SIZE * scale_mult
	inst.position = Vector3(x_off, 0.0, z_off)
	inst.rotation.y = y_rot
	parent.add_child(inst)

func _build_gate_doors(outward: float) -> void:
	# Two wooden door panels that sit inside the gate archway, giving it
	# the look of a real openable gate with wood plank doors.
	var door_container := Node3D.new()
	door_container.name = "GateDoors"
	_gate_center.add_child(door_container)

	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = Color(0.45, 0.28, 0.12)  # dark oak wood

	var plank_mat := StandardMaterial3D.new()
	plank_mat.albedo_color = Color(0.35, 0.22, 0.08)  # darker planks for contrast

	var iron_mat := StandardMaterial3D.new()
	iron_mat.albedo_color = Color(0.2, 0.2, 0.22)  # dark iron fittings
	iron_mat.metallic = 0.7
	iron_mat.roughness = 0.4

	# Door dimensions (in gate-local space, gate is scaled 1.5*CELL_SIZE)
	# The gate model is ~1 unit across; we work in local scale
	var door_h := 0.65  # height of the door panels
	var door_w := 0.28  # half-width (two doors side by side)
	var door_d := 0.06  # thickness

	# Left door panel
	for side in [-1.0, 1.0]:
		var door := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(door_w, door_h, door_d)
		door.mesh = box
		door.set_surface_override_material(0, wood_mat)
		door.position = Vector3(side * door_w * 0.5, door_h * 0.5 + 0.02, 0.0)
		door_container.add_child(door)

		# Horizontal plank lines across each door for detail
		for plank_y in [0.15, 0.35, 0.55]:
			var plank := MeshInstance3D.new()
			var pbox := BoxMesh.new()
			pbox.size = Vector3(door_w + 0.01, 0.04, door_d + 0.02)
			plank.mesh = pbox
			plank.set_surface_override_material(0, plank_mat)
			plank.position = Vector3(side * door_w * 0.5, plank_y + 0.02, 0.0)
			door_container.add_child(plank)

		# Iron hinge bands
		for hinge_y in [0.20, 0.50]:
			var hinge := MeshInstance3D.new()
			var hbox := BoxMesh.new()
			hbox.size = Vector3(door_w * 0.6, 0.025, door_d + 0.04)
			hinge.mesh = hbox
			hinge.set_surface_override_material(0, iron_mat)
			hinge.position = Vector3(side * door_w * 0.5, hinge_y + 0.02, 0.0)
			door_container.add_child(hinge)

	# Iron crossbar across both doors
	var crossbar := MeshInstance3D.new()
	var cbox := BoxMesh.new()
	cbox.size = Vector3(door_w * 2.0 + 0.04, 0.035, door_d + 0.05)
	crossbar.mesh = cbox
	crossbar.set_surface_override_material(0, iron_mat)
	crossbar.position = Vector3(0.0, door_h * 0.55 + 0.02, 0.0)
	door_container.add_child(crossbar)

	# Store materials for damage tinting
	_gate_materials.append(wood_mat)
	_gate_materials.append(plank_mat)
	_gate_materials.append(iron_mat)

func _apply_gate_material_override(node: Node3D) -> void:
	# Find all MeshInstance3D children and apply a tintable override material
	var meshes: Array[MeshInstance3D] = []
	_collect_mesh_instances(node, meshes)
	for mi in meshes:
		for s in mi.mesh.get_surface_count() if mi.mesh else 0:
			var base_mat := mi.mesh.surface_get_material(s)
			if base_mat is StandardMaterial3D:
				var override := base_mat.duplicate() as StandardMaterial3D
				mi.set_surface_override_material(s, override)
				_gate_materials.append(override)

func _collect_mesh_instances(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_mesh_instances(child, result)

func _collect_gate_center_meshes() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if _gate_center:
		_collect_mesh_instances(_gate_center, result)
	return result

func _on_hp_changed_gate(new_hp: int) -> void:
	if _gate_destroyed:
		return
	if new_hp <= 0:
		_destroy_gate()
	else:
		_update_gate_damage(new_hp)

func _update_gate_damage(hp: int) -> void:
	var hp_pct := float(hp) / float(STARTING_HP)

	# Tint only the gate center materials darker/redder as damage increases
	var damage_t := 1.0 - hp_pct  # 0 = full hp, 1 = nearly dead
	var tint := Color(1.0, 1.0, 1.0).lerp(Color(0.35, 0.2, 0.15), damage_t)
	if _gate_center:
		for mesh in _collect_gate_center_meshes():
			for si in mesh.get_surface_override_material_count():
				var mat := mesh.get_surface_override_material(si)
				if mat is StandardMaterial3D:
					mat.albedo_color = mat.albedo_color.lerp(tint, 0.7)

	# Apply increasing positional/rotational offsets to gate center only
	if _gate_center and _gate_original_transforms.size() > 0:
		var orig := _gate_original_transforms[0]
		var jitter_rot := damage_t * 0.15  # up to ~8.6 degrees lean
		_gate_center.transform = orig
		_gate_center.rotation.z += jitter_rot * (1.0 if board_side == 0 else -1.0)
		_gate_center.position.y -= damage_t * 0.3  # sink slightly

	# Spawn rubble pieces at low HP
	if hp_pct < 0.4 and _gate_rubble.size() == 0:
		_spawn_gate_rubble()

func _spawn_gate_rubble() -> void:
	const WALL_HALF_PATH := "res://assets/models/mini-dungeon/Models/GLB format/wall-half.glb"
	if not ResourceLoader.exists(WALL_HALF_PATH):
		return
	var scene: PackedScene = load(WALL_HALF_PATH)
	var rng := RandomNumberGenerator.new()
	rng.seed = player_index * 100 + 7
	for i in 3:
		var rubble := scene.instantiate()
		rubble.scale = Vector3.ONE * CELL_SIZE * 0.5
		rubble.position = Vector3(
			rng.randf_range(-0.8, 0.8),
			0.0,
			rng.randf_range(-CELL_SIZE * 2.0, CELL_SIZE * 2.0)
		)
		rubble.rotation = Vector3(
			rng.randf_range(-0.3, 0.3),
			rng.randf_range(0.0, TAU),
			rng.randf_range(-0.5, 0.5)
		)
		_gate_root.add_child(rubble)
		_gate_rubble.append(rubble)

func _destroy_gate() -> void:
	_gate_destroyed = true
	AudioManager.play_sfx_path("res://assets/audio/sfx_explosion.ogg", 2.0)

	# Animate all gate pieces flying outward
	var all_pieces: Array[Node3D] = []
	if _gate_center:
		all_pieces.append(_gate_center)
	for w in _gate_walls:
		all_pieces.append(w)
	for r in _gate_rubble:
		all_pieces.append(r)

	# Direction: pieces fly away from the board (outward from exit)
	var outward_x := -1.0 if board_side == 0 else 1.0

	for piece in all_pieces:
		var tween := create_tween()
		tween.set_parallel(true)
		var target_pos := piece.position + Vector3(
			outward_x * 6.0,
			randf_range(1.0, 4.0),
			piece.position.z * 0.5
		)
		tween.tween_property(piece, "position", target_pos, 1.2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
		tween.tween_property(piece, "rotation:x", randf_range(-1.5, 1.5), 1.2)
		tween.tween_property(piece, "rotation:z", randf_range(-2.0, 2.0), 1.2)
		# Fade out by scaling down
		tween.tween_property(piece, "scale", Vector3.ZERO, 1.2).set_delay(0.4)

func _update_cursor_visual() -> void:
	if _cursor == null:
		return
	var pos := cell_to_world(_cursor_col, _cursor_row)
	_cursor.position = Vector3(pos.x, 0.55, pos.z)
	# Tint red if cell is occupied by tower/wall, green if trap, otherwise use player color
	var mesh: MeshInstance3D = _cursor.get_child(0)
	if mesh:
		var mat: StandardMaterial3D = mesh.get_surface_override_material(0)
		if mat:
			var key := "%d,%d" % [_cursor_col, _cursor_row]
			if _grid[_cursor_col][_cursor_row]:
				mat.albedo_color = Color(1.0, 0.2, 0.2, 0.7)
			elif _trap_nodes.has(key):
				mat.albedo_color = Color(0.4, 0.7, 0.3, 0.7)
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
		return  # already occupied by tower/wall
	var place_key := "%d,%d" % [_cursor_col, _cursor_row]
	if _trap_nodes.has(place_key):
		return  # already occupied by trap
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
	elif _selected_item is TrapData:
		var data: TrapData = _selected_item
		if not EconomyManager.can_afford(player_index, data.cost):
			return
		EconomyManager.spend(player_index, data.cost)
		_spawn_trap(data, _cursor_col, _cursor_row)

func _try_sell() -> void:
	var key := "%d,%d" % [_cursor_col, _cursor_row]
	if _tower_nodes.has(key):
		var tower_node: Node = _tower_nodes[key]
		var data: TowerData = tower_node.get("data")
		if data:
			var hp_frac: float = 1.0
			if tower_node.has_method("get_hp_fraction"):
				hp_frac = tower_node.call("get_hp_fraction")
			var refund := int(data.sell_value * hp_frac)
			EconomyManager.add_coins(player_index, refund)
		tower_node.queue_free()
		_tower_nodes.erase(key)
		_grid[_cursor_col][_cursor_row] = false
		_pathfinding.bake_async()
		tower_changed.emit()
		return
	if _trap_nodes.has(key):
		var trap_node: Node = _trap_nodes[key]
		var data: TrapData = trap_node.get("data")
		if data:
			EconomyManager.add_coins(player_index, data.sell_value)
		trap_node.queue_free()
		_trap_nodes.erase(key)
		trap_changed.emit()

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

# ---------- trap spawning ----------

func _spawn_trap(data: TrapData, col: int, row: int) -> void:
	var trap: Node = load("res://scenes/game/TrapNode.gd").new()
	trap.data = data
	trap.field_player_index = player_index
	add_child(trap)
	var world_pos := cell_to_world(col, row)
	trap.position = Vector3(world_pos.x, 0.0, world_pos.z)
	var key := "%d,%d" % [col, row]
	_trap_nodes[key] = trap
	trap.expired.connect(_on_trap_expired)
	trap_changed.emit()
	AudioManager.play_sfx_path("res://assets/audio/sfx_place.ogg", -4.0)

func _on_trap_expired(trap: Node) -> void:
	for key in _trap_nodes.keys():
		if _trap_nodes[key] == trap:
			_trap_nodes.erase(key)
			trap_changed.emit()
			break

func get_trap_counts() -> Dictionary:
	# Returns {display_name: {"count": int, "color": Color, "model_path": String, "texture_path": String}}
	var counts := {}
	for trap_node in _trap_nodes.values():
		var data: TrapData = trap_node.get("data")
		if data:
			var n: String = data.display_name
			if not counts.has(n):
				counts[n] = {"count": 0, "color": data.icon_color, "model_path": data.model_path, "texture_path": data.texture_path}
			counts[n]["count"] += 1
	return counts

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
			# Gold Mine income: award bonus coins for each Gold Mine trap
			var mine_income := 0
			for trap_node in _trap_nodes.values():
				if is_instance_valid(trap_node):
					var td: TrapData = trap_node.get("data")
					if td and td.income_per_round > 0:
						mine_income += td.income_per_round
			if mine_income > 0:
				EconomyManager.add_coins(player_index, mine_income)
		GameManager.GameState.PLAY:
			_cursor.visible = false
			# Final bake at play start so mobs have an up-to-date nav mesh
			_pathfinding.bake_async()
