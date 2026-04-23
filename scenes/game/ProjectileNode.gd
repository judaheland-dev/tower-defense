extends Node3D

## ProjectileNode - visual projectile that travels from a tower to a target mob.
## On arrival, applies damage (and optional splash) to mobs within splash_radius.
## Freed automatically when it hits or the target dies.

var damage: float = 0.0
var splash_radius: float = 0.0
var field_player_index: int = 0
var target: Node = null
var speed: float = 14.0   # world units per second
var color: Color = Color.WHITE
var scale_factor: float = 1.0

# Chain lightning (Tesla)
var chain_count: int = 0
var chain_range: float = 0.0
var chain_damage_falloff: float = 0.7

# Damage over time (Poison)
var dot_damage: float = 0.0
var dot_duration: float = 0.0

# Mortar flag
var is_mortar: bool = false

# Set internally
var _mesh_inst: MeshInstance3D = null
var _lifetime: float = 4.0  # safety free if target vanishes

func _ready() -> void:
	_build_visual()

func _build_visual() -> void:
	_mesh_inst = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.18 * scale_factor
	sphere.height = 0.36 * scale_factor
	_mesh_inst.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mesh_inst.set_surface_override_material(0, mat)
	add_child(_mesh_inst)

func _process(delta: float) -> void:
	_lifetime -= delta
	if _lifetime <= 0.0:
		queue_free()
		return

	if target == null or not is_instance_valid(target) or target.is_queued_for_deletion():
		queue_free()
		return

	var target_pos: Vector3 = target.global_position + Vector3(0.0, 0.6, 0.0)
	var dir := (target_pos - global_position)
	var dist := dir.length()

	if dist <= speed * delta + 0.05:
		# Hit
		_on_hit()
		return

	global_position += dir.normalized() * speed * delta

func _on_hit() -> void:
	if target == null or not is_instance_valid(target) or target.is_queued_for_deletion():
		queue_free()
		return

	if splash_radius > 0.0:
		# AoE - damage all mobs of the same field layer near impact
		var hit_pos: Vector3 = (target as Node3D).global_position
		var space := get_world_3d().direct_space_state
		var query := PhysicsShapeQueryParameters3D.new()
		var sphere_shape := SphereShape3D.new()
		sphere_shape.radius = splash_radius
		query.shape = sphere_shape
		query.transform = Transform3D(Basis.IDENTITY, hit_pos)
		query.collision_mask = 3 if field_player_index == 0 else 4
		var results := space.intersect_shape(query, 32)
		for r in results:
			var body: Node = r.get("collider")
			if body != null and is_instance_valid(body) and body.has_method("take_damage"):
				body.call("take_damage", damage)
				_apply_dot_to(body)
		if is_mortar:
			_spawn_mortar_explosion(hit_pos)
		else:
			_spawn_impact_flash(hit_pos, true)
	else:
		if target.has_method("take_damage"):
			target.call("take_damage", damage)
		_apply_dot_to(target)
		_spawn_impact_flash(target.global_position + Vector3(0.0, 0.6, 0.0), false)

	# Chain lightning bounces
	if chain_count > 0:
		_perform_chain_lightning()

	queue_free()

func _apply_dot_to(mob: Node) -> void:
	if dot_damage > 0.0 and dot_duration > 0.0:
		if mob != null and is_instance_valid(mob) and mob.has_method("apply_dot"):
			mob.call("apply_dot", dot_damage, dot_duration)

# ---------- chain lightning ----------

func _perform_chain_lightning() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var hit_mobs: Array[Node] = []
	if target != null and is_instance_valid(target):
		hit_mobs.append(target)

	var current_pos: Vector3 = target.global_position if (target != null and is_instance_valid(target)) else global_position
	var current_damage := damage

	for i in chain_count:
		current_damage *= chain_damage_falloff
		# Find nearest un-hit mob within chain_range
		var space := get_world_3d().direct_space_state
		var query := PhysicsShapeQueryParameters3D.new()
		var sphere_shape := SphereShape3D.new()
		sphere_shape.radius = chain_range
		query.shape = sphere_shape
		query.transform = Transform3D(Basis.IDENTITY, current_pos)
		query.collision_mask = 3 if field_player_index == 0 else 4
		var results := space.intersect_shape(query, 32)

		var nearest: Node = null
		var nearest_dist: float = chain_range + 1.0
		for r in results:
			var body: Node = r.get("collider")
			if body == null or not is_instance_valid(body):
				continue
			if hit_mobs.has(body):
				continue
			var d := current_pos.distance_to(body.global_position)
			if d < nearest_dist:
				nearest_dist = d
				nearest = body

		if nearest == null:
			break

		# Deal chain damage
		if nearest.has_method("take_damage"):
			nearest.call("take_damage", current_damage)
		_apply_dot_to(nearest)

		# Spawn lightning arc VFX
		var chain_target_pos: Vector3 = nearest.global_position + Vector3(0.0, 0.6, 0.0)
		_spawn_chain_arc(current_pos + Vector3(0.0, 0.6, 0.0), chain_target_pos, parent)
		_spawn_chain_flash(chain_target_pos, parent)

		hit_mobs.append(nearest)
		current_pos = nearest.global_position

