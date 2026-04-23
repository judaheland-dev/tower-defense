extends Node

## Game - root game scene. Single shared board with P1 on left, P2 on right.
## No SubViewports - one Camera3D renders the entire field.

const STATUS_BAR_HEIGHT: int = 28
const HUD_STRIP_HEIGHT: int = 48

var _player_worlds: Array[Node] = []  # [PlayerWorld P1, PlayerWorld P2]
var _round_manager: Node = null
var _shared_hud: CanvasLayer = null
var _p1_hud: CanvasLayer = null
var _p2_hud: CanvasLayer = null
var _shop_uis: Array[Node] = []
var _world_root: Node3D = null

func _ready() -> void:
	_build_world()
	_build_huds()
	_build_round_manager()

	GameManager.state_changed.connect(_on_state_changed)

# ---------- scene construction ----------

func _build_world() -> void:
	_world_root = Node3D.new()
	_world_root.name = "WorldRoot"
	add_child(_world_root)

	# Shared camera - true isometric (45-degree azimuth, ~32-degree elevation)
	# matching the Kenney tower defense kit visual style
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 30.0
	camera.near = 0.1
	camera.far = 200.0
	_world_root.add_child(camera)
	# Board center at (22, 0, 0). Camera from the front-left corner
	# so P1 (left half) appears screen-left and P2 (right half) appears screen-right
	camera.position = Vector3(22.0 - 25.0, 22.0, 25.0)
	camera.look_at(Vector3(22.0, 0.0, 0.0), Vector3.UP)
	camera.current = true

	# Shared lighting
	_build_lighting()

	# P1 world - left half (side = 0)
	var p1_world: Node = load("res://scenes/game/PlayerWorld.gd").new()
	p1_world.player_index = 0
	p1_world.board_side = 0  # LEFT
	_world_root.add_child(p1_world)
	_player_worlds.append(p1_world)

	# P2 world - right half (side = 1)
	var p2_world: Node = load("res://scenes/game/PlayerWorld.gd").new()
	p2_world.player_index = 1
	p2_world.board_side = 1  # RIGHT
	_world_root.add_child(p2_world)
	_player_worlds.append(p2_world)

func _build_lighting() -> void:
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.15, 0.15, 0.18)  # dark slate matching Kenney sample style
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.55, 0.6)
	environment.ambient_light_energy = 0.6
	env.environment = environment
	_world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, 45.0, 0.0)
	sun.light_energy = 1.2
	_world_root.add_child(sun)

func _build_huds() -> void:
	var font := GameManager.kenney_font()

	# Shared status bar at very top, full width
	_shared_hud = CanvasLayer.new()
	_shared_hud.layer = 10
	add_child(_shared_hud)

	var status_bg := ColorRect.new()
	status_bg.color = Color(0.05, 0.05, 0.05, 0.95)
	status_bg.set_anchors_preset(Control.PRESET_TOP_LEFT)
	status_bg.offset_left = 0
	status_bg.offset_top = 0
	status_bg.offset_right = 1920
	status_bg.offset_bottom = STATUS_BAR_HEIGHT
	status_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shared_hud.add_child(status_bg)

	var status_label := Label.new()
	status_label.name = "StatusLabel"
	status_label.text = "PREP PHASE"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	status_label.offset_left = 0
	status_label.offset_top = 4
	status_label.offset_right = 1920
	status_label.offset_bottom = STATUS_BAR_HEIGHT
	if font:
		status_label.add_theme_font_override("font", font)
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.add_theme_color_override("font_color", Color.WHITE)
	_shared_hud.add_child(status_label)

	# P1 HUD strip - bottom-left corner
	_p1_hud = CanvasLayer.new()
	_p1_hud.layer = 1
	add_child(_p1_hud)

	var p1_strip := _make_hud_strip(Color(0.1, 0.15, 0.3, 0.85), font, 0, 0, 1080 - HUD_STRIP_HEIGHT)
	_p1_hud.add_child(p1_strip)
	var p1_label := p1_strip.get_node("PlayerLabel") as Label
	_refresh_hud_label(0, p1_label)
	_player_worlds[0].hp_changed.connect(func(_hp: int) -> void: _refresh_hud_label(0, p1_label))
	_player_worlds[0].selected_item_changed.connect(func(_item: Resource) -> void: _refresh_hud_label(0, p1_label))

	# P2 HUD strip - bottom-right corner
	_p2_hud = CanvasLayer.new()
	_p2_hud.layer = 2
	add_child(_p2_hud)

	var p2_strip := _make_hud_strip(Color(0.3, 0.1, 0.1, 0.85), font, 1, 960, 1080 - HUD_STRIP_HEIGHT)
	_p2_hud.add_child(p2_strip)
	var p2_label := p2_strip.get_node("PlayerLabel") as Label
	_refresh_hud_label(1, p2_label)
	_player_worlds[1].hp_changed.connect(func(_hp: int) -> void: _refresh_hud_label(1, p2_label))
	_player_worlds[1].selected_item_changed.connect(func(_item: Resource) -> void: _refresh_hud_label(1, p2_label))

