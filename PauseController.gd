# res://globals/PauseController.gd
extends Node

const PAUSE_MENU_SCENE := "res://scenes/ui/PauseMenu.tscn"

var paused: bool = false
var pause_menu: Node = null

func _ready() -> void:
	# Load the pause menu PackedScene safely
	var packed: PackedScene = null
	if ResourceLoader.exists(PAUSE_MENU_SCENE):
		packed = load(PAUSE_MENU_SCENE)

	if not packed:
		push_error("[PauseController] PauseMenu scene not found at: %s" % PAUSE_MENU_SCENE)
		return

	# instantiate and add to the root viewport (so it's above the game and visible even when current_scene changes)
	pause_menu = packed.instantiate()
	if pause_menu == null:
		push_error("[PauseController] Failed to instantiate PauseMenu.")
		return

	# Add to root so CanvasLayer renders above all scenes and won't block input when hidden
	get_tree().get_root().add_child(pause_menu)

	# ensure it's hidden initially and doesn't block input
	if pause_menu.has_method("set_visible_on_pause"):
		pause_menu.set_visible_on_pause(false)
	else:
		# fallback defensive behavior
		pause_menu.visible = false

	# Allow _unhandled_input to capture Esc while game is running
	set_process_unhandled_input(true)

	# Optionally listen for app quit events on supported platforms
	if get_tree().has_signal("about_to_quit"):
		get_tree().connect("about_to_quit", Callable(self, "_on_about_to_quit"))

func _unhandled_input(event) -> void:
	# Toggle pause when the "pause" action is pressed (map to Esc)
	if event.is_action_pressed("pause") and not event.is_echo():
		toggle_pause()

func toggle_pause() -> void:
	if paused:
		resume_game()
	else:
		pause_game()

func pause_game() -> void:
	if paused:
		return
	paused = true
	# show menu first (so it can grab focus) then pause tree
	if pause_menu and pause_menu.has_method("set_visible_on_pause"):
		pause_menu.set_visible_on_pause(true)
	else:
		if pause_menu:
			pause_menu.visible = true
	# Pause the game
	get_tree().paused = true
	# show mouse so user can interact with menu
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	print("[PauseController] Game paused")

func resume_game() -> void:
	if not paused:
		return
	# hide menu first so input is not trapped by UI when unpausing
	if pause_menu and pause_menu.has_method("set_visible_on_pause"):
		pause_menu.set_visible_on_pause(false)
	else:
		if pause_menu:
			pause_menu.visible = false
	# unpause the tree
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE) # change to CAPTURED if you want to recapture
	paused = false
	print("[PauseController] Resumed")

# Save helpers (delegates to GameState if avail)
func save_game() -> void:
	# prefer GameState autoload if present
	if has_node("/root/GameState"):
		var gs = get_node("/root/GameState")
		if gs.has_method("save"):
			gs.save()
			print("[PauseController] GameState.save() called")
			return
		if gs.has_method("save_game"):
			var scene_path := ""
			var pos := Vector2.ZERO
			if get_tree().current_scene:
				scene_path = get_tree().current_scene.scene_file_path
			if "checkpoint_position" in gs:
				pos = gs.checkpoint_position
			gs.save_game(scene_path, pos)
			print("[PauseController] GameState.save_game(...) fallback called")
			return

	var cfg := ConfigFile.new()

	# optional: store current scene path if available
	if get_tree().current_scene:
		cfg.set_value("fallback", "scene", get_tree().current_scene.scene_file_path)

	var path := "user://fallback_save.cfg"
	var err := cfg.save(path)
	if err != OK:
		push_error("[PauseController] Could not write fallback save to %s (err %s)" % [path, str(err)])

func save_and_quit() -> void:
	save_game()
	quit_now()

func quit_now() -> void:
	print("[PauseController] Quitting now (no save).")
	get_tree().quit()

func _on_about_to_quit() -> void:
	# called on some platforms before exit
	print("[PauseController] about_to_quit — saving before exit.")
	save_game()
