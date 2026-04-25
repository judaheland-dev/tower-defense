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
var _info_labels: Array[HBoxContainer] = []  # army/defense info container per player
var _icon_cache: Dictionary = {}  # model_path -> ImageTexture (pre-rendered 3D icons)
var _music_prep: AudioStream = null
var _music_battle: AudioStream = null
var _pause_overlay: CanvasLayer = null
var _game_over_overlay: CanvasLayer = null
var _pause_buttons: Array[Button] = []
var _pause_focused_idx: int = 0

func _ready() -> void:
	_load_music()
	_build_world()
	_build_huds()
	await _prerender_item_icons()
	_build_round_manager()

	GameManager.state_changed.connect(_on_state_changed)
	GameManager.overlay_navigate.connect(_on_overlay_navigate)
	GameManager.overlay_confirm.connect(_on_overlay_confirm)

func _load_music() -> void:
	var prep_path := "res://assets/audio/music_prep.ogg"
	var battle_path := "res://assets/audio/music_battle.ogg"
	if ResourceLoader.exists(prep_path):
		_music_prep = load(prep_path)
	if ResourceLoader.exists(battle_path):
		_music_battle = load(battle_path)

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

	_build_surrounding_terrain()

func _build_surrounding_terrain() -> void:
	# Fill the visible area outside the play board with natural terrain tiles
	# Board occupies X=[0,44], Z=[-14,14] in world space
	# Camera visible area roughly X=[-4,48], Z=[-20,20] at Y=0
	const TD_BASE := "res://assets/models/tower-defense-kit/"
	var tile_paths: Array[String] = [
		TD_BASE + "tile.glb",
		TD_BASE + "tile-tree.glb",
		TD_BASE + "tile-tree-double.glb",
		TD_BASE + "tile-tree-quad.glb",
		TD_BASE + "tile-hill.glb",
		TD_BASE + "tile-rock.glb",
	]
	# Weights: 60% plain, 10% tree, 7% tree-double, 3% tree-quad, 15% hill, 5% rock
	var weights: Array[float] = [0.60, 0.70, 0.77, 0.80, 0.95, 1.0]

	# Preload available scenes
	var scenes: Array = []
	for p in tile_paths:
		if ResourceLoader.exists(p):
			scenes.append(load(p))
		else:
			scenes.append(null)

	# Need at least the base tile
	if scenes[0] == null:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = 42

	var cell := 2.0  # CELL_SIZE
	# Exclusion zone slightly inset from board edges so terrain tiles tuck under
	# the outermost board tiles, eliminating visible seams
	var board_x_min := 1.0
	var board_x_max := 43.0
	var board_z_min := -13.0
	var board_z_max := 13.0

	var terrain_root := Node3D.new()
	terrain_root.name = "SurroundingTerrain"
	_world_root.add_child(terrain_root)

	# Cover a generous area around the board
	var x_start := -10.0
	var x_end := 54.0
	var z_start := -24.0
	var z_end := 24.0

	var x := x_start
	while x < x_end:
		var z := z_start
		while z < z_end:
			# Skip cells that overlap the play board
			if x >= board_x_min and x < board_x_max and z >= board_z_min and z < board_z_max:
				z += cell
				continue
			# Skip P1 town area (behind left gate)
			if x < 0.0 and x >= -10.0 and z >= -13.0 and z < 13.0:
				z += cell
				continue
			# Skip P2 town area (behind right gate)
			if x >= 44.0 and x < 54.0 and z >= -13.0 and z < 13.0:
				z += cell
				continue

			var roll := rng.randf()
			var idx := 0
			for i in weights.size():
				if roll <= weights[i]:
					idx = i
					break

			var scene: PackedScene = scenes[idx] if scenes[idx] != null else scenes[0]
			var inst := scene.instantiate()
			inst.scale = Vector3.ONE * cell
			inst.position = Vector3(x + cell * 0.5, -0.05, z + cell * 0.5)
			# Random Y rotation for variety (0, 90, 180, 270 degrees)
			inst.rotation.y = rng.randi_range(0, 3) * PI * 0.5
			terrain_root.add_child(inst)

			z += cell
		x += cell

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
	_shared_hud.process_mode = Node.PROCESS_MODE_ALWAYS
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
	_p1_hud.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_p1_hud)

	var p1_strip := _make_hud_strip(Color(0.1, 0.15, 0.3, 0.85), font, 0, 0, 1080 - HUD_STRIP_HEIGHT)
	_p1_hud.add_child(p1_strip)
	var p1_label := p1_strip.get_node("PlayerLabel") as Label
	_refresh_hud_label(0, p1_label)
	_player_worlds[0].hp_changed.connect(func(_hp: int) -> void: _refresh_hud_label(0, p1_label))
	_player_worlds[0].selected_item_changed.connect(func(_item: Resource) -> void: _refresh_hud_label(0, p1_label))

	var p1_info := _make_info_strip(Color(0.08, 0.12, 0.25, 0.80), font, 0, 0, 1080 - HUD_STRIP_HEIGHT - 28)
	_p1_hud.add_child(p1_info)

	# P2 HUD strip - bottom-right corner
	_p2_hud = CanvasLayer.new()
	_p2_hud.layer = 2
	_p2_hud.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_p2_hud)

	var p2_strip := _make_hud_strip(Color(0.3, 0.1, 0.1, 0.85), font, 1, 960, 1080 - HUD_STRIP_HEIGHT)
	_p2_hud.add_child(p2_strip)
	var p2_label := p2_strip.get_node("PlayerLabel") as Label
	_refresh_hud_label(1, p2_label)
	_player_worlds[1].hp_changed.connect(func(_hp: int) -> void: _refresh_hud_label(1, p2_label))
	_player_worlds[1].selected_item_changed.connect(func(_item: Resource) -> void: _refresh_hud_label(1, p2_label))

	var p2_info := _make_info_strip(Color(0.25, 0.08, 0.08, 0.80), font, 1, 960, 1080 - HUD_STRIP_HEIGHT - 28)
	_p2_hud.add_child(p2_info)

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

