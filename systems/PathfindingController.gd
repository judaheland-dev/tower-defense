extends Node

## PathfindingController - wraps NavigationRegion3D baking and path validation.
## Owned by PlayerWorld; call setup() before use.

var _nav_region: NavigationRegion3D = null
var _spawn_pos: Vector3 = Vector3.ZERO
var _exit_pos: Vector3 = Vector3.ZERO
var _bake_requested: bool = false
var _bake_in_progress: bool = false
var _pending_validation_callbacks: Array[Callable] = []

func setup(nav_region: NavigationRegion3D, spawn_pos: Vector3, exit_pos: Vector3) -> void:
	_nav_region = nav_region
	_spawn_pos = spawn_pos
	_exit_pos = exit_pos
	bake_async()

# Bake nav mesh and call callback(valid: bool) when done.
# The callback receives true if a path still exists from spawn to exit.
func bake_and_validate(callback: Callable) -> void:
	if not callback.is_valid():
		return
	if _nav_region == null or not is_instance_valid(_nav_region):
		callback.call(false)
		return
	_pending_validation_callbacks.append(callback)
	_request_bake()

# Bake without validation callback (e.g. after a sell).
func bake_async() -> void:
	_request_bake()

func _request_bake() -> void:
	if _nav_region == null or not is_instance_valid(_nav_region):
		return
	_bake_requested = true
	if not _bake_in_progress:
		_drain_bake_queue()

func _drain_bake_queue() -> void:
	_bake_in_progress = true
	while _bake_requested and is_instance_valid(_nav_region):
		_bake_requested = false

		# Respect a bake started outside this controller, then start exactly one
		# controller-owned bake. Requests received while awaiting it are collapsed
		# into the next loop iteration.
		if _nav_region.is_baking():
			await _nav_region.bake_finished
		if not is_instance_valid(_nav_region):
			break

		_nav_region.bake_navigation_mesh()
		# Threadless Web exports may finish synchronously. Only await the signal
		# when Godot reports that the asynchronous bake is still running.
		if _nav_region.is_baking():
			await _nav_region.bake_finished

		# NavigationServer applies the new region on its synchronization step.
		# Waiting one physics frame prevents validation from querying stale data.
		if is_inside_tree():
			await get_tree().physics_frame

	var callbacks := _pending_validation_callbacks.duplicate()
	_pending_validation_callbacks.clear()
	var valid := _has_open_path() if is_instance_valid(_nav_region) else false
	for callback in callbacks:
		if callback.is_valid():
			callback.call(valid)

	_bake_in_progress = false
	if _bake_requested:
		_drain_bake_queue()

func _has_open_path() -> bool:
	var map := _nav_region.get_navigation_map()
	if not NavigationServer3D.map_is_active(map):
		return false  # validation must fail closed when navigation is unavailable
	var start := NavigationServer3D.map_get_closest_point(map, _spawn_pos)
	var end := NavigationServer3D.map_get_closest_point(map, _exit_pos)
	var path := NavigationServer3D.map_get_path(map, start, end, true)
	return path.size() >= 2
