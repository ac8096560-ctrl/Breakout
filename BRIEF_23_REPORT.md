# BRIEF 23 — follow-up: the two blocking failures

Base: `ac8096560-ctrl/Breakout` main @ `f1f3712`. This patch is `f1f3712` + the previous
`brief23.patch` + these two fixes, applies cleanly, and is **not committed** (HEAD is still
`f1f3712`).

Everything below was run on this machine (Linux, Godot 4.7.2.stable.official.ed1daf0bf,
Xvfb + llvmpipe software GL, static ffmpeg 7.0.2). Every number is read from a command's
output or from the finished file; nothing is inferred.

---

## Failure 1 — Part A: the win anchor

### What I measured first

I re-measured the take from the first round (`breakout_20261117_104703.mp4`, linear atempo
take) with a purpose-built meter (`measure_win.py`: matched filter of `audio/victory.wav`
over the whole soundtrack, plus per-frame picture change for the popup):

```
video 71.200 s / audio 71.200 s          <- the two lengths agree to 32 ms
win popup (picture)   63.233 s
victory jingle (sound) 68.310 s  score 0.857
offset                -5.077 s (sound later)
brick-break offsets:  +3.714 +1.314 -2.853 +3.627 +3.127 +3.027 +2.060 +1.694
```

The second line is the diagnosis. The brick-break sounds scatter **±3.7 s around their
pictures** and the totals agree, so the error is not a growing offset in the audio: the
**picture clock itself is bent**. `pace_holds()` placed picture *k* at
`round(k * total / count)`, i.e. evenly in picture **index**, and this machine's capture
rate swings inside a take (30 FPS renderer, 8 FPS under load). Even pacing re-times the
take. No audio correction can repair that from the outside — it would have to bend the
audio around a bent picture clock, which is what my first-round fix effectively did.

### What I changed

**1. The video timeline is now the take's real timeline.**
Each captured picture already carried the slot it was taken at; that slot was being
thrown away. It is now kept (`_slots`), and the finaliser lays each picture at the slot
it was taken at (`slot_holds()` / `timeline_holds()`, both the MP4 and AVI paths):

* hold = the real gap to the next picture, summing to exactly `total` frames, so the
  duration is still the take's wall-clock duration;
* a machine that keeps up (one picture per slot) gets hold 1 everywhere — identical
  output to before;
* a machine that misses slots holds the previous picture for the missed frames, which is
  what the eye saw anyway.

**2. The game's own win instant is stamped on the take and exported.**
`RecordSession` calls `GameRecorder.note_event("win")` the moment `_ended` fires (the same
call that shows the popup and plays the jingle), and the result carries
`sync_win_seconds`. `--breakout-record` now prints it as `win_wall=…`, so the finished
file can be checked against a fact from the game instead of a guess.

**3. The audio path is deliberately left append-only, and I can show why.**
I first implemented the per-block anchor you suggested — resample every drained audio
block so its end lands on the take's wall clock. It measured well on duration and *destroyed
the soundtrack*: on this machine the mixer's output is already real time (a 71.6 s take at
7.5 FPS held 71.6 s of continuous audio, zero-fraction 0.27, mean RMS 0.053), and what
varies is only how the frames are **delivered** — a slow frame hands over a double-length
block, the next a short one, and they cancel. Re-timing each block to its own slice turned
that delivery jitter into **pitch swings of 0.36×–2.80×**, and the victory jingle stopped
matching its own recording:

```
take 134844 (per-block resampling, 7.5 FPS): victory match 0.236  <- jingle gone
take 135227 (append-only,          7.9 FPS): victory match 0.995
```

So the block resampling was reverted. The one real clock difference between the streams —
the take's total audio length against its video length — is still measured and corrected
once at encode time (`audio_time_scale`, the existing `atempo`), which is where it belongs.

### Result on real takes (recorded here with `--breakout-record`, measured in the output mp4)