func _make_info_strip(color: Color, font: FontFile, player_index: int, x_offset: int, y_offset: int) -> ColorRect:
	var strip := ColorRect.new()
	strip.color = color
	strip.set_anchors_preset(Control.PRESET_TOP_LEFT)
	strip.offset_left = x_offset
	strip.offset_top = y_offset
	strip.offset_right = x_offset + 960
	strip.offset_bottom = y_offset + 28
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var hbox := HBoxContainer.new()
	hbox.name = "InfoContainer"
	hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 12
	hbox.offset_right = -12
	hbox.add_theme_constant_override("separation", 6)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_child(hbox)

	# Store for later refresh
	while _info_labels.size() <= player_index:
		_info_labels.append(null)
	_info_labels[player_index] = hbox

	# Connect signals for live updates
	var world := _player_worlds[player_index]
	world.mob_queue_changed.connect(func() -> void: _refresh_info_label(player_index))
	world.tower_changed.connect(func() -> void: _refresh_info_label(player_index))
	world.trap_changed.connect(func() -> void: _refresh_info_label(player_index))
	EconomyManager.coins_changed.connect(
		func(idx: int, _amount: int) -> void:
			if idx == player_index:
				_refresh_info_label(player_index)
	)

	_refresh_info_label(player_index)
	return strip

func _refresh_info_label(player_index: int) -> void:
	if player_index >= _info_labels.size() or _info_labels[player_index] == null:
		return
	var hbox: HBoxContainer = _info_labels[player_index]
	var world := _player_worlds[player_index]
	var font := GameManager.kenney_font()

	# Clear previous children
	for child in hbox.get_children():
		child.queue_free()

	var mob_counts: Dictionary = world.call("get_queued_mob_counts")
	var tower_counts: Dictionary = world.call("get_tower_counts")
	var trap_counts: Dictionary = world.call("get_trap_counts")

	if not mob_counts.is_empty():
		var army_label := Label.new()
		army_label.text = "Army:"
		if font:
			army_label.add_theme_font_override("font", font)
		army_label.add_theme_font_size_override("font_size", 12)
		army_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.5))
		army_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(army_label)
		for mob_name in mob_counts:
			var info: Dictionary = mob_counts[mob_name]
			_add_icon_count(hbox, info, mob_name, font)

	if not mob_counts.is_empty() and not tower_counts.is_empty():
		var sep := Label.new()
		sep.text = "|"
		sep.add_theme_font_size_override("font_size", 12)
		sep.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(sep)

	if not tower_counts.is_empty():
		var tower_label := Label.new()
		tower_label.text = "Towers:"
		if font:
			tower_label.add_theme_font_override("font", font)
		tower_label.add_theme_font_size_override("font_size", 12)
		tower_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
		tower_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(tower_label)
		for tower_name in tower_counts:
			var info: Dictionary = tower_counts[tower_name]
			_add_icon_count(hbox, info, tower_name, font)

	if not trap_counts.is_empty():
		if not tower_counts.is_empty() or not mob_counts.is_empty():
			var sep2 := Label.new()
			sep2.text = "|"
			sep2.add_theme_font_size_override("font_size", 12)
			sep2.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			sep2.mouse_filter = Control.MOUSE_FILTER_IGNORE
			hbox.add_child(sep2)
		var trap_label := Label.new()
		trap_label.text = "Traps:"
		if font:
			trap_label.add_theme_font_override("font", font)
		trap_label.add_theme_font_size_override("font_size", 12)
		trap_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.4))
		trap_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(trap_label)
		for trap_name in trap_counts:
			var info: Dictionary = trap_counts[trap_name]
			_add_icon_count(hbox, info, trap_name, font)

