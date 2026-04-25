extends CharacterBody3D

## MobNode - a mob that navigates from spawn to exit through the player's maze.

var data: MobData = null
var field_player_index: int = 0
var nav_map: RID
var exit_position: Vector3

var _current_hp: float = 0.0
var _base_speed: float = 0.0
var _slow_stacks: float = 0.0      # total slow fraction applied by towers
var _speed_buff: float = 0.0       # buff from nearby healer/buffer mobs
var _armor_buff: float = 0.0

# Trap effects (separate from tower slow so they stack multiplicatively)
var _trap_slow: float = 0.0        # total trap-based slow fraction
var _damage_amplify: float = 0.0   # extra damage multiplier from amplifier traps
var _heal_reduction: float = 0.0   # fraction reduction to incoming heals

var _nav_agent: NavigationAgent3D = null
var _aura_area: Area3D = null       # for healer/buffer mobs emitting auras
var _debuff_area: Area3D = null     # for mobs that debuff towers
var _attack_area: Area3D = null      # for mobs that attack defenses
var _allies_in_range: Array[Node] = []
var _towers_in_debuff_range: Array[Node] = []
var _defenses_in_range: Array[Node] = []  # TowerNode refs detected by _attack_area
var _attack_target: Node = null
var _attack_cooldown: float = 0.0
var _is_attacking: bool = false

# Path progress (0-1): how far along the path the mob has traveled, used by towers for targeting priority
var path_progress: float = 0.0
var _total_path_length: float = 0.0
var _distance_traveled: float = 0.0

# --- Animation state ---
var _visual_root: Node3D = null
var _dust_particles: GPUParticles3D = null
var _bob_time: float = 0.0
var _dying: bool = false
var _prev_direction: Vector3 = Vector3.ZERO
var _healer_pulse_time: float = 0.0

# --- Soft separation ---
const SEPARATION_RADIUS: float = 0.6
const SEPARATION_STRENGTH: float = 2.5
var _separation_area: Area3D = null
var _nearby_mobs: Array[Node] = []

# Damage-over-time timers (from Poison towers)
var _dot_timers: Array[Dictionary] = []

signal reached_exit(mob: Node)
signal died(mob: Node)

