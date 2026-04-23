extends Node

## MainMenu - title screen with PVP / PVE mode selection.
## Builds its own scene tree in code; no .tscn required.

func _ready() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 1
	canvas.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(canvas)

	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.12)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.custom_minimum_size = Vector2(400, 300)
	vbox.offset_left = -200
	vbox.offset_top = -150
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 24)
	canvas.add_child(vbox)

	var font := GameManager.kenney_font()

	var title := Label.new()
	title.text = "TOWER DEFENSE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if font:
		title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "PVP / PVE"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if font:
		subtitle.add_theme_font_override("font", font)
	subtitle.add_theme_font_size_override("font_size", 24)
	subtitle.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(spacer)

	var btn_pvp := _make_button("2 Players (PVP)", font)
	btn_pvp.pressed.connect(_on_pvp_pressed)
	vbox.add_child(btn_pvp)

	var btn_pve := _make_button("vs AI (PVE)", font)
	btn_pve.pressed.connect(_on_pve_pressed)
	vbox.add_child(btn_pve)

	var btn_quit := _make_button("Quit", font)
	btn_quit.pressed.connect(_on_quit_pressed)
	vbox.add_child(btn_quit)

func _make_button(text: String, font: FontFile) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(320, 56)
	btn.process_mode = Node.PROCESS_MODE_ALWAYS
	if font:
		btn.add_theme_font_override("font", font)
	btn.add_theme_font_size_override("font_size", 22)
	return btn

func _on_pvp_pressed() -> void:
	AudioManager.play_ui_click()
	GameManager.start_game(GameManager.GameMode.PVP)

func _on_pve_pressed() -> void:
	AudioManager.play_ui_click()
	GameManager.start_game(GameManager.GameMode.PVE)

func _on_quit_pressed() -> void:
	AudioManager.play_ui_click()
	get_tree().quit()
