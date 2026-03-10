# TutorialManager.gd
extends Node

var _shown_first_chest_hint: bool = false
@export var hint_delay_seconds: float = 0.8
@export var hint_lines: Array = [
	"Press I to open your inventory.",
	"You can equip items or inspect them there."
]

# How many times to retry finding DialogBox (when scene builds slowly)
const MAX_DLG_RETRIES := 8
const RETRY_DELAY := 0.25

func _ready() -> void:
	print("[TutorialManager] ready (autoload)")

func chest_opened() -> void:
	print("[TutorialManager] chest_opened() called")
	if _shown_first_chest_hint:
		print("[TutorialManager] already shown, ignoring")
		return
	_shown_first_chest_hint = true

	# one-shot timer to delay showing the hint
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = hint_delay_seconds
	add_child(t)
	t.connect("timeout", Callable(self, "_on_hint_timer_timeout"))
	t.start()
	print("[TutorialManager] scheduled hint in", hint_delay_seconds, "s")

func _on_hint_timer_timeout() -> void:
	print("[TutorialManager] hint timer timeout -> attempting to show hint")
	_try_show_hint_with_retries(0)

func _try_show_hint_with_retries(retry_count: int) -> void:
	var dlg := _find_dialog_box()
	if dlg:
		print("[TutorialManager] DialogBox found -> showing hint")
		_show_hint_with_dialog(dlg)
		return

	# not found -> retry a few times (non-async, timer-based)
	if retry_count >= MAX_DLG_RETRIES:
		push_warning("[TutorialManager] DialogBox not found after retries; giving up.")
		return

	var t := Timer.new()
	t.one_shot = true
	t.wait_time = RETRY_DELAY
	add_child(t)
	# connect with a lambda-like callable that passes retry_count+1
	t.connect("timeout", Callable(self, "_on_retry_timeout"), (retry_count + 1))
	t.start()
	print("[TutorialManager] DialogBox missing, will retry in", RETRY_DELAY, "s (try", retry_count + 1, ")")

func _on_retry_timeout(next_retry: int) -> void:
	_try_show_hint_with_retries(next_retry)

func _find_dialog_box() -> Node:
	var dlg = null
	if get_tree().current_scene:
		dlg = get_tree().current_scene.get_node_or_null("DialogBox")
	if dlg == null:
		dlg = get_tree().root.find_node("DialogBox", true, false)
	return dlg

func _show_hint_with_dialog(dlg: Node) -> void:
	if dlg == null:
		push_warning("[TutorialManager] _show_hint_with_dialog called with null dlg")
		return

	# convert simple strings into dialog dicts
	var dict_lines := []
	for s in hint_lines:
		dict_lines.append({
			"text": str(s),
			"speaker_name": "",
			"speaker_role": "narrator"
		})

	# try to set pause_mode on a CanvasLayer ancestor so it processes while paused
	var p := dlg
	while p:
		if p is CanvasLayer:
			if p.has_method("set"):
				p.set("pause_mode", 2) # PAUSE_MODE_PROCESS
			break
		p = p.get_parent()

	# show dialog
	if dlg.has_method("show_dialog"):
		dlg.show_dialog(dict_lines, "Narrator", "pop")
		print("[TutorialManager] show_dialog called with lines:", dict_lines)
	else:
		push_warning("[TutorialManager] DialogBox has no show_dialog method. Lines: " + str(dict_lines))
