class_name VideoEncoder extends RefCounted
## M-G MP4 ENCODER — the local-encoder half of the gameplay recorder.
##
## Godot 4.7 can only WRITE Motion-JPEG inside an AVI (that is what Movie Maker
## and `MjpegAviWriter` do); it cannot encode H.264. A YouTube-ready MP4
## therefore needs a real encoder, and this class uses the one that is actually
## installed on the machine: FFmpeg.
##
## The encoder is NEVER assumed to exist. `discover()` looks in the project, in
## the environment and on PATH, runs `<ffmpeg> -version`, and reports exactly
## what it found (or why it found nothing). `encode_mp4()` then runs one FFmpeg
## process over the JPEG frames the recorder already wrote to disk plus the WAV
## the audio tap captured — frames are read from disk one at a time, so a long
## recording never accumulates frames in memory — and `probe()` re-opens the
## finished file with ffprobe and returns the real stream facts.
##
## Nothing here writes a video codec: H.264 and AAC are FFmpeg's, the container
## is FFmpeg's, and the game only produces the frames and the audio samples.

## Where a bundled encoder is looked for, in order. Any FFmpeg build works;
## `tools/ffmpeg/README.md` says where the one used here came from.
const BUNDLED_PATHS := [
	"res://tools/ffmpeg/ffmpeg.exe",
	"res://tools/ffmpeg/bin/ffmpeg.exe",
	"res://tools/ffmpeg/ffmpeg",
]
## An explicit override, for a machine that keeps FFmpeg elsewhere.
const ENV_OVERRIDE := "WORLD_RACE_FFMPEG"
const ENV_OVERRIDE_PROBE := "WORLD_RACE_FFPROBE"
const HELP := "put ffmpeg.exe (and ffprobe.exe) in tools/ffmpeg/, or add FFmpeg to PATH, or set WORLD_RACE_FFMPEG"

## H.264 quality. CRF is constant-quality: 20 is visually transparent for flat
## game art and stays well inside YouTube's recommended bitrate for 1080x1920.
const CRF_DEFAULT := 20
const PRESET := "veryfast"
const AUDIO_BITRATE := "192k"
const AUDIO_RATE := 48000
const AUDIO_CHANNELS := 2

static var _discovery: Dictionary = {}
static var _discovered := false


## ---------------------------------------------------------------- discovery

