class_name RecorderPanel extends Control
## M-F/M-I GAMEPLAY RECORDER — the in-game control surface.
##
## M-I ONE-CLICK: the compact REC pill in the bottom-right corner is now the
## whole workflow. Pressed while idle it validates the recorder, asks for
## confirmation if a race would be thrown away, restarts the race through the
## EXISTING lifecycle and records it from the countdown; the session
## (autoload RecordSession) then stops it automatically once the result screen
## has been on camera for the configured hold. The pill reads
## "REC — Record Take" / "STOP RECORDING" / "Saving video…", and the
## small SET button next to it opens the settings panel (format, size, fps,
## quality, audio, folder, auto-stop, result hold) whose own START records the
## CURRENT race without restarting it — the pre-M-I behaviour, still there.
##
## While a recording runs, STOP also lives in the PAUSE MENU, and pausing
## SUSPENDS capture — so no recorder control can ever appear in the exported
## video. The live status (REC + elapsed) is shown in the OS window title,
## which the game does not render. A user who WANTS the chip burned in can
## enable that in the panel ("burn the REC chip into the video"); it then
## behaves like any other overlay and is captured on purpose.
##
## All real work (capture, sizing, encoding, verification, the session state
## machine) belongs to the GameRecorder / RecordSession autoloads; this node
## only reads/writes their settings and draws the controls.

const PANEL_POS := Vector2(30, 96)
const PANEL_SIZE := Vector2(480, 780)
const PILL_POS := Vector2(284, 884)
const PILL_SIZE := Vector2(244, 36)
const GEAR_POS := Vector2(240, 884)
const GEAR_SIZE := Vector2(40, 36)

var _pill: Button
var _gear: Button
var _confirm_bar: Panel
var _panel: Panel
var _state_label: Label
var _result_label: Label
var _dir_label: Label
var _format: OptionButton
var _audio_btn: CheckButton
var _enc_label: Label
var _audio_note: Label
var _res: OptionButton
var _fps: OptionButton
var _quality: OptionButton
var _name: LineEdit
var _overlay: CheckButton
var _auto_stop: CheckButton
var _hold: SpinBox
var _confirm_dim: ColorRect
var _pause_strip: Panel
var _pause_label: Label
var _dlg: FileDialog
var _label_t := 0.0


func _ready() -> void:
	size = Vector2(540, 960)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_pill()
	_build_gear()
	_build_panel()
	_build_pause_strip()
	_build_confirm()
	GameRecorder.state_changed.connect(_on_rec_state)
	GameRecorder.recording_finished.connect(_on_rec_done)
	_refresh()
	# M-I: hand the live race to the session NOW. This runs while the scene is
	# still being instantiated, i.e. before any frame of this race is drawn, so
	# a pending capture starts with the countdown on screen.
	RecordSession.on_race_ready(_race_node())


## The game scene this panel belongs to.
## ADAPTED FOR PIXEL BREAKOUT: the panel is instantiated by the game scene
## itself (game -> CanvasLayer -> RecorderPanel), so the owner is found by
## walking up the tree — not by looking for WorldRace's director/HUD pair.
## current_scene is only a fallback: during a scene change the new scene is
## built BEFORE current_scene is swapped.
func _race_node() -> Node:
	var n := get_parent()
	while n != null:
		if is_instance_valid(n) and n.has_signal("game_ended"):
			return n
		n = n.get_parent()
	var tree := get_tree()
	if tree == null:
		return null
	var s: Node = tree.current_scene
	if s != null and is_instance_valid(s) and s.has_signal("game_ended"):
		return s
	return null


func _exit_tree() -> void:
	# Leaving the race (restart / menu / quit to menu) SAVES the recording
	# instead of orphaning a temp folder: the session issues the stop (so its
	# state machine stays honest) and the recorder finalises in the background,
	# reporting through the window title.
	if GameRecorder.is_recording():
		RecordSession.stop("leaving_race")