func _add_icon_count(hbox: HBoxContainer, info: Dictionary, item_name: String, font: FontFile) -> void:
	var model_path: String = info.get("model_path", "")
	var texture_path: String = info.get("texture_path", "")
	var icon := _make_mini_icon(info["color"], 18, model_path, texture_path)
	hbox.add_child(icon)

	var lbl := Label.new()
	lbl.text = "%s x%d" % [item_name, info["count"]]
	if font:
		lbl.add_theme_font_override("font", font)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(lbl)

func _make_mini_icon(color: Color, size: int, model_path: String = "", texture_path: String = "") -> TextureRect:
	var rect := TextureRect.new()
	rect.custom_minimum_size = Vector2(size, size)
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if texture_path != "" and ResourceLoader.exists(texture_path):
		rect.texture = load(texture_path)
		rect.self_modulate = color
	elif model_path != "" and _icon_cache.has(model_path):
		rect.texture = _icon_cache[model_path]
		rect.self_modulate = color
	else:
		# Fallback: colored square
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var border := Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, 1.0)
		for y in size:
			for x in size:
				if x == 0 or y == 0 or x == size - 1 or y == size - 1:
					img.set_pixel(x, y, border)
				else:
					img.set_pixel(x, y, color)
		rect.texture = ImageTexture.create_from_image(img)
	return rect

func _prerender_item_icons() -> void:
	var item_paths := [
		"res://resources/towers/wall_basic.tres",
		"res://resources/towers/tower_arrow.tres",
		"res://resources/towers/tower_cannon.tres",
		"res://resources/towers/tower_slow.tres",
		"res://resources/towers/tower_sniper.tres",
		"res://resources/towers/tower_tesla.tres",
		"res://resources/towers/tower_mortar.tres",
		"res://resources/towers/tower_poison.tres",
		"res://resources/towers/tower_buff.tres",
		"res://resources/towers/tower_antiair.tres",
		"res://resources/mobs/mob_basic.tres",
		"res://resources/mobs/mob_armored.tres",
		"res://resources/mobs/mob_fast.tres",
		"res://resources/mobs/mob_healer.tres",
		"res://resources/mobs/mob_flying.tres",
		"res://resources/mobs/mob_saboteur.tres",
		"res://resources/mobs/mob_swarm.tres",
		"res://resources/mobs/mob_siege.tres",
		"res://resources/mobs/mob_breacher.tres",
		"res://resources/traps/trap_mud.tres",
		"res://resources/traps/trap_spike_pit.tres",
		"res://resources/traps/trap_tar_pit.tres",
		"res://resources/traps/trap_lava.tres",
		"res://resources/traps/trap_poison_bog.tres",
		"res://resources/traps/trap_amplifier.tres",
		"res://resources/traps/trap_gold_mine.tres",
	]

	var unique_models: Dictionary = {}  # model_path -> render_scale (float)
	for path in item_paths:
		if not ResourceLoader.exists(path):
			continue
		var item: Resource = load(path)
		var model_path: String = item.get("model_path") if item.get("model_path") else ""
		var model_scale: float = item.get("model_scale") if item.get("model_scale") != null else 1.0
		if model_path != "" and ResourceLoader.exists(model_path):
			# Keep the largest scale if multiple items share a model
			if not unique_models.has(model_path) or model_scale > unique_models[model_path]:
				unique_models[model_path] = model_scale

	if unique_models.is_empty():
		return

	# Temporary SubViewport for rendering model icons
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128, 128)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	add_child(viewport)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.5
	cam.position = Vector3(1.5, 2.0, 1.5)
	viewport.add_child(cam)
	cam.look_at(Vector3(0.0, 0.5, 0.0), Vector3.UP)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, 45.0, 0.0)
	light.light_energy = 1.5
	viewport.add_child(light)

	var env_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.7, 0.7, 0.7)
	environment.ambient_light_energy = 0.8
	env_node.environment = environment
	viewport.add_child(env_node)

	# Wall (model_scale=1.8) looks correct at cam size 2.5.
	# Scale other models relative to the wall so they fill the frame similarly.
	var reference_scale := 1.8

	for model_path in unique_models:
		var render_scale: float = unique_models[model_path]
		var scene: PackedScene = load(model_path)
		var inst := scene.instantiate()
		# Scale the model so it fills the viewport like the wall does
		var scale_factor := render_scale / reference_scale
		inst.scale = Vector3.ONE * scale_factor
		viewport.add_child(inst)

		# Wait 2 frames for the viewport to render the model
		await get_tree().process_frame
		await get_tree().process_frame

		var img := viewport.get_texture().get_image()
		_icon_cache[model_path] = ImageTexture.create_from_image(img)

		viewport.remove_child(inst)
		inst.queue_free()

	viewport.queue_free()

