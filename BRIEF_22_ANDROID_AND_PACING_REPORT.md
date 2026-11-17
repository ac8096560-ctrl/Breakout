# BRIEF 22 — Android level loading, any-art import, 60–90 s pacing, the NUKE

Base commit: `1c940e4` (branch `main`). Godot `4.7.2.stable.official.ed1daf0bf`,
Linux headless binary. Every number below was printed by a command that ran in
this workspace; nothing is estimated. Suites were run **serially** (one shared
`user://` store).

---

## 0. Baseline (before any edit, at `1c940e4`)

| Command | Result |
|---|---|
| `--breakout-test` | **PASS** — 21/21 suites, `WR_BREAKOUT_RESULT PASS failing suites: 0` |
| `--breakout-editor-test` | **PASS** — 6/6, `WR_BREAKOUT_EDITOR_RESULT PASS` |
| `--breakout-smoke` | **PASS** — `menu_buttons=6 bricks=962 balls=1 state=ready` |
| `--breakout-pace` | **PASS** — `level_01_portrait cleared=true elapsed=40.3` |
| `--breakout-sim level=level_01_portrait seconds=120 seed=1` | **PASS** — `won=true at 35.9s` |
| `--breakout-sim level=level_02_jensen seconds=120 seed=1` | won at **25.8 s** |
| `--breakout-sim level=level_03_solid_path seconds=120 seed=1` | won at **32.6 s** |
| `--breakout-sim level=level_04_ronaldo seconds=320 seed=1` | **never won** — 282 left at t=200, 261 left at t=230, ~4 bricks/s in the tail |

The base was healthy on desktop, so the work below was done on it. The Android
defect is not visible headless on desktop (see Task 1).

---

## 1. Task 1 (CRITICAL) — levels did not load in the Android APK

**Cause (as briefed, verified in the source):** `scripts/level_loader.gd` read
the level PNG with
`Image.load_from_file(ProjectSettings.globalize_path(img_path))`. In an exported
Android build `res://` lives *inside* the APK, `globalize_path()` returns a path
that is not a real file, `load_from_file()` returns `null`, and every level
failed with `cannot decode png` → the menu showed raw ids and PLAY could not
start a level.

**Fix**

* New `BreakoutLevel.load_png_image(path)` — `FileAccess.get_file_as_bytes()` +
  `Image.load_png_from_buffer()` (JPEG accepted too, for the importer). This is
  the *only* PNG reader in the project now: it reads `res://` from inside the
  APK **and** `user://` off disk, so a level the editor just wrote still loads
  in the same run it was created (no Godot import step).
* `scripts/editor.gd::load_level_id()` used the same
  `globalize_path` + `load_from_file` pair and had the identical APK bug when
  opening a shipped level in the editor; it now uses the same helper.
* `scripts/level_writer.gd`: `SHIPPED_IDS` now lists all four levels
  (`level_01_portrait`, `level_02_jensen`, `level_03_solid_path`,
  `level_04_ronaldo`), so the editor's `find_all()` can open 03 and 04.

**Proof the loader no longer uses the broken path** (`grep -n globalize_path
scripts/level_loader.gd`): the only three matches are in comments that explain
the bug; `grep -rn "Image.load_from_file" scripts/ autoload/` matches comments
only.

**Verification — new suite `apk_level_loader`** (part of `--breakout-test`),
which loads every shipped level through `BreakoutLevel.load_level`, decodes its
PNG through the bytes path and prints ok + bricks/breakable:

```
WR_BREAKOUT_SUITE apk_level_loader PASS level_01_portrait ok=true bricks=962 breakable=962
 | level_02_jensen ok=true bricks=1898 breakable=1724
 | level_03_solid_path ok=true bricks=1064 breakable=1064
 | level_04_ronaldo ok=true bricks=5945 breakable=4951
 | mismatched png 10x12 -> grid 20x26 ok=true bricks=417
```

The same suite also proves the "old/hand-made PNG is scaled, not rejected" rule
of Task 2. It exercises the reader, not an APK: a real APK on a phone still
needs the owner's build + tap-through (see *Manual checks still required*).

---

