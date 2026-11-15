extends Node
## M-F/M-G GAMEPLAY RECORDER — the service (autoload "GameRecorder").
##
## Records the ACTUAL running game (the root viewport) from a button in the
## race HUD, and writes a portrait video the user can upload. It is completely
## independent of the Studio editor, the Level Designer and the test harness:
## nothing here touches world state, and every capture is a read-only copy of
## the frame the renderer just produced.
##
## PIPELINE
##   1. RECORDING — on each rendered frame (throttled to the chosen FPS) the
##      root viewport is copied and saved as ONE JPEG into a temporary frame
##      folder. Nothing is held in memory between frames, so a long recording
##      cannot grow the heap; a write failure stops the recording instead of
##      corrupting it. The copy is 540x960-native, which is cheap enough to
##      leave the race at full speed.
##   2. SAVING — after STOP a background THREAD decodes each JPEG, scales it to
##      the chosen OUTPUT size (1080x1920 by default; this is an upscale from
##      the internal 540x960 render, and adds no detail), re-encodes it at the
##      chosen quality and muxes it into one MJPEG-AVI (see
##      scripts/mjpeg_avi_writer.gd). Gameplay keeps running while this happens;
##      the UI shows a progress line.
##   3. VERIFYING — the finished file is re-opened and parsed, its dimensions /
##      frame count / frame rate are checked against what was requested, and
##      real frames are decoded with Godot's JPEG decoder. Only then is the
##      recording reported as saved.
##
## M-G: TWO OUTPUTS, ONE PIPELINE.
##   * MP4 / H.264 + AAC — the upload format. Used when a real encoder is
##     installed (`scripts/video_encoder.gd` runs the machine's FFmpeg; Godot
##     itself can only write MJPEG). The captured frames and the WAV recorded by
##     `scripts/audio_capture.gd` (an AudioEffectCapture tap on the Master bus,
##     added for the recording and removed after it) are transcoded in ONE
##     FFmpeg process, so video and audio carry the same timeline.
##   * AVI / Motion-JPEG — the built-in fallback when no encoder is installed,
##     exactly the M-F file, still silent. The panel says which one will be used
##     and why; nothing fails silently.
##
## The approved AudioManager is not modified: the tap is a bus effect that the
## recorder adds and removes, and it sits after the manager's limiter, so the
## recorded audio is what the player hears.
##
## SAFEGUARDS
##   * one recording at a time (start refuses while one is running or saving)
##   * safe, unique filenames (never overwrites an existing recording)
##   * an interrupted recording leaves no .avi behind; its temporary frame
##     folder is removed and a stale one is cleaned at the next start
##   * recordings live in user://recordings — NOT inside the throwaway studio
##     test store, so test cleanup can never erase a real recording
##   * leaving a race while recording stops and saves it instead of orphaning it

signal state_changed(state: String)
signal recording_finished(result: Dictionary)

const STATE_IDLE := "idle"
const STATE_RECORDING := "recording"
const STATE_SAVING := "saving"

const DEFAULT_DIR := "user://recordings"
const SETTINGS_PATH := "user://recorder_settings.cfg"
const SETTINGS_PATH_TEST := "user://recorder_settings.test.cfg"
const TMP_PREFIX := ".tmp_frames_"
const RESOLUTIONS := [Vector2i(1080, 1920), Vector2i(720, 1280), Vector2i(540, 960)]
const FPS_CHOICES := [30, 60, 24]
## Label -> JPEG quality for the FINAL frames (0..1). 0.92 is visually clean
## for gameplay art at 1080x1920 without huge files.
const QUALITIES := {"youtube (high)": 0.92, "compact": 0.75, "master": 0.98}
## M-G: output container. "auto" uses MP4 when a real encoder is installed and
## falls back to AVI when it is not; "mp4" refuses to start without an encoder
## (with the reason) instead of quietly writing a different format.
const FORMATS := ["auto", "mp4", "avi"]
const AUDIO_TMP := "audio.wav"
## Frames handed to the MP4 encoder are temporary; a high JPEG quality keeps the
## double compression invisible at the final CRF.
const MP4_CAPTURE_QUALITY := 0.95

var settings := {
	"width": 1080,
	"height": 1920,
	"fps": 30,
	"quality": 0.92,
	"filename": "",
	"dir": DEFAULT_DIR,
	"include_overlay": false,
	"format": "auto",
	"audio": true,
}

var state := STATE_IDLE
var last_result: Dictionary = {}
var last_error := ""

var _frames := 0
var _captured := 0
var _period_us := 33333
var _start_us := 0
# M-H: the frame writer. The main thread reads the viewport and hands the image
# over; this thread crops, encodes and writes it. _cap_mutex guards the queue
# and the counters below; the semaphore wakes the worker once per hand-off.
const CAP_QUEUE_MAX := 6
var _cap_thread: Thread = null
var _cap_queue: Array = []
var _cap_mutex := Mutex.new()
var _cap_sem := Semaphore.new()
var _cap_quit := false
var _cap_error := ""
var _cap_ratio := 0.5625
var _cap_quality := 0.95
# M-H: wall-clock time spent PAUSED while recording. A pause is dropped from
# BOTH timelines (the audio tap discards it, and this keeps it out of the video's
# slot clock), so a take paused for ten seconds is still one continuous minute
# and still in sync.
var _paused_us := 0
# per-stage capture cost (microseconds), reported with the result so the
# machine's real capture rate is visible instead of guessed
var _cap_read_us := 0
var _cap_enc_us := 0
var _cap_wr_us := 0
# M-H: the other half of the picture. `_render_frames` counts the frames the
# renderer actually produced while recording; `_cap_main_us` is the wall time
# the capture callback took on the main thread (readback + crop + handoff).
# Together they answer "was the machine too slow to render, or did capture
# steal the frame time?" with numbers instead of a guess.
var _render_frames := 0
var _cap_main_us := 0
var _cap_overflow := 0
var _last_push_slot := -1
var _frame_dir := ""
var _out_path := ""
var _title_before := ""
var _title_t := 0.0
var _thread: Thread = null
var _mutex := Mutex.new()
var _progress := 0
var _job_error := ""
var _job_result: Dictionary = {}
var _job_done := false
var _connected := false
# M-G
var _audio: AudioCapture = null
var _use_mp4 := false
var _start_note := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	load_settings()
	_clean_stale_temps()


