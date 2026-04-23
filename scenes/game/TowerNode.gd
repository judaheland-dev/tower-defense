extends Node3D

## TowerNode - a placed tower or wall. Handles auto-targeting and firing.

var data: TowerData = null
var field_player_index: int = 0  # used to determine which mob layer to target

var _current_hp: float = 0.0
var _attack_timer: float = 0.0
var _target: Node = null
var _detection_area: Area3D = null
var _mobs_in_range: Array[Node] = []
var _slow_area: Area3D = null  # for SLOW type towers

# Applied debuffs from nearby mobs (fraction reduction to attack_speed)
var _attack_slow_debuff: float = 0.0

func _ready() -> void:
	if data == null:
		return
	_current_hp = data.max_health
	_build_model()
	_build_collision_body()
	if data.tower_type != TowerData.TowerType.WALL:
		_build_detection_area()
	if data.tower_type == TowerData.TowerType.SLOW:
		_build_slow_area()

func _build_model() -> void:
	# Always add a placeholder box
	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.6, 1.2 if data.tower_type != TowerData.TowerType.WALL else 1.8, 1.6)
	mesh_inst.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _placeholder_color()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_inst.set_surface_override_material(0, mat)
	mesh_inst.position = Vector3(0.0, box.size.y * 0.5, 0.0)
	add_child(mesh_inst)

	if ResourceLoader.exists(data.model_path):
		var scene: PackedScene = load(data.model_path)
		var inst := scene.instantiate()
		inst.scale = Vector3.ONE * data.model_scale
		add_child(inst)
		if _has_mesh_instance(inst):
			mesh_inst.visible = false  # GLB loaded with geometry - hide placeholder

func _has_mesh_instance(node: Node) -> bool:
	if node is MeshInstance3D:
		return true
	for child in node.get_children():
		if _has_mesh_instance(child):
			return true
	return false

func _build_collision_body() -> void:
	# Collision body: layer 1 = terrain (blocks nav mesh), layer 2 = tower (mob targeting)
	var body := StaticBody3D.new()
	var cshape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(1.8, 1.5, 1.8)
	cshape.shape = box_shape
	body.add_child(cshape)
	body.collision_layer = 1 | 2
	add_child(body)

func _placeholder_color() -> Color:
	match data.tower_type:
		TowerData.TowerType.WALL:   return Color(0.55, 0.5, 0.45)
		TowerData.TowerType.ARROW:  return Color(0.5, 0.8, 0.3)
		TowerData.TowerType.CANNON: return Color(0.3, 0.3, 0.7)
		TowerData.TowerType.SLOW:   return Color(0.4, 0.8, 0.9)
		TowerData.TowerType.SNIPER: return Color(0.9, 0.6, 0.1)
	return Color.WHITE

func _build_detection_area() -> void:
	_detection_area = Area3D.new()
	_detection_area.collision_layer = 0
	# Layer 3 (P1 field mobs) = bitmask 4, layer 4 (P2 field mobs) = bitmask 8
	_detection_area.collision_mask = 4 if field_player_index == 0 else 8

	var cshape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = data.range_units
	cshape.shape = sphere
	_detection_area.add_child(cshape)
	_detection_area.body_entered.connect(_on_mob_entered)
	_detection_area.body_exited.connect(_on_mob_exited)
	add_child(_detection_area)

func _build_slow_area() -> void:
	_slow_area = Area3D.new()
	_slow_area.collision_layer = 0
	# Layer 3 (P1 field mobs) = bitmask 4, layer 4 (P2 field mobs) = bitmask 8
	_slow_area.collision_mask = 4 if field_player_index == 0 else 8

	var cshape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = data.splash_radius  # splash_radius doubles as slow radius
	cshape.shape = sphere
	_slow_area.add_child(cshape)
	_slow_area.body_entered.connect(_on_slow_mob_entered)
	_slow_area.body_exited.connect(_on_slow_mob_exited)
	add_child(_slow_area)

# ---------- process ----------

func _process(delta: float) -> void:
	if data == null or data.tower_type == TowerData.TowerType.WALL:
		return
	if GameManager.current_state != GameManager.GameState.PLAY:
		return

	_attack_timer -= delta
	var effective_speed := data.attack_speed * (1.0 - _attack_slow_debuff)
	if effective_speed <= 0.0:
		return

	if _attack_timer <= 0.0:
		_pick_target()
		if _target != null and is_instance_valid(_target):
			_fire_at(_target)
			_attack_timer = 1.0 / effective_speed
		else:
			_attack_timer = 0.0

