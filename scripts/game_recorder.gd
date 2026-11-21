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
## The SLOT (wall clock / frame period) each captured picture was taken at. The
## finaliser needs it to place the picture back on the real timeline: index-only
## pacing silently re-times the take whenever the capture rate varies.
var _slots: Array = []
## Wall-clock marks of game events, taken while recording (see note_event).
var _events := {}
var _start_us := 0
# BRIEF 28: THE VIDEO CLOCK IS THE PHYSICS CLOCK. `_start_phys` is the physics
# frame the take began on, `_paused_phys` the physics frames that elapsed while
# the game was paused (a pause is not a slow recording), and `_last_phys` the
# count seen at the previous tick — which is how the paused frames are measured
# exactly instead of approximated from a render delta.
var _start_phys := 0
var _paused_phys := 0
var _last_phys := 0
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


## Mark a game event on the TAKE's clock (PART A). RecordSession calls this the
## instant the race ends, so the finished file carries the moment the win
## happened: the sync of the exported video can then be checked against the take
## itself instead of guessed from the machine.
func note_event(event: String) -> void:
	if state == STATE_RECORDING:
		_events[event] = recorded_seconds()


## Length of the video captured so far (captured frames / target FPS).
func elapsed_seconds() -> float:
	return float(_frames) / maxf(1.0, float(settings.get("fps", 30)))


## BRIEF 28: THE TAKE'S TIMELINE IS THE GAME'S OWN CLOCK.
## Physics frames elapsed since START, minus every frame that elapsed while the
## game was paused (a pause is not a slow recording). Both the video's slots and
## the audio's placement are derived from this one number.
func recorded_physics() -> int:
	if _start_us <= 0:
		return 0
	return maxi(0, Engine.get_physics_frames() - _start_phys - _paused_phys)


## The take's timeline in GAME seconds — the clock the video's slots live on.
func recorded_seconds() -> float:
	return float(recorded_physics()) / maxf(1.0, float(Engine.physics_ticks_per_second))


## The take's WALL length (pauses excluded). Never used for the timeline: it is
## only the honest denominator for the machine's capture rate, because "this
## machine drew 20 pictures in the last second" is a wall-clock statement.
func wall_seconds() -> float:
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
		real = wall_seconds()
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
	_slots = []
	_events = {}
	_cap_read_us = 0
	_cap_enc_us = 0
	_cap_wr_us = 0
	_render_frames = 0
	_cap_main_us = 0
	_cap_overflow = 0
	_last_push_slot = -1
	_paused_us = 0
	_paused_phys = 0
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
	_start_us = Time.get_ticks_usec()
	# BRIEF 28: both streams are stamped against this physics frame from here on.
	_start_phys = Engine.get_physics_frames()
	_paused_phys = 0
	_last_phys = _start_phys
	# M-G: tap the game's mixed audio for the MP4 path. A machine without an
	# audio output (or without AAC) simply records video — never an error.
	_audio = null
	if _use_mp4 and audio_enabled():
		var tap := AudioCapture.new()
		if tap.start(_frame_dir.path_join(AUDIO_TMP)):
			_audio = tap
			# BRIEF 28: the take's audio map has an ORIGIN (audio 0 ↔ game 0).
			# Without this stamp the first entry is the first DRAIN, which arrives
			# after the take's slowest frame — and measuring from there shifts
			# every later sound earlier by that stall.
			tap.mark(0)
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
	# BRIEF 28: the take's length is its PHYSICS clock's, and the finalizer lays
	# the captured pictures out on that same clock — no tail to fill by hand.
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
		"real_seconds": wall_seconds(),
		"cap_read_us": _cap_read_us, "cap_enc_us": _cap_enc_us, "cap_wr_us": _cap_wr_us,
		"render_frames": _render_frames, "cap_main_us": _cap_main_us, "overflow": _cap_overflow,
		"mp4": _use_mp4, "wav": str(audio.get("path", "")) if bool(audio.get("ok", false)) else "",
		"audio_seconds": float(audio.get("seconds", 0.0)), "audio_peak": float(audio.get("peak", 0.0)),
		"slots": _slots.duplicate(), "events": _events.duplicate(),
		"audio_marks": (audio.get("marks", []) as Array).duplicate(),
		"phys_per_sec": int(Engine.physics_ticks_per_second),
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
	# BRIEF 28: TIMING IS DRIVEN BY THE PHYSICS CLOCK, not by the wall clock.
	# The slot a picture belongs to is its PHYSICS frame on the video grid (60
	# physics/s ÷ 30 video fps = 2 physics frames per slot), so a picture is
	# stamped with the GAME time it shows. Before this, a picture carried the
	# wall-clock moment it was DRAWN: while a take warms up (the first second
	# renders at ~2 FPS) the picture lagged the sound by up to half a second, an
	# error concentrated at the start that no constant atempo can repair. Paused
	# frames are already excluded from `recorded_physics()`.
	var slot := physics_slot(recorded_physics(),
		int(Engine.physics_ticks_per_second), float(settings.get("fps", 30)))
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
	_slots.append(slot)
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