func _ready() -> void:
	if data == null:
		return
	_current_hp = data.max_health
	_base_speed = data.move_speed

	_build_collision()
	_build_visual_root()
	_build_shadow()
	_build_model()
	_build_dust_particles()
	_build_nav_agent()
	_build_separation_area()

	if data.heals_nearby_allies or data.buffs_nearby_allies:
		_build_aura_area()
	if data.debuffs_nearby_towers:
		_build_debuff_area()
	if data.attacks_defenses:
		_build_attack_area()

	# Spawn pop-in animation
	_visual_root.scale = Vector3.ZERO
	var tween := create_tween()
	tween.tween_property(_visual_root, "scale", Vector3.ONE, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

func _build_collision() -> void:
	# Layer 3 (P1 field mobs) = bitmask 4, layer 4 (P2 field mobs) = bitmask 8
	collision_layer = 4 if field_player_index == 0 else 8
	collision_mask = 1  # terrain/walls

	var cshape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.0
	cshape.shape = cap
	cshape.position = Vector3(0.0, 0.5, 0.0)
	add_child(cshape)

func _build_visual_root() -> void:
	_visual_root = Node3D.new()
	_visual_root.name = "VisualRoot"
	add_child(_visual_root)

func _build_shadow() -> void:
	var shadow := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(0.7, 0.7)
	shadow.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.0, 0.0, 0.0, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	shadow.set_surface_override_material(0, mat)
	shadow.position = Vector3(0.0, 0.02, 0.0)
	# Shadow stays on ground - parent to self, not _visual_root
	add_child(shadow)

func _build_model() -> void:
	# Always add a colored capsule so the mob is always visible
	var mesh_inst := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.3
	cap.height = 1.0
	mesh_inst.mesh = cap
	mesh_inst.position = Vector3(0.0, 0.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _placeholder_color()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_inst.set_surface_override_material(0, mat)
	_visual_root.add_child(mesh_inst)

	if ResourceLoader.exists(data.model_path):
		var scene: PackedScene = load(data.model_path)
		var inst := scene.instantiate()
		inst.scale = Vector3.ONE * data.model_scale
		# Rotate 180 so the model's front faces Godot's -Z (node forward direction)
		inst.rotation_degrees.y = 180.0
		_visual_root.add_child(inst)
		if _has_mesh_instance(inst):
			mesh_inst.visible = false

func _build_dust_particles() -> void:
	if data.is_flying:
		return
	_dust_particles = GPUParticles3D.new()
	_dust_particles.emitting = false
	_dust_particles.amount = 6
	_dust_particles.lifetime = 0.4
	_dust_particles.explosiveness = 0.0
	_dust_particles.visibility_aabb = AABB(Vector3(-2, -1, -2), Vector3(4, 3, 4))
	var pmat := ParticleProcessMaterial.new()
	pmat.direction = Vector3(0.0, 1.0, 0.0)
	pmat.spread = 60.0
	pmat.initial_velocity_min = 0.3
	pmat.initial_velocity_max = 0.8
	pmat.gravity = Vector3(0.0, -2.0, 0.0)
	pmat.scale_min = 0.08
	pmat.scale_max = 0.15
	pmat.color = Color(0.6, 0.5, 0.35, 0.6)
	_dust_particles.process_material = pmat
	_dust_particles.draw_pass_1 = SphereMesh.new()
	_dust_particles.draw_pass_1.radius = 0.5
	_dust_particles.draw_pass_1.height = 1.0
	_dust_particles.position = Vector3(0.0, 0.05, 0.0)
	add_child(_dust_particles)

func _build_separation_area() -> void:
	_separation_area = Area3D.new()
	_separation_area.collision_layer = 0
	# Detect mobs on the same field
	_separation_area.collision_mask = 4 if field_player_index == 0 else 8
	var cshape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = SEPARATION_RADIUS
	cshape.shape = sphere
	_separation_area.add_child(cshape)
	_separation_area.body_entered.connect(_on_separation_entered)
	_separation_area.body_exited.connect(_on_separation_exited)
	add_child(_separation_area)

func _has_mesh_instance(node: Node) -> bool:
	if node is MeshInstance3D:
		return true
	for child in node.get_children():
		if _has_mesh_instance(child):
			return true
	return false

func _placeholder_color() -> Color:
	if data.is_flying:        return Color(0.6, 0.4, 0.9)
	if data.attacks_defenses: return Color(0.9, 0.3, 0.3)
	if data.heals_nearby_allies: return Color(0.3, 0.9, 0.5)
	return Color(0.8, 0.7, 0.3)

func _build_nav_agent() -> void:
	_nav_agent = NavigationAgent3D.new()
	_nav_agent.path_desired_distance = 0.4
	_nav_agent.target_desired_distance = 0.8
	add_child(_nav_agent)
	_nav_agent.set_navigation_map(nav_map)
	_nav_agent.target_position = exit_position

func _build_aura_area() -> void:
	_aura_area = Area3D.new()
	_aura_area.collision_layer = 0
	# Detect other mobs on the same field: layer 3 = mask 4, layer 4 = mask 8
	_aura_area.collision_mask = 4 if field_player_index == 0 else 8

	var cshape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = maxf(data.heal_radius, data.buff_radius)
	cshape.shape = sphere
	_aura_area.add_child(cshape)
	_aura_area.body_entered.connect(_on_ally_entered)
	_aura_area.body_exited.connect(_on_ally_exited)
	add_child(_aura_area)

func _build_debuff_area() -> void:
	_debuff_area = Area3D.new()
	_debuff_area.collision_layer = 0
	_debuff_area.collision_mask = 2  # tower layer

	var cshape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = data.debuff_radius
	cshape.shape = sphere
	_debuff_area.add_child(cshape)
	_debuff_area.body_entered.connect(_on_tower_debuff_entered)
	_debuff_area.body_exited.connect(_on_tower_debuff_exited)
	add_child(_debuff_area)

func _build_attack_area() -> void:
	_attack_area = Area3D.new()
	_attack_area.collision_layer = 0
	_attack_area.collision_mask = 2  # tower/wall StaticBody3D layer

	var cshape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = data.defense_attack_range
	cshape.shape = sphere
	_attack_area.add_child(cshape)
	_attack_area.body_entered.connect(_on_defense_entered)
	_attack_area.body_exited.connect(_on_defense_exited)
	add_child(_attack_area)

func _pick_attack_target() -> Node:
	# Clean up invalid refs
	var valid: Array[Node] = []
	for d in _defenses_in_range:
		if is_instance_valid(d) and not d.is_queued_for_deletion():
			valid.append(d)
	_defenses_in_range = valid

	if _defenses_in_range.is_empty():
		return null

	# Separate into towers and walls
	var towers: Array[Node] = []
	var walls: Array[Node] = []
	for d in _defenses_in_range:
		var d_data: Variant = d.get("data")
		if d_data == null:
			continue
		if d_data.tower_type == TowerData.TowerType.WALL:
			walls.append(d)
		else:
			towers.append(d)

	# Priority: towers first (or walls first if prefers_walls)
	var primary: Array[Node] = walls if data.prefers_walls else towers
	var secondary: Array[Node] = towers if data.prefers_walls else walls

	var best: Node = null
	var best_dist: float = INF
	for d in primary:
		var dist := global_position.distance_to(d.global_position)
		if dist < best_dist:
			best_dist = dist
			best = d
	if best != null:
		return best

	# Fallback to secondary group
	for d in secondary:
		var dist := global_position.distance_to(d.global_position)
		if dist < best_dist:
			best_dist = dist
			best = d
	return best

# ---------- process ----------

func _physics_process(delta: float) -> void:
	if _dying:
		return
	if GameManager.current_state != GameManager.GameState.PLAY:
		return
	if _nav_agent == null:
		return

	# --- Attack defenses ---
	if data.attacks_defenses:
		_attack_cooldown -= delta
		var target := _pick_attack_target()
		if target != null:
			_attack_target = target
			_is_attacking = true
			# Face target
			var dir_to_target: Vector3 = (target.global_position - global_position).normalized()
			if dir_to_target.length() > 0.1:
				look_at(global_position + dir_to_target, Vector3.UP)
			# Attack on cooldown
			if _attack_cooldown <= 0.0:
				target.call("take_damage", data.defense_attack_damage)
				_attack_cooldown = 1.0 / maxf(data.defense_attack_speed, 0.1)
				AudioManager.play_sfx_path("res://assets/audio/sfx_impact.ogg", -8.0)
				# Attack lunge animation
				if _visual_root and not _dying:
					var punch := create_tween()
					punch.tween_property(_visual_root, "scale", Vector3(1.2, 0.85, 1.2), 0.08)
					punch.tween_property(_visual_root, "scale", Vector3.ONE, 0.12)
			# Stop moving while attacking
			if _dust_particles:
				_dust_particles.emitting = false
			return
		else:
			_is_attacking = false
			_attack_target = null

	# Heal nearby allies
	if data.heals_nearby_allies and data.heal_rate > 0.0:
		for ally in _allies_in_range:
			if is_instance_valid(ally) and ally != self:
				if ally.has_method("receive_heal"):
					ally.call("receive_heal", data.heal_rate * delta)

	# Tick DoT timers (damage bypasses armor)
	if not _dot_timers.is_empty():
		var i := _dot_timers.size() - 1
		while i >= 0:
			var dot: Dictionary = _dot_timers[i]
			dot["remaining"] -= delta
			_current_hp -= dot["dps"] * delta
			if dot["remaining"] <= 0.0:
				var hr: float = dot.get("heal_reduction", 0.0)
				if hr > 0.0:
					remove_heal_reduction(hr)
				_dot_timers.remove_at(i)
			i -= 1
		if _current_hp <= 0.0 and not _dying:
			_play_death()
			return

	# Reached exit check: nav agent finished OR mob is physically close to exit
	var at_exit := global_position.distance_to(exit_position) < 1.5
	if ((_nav_agent.is_navigation_finished() and _distance_traveled > 1.0) or at_exit):
		AudioManager.play_sfx_path("res://assets/audio/sfx_impact.ogg", -2.0)
		reached_exit.emit(self)
		queue_free()
		return

	var next_pos: Vector3 = _nav_agent.get_next_path_position()
	# Fallback: if nav agent isn't giving us a useful next position, move directly to exit
	var to_next := (next_pos - global_position)
	if to_next.length() < 0.1:
		next_pos = exit_position
	var direction := (next_pos - global_position).normalized()
	var effective_speed := (_base_speed + _speed_buff) * (1.0 - _slow_stacks) * (1.0 - _trap_slow)
	effective_speed = maxf(effective_speed, 0.2)  # never fully stopped

	# Compute soft separation force from nearby mobs
	var separation := _compute_separation()

	if data.is_flying:
		# Flying mobs ignore nav mesh - move directly toward exit
		direction = (exit_position - global_position).normalized()
		var fly_vel := direction * effective_speed + separation
		global_position += fly_vel * delta
		_animate_flying(delta, effective_speed)
		if global_position.distance_to(exit_position) < 1.0:
			reached_exit.emit(self)
			queue_free()
		return

	velocity = direction * effective_speed + separation
	move_and_slide()

	# Track path progress for targeting priority
	_distance_traveled += effective_speed * delta
	if _total_path_length > 0.0:
		path_progress = _distance_traveled / _total_path_length
	else:
		# Estimate using distance to exit
		var dist_to_exit := global_position.distance_to(exit_position)
		path_progress = 1.0 - (dist_to_exit / 50.0)

	# Face movement direction
	if velocity.length() > 0.1:
		look_at(global_position + velocity.normalized(), Vector3.UP)

	_animate_ground(delta, effective_speed, direction)

# ---------- procedural animation ----------

func _animate_ground(delta: float, speed: float, direction: Vector3) -> void:
	var moving := velocity.length() > 0.1

	# Bobbing
	if moving:
		var bob_freq := 6.0 + speed * 1.2
		_bob_time += delta * bob_freq
		var bob_val := sin(_bob_time)
		var bob_amp := 0.1
		_visual_root.position.y = bob_val * bob_amp

		# Squash & stretch synced to bob
		var squash := 1.0 - bob_val * 0.08
		var stretch := 1.0 + bob_val * 0.04
		_visual_root.scale = Vector3(stretch, squash, stretch)
	else:
		_visual_root.position.y = lerpf(_visual_root.position.y, 0.0, delta * 8.0)
		_visual_root.scale = _visual_root.scale.lerp(Vector3.ONE, delta * 8.0)
		_bob_time = 0.0

	# Tilt into movement direction changes
	var target_tilt := 0.0
	if moving and _prev_direction.length() > 0.1:
		var dir_change := direction - _prev_direction
		if dir_change.length() > 0.01:
			target_tilt = clampf(dir_change.dot(basis.z) * 15.0, -10.0, 10.0)
	_visual_root.rotation_degrees.x = lerpf(_visual_root.rotation_degrees.x, target_tilt, delta * 6.0)
	_prev_direction = direction

	# Dust particles
	if _dust_particles:
		_dust_particles.emitting = moving

	# Healer pulse
	if data.heals_nearby_allies:
		_animate_healer_pulse(delta)

func _animate_flying(delta: float, speed: float) -> void:
	# Floating hover - slow, large amplitude bob
	_bob_time += delta * 2.5
	var hover_y := sin(_bob_time) * 0.3 + 0.8  # hover above ground
	_visual_root.position.y = hover_y

	# Gentle sway
	_visual_root.rotation_degrees.z = sin(_bob_time * 0.7) * 5.0
	_visual_root.rotation_degrees.x = cos(_bob_time * 0.5) * 3.0

	# No squash/stretch for flying mobs
	_visual_root.scale = Vector3.ONE

	# Face movement
	var dir := (exit_position - global_position).normalized()
	if dir.length() > 0.1:
		look_at(global_position + dir, Vector3.UP)

	# Healer pulse
	if data.heals_nearby_allies:
		_animate_healer_pulse(delta)

func _animate_healer_pulse(delta: float) -> void:
	_healer_pulse_time += delta * TAU  # full cycle per second
	var pulse := 1.0 + sin(_healer_pulse_time) * 0.05
	_visual_root.scale *= pulse

# ---------- separation ----------

func _compute_separation() -> Vector3:
	var push := Vector3.ZERO
	for other in _nearby_mobs:
		if not is_instance_valid(other) or other == self:
			continue
		var other_pos: Vector3 = other.global_position
		var diff := global_position - other_pos
		diff.y = 0.0
		var dist := diff.length()
		if dist < 0.01:
			# Nearly overlapping - push in a random-ish direction
			diff = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)).normalized()
			dist = 0.01
		if dist < SEPARATION_RADIUS:
			var strength := (SEPARATION_RADIUS - dist) / SEPARATION_RADIUS
			push += diff.normalized() * strength * SEPARATION_STRENGTH
	return push

