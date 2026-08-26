extends Node

const PLAYER_WORLD := preload("res://scenes/game/PlayerWorld.gd")
const PATHFINDING_CONTROLLER := preload("res://systems/PathfindingController.gd")
const BASIC_WALL := preload("res://resources/towers/wall_basic.tres")

var _failures: Array[String] = []


class FakePathfinding extends Node:
	var result: bool = true
	var complete_immediately: bool = true
	var validation_count: int = 0
	var recovery_bake_count: int = 0
	var pending_callback: Callable

	func bake_and_validate(callback: Callable) -> void:
		validation_count += 1
		if complete_immediately:
			callback.call(result)
		else:
			pending_callback = callback

	func bake_async() -> void:
		recovery_bake_count += 1

	func finish(valid: bool) -> void:
		var callback := pending_callback
		pending_callback = Callable()
		callback.call(valid)


func _ready() -> void:
	_test_valid_placement()
	_test_invalid_placement_rolls_back()
	_test_pending_validation_blocks_second_placement()
	_test_missing_navigation_fails_closed()
	if _failures.is_empty():
		print("PASS: tower placement validation")
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error(failure)
	get_tree().quit(1)


func _new_world(pathfinding: FakePathfinding) -> Node:
	var world := PLAYER_WORLD.new()
	world.player_index = 0
	world._init_grid()
	world._cursor_col = 5
	world._cursor_row = 5
	world._selected_item = BASIC_WALL
	world._pathfinding = pathfinding
	world.add_child(pathfinding)
	return world


func _test_valid_placement() -> void:
	EconomyManager.coins[0] = 150
	var pathfinding := FakePathfinding.new()
	var world := _new_world(pathfinding)
	world._try_place()
	_check(pathfinding.validation_count == 1, "valid tower was not validated")
	_check(not world._tower_placement_pending, "valid tower left placement locked")
	_check(world._grid[5][5], "valid tower was removed from the grid")
	_check(world._tower_nodes.has("5,5"), "valid tower was removed from the index")
	_check(EconomyManager.coins[0] == 150 - BASIC_WALL.cost,
		"valid tower cost was refunded")
	_check(pathfinding.recovery_bake_count == 0,
		"valid tower requested an unnecessary recovery bake")
	world.free()


func _test_invalid_placement_rolls_back() -> void:
	EconomyManager.coins[0] = 150
	var pathfinding := FakePathfinding.new()
	pathfinding.result = false
	var world := _new_world(pathfinding)
	world._try_place()
	_check(not world._tower_placement_pending, "invalid tower left placement locked")
	_check(not world._grid[5][5], "invalid tower still occupies the grid")
	_check(not world._tower_nodes.has("5,5"), "invalid tower remains indexed")
	_check(EconomyManager.coins[0] == 150, "invalid tower cost was not fully refunded")
	_check(pathfinding.recovery_bake_count == 1,
		"invalid tower did not request a recovery bake")
	world.free()


func _test_pending_validation_blocks_second_placement() -> void:
	EconomyManager.coins[0] = 150
	var pathfinding := FakePathfinding.new()
	pathfinding.complete_immediately = false
	var world := _new_world(pathfinding)
	world._try_place()
	var coins_after_first: int = EconomyManager.coins[0]
	world._cursor_row = 6
	world._try_place()
	_check(pathfinding.validation_count == 1,
		"a second placement started while validation was pending")
	_check(not world._grid[5][6], "a second tower entered the pending grid")
	_check(EconomyManager.coins[0] == coins_after_first,
		"a blocked second placement spent coins")
	pathfinding.finish(false)
	_check(EconomyManager.coins[0] == 150,
		"deferred invalid placement was not refunded")
	world.free()


func _test_missing_navigation_fails_closed() -> void:
	var controller := PATHFINDING_CONTROLLER.new()
	var results: Array[bool] = []
	controller.bake_and_validate(func(valid: bool) -> void: results.append(valid))
	_check(results == [false], "missing navigation did not fail validation closed")
	controller.free()


func _check(condition: bool, failure: String) -> void:
	if not condition:
		_failures.append(failure)
