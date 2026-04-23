extends Node

## AudioManager - music and pooled SFX (16 slots).

const MUSIC_BUS: StringName = &"Master"
const SFX_BUS: StringName = &"Master"
const SFX_POOL_SIZE: int = 16

var _music_player: AudioStreamPlayer = null
var _music_loop: bool = false
var _sfx_pool: Array[AudioStreamPlayer] = []

func _ready() -> void:
	_music_player = AudioStreamPlayer.new()
	_music_player.bus = MUSIC_BUS
	add_child(_music_player)
	_music_player.finished.connect(_on_music_finished)

	for i in SFX_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = SFX_BUS
		add_child(p)
		_sfx_pool.append(p)

func play_music(stream: AudioStream, loop: bool = true) -> void:
	if _music_player.stream == stream and _music_player.playing:
		return
	_music_loop = loop
	_music_player.stream = stream
	_music_player.play()

func stop_music() -> void:
	_music_loop = false
	_music_player.stop()

func _on_music_finished() -> void:
	if _music_loop and _music_player.stream != null:
		_music_player.play()

func play_sfx(stream: AudioStream, volume_db: float = 0.0, pitch_scale: float = 1.0) -> void:
	if stream == null:
		return
	for p in _sfx_pool:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = pitch_scale
			p.play()
			return
	# All slots busy - overwrite oldest
	_sfx_pool[0].stream = stream
	_sfx_pool[0].volume_db = volume_db
	_sfx_pool[0].pitch_scale = pitch_scale
	_sfx_pool[0].play()

func play_ui_click() -> void:
	var path := "res://assets/audio/sfx_click.ogg"
	if ResourceLoader.exists(path):
		play_sfx(load(path), -4.0, 1.2)
