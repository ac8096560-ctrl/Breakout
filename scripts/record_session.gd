extends Node
## Milestone I — ONE-CLICK RACE RECORDING (autoload "RecordSession").
##
## The recorder (GameRecorder) captures frames; this node owns the SESSION
## around it: one click validates, restarts the race through the EXISTING
## lifecycle (Game.restart_race / Game.start_race — never a second race
## manager), starts the capture before the first frame of that race, and stops
## it once — automatically, after the result screen has been on camera for a
## configurable hold, or manually at any time.
##
## STATES (the milestone's explicit recording states)
##   idle           nothing armed; the pill reads "REC — Restart & Record Race"
##   preparing      validated + the restart was issued; the next race starts
##                  the capture (never while a race is being torn down)
##   recording      GameRecorder is capturing this race
##   waiting_result the race ended; the result screen is on camera for
##                  `result_hold` seconds before the stop is issued
##   finalizing     GameRecorder.stop() was issued; the encoder thread runs
##   saved          the file exists and is verified (last_result carries it)
##   error          validation or capture failed — the game stays usable
##
## EVERY stop goes through stop()/stop_manual(), so a duplicate result signal
## (MatchRules match_ended AND the director's race_concluded, or an ending
## reported twice) can never finalize the same recording a second time.

signal state_changed(state: String)
signal session_finished(result: Dictionary)

const STATE_IDLE := "idle"
const STATE_PREPARING := "preparing"
const STATE_RECORDING := "recording"
const STATE_WAITING_RESULT := "waiting_result"
const STATE_FINALIZING := "finalizing"
const STATE_SAVED := "saved"
const STATE_ERROR := "error"

const SETTINGS_PATH := "user://record_session.cfg"
const DEFAULT_HOLD := 3.0

## The two settings this milestone adds. auto_stop is ON by default so one
## click is all it takes; result_hold is the seconds the winner screen stays
## on camera before the encoder is asked to finish.
var settings := {
	"auto_stop": true,
	"result_hold": DEFAULT_HOLD,
}

var state := STATE_IDLE
var last_error := ""
## A restart was issued and the NEXT race must start the capture in _ready,
## before any of its frames are rendered.
var pending_restart := false
## True when the capture began while the director was still counting down —
## "recording begins before the countdown" is a claim, so it is measured.
var started_before_go := false
## Result-screen hold countdown, in seconds of UNPAUSED result screen.
var hold_left := -1.0
## How many times a stop was actually issued (must be exactly 1 per take).
var stop_requests := 0
## How many authoritative race-end signals arrived (2 is normal and fine).
var end_events := 0
## True from the moment a stop is issued until the encoder reports back: the
## single guard against double finalization.
var finalizing := false

var _end_seen := false
var _race: Node = null
var _attached_id := 0


func _ready() -> void:
	# ALWAYS: the encoder callback and the result hold must keep working while
	# a modal dialog (the discard warning) has the tree paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()
	GameRecorder.recording_finished.connect(_on_recording_finished)


func _process(delta: float) -> void:
	if state != STATE_WAITING_RESULT:
		return
	var tree := get_tree()
	# A paused game records no frames, so paused time is not result-screen
	# time: the hold counts only what the video will actually contain.
	if tree != null and tree.paused:
		return
	hold_left -= delta
	if hold_left <= 0.0:
		_issue_stop()


# ---------------------------------------------------------------- settings
func load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK:
		return
	settings["auto_stop"] = bool(cf.get_value("session", "auto_stop", true))
	settings["result_hold"] = clampf(
		float(cf.get_value("session", "result_hold", DEFAULT_HOLD)), 0.0, 60.0)


func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("session", "auto_stop", bool(settings.get("auto_stop", true)))
	cf.set_value("session", "result_hold", float(settings.get("result_hold", DEFAULT_HOLD)))
	cf.save(SETTINGS_PATH)


func auto_stop_enabled() -> bool:
	return bool(settings.get("auto_stop", true))


func result_hold_seconds() -> float:
	return maxf(0.0, float(settings.get("result_hold", DEFAULT_HOLD)))


