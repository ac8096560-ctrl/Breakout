# BRIEF 25 — Pixel Breakout: time-based power-up pacing, paddle gap, full-width portrait

Base: `github.com/ac8096560-ctrl/Breakout`, branch `main`, commit `8194428`
("Brief 23 follow-up: permanent A/V sync (slot pacing + win stamp), Jensen fix, Messi level").
Godot `4.7.2.stable.official.ed1daf0bf`.
Deliverable: `brief25.patch` (applies cleanly to 8194428 — verified with `git apply --check` on a
fresh clone) + this report. Nothing was committed, pushed or merged.

---

## 1. Confirmation of base

```
$ git clone https://github.com/ac8096560-ctrl/Breakout.git breakout
$ cd breakout && git checkout 8194428 && git rev-parse HEAD
8194428d2f3a8abbdaec83dcb1e8e7f59519d25d
8194428 Brief 23 follow-up: permanent A/V sync (slot pacing + win stamp), Jensen fix, Messi level
```

Environment note: a fresh clone has no `.godot/` import cache, so `class_name` types (`Ball`,
`Brick`, `BreakoutLevelWriter`, …) do not resolve and the suites cannot run at all. One import pass
is required before any suite:

```
$ "$G" --headless --path . --import      # generated .godot/global_script_class_cache.cfg
```

---

## 2. Baselines at 8194428 (before any edit), run serially

| # | Command | Exit | Verdict line |
|---|---------|------|--------------|
| 1 | `"$G" --headless --path . -- --breakout-test` | 0 | `WR_BREAKOUT_RESULT PASS failing suites: 0` (23 suites, all PASS) |
| 2 | `"$G" --headless --path . -- --breakout-smoke` | 0 | `WR_BREAKOUT_SMOKE_RESULT PASS menu_buttons=6 bricks=962 balls=1 state=ready` |
| 3 | `"$G" --headless --path . -- --breakout-editor-test` | 0 | `WR_BREAKOUT_EDITOR_RESULT PASS failing suites: 0` (10 suites, all PASS) |

All three baselines green, so editing was allowed.

Baseline win times (`--breakout-sim … seed=1 seconds=150`, real time, serial):

| Level | Win time | Stars | Score |
|---|---|---|---|
| level_01_portrait | 27.0 s | 1/3 | 7,551,900 |
| level_02_jensen | 31.9 s | 3/3 | 24,597,890 |
| level_03_solid_path | 22.3 s | 1/3 | 9,256,540 |
| level_04_ronaldo | 51.5 s | 1/3 | 112,122,170 |
| level_05_messi | **31.0 s** | 2/3 | 95,786,130 |

`level_05_messi = 31.0 s` reproduces the number in the brief.

---

## 3. What changed and why

### 3.1 Time-based power-up pace (`scripts/breakout_game.gd`)

The flat `POWERUP_CHANCE := 0.20` is replaced by a chance that ramps with **elapsed game time**:

```gdscript
func powerup_chance() -> float:
    var t := clampf(elapsed / POWERUP_RAMP_SECONDS, 0.0, 1.0)
    return lerpf(POWERUP_CHANCE_START, POWERUP_CHANCE_END, t)

const POWERUP_CHANCE_START := 0.10
const POWERUP_CHANCE_END   := 0.42
const POWERUP_RAMP_SECONDS := 40.0
```

| t (game seconds) | 0 | 10 | 12.5 | 20 | 30 | 40+ |
|---|---|---|---|---|---|---|
| drop chance per broken brick | **0.10** | 0.18 | 0.20 (old flat value) | 0.26 | 0.34 | **0.42** |

* The opening is **half** the old rate (0.10 vs 0.20) and only passes the old rate at ~12.5 s, so the
  early multi-ball wave is delayed — the early game is measurably slower.
* From the middle of the take onwards the rate is above the old value and reaches **2.1×** it
  (0.42) at 40 s, so the mid/late game is faster and the take still ends well inside a minute.
* Global rule: it reads `elapsed` only — never the level id, the level size or any per-level value.
* Only the *chance* is scaled. The drop pool weights, `NUKE_RADIUS`, the win rule, the 3-star
  system, `BALL_SPEED` / `BALL_SPEED_DENSE`, `FALL_SPEED` and `DROP_DELAY` are untouched.