func _exit_tree() -> void:
	# Never leave a callback or a thread running when the engine shuts down.
	if _connected:
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
		_connected = false
	_stop_capture_worker()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_restore_title()


## ---------------------------------------------------------------- settings

func settings_path() -> String:
	# ADAPTED FOR PIXEL BREAKOUT: WorldRace asked StudioStore whether a test
	# owned a throwaway store. This project has no StudioStore, so a test run
	# (any --breakout-* mode) writes the separate settings file and can never
	# rewrite the player's saved recorder settings.
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--breakout-"):
			return SETTINGS_PATH_TEST
	return SETTINGS_PATH


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(settings_path()) != OK:
		return
	settings["width"] = clampi(int(cfg.get_value("video", "width", 1080)), 240, 3840)
	settings["height"] = clampi(int(cfg.get_value("video", "height", 1920)), 240, 3840)
	settings["fps"] = clampi(int(cfg.get_value("video", "fps", 30)), 5, 120)
	settings["quality"] = clampf(float(cfg.get_value("video", "quality", 0.92)), 0.3, 1.0)
	settings["filename"] = str(cfg.get_value("video", "filename", ""))
	settings["dir"] = str(cfg.get_value("video", "dir", DEFAULT_DIR))
	settings["include_overlay"] = bool(cfg.get_value("video", "include_overlay", false))
	settings["format"] = str(cfg.get_value("video", "format", "auto"))
	if not FORMATS.has(str(settings["format"])):
		settings["format"] = "auto"
	settings["audio"] = bool(cfg.get_value("video", "audio", true))
	if str(settings["dir"]).strip_edges() == "":
		settings["dir"] = DEFAULT_DIR


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for k in settings:
		cfg.set_value("video", str(k), settings[k])
	cfg.save(settings_path())


func set_output(width: int, height: int) -> void:
	settings["width"] = clampi(width, 240, 3840)
	settings["height"] = clampi(height, 240, 3840)
	save_settings()


## The destination folder as an absolute path (created on demand by start()).
func output_dir() -> String:
	var d := str(settings.get("dir", DEFAULT_DIR)).strip_edges()
	if d == "":
		d = DEFAULT_DIR
	return ProjectSettings.globalize_path(d)


## ---------------------------------------------------------------- formats

## What an MP4 needs is a working H.264 encoder (scripts/video_encoder.gd).
func mp4_ready() -> bool:
	return VideoEncoder.available()


## Audio capture needs an encoder that can mux it, the engine's capture effect
## and a real audio output (headless has none).
static func audio_supported() -> bool:
	return VideoEncoder.audio_available() \
		and ClassDB.class_exists("AudioEffectCapture") \
		and DisplayServer.get_name() != "headless"


func audio_enabled() -> bool:
	return bool(settings.get("audio", true)) and audio_supported()


## "mp4" or "avi" for the NEXT recording, with a human note for the panel and
## an error when the user explicitly asked for a format this machine cannot
## produce (never a silent switch to something else).
func resolve_format() -> Dictionary:
	var want := str(settings.get("format", "auto"))
	if not FORMATS.has(want):
		want = "auto"
	var disc := VideoEncoder.discover()
	if want == "avi":
		return {"format": "avi", "err": "", "note": "AVI / Motion-JPEG (built-in encoder, silent)"}
	if bool(disc.get("ok", false)):
		var a := " + AAC audio" if audio_enabled() else " (silent)"
		return {"format": "mp4", "err": "", "note": "MP4 / H.264" + a + " via ffmpeg"}
	if want == "mp4":
		return {"format": "mp4", "err": "MP4 recording needs a local encoder: " + str(disc.get("reason", "no encoder found")), "note": ""}
	return {"format": "avi", "err": "",
		"note": "AVI / Motion-JPEG — no MP4 encoder found, so this take is AVI and silent"}


## A short sentence the panel shows about the encoder and the audio tap.
func encoder_note() -> String:
	var d := VideoEncoder.discover()
	if not bool(d.get("ok", false)):
		return "MP4 needs a local encoder: " + str(d.get("reason", "none found"))
	if not audio_supported():
		return VideoEncoder.summary() + " · audio capture unavailable here (video only)"
	return VideoEncoder.summary() + " · audio ON"


## ---------------------------------------------------------------- state

func is_recording() -> bool:
	return state == STATE_RECORDING


func is_busy() -> bool:
	return state != STATE_IDLE


## Length of the video captured so far (captured frames / target FPS).
func elapsed_seconds() -> float:
	return float(_frames) / maxf(1.0, float(settings.get("fps", 30)))


## How much of the take the game was actually RUNNING for: wall-clock since
## START minus every paused millisecond. This is the timeline both the video
## slots and the audio tap use, so it is also the honest denominator for a
## capture rate (a paused game is not a slow recording).
func recorded_seconds() -> float:
	if _start_us <= 0:
		return 0.0
	return maxf(0.0, float(Time.get_ticks_usec() - _start_us - _paused_us) / 1000000.0)


## M-H: the honest live numbers. `frames` is how many frames the VIDEO will
## have (real time, duplicates included); `unique` is how many distinct
## pictures were actually captured; `unique_fps` is the machine's real capture
## rate. The UI shows both so "30 FPS" is never mistaken for 30 unique frames.
func capture_stats() -> Dictionary:
	var real := 0.0
	if _start_us > 0:
		real = recorded_seconds()
	elif not last_result.is_empty():
		real = float(last_result.get("real_seconds", 0.0))
	_mutex.lock()
	var overflow := _cap_overflow
	_mutex.unlock()
	var uniq := _captured
	var target := float(settings.get("fps", 30))
	var cap_fps := float(uniq) / real if real > 0.0 else 0.0
	var rnd_fps := float(_render_frames) / real if real > 0.0 else 0.0
	return {"unique": uniq, "out_frames": _frames, "rendered": _render_frames,
		"real_seconds": real, "unique_fps": cap_fps, "render_fps": rnd_fps,
		"target_fps": target, "overflow": overflow,
		"keeping_up": real <= 0.0 or cap_fps >= target - 0.75}


