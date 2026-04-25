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

# Buff aura received from nearby BUFF towers
var _damage_buff: float = 0.0
var _attack_speed_buff: float = 0.0

# Mortar ground indicator
var _mortar_decal: MeshInstance3D = null

# Health bar (visible when damaged)
var _hp_bar_bg: MeshInstance3D = null
var _hp_bar_fill: MeshInstance3D = null
var _model_root: Node3D = null  # for hit reaction animation

func _ready() -> void:
	if data == null:
		return
	_current_hp = data.max_health
	_build_model()
	_build_collision_body()
	var skip_detection := data.tower_type == TowerData.TowerType.WALL or data.tower_type == TowerData.TowerType.BUFF
	if not skip_detection:
		_build_detection_area()
	if data.tower_type == TowerData.TowerType.SLOW:
		_build_slow_area()
	if data.tower_type == TowerData.TowerType.BUFF:
		_build_buff_aura()
	if data.tower_type == TowerData.TowerType.MORTAR:
		_build_mortar_decal()
	_build_health_bar()

func _build_model() -> void:
	_model_root = Node3D.new()
	_model_root.name = "ModelRoot"
	add_child(_model_root)

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
	_model_root.add_child(mesh_inst)

	if ResourceLoader.exists(data.model_path):
		var scene: PackedScene = load(data.model_path)
		var inst := scene.instantiate()
		inst.scale = Vector3.ONE * data.model_scale
		_model_root.add_child(inst)
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
		TowerData.TowerType.TESLA:  return Color(0.3, 0.5, 1.0)
		TowerData.TowerType.MORTAR: return Color(0.6, 0.4, 0.2)
		TowerData.TowerType.BUFF:   return Color(1.0, 0.85, 0.2)
		TowerData.TowerType.POISON: return Color(0.2, 0.8, 0.2)
		TowerData.TowerType.ANTI_AIR: return Color(0.8, 0.2, 0.2)
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
	if data == null or data.tower_type == TowerData.TowerType.WALL or data.tower_type == TowerData.TowerType.BUFF:
		return
	if GameManager.current_state != GameManager.GameState.PLAY:
		return

	# Update mortar ground indicator
	if data.tower_type == TowerData.TowerType.MORTAR and _mortar_decal:
		_pick_target()
		if _target != null and is_instance_valid(_target):
			var predicted := _predict_impact_pos(_target)
			_mortar_decal.global_position = Vector3(predicted.x, 0.05, predicted.z)
			_mortar_decal.visible = true
		else:
			_mortar_decal.visible = false

	_attack_timer -= delta
	var effective_speed := data.attack_speed * (1.0 + _attack_speed_buff) * (1.0 - _attack_slow_debuff)
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

	# Target the mob that has traveled furthest (closest to exit by path progress),
	# excluding mobs inside the minimum engagement range.
	var best: Node = null
	var best_progress: float = -1.0
	var min_r: float = data.min_range_units
	for m in _mobs_in_range:
		if min_r > 0.0 and global_position.distance_to(m.global_position) < min_r:
			continue
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
	elif data.tower_type == TowerData.TowerType.TESLA:
		_launch_projectile(target, Color(0.3, 0.6, 1.0), 1.3, 0.0)
		_play_fire_sfx("res://assets/audio/sfx_shoot.ogg")
	elif data.tower_type == TowerData.TowerType.MORTAR:
		_launch_projectile(target, Color(0.7, 0.4, 0.1), 0.5, data.splash_radius)
		_play_fire_sfx("res://assets/audio/sfx_cannon.ogg")
		if _mortar_decal:
			_mortar_decal.visible = false
	elif data.tower_type == TowerData.TowerType.POISON:
		_launch_projectile(target, Color(0.2, 0.9, 0.2), 0.9, 0.0)
		_play_fire_sfx("res://assets/audio/sfx_shoot.ogg")
	elif data.tower_type == TowerData.TowerType.ANTI_AIR:
		_launch_projectile(target, Color(0.9, 0.2, 0.2), 1.2, 0.0)
		_play_fire_sfx("res://assets/audio/sfx_shoot.ogg")
	else:
		# ARROW and others
		_launch_projectile(target, Color(0.6, 0.9, 0.3), 1.1, 0.0)
		_play_fire_sfx("res://assets/audio/sfx_shoot.ogg")