| take | render fps | win popup (picture) | victory jingle (sound) | game's win stamp | offset vs popup | offset vs stamp | atempo |
|---|---|---|---|---|---|---|---|
| 135558 | 30.2 | 52.967 s | **52.980 s** (score 0.857) | 52.963 s | **+0.013 s** | +0.017 s | 0.994074 |
| 135227 | 7.9 (loaded) | 66.500 s | **66.629 s** (score 0.995) | 66.439 s | **+0.129 s** | +0.190 s | 0.992561 |

**Acceptance: the win anchor in the output mp4 is +0.013 s on a real take — inside 0.15 s,
with the fix entirely inside the recorder (no manual ffmpeg step).**

The second row is the same fix on a deliberately starved machine (14 busy loops, 7.9 FPS).
The residual there is one frame of quantization (frame interval 126 ms) plus the mixer's
own scheduling delay on a starved audio thread; it is latency, not drift, which is why it
shrinks to 13 ms as soon as the machine renders at 30 FPS. Take 135227 also shows the
jingle matching at 0.995, i.e. the recording's audio is intact.

Popup position was verified by eye as well as by the meter: frames at 66.46 s and 66.53 s
were dumped and 66.46 s has no popup, 66.53 s does, matching the 66.500 s transition.

---

## Failure 2 — Part B: Jensen regressed, Messi frame not covered

### Jensen: the old rule was not finding a frame at all

`level_02_jensen` is a photograph. Its **background is grey**: 670 grey bricks in one
region that does reach the level's edge. The old rule ("neutral + mid-bright + part of a
grey region reaching the outer edge") therefore took the photo's *background* for a wall,
walled the picture in, and left **44 bricks unreachable** — the level could not be won
(120 s timeout, `bricks_left=40`, `longest_stall=44.4 s`).

The rule is now **per cell, not per region**, and it is about position only: a grey brick
is a wall when it lies in the picture's **frame band** — within `GREY_FRAME_BAND = 2` cells
of the picture's outer edge (the bounding box of its bricks, so an imported portrait with a
transparent margin is framed from *its* edge). Distance does not care about connectivity,
so a frame broken into single cells is still covered, and a background that starts one cell
inside the picture's own border is not. No per-level exemption.

I also added the invariant that was missing: `level_loader.stranded_breakable()` — a
solid cell is a wall the ball can never break, so a breakable brick no path reaches from the
channel can never be broken. `load_level()` now reports it and the level-load suite asserts
it is **0 for every shipped level**, which would have caught this regression on its own
instead of in a 120-second sim.

| | solid | from list | from grey | breakable | stranded |
|---|---|---|---|---|---|
| Jensen, old rule (your report) | 690 | 174 | 516 | 1208 | 44 → unwinnable |
| Jensen, now | 245 | 174 | 71 | 1653 | 0 |

```
--breakout-sim level=level_02_jensen seed=1
WR_BREAKOUT_SIM_RESULT PASS level=level_02_jensen seed=1 won=true at 31.9s
  (longest stall 1.2s, bricks_left 24)      exit 0
```
Pre-patch Jensen won at 28.4 s; it wins again, 3.5 s later because 71 grey frame bricks
are now solid. The grey frame is solid; the level is winnable.

### Messi frame: covered per piece

The real Messi art is **not in this repository or this workspace**, so I could not run your
292-cell frame directly. I rebuilt the geometry you described and put the check in the
suite so it runs from the patch alone (`editor_grey_frame`): 80×100, a closed grey frame
(top bars + side walls) at inset 5 around a portrait, the frame broken into single cells
the way a resize leaves it (every third frame cell is a resize-stained near-grey,
chroma 30, which no colour rule can see — that is the fragmentation), neutral grey
**shading** inside the face, and `unbreakable_cells: []`.

```
WR_BREAKOUT_SUITE editor_grey_frame PASS
  frame_cells=316 frame_grey=210 covered=208 (99%)
  shading_grey=188 shading_solid=0 grey_solid=208 stranded=0 unstained_out_of_reach=106
```

