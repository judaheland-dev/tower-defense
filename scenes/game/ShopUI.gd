extends CanvasLayer

## ShopUI - prep phase shop panel for one player.
## Half-screen grid layout with card-style items. Opens on key press, closes on selection.

const HALF_WIDTH: int = 960
const GRID_COLS: int = 5
const CARD_W: int = 168
const CARD_H: int = 190
const ICON_SIZE: int = 96
const NAV_REPEAT_DELAY: float = 0.18

var player_index: int = 0
var player_world: Node = null
var viewport_top: int = 0
var viewport_left: int = 0

var _backdrop: ColorRect = null
var _panel: PanelContainer = null
var _scroll: ScrollContainer = null
var _coin_label: Label = null
var _is_visible: bool = false

# All shop items - loaded once
var _tower_items: Array[TowerData] = []
var _trap_items: Array[TrapData] = []
var _mob_items: Array[MobData] = []

# Sections: each section has a grid of buttons and a column count
# _sections[i] = { "buttons": Array[Button], "items": Array[Resource], "cols": int }
var _sections: Array[Dictionary] = []

# Flat parallel arrays for keyboard navigation (built from sections)
var _item_buttons: Array[Button] = []
var _all_items: Array[Resource] = []
var _focused_idx: int = 0
var _nav_timer: float = 0.0

# Pre-rendered 3D model icon textures, set by Game.gd before add_child
var icon_cache: Dictionary = {}

# Mob card tracking: MobData resource -> { "button": Button, "qty_label": Label }
var _mob_card_map: Dictionary = {}

# --- Focus style boxes ---
var _style_normal: StyleBoxFlat = null
var _style_focused: StyleBoxFlat = null
var _style_disabled: StyleBoxFlat = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_init_styles()
	_load_items()
	_build_ui()
	_set_panel_visible(false)

	GameManager.state_changed.connect(_on_state_changed)
	EconomyManager.coins_changed.connect(_on_coins_changed)

func _init_styles() -> void:
	_style_normal = StyleBoxFlat.new()
	_style_normal.bg_color = Color(0.15, 0.15, 0.2, 0.9)
	_style_normal.border_color = Color(0.4, 0.4, 0.5, 0.8)
	_style_normal.set_border_width_all(2)
	_style_normal.set_corner_radius_all(6)
	_style_normal.set_content_margin_all(6)

	_style_focused = StyleBoxFlat.new()
	_style_focused.bg_color = Color(0.2, 0.2, 0.1, 0.95)
	_style_focused.border_color = Color(1.0, 0.85, 0.2, 1.0)
	_style_focused.set_border_width_all(3)
	_style_focused.set_corner_radius_all(6)
	_style_focused.set_content_margin_all(6)

	_style_disabled = StyleBoxFlat.new()
	_style_disabled.bg_color = Color(0.1, 0.1, 0.1, 0.7)
	_style_disabled.border_color = Color(0.3, 0.3, 0.3, 0.5)
	_style_disabled.set_border_width_all(2)
	_style_disabled.set_corner_radius_all(6)
	_style_disabled.set_content_margin_all(6)

func _load_items() -> void:
	var tower_paths := [
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
	]
	for path in tower_paths:
		if ResourceLoader.exists(path):
			_tower_items.append(load(path))

	var trap_paths := [
		"res://resources/traps/trap_mud.tres",
		"res://resources/traps/trap_spike_pit.tres",
		"res://resources/traps/trap_tar_pit.tres",
		"res://resources/traps/trap_lava.tres",
		"res://resources/traps/trap_poison_bog.tres",
		"res://resources/traps/trap_amplifier.tres",
		"res://resources/traps/trap_gold_mine.tres",
	]
	for path in trap_paths:
		if ResourceLoader.exists(path):
			_trap_items.append(load(path))

	var mob_paths := [
		"res://resources/mobs/mob_basic.tres",
		"res://resources/mobs/mob_armored.tres",
		"res://resources/mobs/mob_fast.tres",
		"res://resources/mobs/mob_healer.tres",
		"res://resources/mobs/mob_flying.tres",
		"res://resources/mobs/mob_saboteur.tres",
		"res://resources/mobs/mob_swarm.tres",
		"res://resources/mobs/mob_siege.tres",
		"res://resources/mobs/mob_breacher.tres",
	]
	for path in mob_paths:
		if ResourceLoader.exists(path):
			_mob_items.append(load(path))