func _launch_projectile(target: Node, col: Color, spd_mult: float, splash: float) -> void:
	var proj: Node = load("res://scenes/game/ProjectileNode.gd").new()
	proj.damage = data.damage + _damage_buff
	proj.splash_radius = splash
	proj.field_player_index = field_player_index
	proj.target = target
	proj.speed = 14.0 * spd_mult
	proj.color = col
	proj.scale_factor = 1.0 if data.tower_type != TowerData.TowerType.CANNON else 1.6
	# Chain lightning properties (Tesla)
	if data.tower_type == TowerData.TowerType.TESLA:
		proj.chain_count = data.chain_count
		proj.chain_range = data.chain_range
		proj.chain_damage_falloff = data.chain_damage_falloff
	# DoT properties (Poison)
	if data.tower_type == TowerData.TowerType.POISON:
		proj.dot_damage = data.dot_damage
		proj.dot_duration = data.dot_duration
		proj.heal_reduction = data.heal_reduction
	# Mortar flag
	if data.tower_type == TowerData.TowerType.MORTAR:
		proj.is_mortar = true
	# Anti-air damage multiplier
	if data.tower_type == TowerData.TowerType.ANTI_AIR:
		var mob_data: Variant = target.get("data") if target != null else null
		if mob_data != null and mob_data.get("is_flying") == true:
			proj.damage *= data.flying_damage_multiplier
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
	_update_health_bar()
	# Hit reaction: scale punch
	if _model_root and _current_hp > 0.0:
		var punch := create_tween()
		punch.tween_property(_model_root, "scale", Vector3(1.1, 0.9, 1.1), 0.06)
		punch.tween_property(_model_root, "scale", Vector3.ONE, 0.1)
	if _current_hp <= 0.0:
		_on_destroyed()

func _on_destroyed() -> void:
	var parent := get_parent()
	if parent and parent.has_method("on_tower_destroyed"):
		parent.call("on_tower_destroyed", self)
	AudioManager.play_sfx_path("res://assets/audio/sfx_explosion.ogg", -3.0)
	queue_free()

func get_hp_fraction() -> float:
	if data == null or data.max_health <= 0.0:
		return 1.0
	return clampf(_current_hp / data.max_health, 0.0, 1.0)

# ---------- upgrade ----------

func upgrade(new_data: TowerData) -> void:
	var old_type := data.tower_type
	data = new_data
	_current_hp = data.max_health

	# Rebuild model
	if _model_root:
		_model_root.queue_free()
		_model_root = null
	_build_model()

	# Rebuild detection area if needed
	if _detection_area:
		_detection_area.queue_free()
		_detection_area = null
		_mobs_in_range.clear()
	if _slow_area:
		_slow_area.queue_free()
		_slow_area = null

	var skip_detection := data.tower_type == TowerData.TowerType.WALL or data.tower_type == TowerData.TowerType.BUFF
	if not skip_detection:
		_build_detection_area()
	if data.tower_type == TowerData.TowerType.SLOW:
		_build_slow_area()

	# Rebuild health bar
	if _hp_bar_bg:
		_hp_bar_bg.queue_free()
		_hp_bar_bg = null
	if _hp_bar_fill:
		_hp_bar_fill.queue_free()
		_hp_bar_fill = null
	_build_health_bar()

	# Reset attack timer
	_attack_timer = 0.0
	_target = null

	# Visual feedback: scale pop
	if _model_root:
		_model_root.scale = Vector3(1.3, 0.7, 1.3)
		var tween := create_tween()
		tween.tween_property(_model_root, "scale", Vector3.ONE, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)

# ---------- health bar ----------

func _build_health_bar() -> void:
	var bar_y := 2.2 if data.tower_type != TowerData.TowerType.WALL else 2.5
	var bar_width := 1.2
	var bar_height := 0.12

	# Background (dark)
	_hp_bar_bg = MeshInstance3D.new()
	var bg_quad := QuadMesh.new()
	bg_quad.size = Vector2(bar_width, bar_height)
	_hp_bar_bg.mesh = bg_quad
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.15, 0.15, 0.15, 0.8)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.no_depth_test = true
	bg_mat.render_priority = 10
	_hp_bar_bg.set_surface_override_material(0, bg_mat)
	_hp_bar_bg.position = Vector3(0.0, bar_y, 0.0)
	_hp_bar_bg.visible = false
	add_child(_hp_bar_bg)

	# Fill (colored)
	_hp_bar_fill = MeshInstance3D.new()
	var fill_quad := QuadMesh.new()
	fill_quad.size = Vector2(bar_width - 0.04, bar_height - 0.04)
	_hp_bar_fill.mesh = fill_quad
	var fill_mat := StandardMaterial3D.new()
	fill_mat.albedo_color = Color(0.2, 0.9, 0.2)
	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_mat.no_depth_test = true
	fill_mat.render_priority = 11
	_hp_bar_fill.set_surface_override_material(0, fill_mat)
	_hp_bar_fill.position = Vector3(0.0, bar_y, 0.0)
	_hp_bar_fill.visible = false
	add_child(_hp_bar_fill)

