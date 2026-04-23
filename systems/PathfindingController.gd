extends Node

## PathfindingController - wraps NavigationRegion3D baking and path validation.
## Owned by PlayerWorld; call setup() before use.

var _nav_region: NavigationRegion3D = null
var _spawn_pos: Vector3 = Vector3.ZERO
var _exit_pos: Vector3 = Vector3.ZERO
var _pending_callback: Callable

func setup(nav_region: NavigationRegion3D, spawn_pos: Vector3, exit_pos: Vector3) -> void:
	_nav_region = nav_region
	_spawn_pos = spawn_pos
	_exit_pos = exit_pos
	# Initial bake
	bake_async()

# Bake nav mesh and call callback(valid: bool) when done.
# The callback receives true if a path still exists from spawn to exit.
func bake_and_validate(callback: Callable) -> void:
	_pending_callback = callback
	if not _nav_region.bake_finished.is_connected(_on_bake_finished_validate):
		_nav_region.bake_finished.connect(_on_bake_finished_validate, CONNECT_ONE_SHOT)
	_nav_region.bake_navigation_mesh()

# Bake without validation callback (e.g. after a sell).
func bake_async() -> void:
	_nav_region.bake_navigation_mesh()

func _on_bake_finished_validate() -> void:
	var valid := _has_open_path()
	if _pending_callback.is_valid():
		_pending_callback.call(valid)

func _has_open_path() -> bool:
	var map := _nav_region.get_navigation_map()
	if not NavigationServer3D.map_is_active(map):
		return true  # map not ready yet - allow placement
	var start := NavigationServer3D.map_get_closest_point(map, _spawn_pos)
	var end := NavigationServer3D.map_get_closest_point(map, _exit_pos)
	var path := NavigationServer3D.map_get_path(map, start, end, true)
	return path.size() >= 2