* The two guarantees are untouched by the ramp: the channel's two tip cells always drop, and the
  `FIRST_DROP_BRICKS`-th (30th) brick always drops, so the first multi-ball still lands in the early
  game. The suite proves it still fires: `multiball_plus3 PASS balls 1 -> 4 caught=1 first=0.33s`.

Why this mechanism: the brief allows chance and/or fall speed and/or ball speed. Chance is the one
that changes the *number* of balls, which is what the brick rate is actually proportional to. Ball
speed and fall speed were left alone so that movement/physics, the 420/570 px/s tuning and the
landing feel of a drop are exactly as Brief 22/23 left them.

### 3.2 Bigger gap between the portrait and the paddle (follow-ups 1)

| | before | after |
|---|---|---|
| field bottom (`origin.y + rows*cell`) | 664 | **739** |
| paddle line `PADDLE_Y` | 760 | **890** |
| gap `PADDLE_Y - field_bottom` | **96 px** | **151 px** (+57%) |
| clear space, field bottom to paddle top | 89 px | **144 px** |

Both level geometries give the same numbers (see 3.3), so the gap is 96 → 151 px for a 40x50 level
and for an 80x100 level. At 420 px/s that is 0.36 s of visible ball travel instead of 0.23 s.
The safety floor moved with the bar (`SafetyFloor.Y` 880 → **930**, still 33 px under the paddle
face); `LOSS_Y` is unchanged at 1000. The held serve ball (`PADDLE_Y - 22`), the star-drop clamp,
the ball-spawn clamp, the HUD and the win rule are all still inside the frame and still work
(see the suites).

### 3.3 Full-width portrait (follow-up 2)

The field pitch is now **derived** instead of read from the level JSON (`_load_level`):

```gdscript
cell = VIEW.x / float(cols)      # 40 cols -> 13.5 px, 80 cols -> 6.75 px
origin = Vector2(0.0, origin.y)  # level's own vertical offset is kept
```

| | 40x50 level (level_01/02/03) | 80x100 level (level_04/05) |
|---|---|---|
| before: cell / origin.x / width | 12.0 / 30 / 480 px | 6.0 / 30 / 480 px |
| after: cell / origin.x / width | **13.5 / 0 / 540 px** | **6.75 / 0 / 540 px** |
| left margin | 30 px | 30 px |
| right margin | 30 px | 30 px |
| margins after | **0 px / 0 px** | **0 px / 0 px** |

* Uniform scale on both axes (12 → 13.5 and 6 → 6.75 are both ×1.125), so the portrait is scaled up,
  **not stretched**; `cols*cell = 540` exactly and no column or row is cropped.
* Field box is 540 × 675 at y 64…739 for every shipped level: fully visible, top edge where it always
  was (the top wall overlap is unchanged), bottom edge 221 px above the frame bottom.
* Because the rule is derived in the game, it applies to every level including an editor-saved one.

### 3.4 One thing the flush field exposed (arena containment)

With the field flush to the frame, a brick body (`cell - 2` wide) leaves a ~1 px slot in front of the
side wall. The ball could be squeezed into that slot and come out of the arena — measured in a sim:
`ball_x` reached `-46` and `15194` (a ball outside the walls can travel sideways for a whole take
and is then simply lost). Two small changes close it:

* the side walls moved 2 px inward (`x = -8` and `x = 548`), so their inner faces (2 and 538) sit
  **behind** the edge bricks instead of leaving a slot in front of them;
* `_tick_balls()` gained the same kind of last-resort guard the safety floor already uses: a ball
  found outside `[RADIUS, VIEW.x - RADIUS]` is put back at the wall face with `vel.x` reversed.

After the change every sim reports `ball_x` inside the arena: `[6..534]`, `[6..535]`, `[6..538]`.
The guard does not fire in normal play (no test output changed because of it).

### 3.5 Test-harness geometry (they are geometry assertions, not weakened ones)

`autoload/test_runner.gd` had absolute screen coordinates that only worked with the old layout; they
now derive from the field/paddle, so the assertions keep their original meaning:

| helper / check | before | after |
|---|---|---|
| `_park_ball` / floor keep-alive ball | `y = 700` (was below a field ending at 664) | `_open_band_y(g)` = field bottom + 36 = 775 |
| `level03_guide_path` serve into the stem | `y = 738.0` | field bottom + 74 = 813 |
| safety-floor "power-up falls through" | `y > 890.0` after 40 frames | `y > SafetyFloor.Y + 10` after 70 frames (starts at `SafetyFloor.Y - 75`) — stronger: it now really passes the bar |
| `_miss_star` (star past the paddle) | `y = 800` | `paddle.position.y + 30` |