func _process(delta: float) -> void:
	var recording := GameRecorder.is_recording()
	var paused := get_tree() != null and get_tree().paused
	if _pause_strip != null:
		_pause_strip.visible = recording and paused
	if _pause_label != null and _pause_strip != null and _pause_strip.visible:
		# M-H: the pause strip also says what is REALLY being captured, so a slow
		# take is visible before it is saved (never a silent "30 FPS" claim).
		var s := GameRecorder.capture_stats()
		var rate := ""
		if float(s.get("real_seconds", 0.0)) >= 0.75:
			rate = "  ·  %.0f/%d fps" % [float(s.get("unique_fps", 0.0)), int(s.get("target_fps", 30))]
		_pause_label.text = "● RECORDING  " + _clock(GameRecorder.elapsed_seconds()) + rate
	_label_t += delta
	if _label_t < 0.2:
		return
	_label_t = 0.0
	if _pill != null:
		_pill.visible = _pill_should_show()
		# M-I: the pill IS the control, so its label states the state machine.
		match RecordSession.state:
			RecordSession.STATE_PREPARING:
				_pill.text = "PREPARING…"
				_pill.modulate = Color(1.0, 0.9, 0.6)
			RecordSession.STATE_FINALIZING:
				_pill.text = "Saving video…"
				_pill.modulate = Color(1.0, 0.9, 0.6)
			RecordSession.STATE_RECORDING, RecordSession.STATE_WAITING_RESULT:
				_pill.text = "■ STOP RECORDING  " + _clock(GameRecorder.elapsed_seconds())
				_pill.modulate = Color(1.0, 0.55, 0.55)
			_:
				if GameRecorder.state == GameRecorder.STATE_SAVING:
					_pill.text = "Saving video…"
					_pill.modulate = Color(1.0, 0.9, 0.6)
				else:
					_pill.text = "REC — Record Take"
					_pill.modulate = Color(1, 1, 1)
	if _gear != null:
		# the settings button follows the pill: neither may sit in the video
		_gear.visible = _pill_should_show()
		_gear.disabled = RecordSession.state == RecordSession.STATE_PREPARING \
			or RecordSession.state == RecordSession.STATE_FINALIZING
	if _panel != null and _panel.visible:
		_refresh_state_line()


## Show the pill while idle, while SAVING, and while recording ONLY when the
## user asked for the chip to be part of the video.
func _pill_should_show() -> bool:
	match GameRecorder.state:
		GameRecorder.STATE_RECORDING:
			return bool(GameRecorder.settings.get("include_overlay", false))
		_:
			return true


func _clock(secs: float) -> String:
	var s := int(maxf(0.0, secs))
	return "%02d:%02d" % [s / 60, s % 60]


func _progress_pct() -> int:
	var st := GameRecorder.status()
	var total := maxi(1, int(st.get("frames", 1)))
	return clampi(int(round(100.0 * float(st.get("progress", 0)) / float(total))), 0, 100)


## ---------------------------------------------------------------- building

func _build_pill() -> void:
	_pill = Button.new()
	_pill.name = "RecordButton"
	_pill.text = "REC — Record Take"
	_pill.position = PILL_POS
	_pill.size = PILL_SIZE
	_pill.custom_minimum_size = PILL_SIZE
	_pill.focus_mode = Control.FOCUS_NONE
	_pill.add_theme_font_size_override("font_size", 12)
	_pill.tooltip_text = "Restart this level and record the take. Stops by itself when the result screen has been shown."
	_pill.add_theme_color_override("font_color", Color(1, 0.86, 0.86))
	var sb := UITheme.panel_style(Color(0.30, 0.05, 0.07, 0.92), 12, Color(1.0, 0.35, 0.40, 0.75), 1, 6)
	var sh := UITheme.panel_style(Color(0.45, 0.08, 0.10, 0.96), 12, Color(1.0, 0.42, 0.46, 1.0), 1, 8)
	_pill.add_theme_stylebox_override("normal", sb)
	_pill.add_theme_stylebox_override("hover", sh)
	_pill.add_theme_stylebox_override("pressed", sb)
	_pill.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_pill.pressed.connect(_on_pill_pressed)
	add_child(_pill)