## One sentence for the panel and the window title: what this machine is
## ACTUALLY capturing, and why it is not 30 when it is not.
func capture_note() -> String:
	if state != STATE_RECORDING:
		return ""
	var s := capture_stats()
	var real := float(s["real_seconds"])
	if real < 0.75:
		return "measuring…"
	var uniq := float(s["unique"])
	var target := float(s["target_fps"])
	if bool(s["keeping_up"]):
		return "capturing %.0f of %d FPS (keeping up)" % [float(s["unique_fps"]), int(target)]
	var why := "this machine renders slowly" if float(s["render_fps"]) < target - 0.75 else "capture is the limit"
	return "capturing %.1f of %d FPS — %s (%d unique frames so far)" % [float(s["unique_fps"]), int(target), why, int(uniq)]


func status() -> Dictionary:
	_mutex.lock()
	var progress := _progress
	var overflow := _cap_overflow
	_mutex.unlock()
	return {
		"state": state,
		"frames": _frames,
		"captured": _captured,
		"rendered": _render_frames,
		"overflow": overflow,
		"cap_main_ms": float(_cap_main_us) / 1000.0,
		"unique_fps": float(capture_stats().get("unique_fps", 0.0)),
		"capture_note": capture_note(),
		"elapsed": elapsed_seconds(),
		"fps": int(settings.get("fps", 30)),
		"width": int(settings.get("width", 1080)),
		"height": int(settings.get("height", 1920)),
		"output": _out_path,
		"dir": output_dir(),
		"progress": progress,
		"error": last_error,
		"audio": audio_enabled(),
		"format": resolve_format(),
		"encoder": encoder_note(),
		"last": last_result.duplicate(true),
	}


## ---------------------------------------------------------------- capture

## M-I: NON-DESTRUCTIVE preflight for the one-click REC flow. Every check
## `start()` makes before it commits — state, viewport, renderer, format,
## output folder — without creating a temp folder, opening the audio tap or
## touching the capture thread, so a failure can be reported BEFORE the race
## is restarted (the milestone's rule: a failed setup never discards a race).
## Returns {ok, err, format, note}.
func prepare() -> Dictionary:
	if state != STATE_IDLE:
		return {"ok": false, "err": "a recording is already %s" % (
			"running" if state == STATE_RECORDING else "being saved")}
	if get_viewport() == null:
		return {"ok": false, "err": "there is no game viewport to record"}
	if DisplayServer.get_name() == "headless":
		return {"ok": false, "err": "the headless renderer produces no frames to record"}
	var fmt := resolve_format()
	if str(fmt.get("err", "")) != "":
		return {"ok": false, "err": str(fmt["err"])}
	var dir := output_dir()
	if DirAccess.make_dir_recursive_absolute(dir) != OK and not DirAccess.dir_exists_absolute(dir):
		return {"ok": false, "err": "cannot create the recordings folder: %s" % dir}
	if not DirAccess.dir_exists_absolute(dir):
		return {"ok": false, "err": "the recordings folder does not exist: %s" % dir}
	return {"ok": true, "err": "", "format": str(fmt.get("format", "")),
		"note": str(fmt.get("note", ""))}


## Begin a recording. `opts` may override any key of `settings` (the settings
## panel and the tests both use this). Returns {ok, err, path, dir, fps}.
func start(opts: Dictionary = {}) -> Dictionary:
	if state != STATE_IDLE:
		return {"ok": false, "err": "a recording is already %s" % ("running" if state == STATE_RECORDING else "being saved"), "path": ""}
	for k in opts:
		if settings.has(str(k)):
			settings[str(k)] = opts[k]
	settings["fps"] = clampi(int(settings["fps"]), 5, 120)
	settings["width"] = clampi(int(settings["width"]), 240, 3840)
	settings["height"] = clampi(int(settings["height"]), 240, 3840)
	var vp := get_viewport()
	if vp == null:
		return _fail_start("there is no game viewport to record")
	if DisplayServer.get_name() == "headless":
		return _fail_start("the headless renderer produces no frames to record")
	# The format is decided BEFORE anything is created: if the user asked for MP4
	# and this machine has no encoder, they get the reason, not a silent AVI.
	var fmt := resolve_format()
	if str(fmt.get("err", "")) != "":
		return _fail_start(str(fmt["err"]))
	_use_mp4 = str(fmt["format"]) == "mp4"
	_start_note = str(fmt.get("note", ""))
	var dir := output_dir()
	if DirAccess.make_dir_recursive_absolute(dir) != OK and not DirAccess.dir_exists_absolute(dir):
		return _fail_start("cannot create the recordings folder: %s" % dir)
	if not DirAccess.dir_exists_absolute(dir):
		return _fail_start("the recordings folder does not exist: %s" % dir)
	_clean_stale_temps()
	_frames = 0
	_captured = 0
	_cap_read_us = 0
	_cap_enc_us = 0
	_cap_wr_us = 0
	_render_frames = 0
	_cap_main_us = 0
	_cap_overflow = 0
	_last_push_slot = -1
	_paused_us = 0
	_progress = 0
	_job_error = ""
	_job_result = {}
	_job_done = false
	last_error = ""
	var stamp := _stamp()
	var base := _sanitize(ProjectSettings.globalize_path(str(settings.get("filename", ""))).get_file().get_basename())
	if base == "":
		base = _sanitize(str(settings.get("filename", "")))
	if base == "":
		# ADAPTED: this project's own file prefix (WorldRace wrote "worldrace_").
		base = "breakout_" + stamp
	_frame_dir = dir.path_join(TMP_PREFIX + stamp)
	if DirAccess.make_dir_recursive_absolute(_frame_dir) != OK and not DirAccess.dir_exists_absolute(_frame_dir):
		return _fail_start("cannot create the temporary frame folder: %s" % _frame_dir)
	_out_path = _unique_path(dir.path_join(base + (".mp4" if _use_mp4 else ".avi")))
	_cap_quality = clampf(MP4_CAPTURE_QUALITY if _use_mp4 else float(settings["quality"]), 0.3, 1.0)
	_cap_ratio = float(settings["width"]) / float(settings["height"])
	_period_us = maxi(1000, int(round(1000000.0 / float(settings["fps"]))))
	_start_us = Time.get_ticks_usec()
	# M-G: tap the game's mixed audio for the MP4 path. A machine without an
	# audio output (or without AAC) simply records video — never an error.
	_audio = null
	if _use_mp4 and audio_enabled():
		var tap := AudioCapture.new()
		if tap.start(_frame_dir.path_join(AUDIO_TMP)):
			_audio = tap
		else:
			_start_note += " (audio unavailable: %s)" % tap.err
	# M-H: the writer thread must exist before the first frame can be handed off.
	if not _start_capture_worker():
		_cleanup_frames()
		return {"ok": false, "err": last_error, "path": ""}
	if not _connected:
		RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
		_connected = true
	# DisplayServer has no title GETTER; the app name is what the project sets.
	_title_before = str(ProjectSettings.get_setting("application/config/name", "WORLD RACE"))
	_title_t = 0.0
	_set_state(STATE_RECORDING)
	_update_title()
	return {"ok": true, "err": "", "path": _out_path, "dir": dir,
		"fps": int(settings["fps"]), "width": int(settings["width"]), "height": int(settings["height"]),
		"format": "mp4" if _use_mp4 else "avi", "audio": _audio != null, "note": _start_note}