* `grey_solid = 208` against 210 detected frame bricks — 2 are eaten by the channel carve
  through the frame's bottom bar, which is required.
* The 188 neutral shading bricks inside the portrait stay breakable (`shading_solid=0`).
* The old rule gets **0** on the same fixture: none of its 63 pieces reach the edge as a
  connected region.
* 106 of the frame's 316 cells are the resize-stained near-greys above. Any colour rule is
  blind to them; they stay breakable, and the fixture prints that number rather than hiding
  it. If your real frame's lost cells are tinted rather than transparent, that is the
  limitation you will still see.

`level_04_ronaldo` is unaffected: **994 solid, from_grey 0**, and its sim is unchanged
(`won=true at 51.5 s`, `bricks_left=74`, same score 112 122 170).

---

## Everything else still passes (run in this tree, serially)

| command | exit | result |
|---|---|---|
| `--breakout-test` | 0 | `WR_BREAKOUT_RESULT PASS failing suites: 0` |
| `--breakout-smoke` | 0 | `WR_BREAKOUT_SMOKE_RESULT PASS menu_buttons=6 bricks=962 balls=1 state=ready` |
| `--breakout-editor-test` | 0 | `WR_BREAKOUT_EDITOR_RESULT PASS failing suites: 0` |
| `--breakout-editor-test` → `editor_import_pixel_file` | 0 | `id=level_04_ronaldo_2 80x100 bricks=5803 breakable=5449 unbreakable=354 grey_solid=0 saved=true in_menu=true` |
| `--breakout-sim level=level_02_jensen seed=1` | 0 | `won=true at 31.9s (longest stall 1.2s, bricks_left 24)` |
| `--breakout-sim level=level_04_ronaldo seed=1` | 0 | `won=true at 51.5s (longest stall 2.7s, bricks_left 74)` |

Part C (`use_native_dialog = true`) and Part D (pixel import) are unchanged by this
follow-up.

---

## Files in the patch

* `scripts/game_recorder.gd` — `_slots`, `slot_holds()` / `timeline_holds()`, slot-based
  layout in both finalisers, `note_event()`, `sync_win_seconds` in the result.
* `scripts/record_session.gd` — stamps the race end on the take's clock.
* `scripts/level_loader.gd` — `GREY_FRAME_BAND`, `grey_frame_cells()` (per-cell frame band,
  replacing `grey_edge_cells()`), `stranded_breakable()`, new `stranded_breakable` field.
* `scripts/audio_capture.gd` — comment only: why the tap appends instead of re-timing.
* `autoload/test_runner.gd` — Jensen 245/1653/71, editor preview 245/1653, the
  `stranded_breakable == 0` assertion for every shipped level, the `editor_grey_frame`
  fixture suite, `win_wall` in the record print.
* `scripts/video_encoder.gd`, `scripts/editor.gd`, `autoload/game.gd` — unchanged by the
  follow-up (still as delivered in round one).

## Limitations, stated plainly

1. **The Messi number is from a reconstruction**, not your art — the fixture's geometry and
   fragmentation are described above. Frame cells that the resize *tinted* (chroma ≥ 25)
   are invisible to any colour rule and stay breakable.
2. **The residual win offset grows with frame time** (+0.013 s at 30 FPS, +0.129 s at
   7.9 FPS). It is one frame of picture quantization plus mixer scheduling delay, not
   accumulating drift — the same take shows it does not grow with duration.
3. **Slot-based pacing changes how a slow machine's video looks**: where a capture slot was
   missed the previous picture is held, so the video freezes where the machine stalled
   instead of spreading pictures evenly. That is the honest timeline, and it is what makes
   the two streams agree; on a machine that keeps up the output is identical to before.
4. **Part C is still not proven on an APK here** (no JDK / Android SDK / export templates in
   this workspace); unchanged from round one.
5. `hold_stats` still reports the pacing; `pace_holds()` survives only as the fallback for
   a take with no slot data.