## M-I: the settings stay one tap away without making the REC pill ambiguous.
func _build_gear() -> void:
	_gear = Button.new()
	_gear.name = "RecorderSettingsButton"
	_gear.text = "SET"
	_gear.position = GEAR_POS
	_gear.size = GEAR_SIZE
	_gear.custom_minimum_size = GEAR_SIZE
	_gear.focus_mode = Control.FOCUS_NONE
	_gear.tooltip_text = "recorder settings (format, size, audio, auto-stop)"
	_gear.add_theme_font_size_override("font_size", 11)
	var sb := UITheme.panel_style(Color(0.06, 0.10, 0.16, 0.92), 12, Color(0.5, 0.65, 0.8, 0.6), 1, 6)
	_gear.add_theme_stylebox_override("normal", sb)
	_gear.add_theme_stylebox_override("hover", UITheme.panel_style(Color(0.10, 0.16, 0.24, 0.96), 12, Color(0.6, 0.78, 0.95, 0.9), 1, 8))
	_gear.add_theme_stylebox_override("pressed", sb)
	_gear.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_gear.pressed.connect(_toggle_panel)
	add_child(_gear)


## M-I: the discard warning, drawn INSIDE the HUD (same layer as the pause
## menu, so it is clickable by the same input path and can never reach the
## video — nothing is recording yet). Shown BEFORE anything is thrown away:
## Cancel leaves the race exactly as it was.
func _build_confirm() -> void:
	var dim := ColorRect.new()
	dim.name = "RecordConfirmDim"
	dim.size = Vector2(540, 960)
	dim.color = Color(0, 0, 0, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.visible = false
	add_child(dim)
	_confirm_dim = dim

	var bar := Panel.new()
	bar.name = "RecordConfirmBar"
	bar.position = Vector2(40, 344)
	bar.size = Vector2(460, 272)
	bar.add_theme_stylebox_override("panel", UITheme.panel_style(
		Color(0.05, 0.07, 0.12, 0.98), 16, Color(1.0, 0.55, 0.4, 0.7), 2, 12))
	bar.visible = false
	add_child(bar)
	_confirm_bar = bar

	var t := UITheme.label("RESTART && RECORD?", 20, Color(1.0, 0.92, 0.86), 3, Color(0, 0, 0, 0.7))
	t.position = Vector2(20, 18)
	t.size = Vector2(420, 28)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(t)

	var body := UITheme.label(
		"The race on screen will be discarded and a fresh one started from its "
		+ "countdown, recorded from the first frame.\n\nThe level, the roster and "
		+ "the seed stay exactly the same.", 13, Color(0.82, 0.88, 0.95))
	body.position = Vector2(28, 60)
	body.size = Vector2(404, 120)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bar.add_child(body)

	var cancel := UITheme.button("CANCEL", 15, Color(0.35, 0.45, 0.6), Vector2(190, 46))
	cancel.name = "RecordConfirmCancel"
	cancel.position = Vector2(30, 200)
	cancel.pressed.connect(func(): _hide_confirm())
	bar.add_child(cancel)

	var ok := UITheme.button("DISCARD & RECORD", 15, Color(0.9, 0.35, 0.3), Vector2(212, 46))
	ok.name = "RecordConfirmOk"
	ok.position = Vector2(236, 200)
	ok.pressed.connect(_confirm_record)
	bar.add_child(ok)


func _hide_confirm() -> void:
	if _confirm_bar != null:
		_confirm_bar.visible = false
	if _confirm_dim != null:
		_confirm_dim.visible = false


func _confirm_record() -> void:
	_hide_confirm()
	var r := RecordSession.begin(true)
	if not bool(r.get("ok", false)):
		_panel.visible = true
		_refresh()
		return
	_result_label.text = ""
	_panel.visible = false


func _build_panel() -> void:
	_panel = Panel.new()
	_panel.name = "RecorderPanel"
	_panel.position = PANEL_POS
	_panel.size = PANEL_SIZE
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style(
		Color(0.035, 0.06, 0.10, 0.985), 16, Color(0.9, 0.35, 0.4, 0.55), 1, 14))
	_panel.visible = false
	add_child(_panel)

	var box := VBoxContainer.new()
	box.position = Vector2(14, 12)
	box.size = Vector2(PANEL_SIZE.x - 28, PANEL_SIZE.y - 24)
	box.add_theme_constant_override("separation", 7)
	_panel.add_child(box)

	var head := UITheme.label("GAMEPLAY RECORDER", 16, Color(1.0, 0.88, 0.88), 2, Color(0, 0, 0, 0.7))
	box.add_child(head)
	var sub := UITheme.label("Records the GAME WINDOW (not the editor or desktop) into a portrait video.",
		9, Color(0.72, 0.8, 0.88))
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(sub)

	# resolution / fps / quality
	# M-G: container first — it decides whether audio is even possible.
	var fr0 := _row(box, "format")
	_format = OptionButton.new()
	_format.name = "FormatOption"
	_format.add_theme_font_size_override("font_size", 10)
	_format.custom_minimum_size = Vector2(200, 24)
	for f in GameRecorder.FORMATS:
		_format.add_item(str(f).to_upper())
	_format.tooltip_text = "AUTO = MP4 when an encoder is installed, AVI otherwise. MP4 = refuse (and say why) without an encoder."
	_format.item_selected.connect(func(_i: int): _on_format_changed())
	fr0.add_child(_format)
	_enc_label = _note(box, "")

	var r := _row(box, "resolution")
	_res = OptionButton.new()
	_res.add_theme_font_size_override("font_size", 10)
	_res.custom_minimum_size = Vector2(180, 24)
	for v in GameRecorder.RESOLUTIONS:
		_res.add_item("%d x %d" % [v.x, v.y])
	_res.tooltip_text = "1080x1920 is YouTube Shorts. The game renders at 540x960, so larger sizes are an upscale (same picture, more pixels)."
	_res.item_selected.connect(func(_i: int): _save_size_opts())
	r.add_child(_res)
	_note(box, "1080 x 1920 = YouTube Shorts. The game renders at 540 x 960, so bigger sizes are an upscale — they add no detail.")

	var fr := _row(box, "frame rate")
	_fps = OptionButton.new()
	_fps.add_theme_font_size_override("font_size", 10)
	_fps.custom_minimum_size = Vector2(96, 24)
	for f in GameRecorder.FPS_CHOICES:
		_fps.add_item("%d FPS" % int(f))
	_fps.item_selected.connect(func(_i: int): _save_size_opts())
	fr.add_child(_fps)

	var qr := _row(box, "quality")
	_quality = OptionButton.new()
	_quality.add_theme_font_size_override("font_size", 10)
	_quality.custom_minimum_size = Vector2(180, 24)
	for k in GameRecorder.QUALITIES:
		_quality.add_item(str(k))
	_quality.item_selected.connect(func(_i: int): _save_size_opts())
	qr.add_child(_quality)

	var ar := _row(box, "audio")
	_audio_btn = CheckButton.new()
	_audio_btn.name = "AudioCheck"
	_audio_btn.text = "include game audio"
	_audio_btn.add_theme_font_size_override("font_size", 10)
	_audio_btn.tooltip_text = "Records the game's mixed output (SFX + music after the master limiter) into the MP4's AAC track. Needs MP4. The audio system itself is untouched."
	_audio_btn.toggled.connect(func(on: bool):
		GameRecorder.settings["audio"] = on
		GameRecorder.save_settings()
		_refresh())
	ar.add_child(_audio_btn)
	_audio_note = _note(box, "")

	var nr := _row(box, "file name")
	_name = LineEdit.new()
	_name.custom_minimum_size = Vector2(0, 24)
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.add_theme_font_size_override("font_size", 10)
	_name.placeholder_text = "auto: breakout_YYYYMMDD_HHMMSS"
	nr.add_child(_name)
	_note(box, "MP4 (H.264) when an encoder is installed, otherwise AVI (Motion-JPEG). A name that already exists gets _2, _3, … — a recording is never overwritten.")

	var dr := HBoxContainer.new()
	dr.add_theme_constant_override("separation", 4)
	_dir_label = UITheme.label("", 9, Color(0.7, 0.8, 0.9))
	_dir_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dir_label.clip_text = true
	_dir_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dr.add_child(_dir_label)
	var open := UITheme.small_button("OPEN", Vector2(52, 26))
	open.tooltip_text = "open the recordings folder"
	open.pressed.connect(func():
		var d := GameRecorder.output_dir()
		DirAccess.make_dir_recursive_absolute(d)
		OS.shell_open(d))
	dr.add_child(open)
	var pick := UITheme.small_button("CHANGE…", Vector2(74, 26))
	pick.tooltip_text = "choose another destination folder"
	pick.pressed.connect(_pick_folder)
	dr.add_child(pick)
	box.add_child(dr)

	_overlay = CheckButton.new()
	_overlay.text = "burn the REC chip into the video"
	_overlay.add_theme_font_size_override("font_size", 10)
	_overlay.tooltip_text = "OFF (default): the video is pure gameplay. ON: the recording chip is deliberately recorded."
	_overlay.toggled.connect(func(on: bool):
		GameRecorder.settings["include_overlay"] = on
		GameRecorder.save_settings()
		_refresh())
	box.add_child(_overlay)

	# --- M-I: the session's own settings (one-click recording behaviour) ---
	var sr := _row(box, "auto stop")
	_auto_stop = CheckButton.new()
	_auto_stop.name = "AutoStopCheck"
	_auto_stop.text = "stop when the race ends"
	_auto_stop.add_theme_font_size_override("font_size", 10)
	_auto_stop.tooltip_text = "ON (default): the take finishes by itself after the result screen has been shown for the hold below, so one click records a whole race. OFF: keep recording until you press STOP."
	_auto_stop.toggled.connect(func(on: bool):
		RecordSession.settings["auto_stop"] = on
		RecordSession.save_settings())
	sr.add_child(_auto_stop)

	var hr := _row(box, "result hold")
	_hold = SpinBox.new()
	_hold.name = "ResultHoldSpin"
	_hold.min_value = 0.0
	_hold.max_value = 60.0
	_hold.step = 0.5
	_hold.suffix = " s"
	_hold.custom_minimum_size = Vector2(96, 24)
	_hold.add_theme_font_size_override("font_size", 10)
	_hold.tooltip_text = "How long the winner / result screen stays on camera before the video is finalized. Default 3 seconds."
	_hold.value_changed.connect(func(v: float):
		RecordSession.settings["result_hold"] = v
		RecordSession.save_settings())
	hr.add_child(_hold)
	_note(box, "One click records the countdown, the race and the result screen — never the editor, the menus or this panel.")

	var _sp := Control.new()
	_sp.custom_minimum_size = Vector2(0, 2)
	box.add_child(_sp)

	var start := UITheme.button("START RECORDING", 16, Color(0.9, 0.25, 0.3), Vector2(0, 44))
	start.name = "StartRecordingButton"
	start.pressed.connect(_start)
	box.add_child(start)

	_state_label = UITheme.label("", 9, Color(0.68, 0.82, 0.95))
	_state_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_state_label.custom_minimum_size = Vector2(0, 50)
	box.add_child(_state_label)

	_result_label = UITheme.label("", 9, Color(0.6, 0.92, 0.72))
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_label.custom_minimum_size = Vector2(0, 58)
	box.add_child(_result_label)

	var close := UITheme.small_button("CLOSE", Vector2(80, 26))
	close.name = "CloseRecorderButton"
	close.pressed.connect(func(): _panel.visible = false)
	var crow := HBoxContainer.new()
	crow.alignment = BoxContainer.ALIGNMENT_END
	crow.add_child(close)
	box.add_child(crow)