No assertion was relaxed: the same properties are checked, at coordinates that follow the layout.

---

## 4. Files touched (3)

| File | Why |
|---|---|
| `scripts/breakout_game.gd` | pacing constants + `powerup_chance()`, `PADDLE_Y` 760→890, derived field pitch/origin in `_load_level`, wall inset, arena containment guard |
| `scripts/safety_floor.gd` | `Y` 880→930 so the bar stays below the moved paddle |
| `autoload/test_runner.gd` | layout-derived spawn points / floor threshold described in 3.5 |

Not touched (by design): `scripts/powerup.gd` (`FALL_SPEED` stays 95), `scripts/ball.gd`,
`scripts/paddle.gd`, `scripts/game_recorder.gd`, `scripts/record_session.gd`,
`scripts/audio_capture.gd`, all level JSON/PNG data, `project.godot` (portrait 540×960, stretch,
input maps, autoload list), drop weights, NUKE radius, win rule, 3-star system.

---

## 5. Verification (final code), run serially

| # | Command | Exit | Verdict line |
|---|---------|------|--------------|
| 1 | `"$G" --headless --path . -- --breakout-test` | 0 | `WR_BREAKOUT_RESULT PASS failing suites: 0` |
| 2 | `"$G" --headless --path . -- --breakout-smoke` | 0 | `WR_BREAKOUT_SMOKE_RESULT PASS menu_buttons=6 bricks=962 balls=1 state=ready` |
| 3 | `"$G" --headless --path . -- --breakout-editor-test` | 0 | `WR_BREAKOUT_EDITOR_RESULT PASS failing suites: 0` |

### Sim win times, seed 1, real time (after)

```
WR_BREAKOUT_SIM level=level_05_messi seed=1 won=true elapsed=49.5 bricks_left=81 bricks_total=5427 score=112504250 lives=3 hits=5346 longest_stall=9.2s ball_x=[6..534] stars=2/3 nukes=9 nuke_bricks=1237 peak_balls=180
WR_BREAKOUT_SIM level=level_01_portrait seed=1 won=true elapsed=23.4 bricks_left=14 bricks_total=962 score=4479340 lives=3 hits=948 longest_stall=1.4s ball_x=[6..534] stars=1/3 nukes=5 nuke_bricks=579 peak_balls=120
WR_BREAKOUT_SIM level=level_02_jensen seed=1 won=true elapsed=30.7 bricks_left=24 bricks_total=1653 score=29645280 lives=3 hits=1629 longest_stall=3.3s ball_x=[6..535] stars=3/3 nukes=6 nuke_bricks=927 peak_balls=120
WR_BREAKOUT_SIM level=level_03_solid_path seed=1 won=true elapsed=31.9 bricks_left=15 bricks_total=1064 score=14046730 lives=3 hits=1049 longest_stall=1.9s ball_x=[6..534] stars=2/3 nukes=4 nuke_bricks=666 peak_balls=120
WR_BREAKOUT_SIM level=level_04_ronaldo seed=1 won=true elapsed=61.8 bricks_left=74 bricks_total=4951 score=122724980 lives=3 hits=4877 longest_stall=9.3s ball_x=[6..538] stars=3/3 nukes=10 nuke_bricks=1563 peak_balls=180
```

| Level | before (8194428) | after | Δ | stars | score (after) |
|---|---|---|---|---|---|
| level_01_portrait | 27.0 s | **23.4 s** | −3.6 s | 1/3 | 4,479,340 |
| level_02_jensen | 31.9 s | **30.7 s** | −1.2 s | 3/3 | 29,645,280 |
| level_03_solid_path | 22.3 s | **31.9 s** | +9.6 s | 2/3 | 14,046,730 |
| level_04_ronaldo | 51.5 s | **61.8 s** | +10.3 s | 3/3 | 122,724,980 |
| level_05_messi | 31.0 s | **49.5 s** | +18.5 s | 2/3 | 112,504,250 |

* **Messi: WIN at 49.5 s, inside the 40–55 s bar, 2/3 stars, score 112,504,250.** The sim was run
  twice with the final constants and returned 49.5 s both times (deterministic per seed/code).