func _on_separation_entered(body: Node) -> void:
	if body != self and not _nearby_mobs.has(body):
		_nearby_mobs.append(body)

func _on_separation_exited(body: Node) -> void:
	_nearby_mobs.erase(body)

# ---------- combat ----------

func take_damage(amount: float) -> void:
	if _dying:
		return
	var actual := maxf((amount * (1.0 + _damage_amplify)) - (data.armor + _armor_buff), 1.0)
	_current_hp -= actual

	# Damage flash: brief scale punch
	if _visual_root and not _dying:
		var punch := create_tween()
		punch.tween_property(_visual_root, "scale", Vector3.ONE * 1.15, 0.05)
		punch.tween_property(_visual_root, "scale", Vector3.ONE, 0.08)

	if _current_hp <= 0.0:
		_play_death()

func _play_death() -> void:
	if _dying:
		return
	_dying = true
	AudioManager.play_sfx_path("res://assets/audio/sfx_death.ogg", -8.0)
	died.emit(self)
	# Disable collision so mob doesn't block anything during death anim
	collision_layer = 0
	collision_mask = 0
	if _dust_particles:
		_dust_particles.emitting = false
	# Death tween: shrink + spin
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_visual_root, "scale", Vector3.ZERO, 0.3).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tween.tween_property(_visual_root, "rotation_degrees:y", _visual_root.rotation_degrees.y + 360.0, 0.3)
	tween.tween_property(_visual_root, "position:y", _visual_root.position.y + 0.5, 0.15)
	tween.chain().tween_callback(queue_free)