## How many OUTPUT frames (30 FPS slots) this take must have. It is the physics
## clock's position at STOP — the same timeline the audio is placed on — so the
## video can never be shorter than the race, and the last fraction of a second
## (which has no captured picture) is covered by the pacing below instead of by
## a bespoke tail fill.
func _total_slots() -> int:
	return maxi(_captured, int(round(recorded_seconds() * float(settings.get("fps", 30)))))


## Brief 23 A — THE TIMELINE: every picture goes back where it was TAKEN.
##
## M-J placed picture k at round(k * total / count), i.e. evenly in picture
## INDEX, which is the real timeline only when the machine captures at a
## constant rate. It does not: the render rate swings from 8 to 40 FPS inside
## one race, so index pacing silently RE-TIMES the take. On a real take both
## streams had the same total length (video 71.200 s, audio 71.200 s) and yet
## the win popup sat 5.1 s away from the victory jingle, and the brick-break
## sounds scattered +-3.7 s around their pictures: the picture clock itself was
## bent. No audio correction can fix that from the outside — it would have to
## bend the audio around a bent picture clock.
##
## So each captured picture carries the slot it was taken at (`_slots`):
## hold = the real gap to the next picture. A machine that keeps up (one picture
## per slot) gets hold 1 everywhere, exactly like before; a machine that misses
## slots holds the previous picture for the missed frames, which is what the eye
## saw anyway. The sequence is still exactly `total` frames, so the file's
## duration is still the take's wall-clock duration.
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


## The holds for `count` pictures laid out on the take's own slot clock, always
## summing to exactly `total` frames. Falls back to even spacing only when there
## is no slot data for these pictures.
static func timeline_holds(slots: Array, count: int, total: int) -> Array:
	var s: Array = slots
	if s.size() > count:
		s = s.slice(0, count)
	if count > 0 and s.size() == count:
		return slot_holds(s, total)
	return pace_holds(count, total)


static func slot_holds(slots: Array, total: int) -> Array:
	var count := slots.size()
	var out: Array = []
	if count <= 0 or total <= 0:
		return out
	var prev := 0
	for i in count:
		# The next picture's slot is where this one stops being on screen; the
		# last one runs to the end of the take.
		var next_bound := total if i + 1 >= count else int(slots[i + 1])
		# Leave at least one frame for every picture still to come.
		var room := maxi(prev + 1, total - (count - 1 - i))
		var cut := clampi(next_bound, prev + 1, room)
		out.append(cut - prev)
		prev = cut
	# Any tail (slots that never arrived) belongs to the last picture.
	if prev < total:
		out[count - 1] = int(out[count - 1]) + (total - prev)
	return out


## Even spacing, only for a take with no slot data at all.
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
		"note": str(job.get("note", "")), "audio_seconds": float(job.get("audio_seconds", 0.0)),
		# PART A evidence: the moment the win happened on the take's own clock, so
		# the finished file can be checked against the game instead of a guess.
		"sync_win_seconds": float((job.get("events", {}) as Dictionary).get("win", -1.0))}
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
	var holds := timeline_holds(job.get("slots", []), count, total)
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