## Finish the current recording. The heavy work happens on a background thread
## (state becomes "saving"); recording_finished carries the verified result.
func stop() -> Dictionary:
	if state != STATE_RECORDING:
		return {"ok": false, "err": "nothing is being recorded", "path": ""}
	_disconnect_capture()
	# Close the audio tap first, so its last blocks are inside the file.
	var audio := {"ok": false, "path": "", "seconds": 0.0, "peak": 0.0, "err": "no tap"}
	if _audio != null:
		audio = _audio.stop()
		_audio = null
	# Let the writer finish the frames it already owns BEFORE the totals are
	# read: otherwise a take could lose its last queued frames.
	_stop_capture_worker()
	var writer_err := _capture_error()
	if writer_err != "":
		_cleanup_frames()
		last_error = writer_err
		_set_state(STATE_IDLE)
		_restore_title()
		return {"ok": false, "err": writer_err, "path": ""}
	# M-J: the take's length is the wall clock's, and the finalizer spreads the
	# captured pictures over it evenly — there is no tail to fill by hand.
	_frames = _total_slots()
	if _captured <= 0 or _frames <= 0:
		var why := "no frames were captured — the viewport could not be read"
		_cleanup_frames()
		last_error = why
		_set_state(STATE_IDLE)
		_restore_title()
		return {"ok": false, "err": why, "path": ""}
	_set_state(STATE_SAVING)
	_mutex.lock()
	_progress = 0
	_mutex.unlock()
	var job := {
		"frames": _frames, "width": int(settings["width"]), "height": int(settings["height"]),
		"fps": float(settings["fps"]), "quality": float(settings["quality"]),
		"out": _out_path, "frame_dir": _frame_dir,
		"captured": _captured,
		"real_seconds": recorded_seconds(),
		"cap_read_us": _cap_read_us, "cap_enc_us": _cap_enc_us, "cap_wr_us": _cap_wr_us,
		"render_frames": _render_frames, "cap_main_us": _cap_main_us, "overflow": _cap_overflow,
		"mp4": _use_mp4, "wav": str(audio.get("path", "")) if bool(audio.get("ok", false)) else "",
		"audio_seconds": float(audio.get("seconds", 0.0)), "audio_peak": float(audio.get("peak", 0.0)),
		"crf": crf_for(float(settings["quality"])), "note": _start_note,
	}
	_thread = Thread.new()
	var err := _thread.start(_finalize_thread.bind(job))
	if err != OK:
		_thread = null
		last_error = "could not start the video encoder thread"
		_cleanup_frames()
		_set_state(STATE_IDLE)
		_restore_title()
		return {"ok": false, "err": last_error, "path": ""}
	return {"ok": true, "err": "", "path": _out_path}


## Drop the current recording without writing a video (used by tests and by a
## race that is being torn down after a fatal capture error).
func abort() -> void:
	if state == STATE_RECORDING:
		_disconnect_capture()
		if _audio != null:
			_audio.abort()
			_audio = null
		_stop_capture_worker()
		_cleanup_frames()
		_set_state(STATE_IDLE)
		_restore_title()


func _fail_start(why: String) -> Dictionary:
	last_error = why
	_cleanup_frames()
	return {"ok": false, "err": why, "path": ""}


func _on_frame_post_draw() -> void:
	if state != STATE_RECORDING:
		return
	# Pausing the game suspends recording: the pause menu (and its STOP button)
	# is recorder UI and must never end up inside the exported video.
	var tree := get_tree()
	if tree != null and tree.paused:
		return
	_render_frames += 1
	var t_main := Time.get_ticks_usec()
	_capture_tick()
	_cap_main_us += Time.get_ticks_usec() - t_main


## One capture attempt for the frame the renderer just finished. Split out of
## the signal callback so its wall-clock cost can be measured around it.
##
## M-H: THIS IS THE ONLY WORK LEFT ON THE MAIN THREAD. It reads the viewport
## (a GPU readback that has to happen here), stamps the frame with its target
## slot and hands it to the capture thread. Cropping, JPEG encoding and the
## disk write — the three costs that used to stall the race — happen on that
## thread. On this machine that is ~47 ms of the ~55 ms a capture used to cost.
func _capture_tick() -> void:
	# TIMING IS DRIVEN BY THE WALL CLOCK, not by the render frame count. The
	# target slot this frame belongs to is derived from real elapsed time; if
	# the machine could not capture every slot, the previous frame is written
	# again for the missed ones. The video therefore keeps its REAL duration
	# (a 10 s recording is a 10 s video) and merely shows motion at the rate the
	# machine managed, instead of playing the race back too fast.
	var now := Time.get_ticks_usec()
	if _start_us <= 0:
		_start_us = now
	# (Paused time is subtracted: a pause must not create a gap in the video.)
	var slot := int((now - _start_us - _paused_us) / _period_us)
	if slot <= _last_push_slot:
		return
	var vp := get_viewport()
	if vp == null:
		return
	# M-J: ASK THE WRITER FIRST. The GPU readback below is the single most
	# expensive thing the recorder does on the main thread (~9 ms of stall per
	# capture on this machine, measured: 26 % of the whole frame rate), and M-H
	# paid for it BEFORE looking at the queue — a frame the writer could not take
	# was read back and then dropped. The slot is consumed either way (a later
	# frame must never re-use it), but the readback is now only paid for a frame
	# that will actually be encoded. The queue itself stays bounded.
	_cap_mutex.lock()
	var full := _cap_queue.size() >= CAP_QUEUE_MAX
	if full:
		_cap_overflow += 1
	_cap_mutex.unlock()
	_last_push_slot = slot
	if full:
		return
	var t_read := Time.get_ticks_usec()
	var tex := vp.get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null or img.get_width() <= 0 or img.get_height() <= 0:
		return
	_cap_read_us += Time.get_ticks_usec() - t_read
	# Re-check under the lock: the writer may have fallen behind (or failed)
	# while the readback was running.
	_cap_mutex.lock()
	var lost := _cap_queue.size() >= CAP_QUEUE_MAX
	if lost:
		_cap_overflow += 1
	else:
		_cap_queue.append({"slot": slot, "img": img})
	_cap_mutex.unlock()
	if lost:
		return
	_cap_sem.post()


