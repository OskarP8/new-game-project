extends CanvasLayer

signal line_finished()        # emitted when a line fully typed and not skipped
signal dialog_complete()      # emitted when whole dialog sequence is done
signal skipped()              # emitted when user skipped typing

@export var char_delay := 0.02    # seconds per character (smaller => faster)
@export var sound_on_char: AudioStream = null   # optional sfx for each char

# entrance: "slide_up", "slide_down", "pop", "none"
func show_dialog(lines: Array, speaker: String = "", entrance: String = "pop") -> void:
	# lines = array of strings
	# store and start
	_lines = lines.duplicate(true)
	_line_index = 0
	_is_showing = true
	$Window.visible = true
	_current_speaker = speaker
	$Speaker.text = speaker
	# play entrance
	_play_entrance(entrance)
	# start first line
	_play_next_line()

func hide_dialog() -> void:
	_is_showing = false
	_lines = []
	_line_index = 0
	$Window.visible = false

# internals
var _lines: Array = []
var _line_index: int = 0
var _typing: bool = false
var _skip: bool = false
var _is_showing: bool = false
var _current_speaker: String = ""

@onready var _text_ctrl: RichTextLabel = $Window/Text
@onready var _speaker_label: Label = $Window/Speaker

func _ready() -> void:
	$Window.visible = false
	_text_ctrl.bbcode_enabled = false
	_text_ctrl.clear()
	# input processing enabled so _unhandled_input catches keys
	set_process_unhandled_input(true)

func _play_entrance(style: String) -> void:
	$Window.modulate = Color(1,1,1,0)
	$Window.rect_scale = Vector2.ONE
	match style:
		"slide_up":
			$Window.rect_position += Vector2(0, 40)
			get_tree().create_tween().tween_property($Window, "rect_position", $Window.rect_position - Vector2(0,40), 0.25).tween_property($Window, "modulate:a", 1.0, 0.25)
		"slide_down":
			$Window.rect_position -= Vector2(0, 40)
			get_tree().create_tween().tween_property($Window, "rect_position", $Window.rect_position + Vector2(0,40), 0.25).tween_property($Window, "modulate:a", 1.0, 0.25)
		"pop":
			$Window.rect_scale = Vector2(0.8, 0.8)
			get_tree().create_tween().tween_property($Window, "rect_scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT).tween_property($Window, "modulate:a", 1.0, 0.12)
		"_":
			$Window.modulate = Color(1,1,1,1)

func _play_next_line() -> void:
	if _line_index >= _lines.size():
		emit_signal("dialog_complete")
		hide_dialog()
		return
	_text_ctrl.clear()
	var txt := str(_lines[_line_index])
	# speaker label already set in show_dialog; keep it unless you plan to change per-line
	_typing = true
	_skip = false
	# start the typing coroutine-style (uses await)
	_typing_task(txt)

func _typing_task(full_text: String) -> void:
	_text_ctrl.clear()
	var length := full_text.length()
	for i in range(length):
		if _skip:
			# finish instantly
			_text_ctrl.clear()
			_text_ctrl.append_text(full_text)
			break
		# append next character
		_text_ctrl.append_text(full_text.substr(i, 1))
		# optional per-char sound
		if sound_on_char:
			var ps := AudioStreamPlayer2D.new()
			add_child(ps)
			ps.stream = sound_on_char
			ps.play()
			# queue free soon (cheap)
			ps.call_deferred("queue_free")
		# wait a short time (Godot 4 await)
		await get_tree().create_timer(char_delay).timeout
	# finished typing
	_typing = false
	emit_signal("line_finished")
	_line_index += 1

func _unhandled_input(event: InputEvent) -> void:
	if not _is_showing:
		return
	# Space or Enter => advance or skip
	if event.is_action_pressed("ui_accept"):
		if _typing:
			# skip typing, show full line immediately
			_skip = true
			emit_signal("skipped")
		else:
			# if not typing, advance to next line
			_play_next_line()
