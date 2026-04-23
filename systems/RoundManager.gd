extends Node

## RoundManager - drives the PREP -> PLAY -> ROUND_OVER game loop.
## Owned by Game.gd. Receives references to both PlayerWorld nodes.

const PREP_TIME: float = 60.0
const PLAY_TIME: float = 90.0
const ROUND_OVER_DURATION: float = 5.0

const FREE_MOB_ID: StringName = &"mob_basic"

# Set by Game.gd before adding to tree
var player_worlds: Array[Node] = []

var _phase_timer: float = 0.0
var _play_time_remaining: float = 0.0
# Track when each player's mobs were all destroyed for speed bonus
var _player_cleared_time: Array[float] = [0.0, 0.0]
var _player_mobs_cleared: Array[bool] = [false, false]
var _player_ready: Array[bool] = [false, false]

func _ready() -> void:
	GameManager.state_changed.connect(_on_state_changed)
	# Start first prep phase
	_begin_prep()

func _process(delta: float) -> void:
	match GameManager.current_state:
		GameManager.GameState.PREP:
			_phase_timer -= delta
			if _phase_timer <= 0.0:
				_begin_play()

		GameManager.GameState.PLAY:
			_play_time_remaining -= delta
			_check_play_end()
			if _play_time_remaining <= 0.0:
				_end_play()

		GameManager.GameState.ROUND_OVER:
			_phase_timer -= delta
			if _phase_timer <= 0.0:
				_begin_prep()

# ---------- phase transitions ----------

func _begin_prep() -> void:
	GameManager.round_number += 1
	_player_cleared_time = [0.0, 0.0]
	_player_mobs_cleared = [false, false]
	_player_ready = [false, false]
	# AI is always ready in PVE mode
	if GameManager.current_mode == GameManager.GameMode.PVE:
		_player_ready[1] = true
	_phase_timer = PREP_TIME

	# Give each player a free mob if they have none queued
	for i in player_worlds.size():
		var world: Node = player_worlds[i]
		var queued: Array = world.call("get_queued_mobs")
		if queued.is_empty():
			_give_free_mob(i)

	GameManager.set_state(GameManager.GameState.PREP)

func _give_free_mob(player_index: int) -> void:
	var path := "res://resources/mobs/mob_basic.tres"
	if ResourceLoader.exists(path):
		var mob_data: MobData = load(path)
		player_worlds[player_index].call("_queue_mob", mob_data)

func _begin_play() -> void:
	_play_time_remaining = PLAY_TIME
	GameManager.set_state(GameManager.GameState.PLAY)
	_spawn_queued_mobs()

func _spawn_queued_mobs() -> void:
	# Each player's purchased mobs spawn on the OPPONENT's field
	for i in player_worlds.size():
		var attacker_world: Node = player_worlds[i]
		# Opponent index: 0->1, 1->0
		var defender_index := 1 - i
		var defender_world: Node = player_worlds[defender_index]

		var queued: Array = attacker_world.call("get_queued_mobs")
		for mob_data in queued:
			defender_world.call("spawn_mob", mob_data)
		attacker_world.call("clear_queued_mobs")

func _check_play_end() -> void:
	for i in player_worlds.size():
		if not _player_mobs_cleared[i]:
			var count: int = player_worlds[i].call("get_active_mob_count")
			if count == 0:
				_player_mobs_cleared[i] = true
				_player_cleared_time[i] = _play_time_remaining

	# End early if all sides are clear
	var all_clear := true
	for cleared in _player_mobs_cleared:
		if not cleared:
			all_clear = false
			break
	if all_clear:
		_end_play()

func _end_play() -> void:
	if GameManager.current_state == GameManager.GameState.GAME_OVER:
		return

	# Award income
	for i in player_worlds.size():
		var time_left := _player_cleared_time[i] if _player_mobs_cleared[i] else 0.0
		EconomyManager.award_round_income(i, time_left, PLAY_TIME)

	_phase_timer = ROUND_OVER_DURATION
	GameManager.set_state(GameManager.GameState.ROUND_OVER)

# ---------- state signals ----------

func _on_state_changed(new_state: GameManager.GameState) -> void:
	pass  # handled in _process

# ---------- ready-up API (called by Game.gd) ----------

func get_prep_timer() -> float:
	return _phase_timer

func toggle_ready(player_index: int) -> void:
	if GameManager.current_state != GameManager.GameState.PREP:
		return
	_player_ready[player_index] = not _player_ready[player_index]
	if _player_ready[0] and _player_ready[1]:
		_begin_play()

func is_player_ready(player_index: int) -> bool:
	if player_index >= _player_ready.size():
		return false
	return _player_ready[player_index]