## ---------------------------------------------------------------- capture thread

## Runs on its OWN THREAD for the whole take: takes the image the main thread
## read back, centre-crops it to the output aspect, encodes one JPEG and writes
## it. One file per picture, nothing else — the repeated frames that keep the
## video's real duration are built at finalize (`pace_holds`), so the race pays
## for exactly the frames it drew. Only Image/FileAccess are used here (Image
## handling is thread-safe in Godot and the finalise thread already does the
## same), so no node, scene or rendering API is touched.
func _capture_worker() -> void:
	while true:
		_cap_sem.wait()
		_cap_mutex.lock()
		if _cap_queue.is_empty():
			var quit_now := _cap_quit
			_cap_mutex.unlock()
			if quit_now:
				return
			continue
		var item: Dictionary = _cap_queue.pop_front()
		_cap_mutex.unlock()
		if not _consume_frame(item):
			return


## Encode + write one queued frame. Returns false when the take cannot go on
## (the error is recorded for the main thread, which ends the recording).
##
## M-J: ONE PICTURE, ONE FILE. M-H also wrote a copy of the previous picture for
## every slot this machine missed, so a 30 FPS take of 1,340 real frames became
## 2,702 files written DURING the race (and 2,702 decodes at save time). The
## copies bought nothing: a repeated picture is not new information, and it made
## every hold as irregular as the renderer's own frame times. The timeline is
## now laid out once, at finalize (see `pace_holds`), so the capture thread only
## ever stores what the GPU actually drew.
func _consume_frame(item: Dictionary) -> bool:
	var img = item.get("img", null)
	if not (img is Image):
		return true
	var t_enc := Time.get_ticks_usec()
	# Keep the 9:16 frame the game actually presents: if the OS window is not
	# 9:16 (letterboxed by the stretch mode), centre-crop instead of squashing.
	var pic := _crop_to_ratio(img, _cap_ratio)
	var bytes := pic.save_jpg_to_buffer(_cap_quality)
	var enc_us := Time.get_ticks_usec() - t_enc
	if bytes.size() < 4:
		_set_capture_error("could not encode frame %d" % _captured)
		return false
	var t_wr := Time.get_ticks_usec()
	if not _write_frame(bytes, _captured):
		_set_capture_error("could not write frame %d (disk full?)" % _captured)
		return false
	_captured += 1
	# `_frames` is the OUTPUT position the take will reach — the clock the UI
	# shows — not a count of files. The finalizer turns the pictures into that
	# many frames.
	var slot := int(item.get("slot", 0))
	if slot + 1 > _frames:
		_frames = slot + 1
	_cap_enc_us += enc_us
	_cap_wr_us += Time.get_ticks_usec() - t_wr
	return true