## ------------------------------------------------------------ A/V sync (A)
## THE TAKE'S OWN DRIFT, MEASURED — never a constant.
##
## The two streams are produced by two different clocks and the encoder used to
## mux them as if they agreed:
##   * the VIDEO is laid out on the recorder's slot clock (wall time,
##     `_total_slots()` = captured/recorded seconds at the target FPS);
##   * the AUDIO is whatever the audio thread actually mixed while the take
##     ran. Under software rendering the mixer does not always get its full
##     1/rate per second of wall time (it shares a CPU with llvmpipe), so the
##     WAV covers LESS time than the video does.
## Muxing those two unchanged is what a viewer hears as drift: every sound
## arrives a little earlier than the picture, and the error grows across the
## take (measured 0.12 s at the first brick -> 0.97 s at the win on the
## reference take).
##
## The fix is to give both streams ONE time base at encode time: the ratio of
## the take's own two lengths is exactly the factor the audio must be re-timed
## by, so the audio ends where the video ends. It is computed per take from
## that take's numbers, so a fast machine (ratio 1.000) is left completely
## alone and a slow one is corrected by its own measured drift. A fixed atempo
## constant could never do this.
##
## `audio_seconds` comes from the tap's own sample count (frames_written /
## rate), and `video_seconds` from the frame count the file will hold, so this
## measures the artifact that gets written, not a guess about the machine.
const SYNC_TOLERANCE := 0.002   # 0.2 % = 120 ms in a minute: below this, nothing is touched
const SYNC_ATEMPO_MIN := 0.5
const SYNC_ATEMPO_MAX := 2.0


## The factor to re-time the recorded audio by so it covers the video's length
## exactly (1.0 = already in sync, leave it alone).
static func audio_time_scale(audio_seconds: float, video_seconds: float) -> float:
	if audio_seconds <= 0.0 or video_seconds <= 0.0:
		return 1.0
	var ratio := audio_seconds / video_seconds
	if absf(ratio - 1.0) < SYNC_TOLERANCE:
		return 1.0
	return clampf(ratio, SYNC_ATEMPO_MIN, SYNC_ATEMPO_MAX)


## --------------------------------------------------------------------------
## BRIEF 28 — THE AUDIO ON THE SAME CLOCK AS THE VIDEO
##
## Under software rendering the game runs slower than real time, and the take's
## two streams were built from two different clocks:
##   * the VIDEO's slots came from the WALL clock, so a picture was stamped with
##     the moment it was DRAWN, not with the game state it shows;
##   * the AUDIO tap captures the mixer in REAL time.
## Within one take those two agree closely (a slow frame hears and shows the
## same game state), which is why a constant ratio almost worked. The file is
## now re-timed onto the GAME clock, so the audio must be re-timed by the same
## LOCAL factor — not by one constant, because the machine's game/wall rate
## changes during a take (it is worst exactly where the renderer is slowest).
## Both streams therefore run on the PHYSICS clock:
##   * `physics_slot()` gives a picture its video slot from the physics-frame
##     count, and
##   * the tap is stamped (`AudioCapture.mark`) with the physics frame it was
##     drained at — including the origin at take start — which yields this
##     take's OWN map from audio samples to game time. `audio_clock_segments()`
##     turns that map into a short chain of pitch-preserving `atempo` segments
##     (0.25 s through the warm-up, coarser after it), so each block of audio is
##     placed where its physics frame is.
## Nothing here is a constant: a take with no usable stamps yields no segments
## and keeps the single-ratio correction as the safety net.

## The video slot of a picture, from the take's physics-frame clock. 60 physics
## frames/sec ÷ 30 video frames/sec = 2 physics frames per slot, so the slot
## grid follows GAME time: a machine that only draws 2 pictures in a second
## still gets the right number of slots for the physics frames that elapsed.
static func physics_slot(phys_elapsed: int, phys_per_sec: int, fps: float) -> int:
	var per := maxf(1.0, float(maxi(1, phys_per_sec)) / maxf(1.0, fps))
	return int(floor(float(maxi(0, phys_elapsed)) / per))


## The source-audio moment that belongs at `game_seconds` on the take's own
## map ({audio, phys} stamps). Linear between stamps, held at the ends.
static func audio_time_at(pts: Array, game_seconds: float) -> float:
	if pts.is_empty():
		return 0.0
	var prev: Vector2 = pts[0]
	if game_seconds <= prev.y:
		return 0.0
	for i in range(1, pts.size()):
		var cur: Vector2 = pts[i]
		if game_seconds <= cur.y:
			var span := cur.y - prev.y
			if span <= 0.0001:
				return cur.x
			return prev.x + (cur.x - prev.x) * ((game_seconds - prev.y) / span)
		prev = cur
	return prev.x


