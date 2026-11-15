# Pixel Breakout — AI Development Instructions (AGENTS.md)

Project-specific operating rules for any agent working in THIS repository.
Read this file before the first edit of a session.

This is a **standalone game**. It is not a mode, scene or subsystem of
WorldRace: it has its own `project.godot`, its own autoloads, its own `user://`
store and its own tests. Do not import race concepts (racers, floods,
standings, finish lines, participants, match rules) into it.

---

## 1. Role and objective

Senior Godot 4.7 / GDScript game developer, gameplay engineer, performance
specialist, automated-QA engineer and documentation writer.

**The objective is working, measured features — not plausible-looking code.**
Every change ends with evidence from a command that actually ran.

---

## 2. Environment facts

| Item | Value |
|---|---|
| Godot | 4.7.2.stable (`ed1daf0bf`), GL Compatibility |
| Project | `config/features = 4.7`, portrait 540×960, `canvas_items` stretch, 2D gravity 0.0 |
| Layout | `scenes/`, `scripts/`, `data/`, `autoload/`, `art/`, `audio/`, `shaders/`, `tools/` |
| Version control | none assumed in the working copy; the GitHub repo is set up by the owner |

The Godot binary is **not on PATH** in the reference environment. Call it by
absolute path (the owner's Linux binary lives at
`~/Projects/WorldRace/tools/Godot_v4.7.2-stable_linux.x86_64`; on Windows it is
the `Godot_v4.7.2-stable_win64.exe` folder). Shared tooling — the Godot binary,
FFmpeg, Xvfb and the recording pipeline — is **not duplicated in this project**.

```bash
G=/path/to/Godot_v4.7.2-stable_linux.x86_64
"$G" --headless --path . -- --breakout-test
```

---

## 3. What must not regress

- Portrait **540×960**, `canvas_items` stretch, gravity 0.0, GL Compatibility.
- **Player control is real**: mouse motion / touch drag moves the paddle, arrow
  keys (and A/D) are the desktop fallback, and **auto-play** is the default for
  recording. WorldRace's "no human control" rule does **not** apply here.
- **The brick layout is a portrait**, not a uniform grid, and every level has a
  **carved channel with a fork** (stem + two arms). A level without a fork is a
  bug.
- **Physics ball**: velocity + bounce off walls, paddle and bricks. Paddle hit
  position sets the bounce angle. Balls below the paddle are lost.
- **"+3" multi-ball** (blue and green): falling, caught by the paddle, lost if
  it falls past, +3 balls on catch.
- **Flow**: ready → playing → ball_lost → level_clear / game_over, with
  `game_ended` as the single end signal.
- **Recorder wiring**: `GameRecorder` captures the viewport; `RecordSession`
  auto-stops on `game_ended`; the REC pill is instantiated by the game scene.
  Recordings are 1080×1920 at 30 fps unless the user asks otherwise.
- **Test contract**: `WR_BREAKOUT_*_RESULT PASS|FAIL`, exit 0/1. Never weaken an
  assertion to make a run green.

---

## 4. Coding standards

- Godot **4.7** APIs only; typed GDScript where the file is typed; tabs.
- Minimal, targeted diffs. Never rewrite a shared script to bolt on a feature.
- Never change resolution, stretch, input maps, physics settings or the
  autoload list (`Game`, `TestRunner`, `AudioManager`, `GameRecorder`,
  `RecordSession`) without an explicit request.
- Safe access: `get_node_or_null`, `is_instance_valid`; nodes are freed at
  runtime (bricks, balls, power-ups), so stale references are a real crash.
- No per-frame allocations in hot paths. The brick field is ONE `_draw()`
  pass over the grid; keep it that way (1,700 bricks must never become 1,700
  canvas items).
- Level data lives in `data/levels/` as **PNG + JSON only**. Stage B's editor
  writes exactly that pair — do not invent a second level format.
- No hard-coded absolute paths inside game code.
- `AudioManager.play("…")` is the only way a sound is played; unknown event
  names must stay absent from `stats().missing`.

---

## 5. Testing standards

`autoload/test_runner.gd` is the harness: one `--mode` per suite, one verdict
line per suite, one summary line, exit 0 on pass / 1 on fail.

```bash
"$G" --headless --path . -- --breakout-test     # gameplay suites (must pass)
"$G" --headless --path . -- --breakout-smoke    # menu + scene build
"$G" --headless --path . -- --breakout-pace     # 70s pacing measurement
"$G" --path . -- --breakout-record              # one recorded take (needs a display)
```

Rules:

- Run suites **serially** — every instance shares one `user://` store.
- Windowed suites need a display (Xvfb is fine); headless cannot capture
  viewport frames, so the recorder refuses in headless by design.
- Record every result as **PASS / FAIL / BLOCKED / NOT RUN** with the command
  and the exit code. A parse check is not a gameplay result.
- No Godot process may be left running after a sweep; kill only the PIDs you
  started (never `pkill -f godot`).

---

## 6. Reporting standards

Every implementation task ends with: what changed and why, the exact list of
files touched, the commands actually run (with exit codes) and their verdict
lines, measured numbers (pacing, fps, encode time), known limitations, and any
manual verification still required (visual/audio checks usually are).

**Never claim a test passed unless you ran it and read its output. Never hide a
failure to make a report look clean.**

---

## 7. Change safety

- Before a risky change, copy the files you will touch into
  `backups/pre_<topic>_<YYYY-MM-DD>/`.
- Never delete or rename scenes, scripts, level files or audio without
  approval. Never bulk-revert or "clean" the project.
- Never commit to, push to, or merge into any branch unless the task says so.
