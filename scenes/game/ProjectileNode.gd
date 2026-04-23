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
		_spawn_impact_flash(hit_pos, true)
	else:
		if target.has_method("take_damage"):
			target.call("take_damage", damage)
		_spawn_impact_flash(target.global_position + Vector3(0.0, 0.6, 0.0), false)

	queue_free()

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