func _build_round_manager() -> void:
	_round_manager = load("res://systems/RoundManager.gd").new()
	_round_manager.player_worlds = _player_worlds
	add_child(_round_manager)

	# Shop UI - only human players get a shop panel (half-screen per player)
	var human_players := 1 if GameManager.current_mode == GameManager.GameMode.PVE else 2
	for i in human_players:
		var shop: CanvasLayer = load("res://scenes/game/ShopUI.gd").new()
		shop.player_index = i
		shop.player_world = _player_worlds[i]
		shop.icon_cache = _icon_cache
		# P1 shop covers left half, P2 shop covers right half
		shop.viewport_top = STATUS_BAR_HEIGHT
		shop.viewport_left = 0 if i == 0 else 960
		shop.layer = 15 + i
		add_child(shop)
		_shop_uis.append(shop)

	# PVE: add AI for P2
	if GameManager.current_mode == GameManager.GameMode.PVE:
		var ai: Node = load("res://systems/SimpleAI.gd").new()
		ai.player_world = _player_worlds[1]
		ai.opponent_world = _player_worlds[0]
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
		if InputManager.is_shop_pressed(i):
			_shop_uis[i].call("toggle")
			return
	# Ready-up: cancel while no item selected and shop closed
	var human_players := 1 if GameManager.current_mode == GameManager.GameMode.PVE else 2
	for i in human_players:
		if InputManager.is_cancel_pressed(i):
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
			if _music_prep:
				AudioManager.crossfade_music(_music_prep)
		GameManager.GameState.PLAY:
			if status_label:
				status_label.text = "BATTLE PHASE"
			if _music_battle:
				AudioManager.crossfade_music(_music_battle)
		GameManager.GameState.ROUND_OVER:
			if status_label:
				status_label.text = "ROUND OVER"
		GameManager.GameState.PAUSED:
			_show_pause_overlay()
		GameManager.GameState.GAME_OVER:
			AudioManager.fade_out_music(2.0)
			_show_game_over()
	# Hide pause overlay when leaving paused state
	if new_state != GameManager.GameState.PAUSED:
		_hide_pause_overlay()

# ---------- pause overlay ----------

func _show_pause_overlay() -> void:
	if _pause_overlay != null:
		return
	var font := GameManager.kenney_font()

	_pause_overlay = CanvasLayer.new()
	_pause_overlay.layer = 20
	_pause_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_pause_overlay)

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_overlay.add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.custom_minimum_size = Vector2(300, 200)
	vbox.offset_left = -150
	vbox.offset_top = -100
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	_pause_overlay.add_child(vbox)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if font:
		title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	vbox.add_child(title)

	var btn_resume := _make_overlay_button("Resume", font)
	btn_resume.pressed.connect(_on_resume_pressed)
	vbox.add_child(btn_resume)

	var btn_quit := _make_overlay_button("Quit to Menu", font)
	btn_quit.pressed.connect(_on_quit_to_menu_pressed)
	vbox.add_child(btn_quit)

	_pause_buttons = [btn_resume, btn_quit]
	_pause_focused_idx = 0
	_update_pause_focus()

func _hide_pause_overlay() -> void:
	if _pause_overlay != null:
		_pause_overlay.queue_free()
		_pause_overlay = null
		_pause_buttons.clear()

func _update_pause_focus() -> void:
	for i in _pause_buttons.size():
		var btn := _pause_buttons[i]
		if i == _pause_focused_idx:
			var style := StyleBoxFlat.new()
			style.bg_color = Color(1.0, 0.85, 0.2, 0.2)
			style.border_color = Color(1.0, 0.85, 0.2, 0.9)
			style.set_border_width_all(3)
			style.set_corner_radius_all(4)
			btn.add_theme_stylebox_override("normal", style)
		else:
			btn.remove_theme_stylebox_override("normal")