# ---------------------------------------------------------------- helpers
func is_session_recording() -> bool:
	return state == STATE_RECORDING or state == STATE_WAITING_RESULT


## The live game scene, or null when there is none (menu).
## ADAPTED FOR PIXEL BREAKOUT: identified by the game's own end signal instead
## of WorldRace's director/HUD pair.
func current_game() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var s: Node = tree.current_scene
	if s != null and is_instance_valid(s) and s.has_signal("game_ended"):
		return s
	return null


func results_visible() -> bool:
	var r := current_game()
	if r == null:
		return false
	return bool(r.call("results_visible"))


## A race whose progress would be thrown away by a restart. The COUNTDOWN
## state (0) has no progress to lose, and a finished race has a result screen
## already — neither needs the discard warning.
func race_in_progress() -> bool:
	var r := current_game()
	if r == null or results_visible():
		return false
	var s := str(r.get("state"))
	return s == "playing" or s == "ball_lost"     # a take would throw this away


## Non-destructive preflight: can this machine start a recording right now?
func validate() -> Dictionary:
	if state == STATE_PREPARING:
		return {"ok": false, "err": "a restart is already on its way"}
	if state == STATE_FINALIZING:
		return {"ok": false, "err": "the last recording is still being saved"}
	if pending_restart:
		return {"ok": false, "err": "a race is already being prepared for recording"}
	return GameRecorder.prepare()


# ---------------------------------------------------------------- starting
## One click. Validates FIRST (a failure never restarts or discards the
## current race), asks for confirmation when a race is in progress, then
## arms the capture and restarts through the existing race lifecycle.
## Returns {ok, needs_confirm, restarted, err}.
func begin(confirmed := false) -> Dictionary:
	var v := validate()
	if not bool(v.get("ok", false)):
		last_error = str(v.get("err", "recording is not available"))
		_set_state(STATE_ERROR)
		return {"ok": false, "needs_confirm": false, "restarted": false, "err": last_error}
	if not confirmed and race_in_progress():
		# nothing has happened yet — the UI shows the warning first
		return {"ok": true, "needs_confirm": true, "restarted": false, "err": ""}
	_arm()
	var game := current_game()
	if game != null:
		Game.restart_game()          # same level, same seed — the shipped path
	else:
		Game.start_game(Game.resolve_seed())
	return {"ok": true, "needs_confirm": false, "restarted": true, "err": ""}


## The settings panel's own START: records the race that is already on screen
## (no restart, no countdown re-run). Same validation, same state machine.
func begin_immediate(opts: Dictionary = {}) -> Dictionary:
	var v := validate()
	if not bool(v.get("ok", false)):
		last_error = str(v.get("err", "recording is not available"))
		_set_state(STATE_ERROR)
		return {"ok": false, "err": last_error}
	var r := GameRecorder.start(opts)
	if not bool(r.get("ok", false)):
		last_error = str(r.get("err", "the recorder did not start"))
		_set_state(STATE_ERROR)
		return {"ok": false, "err": last_error}
	_arm_recording()
	return {"ok": true, "err": ""}


func _arm() -> void:
	last_error = ""
	pending_restart = true
	_set_state(STATE_PREPARING)


## Shared by both start paths: the counters a take owns are reset exactly
## when that take begins, never between the click and the first frame.
func _arm_recording() -> void:
	pending_restart = false
	_end_seen = false
	finalizing = false
	hold_left = -1.0
	stop_requests = 0
	end_events = 0
	started_before_go = false
	_set_state(STATE_RECORDING)


# ---------------------------------------------------------------- race hookup
## Called by the RecorderPanel as soon as a race scene exists. Starts a
## PENDING capture here: the panel's _ready runs while the scene is being
## instantiated, i.e. BEFORE the first frame of the new race is rendered, so
## the countdown is on camera from frame one.
func on_race_ready(race: Node) -> void:
	_race = race
	_attach_end_signals(race)
	if not pending_restart:
		return
	var r := GameRecorder.start({})
	if not bool(r.get("ok", false)):
		last_error = str(r.get("err", "the recorder did not start"))
		pending_restart = false
		_set_state(STATE_ERROR)
		return
	_arm_recording()
	# AFTER _arm (which resets the take's own flags): the game is still in its
	# READY state, so the capture provably began before the first serve.
	started_before_go = str(race.get("state")) == "ready"