* All four other levels WIN, every one well under 90 s (max 61.8 s), none timed out.
* Ronaldo moved 51.5 → 61.8 s and is reported as measured, not tuned back to the old number.

### Recording (`--breakout-record`) — BLOCKED in this environment

```
$ "$G" --headless --path . -- --breakout-record level=level_05_messi
WR_BREAKOUT_RECORD_RESULT FAIL recorder refused: the headless renderer produces no frames to record
EXIT=1
```

The recorder refuses headless by design (`game_recorder.gd` checks `DisplayServer.get_name() ==
"headless"`), and this VM has no display server, no `Xvfb`/`xvfb-run` and no `ffmpeg`, and no root to
install them (`sudo` is blocked, `apt-get` cannot write its lock). **No take was recorded and
`win_wall` is therefore NOT measured here.** What can be said honestly: the whole recorder path
(`game_recorder.gd`, `record_session.gd`, `audio_capture.gd`) is byte-identical to 8194428 — this
patch does not touch the slot-based capture, the win stamp or the A/V correction, and the win stamp
still anchors on the same single `game_ended` signal. The ≤0.15 s anchor claim itself can only be
re-verified on a machine with a display:
`"$G" --path . -- --breakout-record level=level_05_messi`.

---

## 6. Measured trials while choosing the pacing (honest tuning record)

The ball count is **multiplicative** in caught `x3` drops (each one triples the balls in play), so the
time a take ends at is strongly stepped, not smooth: two chances 0.02 apart can differ by 10–20 s.
Every row below is a real `--breakout-sim level=level_05_messi seed=1 seconds=110` run.

| START | END | RAMP | Messi win time | balls at t=20 |
|---|---|---|---|---|
| 0.08 | 0.32 | 40 | 60.2 s | 3 |
| 0.08 | 0.48 | 30 | 57.4 s | – |
| 0.08 | 0.56 | 28 | 56.5 s | – |
| 0.08 | 0.58 | 28 | 68.7 s | – |
| 0.08 | 0.62 | 26 | 80.8 s | – |
| 0.08 | 0.56 | 22 | 80.6 s | – |
| 0.08 | 0.36 | 22 | 82.1 s | – |
| 0.10 | 0.46 | 40 | 55.7 s | 6 |
| 0.10 | 0.46 | 35 | 75.4 s | 5 |
| 0.10 | 0.46 | 34 | 60.8 s | 6 |
| 0.10 | 0.42 | 40 | **49.5 s** | 6 |
| 0.10 | 0.56 | 35 | 75.4 s | 5 |
| 0.11 | 0.46 | 36 | 60.6 s | 6 |
| 0.12 | 0.50 | 40 | 75.7 s | 5 |
| 0.14 | 0.56 | 30 | 72.3 s | 5 |

`0.10 / 0.42 / 40` was chosen because it is the measured configuration inside 40–55 s (49.5 s, mid
band) — not because it is the only one that can.

---

## 7. Known limitations / things still to check by hand

1. **No recorded take** (section 5). A/V sync and `win_wall` are unverified here; the recorder code is
   unchanged by this patch.
2. **Longest stall is large on the dense levels** (9.2 s Messi, 9.3 s Ronaldo). This is the dense
   field's tail (the last ~1.5 % of bricks are picked off by NUKEs) and it got bigger with the larger
   field; it is not a hang — the level still wins.
3. **Win time is sensitive to the pacing constants** (section 6). The values were chosen against
   `level_05_messi seed=1`, which is the stated bar; another seed can land differently.
4. **Editor canvas pitch**: the editor still draws levels at the JSON pitch (12 / 6 px), while the
   played field is now full width (13.5 / 6.75). Editor **PLAY** runs the real game scene, so it is
   full width; only the painting grid in the editor is at the old pitch. Not changed — out of scope.
5. **The decorative frame is clipped at the sides.** `BrickField` draws an 8 px frame around the grid;
   with the grid at x 0…540 that outline now runs off the left and right edges. The brick portrait
   itself is complete (540 × 675, nothing cropped, nothing stretched); only that thin outline is cut.
6. **The arena containment guard** (3.4) is a new last-resort behaviour. It never fired in the
   measured runs with the inset walls, but it is a behaviour change in `_tick_balls()` and is
   documented as such.
7. **Visual check not performed**: no frame was rendered or looked at in this environment (headless
   only), so the new gap and the edge-to-edge field have not been inspected by eye.