func _build_ui() -> void:
	var font := GameManager.kenney_font()

	# Semi-transparent backdrop covering this player's half
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0.0, 0.0, 0.0, 0.6)
	_backdrop.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_backdrop.offset_left = viewport_left
	_backdrop.offset_right = viewport_left + HALF_WIDTH
	_backdrop.offset_top = viewport_top
	_backdrop.offset_bottom = 1080
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)

	# Main panel
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var pad_x := 20
	var pad_top := viewport_top + 12
	_panel.offset_left = viewport_left + pad_x
	_panel.offset_right = viewport_left + HALF_WIDTH - pad_x
	_panel.offset_top = pad_top
	_panel.offset_bottom = 1080 - 12
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.08, 0.12, 0.95)
	panel_style.set_border_width_all(2)
	panel_style.border_color = Color(0.3, 0.3, 0.4, 0.8)
	panel_style.set_corner_radius_all(8)
	panel_style.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_panel)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel.add_child(_scroll)

	var main_vbox := VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_theme_constant_override("separation", 10)
	_scroll.add_child(main_vbox)

	# --- Header row: title + coins ---
	var header_hbox := HBoxContainer.new()
	header_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_vbox.add_child(header_hbox)

	var title := Label.new()
	title.text = "SHOP - Player %d" % (player_index + 1)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if font:
		title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_hbox.add_child(title)

	_coin_label = Label.new()
	_coin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if font:
		_coin_label.add_theme_font_override("font", font)
	_coin_label.add_theme_font_size_override("font_size", 20)
	_coin_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_coin_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_hbox.add_child(_coin_label)
	_update_coin_display()

	# --- Tower section ---
	_add_section_header(main_vbox, "TOWERS", Color(0.7, 0.85, 1.0), font)
	var tower_grid := _make_grid(GRID_COLS)
	main_vbox.add_child(tower_grid)
	var tower_btns: Array[Button] = []
	var tower_res: Array[Resource] = []
	for item in _tower_items:
		var btn := _make_card(item, font)
		tower_grid.add_child(btn)
		tower_btns.append(btn)
		tower_res.append(item)
		_item_buttons.append(btn)
		_all_items.append(item)
	_sections.append({"buttons": tower_btns, "items": tower_res, "cols": GRID_COLS})

	# --- Trap section ---
	_add_section_header(main_vbox, "TRAPS", Color(0.6, 0.8, 0.4), font)
	var trap_grid := _make_grid(GRID_COLS)
	main_vbox.add_child(trap_grid)
	var trap_btns: Array[Button] = []
	var trap_res: Array[Resource] = []
	for item in _trap_items:
		var btn := _make_card(item, font)
		trap_grid.add_child(btn)
		trap_btns.append(btn)
		trap_res.append(item)
		_item_buttons.append(btn)
		_all_items.append(item)
	_sections.append({"buttons": trap_btns, "items": trap_res, "cols": GRID_COLS})

	# --- Mob section ---
	_add_section_header(main_vbox, "SEND MOBS", Color(1.0, 0.75, 0.5), font)
	var mob_grid := _make_grid(GRID_COLS)
	main_vbox.add_child(mob_grid)
	var mob_btns: Array[Button] = []
	var mob_res: Array[Resource] = []
	for item in _mob_items:
		var btn := _make_card(item, font)
		mob_grid.add_child(btn)
		mob_btns.append(btn)
		mob_res.append(item)
		_item_buttons.append(btn)
		_all_items.append(item)
	_sections.append({"buttons": mob_btns, "items": mob_res, "cols": GRID_COLS})

func _add_section_header(parent: VBoxContainer, text: String, color: Color, font: FontFile) -> void:
	var lbl := Label.new()
	lbl.text = text
	if font:
		lbl.add_theme_font_override("font", font)
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", color)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(lbl)

func _make_grid(cols: int) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = cols
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return grid