## The ONE authoritative end hook: MatchRules' match_ended and the director's
## race_concluded both land here. Nothing else (an elimination, a flood event,
## a checkpoint) can stop a recording, and only the first signal of a take
## can arm the result hold.
func _attach_end_signals(race: Node) -> void:
	if race == null or not is_instance_valid(race) \
			or race.get_instance_id() == _attached_id:
		return
	_attached_id = race.get_instance_id()
	# THE one authoritative end hook for this game: its own end signal.
	if race.has_signal("game_ended"):
		race.game_ended.connect(_on_race_end)


## A race reached its completed result state. Returns true when THIS call
## armed the result hold (so a second signal for the same race returns false).
## The payload is the signal's own argument (MatchRules passes the result
## dictionary, the director passes the rows) — the content never decides
## anything here; only "the match ended" does.
func _on_race_end(_payload: Variant = null) -> bool:
	end_events += 1
	if _end_seen:
		return false
	if state != STATE_RECORDING:
		return false
	# PART A: stamp the end of the race on the take's own clock, so the exported
	# file carries the instant the win happened. The A/V sync of the take is then
	# measured against a fact from the game, not inferred afterwards.
	GameRecorder.note_event("win" if (_payload is Dictionary and bool((_payload as Dictionary).get("won", false))) else "end")
	_end_seen = true
	if not auto_stop_enabled():
		# the user asked to keep rolling: the take stays in "recording" until
		# they stop it by hand (or the race is left).
		return false
	hold_left = result_hold_seconds()
	_set_state(STATE_WAITING_RESULT)
	return true


# ---------------------------------------------------------------- stopping
## Manual STOP (the pill / the pause-menu strip / leaving the race). Safe to
## call any number of times: only the first call issues a stop.
func stop(reason := "manual") -> Dictionary:
	if finalizing or state == STATE_FINALIZING:
		return {"ok": false, "err": "this recording is already being saved"}
	if state != STATE_RECORDING and state != STATE_WAITING_RESULT:
		return {"ok": false, "err": "nothing is being recorded"}
	var ok := _issue_stop(reason)
	return {"ok": ok, "err": last_error}


func stop_manual() -> Dictionary:
	return stop("manual")


## The single place a stop is ever issued.
func _issue_stop(reason := "auto") -> bool:
	if finalizing:
		return false
	if not GameRecorder.is_recording():
		# the recorder stopped on its own (capture error / writer refusal):
		# surface it instead of waiting for a take that will never end.
		if state == STATE_RECORDING or state == STATE_WAITING_RESULT:
			last_error = GameRecorder.last_error if GameRecorder.last_error != "" \
				else "the recorder stopped unexpectedly"
			_set_state(STATE_ERROR)
		return false
	finalizing = true
	stop_requests += 1
	_set_state(STATE_FINALIZING)
	var r := GameRecorder.stop()
	if not bool(r.get("ok", false)):
		finalizing = false
		last_error = str(r.get("err", "the recording could not be finalized"))
		_set_state(STATE_ERROR)
		return false
	return true


## The encoder thread finished: this take is saved (or failed). Only a stop
## THIS session issued may be consumed here, so a stray or duplicate
## recording_finished can never report the same file twice.
func _on_recording_finished(result: Dictionary) -> void:
	if not finalizing:
		return
	finalizing = false
	hold_left = -1.0
	pending_restart = false
	if bool(result.get("ok", false)):
		last_error = ""
		_set_state(STATE_SAVED)
	else:
		last_error = str(result.get("err", "the recording could not be saved"))
		_set_state(STATE_ERROR)
	session_finished.emit(result)


# ---------------------------------------------------------------- state
func _set_state(s: String) -> void:
	if state == s:
		return
	state = s
	state_changed.emit(s)