func _make_hud_strip(color: Color, font: FontFile, player_index: int, x_offset: int, y_offset: int) -> ColorRect:
	var strip := ColorRect.new()
	strip.color = color
	strip.set_anchors_preset(Control.PRESET_TOP_LEFT)
	strip.offset_left = x_offset
	strip.offset_top = y_offset
	strip.offset_right = x_offset + 960
	strip.offset_bottom = y_offset + HUD_STRIP_HEIGHT
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var label := Label.new()
	label.name = "PlayerLabel"
	label.text = "P%d  HP: --  Coins: --" % (player_index + 1)
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	label.offset_left = 20
	if font:
		label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color.WHITE)
	strip.add_child(label)

	# Connect economy signal to update label
	EconomyManager.coins_changed.connect(
		func(idx: int, amount: int) -> void:
			if idx == player_index:
				_refresh_hud_label(player_index, label)
	)
	return strip

func _refresh_hud_label(player_index: int, label: Label) -> void:
	if player_index >= _player_worlds.size():
		return
	var world := _player_worlds[player_index]
	var hp: int = world.get("current_hp") if world.get("current_hp") != null else 0
	var coins := EconomyManager.coins[player_index]
	var is_pve := GameManager.current_mode == GameManager.GameMode.PVE
	var prefix := "CPU" if (player_index == 1 and is_pve) else ("P%d" % (player_index + 1))
	var item_name := world.call("get_selected_item_name") as String
	var item_str := ("  [%s]" % item_name) if item_name != "" else ""
	label.text = "%s  HP: %d  Coins: %d%s" % [prefix, hp, coins, item_str]

func _build_round_manager() -> void:
	_round_manager = load("res://systems/RoundManager.gd").new()
	_round_manager.player_worlds = _player_worlds
	add_child(_round_manager)

	# Shop UI - only human players get a shop panel
	var human_players := 1 if GameManager.current_mode == GameManager.GameMode.PVE else 2
	for i in human_players:
		var shop: CanvasLayer = load("res://scenes/game/ShopUI.gd").new()
		shop.player_index = i
		shop.player_world = _player_worlds[i]
		# P1 shop on left edge, P2 shop on right edge
		shop.viewport_top = STATUS_BAR_HEIGHT
		shop.viewport_left = 0 if i == 0 else (1920 - 360)
		shop.layer = 15 + i
		add_child(shop)
		_shop_uis.append(shop)

	# PVE: add AI for P2
	if GameManager.current_mode == GameManager.GameMode.PVE:
		var ai: Node = load("res://systems/SimpleAI.gd").new()
		ai.player_world = _player_worlds[1]
		add_child(ai)

func _process(_delta: float) -> void:
	match GameManager.current_state:
		GameManager.GameState.PREP:
			_handle_prep_input()
			_update_prep_status()
		GameManager.GameState.PLAY:
			_update_play_status()

func _handle_prep_input() -> void:
	# Shop toggle
	for i in _shop_uis.size():
		var action := "p1_shop" if i == 0 else "p2_shop"
		if Input.is_action_just_pressed(action):
			_shop_uis[i].call("toggle")
			return
	# Ready-up: cancel while no item selected and shop closed
	var human_players := 1 if GameManager.current_mode == GameManager.GameMode.PVE else 2
	for i in human_players:
		var action := "p1_cancel" if i == 0 else "p2_cancel"
		if Input.is_action_just_pressed(action):
			var shop_open := (i < _shop_uis.size()) and (_shop_uis[i].call("is_shop_open") as bool)
			if not shop_open:
				var has_item := (_player_worlds[i].call("get_selected_item_name") as String) != ""
				if not has_item:
					_round_manager.call("toggle_ready", i)
				return

func _update_prep_status() -> void:
	var status_label: Label = _shared_hud.get_node_or_null("StatusLabel")
	if status_label == null or _round_manager == null:
		return
	var t := int(_round_manager.call("get_prep_timer"))
	var r0: bool = _round_manager.call("is_player_ready", 0)
	var r1: bool = _round_manager.call("is_player_ready", 1)
	var is_pve := GameManager.current_mode == GameManager.GameMode.PVE
	var s0 := "[READY]" if r0 else "Q=Ready"
	var s1 := "[READY]" if r1 else "Q=Ready"
	var right := ("  P2:%s" % s1) if not is_pve else ""
	status_label.text = "Round %d  PREP  %ds  |  P1:%s%s" % [GameManager.round_number, t, s0, right]

func _update_play_status() -> void:
	var status_label: Label = _shared_hud.get_node_or_null("StatusLabel")
	if status_label == null or _round_manager == null:
		return
	var t := int(_round_manager.call("get_play_timer"))
	status_label.text = "Round %d  BATTLE  %ds" % [GameManager.round_number, t]

func _unhandled_input(_event: InputEvent) -> void:
	pass  # all prep input handled via polling in _process

# ---------- state handling ----------

func _on_state_changed(new_state: GameManager.GameState) -> void:
	var status_label: Label = _shared_hud.get_node_or_null("StatusLabel")
	match new_state:
		GameManager.GameState.PREP:
			if status_label:
				status_label.text = "PREP PHASE"
		GameManager.GameState.PLAY:
			if status_label:
				status_label.text = "BATTLE PHASE"
		GameManager.GameState.ROUND_OVER:
			if status_label:
				status_label.text = "ROUND OVER"
		GameManager.GameState.GAME_OVER:
			_show_game_over()

func _show_game_over() -> void:
	var overlay := CanvasLayer.new()
	overlay.layer = 25
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(overlay)

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.75)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(bg)

	var lbl := Label.new()
	lbl.text = "GAME OVER\n\nPress Escape / Start to return to menu"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var font := GameManager.kenney_font()
	if font:
		lbl.add_theme_font_override("font", font)
	lbl.add_theme_font_size_override("font_size", 48)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	overlay.add_child(lbl)