## 2. Task 2 — level editor: import ANY art, any size

* **Loader tolerance** (`level_loader.gd`): a PNG whose pixel size is not
  `cols x rows` is now stretched onto the grid (`Image.resize(..., INTERPOLATE_NEAREST)`)
  instead of returning `ok:false "portrait is WxH but the level says CxR"`.
* **Editor import** (`editor.gd`):
  * `import_art(path, target_cols = 0, target_rows = 0)` decodes any PNG/JPEG,
    **stretches it to exactly cols x rows** (Lanczos when shrinking, nearest
    when growing), adopts the current grid (or the requested one), picks
    `cell = min(12, 480/cols, 600/rows)` so the field keeps the 480x600 area
    (an 80x100 grid gets cell 6, exactly like level_04), re-carves the Y channel
    if the existing one does not fit, re-derives the power-up tips and marks the
    level dirty. SAVE then writes the ordinary PNG + JSON pair — **no second
    level format**.
  * UI: an **IMPORT** button (magenta) next to the existing grid presets, with a
    new **80x100** preset and a FileDialog over `ACCESS_FILESYSTEM`
    (`*.png, *.jpg, *.jpeg`). The grid size used is the editor's current grid,
    shown in the counts line.
* **Verification — two new editor suites** (a 37x91 image, i.e. neither the
  grid size nor its aspect):

```
WR_BREAKOUT_SUITE editor_import_any_size PASS 37x91 -> 20x26 import=true bricks=424 saved=true loader=true png=20x26
WR_BREAKOUT_SUITE editor_import_ronaldo_grid PASS 37x91 -> 80x100 ok=true breakable=7502 tiles=7856
```

---

## 3. Task 4 — the new power-up: **NUKE** (magenta)

One catch detonates a radial blast: **every breakable brick within 14 cells of
the blast cell is broken**, through the normal `break_cell()` path, so score,
combo chain, power-up drops, star milestones and the win rule all behave exactly
as in play. Unbreakable cells (the border, level_04's two grey wall columns, the
filled left frame) are walls and survive.

* **Blast cell rule (documented in code):** the **lowest remaining breakable
  brick**, ties broken by nearest the field's centre column. That is where a
  take actually stalls — the last few dozen bricks of a dense level sit lowest
  and are the ones a 175-ball field keeps missing.
* **Rarity:** pool weight **4%** (`+3 52% · x3 20% · minus 9% · star 5% ·
  floor 10% · NUKE 4%`, measured 3.5–4% over 2000 draws). Rare enough to be an
  event, common enough to matter: 9–16 catches per level_04 take.
* **Look:** the only hot-pink drop, a white four-point blast star inside two
  overhanging rings, plus a magenta flash + two shock rings at the blast and a
  **HUD counter** (`NUKE xN  (M BRICKS)`, hidden until the first catch).
* **Auto-play uses it:** the AI's drop picker is value-weighted
  (`nuke 9 > star 7 > x3 5 > +3 4 > floor 2 > minus -2`) and will detour for a
  catchable NUKE.
* **Verification:**

```
WR_BREAKOUT_SUITE powerup_nuke PASS blast=(21, 49) (lowest=49) broke=229 expected=229 caught=1 walls 0->0 telemetry=229
WR_BREAKOUT_SUITE drop_pool   PASS plus3=52.6% times3=20.6% minus=8.6% star=4.9% floor=9.8% nuke=3.5% sum=1.000 (n=2000)
```

`simer` shows the NUKE firing in real takes: level_04 seed 3 caught **15**
nukes worth **2,142 bricks** (43% of the level).

---

## 4. Task 3 + 5 — pacing and the auto-play AI

### 4.1 What was actually stopping level_04

Three separate defects, each found by measurement:

1. **The grey rule** (`tools/make_level_04_ronaldo.py`, as briefed): every
   grey-ish art pixel was unbreakable (309 cells, 261 in the face/hair). Now
   **only wall columns 9 and 12** are grey-unbreakable, and a grey art pixel
   elsewhere keeps its colour but is **breakable**. Rebuilt the pair with the
   fixed script.
