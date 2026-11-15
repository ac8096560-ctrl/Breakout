class_name AudioCapture extends RefCounted
## M-G GAME-AUDIO TAP — captures the game's real mixed output while recording.
##
## Godot has no "record what you hear" API, but it does expose the mixed audio
## of any bus through `AudioEffectCapture`. This class appends ONE capture
## effect to the Master bus for the duration of a recording, drains it into a
## 16-bit stereo WAV on disk, and removes the effect on stop. The approved
## AudioManager is not touched: its buses, its limiter, its volumes and its
## voices stay exactly as they are — the tap sits after them and only listens.
##
## Memory: the WAV is streamed to disk a block at a time (a few KB per frame),
## so the audio of a ten-minute recording costs no RAM.
##
## Placement: the effect is appended to Master, i.e. AFTER the limiter, so the
## recorded audio is exactly what the player hears (including the limiter's
## effect on stacked sounds).

const EFFECT := "BreakoutRecorderTap"
const BITS := 16
const MAX_SECONDS_BEFORE_STOP := 3600.0   # a stuck recording cannot fill the disk

var ok := false
var err := ""
var path := ""
var rate := 44100
var channels := 2
var frames_written := 0
var dropped_blocks := 0

var _capture: AudioEffectCapture = null
var _bus := -1
var _effect_index := -1
var _file: FileAccess = null
var _peak := 0.0


## Start tapping. Returns true when the effect is in place and the WAV is open.
func start(wav_path: String) -> bool:
	if not ClassDB.class_exists("AudioEffectCapture"):
		err = "this Godot build has no AudioEffectCapture, so the game's audio cannot be captured"
		return false
	if DisplayServer.get_name() == "headless":
		# Headless has a dummy audio driver: there is nothing to record.
		err = "the headless renderer has no audio output to capture"
		return false
	_bus = AudioServer.get_bus_index("Master")
	if _bus < 0:
		err = "the Master audio bus is missing"
		return false
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = 2.0
	AudioServer.add_bus_effect(_bus, _capture)
	_effect_index = AudioServer.get_bus_effect_count(_bus) - 1
	rate = int(AudioServer.get_mix_rate())
	if rate <= 0:
		rate = 44100
	channels = 2
	path = wav_path
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		err = "the audio file could not be opened: " + path
		_detach()
		return false
	frames_written = 0
	dropped_blocks = 0
	_peak = 0.0
	_write_header(0)
	if _capture != null:
		_capture.clear_buffer()
	ok = true
	return true


## Pull everything the tap has buffered into the WAV. Called once per rendered
## frame; the effect only holds ~2 s, so a stall is the only way to lose audio.
func drain() -> void:
	if not ok or _file == null or _capture == null:
		return
	var avail := _capture.get_frames_available()
	if avail <= 0:
		return
	var buf: PackedVector2Array = _capture.get_buffer(avail)
	if buf.is_empty():
		return
	var pcm := PackedByteArray()
	pcm.resize(buf.size() * channels * 2)
	var o := 0
	for i in buf.size():
		var v: Vector2 = buf[i]
		var l := int(clampf(v.x, -1.0, 1.0) * 32767.0)
		var r := int(clampf(v.y, -1.0, 1.0) * 32767.0)
		pcm.encode_s16(o, l)
		pcm.encode_s16(o + 2, r)
		o += 4
		var a := maxf(absf(v.x), absf(v.y))
		if a > _peak:
			_peak = a
	_file.store_buffer(pcm)
	frames_written += buf.size()


## Drop what is buffered without writing it (a paused game has no video either,
## so keeping the pause in the audio would desynchronise the two timelines).
func discard() -> void:
	if _capture != null:
		_capture.clear_buffer()


func seconds() -> float:
	return float(frames_written) / float(maxi(1, rate))


func peak() -> float:
	return _peak


## Close the WAV, patch its header with the real sizes and remove the tap.
## Returns {ok, path, seconds, rate, channels, bytes, peak, err}.
func stop() -> Dictionary:
	if _file == null:
		return {"ok": false, "path": path, "seconds": 0.0, "rate": rate,
			"channels": channels, "bytes": 0, "peak": _peak,
			"err": err if err != "" else "the audio tap was never started"}
	drain()
	var data_bytes := frames_written * channels * (BITS / 8)
	_file.flush()
	_file.close()
	_file = null
	_detach()
	_patch_header(data_bytes)
	var res := {"ok": frames_written > 0, "path": path, "seconds": seconds(),
		"rate": rate, "channels": channels, "bytes": data_bytes, "peak": _peak,
		"err": "" if frames_written > 0 else "no audio was captured"}
	if not res["ok"]:
		# Never hand a zero-length WAV to the encoder.
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	return res


## Abandon the tap without keeping the file.
func abort() -> void:
	if _file != null:
		_file.close()
		_file = null
	_detach()
	ok = false
	if path != "" and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _detach() -> void:
	ok = false
	if _capture != null and _bus >= 0:
		# Remove by index: the effect list is short and the tap is the last one.
		for i in AudioServer.get_bus_effect_count(_bus):
			if AudioServer.get_bus_effect(_bus, i) == _capture:
				AudioServer.remove_bus_effect(_bus, i)
				break
	_capture = null
	_effect_index = -1


## A PCM WAV header is 44 bytes; the two size fields are patched on stop.
func _write_header(data_bytes: int) -> void:
	if _file == null:
		return
	_file.seek(0)
	_file.store_buffer("RIFF".to_ascii_buffer())
	_file.store_32(36 + data_bytes)
	_file.store_buffer("WAVEfmt ".to_ascii_buffer())
	_file.store_32(16)                                   # fmt chunk size
	_file.store_16(1)                                    # PCM
	_file.store_16(channels)
	_file.store_32(rate)
	_file.store_32(rate * channels * (BITS / 8))         # byte rate
	_file.store_16(channels * (BITS / 8))                # block align
	_file.store_16(BITS)
	_file.store_buffer("data".to_ascii_buffer())
	_file.store_32(data_bytes)
	_file.seek(_file.get_length())


func _patch_header(data_bytes: int) -> void:
	if path == "" or not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		return
	f.seek(4)
	f.store_32(36 + data_bytes)
	f.seek(40)
	f.store_32(data_bytes)
	f.close()
