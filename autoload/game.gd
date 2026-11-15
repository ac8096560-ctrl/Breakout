extends Node
## Game (autoload) — the tiny session owner: which portrait level, which seed,
## whether the paddle auto-plays, and the scene changes. This is the Breakout
## equivalent of WorldRace's Game autoload, with no race concepts in it.

const LEVELS := ["level_01_portrait"]
const SEED_OPTIONS := [1, 2, 3, 7, 42]
const THEME_ID := "rose"

const MENU_SCENE := "res://scenes/menu.tscn"
const GAME_SCENE := "res://scenes/game.tscn"

var menu_level_idx := 0
var menu_seed_idx := 0
var game_seed := 1
var level_id := "level_01_portrait"
var auto_play := true
var theme_id := THEME_ID
var last_result: Dictionary = {}


func resolve_seed() -> int:
	return int(SEED_OPTIONS[posmod(menu_seed_idx, SEED_OPTIONS.size())])


func seed_label() -> String:
	return "SEED %d" % resolve_seed()


func level_display_name() -> String:
	var lv := BreakoutLevel.load_level("res://data/levels/%s.json" % level_id)
	if bool(lv.get("ok", false)):
		return str(lv.get("name", level_id))
	return level_id


## Start a game. `seed_value` < 0 keeps the current seed (the recording path).
func start_game(seed_value := -1) -> void:
	if seed_value >= 0:
		game_seed = seed_value
	level_id = LEVELS[posmod(menu_level_idx, LEVELS.size())]
	get_tree().paused = false
	get_tree().change_scene_to_file(GAME_SCENE)


## A fresh take on the same level + seed — used by RecordSession and by the
## game-over retry, so a recording always starts from the level's first frame.
func restart_game() -> void:
	start_game(game_seed)


func goto_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_SCENE)