func _make_card(item: Resource, font: FontFile) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(CARD_W, CARD_H)
	btn.process_mode = Node.PROCESS_MODE_ALWAYS
	btn.text = ""
	btn.add_theme_stylebox_override("normal", _style_normal)
	btn.add_theme_stylebox_override("hover", _style_normal)
	btn.add_theme_stylebox_override("pressed", _style_focused)
	btn.add_theme_stylebox_override("focus", _style_focused)
	btn.add_theme_stylebox_override("disabled", _style_disabled)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 2)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(vbox)

	# Icon (96x96)
	var icon := _make_item_icon(item, ICON_SIZE)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(icon)

	var name_str: String = item.get("display_name") if item.get("display_name") else "?"
	var cost_val: int = item.get("cost") if item.get("cost") != null else 0

	# Name
	var name_lbl := Label.new()
	name_lbl.text = name_str
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font:
		name_lbl.add_theme_font_override("font", font)
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 0.9))
	vbox.add_child(name_lbl)

	# Cost
	var cost_lbl := Label.new()
	cost_lbl.text = "%d coins" % cost_val
	cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font:
		cost_lbl.add_theme_font_override("font", font)
	cost_lbl.add_theme_font_size_override("font_size", 12)
	cost_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	vbox.add_child(cost_lbl)

	# Stat line
	var stat_text := _get_stat_line(item)
	if stat_text != "":
		var stat_lbl := Label.new()
		stat_lbl.text = stat_text
		stat_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stat_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if font:
			stat_lbl.add_theme_font_override("font", font)
		stat_lbl.add_theme_font_size_override("font_size", 11)
		stat_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
		vbox.add_child(stat_lbl)

	# Qty badge for mob cards (hidden for non-mobs)
	var qty_lbl := Label.new()
	qty_lbl.text = ""
	qty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	qty_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font:
		qty_lbl.add_theme_font_override("font", font)
	qty_lbl.add_theme_font_size_override("font_size", 14)
	qty_lbl.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
	qty_lbl.visible = false
	vbox.add_child(qty_lbl)

	if item is MobData:
		_mob_card_map[item] = {"button": btn, "qty_label": qty_lbl}
		btn.pressed.connect(func() -> void:
			_try_purchase_mob(item, btn)
		)
	else:
		btn.pressed.connect(func() -> void:
			if player_world:
				player_world.call("set_selected_item", item)
				AudioManager.play_ui_click()
			_set_panel_visible(false)
		)
	return btn

func _get_stat_line(item: Resource) -> String:
	if item is TowerData:
		var td: TowerData = item as TowerData
		if td.tower_type == TowerData.TowerType.WALL:
			return "HP: %d" % int(td.max_health)
		if td.tower_type == TowerData.TowerType.BUFF:
			return "DMG+%.0f  SPD+%.1f" % [td.buff_damage_bonus, td.buff_attack_speed_bonus]
		if td.tower_type == TowerData.TowerType.SLOW:
			return "Slow: %d%%  R: %.0f" % [int(td.slow_amount * 100), td.range_units]
		var dps := td.damage * td.attack_speed
		return "DPS: %.0f  R: %.0f" % [dps, td.range_units]
	if item is TrapData:
		var trap: TrapData = item as TrapData
		if trap.slow_amount > 0:
			return "Slow: %d%%" % int(trap.slow_amount * 100)
		if trap.damage_per_second > 0:
			return "DPS: %.0f" % trap.damage_per_second
		if trap.burst_damage > 0:
			return "DMG: %.0f" % trap.burst_damage
		if trap.damage_amplify > 0:
			return "Amp: +%d%%" % int(trap.damage_amplify * 100)
		if trap.income_per_round > 0:
			return "+%d/round" % trap.income_per_round
		return ""
	if item is MobData:
		var md: MobData = item as MobData
		var traits: Array[String] = []
		if md.is_flying:
			traits.append("Flying")
		if md.heals_nearby_allies:
			traits.append("Healer")
		if md.attacks_defenses:
			traits.append("Saboteur")
		if md.spawn_count > 1:
			traits.append("x%d" % md.spawn_count)
		if traits.size() > 0:
			return "HP:%d %s" % [int(md.max_health), " ".join(traits)]
		return "HP: %d  SPD: %.1f" % [int(md.max_health), md.move_speed]
	return ""