func _update_health_bar() -> void:
	var frac := get_hp_fraction()
	var damaged := frac < 1.0 and _current_hp > 0.0
	if _hp_bar_bg:
		_hp_bar_bg.visible = damaged
	if _hp_bar_fill:
		_hp_bar_fill.visible = damaged
		if damaged:
			# Scale fill bar horizontally based on HP fraction
			_hp_bar_fill.scale.x = frac
			# Shift fill bar left so it drains from right
			var full_width := 1.16  # bar_width - 0.04
			_hp_bar_fill.position.x = -(1.0 - frac) * full_width * 0.5
			# Color: green -> yellow -> red
			var fill_mat: StandardMaterial3D = _hp_bar_fill.get_surface_override_material(0)
			if fill_mat:
				if frac > 0.5:
					fill_mat.albedo_color = Color(lerp(0.9, 0.2, (frac - 0.5) * 2.0), 0.9, 0.2)
				else:
					fill_mat.albedo_color = Color(0.9, lerp(0.2, 0.9, frac * 2.0), 0.2)

func apply_attack_slow(amount: float) -> void:
	_attack_slow_debuff = minf(_attack_slow_debuff + amount, 0.9)

func remove_attack_slow(amount: float) -> void:
	_attack_slow_debuff = maxf(_attack_slow_debuff - amount, 0.0)

# ---------- buff aura (BUFF tower type) ----------

func _build_buff_aura() -> void:
	var aura := Area3D.new()
	aura.collision_layer = 0
	aura.collision_mask = 2  # tower layer
	var cshape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = data.buff_radius
	cshape.shape = sphere
	aura.add_child(cshape)
	aura.body_entered.connect(_on_buff_target_entered)
	aura.body_exited.connect(_on_buff_target_exited)
	add_child(aura)

func _on_buff_target_entered(body: Node) -> void:
	# The StaticBody3D is a child of the TowerNode, so get the TowerNode parent
	var tower := body.get_parent()
	if tower == self or tower == null:
		return
	if tower.has_method("apply_tower_buff"):
		tower.call("apply_tower_buff", data.buff_damage_bonus, data.buff_attack_speed_bonus)

func _on_buff_target_exited(body: Node) -> void:
	var tower := body.get_parent()
	if tower == self or tower == null:
		return
	if tower.has_method("remove_tower_buff"):
		tower.call("remove_tower_buff", data.buff_damage_bonus, data.buff_attack_speed_bonus)

func apply_tower_buff(dmg_bonus: float, spd_bonus: float) -> void:
	_damage_buff += dmg_bonus
	_attack_speed_buff += spd_bonus

func remove_tower_buff(dmg_bonus: float, spd_bonus: float) -> void:
	_damage_buff = maxf(_damage_buff - dmg_bonus, 0.0)
	_attack_speed_buff = maxf(_attack_speed_buff - spd_bonus, 0.0)

# ---------- mortar ground indicator ----------

func _build_mortar_decal() -> void:
	_mortar_decal = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = data.splash_radius - 0.15
	torus.outer_radius = data.splash_radius
	_mortar_decal.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.3, 0.1, 0.4)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.3, 0.1)
	mat.emission_energy_multiplier = 0.8
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mortar_decal.set_surface_override_material(0, mat)
	_mortar_decal.rotation_degrees.x = 90.0
	_mortar_decal.visible = false
	# Parent to world so it shows at target position, not tower-local
	call_deferred("_attach_mortar_decal")

func _attach_mortar_decal() -> void:
	var world_parent := get_parent()
	if world_parent and _mortar_decal:
		world_parent.add_child(_mortar_decal)

func _predict_impact_pos(target: Node) -> Vector3:
	var target_pos: Vector3 = target.global_position
	var target_vel: Variant = target.get("velocity")
	if target_vel is Vector3 and (target_vel as Vector3).length() > 0.1:
		# Lead time based on projectile travel time
		var dist := global_position.distance_to(target_pos)
		var proj_speed := 14.0 * 0.5  # mortar speed multiplier
		var lead_time := dist / proj_speed if proj_speed > 0.0 else 0.0
		target_pos += (target_vel as Vector3) * lead_time * 0.5
	return target_pos
