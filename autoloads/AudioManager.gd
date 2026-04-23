extends Node

## AudioManager - music and pooled SFX (16 slots).
## Falls back to procedurally generated tones when .ogg files are missing.

const MUSIC_BUS: StringName = &"Master"
const SFX_BUS: StringName = &"Master"
const SFX_POOL_SIZE: int = 16

var _music_player: AudioStreamPlayer = null
var _music_loop: bool = false
var _sfx_pool: Array[AudioStreamPlayer] = []
var _proc_cache: Dictionary = {}

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

	# Pre-generate procedural fallback SFX
	_proc_cache["sfx_shoot"]    = _gen_proc("shoot")
	_proc_cache["sfx_cannon"]   = _gen_proc("cannon")
	_proc_cache["sfx_death"]    = _gen_proc("death")
	_proc_cache["sfx_place"]    = _gen_proc("place")
	_proc_cache["sfx_impact"]   = _gen_proc("impact")
	_proc_cache["sfx_click"]    = _gen_proc("click")
	_proc_cache["sfx_explosion"]= _gen_proc("cannon")

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
	_sfx_pool[0].stream = stream
	_sfx_pool[0].volume_db = volume_db
	_sfx_pool[0].pitch_scale = pitch_scale
	_sfx_pool[0].play()

# Use this everywhere instead of checking ResourceLoader manually.
# Falls back to procedural audio when the .ogg file doesn't exist.
func play_sfx_path(path: String, volume_db: float = 0.0, pitch_scale: float = 1.0) -> void:
	if ResourceLoader.exists(path):
		play_sfx(load(path), volume_db, pitch_scale)
		return
	var key := path.get_file().get_basename()
	if _proc_cache.has(key):
		play_sfx(_proc_cache[key], volume_db, pitch_scale)

func play_ui_click() -> void:
	play_sfx_path("res://assets/audio/sfx_click.ogg", -4.0, 1.2)

# ---------- procedural SFX generator ----------
# Generates a simple AudioStreamWAV from PCM samples at 22050 Hz, 8-bit unsigned.

func _gen_proc(type: String) -> AudioStreamWAV:
	const RATE := 22050
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	var data := PackedByteArray()

	match type:
		"shoot":
			# Short high-pitched chirp descending in pitch
			var dur := 0.07
			var n := int(RATE * dur)
			for i in n:
				var t := float(i) / RATE
				var env := 1.0 - (t / dur)
				var freq := 1400.0 - t * 8000.0
				var v := sin(t * TAU * maxf(freq, 200.0)) * env * 0.55
				data.append(clampi(int(v * 127) + 128, 0, 255))
		"cannon":
			# Low boom with noise
			var dur := 0.30
			var n := int(RATE * dur)
			for i in n:
				var t := float(i) / RATE
				var env := exp(-t * 9.0)
				var noise := randf_range(-1.0, 1.0)
				var tone := sin(t * TAU * 70.0)
				var v := (noise * 0.55 + tone * 0.45) * env * 0.75
				data.append(clampi(int(v * 127) + 128, 0, 255))
		"death":
			# Descending "oof" tone
			var dur := 0.20
			var n := int(RATE * dur)
			for i in n:
				var t := float(i) / RATE
				var env := 1.0 - (t / dur)
				var freq := 500.0 - t * 900.0
				var v := sin(t * TAU * maxf(freq, 80.0)) * env * 0.5
				data.append(clampi(int(v * 127) + 128, 0, 255))
		"place":
			# Soft thump
			var dur := 0.10
			var n := int(RATE * dur)
			for i in n:
				var t := float(i) / RATE
				var env := exp(-t * 22.0)
				var v := sin(t * TAU * 350.0) * env * 0.5
				data.append(clampi(int(v * 127) + 128, 0, 255))
		"impact":
			# Mid thud - mob reaches exit
			var dur := 0.18
			var n := int(RATE * dur)
			for i in n:
				var t := float(i) / RATE
				var env := exp(-t * 12.0)
				var noise := randf_range(-1.0, 1.0)
				var v := (noise * 0.6 + sin(t * TAU * 140.0) * 0.4) * env * 0.7
				data.append(clampi(int(v * 127) + 128, 0, 255))
		"click":
			# Short tick
			var dur := 0.04
			var n := int(RATE * dur)
			for i in n:
				var t := float(i) / RATE
				var env := exp(-t * 50.0)
				var v := sin(t * TAU * 900.0) * env * 0.4
				data.append(clampi(int(v * 127) + 128, 0, 255))
		_:
			data.append(128)

	stream.data = data
	return stream