func _make_item_icon(item: Resource, size: int) -> TextureRect:
	var model_path: String = item.get("model_path") if item.get("model_path") else ""
	var texture_path: String = item.get("texture_path") if item.get("texture_path") else ""
	var color: Color = item.get("icon_color") if item.get("icon_color") != null else Color(0.5, 0.5, 0.5)
	var rect := TextureRect.new()
	rect.custom_minimum_size = Vector2(size, size)
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if texture_path != "" and ResourceLoader.exists(texture_path):
		rect.texture = load(texture_path)
		rect.self_modulate = color
	elif model_path != "" and icon_cache.has(model_path):
		rect.texture = icon_cache[model_path]
		rect.self_modulate = color
	else:
		# Fallback: colored square with border
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var border := Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, 1.0)
		var highlight := Color(minf(color.r + 0.3, 1.0), minf(color.g + 0.3, 1.0), minf(color.b + 0.3, 1.0), 1.0)
		for y in size:
			for x in size:
				if x == 0 or y == 0 or x == size - 1 or y == size - 1:
					img.set_pixel(x, y, border)
				elif x <= 2 or y <= 2:
					img.set_pixel(x, y, highlight)
				else:
					img.set_pixel(x, y, color)
		rect.texture = ImageTexture.create_from_image(img)
	return rect

# --- Visibility & State ---

func toggle() -> void:
	_set_panel_visible(not _is_visible)
	AudioManager.play_ui_click()

func is_shop_open() -> bool:
	return _is_visible

func _set_panel_visible(visible: bool) -> void:
	_is_visible = visible
	if _backdrop:
		_backdrop.visible = visible
	if _panel:
		_panel.visible = visible
	if player_world:
		player_world.shop_open = visible
	if visible:
		_focused_idx = 0
		_nav_timer = 0.0
		_update_coin_display()
		_update_mob_qty_labels()
		_update_focus_visual()

func _update_coin_display() -> void:
	if _coin_label and player_index < EconomyManager.coins.size():
		_coin_label.text = "Coins: %d" % EconomyManager.coins[player_index]

# --- Focus & Navigation ---

func _update_focus_visual() -> void:
	for i in _item_buttons.size():
		var btn: Button = _item_buttons[i]
		if btn.disabled:
			btn.add_theme_stylebox_override("normal", _style_disabled)
			btn.modulate = Color(0.5, 0.5, 0.5, 0.8)
		elif i == _focused_idx:
			btn.add_theme_stylebox_override("normal", _style_focused)
			btn.modulate = Color(1.0, 1.0, 1.0, 1.0)
		else:
			btn.add_theme_stylebox_override("normal", _style_normal)
			btn.modulate = Color(1.0, 1.0, 1.0, 1.0)

func _ensure_focused_visible() -> void:
	if not _scroll or _focused_idx >= _item_buttons.size():
		return
	var btn: Button = _item_buttons[_focused_idx]
	# Get button's top/bottom relative to the scroll container's content
	var btn_rect := btn.get_global_rect()
	var scroll_rect := _scroll.get_global_rect()
	var scroll_v := _scroll.scroll_vertical
	if btn_rect.position.y < scroll_rect.position.y:
		# Button is above visible area - scroll up
		_scroll.scroll_vertical = scroll_v - int(scroll_rect.position.y - btn_rect.position.y) - 8
	elif btn_rect.end.y > scroll_rect.end.y:
		# Button is below visible area - scroll down
		_scroll.scroll_vertical = scroll_v + int(btn_rect.end.y - scroll_rect.end.y) + 8

func _select_focused_item() -> void:
	if _focused_idx >= _item_buttons.size():
		return
	var btn: Button = _item_buttons[_focused_idx]
	if btn.disabled:
		return
	var item: Resource = _all_items[_focused_idx]
	if item is MobData:
		_try_purchase_mob(item, btn)
		return
	if player_world:
		player_world.call("set_selected_item", item)
		AudioManager.play_ui_click()
	_set_panel_visible(false)

## Convert flat index to (section_idx, local_row, local_col).
func _idx_to_grid(idx: int) -> Vector3i:
	var offset := 0
	for s in _sections.size():
		var sec: Dictionary = _sections[s]
		var count: int = (sec["buttons"] as Array).size()
		if idx < offset + count:
			var local := idx - offset
			var cols: int = sec["cols"]
			return Vector3i(s, local / cols, local % cols)
		offset += count
	return Vector3i(0, 0, 0)

## Convert (section_idx, local_row, local_col) back to flat index, clamped.
func _grid_to_idx(section: int, row: int, col: int) -> int:
	var offset := 0
	for s in _sections.size():
		var sec: Dictionary = _sections[s]
		var count: int = (sec["buttons"] as Array).size()
		if s == section:
			var cols: int = sec["cols"]
			var max_row := (count - 1) / cols
			row = clampi(row, 0, max_row)
			var row_start := row * cols
			var row_end := mini(row_start + cols, count) - 1
			col = clampi(col, 0, row_end - row_start)
			return offset + row * cols + col
		offset += count
	return 0