2. **A 1-cell-wide, physically unreachable slot.** After the grey fix the take
   cleared 5,153 → 136 bricks and then froze; a `--breakout-sim dump=1` map
   (new diagnostic flag) showed **64 of the 136 in column 1**: the v3 "cavity
   fill" only filled the *black* pixels of cols 2–5, leaving col 1 as 6 px of
   space for an 8 px ball. No ball can ever enter it. Fix: the whole left frame
   strip (cols 1–5, 490 cells) is now solid red unbreakable — the same
   structural rule the border ring already follows. **Breakable count 5,153 →
   4,951** (the 89 unreachable bricks + 111 art pixels inside the frame strip are
   no longer part of the breakable set). This is the only brick-count change,
   and it removes bricks no ball could reach — it is not a thinning of playable
   art.
3. **The serve missed level_04's stem.** `SERVE_ANGLE_DEG = 2°` drifts ~2.6 px
   over the 74 px trip to the stem gap: fine for level_01's 24 px stem, fatal
   for level_04's 12 px one (a ~4 px window). Measured as a **19 s opening
   stall** at 570 px/s in which the first ball never entered the field. The
   serve angle is now **derived from the level's own stem width**
   (`_serve_angle_deg()`), so every level threads its stem.

### 4.2 Levers used (all from the brief's allowed list)

| Lever | Before | After |
|---|---|---|
| Dense-field ball speed | 420 | **570** (only for fields ≥ 2,500 breakable) |
| Dense-field ball cap | 120 | **180** (same condition) |
| Nuke drop weight / radius | — | **4% / 14 cells** |
| Serve angle | fixed ±2° | derived from the stem width |
| AI drop picker | lowest drop | **value-weighted**, skips the "−1 ball" debuff, also catches 3-star collectibles, detours only when the next save is still ≥ 0.3 s away |

The dense-field rule keeps levels 01–03 at the reference pace they were tuned
at (applying 570/180 to them shortened their takes by ~25%, measured, so it is
gated on brick count, not applied globally). **Nothing is scripted for a win**:
drops are ordinary pool draws, the blast breaks real bricks, the win rule
(`WIN_LEFTOVER = 0.015`) is unchanged, and no seed is selected for.

### 4.3 Measured win times — `--breakout-sim` (time_scale 1, authoritative)

| Level | seed 1 | seed 3 | seed 7 | seed 42 | breakable | win at |
|---|---|---|---|---|---|---|
| level_01_portrait | **27.0 s** | **38.5 s** | **24.2 s** | **32.1 s** | 962 | 14 left |
| level_02_jensen | **28.4 s** | **32.4 s** | **30.1 s** | **29.4 s** | 1,724 | 25 left |
| level_03_solid_path | **22.3 s** | **24.7 s** | **33.7 s** | **27.1 s** | 1,064 | 15 left |
| level_04_ronaldo | **51.5 s** | **63.2 s** | **82.3 s** | **76.9 s** | 4,951 | 74 left |

All 16 runs `won=true`. Baseline for comparison: 35.9 / 25.8 / 32.6 / **never**.

`--breakout-pace` (time_scale 6, approximate — the 6× step is why the sim above
is the number to trust): level_01 42.0 s, level_02 93.1 s, level_03 42.4 s,
level_04 105.6 s, all four `cleared=true`.

### 4.4 Honest verdict on "60–90 s for every level"

* **level_04 is fixed as a take**: 51.5 / 63.2 / 82.3 / 76.9 s — three of the
  four seeds sit inside 60–90 s, all are under 90 s, mean 68.5 s. Before this
  brief it never finished (241+ bricks left at 140 s; ~300 s+ per the brief).
* **levels 01–03 finish in 22–39 s, i.e. *under* the window**, not over it.
  They were already under it at the baseline (35.9 / 25.8 / 32.6 s), so this is
  the pre-existing state, not a regression from this brief: a 962-brick field
  simply cannot fill 60 s at a watchable pace. Getting them into 60–90 s needs a
  *design* change I did not make silently — **proposal:** ship denser art
  (e.g. 80x100 versions of 01–03, ~4,000–5,000 breakable) or a per-level ball
  speed, and each take lands in the same band level_04 now occupies. Both are
  content decisions for the owner; the level format (PNG + JSON) already
  supports them and the editor's new 80x100 IMPORT makes them a 10-minute job.

