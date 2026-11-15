extends Node
## AUDIO MANAGER (autoload "AudioManager") — the ONE place a sound is played.
##
## Every gameplay/UI script calls `AudioManager.play("splash")`; nothing else
## touches AudioStreamPlayer, so there is a single table of effects, a single
## volume policy and a single place that decides when a repeat is suppressed.
##
## Design rules (audio milestone):
##   * Buses: Master -> SFX and Master -> Music. The manager creates SFX/Music
##     at runtime if they are missing (no default_bus_layout.tres to maintain)
##     and puts a hard limiter on Master, so layering can never clip.
##   * Every effect has a SMALL fixed pool of AudioStreamPlayer voices. A
##     same-event repeat inside its `gap_ms` window is dropped instead of
##     stacking, and when the pool is exhausted the oldest voice is reused —
##     the same sound can never pile up.
##   * Volumes are independent (master / sfx / music), clamped 0..1, stored in
##     user://wrace_audio.json and re-applied on boot. 0 = muted bus.
##   * play() refuses unknown names and records them in stats().missing, so a
##     typo can never fail silently — the audio test asserts the list is empty.
##
## The WAVs in res://audio/ are original: they are synthesised from scratch by
## tools/gen_audio.cjs (see AUDIO_MILESTONE_REPORT.md).

signal played(event_name: String)

const AUDIO_DIR := "res://audio/"
const SETTINGS_PATH := "user://breakout_audio.json"
const BUS_MASTER := "Master"
const BUS_SFX := "SFX"
const BUS_MUSIC := "Music"
const DEFAULT_VOLUMES := {"master": 0.9, "sfx": 0.85, "music": 0.5}

## THE event table. `db` is the per-effect trim, `voices` the maximum number of
## simultaneous copies, `gap_ms` the minimum spacing between two plays of the
## same event (0 = always allowed).
## Breakout's own event table (the WorldRace race events are gone). A brick
## break is the most repeated event in the game, so it is quiet and tightly
## gapped; a lost life and the win/lose jingles are the loudest things in the
## mix.
const EVENTS := {
	"bounce": {"file": "bounce.wav", "db": -15.0, "voices": 3, "gap_ms": 40},
	"brick_break": {"file": "brick_break.wav", "db": -13.0, "voices": 3, "gap_ms": 30},
	"powerup": {"file": "powerup.wav", "db": -8.0, "voices": 2, "gap_ms": 80},
	"lose_life": {"file": "lose_life.wav", "db": -6.0, "voices": 1, "gap_ms": 300},
	"click": {"file": "click.wav", "db": -13.0, "voices": 2, "gap_ms": 55},
	"confirm": {"file": "confirm.wav", "db": -9.0, "voices": 2, "gap_ms": 120},
	"start": {"file": "start.wav", "db": -5.0, "voices": 1, "gap_ms": 300},
	"countdown": {"file": "countdown.wav", "db": -6.0, "voices": 1, "gap_ms": 120},
	"victory": {"file": "victory.wav", "db": -3.0, "voices": 1, "gap_ms": 900},
	"defeat": {"file": "defeat.wav", "db": -3.0, "voices": 1, "gap_ms": 900},
	"error": {"file": "error.wav", "db": -10.0, "voices": 1, "gap_ms": 200},
}

var _streams := {}      # event -> AudioStream (loaded once)
var _pools := {}        # event -> Array[AudioStreamPlayer]
var _cursor := {}       # event -> next voice index
var _last_ms := {}      # event -> ticks of the last accepted play
var _missing: Array = []# event names asked for but not in EVENTS / not loadable
var _plays := {}        # event -> accepted play count (since reset_stats)
var _suppressed := 0    # plays dropped by the gap/pool policy
var _volumes := {}


func _ready() -> void:
	_ensure_buses()
	load_settings()
	_build_pools()


## ---------------------------------------------------------------- buses
func _ensure_buses() -> void:
	var master := AudioServer.get_bus_index(BUS_MASTER)
	if master < 0:
		return  # Master always exists; nothing sensible to do if it does not
	for name in [BUS_SFX, BUS_MUSIC]:
		if AudioServer.get_bus_index(name) < 0:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, name)
			AudioServer.set_bus_send(idx, BUS_MASTER)
	# a limiter on Master keeps stacked effects below 0 dBFS
	var master_idx := AudioServer.get_bus_index(BUS_MASTER)
	if master_idx >= 0 and AudioServer.get_bus_effect_count(master_idx) == 0:
		if ClassDB.class_exists("AudioEffectHardLimiter"):
			var lim = ClassDB.instantiate("AudioEffectHardLimiter")
			lim.set("ceiling_db", -0.5)
			AudioServer.add_bus_effect(master_idx, lim)
		elif ClassDB.class_exists("AudioEffectLimiter"):
			var lim2 = ClassDB.instantiate("AudioEffectLimiter")
			AudioServer.add_bus_effect(master_idx, lim2)


func bus_index(kind: String) -> int:
	var name := BUS_MASTER
	match kind:
		"sfx":
			name = BUS_SFX
		"music":
			name = BUS_MUSIC
	return AudioServer.get_bus_index(name)