## Where a source-audio moment lands on the game clock after the mapping. The
## primitive the recorder test uses to prove the PLACEMENT, not just the count.
static func clock_time_at(segments: Array, audio_t: float) -> float:
	var t := 0.0
	for s in segments:
		var seg: Dictionary = s
		var st := float(seg.get("start", 0.0))
		var en := float(seg.get("end", 0.0))
		var tp := maxf(0.0001, float(seg.get("tempo", 1.0)))
		if audio_t < st:
			return t
		t += minf(en - st, maxf(0.0, audio_t - st)) / tp
		if audio_t <= en + 0.0001:
			return t
	return t


## THIS TAKE'S map from audio samples to game time, as atempo segments.
##
## `marks` are the tap's {audio, phys} stamps; `video_seconds` is how long the
## video will be; `audio_seconds` is the WAV's length. Each segment carries the
## span of the recorded WAV it consumes, the tempo (source span ÷ target span)
## that turns it into the game-time span it belongs to, and the `atempo` stages
## that realise that tempo legally. Empty means "no usable map" and the caller
## keeps the old single-ratio correction.
static func audio_clock_segments(marks: Array, video_seconds: float, phys_per_sec: int,
		audio_seconds: float = 0.0, max_segments: int = 48) -> Array:
	if video_seconds <= 0.0:
		return []
	var pps := float(maxi(1, phys_per_sec))
	# The map's origin is the START OF THE TAKE (audio 0 ↔ game 0), never the
	# first stamp: the first drain arrives after the take's first — and slowest —
	# frame, so re-basing on it would shift every later sound EARLIER by exactly
	# that stall. That is what a real take measured: -0.45 s at the first brick.
	var pts: Array = [Vector2(0.0, 0.0)]
	for m in marks:
		if not (m is Dictionary):
			continue
		var d: Dictionary = m
		var a := float(d.get("audio", -1.0))
		if a < 0.0:
			continue
		var g := float(maxi(0, int(d.get("phys", 0)))) / pps
		var last: Vector2 = pts[pts.size() - 1]
		# A stamp that does not move forward carries no information and would
		# break the inverse lookup.
		if a <= last.x + 0.0005:
			continue
		pts.append(Vector2(a, maxf(last.y, g)))
	if pts.size() < 3:
		return []
	# The map can end a frame before the video does: extend it with its own
	# final slope instead of inventing a jump.
	var lastp: Vector2 = pts[pts.size() - 1]
	if lastp.y < video_seconds and pts.size() >= 2:
		var prevp: Vector2 = pts[pts.size() - 2]
		var slope := (lastp.x - prevp.x) / maxf(0.0001, lastp.y - prevp.y)
		pts.append(Vector2(lastp.x + (video_seconds - lastp.y) * slope, video_seconds))
	# Segment cuts in GAME time: fine through the warm-up (where the transient
	# lives), coarse afterwards, and never more than `max_segments` of them.
	var cuts: Array = []
	var head := minf(video_seconds, 6.0)
	var t := 0.0
	while t < head - 0.0001:
		cuts.append(t)
		t += 0.25
	var rest := video_seconds - t
	if rest > 0.0001:
		var left := maxi(1, max_segments - cuts.size())
		var step := maxf(0.5, rest / float(left))
		while t < video_seconds - 0.0001:
			cuts.append(t)
			t += step
	cuts.append(video_seconds)
	var out: Array = []
	var a_prev := 0.0
	for i in cuts.size() - 1:
		var t0 := float(cuts[i])
		var t1 := float(cuts[i + 1])
		if t1 - t0 <= 0.0001:
			continue
		var a0 := a_prev
		var a1 := audio_time_at(pts, t1)
		if audio_seconds > 0.0:
			a1 = minf(a1, audio_seconds)
		if a1 <= a0 + 0.0001:
			continue
		var tempo := (a1 - a0) / (t1 - t0)
		var stages := atempo_stages(tempo)
		if stages.size() == 1:
			tempo = float(stages[0])
			a1 = a0 + tempo * (t1 - t0)
		out.append({"start": a0, "end": a1, "tempo": tempo, "stages": stages})
		a_prev = a1
	if out.size() < 2:
		return []
	return out


