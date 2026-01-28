# res://scenes/ui/PauseMenu.gd
extends CanvasLayer

@onready var panel := $Panel
@onready var btn_resume := $Panel/VBoxContainer/Resume
@onready var btn_save := $Panel/VBoxContainer/Options
@onready var btn_save_quit := $Panel/VBoxContainer/SaveQuit
@onready var btn_quit := $Panel/VBoxContainer/QuitMenu

func _ready() -> void:
	# Defensive: ensure nodes exist and print diagnostics so we can see what's going on at runtime
	if not panel:
		push_warning("[PauseMenu] Panel node NOT found at $Panel - check scene! Current children: " + str(get_children()))
	else:
		# default hidden
		panel.visible = false
		_set_panel_mouse_filter(false)

	# Connect buttons safely (only if they exist)
	if btn_resume:
		if not btn_resume.pressed.is_connected(Callable(self, "_on_resume")):
			btn_resume.pressed.connect(Callable(self, "_on_resume"))
	else:
		push_warning("[PauseMenu] Resume button not found at $Panel/VBoxContainer/Resume")

	if btn_save:
		if not btn_save.pressed.is_connected(Callable(self, "_on_save")):
			btn_save.pressed.connect(Callable(self, "_on_save"))
	if btn_save_quit:
		if not btn_save_quit.pressed.is_connected(Callable(self, "_on_save_and_quit")):
			btn_save_quit.pressed.connect(Callable(self, "_on_save_and_quit"))
	if btn_quit:
		if not btn_quit.pressed.is_connected(Callable(self, "_on_quit_no_save")):
			btn_quit.pressed.connect(Callable(self, "_on_quit_no_save"))

	# Hide the whole CanvasLayer initially so it doesn't block input.
	self.visible = false

	# debug info
	print("[PauseMenu] ready — self:", self, "panel:", panel)

# Called by PauseController to show/hide
func set_visible_on_pause(visible: bool) -> void:
	# Hide/Show the CanvasLayer so nothing inside can block input when hidden
	self.visible = visible

	# Panel may be null in some weird instancing cases — guard against it
	if panel:
		panel.visible = visible
		_set_panel_mouse_filter(visible)
		if visible and btn_resume:
			btn_resume.grab_focus()
	else:
		# If panel missing, still ensure CanvasLayer visibility is set (so it won't block input)
		push_warning("[PauseMenu] set_visible_on_pause called but panel is null")

# Helper to set mouse_filter for the panel so hidden menu doesn't steal clicks
func _set_panel_mouse_filter(enabled: bool) -> void:
	if not panel:
		return
	if enabled:
		# stop mouse events from passing through while visible
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
	else:
		# ignore the panel entirely so it doesn't block input when hidden
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _on_resume() -> void:
	# call PauseController (autoload) safely
	if has_node("/root/PauseController"):
		var pc = get_node("/root/PauseController")
		if pc and pc.has_method("resume_game"):
			pc.resume_game()
	else:
		# fall back to calling the autoload name if it exists
		if Engine.has_singleton("PauseController"):
			Engine.get_singleton("PauseController").resume_game()

func _on_save() -> void:
	if has_node("/root/PauseController"):
		var pc = get_node("/root/PauseController")
		if pc and pc.has_method("save_game"):
			pc.save_game()
	print("[PauseMenu] Save requested.")

func _on_save_and_quit() -> void:
	if has_node("/root/PauseController"):
		var pc = get_node("/root/PauseController")
		if pc and pc.has_method("save_and_quit"):
			pc.save_and_quit()

func _on_quit_no_save() -> void:
	if has_node("/root/PauseController"):
		var pc = get_node("/root/PauseController")
		if pc and pc.has_method("quit_now"):
			pc.quit_now()