func _spawn_chain_arc(from_pos: Vector3, to_pos: Vector3, world_parent: Node) -> void:
	# Thin glowing cylinder stretched between two points
	var arc := MeshInstance3D.new()
	var dist := from_pos.distance_to(to_pos)
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04
	cyl.bottom_radius = 0.04
	cyl.height = dist
	arc.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.6, 1.0, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.6, 1.0)
	mat.emission_energy_multiplier = 3.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arc.set_surface_override_material(0, mat)
	# Position at midpoint, orient toward target
	var mid := (from_pos + to_pos) * 0.5
	arc.position = mid
	# Cylinder is Y-axis aligned by default; rotate to face from->to
	var dir := (to_pos - from_pos).normalized()
	if dir.length() > 0.001:
		arc.look_at(mid + dir, Vector3.UP)
		arc.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	world_parent.add_child(arc)
	# Fade out
	var tween := arc.create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.15)
	tween.tween_callback(arc.queue_free)

func _spawn_chain_flash(pos: Vector3, world_parent: Node) -> void:
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.3
	flash.mesh = sphere
	flash.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.8, 1.0, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.5, 0.8, 1.0)
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash.set_surface_override_material(0, mat)
	world_parent.add_child(flash)
	var tween := flash.create_tween()
	tween.set_parallel(true)
	tween.tween_property(flash, "scale", Vector3.ONE * 2.5, 0.12)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.12)
	tween.chain().tween_callback(flash.queue_free)

# ---------- mortar explosion VFX ----------

func _spawn_mortar_explosion(pos: Vector3) -> void:
	var parent := get_parent()
	if parent == null:
		return
	# Expanding orange ring
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.1
	torus.outer_radius = splash_radius
	ring.mesh = torus
	ring.position = Vector3(pos.x, 0.1, pos.z)
	ring.rotation_degrees.x = 90.0
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(1.0, 0.4, 0.1, 0.9)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(1.0, 0.4, 0.1)
	ring_mat.emission_energy_multiplier = 2.0
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.set_surface_override_material(0, ring_mat)
	ring.scale = Vector3.ONE * 0.3
	parent.add_child(ring)
	var ring_tween := ring.create_tween()
	ring_tween.set_parallel(true)
	ring_tween.tween_property(ring, "scale", Vector3.ONE * 1.5, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ring_tween.tween_property(ring_mat, "albedo_color:a", 0.0, 0.3)
	ring_tween.chain().tween_callback(ring.queue_free)

	# Fire flash sphere
	var fire := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	fire.mesh = sphere
	fire.position = Vector3(pos.x, 0.5, pos.z)
	var fire_mat := StandardMaterial3D.new()
	fire_mat.albedo_color = Color(1.0, 0.6, 0.1, 0.8)
	fire_mat.emission_enabled = true
	fire_mat.emission = Color(1.0, 0.5, 0.0)
	fire_mat.emission_energy_multiplier = 3.0
	fire_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fire.set_surface_override_material(0, fire_mat)
	fire.scale = Vector3.ONE * 0.2
	parent.add_child(fire)
	var fire_tween := fire.create_tween()
	fire_tween.set_parallel(true)
	fire_tween.tween_property(fire, "scale", Vector3.ONE * 1.2, 0.2).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	fire_tween.tween_property(fire_mat, "albedo_color:a", 0.0, 0.25)
	fire_tween.chain().tween_callback(fire.queue_free)

	AudioManager.play_sfx_path("res://assets/audio/sfx_explosion.ogg", -3.0)

func _spawn_impact_flash(pos: Vector3, large: bool) -> void:
	# Small expanding ring that fades out - parented to the world so it outlives this node
	var parent := get_parent()
	if parent == null:
		return
	var flash := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.05
	torus.outer_radius = 0.35 if not large else 0.6
	flash.mesh = torus
	flash.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash.set_surface_override_material(0, mat)
	parent.add_child(flash)
	# Animate scale up and fade out over 0.25s via a tween
	var tween := flash.create_tween()
	var target_scale := 3.0 if not large else 4.5
	tween.set_parallel(true)
	tween.tween_property(flash, "scale", Vector3.ONE * target_scale, 0.25)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.25)
	tween.chain().tween_callback(flash.queue_free)