## {"ok", "ffmpeg", "ffprobe", "version", "h264", "aac", "reason", "searched"}
## Cached: the settings panel asks on every refresh, and spawning a process for
## each refresh would be silly. `force` re-runs the search (used by the tests).
static func discover(force := false) -> Dictionary:
	if _discovered and not force:
		return _discovery.duplicate(true)
	_discovered = true
	var searched: Array = []
	var found := ""
	var version := ""
	var candidates: Array = []
	if OS.has_environment(ENV_OVERRIDE):
		var env_path := OS.get_environment(ENV_OVERRIDE).strip_edges()
		if env_path != "":
			candidates.append(env_path)
	for p in BUNDLED_PATHS:
		candidates.append(ProjectSettings.globalize_path(p))
	candidates.append("ffmpeg")
	for c in candidates:
		var tag: String = str(c)
		if tag.begins_with(ProjectSettings.globalize_path("res://")):
			tag = "res://" + tag.substr(ProjectSettings.globalize_path("res://").length())
		if not searched.has(tag):
			searched.append(tag)
		var out: Array = []
		var code := OS.execute(c, ["-version"], out, true)
		if code == 0 and not out.is_empty():
			# keep only the version line: `-version` also prints the whole build
			var first := str(out[0]).strip_edges().get_slice("\n", 0).strip_edges()
			if first.to_lower().begins_with("ffmpeg version"):
				found = c
				version = first.get_slice("Copyright", 0).strip_edges()
				break
	if found == "":
		_discovery = {
			"ok": false, "ffmpeg": "", "ffprobe": "", "version": "",
			"h264": false, "aac": false, "searched": searched,
			"reason": "no FFmpeg found — " + HELP,
			"help": HELP,
		}
		return _discovery.duplicate(true)
	# A sibling ffprobe is the normal case; PATH is the fallback.
	var probe := ""
	var probe_cands: Array = []
	if OS.has_environment(ENV_OVERRIDE_PROBE):
		probe_cands.append(OS.get_environment(ENV_OVERRIDE_PROBE).strip_edges())
	# ".../ffmpeg.exe" -> ".../ffprobe.exe"; never the ffmpeg binary itself.
	var pdir := found.get_base_dir()
	var is_exe := found.get_file().to_lower().ends_with(".exe")
	probe_cands.append(pdir.path_join("ffprobe.exe" if is_exe else "ffprobe"))
	probe_cands.append("ffprobe")
	for p in probe_cands:
		if p == "":
			continue
		var po: Array = []
		if OS.execute(p, ["-version"], po, true) == 0 and not po.is_empty():
			var pline := str(po[0]).strip_edges().get_slice("\n", 0).strip_edges().to_lower()
			if pline.begins_with("ffprobe version"):
				probe = p
				break
	# Codec support is asked of the build itself, not assumed.
	var enc_out: Array = []
	OS.execute(found, ["-hide_banner", "-encoders"], enc_out, true)
	var enc_text := "\n".join(enc_out)
	var h264 := enc_text.find("libx264 ") >= 0
	var aac := enc_text.find(" aac ") >= 0 or enc_text.find(" aac\n") >= 0 or enc_text.contains("AAC (Advanced Audio Coding)")
	# A take is only offered in MP4 when it can also be VERIFIED: without
	# ffprobe the recorder would write a file it cannot re-read, so the encoder
	# counts as unusable and AVI (or an explicit refusal) is the honest answer.
	var ready := readiness(h264, probe)
	var ok := bool(ready["ok"])
	var reason := str(ready["reason"])
	_discovery = {
		"ok": ok, "ffmpeg": found, "ffprobe": probe, "version": version, "h264": h264, "aac": aac,
		"searched": searched, "reason": reason,
		"help": HELP,
	}
	return _discovery.duplicate(true)


## Is this encoder pair enough to RECORD AND VERIFY an MP4? Both halves matter:
## libx264 to encode, ffprobe to re-read the finished file. Split out so the
## rule itself is testable without deleting a binary.
static func readiness(h264: bool, probe: String) -> Dictionary:
	if not h264:
		return {"ok": false, "reason": "this FFmpeg build has no libx264 H.264 encoder — " + HELP}
	if probe.strip_edges() == "":
		return {"ok": false, "reason": "FFmpeg was found but ffprobe was not, and an MP4 must be verified before it is reported — " + HELP}
	return {"ok": true, "reason": ""}


## TEST ONLY: replace the cached discovery result, so the "no encoder installed"
## path can be exercised on a machine that DOES have one (and vice versa).
## `_test_reset()` puts the real search back.
static func _test_override(d: Dictionary) -> void:
	_discovered = true
	_discovery = d.duplicate(true)


static func _test_reset() -> void:
	_discovered = false
	_discovery = {}


static func available() -> bool:
	return bool(discover().get("ok", false))


static func audio_available() -> bool:
	var d := discover()
	return bool(d.get("ok", false)) and bool(d.get("aac", false))


## A short human line for the panel ("ffmpeg 9.0.2 · H.264 + AAC" / why not).
static func summary() -> String:
	var d := discover()
	if not bool(d.get("ok", false)):
		return "MP4 unavailable: " + str(d.get("reason", "no encoder"))
	var v := str(d.get("version", "ffmpeg"))
	var bits := v.split(" ", false)
	# "9.0.2-essentials_build-www.gyan.dev" -> "9.0.2" is plenty for a panel
	var ver := (bits[2] if bits.size() > 2 else v).get_slice("-", 0)
	return "MP4 via ffmpeg %s · H.264%s" % [ver, " + AAC" if bool(d.get("aac", false)) else " (no AAC)"]


## ---------------------------------------------------------------- encoding