func _write_frame(bytes: PackedByteArray, index: int) -> bool:
	var f := FileAccess.open(_frame_path(index), FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.close()
	return true


## Start the frame writer. Called by the main thread before capture begins, so
## the first hand-off never races a half-initialised queue.
func _start_capture_worker() -> bool:
	_cap_mutex.lock()
	_cap_queue.clear()
	_cap_quit = false
	_cap_error = ""
	_cap_mutex.unlock()
	_cap_thread = Thread.new()
	var err := _cap_thread.start(_capture_worker)
	if err != OK:
		_cap_thread = null
		last_error = "could not start the frame writer thread"
		return false
	return true


## Drain whatever is queued, stop the writer and wait for it. Never called from
## the worker itself: the main thread owns the join.
func _stop_capture_worker() -> void:
	if _cap_thread == null:
		return
	_cap_mutex.lock()
	_cap_quit = true
	_cap_mutex.unlock()
	_cap_sem.post()
	_cap_thread.wait_to_finish()
	_cap_thread = null
	_cap_mutex.lock()
	_cap_queue.clear()
	_cap_mutex.unlock()


## How many OUTPUT frames (30 FPS slots) this take must have. It is the slot
## clock's position at STOP — the same timeline the audio tap runs on — so the
## video can never be shorter than the race, and the last fraction of a second
## (which has no captured picture) is covered by the pacing below instead of by
## a bespoke tail fill.
func _total_slots() -> int:
	return maxi(_captured, int(round(recorded_seconds() * float(settings.get("fps", 30)))))


## M-J: THE TIMELINE. Spread `count` distinct pictures evenly over `total`
## output frames.
##
## M-H placed picture k at the slot it happened to be captured at, so every hold
## was the length of that renderer interval. On this machine the render rate
## swings from 8 to 40 FPS inside one race, which turns into holds of 1 to 12
## frames (33 ms to 400 ms) — a random walk of short stutters and short freezes.
## That irregularity, not the average rate, is what reads as "choppy" and
## "pausing for fractions of a second".
##
## Placing picture k at round(k * total / count) gives every picture the same
## number of frames (±1 from rounding), i.e. a steady cadence at the rate the
## machine actually managed, while the total is EXACTLY `total` — the duration
## still equals the wall-clock duration of the take, so the audio stays in sync.
## Nothing is invented: the picture count is unchanged, only the spacing.
## How evenly the take was paced, for the result dictionary and the report:
## a hold of 12 frames next to a hold of 1 is what judder looks like in numbers.
static func hold_stats(holds: Array) -> Dictionary:
	if holds.is_empty():
		return {"min": 0, "max": 0, "mean": 0.0, "jitter": 0.0}
	var lo := 1 << 30
	var hi := 0
	var sum := 0
	for h in holds:
		var v := int(h)
		lo = mini(lo, v)
		hi = maxi(hi, v)
		sum += v
	var mean := float(sum) / float(holds.size())
	var var_sum := 0.0
	for h in holds:
		var d := float(h) - mean
		var_sum += d * d
	return {"min": lo, "max": hi, "mean": snappedf(mean, 0.001),
		"jitter": snappedf(sqrt(var_sum / float(holds.size())), 0.001)}


static func pace_holds(count: int, total: int) -> Array:
	var out: Array = []
	if count <= 0:
		return out
	var slots := maxi(count, total)
	var prev := 0
	for i in count:
		var cut := int(round(float(i + 1) * float(slots) / float(count)))
		var hold := cut - prev
		if hold < 1:
			hold = 1
		out.append(hold)
		prev = cut
	return out


## The worker could not encode or write a frame. The main thread sees this in
## _process() and ends the take with that reason (never a silent partial file).
func _set_capture_error(why: String) -> void:
	_cap_mutex.lock()
	if _cap_error == "":
		_cap_error = why
	_cap_mutex.unlock()


func _capture_error() -> String:
	_cap_mutex.lock()
	var why := _cap_error
	_cap_mutex.unlock()
	return why


func _capture_failed(why: String) -> void:
	last_error = why
	_disconnect_capture()
	_stop_capture_worker()
	_cleanup_frames()
	_set_state(STATE_IDLE)
	_restore_title()
	AudioManager.play("error")
	recording_finished.emit({"ok": false, "err": why, "path": ""})


## ---------------------------------------------------------------- finalise

## Runs on a THREAD: decode each captured JPEG, scale it to the requested
## output size, re-encode it, and append it to one AVI. No engine node, scene
## or rendering API is touched here — only Image/FileAccess, which is safe off
## the main thread — so the race keeps running.
func _finalize_thread(job: Dictionary) -> void:
	var w := int(job["width"])
	var h := int(job["height"])
	var total := int(job["frames"])
	var quality := float(job["quality"])
	var frame_dir := str(job["frame_dir"])
	var out := str(job["out"])
	var result := {"ok": false, "err": "", "path": out, "width": w, "height": h,
		"fps": float(job["fps"]), "frames": 0, "duration": 0.0, "bytes": 0,
		"audio": false, "format": "avi/mjpeg", "quality": quality,
		"captured": int(job.get("captured", 0)), "real_seconds": float(job.get("real_seconds", 0.0)),
		"cap_read_ms": float(job.get("cap_read_us", 0)) / 1000.0,
		"cap_enc_ms": float(job.get("cap_enc_us", 0)) / 1000.0,
		"cap_write_ms": float(job.get("cap_wr_us", 0)) / 1000.0,
		"render_frames": int(job.get("render_frames", 0)),
		"cap_main_ms": float(job.get("cap_main_us", 0)) / 1000.0,
		"overflow": int(job.get("overflow", 0)),
		"note": str(job.get("note", "")), "audio_seconds": float(job.get("audio_seconds", 0.0))}
	# M-G: MP4 goes through the machine's encoder; AVI stays the built-in path.
	if bool(job.get("mp4", false)):
		_job_finish(_finalize_mp4(job, result))
		return
	var writer := MjpegAviWriter.new()
	var werr := writer.open(out, w, h, float(job["fps"]))
	if werr != "":
		result["err"] = werr
		_job_finish(result)
		return
	var t_fin := Time.get_ticks_msec()
	# M-J: decode + resize + re-encode each DISTINCT picture once, then append the
	# same bytes for as many frames as the even timeline gives it. M-H did the
	# whole decode/resize/encode for every one of the `total` output frames, half
	# of which were copies of the frame before.
	var count := mini(int(job.get("captured", total)), total)
	var holds := pace_holds(count, total)
	var written := 0
	for i in count:
		var p := frame_dir.path_join("%06d.jpg" % i)
		var bytes := FileAccess.get_file_as_bytes(p)
		if bytes.is_empty():
			result["err"] = "captured frame %d is missing or empty" % i
			writer.close_quietly()
			_remove_file(out)
			_job_finish(result)
			return
		var img := Image.new()
		if img.load_jpg_from_buffer(bytes) != OK:
			result["err"] = "captured frame %d could not be decoded" % i
			writer.close_quietly()
			_remove_file(out)
			_job_finish(result)
			return
		if img.get_width() != w or img.get_height() != h:
			# OUTPUT scaling. The internal render is 540x960, so 1080x1920 is a
			# 2x upscale: it makes the file fit YouTube's Shorts frame, it does
			# not invent detail.
			img.resize(w, h, Image.INTERPOLATE_LANCZOS)
		var jpg := img.save_jpg_to_buffer(quality)
		if jpg.size() < 4:
			result["err"] = "frame %d could not be encoded" % i
			writer.close_quietly()
			_remove_file(out)
			_job_finish(result)
			return
		for rep in int(holds[i]):
			var aerr := writer.add_jpeg(jpg)
			if aerr != "":
				result["err"] = aerr
				writer.close_quietly()
				_remove_file(out)
				_job_finish(result)
				return
			written += 1
		_mutex.lock()
		_progress = written
		_mutex.unlock()
	result["hold_stats"] = hold_stats(holds)
	result["encode_ms"] = Time.get_ticks_msec() - t_fin
	var ferr := writer.finish()
	if ferr != "":
		result["err"] = ferr
		_remove_file(out)
		_job_finish(result)
		return
	# --- verify the finished file with a real decoder -----------------------
	var info := MjpegAviReader.inspect(out)
	if not bool(info.get("ok", false)):
		result["err"] = "the saved video could not be re-opened: %s" % str(info.get("err", "unknown"))
		_job_finish(result)
		return
	if int(info.get("width", 0)) != w or int(info.get("height", 0)) != h:
		result["err"] = "the saved video is %dx%d, expected %dx%d" % [
			int(info.get("width", 0)), int(info.get("height", 0)), w, h]
		_job_finish(result)
		return
	if int(info.get("frames", 0)) != total:
		result["err"] = "the saved video holds %d frames, expected %d" % [int(info.get("frames", 0)), total]
		_job_finish(result)
		return
	for probe in [0, total / 2, total - 1]:
		var img := MjpegAviReader.decode_frame(out, info, int(probe))
		if img == null:
			result["err"] = "frame %d of the saved video does not decode (%s)" % [int(probe), MjpegAviReader.last_error]
			_job_finish(result)
			return
	result["ok"] = true
	result["frames"] = int(info.get("frames", total))
	result["duration"] = float(info.get("duration", 0.0))
	result["bytes"] = int(info.get("bytes", 0))
	result["fps"] = float(info.get("fps", float(job["fps"])))
	# The AVI path never carries sound; say so explicitly rather than leaving a
	# field that could be misread.
	result["audio"] = false
	_job_finish(result)


## Quality setting -> H.264 CRF (lower is better). Constant quality keeps the
## flat game art clean without a bitrate to tune.
func crf_for(quality: float) -> int:
	if quality >= 0.96:
		return 18
	if quality <= 0.80:
		return 26
	return 20


## MP4 / H.264 (+AAC when the tap recorded something). Runs on the finalise
## thread. The frames already exist on disk, so FFmpeg reads them one at a time
## and this function never holds the recording in memory.
func _finalize_mp4(job: Dictionary, result: Dictionary) -> Dictionary:
	var w := int(job["width"])
	var h := int(job["height"])
	var total := int(job["frames"])
	var fps := float(job["fps"])
	var out := str(job["out"])
	var frame_dir := str(job["frame_dir"])
	var wav := str(job.get("wav", ""))
	var want_audio := wav != "" and FileAccess.file_exists(wav)
	# M-J: lay the captured pictures out on the even timeline and materialise the
	# 30 FPS sequence ffmpeg reads. One picture was stored per capture; the
	# copies are made HERE, after the race, so the file still holds exactly
	# `total` frames and ffmpeg still sees one image per output frame. Copying
	# bytes costs no decode, which is why this is cheap even for minutes of take.
	var count := mini(int(job.get("captured", total)), total)
	var holds: Array = pace_holds(count, total)
	var seq := frame_dir.path_join("seq")
	if DirAccess.make_dir_recursive_absolute(seq) != OK and not DirAccess.dir_exists_absolute(seq):
		result["err"] = "could not create the frame sequence folder: " + seq
		return result
	var idx := 0
	for i in count:
		var src := FileAccess.get_file_as_bytes(frame_dir.path_join("%06d.jpg" % i))
		if src.is_empty():
			result["err"] = "captured frame %d is missing or empty" % i
			return result
		for rep in int(holds[i]):
			var f := FileAccess.open(seq.path_join("%06d.jpg" % idx), FileAccess.WRITE)
			if f == null:
				result["err"] = "could not write frame %d (disk full?)" % idx
				return result
			f.store_buffer(src)
			f.close()
			idx += 1
	result["hold_stats"] = hold_stats(holds)
	frame_dir = seq
	_mutex.lock()
	_progress = int(total * 0.15)     # the transcode itself reports no progress
	_mutex.unlock()
	# M-H: the transcode is timed too. It never runs while the game is being
	# played (it is the background save), so its duration is reported, not
	# optimized away.
	var t_enc := Time.get_ticks_msec()
	var enc: Dictionary = VideoEncoder.encode_mp4({
		"frame_dir": frame_dir, "frames": total, "fps": fps,
		"width": w, "height": h, "out": out, "wav": wav,
		"crf": int(job.get("crf", 20)),
	})
	result["encode_ms"] = Time.get_ticks_msec() - t_enc
	_mutex.lock()
	_progress = int(total * 0.85)
	_mutex.unlock()
	if not bool(enc.get("ok", false)):
		result["err"] = str(enc.get("err", "the MP4 encoder failed"))
		_remove_file(out)
		return result
	# --- verify with an INDEPENDENT decoder: ffprobe re-reads the file --------
	var info: Dictionary = VideoEncoder.probe(out)
	if not bool(info.get("ok", false)):
		result["err"] = "the MP4 could not be re-read: " + str(info.get("err", "unknown"))
		_remove_file(out)
		return result
	if int(info["width"]) != w or int(info["height"]) != h:
		result["err"] = "the MP4 is %dx%d, expected %dx%d" % [int(info["width"]), int(info["height"]), w, h]
		_remove_file(out)
		return result
	var got_fps := float(info["fps"])
	if got_fps <= 0.0 or absf(got_fps - fps) > 0.6:
		result["err"] = "the MP4 runs at %.2f FPS, expected %.2f" % [got_fps, fps]
		_remove_file(out)
		return result
	var expected := float(total) / fps
	var dur := float(info["duration"])
	if dur <= 0.0 or absf(dur - expected) > maxf(0.35, 2.0 / fps):
		result["err"] = "the MP4 lasts %.2f s, expected about %.2f s" % [dur, expected]
		_remove_file(out)
		return result
	if want_audio and not bool(info["has_audio"]):
		result["err"] = "the MP4 has no audio stream although audio was recorded"
		_remove_file(out)
		return result
	# Every captured frame must be in the file: a transcode that quietly dropped
	# frames would make the video shorter than the race.
	var nb := int(info.get("nb_frames", 0))
	if nb > 0 and nb != total:
		result["err"] = "the MP4 holds %d frames, expected %d" % [nb, total]
		_remove_file(out)
		return result
	result["ok"] = true
	result["bytes"] = int(info["bytes"])
	result["duration"] = dur
	result["fps"] = got_fps
	result["width"] = int(info["width"])
	result["height"] = int(info["height"])
	result["frames"] = nb if nb > 0 else total
	result["audio"] = bool(info["has_audio"])
	result["vcodec"] = str(info.get("vcodec", "h264"))
	result["acodec"] = str(info.get("acodec", ""))
	result["audio_rate"] = int(info.get("audio_rate", 0))
	result["audio_channels"] = int(info.get("audio_channels", 0))
	result["format"] = "mp4/%s%s" % [str(info.get("vcodec", "h264")),
		"+" + str(info.get("acodec", "aac")) if bool(info["has_audio"]) else ""]
	result["audio_seconds"] = float(job.get("audio_seconds", 0.0))
	# How far the two timelines drifted: a real number, not a promise.
	result["sync_delta"] = float(job.get("audio_seconds", 0.0)) - dur
	result["audio_peak"] = float(job.get("audio_peak", 0.0))
	result["cmd"] = str(enc.get("cmd", ""))
	_mutex.lock()
	_progress = total
	_mutex.unlock()
	return result


func _job_finish(result: Dictionary) -> void:
	# M-H: derived rates on EVERY result (both containers), so the "30 FPS" the
	# user asked for can never be confused with "30 distinct frames per second
	# of gameplay". capture_fps is what the machine actually captured.
	var real := float(result.get("real_seconds", 0.0))
	if real > 0.0:
		result["capture_fps"] = float(result.get("captured", 0)) / real
		result["render_fps"] = float(result.get("render_frames", 0)) / real
	result["dup_frames"] = maxi(0, int(result.get("frames", 0)) - int(result.get("captured", 0)))
	_mutex.lock()
	_job_result = result
	_job_done = true
	_mutex.unlock()


func _process(delta: float) -> void:
	if state == STATE_RECORDING:
		# M-H: a write/encode failure on the writer thread ends the take here,
		# with the real reason — the file is never left half-written.
		var werr := _capture_error()
		if werr != "":
			_capture_failed(werr)
			return
		# M-G/M-H: a PAUSE is dropped from both timelines. While paused the
		# recorder writes no video frames AND does not let the slot clock run, so
		# resuming continues where the pause started; the audio tap discards what
		# the paused game played (nothing the player should hear in the video).
		var paused_now := get_tree() != null and get_tree().paused
		if paused_now:
			_paused_us += int(delta * 1000000.0)
		if _audio != null:
			if paused_now:
				_audio.discard()
			else:
				_audio.drain()
		_title_t += delta
		if _title_t >= 0.25:
			_title_t = 0.0
			_update_title()
		return
	if state == STATE_SAVING:
		var done := false
		_mutex.lock()
		done = _job_done
		_mutex.unlock()
		if not done and (_thread == null or _thread.is_alive()):
			return
		if _thread != null:
			_thread.wait_to_finish()
			_thread = null
		_mutex.lock()
		var result := _job_result.duplicate(true)
		_job_done = false
		_mutex.unlock()
		_progress = 0
		if bool(result.get("ok", false)):
			_cleanup_frames()
			last_result = result
			last_error = ""
			AudioManager.play("confirm")
		else:
			# Keep the captured frames? No: a failed encode leaves a broken
			# partial recording, not something the user can use. Delete both so
			# the folder never fills with unusable files.
			_cleanup_frames()
			_remove_file(str(result.get("path", "")))
			last_error = str(result.get("err", "the recording could not be saved"))
			AudioManager.play("error")
		_set_state(STATE_IDLE)
		_restore_title()
		recording_finished.emit(result)


func _set_state(s: String) -> void:
	if state == s:
		return
	state = s
	state_changed.emit(s)


## ---------------------------------------------------------------- helpers

func _disconnect_capture() -> void:
	if _connected:
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
		_connected = false


func _frame_path(i: int) -> String:
	return _frame_dir.path_join("%06d.jpg" % i)


func _stamp() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d_%02d%02d%02d" % [int(d["year"]), int(d["month"]), int(d["day"]),
		int(d["hour"]), int(d["minute"]), int(d["second"])]