## ---------------------------------------------------------------- pools
func _build_pools() -> void:
	for ev in EVENTS:
		var spec: Dictionary = EVENTS[ev]
		var stream: AudioStream = load(AUDIO_DIR + str(spec.get("file", "")))
		if stream == null:
			_missing.append(ev)
			continue
		_streams[ev] = stream
		var voices := maxi(1, int(spec.get("voices", 1)))
		var pool: Array = []
		for i in voices:
			var p := AudioStreamPlayer.new()
			p.name = "%s_%d" % [ev, i]
			p.stream = stream
			p.bus = BUS_SFX
			p.process_mode = Node.PROCESS_MODE_ALWAYS   # UI clicks still sound while paused
			add_child(p)
			pool.append(p)
		_pools[ev] = pool
		_cursor[ev] = 0


## ---------------------------------------------------------------- playback
## Play one effect. `db_offset` lets a caller trim a single instance (a gentle
## bump vs a hard hit) without changing the shared table. Returns true when the
## sound was actually started.
func play(event_name: String, db_offset := 0.0) -> bool:
	if not EVENTS.has(event_name):
		if not _missing.has(event_name):
			_missing.append(event_name)
		return false
	var spec: Dictionary = EVENTS[event_name]
	var now := Time.get_ticks_msec()
	var gap := int(spec.get("gap_ms", 0))
	if gap > 0 and _last_ms.has(event_name) and now - int(_last_ms[event_name]) < gap:
		_suppressed += 1
		return false
	var pool: Array = _pools.get(event_name, [])
	if pool.is_empty():
		if not _missing.has(event_name):
			_missing.append(event_name)
		return false
	var idx := int(_cursor.get(event_name, 0)) % pool.size()
	_cursor[event_name] = idx + 1
	var p: AudioStreamPlayer = pool[idx]
	if p.playing:
		p.stop()   # reuse the oldest voice instead of stacking
	p.stream = _streams[event_name]
	p.volume_db = float(spec.get("db", 0.0)) + db_offset
	p.play()
	_last_ms[event_name] = now
	_plays[event_name] = int(_plays.get(event_name, 0)) + 1
	played.emit(event_name)
	return true


## Strength-aware variant for physical events (impact 0..1): louder hit = closer
## to the effect's own trim, softer hit = up to 14 dB quieter.
func play_scaled(event_name: String, strength: float) -> bool:
	var s := clampf(strength, 0.0, 1.0)
	return play(event_name, -14.0 * (1.0 - s))


## ---------------------------------------------------------------- volumes
func volume(kind: String) -> float:
	var key := kind if DEFAULT_VOLUMES.has(kind) else "master"
	return float(_volumes.get(key, DEFAULT_VOLUMES[key]))


func set_volume(kind: String, linear: float) -> void:
	var key := kind if DEFAULT_VOLUMES.has(kind) else "master"
	var v := clampf(linear, 0.0, 1.0)
	_volumes[key] = v
	_apply_bus(key, v)
	save_settings()


func _apply_bus(kind: String, linear: float) -> void:
	var idx := bus_index(kind)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.001)))


func load_settings() -> void:
	_volumes = DEFAULT_VOLUMES.duplicate(true)
	if FileAccess.file_exists(SETTINGS_PATH):
		var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				for k in DEFAULT_VOLUMES:
					var v: Variant = (parsed as Dictionary).get(k, null)
					if v is int or v is float:
						_volumes[k] = clampf(float(v), 0.0, 1.0)
	for k in DEFAULT_VOLUMES:
		_apply_bus(k, float(_volumes[k]))


func save_settings() -> String:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f == null:
		return "cannot write %s" % SETTINGS_PATH
	f.store_string(JSON.stringify(_volumes, "  "))
	f.close()
	return ""


## ---------------------------------------------------------------- introspection (tests)
func event_names() -> Array:
	return EVENTS.keys()


func stream_for(event_name: String) -> AudioStream:
	return _streams.get(event_name, null)


func voices_for(event_name: String) -> int:
	return (_pools.get(event_name, []) as Array).size()


func reset_stats() -> void:
	_plays.clear()
	_suppressed = 0
	_missing.clear()
	_last_ms.clear()
	for ev in _cursor:
		_cursor[ev] = 0


func stats() -> Dictionary:
	return {
		"plays": _plays.duplicate(true),
		"suppressed": _suppressed,
		"missing": _missing.duplicate(),
		"total_played": _total_plays(),
	}


func _total_plays() -> int:
	var n := 0
	for k in _plays:
		n += int(_plays[k])
	return n


## Release the pooled players' playbacks at shutdown, so an effect that is still
## sounding when the process exits cannot leave a leaked stream/playback behind.
func _exit_tree() -> void:
	stop_all()
	for ev in _pools:
		for p in _pools[ev]:
			if is_instance_valid(p):
				p.free()   # release the players before the tree tears itself down
	_pools.clear()
	_streams.clear()


## Stop every voice (used when a scene ends so a jingle cannot bleed into the
## next race). Pending gap timers are cleared so the next race's first sound is
## never swallowed by the previous one.
func stop_all() -> void:
	for ev in _pools:
		for p in _pools[ev]:
			if is_instance_valid(p):
				p.stop()
				# drop the reference too: an idle player holding a stream keeps the
				# playback (and the WAV) alive until the process exits
				p.stream = null
	_last_ms.clear()
