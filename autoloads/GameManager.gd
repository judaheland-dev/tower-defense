extends Node

## GameManager - global game state machine and scene transitions.
## Persists between scenes. All other systems read GameState from here.

const FONT_PATH := "res://assets/fonts/kenney_future.ttf"

static func kenney_font() -> FontFile:
	if ResourceLoader.exists(FONT_PATH):
		return load(FONT_PATH)
	return null

enum GameMode {
	PVP,  # two human players
	PVE,  # one human vs AI
}

enum GameState {
	MENU,
	PREP,
	PLAY,
	ROUND_OVER,
	PAUSED,
	GAME_OVER,
}

var current_mode: GameMode = GameMode.PVP
var current_state: GameState = GameState.MENU
var round_number: int = 0
var _pre_pause_state: GameState = GameState.PREP  # restored on unpause

# Set before starting a game
var player_count: int = 2  # 1 = PVE, 2 = PVP

signal state_changed(new_state: GameState)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func set_state(new_state: GameState) -> void:
	current_state = new_state
	state_changed.emit(new_state)

func start_game(mode: GameMode) -> void:
	current_mode = mode
	player_count = 1 if mode == GameMode.PVE else 2
	round_number = 0
	EconomyManager.reset()
	set_state(GameState.PREP)
	get_tree().change_scene_to_file("res://scenes/game/Game.tscn")

func go_to_main_menu() -> void:
	round_number = 0
	set_state(GameState.MENU)
	get_tree().change_scene_to_file("res://scenes/main_menu/MainMenu.tscn")

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		match current_state:
			GameState.PREP, GameState.PLAY:
				_pre_pause_state = current_state
				set_state(GameState.PAUSED)
				get_tree().paused = true
			GameState.PAUSED:
				set_state(_pre_pause_state)
				get_tree().paused = false
			GameState.GAME_OVER:
				get_tree().paused = false
				go_to_main_menu()
