extends Node
## Game (autoload) — the tiny session owner: which portrait level, which seed,
## whether the paddle auto-plays, and the scene changes. This is the Breakout
## equivalent of WorldRace's Game autoload, with no race concepts in it.

const LEVELS := ["level_01_portrait", "level_02_jensen"]
const SEED_OPTIONS := [1, 2, 3, 7, 42]
const THEME_ID := "rose"

const MENU_SCENE := "res://scenes/menu.tscn"
const GAME_SCENE := "res://scenes/game.tscn"
const EDITOR_SCENE := "res://scenes/editor.tscn"

var menu_level_idx := 0
var menu_seed_idx := 0
var game_seed := 1
var level_id := "level_01_portrait"
var auto_play := true
var theme_id := THEME_ID
var last_result: Dictionary = {}
## Stage B — a level played straight from the editor: an explicit JSON path that
## wins over the id lookup (the editor saves to user:// so a shipped file is
## never overwritten). Empty means "derive the path from level_id".
var play_level_path := ""
## True while a take was launched from the editor, so the end-of-game click
## returns to the editor instead of the menu.
var editor_return := false
## The editor's in-memory state, kept across the scene change so PLAY -> back
## returns to the same level instead of an empty grid.
var editor_snapshot: Dictionary = {}


func resolve_seed() -> int:
	return int(SEED_OPTIONS[posmod(menu_seed_idx, SEED_OPTIONS.size())])


func seed_label() -> String:
	return "SEED %d" % resolve_seed()


## The JSON for a level id: an explicit editor path first, then the shipped
## folder, then the user folder the editor falls back to when res:// is
## read-only. Nothing else in the game resolves a level path.
func level_json_path(id := "") -> String:
	if play_level_path != "" and FileAccess.file_exists(play_level_path):
		return play_level_path
	return BreakoutLevelWriter.find_json(id if id != "" else level_id)


func level_display_name() -> String:
	var lv := BreakoutLevel.load_level(level_json_path())
	if bool(lv.get("ok", false)):
		return str(lv.get("name", level_id))
	return level_id


## Start a game. `seed_value` < 0 keeps the current seed (the recording path).
func start_game(seed_value := -1) -> void:
	if seed_value >= 0:
		game_seed = seed_value
	play_level_path = ""
	level_id = LEVELS[posmod(menu_level_idx, LEVELS.size())]
	get_tree().paused = false
	get_tree().change_scene_to_file(GAME_SCENE)


## Start a NAMED level (the editor path). `json_path` is optional: an empty one
## means "find the id in res:// or user://".
func start_level(id: String, seed_value := -1, json_path := "") -> void:
	if seed_value >= 0:
		game_seed = seed_value
	level_id = id
	play_level_path = json_path
	get_tree().paused = false
	get_tree().change_scene_to_file(GAME_SCENE)


## A fresh take on the same level + seed — used by RecordSession and by the
## game-over retry, so a recording always starts from the level's first frame.
func restart_game() -> void:
	start_level(level_id, game_seed, play_level_path)


func goto_editor() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(EDITOR_SCENE)


func goto_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_SCENE)
