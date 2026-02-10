# res://scenes/ui/PauseMenu.gd
extends Control

const MAIN_MENU_SCENE := "res://scenes/start_screen.tscn" # change if your main menu path differs

@onready var panel         := $Panel
@onready var btn_resume    := $Panel/VBoxContainer/Resume
@onready var btn_options   := $Panel/VBoxContainer/Options
@onready var btn_savequit  := $Panel/VBoxContainer/SaveQuit
@onready var btn_quitmenu  := $Panel/VBoxContainer/QuitMenu

var paused_state: bool = false

func _ready() -> void:
	# start hidden and make hidden UI ignore mouse so it won't block underlying clicks
	panel.visible = false
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	# connect buttons if not wired in inspector
	if btn_resume:
		btn_resume.pressed.connect(Callable(self, "_on_resume_pressed"))
	if btn_options:
		btn_options.pressed.connect(Callable(self, "_on_options_pressed"))
	if btn_savequit:
		btn_savequit.pressed.connect(Callable(self, "_on_save_and_quit_pressed"))
	if btn_quitmenu:
		btn_quitmenu.pressed.connect(Callable(self, "_on_quitmenu_pressed"))

	# listen for platform quit (some platforms emit this)
	if get_tree().has_signal("about_to_quit"):
		get_tree().connect("about_to_quit", Callable(self, "_on_about_to_quit"))

	# allow Esc toggle even if UI doesn't have focus
	set_process_unhandled_input(true)


func _unhandled_input(event) -> void:
	if event.is_action_pressed("pause") and not event.is_echo():
		_toggle_pause()


func _toggle_pause() -> void:
	if paused_state:
		_resume_game()
	else:
		_pause_game()


func _pause_game() -> void:
	if paused_state:
		return
	paused_state = true

	# show menu + make it capture mouse
	visible = true
	panel.visible = true
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	# show mouse so player can click
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# pause AFTER showing menu so UI can grab focus
	get_tree().paused = true

	if btn_resume:
		btn_resume.grab_focus()


func _resume_game() -> void:
	if not paused_state:
		return
	# hide menu first so UI won't trap input on unpause
	panel.visible = false
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	# unpause the tree
	get_tree().paused = false

	# optionally recapture mouse (here we show it; change to CAPTURED if desired)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	paused_state = false


# ---- button callbacks ----
func _on_resume_pressed() -> void:
	_resume_game()


func _on_options_pressed() -> void:
	# TODO: open an options-style overlay (different buttons/layout).
	# placeholder for now — implement options overlay or popup later
	print("[PauseMenu] Options pressed (TODO: open options overlay)")
	# keep menu open or close depending on desired UX; we keep it open now
	return


func _on_save_pressed() -> void:
	# Not connected by default — left for completeness if you add a separate Save button
	_save_game_once()
	print("[PauseMenu] Saved")


func _on_save_and_quit_pressed() -> void:
	# Save then quit application
	_save_game_once()
	# ensure we unpause so save code isn't accidentally blocked
	if get_tree().paused:
		get_tree().paused = false
	paused_state = false
	print("[PauseMenu] Save and Quit requested")
	get_tree().quit()


func _on_quitmenu_pressed() -> void:
	# Save then go back to main menu (don't quit the app)
	_save_game_once()

	# ensure the game is unpaused and menu hidden so the main menu receives input
	if get_tree().paused:
		get_tree().paused = false
	panel.visible = false
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	paused_state = false

	# change scene safely
	if ResourceLoader.exists(MAIN_MENU_SCENE):
		get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	else:
		push_error("[PauseMenu] MAIN_MENU_SCENE not found: %s" % MAIN_MENU_SCENE)
		# fallback: quit the app
		get_tree().quit()


func _on_about_to_quit() -> void:
	# called on some platforms before exit
	_save_game_once()


# ---- small save helper which prefers your GameState autoload ----
func _save_game_once() -> void:
	# prefer an autoload GameState if present
	if has_node("/root/GameState"):
		var gs = get_node("/root/GameState")
		if gs.has_method("save"):
			gs.save()
			return
		if gs.has_method("save_game"):
			var scene_path := ""
			var pos := Vector2.ZERO
			if get_tree().current_scene:
				scene_path = get_tree().current_scene.scene_file_path
			if "checkpoint_position" in gs:
				pos = gs.checkpoint_position
			gs.save_game(scene_path, pos)
			return

	# fallback: minimal ConfigFile fallback
	var cfg := ConfigFile.new()
	if get_tree().current_scene:
		cfg.set_value("fallback", "scene", get_tree().current_scene.scene_file_path)
	cfg.save("user://fallback_save.cfg")