func receive_heal(amount: float) -> void:
	_current_hp = minf(_current_hp + amount * (1.0 - _heal_reduction), data.max_health)

func apply_dot(dps: float, duration: float, hr: float = 0.0) -> void:
	_dot_timers.append({"dps": dps, "remaining": duration, "heal_reduction": hr})
	if hr > 0.0:
		apply_heal_reduction(hr)

# ---------- slow/buff ----------

func apply_slow(fraction: float) -> void:
	_slow_stacks = minf(_slow_stacks + fraction, 0.9)

func remove_slow(fraction: float) -> void:
	_slow_stacks = maxf(_slow_stacks - fraction, 0.0)

# ---------- trap effects ----------

func apply_trap_slow(amount: float) -> void:
	_trap_slow = minf(_trap_slow + amount, 0.9)

func remove_trap_slow(amount: float) -> void:
	_trap_slow = maxf(_trap_slow - amount, 0.0)

func apply_damage_amplify(amount: float) -> void:
	_damage_amplify += amount

func remove_damage_amplify(amount: float) -> void:
	_damage_amplify = maxf(_damage_amplify - amount, 0.0)

func apply_heal_reduction(amount: float) -> void:
	_heal_reduction = minf(_heal_reduction + amount, 1.0)

func remove_heal_reduction(amount: float) -> void:
	_heal_reduction = maxf(_heal_reduction - amount, 0.0)