func _pick_target() -> void:
	# Remove dead/freed mobs from list
	var valid: Array[Node] = []
	for m in _mobs_in_range:
		if is_instance_valid(m) and not m.is_queued_for_deletion():
			valid.append(m)
	_mobs_in_range = valid

	if _mobs_in_range.is_empty():
		_target = null
		return

	# Target the mob that has traveled furthest (closest to exit by path progress)
	var best: Node = null
	var best_progress: float = -1.0
	for m in _mobs_in_range:
		var progress: float = m.get("path_progress") if m.get("path_progress") != null else 0.0
		if progress > best_progress:
			best_progress = progress
			best = m
	_target = best

func _fire_at(target: Node) -> void:
	if data.tower_type == TowerData.TowerType.CANNON:
		_launch_projectile(target, Color(0.9, 0.5, 0.1), 0.8, data.splash_radius)
		_play_fire_sfx("res://assets/audio/sfx_cannon.ogg")
	elif data.tower_type == TowerData.TowerType.SNIPER:
		_launch_projectile(target, Color(0.9, 0.9, 0.2), 0.6, 0.0)
		_play_fire_sfx("res://assets/audio/sfx_shoot.ogg")
	elif data.tower_type == TowerData.TowerType.SLOW:
		# Slow is applied via Area3D continuously; just fire a visual projectile
		_launch_projectile(target, Color(0.3, 0.8, 1.0), 0.7, 0.0)
	else:
		# ARROW and others
		_launch_projectile(target, Color(0.6, 0.9, 0.3), 1.1, 0.0)
		_play_fire_sfx("res://assets/audio/sfx_shoot.ogg")

func _launch_projectile(target: Node, col: Color, spd_mult: float, splash: float) -> void:
	var proj: Node = load("res://scenes/game/ProjectileNode.gd").new()
	proj.damage = data.damage
	proj.splash_radius = splash
	proj.field_player_index = field_player_index
	proj.target = target
	proj.speed = 14.0 * spd_mult
	proj.color = col
	proj.scale_factor = 1.0 if data.tower_type != TowerData.TowerType.CANNON else 1.6
	get_parent().add_child(proj)
	proj.global_position = global_position + Vector3(0.0, 1.2, 0.0)

func _play_fire_sfx(path: String) -> void:
	AudioManager.play_sfx_path(path, -6.0)

func _splash_attack(center: Vector3) -> void:
	for m in _mobs_in_range:
		if is_instance_valid(m) and not m.is_queued_for_deletion():
			if m.global_position.distance_to(center) <= data.splash_radius:
				_apply_damage_to(m, data.damage)

func _apply_damage_to(mob: Node, amount: float) -> void:
	if mob.has_method("take_damage"):
		mob.call("take_damage", amount)

# ---------- signals ----------

func _on_mob_entered(body: Node) -> void:
	if not _mobs_in_range.has(body):
		_mobs_in_range.append(body)

func _on_mob_exited(body: Node) -> void:
	_mobs_in_range.erase(body)
	if _target == body:
		_target = null

func _on_slow_mob_entered(body: Node) -> void:
	if body.has_method("apply_slow"):
		body.call("apply_slow", data.slow_amount)

func _on_slow_mob_exited(body: Node) -> void:
	if body.has_method("remove_slow"):
		body.call("remove_slow", data.slow_amount)

# ---------- damage (walls can be destroyed) ----------

func take_damage(amount: float) -> void:
	_current_hp -= amount
	if _current_hp <= 0.0:
		_on_destroyed()

func _on_destroyed() -> void:
	var parent := get_parent()
	if parent and parent.has_method("on_tower_destroyed"):
		parent.call("on_tower_destroyed", self)
	AudioManager.play_sfx_path("res://assets/audio/sfx_explosion.ogg", -3.0)
	queue_free()

func apply_attack_slow(amount: float) -> void:
	_attack_slow_debuff = minf(_attack_slow_debuff + amount, 0.9)

func remove_attack_slow(amount: float) -> void:
	_attack_slow_debuff = maxf(_attack_slow_debuff - amount, 0.0)