## Transcode captured frames + optional WAV into one MP4.
## job = {frame_dir, frames, fps, width, height, wav ("" for silent), out,
##        crf}
## Returns {ok, err, bytes, cmd, log}.
static func encode_mp4(job: Dictionary) -> Dictionary:
	var d := discover()
	if not bool(d.get("ok", false)):
		return {"ok": false, "err": str(d.get("reason", "no encoder")), "bytes": 0, "cmd": "", "log": ""}
	var frames := int(job.get("frames", 0))
	if frames <= 0:
		return {"ok": false, "err": "there are no frames to encode", "bytes": 0, "cmd": "", "log": ""}
	var w := int(job.get("width", 1080))
	var h := int(job.get("height", 1920))
	var fps := float(job.get("fps", 30.0))
	var dir := str(job.get("frame_dir", ""))
	var out := str(job.get("out", ""))
	var wav := str(job.get("wav", ""))
	if dir == "" or out == "":
		return {"ok": false, "err": "the encoder was given no frame folder or no output path", "bytes": 0, "cmd": "", "log": ""}
	if not DirAccess.dir_exists_absolute(dir):
		return {"ok": false, "err": "the frame folder is gone: " + dir, "bytes": 0, "cmd": "", "log": ""}
	if not FileAccess.file_exists(dir.path_join("%06d.jpg" % 0)):
		return {"ok": false, "err": "the first captured frame is missing", "bytes": 0, "cmd": "", "log": ""}
	var args: Array = [
		"-y", "-hide_banner", "-loglevel", "error", "-nostdin",
		"-framerate", _num(fps), "-start_number", "0",
		"-i", dir.path_join("%06d.jpg"),
	]
	var has_audio := wav != "" and FileAccess.file_exists(wav)
	if has_audio:
		args.append_array(["-i", wav])
	# The captured frames are the native 540x960 render: scale once, here, with
	# Lanczos, and hand FFmpeg planar YUV so the encoder does no guessing. The
	# JPEG frames are FULL range; HD video is normally LIMITED range BT.709, so
	# the scale filter converts the range instead of just relabelling it (that
	# is the difference between correct colours and washed-out ones on YouTube).
	args.append_array([
		"-vf", "scale=%d:%d:flags=lanczos:in_range=full:out_range=tv,format=yuv420p" % [w, h],
		"-c:v", "libx264", "-preset", PRESET, "-crf", str(int(job.get("crf", CRF_DEFAULT))),
		"-profile:v", "high", "-pix_fmt", "yuv420p",
		"-color_range", "tv", "-colorspace", "bt709",
		"-color_primaries", "bt709", "-color_trc", "bt709",
		"-movflags", "+faststart",
	])
	if has_audio:
		args.append_array(["-c:a", "aac", "-b:a", AUDIO_BITRATE,
			"-ar", str(AUDIO_RATE), "-ac", str(AUDIO_CHANNELS)])
		# A/V SYNC (brief 23, part A): the caller passes the take's OWN measured
		# ratio between the audio it captured and the video it is writing. When
		# they differ the audio is re-timed by exactly that factor, so both
		# streams share one time base instead of the audio slowly running ahead.
		# 1.0 (the normal case on a machine that keeps up) adds no filter at all.
		var atempo := clampf(float(job.get("atempo", 1.0)), 0.5, 2.0)
		var af := "apad"
		if absf(atempo - 1.0) >= 0.0005:
			af = "atempo=%.6f,apad" % atempo
		# Audio and video start together and END together. `apad` pads a tap that
		# ended a block early with silence, and `-t` cuts both streams at the
		# video's exact length. `-shortest` is NOT used: with an infinite apad
		# stream it lets the container run past the last frame.
		args.append_array(["-af", af, "-t", "%.6f" % (float(frames) / maxf(0.001, fps))])
	args.append(out)
	var log: Array = []
	var code := OS.execute(str(d.get("ffmpeg", "ffmpeg")), args, log, true)
	var text := "\n".join(log)
	if code != 0:
		if FileAccess.file_exists(out):
			DirAccess.remove_absolute(out)
		var first := ""
		for line in log:
			var s := str(line).strip_edges()
			if s != "":
				first = s
				break
		return {"ok": false, "err": "ffmpeg failed (exit %d): %s" % [code, first if first != "" else "no output"],
			"bytes": 0, "cmd": " ".join(args), "log": text}
	if not FileAccess.file_exists(out):
		return {"ok": false, "err": "ffmpeg reported success but wrote no file", "bytes": 0, "cmd": " ".join(args), "log": text}
	var size := 0
	var f := FileAccess.open(out, FileAccess.READ)
	if f != null:
		size = int(f.get_length())
		f.close()
	if size < 1024:
		DirAccess.remove_absolute(out)
		return {"ok": false, "err": "the encoded file is empty (%d bytes)" % size, "bytes": 0, "cmd": " ".join(args), "log": text}
	return {"ok": true, "err": "", "bytes": size, "cmd": " ".join(args), "log": text, "audio": has_audio}