## A filename safe on every desktop: lowercase a-z 0-9 _ - only, no path parts.
func _sanitize(raw: String) -> String:
	var out := ""
	for ch in raw.strip_edges().to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			out += ch
	return out.left(64)


## Never overwrite: "name.avi" -> "name_2.avi" -> "name_3.avi" ...
func _unique_path(candidate: String) -> String:
	if not FileAccess.file_exists(candidate):
		return candidate
	var stem := candidate.get_basename()
	var ext := candidate.get_extension()
	var n := 2
	while n < 10000:
		var p := "%s_%d.%s" % [stem, n, ext]
		if not FileAccess.file_exists(p):
			return p
		n += 1
	return candidate


func _crop_to_ratio(img: Image, want: float) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0 or want <= 0.0:
		return img
	var have := float(w) / float(h)
	if absf(have - want) <= 0.002:
		return img
	if have > want:
		var nw := maxi(2, int(round(float(h) * want)))
		return img.get_region(Rect2i((w - nw) / 2, 0, nw, h))
	var nh := maxi(2, int(round(float(w) / want)))
	return img.get_region(Rect2i(0, (h - nh) / 2, w, nh))


func _cleanup_frames() -> void:
	if _frame_dir == "":
		return
	_remove_tree(_frame_dir)
	_frame_dir = ""


