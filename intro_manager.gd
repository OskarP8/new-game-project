# IntroManager.gd  (Godot 4)
extends Node

@export var intro_lines: Array = [
	"For weeks, the Iron Men have been terrorising the village.",
	"They march without rest, and their metal footsteps echo through the night.",
	"The elders spoke your name.",
	"Not because you were the strongest...<pause=0.5> but because you were the only villager in the village.",
	"You have been chosen to seek the god Taara beneath the great oak.",
	"Follow the road until you reach the big tree."
]

@export var delay_before_show: float = 2.0   # seconds to wait before showing intro
@export var dlg_search_tries: int = 60       # how many short retries to find DialogBox
@export var dlg_search_interval: float = 0.05

var _shown := false

func _ready() -> void:
	# defer start so the scene has a chance to finish construction
	call_deferred("_try_show_intro")

func _try_show_intro() -> void:
	if _shown:
		return
	_shown = true

	# wait a little to let the scene create UI nodes
	# (this is simple non-blocking wait using a timer + await)
	await get_tree().create_timer(0.05).timeout

	# find DialogBox in current scene or root
	var dlg := get_tree().current_scene.get_node_or_null("DialogBox")
	if dlg == null:
		dlg = get_tree().root.find_node("DialogBox", true, false)

	# retry loop (short polling) in case DialogBox is created a bit later
	var tries := 0
	while dlg == null and tries < dlg_search_tries:
		await get_tree().create_timer(dlg_search_interval).timeout
		dlg = get_tree().current_scene.get_node_or_null("DialogBox")
		if dlg == null:
			dlg = get_tree().root.find_node("DialogBox", true, false)
		tries += 1

	if dlg == null:
		push_warning("IntroManager: DialogBox not found; skipping intro.")
		return

	# optional: ensure dialog UI will process while tree.paused (if you ever pause)
	var p := dlg
	while p:
		if p is CanvasLayer:
			if p.has_method("set"):
				p.set("pause_mode", 2) # PAUSE_MODE_PROCESS
			break
		p = p.get_parent()

	# wait the requested delay before showing lines
	if delay_before_show > 0.0:
		await get_tree().create_timer(delay_before_show).timeout

	# show dialog — many DialogBoxes accept Array<String>. If yours needs dictionaries, adapt.
	# The third arg ("pop") is style in your DialogBox API examples; change if needed.
	dlg.show_dialog(intro_lines, "", "pop")

	# wait until dialog completes if it exposes dialog_complete signal (your DialogBox does)
	# If your DialogBox doesn't emit this signal, remove the await and just return.
	if dlg.has_signal("dialog_complete"):
		await dlg.dialog_complete