func _navigate(dir: Vector2) -> void:
	if _item_buttons.size() == 0:
		return
	var pos := _idx_to_grid(_focused_idx)
	var sec_idx := pos.x
	var row := pos.y
	var col := pos.z

	var dx := int(sign(dir.x))
	var dy := int(sign(dir.y))

	if dx != 0:
		# Horizontal movement within current section
		_focused_idx = _grid_to_idx(sec_idx, row, col + dx)
	elif dy != 0:
		# Vertical: try same section first
		var sec: Dictionary = _sections[sec_idx]
		var count: int = (sec["buttons"] as Array).size()
		var cols: int = sec["cols"]
		var max_row := (count - 1) / cols
		var new_row := row + dy
		if new_row >= 0 and new_row <= max_row:
			_focused_idx = _grid_to_idx(sec_idx, new_row, col)
		else:
			# Cross to adjacent section
			var new_sec := sec_idx + dy
			if new_sec >= 0 and new_sec < _sections.size():
				if dy > 0:
					# Enter top of next section, keep column
					_focused_idx = _grid_to_idx(new_sec, 0, col)
				else:
					# Enter bottom of previous section, keep column
					var prev_sec: Dictionary = _sections[new_sec]
					var prev_count: int = (prev_sec["buttons"] as Array).size()
					var prev_cols: int = prev_sec["cols"]
					var last_row := (prev_count - 1) / prev_cols
					_focused_idx = _grid_to_idx(new_sec, last_row, col)

	_focused_idx = clampi(_focused_idx, 0, _item_buttons.size() - 1)
	_update_focus_visual()
	_ensure_focused_visible()

func _process(delta: float) -> void:
	if GameManager.current_state != GameManager.GameState.PREP:
		_set_panel_visible(false)
		return
	if not _is_visible:
		return
	# Shop is open - handle navigation
	if InputManager.is_cancel_pressed(player_index):
		_set_panel_visible(false)
		return
	if InputManager.is_confirm_pressed(player_index):
		_select_focused_item()
		return
	var dir := InputManager.get_cursor_dir(player_index)
	if dir == Vector2.ZERO:
		_nav_timer = 0.0
	else:
		_nav_timer -= delta
		if _nav_timer <= 0.0:
			_nav_timer = NAV_REPEAT_DELAY
			_navigate(dir)

func _on_state_changed(new_state: GameManager.GameState) -> void:
	if new_state != GameManager.GameState.PREP:
		_set_panel_visible(false)

func _on_coins_changed(idx: int, _amount: int) -> void:
	if idx == player_index:
		_refresh_affordability()
		_update_coin_display()

func _refresh_affordability() -> void:
	var coins := EconomyManager.coins[player_index]
	for i in mini(_item_buttons.size(), _all_items.size()):
		var btn: Button = _item_buttons[i]
		var cost: int = _all_items[i].get("cost") if _all_items[i].get("cost") != null else 0
		btn.disabled = coins < cost
	_update_focus_visual()

# --- Mob instant-purchase from shop ---

func _try_purchase_mob(data: MobData, btn: Button) -> void:
	if not player_world:
		return
	if not EconomyManager.can_afford(player_index, data.cost):
		return
	EconomyManager.spend(player_index, data.cost)
	player_world.call("queue_mob", data)
	_flash_card(btn)
	_update_mob_qty_labels()

## Flash card green briefly on successful purchase.
func _flash_card(btn: Button) -> void:
	var tween := create_tween()
	tween.tween_property(btn, "modulate", Color(0.5, 1.5, 0.5, 1.0), 0.0)
	tween.tween_property(btn, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.25)

func _update_mob_qty_labels() -> void:
	if not player_world:
		return
	var counts: Dictionary = player_world.call("get_queued_mob_counts")
	for mob_data: MobData in _mob_card_map:
		var entry: Dictionary = _mob_card_map[mob_data]
		var qty_lbl: Label = entry["qty_label"]
		var mob_name: String = mob_data.display_name
		if counts.has(mob_name):
			var c: int = counts[mob_name]["count"]
			qty_lbl.text = "Queued: %d" % c
			qty_lbl.visible = true
		else:
			qty_lbl.text = ""
			qty_lbl.visible = false