## One segment's tempo as legal `atempo` links. FFmpeg's filter is stable only
## inside [0.5, 2.0] per link, so a segment that needs more is SPLIT into a
## chain whose stages multiply back to the requested tempo — the mapping stays
## exact. Clamping instead would re-time the segment wrongly and move every
## sound after it.
static func atempo_stages(tempo: float) -> Array:
	if not is_finite(tempo) or tempo <= 0.0:
		return [1.0]
	var stages: Array = []
	var t := tempo
	while t > SYNC_ATEMPO_MAX and stages.size() < 3:
		stages.append(SYNC_ATEMPO_MAX)
		t /= SYNC_ATEMPO_MAX
	while t < SYNC_ATEMPO_MIN and stages.size() < 3:
		stages.append(SYNC_ATEMPO_MIN)
		t /= SYNC_ATEMPO_MIN
	if t > SYNC_ATEMPO_MAX or t < SYNC_ATEMPO_MIN:
		# More than four links is not a correction, it is a broken map: keep the
		# single legal ratio instead of an absurd chain.
		return [clampf(tempo, SYNC_ATEMPO_MIN, SYNC_ATEMPO_MAX)]
	var prod := 1.0
	for s in stages:
		prod *= float(s)
	# The last link is the exact remainder, so the chain lands on the requested
	# tempo and the segment still consumes exactly `end - start` of the WAV.
	stages.append(clampf(tempo / prod, 0.01, 100.0))
	return stages


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
	var holds: Array = timeline_holds(job.get("slots", []), count, total)
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
	# BRIEF 28: place the audio on the video's clock. The tap's own physics
	# stamps give THIS take's map from samples to game time, which the encoder
	# turns into a short atempo chain — automatic, per take. The constant ratio
	# is kept as the fallback (and is reported) only for a take whose stamps are
	# missing or unusable; when the map is used the two are mutually exclusive,
	# never stacked, because two corrections fighting each other is the failure
	# this brief exists to remove.
	var video_seconds := float(total) / maxf(0.001, fps)
	var audio_seconds := float(job.get("audio_seconds", 0.0))
	var segments: Array = []
	if want_audio:
		segments = audio_clock_segments(job.get("audio_marks", []), video_seconds,
			int(job.get("phys_per_sec", 60)), audio_seconds)
	var atempo := audio_time_scale(audio_seconds, video_seconds)
	if segments.size() >= 2:
		atempo = 1.0
	result["sync_audio_seconds"] = audio_seconds
	result["sync_video_seconds"] = video_seconds
	result["sync_atempo"] = atempo
	result["sync_clock"] = "game" if segments.size() >= 2 else "linear"
	result["sync_segments"] = segments.size()
	var stages_max := 1
	for s in segments:
		stages_max = maxi(stages_max, ((s as Dictionary).get("stages", []) as Array).size())
	result["sync_stages_max"] = stages_max
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
		"crf": int(job.get("crf", 20)), "atempo": atempo,
		"atempo_segments": segments, "audio_seconds": audio_seconds,
	})
	result["encode_ms"] = Time.get_ticks_msec() - t_enc
	_mutex.lock()
	_progress = int(total * 0.85)
	_mutex.unlock()
	if not bool(enc.get("ok", false)):
		result["err"] = str(enc.get("err", "the MP4 encoder failed"))
		_remove_file(out)
		return result
	# The encoder reports which correction it ACTUALLY used, so the take's
	# record can never claim a mapping that was silently dropped.
	result["sync_segments"] = int(enc.get("segments", 0))
	if int(enc.get("segments", 0)) >= 2:
		result["sync_clock"] = "game"
	elif str(result.get("sync_clock", "")) == "game":
		result["sync_clock"] = "linear"
		result["sync_stages_max"] = 0
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
		var phys_now := Engine.get_physics_frames()
		if paused_now:
			# BOTH clocks drop the pause: the wall milliseconds AND the physics
			# frames that elapsed, so resuming continues where the pause started.
			_paused_us += int(delta * 1000000.0)
			_paused_phys += maxi(0, phys_now - _last_phys)
		_last_phys = phys_now
		if _audio != null:
			if paused_now:
				_audio.discard()
			else:
				_audio.drain()
				# BRIEF 28: stamp the block with the physics frame it was mixed for.
				_audio.mark(recorded_physics())
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
