extends Node

## Game - root game scene. Owns both player SubViewports, shared HUD,
## and the RoundManager. Builds entire tree in _ready().

const VIEWPORT_HEIGHT_EACH: int = 526
const STATUS_BAR_HEIGHT: int = 28
const VIEWPORT_WIDTH: int = 1920

var _player_worlds: Array[Node] = []  # [PlayerWorld P1, PlayerWorld P2]
var _round_manager: Node = null
var _shared_hud: CanvasLayer = null
var _p1_hud: CanvasLayer = null
var _p2_hud: CanvasLayer = null
var _shop_uis: Array[Node] = []

func _ready() -> void:
	_build_viewports()
	_build_huds()
	_build_round_manager()

	GameManager.state_changed.connect(_on_state_changed)

# ---------- scene construction ----------

func _build_viewports() -> void:
	# P1 viewport - top half
	var p1_container := SubViewportContainer.new()
	p1_container.stretch = true
	p1_container.set_anchors_preset(Control.PRESET_TOP_LEFT)
	p1_container.offset_left = 0
	p1_container.offset_top = 0
	p1_container.offset_right = VIEWPORT_WIDTH
	p1_container.offset_bottom = VIEWPORT_HEIGHT_EACH
	add_child(p1_container)

	var p1_viewport := SubViewport.new()
	p1_viewport.size = Vector2i(VIEWPORT_WIDTH, VIEWPORT_HEIGHT_EACH)
	p1_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	p1_viewport.own_world_3d = true
	p1_container.add_child(p1_viewport)

	var p1_world: Node = load("res://scenes/game/PlayerWorld.gd").new()
	p1_world.player_index = 0
	p1_viewport.add_child(p1_world)
	_player_worlds.append(p1_world)

	# P2 viewport - bottom half
	var p2_container := SubViewportContainer.new()
	p2_container.stretch = true
	p2_container.set_anchors_preset(Control.PRESET_TOP_LEFT)
	p2_container.offset_left = 0
	p2_container.offset_top = VIEWPORT_HEIGHT_EACH + STATUS_BAR_HEIGHT
	p2_container.offset_right = VIEWPORT_WIDTH
	p2_container.offset_bottom = VIEWPORT_HEIGHT_EACH + STATUS_BAR_HEIGHT + VIEWPORT_HEIGHT_EACH
	add_child(p2_container)

	var p2_viewport := SubViewport.new()
	p2_viewport.size = Vector2i(VIEWPORT_WIDTH, VIEWPORT_HEIGHT_EACH)
	p2_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	p2_viewport.own_world_3d = true
	p2_container.add_child(p2_viewport)

	var p2_world: Node = load("res://scenes/game/PlayerWorld.gd").new()
	p2_world.player_index = 1
	p2_viewport.add_child(p2_world)
	_player_worlds.append(p2_world)

func _build_huds() -> void:
	var font := GameManager.kenney_font()

	# P1 HUD strip - anchored to top
	_p1_hud = CanvasLayer.new()
	_p1_hud.layer = 1
	add_child(_p1_hud)

	var p1_strip := _make_hud_strip(Color(0.1, 0.15, 0.3, 0.85), font, 0)
	_p1_hud.add_child(p1_strip)
	var p1_label := p1_strip.get_node("PlayerLabel") as Label
	_refresh_hud_label(0, p1_label)
	_player_worlds[0].hp_changed.connect(func(_hp: int) -> void: _refresh_hud_label(0, p1_label))
	_player_worlds[0].selected_item_changed.connect(func(_item: Resource) -> void: _refresh_hud_label(0, p1_label))

	# P2 HUD strip - anchored to bottom of its viewport region
	_p2_hud = CanvasLayer.new()
	_p2_hud.layer = 2
	add_child(_p2_hud)

	var p2_strip := _make_hud_strip(Color(0.3, 0.1, 0.1, 0.85), font, 1)
	# Position P2 HUD in the lower half
	p2_strip.set_anchors_preset(Control.PRESET_TOP_LEFT)
	p2_strip.offset_top = VIEWPORT_HEIGHT_EACH + STATUS_BAR_HEIGHT
	p2_strip.offset_bottom = VIEWPORT_HEIGHT_EACH + STATUS_BAR_HEIGHT + 48
	p2_strip.offset_right = VIEWPORT_WIDTH
	_p2_hud.add_child(p2_strip)
	var p2_label := p2_strip.get_node("PlayerLabel") as Label
	_refresh_hud_label(1, p2_label)
	_player_worlds[1].hp_changed.connect(func(_hp: int) -> void: _refresh_hud_label(1, p2_label))
	_player_worlds[1].selected_item_changed.connect(func(_item: Resource) -> void: _refresh_hud_label(1, p2_label))

	# Shared status bar in the center divider
	_shared_hud = CanvasLayer.new()
	_shared_hud.layer = 10
	add_child(_shared_hud)

	var status_bg := ColorRect.new()
	status_bg.color = Color(0.05, 0.05, 0.05, 0.95)
	status_bg.set_anchors_preset(Control.PRESET_TOP_LEFT)
	status_bg.offset_left = 0
	status_bg.offset_top = VIEWPORT_HEIGHT_EACH
	status_bg.offset_right = VIEWPORT_WIDTH
	status_bg.offset_bottom = VIEWPORT_HEIGHT_EACH + STATUS_BAR_HEIGHT
	status_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shared_hud.add_child(status_bg)

	var status_label := Label.new()
	status_label.name = "StatusLabel"
	status_label.text = "PREP PHASE"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	status_label.offset_left = 0
	status_label.offset_top = VIEWPORT_HEIGHT_EACH + 4
	status_label.offset_right = VIEWPORT_WIDTH
	status_label.offset_bottom = VIEWPORT_HEIGHT_EACH + STATUS_BAR_HEIGHT
	if font:
		status_label.add_theme_font_override("font", font)
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.add_theme_color_override("font_color", Color.WHITE)
	_shared_hud.add_child(status_label)

func _make_hud_strip(color: Color, font: FontFile, player_index: int) -> ColorRect:
	var strip := ColorRect.new()
	strip.color = color
	strip.set_anchors_preset(Control.PRESET_TOP_LEFT)
	strip.offset_left = 0
	strip.offset_top = 0
	strip.offset_right = VIEWPORT_WIDTH
	strip.offset_bottom = 48
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
		shop.viewport_top = i * (VIEWPORT_HEIGHT_EACH + STATUS_BAR_HEIGHT)
		shop.layer = 15 + i
		add_child(shop)
		_shop_uis.append(shop)

	# PVE: add AI for P2
	if GameManager.current_mode == GameManager.GameMode.PVE:
		var ai: Node = load("res://systems/SimpleAI.gd").new()
		ai.player_world = _player_worlds[1]
		add_child(ai)

func _process(_delta: float) -> void:
	if GameManager.current_state == GameManager.GameState.PREP:
		_handle_prep_input()
		_update_prep_status()

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
	status_label.text = "PREP  %ds  |  P1:%s%s" % [t, s0, right]

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
