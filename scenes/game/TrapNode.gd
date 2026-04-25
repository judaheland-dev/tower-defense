extends Node3D

## TrapNode - a placed ground trap. Affects mobs that walk over it.
## Unlike TowerNode, traps have NO StaticBody3D and do NOT block pathfinding.

const CELL_SIZE: float = 2.0

var data: TrapData = null
var field_player_index: int = 0

var _charges_remaining: int = 0  # 0 = permanent
var _mobs_on_trap: Array[Node] = []
var _detection_area: Area3D = null
var _expired: bool = false

signal expired(trap: Node)

func _ready() -> void:
	if data == null:
		return
	_charges_remaining = data.max_charges  # 0 means permanent
	_build_model()
	if data.trap_type != TrapData.TrapType.GOLD_MINE:
		_build_detection_area()

func _build_model() -> void:
	# Colored base box sitting just above the tile surface — thin pad
	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(CELL_SIZE - 0.1, 0.15, CELL_SIZE - 0.1)
	mesh_inst.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _placeholder_color()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if data.texture_path != "" and ResourceLoader.exists(data.texture_path):
		mat.albedo_texture = load(data.texture_path)
		mat.albedo_color = data.icon_color
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.uv1_scale = Vector3(0.35, 0.35, 0.35)
		mat.uv1_offset = Vector3(0.325, 0.325, 0.0)
	mesh_inst.set_surface_override_material(0, mat)
	mesh_inst.position = Vector3(0.0, 0.35, 0.0)
	add_child(mesh_inst)

	if data.texture_path != "" and ResourceLoader.exists(data.texture_path):
		pass  # texture applied directly to base box above
	elif data.model_path != "" and ResourceLoader.exists(data.model_path):
		_build_3d_model(mesh_inst)

func _build_3d_model(placeholder: MeshInstance3D) -> void:
	var scene: PackedScene = load(data.model_path)
	if data.trap_type == TrapData.TrapType.SPIKE_PIT:
		# Place a grid of spike models to fill the cell densely
		var offsets := [
			Vector3(-0.5, 0.15, -0.5), Vector3(0.5, 0.15, -0.5),
			Vector3(-0.5, 0.15, 0.5), Vector3(0.5, 0.15, 0.5),
			Vector3(0.0, 0.15, 0.0),
		]
		for ofs in offsets:
			var inst := scene.instantiate()
			inst.scale = Vector3.ONE * data.model_scale * 0.8
			inst.position = ofs
			add_child(inst)
			_tint_meshes(inst, data.icon_color)
	else:
		var inst := scene.instantiate()
		inst.scale = Vector3.ONE * data.model_scale
		add_child(inst)
		if _has_mesh_instance(inst):
			placeholder.visible = false
			_tint_meshes(inst, data.icon_color)

func _has_mesh_instance(node: Node) -> bool:
	if node is MeshInstance3D:
		return true
	for child in node.get_children():
		if _has_mesh_instance(child):
			return true
	return false

