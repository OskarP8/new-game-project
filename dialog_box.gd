extends CanvasLayer

signal line_finished()
signal dialog_complete()
signal skipped()

@export var char_delay := 0.02
@export var sound_on_char: AudioStream = null

func show_dialog(lines: Array, speaker: String = "", entrance: String = "pop") -> void:
	_lines = lines.duplicate(true)
	_line_index = 0
	_is_showing = true
	$Panel.visible = true
	_current_speaker = speaker
	$Panel/Label.text = speaker
	_play_entrance(entrance)
	_play_next_line()

func hide_dialog() -> void:
	_is_showing = false
	_lines = []
	_line_index = 0
	$Panel.visible = false

# internals
var _lines: Array = []
var _line_index: int = 0
var _typing: bool = false
var _skip: bool = false
var _is_showing: bool = false
var _current_speaker: String = ""

# Use Label type (so label_settings works)
@onready var _text_ctrl: Label = $Panel/Text
@onready var _speaker_label: Label = $Panel/Label

func _ready() -> void:
	$Panel.visible = false

	# --- Outline + color via LabelSettings ---
	var settings := LabelSettings.new()
	settings.font_color = Color(1,1,1)         # white text
	settings.outline_size = 4                 # change to taste
	settings.outline_color = Color(0,0,0)     # black outline
	_text_ctrl.label_settings = settings
	_speaker_label.label_settings = settings

	_text_ctrl.text = ""
	set_process_unhandled_input(true)

func _play_entrance(style: String) -> void:
	$Panel.modulate = Color(1,1,1,0)
	# Panel doesn't have rect_scale property (Control uses rect_scale), use scale via rect_scale on Panel (valid)
	$Panel.scale = Vector2.ONE
	match style:
		"slide_up":
			$Panel.position += Vector2(0, 40)
			var t = get_tree().create_tween()
			t.tween_property($Panel, "position", $Panel.position - Vector2(0,40), 0.25)
			t.tween_property($Panel, "modulate:a", 1.0, 0.25)
		"slide_down":
			$Panel.position -= Vector2(0, 40)
			var t2 = get_tree().create_tween()
			t2.tween_property($Panel, "position", $Panel.position + Vector2(0,40), 0.25)
			t2.tween_property($Panel, "modulate:a", 1.0, 0.25)
		"pop":
			$Panel.scale = Vector2(0.8, 0.8)
			var t3 = get_tree().create_tween()
			t3.tween_property($Panel, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			t3.tween_property($Panel, "modulate:a", 1.0, 0.12)
		"_":
			$Panel.modulate = Color(1,1,1,1)

func _play_next_line() -> void:
	if _line_index >= _lines.size():
		emit_signal("dialog_complete")
		hide_dialog()
		return
	_text_ctrl.text = ""
	var txt := str(_lines[_line_index])
	_typing = true
	_skip = false
	_typing_task(txt)

func _typing_task(full_text: String) -> void:
	_text_ctrl.text = ""
	var length := full_text.length()
	for i in range(length):
		if _skip:
			_text_ctrl.text = full_text
			break
		_text_ctrl.text += full_text.substr(i, 1)
		if sound_on_char:
			var ps := AudioStreamPlayer2D.new()
			add_child(ps)
			ps.stream = sound_on_char
			ps.play()
			ps.call_deferred("queue_free")
		await get_tree().create_timer(char_delay).timeout
	_typing = false
	emit_signal("line_finished")
	_line_index += 1

func _unhandled_input(event: InputEvent) -> void:
	if not _is_showing:
		return
	if event.is_action_pressed("ui_accept"):  # default: Enter/Space if mapped
		if _typing:
			_skip = true
			emit_signal("skipped")
		else:
			_play_next_line()