func _on_overlay_navigate(direction: int) -> void:
	if GameManager.current_state == GameManager.GameState.PAUSED and _pause_buttons.size() > 0:
		var new_idx := clampi(_pause_focused_idx + direction, 0, _pause_buttons.size() - 1)
		if new_idx != _pause_focused_idx:
			_pause_focused_idx = new_idx
			_update_pause_focus()

func _on_overlay_confirm() -> void:
	if GameManager.current_state == GameManager.GameState.PAUSED and _pause_focused_idx < _pause_buttons.size():
		_pause_buttons[_pause_focused_idx].emit_signal("pressed")
	elif GameManager.current_state == GameManager.GameState.GAME_OVER:
		AudioManager.play_ui_click()
		get_tree().paused = false
		GameManager.go_to_main_menu()

func _on_resume_pressed() -> void:
	AudioManager.play_ui_click()
	GameManager.set_state(GameManager._pre_pause_state)
	get_tree().paused = false

func _on_quit_to_menu_pressed() -> void:
	AudioManager.play_ui_click()
	get_tree().paused = false
	GameManager.go_to_main_menu()

# ---------- game over overlay ----------

func _show_game_over() -> void:
	if _game_over_overlay != null:
		return
	var font := GameManager.kenney_font()

	_game_over_overlay = CanvasLayer.new()
	_game_over_overlay.layer = 25
	_game_over_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_game_over_overlay)

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.75)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_game_over_overlay.add_child(bg)

	# Determine winner/loser based on HP
	var p1_hp: int = _player_worlds[0].current_hp if _player_worlds.size() > 0 else 0
	var p2_hp: int = _player_worlds[1].current_hp if _player_worlds.size() > 1 else 0
	var p1_won := p1_hp > p2_hp
	var p2_won := p2_hp > p1_hp

	# Left half - P1 result label
	var p1_label := Label.new()
	p1_label.text = "VICTORY" if p1_won else "DEFEAT"
	p1_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p1_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if font:
		p1_label.add_theme_font_override("font", font)
	p1_label.add_theme_font_size_override("font_size", 64)
	p1_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3) if p1_won else Color(1.0, 0.25, 0.2))
	p1_label.anchor_left = 0.0
	p1_label.anchor_right = 0.5
	p1_label.anchor_top = 0.0
	p1_label.anchor_bottom = 0.5
	p1_label.offset_left = 0
	p1_label.offset_right = 0
	p1_label.offset_top = 0
	p1_label.offset_bottom = 0
	p1_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_game_over_overlay.add_child(p1_label)

	# Right half - P2 result label
	var p2_label := Label.new()
	p2_label.text = "VICTORY" if p2_won else "DEFEAT"
	p2_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p2_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if font:
		p2_label.add_theme_font_override("font", font)
	p2_label.add_theme_font_size_override("font_size", 64)
	p2_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3) if p2_won else Color(1.0, 0.25, 0.2))
	p2_label.anchor_left = 0.5
	p2_label.anchor_right = 1.0
	p2_label.anchor_top = 0.0
	p2_label.anchor_bottom = 0.5
	p2_label.offset_left = 0
	p2_label.offset_right = 0
	p2_label.offset_top = 0
	p2_label.offset_bottom = 0
	p2_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_game_over_overlay.add_child(p2_label)

	# Centered button below
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.custom_minimum_size = Vector2(400, 80)
	vbox.offset_left = -200
	vbox.offset_top = 60
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_game_over_overlay.add_child(vbox)

	var btn_menu := _make_overlay_button("Return to Menu", font)
	btn_menu.pressed.connect(func() -> void:
		AudioManager.play_ui_click()
		get_tree().paused = false
		GameManager.go_to_main_menu()
	)
	vbox.add_child(btn_menu)

	# Highlight the button (single button, always selected)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1.0, 0.85, 0.2, 0.2)
	style.border_color = Color(1.0, 0.85, 0.2, 0.9)
	style.set_border_width_all(3)
	style.set_corner_radius_all(4)
	btn_menu.add_theme_stylebox_override("normal", style)

# ---------- shared overlay button helper ----------

func _make_overlay_button(text: String, font: FontFile) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(280, 48)
	btn.process_mode = Node.PROCESS_MODE_ALWAYS
	if font:
		btn.add_theme_font_override("font", font)
	btn.add_theme_font_size_override("font_size", 22)
	return btn