func _tint_meshes(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		for i in mi.mesh.get_surface_count():
			var base_mat: Material = mi.get_active_material(i)
			var new_mat := StandardMaterial3D.new()
			if base_mat is StandardMaterial3D:
				new_mat = base_mat.duplicate()
			new_mat.albedo_color = color
			mi.set_surface_override_material(i, new_mat)
	for child in node.get_children():
		_tint_meshes(child, color)

func _placeholder_color() -> Color:
	match data.trap_type:
		TrapData.TrapType.MUD:        return Color(0.4, 0.25, 0.08, 1.0)
		TrapData.TrapType.SPIKE_PIT:  return Color(0.1, 0.08, 0.05, 1.0)
		TrapData.TrapType.TAR_PIT:    return Color(0.08, 0.05, 0.02, 1.0)
		TrapData.TrapType.LAVA:       return Color(0.6, 0.1, 0.0, 1.0)
		TrapData.TrapType.POISON_BOG: return Color(0.25, 0.08, 0.35, 1.0)
		TrapData.TrapType.AMPLIFIER:  return Color(0.6, 0.5, 0.05, 1.0)
		TrapData.TrapType.GOLD_MINE:  return Color(0.5, 0.35, 0.02, 1.0)
	return Color(0.3, 0.3, 0.3, 1.0)

func _build_detection_area() -> void:
	_detection_area = Area3D.new()
	_detection_area.collision_layer = 0
	# Layer 3 (P1 field mobs) = bitmask 4, layer 4 (P2 field mobs) = bitmask 8
	_detection_area.collision_mask = 4 if field_player_index == 0 else 8

	var cshape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(CELL_SIZE, 1.0, CELL_SIZE)
	cshape.shape = box
	cshape.position = Vector3(0.0, 0.5, 0.0)
	_detection_area.add_child(cshape)
	_detection_area.body_entered.connect(_on_mob_entered)
	_detection_area.body_exited.connect(_on_mob_exited)
	add_child(_detection_area)

# ---------- process ----------

func _process(delta: float) -> void:
	if _expired or data == null:
		return
	if GameManager.current_state != GameManager.GameState.PLAY:
		return
	# Tick DoT damage for Lava and Poison Bog
	if data.damage_per_second > 0.0:
		var i := _mobs_on_trap.size() - 1
		while i >= 0:
			var mob: Node = _mobs_on_trap[i]
			if not is_instance_valid(mob) or mob.is_queued_for_deletion():
				_mobs_on_trap.remove_at(i)
			else:
				var dying: Variant = mob.get("_dying")
				if dying == null or dying == false:
					if mob.has_method("take_damage"):
						mob.call("take_damage", data.damage_per_second * delta)
			i -= 1

# ---------- mob enter/exit ----------

func _on_mob_entered(body: Node) -> void:
	if _expired:
		return
	var dying: Variant = body.get("_dying")
	if dying == true:
		return
	if _mobs_on_trap.has(body):
		return
	_mobs_on_trap.append(body)

	match data.trap_type:
		TrapData.TrapType.SPIKE_PIT:
			if body.has_method("take_damage"):
				body.call("take_damage", data.burst_damage)
			_use_charge()
		TrapData.TrapType.MUD, TrapData.TrapType.TAR_PIT:
			if body.has_method("apply_trap_slow"):
				body.call("apply_trap_slow", data.slow_amount)
		TrapData.TrapType.LAVA:
			_use_charge()
		TrapData.TrapType.POISON_BOG:
			if body.has_method("apply_heal_reduction"):
				body.call("apply_heal_reduction", data.heal_reduction)
			_use_charge()
		TrapData.TrapType.AMPLIFIER:
			if body.has_method("apply_damage_amplify"):
				body.call("apply_damage_amplify", data.damage_amplify)

func _on_mob_exited(body: Node) -> void:
	_mobs_on_trap.erase(body)
	if _expired:
		return
	# Remove continuous effects
	match data.trap_type:
		TrapData.TrapType.MUD, TrapData.TrapType.TAR_PIT:
			if is_instance_valid(body) and body.has_method("remove_trap_slow"):
				body.call("remove_trap_slow", data.slow_amount)
		TrapData.TrapType.POISON_BOG:
			if is_instance_valid(body) and body.has_method("remove_heal_reduction"):
				body.call("remove_heal_reduction", data.heal_reduction)
		TrapData.TrapType.AMPLIFIER:
			if is_instance_valid(body) and body.has_method("remove_damage_amplify"):
				body.call("remove_damage_amplify", data.damage_amplify)

# ---------- charges ----------

func _use_charge() -> void:
	if _charges_remaining <= 0:
		return  # permanent trap
	_charges_remaining -= 1
	if _charges_remaining <= 0:
		_expire()

func _expire() -> void:
	_expired = true
	# Remove all active effects from mobs still on the trap
	for mob in _mobs_on_trap:
		if not is_instance_valid(mob):
			continue
		match data.trap_type:
			TrapData.TrapType.MUD, TrapData.TrapType.TAR_PIT:
				if mob.has_method("remove_trap_slow"):
					mob.call("remove_trap_slow", data.slow_amount)
			TrapData.TrapType.POISON_BOG:
				if mob.has_method("remove_heal_reduction"):
					mob.call("remove_heal_reduction", data.heal_reduction)
			TrapData.TrapType.AMPLIFIER:
				if mob.has_method("remove_damage_amplify"):
					mob.call("remove_damage_amplify", data.damage_amplify)
	_mobs_on_trap.clear()
	expired.emit(self)
	AudioManager.play_sfx_path("res://assets/audio/sfx_explosion.ogg", -6.0)
	queue_free()