func _row(parent: VBoxContainer, title: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	var l := UITheme.label(title, 10, Color(0.72, 0.82, 0.92))
	l.custom_minimum_size = Vector2(96, 0)
	r.add_child(l)
	parent.add_child(r)
	return r


func _note(parent: VBoxContainer, text: String) -> Label:
	var l := UITheme.label(text, 8, Color(0.58, 0.66, 0.74))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l


func _build_pause_strip() -> void:
	_pause_strip = Panel.new()
	_pause_strip.name = "RecordingStrip"
	_pause_strip.position = Vector2(95, 604)
	_pause_strip.size = Vector2(350, 74)
	_pause_strip.add_theme_stylebox_override("panel", UITheme.panel_style(
		Color(0.22, 0.04, 0.06, 0.97), 12, Color(1.0, 0.35, 0.4, 0.8), 1, 8))
	_pause_strip.visible = false
	add_child(_pause_strip)
	_pause_label = UITheme.label("● RECORDING", 13, Color(1.0, 0.82, 0.82))
	_pause_label.position = Vector2(12, 8)
	_pause_label.size = Vector2(326, 20)
	_pause_strip.add_child(_pause_label)
	var stop := UITheme.button("STOP RECORDING", 13, Color(0.9, 0.3, 0.35), Vector2(326, 32))
	stop.name = "StopRecordingButton"
	stop.position = Vector2(12, 34)
	stop.pressed.connect(func():
		# resume the game AND close the pause overlay it was opened from
		var hud := get_parent()
		if hud != null and hud.has_method("close_pause"):
			hud.close_pause()
		else:
			get_tree().paused = false
		# M-I: EVERY stop goes through the session, so a second stop (or the
		# automatic one already armed) can never finalize the same take twice.
		RecordSession.stop_manual())
	_pause_strip.add_child(stop)## ---------------------------------------------------------------- actions
func _toggle_panel() -> void:
	if GameRecorder.is_recording():
		return
	_panel.visible = not _panel.visible
	_refresh()


## M-I: THE one-click control. Idle -> validate, warn if a race would be
## discarded, then restart + record. Recording -> manual STOP. Saving -> nothing
## (one take at a time). Nothing here ever restarts a race on a failed setup.
func _on_pill_pressed() -> void:
	match RecordSession.state:
		RecordSession.STATE_RECORDING, RecordSession.STATE_WAITING_RESULT:
			RecordSession.stop_manual()
			return
		RecordSession.STATE_PREPARING, RecordSession.STATE_FINALIZING:
			return
	# save whatever the panel carries (file name) before the take is armed
	GameRecorder.settings["filename"] = _name.text.strip_edges()
	GameRecorder.save_settings()
	var r := RecordSession.begin(false)
	if not bool(r.get("ok", false)):
		# useful error, and the current race is left exactly as it was
		_panel.visible = true
		_refresh()
		return
	if bool(r.get("needs_confirm", false)):
		if _confirm_dim != null:
			_confirm_dim.visible = true
		if _confirm_bar != null:
			_confirm_bar.visible = true
		return
	_result_label.text = ""
	_panel.visible = false


## The format picker writes straight into the recorder's settings; the encoder
## note underneath explains what will actually happen (including "no encoder").
func _on_format_changed() -> void:
	var idx := clampi(_format.selected, 0, GameRecorder.FORMATS.size() - 1)
	GameRecorder.settings["format"] = str(GameRecorder.FORMATS[idx])
	GameRecorder.save_settings()
	_refresh()


func _pick_folder() -> void:
	if _dlg == null:
		_dlg = FileDialog.new()
		_dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_dlg.access = FileDialog.ACCESS_FILESYSTEM
		_dlg.title = "Recordings folder"
		_dlg.dir_selected.connect(func(d: String):
			GameRecorder.settings["dir"] = d
			GameRecorder.save_settings()
			_refresh())
		add_child(_dlg)
	_dlg.current_dir = GameRecorder.output_dir()
	_dlg.popup_centered(Vector2i(560, 420))


func _start() -> void:
	# The settings panel's own START: records the race that is already on
	# screen (the pre-M-I behaviour), through the same session state machine
	# so auto-stop and manual STOP behave identically.
	GameRecorder.settings["filename"] = _name.text.strip_edges()
	_save_size_opts()
	var r := RecordSession.begin_immediate(_start_opts())
	if not bool(r.get("ok", false)):
		_state_label.text = "not started: " + str(r.get("err", "unknown error"))
		_state_label.add_theme_color_override("font_color", Color(1.0, 0.68, 0.5))
		return
	_state_label.add_theme_color_override("font_color", Color(0.68, 0.82, 0.95))
	_panel.visible = false
	_result_label.text = ""
	_refresh()


## The panel's widgets are the authority while it is open: write them into the
## recorder settings (and on disk) so the NEXT one-click take uses them too.
func _save_size_opts() -> void:
	if _res == null or _fps == null or _quality == null:
		return
	var size: Vector2i = GameRecorder.RESOLUTIONS[
		mini(maxi(0, _res.selected), GameRecorder.RESOLUTIONS.size() - 1)]
	GameRecorder.settings["width"] = size.x
	GameRecorder.settings["height"] = size.y
	GameRecorder.settings["fps"] = int(GameRecorder.FPS_CHOICES[maxi(0, _fps.selected)])
	var qkeys: Array = GameRecorder.QUALITIES.keys()
	GameRecorder.settings["quality"] = float(GameRecorder.QUALITIES[
		qkeys[clampi(_quality.selected, 0, qkeys.size() - 1)]])
	GameRecorder.save_settings()


func _start_opts() -> Dictionary:
	if _res == null or _fps == null or _quality == null:
		return {}
	var size: Vector2i = GameRecorder.RESOLUTIONS[
		mini(maxi(0, _res.selected), GameRecorder.RESOLUTIONS.size() - 1)]
	var qkeys: Array = GameRecorder.QUALITIES.keys()
	return {"width": size.x, "height": size.y,
		"fps": int(GameRecorder.FPS_CHOICES[maxi(0, _fps.selected)]),
		"quality": float(GameRecorder.QUALITIES[qkeys[maxi(0, mini(_quality.selected, qkeys.size() - 1))]])}


func _on_rec_state(s: String) -> void:
	if s == GameRecorder.STATE_RECORDING:
		_refresh_state_line()
	_refresh()


func _on_rec_done(result: Dictionary) -> void:
	_panel.visible = true
	_refresh()
	if bool(result.get("ok", false)):
		_result_label.add_theme_color_override("font_color", Color(0.6, 0.95, 0.72))
		var fmt := str(result.get("format", "?"))
		var snd := "audio %.2fs" % float(result.get("audio_seconds", 0.0)) if bool(result.get("audio", false)) else "silent"
		# M-H: how many DISTINCT frames the machine managed, next to the output
		# frame count. A 30 FPS file of 180 frames from 34 captures says so.
		var cap_line := ""
		if result.has("captured"):
			var uniq := int(result.get("captured", 0))
			var total := int(result.get("frames", 0))
			var fps := float(result.get("capture_fps", 0.0))
			cap_line = "\n%d unique frames (%.1f fps captured of %d) · %d repeated" % [
				uniq, fps, int(result.get("fps", 30)), maxi(0, total - uniq)]
		_result_label.text = "SAVED  %s\n%.1f s · %d frames · %d x %d · %.1f MB · %s · %s%s\n%s" % [
			str(result.get("path", "")).get_file(),
			float(result.get("duration", 0.0)), int(result.get("frames", 0)),
			int(result.get("width", 0)), int(result.get("height", 0)),
			float(result.get("bytes", 0)) / 1048576.0, fmt, snd, cap_line,
			str(result.get("path", ""))]
	else:
		_result_label.add_theme_color_override("font_color", Color(1.0, 0.68, 0.5))
		_result_label.text = "RECORDING FAILED  " + str(result.get("err", "unknown error"))
	_refresh_state_line()


## ---------------------------------------------------------------- refresh

func _refresh() -> void:
	if _pill != null:
		_pill.visible = _pill_should_show()
	if _panel == null:
		return
	_overlay.set_pressed_no_signal(bool(GameRecorder.settings.get("include_overlay", false)))
	# M-I: the session's own switches (written by their widgets, read back here)
	if _auto_stop != null:
		_auto_stop.set_pressed_no_signal(RecordSession.auto_stop_enabled())
	if _hold != null and not is_equal_approx(float(_hold.value), RecordSession.result_hold_seconds()):
		_hold.value = RecordSession.result_hold_seconds()
	# M-G: format + audio + the encoder the machine actually has.
	if _format != null:
		_format.select(maxi(0, GameRecorder.FORMATS.find(str(GameRecorder.settings.get("format", "auto")))))
	if _audio_btn != null:
		_audio_btn.set_pressed_no_signal(bool(GameRecorder.settings.get("audio", true)))
		_audio_btn.disabled = not GameRecorder.audio_supported()
	if _enc_label != null:
		_enc_label.text = GameRecorder.encoder_note()
		_enc_label.add_theme_color_override("font_color",
			Color(0.55, 0.85, 0.65) if GameRecorder.mp4_ready() else Color(1.0, 0.75, 0.5))
	if _audio_note != null:
		var rf := GameRecorder.resolve_format()
		if not GameRecorder.audio_supported():
			_audio_note.text = "Audio needs MP4 plus an AAC encoder; this machine has neither, so the video is silent."
		elif str(rf.get("format", "avi")) == "avi":
			_audio_note.text = "AVI (Motion-JPEG) has no audio track here, so this take is silent."
		else:
			_audio_note.text = "Records the game's real mixed output into the MP4's AAC track — same limiter, same volumes."
	var dims := Vector2i(int(GameRecorder.settings.get("width", 1080)), int(GameRecorder.settings.get("height", 1920)))
	var ri := 0
	for i in GameRecorder.RESOLUTIONS.size():
		if GameRecorder.RESOLUTIONS[i] == dims:
			ri = i
	_res.select(ri)
	var fi := GameRecorder.FPS_CHOICES.find(int(GameRecorder.settings.get("fps", 30)))
	_fps.select(maxi(0, fi))
	var qkeys: Array = GameRecorder.QUALITIES.keys()
	var qi := 0
	for i in qkeys.size():
		if is_equal_approx(float(GameRecorder.QUALITIES[qkeys[i]]), float(GameRecorder.settings.get("quality", 0.92))):
			qi = i
	_quality.select(qi)
	if _name.text != str(GameRecorder.settings.get("filename", "")) and not _name.has_focus():
		_name.text = str(GameRecorder.settings.get("filename", ""))
	_dir_label.text = GameRecorder.output_dir()
	_dir_label.tooltip_text = GameRecorder.output_dir()
	_refresh_state_line()


func _refresh_state_line() -> void:
	if _state_label == null:
		return
	# M-I: the session's states take precedence — they say what the one-click
	# workflow is doing right now.
	match RecordSession.state:
		RecordSession.STATE_PREPARING:
			_state_label.text = "Restarting the race from its countdown…"
			_state_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
			return
		RecordSession.STATE_WAITING_RESULT:
			_state_label.text = "Result screen on camera — stopping in %.1f s (auto stop %s)" % [
				RecordSession.hold_left,
				"ON" if RecordSession.auto_stop_enabled() else "OFF"]
			_state_label.add_theme_color_override("font_color", Color(1.0, 0.65, 0.65))
			return
		RecordSession.STATE_SAVED:
			var sr := GameRecorder.last_result
			_state_label.text = "Saved — see the details below."
			_state_label.add_theme_color_override("font_color", Color(0.6, 0.95, 0.72))
			if bool(sr.get("ok", false)):
				return
		RecordSession.STATE_ERROR:
			if RecordSession.last_error != "":
				_state_label.text = "not started: " + RecordSession.last_error
				_state_label.add_theme_color_override("font_color", Color(1.0, 0.68, 0.5))
				return
	match GameRecorder.state:
		GameRecorder.STATE_RECORDING:
			_state_label.text = "● RECORDING  %s · %s\nSTOP is in the PAUSE menu (ESC). Recording pauses with the game." % [
				_clock(GameRecorder.elapsed_seconds()), GameRecorder.capture_note()]
			_state_label.add_theme_color_override("font_color", Color(1.0, 0.65, 0.65))
		GameRecorder.STATE_SAVING:
			_state_label.text = "Encoding the video… %d%%  (the race keeps running)" % _progress_pct()
			_state_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
		_:
			if GameRecorder.last_error != "":
				_state_label.text = "last attempt: " + GameRecorder.last_error
				_state_label.add_theme_color_override("font_color", Color(1.0, 0.68, 0.5))
			else:
				var rf := GameRecorder.resolve_format()
				_state_label.text = "Ready. %d FPS · %d x %d · %s" % [
					int(GameRecorder.settings.get("fps", 30)),
					int(GameRecorder.settings.get("width", 1080)),
					int(GameRecorder.settings.get("height", 1920)),
					str(rf.get("note", ""))]
				_state_label.add_theme_color_override("font_color", Color(0.68, 0.82, 0.95))