# ---------- aura signals ----------

func _on_ally_entered(body: Node) -> void:
	if body == self:
		return
	if not _allies_in_range.has(body):
		_allies_in_range.append(body)
	if data.buffs_nearby_allies:
		if body.has_method("receive_speed_buff"):
			body.call("receive_speed_buff", data.buff_speed_bonus)
		if body.has_method("receive_armor_buff"):
			body.call("receive_armor_buff", data.buff_armor_bonus)

func _on_ally_exited(body: Node) -> void:
	_allies_in_range.erase(body)
	if data.buffs_nearby_allies:
		if body.has_method("remove_speed_buff"):
			body.call("remove_speed_buff", data.buff_speed_bonus)
		if body.has_method("remove_armor_buff"):
			body.call("remove_armor_buff", data.buff_armor_bonus)

func receive_speed_buff(amount: float) -> void:
	_speed_buff += amount

func remove_speed_buff(amount: float) -> void:
	_speed_buff = maxf(_speed_buff - amount, 0.0)

func receive_armor_buff(amount: float) -> void:
	_armor_buff += amount

func remove_armor_buff(amount: float) -> void:
	_armor_buff = maxf(_armor_buff - amount, 0.0)

# ---------- tower debuff signals ----------

func _on_tower_debuff_entered(body: Node) -> void:
	# Only debuff towers on the same field we were sent to attack
	if body.get_parent() != null and body.get_parent().get("field_player_index") != field_player_index:
		return
	if not _towers_in_debuff_range.has(body):
		_towers_in_debuff_range.append(body)
		if body.has_method("apply_attack_slow"):
			body.call("apply_attack_slow", data.debuff_attack_slow)

func _on_tower_debuff_exited(body: Node) -> void:
	_towers_in_debuff_range.erase(body)
	if body.has_method("remove_attack_slow"):
		body.call("remove_attack_slow", data.debuff_attack_slow)

# ---------- defense attack signals ----------

func _on_defense_entered(body: Node) -> void:
	# body is the StaticBody3D child of TowerNode; get the TowerNode parent
	var tower := body.get_parent()
	if tower == null:
		return
	if not tower.has_method("take_damage"):
		return
	# Only attack towers on the same field (the opponent's field we were sent to)
	if tower.get("field_player_index") != field_player_index:
		return
	if not _defenses_in_range.has(tower):
		_defenses_in_range.append(tower)

func _on_defense_exited(body: Node) -> void:
	var tower := body.get_parent()
	if tower == null:
		return
	_defenses_in_range.erase(tower)
	if _attack_target == tower:
		_attack_target = null