## ---------------------------------------------------------------- probing

## Read the real streams out of a finished file with ffprobe.
## {ok, err, width, height, fps, duration, bytes, format, vcodec, acodec,
##  has_audio, audio_rate, audio_channels, frames_raw}
static func probe(path: String) -> Dictionary:
	var d := discover()
	var probe_path := str(d.get("ffprobe", ""))
	if probe_path == "":
		return {"ok": false, "err": "ffprobe is not available — " + HELP, "has_audio": false}
	if not FileAccess.file_exists(path):
		return {"ok": false, "err": "the file does not exist: " + path, "has_audio": false}
	var out: Array = []
	var code := OS.execute(probe_path, ["-v", "error", "-print_format", "json",
		"-show_format", "-show_streams", path], out, true)
	if code != 0:
		return {"ok": false, "err": "ffprobe could not read the file (exit %d)" % code, "has_audio": false}
	var text := "\n".join(out)
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "err": "ffprobe returned unreadable output", "has_audio": false}
	var res := {"ok": true, "err": "", "width": 0, "height": 0, "fps": 0.0,
		"duration": 0.0, "bytes": 0, "format": "", "vcodec": "", "acodec": "",
		"has_audio": false, "audio_rate": 0, "audio_channels": 0, "nb_frames": 0}
	var fmt: Dictionary = data.get("format", {})
	res["format"] = str(fmt.get("format_name", ""))
	res["duration"] = float(fmt.get("duration", 0.0))
	res["bytes"] = int(fmt.get("size", 0))
	for s in (data.get("streams", []) as Array):
		var st: Dictionary = s
		match str(st.get("codec_type", "")):
			"video":
				if int(res["width"]) == 0:
					res["width"] = int(st.get("width", 0))
					res["height"] = int(st.get("height", 0))
					res["vcodec"] = str(st.get("codec_name", ""))
					res["fps"] = _parse_rate(str(st.get("avg_frame_rate", st.get("r_frame_rate", "0/1"))))
					res["nb_frames"] = int(st.get("nb_frames", 0))
			"audio":
				if not bool(res["has_audio"]):
					res["has_audio"] = true
					res["acodec"] = str(st.get("codec_name", ""))
					res["audio_rate"] = int(st.get("sample_rate", 0))
					res["audio_channels"] = int(st.get("channels", 0))
	if float(res["duration"]) <= 0.0:
		for s in (data.get("streams", []) as Array):
			var st2: Dictionary = s
			if str(st2.get("codec_type", "")) == "video":
				res["duration"] = float(st2.get("duration", 0.0))
				break
	if int(res["width"]) <= 0 or int(res["height"]) <= 0:
		res["ok"] = false
		res["err"] = "the file has no readable video stream"
	if int(res["bytes"]) <= 0:
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			res["bytes"] = int(f.get_length())
			f.close()
	return res


## ffprobe gives "30000/1001"; never divide by zero.
static func _parse_rate(rate: String) -> float:
	var parts := rate.split("/")
	if parts.size() == 2:
		var a := float(parts[0])
		var b := float(parts[1])
		if b != 0.0:
			return a / b
	return float(rate) if rate.is_valid_float() else 0.0


static func _num(v: float) -> String:
	if is_equal_approx(v, roundf(v)):
		return str(int(roundf(v)))
	return String.num(v, 3)