### 4.5 AI changes (Task 5)

* **Drop catching is value-weighted** and time-aware (`_best_pickup_x()`):
  the AI takes the NUKE over a "+3", never chases the orange "−1 ball" debuff,
  catches the falling 3-star collectibles, and only detours when the next save is
  at least 0.3 s away, so aiming never trades a life for a drop.
* **The serve is aimed per level** (`_serve_angle_deg()`), which removed the
  dead opening stretch on the 6 px grid.
* The existing Stage-D ray planner (`_aim_score`, channel bonus, unbreakable
  walls reflecting instead of breaking) is untouched; with the nuke and the
  serve fix it now wins every level on every tested seed.
* The AI still plays by exactly the human physics: no teleporting the ball, no
  forced breaks, no skipping the paddle.

---

## 5. Files changed

| File | Why |
|---|---|
| `scripts/level_loader.gd` | APK-safe PNG reading (`FileAccess` + buffer), JPEG for import, scale-mismatched PNGs instead of rejecting, `load_png_image()` helper |
| `scripts/level_writer.gd` | `SHIPPED_IDS` lists all four levels (editor `find_all()`) |
| `scripts/editor.gd` | IMPORT ANY ART (`import_art`, FileDialog, 80x100 preset), APK-safe level load |
| `scripts/breakout_game.gd` | NUKE power-up + pool entry + telemetry, density-gated ball speed/cap, stem-derived serve angle, value-weighted drop catching |
| `scripts/powerup.gd` | NUKE capsule art (magenta star + double ring) |
| `scripts/hud.gd` | NUKE counter |
| `autoload/test_runner.gd` | new suites `apk_level_loader`, `powerup_nuke`, `editor_import_any_size`, `editor_import_ronaldo_grid`; drop-pool/nuke assertions; ball cap read from the game; `dump=1` sim diagnostic; sim line reports nukes |
| `tools/make_level_04_ronaldo.py` | grey rule = wall columns only; left frame strip solid (unreachable slot fix) |
| `data/levels/level_04_ronaldo.png` / `.json` | regenerated by that script (5,947 solid, 4,951 breakable, 996 unbreakable) |

No scene, project setting, autoload, input map, physics setting, win rule or
level-format change. Human mouse/touch/keyboard paddle control is untouched.

## 6. Test results after the change (serial)

| Command | Result |
|---|---|
| `--breakout-test` | **PASS** — 23/23 suites (`WR_BREAKOUT_RESULT PASS failing suites: 0`) |
| `--breakout-editor-test` | **PASS** — 8/8 (`WR_BREAKOUT_EDITOR_RESULT PASS failing suites: 0`) |
| `--breakout-smoke` | **PASS** — `menu_buttons=6 bricks=962 balls=1 state=ready` |
| `--breakout-pace` ×4 levels | **PASS** — all `cleared=true` (42.0 / 93.1 / 42.4 / 105.6 s) |
| `--breakout-sim` 4 levels × 4 seeds | **PASS** — 16/16 `won=true` (table above) |

No assertion was weakened: the drop-pool test now checks the real six-kind pool,
the ball-cap test reads the game's own cap, and the nuke test compares the blast
against a cell-by-cell expectation of the radius.

## 7. Manual checks still required (cannot be done here)

* **A real Android APK build + tap-through on a phone** — this is the one thing
  a headless desktop run cannot prove. Build with the existing
  `export_presets.cfg`, install, and confirm: the menu shows *display names*
  (not raw ids), PLAY starts each of the four levels, the fields render, and the
  editor can open level_03 / level_04 via LOAD NEXT.
* **Touch drag on the phone** (mouse drag is covered by `player_input`).
* **Visual check of the NUKE** drop icon, blast flash and HUD counter on a
  device (it is drawn, and it triggered 9–16 times per level_04 take in sims,
  but the visuals were never viewed).
* **Recording an actual 1080x1920 take** (`--breakout-record` needs a display;
  not run here).