## A crash/kill during a recording leaves ".tmp_frames_*" folders behind. They
## are never a saved video, so they are removed at the next start-up instead of
## being mistaken for the user's recordings.
func _clean_stale_temps() -> void:
	var dir := output_dir()
	if not DirAccess.dir_exists_absolute(dir):
		return
	var names := DirAccess.get_directories_at(dir)
	for n in names:
		if n.begins_with(TMP_PREFIX):
			_remove_tree(dir.path_join(n))


func _remove_tree(path: String) -> void:
	if path == "":
		return
	if DirAccess.dir_exists_absolute(path):
		for f in DirAccess.get_files_at(path):
			DirAccess.remove_absolute(path.path_join(f))
		for d in DirAccess.get_directories_at(path):
			_remove_tree(path.path_join(d))
		DirAccess.remove_absolute(path)
	else:
		DirAccess.remove_absolute(path)


func _remove_file(path: String) -> void:
	if path != "" and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _update_title() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var secs := int(elapsed_seconds())
	# M-H: the title carries the machine's REAL capture rate next to the target,
	# so a slow take is visible while it records instead of after.
	var s := capture_stats()
	var rate := ""
	if float(s["real_seconds"]) >= 0.75:
		rate = " · %.0f/%d fps" % [float(s["unique_fps"]), int(s["target_fps"])]
	DisplayServer.window_set_title("● REC %02d:%02d  %dx%d%s  —  WORLD RACE" % [
		secs / 60, secs % 60, int(settings["width"]), int(settings["height"]), rate])


func _restore_title() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_title(_title_before if _title_before != "" else "WORLD RACE")
	_title_before = ""
