extends CanvasLayer

## ShopUI - prep phase shop panel for one player.
## Displays purchasable towers and mobs; connects to the PlayerWorld.

const PANEL_WIDTH: int = 360
const ITEM_HEIGHT: int = 72

var player_index: int = 0
var player_world: Node = null
var viewport_top: int = 0   # y-offset of this player's HUD strip in screen space
var viewport_left: int = 0  # x-offset of this player's viewport in screen space

var _panel: PanelContainer = null
var _item_list: VBoxContainer = null
var _is_visible: bool = false

# All shop items - loaded once
var _tower_items: Array[TowerData] = []
var _mob_items: Array[MobData] = []

# Flat parallel arrays for keyboard navigation
var _item_buttons: Array[Button] = []
var _all_items: Array[Resource] = []
var _focused_idx: int = 0
var _nav_timer: float = 0.0
const NAV_REPEAT_DELAY: float = 0.18

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_items()
	_build_ui()
	_set_panel_visible(false)

	GameManager.state_changed.connect(_on_state_changed)
	EconomyManager.coins_changed.connect(_on_coins_changed)

func _load_items() -> void:
	var tower_paths := [
		"res://resources/towers/wall_basic.tres",
		"res://resources/towers/tower_arrow.tres",
		"res://resources/towers/tower_cannon.tres",
		"res://resources/towers/tower_slow.tres",
	]
	for path in tower_paths:
		if ResourceLoader.exists(path):
			_tower_items.append(load(path))

	var mob_paths := [
		"res://resources/mobs/mob_basic.tres",
		"res://resources/mobs/mob_armored.tres",
		"res://resources/mobs/mob_fast.tres",
		"res://resources/mobs/mob_healer.tres",
	]
	for path in mob_paths:
		if ResourceLoader.exists(path):
			_mob_items.append(load(path))

func _build_ui() -> void:
	var font := GameManager.kenney_font()

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 600)
	# P1 panel on left edge, P2 panel on right edge
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.offset_left = viewport_left
	_panel.offset_right = viewport_left + PANEL_WIDTH
	_panel.offset_top = viewport_top + 48
	_panel.offset_bottom = viewport_top + 48 + 470
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(PANEL_WIDTH, 450)
	_panel.add_child(scroll)

	_item_list = VBoxContainer.new()
	_item_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_item_list)

	# Header
	var header := Label.new()
	header.text = "SHOP - Player %d" % (player_index + 1)
	if font:
		header.add_theme_font_override("font", font)
	header.add_theme_font_size_override("font_size", 18)
	_item_list.add_child(header)

	var sep := HSeparator.new()
	_item_list.add_child(sep)

	# Tower section
	var tower_label := Label.new()
	tower_label.text = "-- TOWERS --"
	if font:
		tower_label.add_theme_font_override("font", font)
	tower_label.add_theme_font_size_override("font_size", 14)
	tower_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	_item_list.add_child(tower_label)

	for item in _tower_items:
		_item_list.add_child(_make_item_button(item, font))

	var sep2 := HSeparator.new()
	_item_list.add_child(sep2)

	# Mob section
	var mob_label := Label.new()
	mob_label.text = "-- SEND MOBS --"
	if font:
		mob_label.add_theme_font_override("font", font)
	mob_label.add_theme_font_size_override("font_size", 14)
	mob_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.5))
	_item_list.add_child(mob_label)

	for item in _mob_items:
		_item_list.add_child(_make_item_button(item, font))

	# Build flat arrays parallel to _item_buttons
	for t in _tower_items:
		_all_items.append(t)
	for m in _mob_items:
		_all_items.append(m)

func _make_item_button(item: Resource, font: FontFile) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(PANEL_WIDTH - 20, ITEM_HEIGHT)
	btn.process_mode = Node.PROCESS_MODE_ALWAYS

	var name_str: String = item.get("display_name") if item.get("display_name") else "?"
	var cost: int = item.get("cost") if item.get("cost") != null else 0
	var desc: String = item.get("description") if item.get("description") else ""
	btn.text = "%s\n%d coins\n%s" % [name_str, cost, desc.left(40)]
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	if font:
		btn.add_theme_font_override("font", font)
	btn.add_theme_font_size_override("font_size", 14)

	btn.pressed.connect(func() -> void:
		if player_world:
			player_world.call("set_selected_item", item)
			AudioManager.play_ui_click()
		_set_panel_visible(false)
	)
	_item_buttons.append(btn)
	return btn

func toggle() -> void:
	_set_panel_visible(not _is_visible)
	AudioManager.play_ui_click()

func is_shop_open() -> bool:
	return _is_visible

func _set_panel_visible(visible: bool) -> void:
	_is_visible = visible
	if _panel:
		_panel.visible = visible
	if player_world:
		player_world.shop_open = visible
	if visible:
		_focused_idx = 0
		_nav_timer = 0.0
		_update_focus_visual()

func _update_focus_visual() -> void:
	for i in _item_buttons.size():
		var btn: Button = _item_buttons[i]
		if i == _focused_idx:
			btn.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2))
		else:
			btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))

func _select_focused_item() -> void:
	if _focused_idx >= _item_buttons.size():
		return
	var btn: Button = _item_buttons[_focused_idx]
	if btn.disabled:
		return
	var item: Resource = _all_items[_focused_idx]
	if player_world:
		player_world.call("set_selected_item", item)
		AudioManager.play_ui_click()
	_set_panel_visible(false)

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
			var new_idx := _focused_idx + int(sign(dir.y))
			_focused_idx = clampi(new_idx, 0, _item_buttons.size() - 1)
			_update_focus_visual()

func _on_state_changed(new_state: GameManager.GameState) -> void:
	if new_state != GameManager.GameState.PREP:
		_set_panel_visible(false)

func _on_coins_changed(idx: int, _amount: int) -> void:
	if idx == player_index:
		_refresh_affordability()

func _refresh_affordability() -> void:
	var coins := EconomyManager.coins[player_index]
	for i in mini(_item_buttons.size(), _all_items.size()):
		var btn: Button = _item_buttons[i]
		var cost: int = _all_items[i].get("cost") if _all_items[i].get("cost") != null else 0
		btn.disabled = coins < cost
