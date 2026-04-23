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

var _nav_agent: NavigationAgent3D = null
var _aura_area: Area3D = null       # for healer/buffer mobs emitting auras
var _debuff_area: Area3D = null     # for mobs that debuff towers
var _allies_in_range: Array[Node] = []
var _towers_in_debuff_range: Array[Node] = []

# Path progress (0-1): how far along the path the mob has traveled, used by towers for targeting priority
var path_progress: float = 0.0
var _total_path_length: float = 0.0
var _distance_traveled: float = 0.0

signal reached_exit(mob: Node)
signal died(mob: Node)

func _ready() -> void:
	if data == null:
		return
	_current_hp = data.max_health
	_base_speed = data.move_speed

	_build_collision()
	_build_model()
	_build_nav_agent()

	if data.heals_nearby_allies or data.buffs_nearby_allies:
		_build_aura_area()
	if data.debuffs_nearby_towers:
		_build_debuff_area()

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
	add_child(mesh_inst)

	if ResourceLoader.exists(data.model_path):
		var scene: PackedScene = load(data.model_path)
		var inst := scene.instantiate()
		inst.scale = Vector3.ONE * data.model_scale
		# Rotate 180° so the model's front faces Godot's -Z (node forward direction)
		inst.rotation_degrees.y = 180.0
		add_child(inst)
		if _has_mesh_instance(inst):
			mesh_inst.visible = false

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

# ---------- process ----------

func _physics_process(delta: float) -> void:
	if GameManager.current_state != GameManager.GameState.PLAY:
		return
	if _nav_agent == null:
		return

	# Heal nearby allies
	if data.heals_nearby_allies and data.heal_rate > 0.0:
		for ally in _allies_in_range:
			if is_instance_valid(ally) and ally != self:
				if ally.has_method("receive_heal"):
					ally.call("receive_heal", data.heal_rate * delta)

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
	var effective_speed := (_base_speed + _speed_buff) * (1.0 - _slow_stacks)
	effective_speed = maxf(effective_speed, 0.2)  # never fully stopped

	if data.is_flying:
		# Flying mobs ignore nav mesh - move directly toward exit
		direction = (exit_position - global_position).normalized()
		global_position += direction * effective_speed * delta
		if global_position.distance_to(exit_position) < 1.0:
			reached_exit.emit(self)
			queue_free()
		return

	velocity = direction * effective_speed
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

# ---------- combat ----------

func take_damage(amount: float) -> void:
	var actual := maxf(amount - (data.armor + _armor_buff), 1.0)
	_current_hp -= actual
	if _current_hp <= 0.0:
		AudioManager.play_sfx_path("res://assets/audio/sfx_death.ogg", -8.0)
		died.emit(self)
		queue_free()

func receive_heal(amount: float) -> void:
	_current_hp = minf(_current_hp + amount, data.max_health)

# ---------- slow/buff ----------

func apply_slow(fraction: float) -> void:
	_slow_stacks = minf(_slow_stacks + fraction, 0.9)

func remove_slow(fraction: float) -> void:
	_slow_stacks = maxf(_slow_stacks - fraction, 0.0)

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
	if not _towers_in_debuff_range.has(body):
		_towers_in_debuff_range.append(body)
		if body.has_method("apply_attack_slow"):
			body.call("apply_attack_slow", data.debuff_attack_slow)

func _on_tower_debuff_exited(body: Node) -> void:
	_towers_in_debuff_range.erase(body)
	if body.has_method("remove_attack_slow"):
		body.call("remove_attack_slow", data.debuff_attack_slow)
