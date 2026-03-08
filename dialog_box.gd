extends CanvasLayer

signal line_finished()
signal dialog_complete()
signal skipped()

@export var char_delay := 0.02
@export var sound_on_char: AudioStream = null
# Font resources (set these in the inspector)
@export var god_font: Font    # assign a larger/bolder font resource in the inspector for Taara/god lines
@export var normal_font: Font # optional: assign your normal dialog font (fallback)
# track tweens we create so we can kill them cleanly
var _active_tweens: Array = []

# remember panel base position so tweens can be relative and we can reset
@onready var _panel_base_pos: Vector2 = $Panel.position

func show_dialog(lines: Array, speaker: String = "", entrance: String = "pop") -> void:
	# Accepts Array of Strings OR Array of Dictionaries:
	# Each Dictionary can contain:
	#   "text": String (required)
	#   "speaker_name": String (optional)
	#   "speaker_role": String (optional) e.g. "god","player","villager","boss"
	#   "style": String (optional explicit style override)
	_lines = []
	for item in lines:
		if typeof(item) == TYPE_STRING:
			_lines.append({"text": str(item), "speaker_name": speaker, "speaker_role": "narrator"})
		elif typeof(item) == TYPE_DICTIONARY:
			var entry = item.duplicate(true)
			# ensure required key
			if not entry.has("text"):
				entry["text"] = ""
			# fallback for speaker_name/role
			if not entry.has("speaker_name"):
				entry["speaker_name"] = speaker
			if not entry.has("speaker_role"):
				entry["speaker_role"] = "narrator"
			_lines.append(entry)
		else:
			# unknown — coerce to string
			_lines.append({"text": str(item), "speaker_name": speaker, "speaker_role": "narrator"})

	_line_index = 0
	_is_showing = true
	$Panel.visible = true
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

	_text_ctrl.visible = true
	_text_ctrl.text = ""

	var entry = _lines[_line_index]
	var txt := ""
	var speaker_role := ""

	if typeof(entry) == TYPE_DICTIONARY:
		txt = str(entry.get("text", ""))
		speaker_role = str(entry.get("speaker_role", ""))

		var spn = entry.get("speaker_name", "")
		_speaker_label.text = spn
	else:
		txt = str(entry)

	# 👉 apply style based on role
	var style_id := _style_for_role(speaker_role)
	_apply_style(style_id)

	_typing = true
	_skip = false
	_typing_task(txt)

# -------------------------
# Replace your existing _typing_task with this (unchanged except for small skip handling):
func _typing_task(full_text: String) -> void:
	_text_ctrl.text = ""
	var i := 0

	while i < full_text.length():
		if _skip:
			var clean := full_text
			# remove all <pause=X> tags before showing
			while clean.find("<pause=") != -1:
				var s := clean.find("<pause=")
				var e := clean.find(">", s)
				if e == -1:
					break
				clean = clean.substr(0, s) + clean.substr(e + 1, clean.length() - (e + 1))
			_text_ctrl.text = clean
			break
		# Detect pause tag (existing behaviour)
		if full_text.substr(i, 7) == "<pause=":
			var end_idx := full_text.find(">", i)
			if end_idx != -1:
				var tag := full_text.substr(i + 7, end_idx - (i + 7))
				var pause_time := float(tag)
				await get_tree().create_timer(pause_time).timeout
				i = end_idx + 1
				continue

		_text_ctrl.text += full_text.substr(i, 1)

		if sound_on_char:
			var ps := AudioStreamPlayer2D.new()
			add_child(ps)
			ps.stream = sound_on_char
			ps.play()
			ps.call_deferred("queue_free")

		await get_tree().create_timer(char_delay).timeout
		i += 1

	_typing = false
	emit_signal("line_finished")
	_line_index += 1

# helper: map role -> style id (strings your _apply_style understands)
func _style_for_role(role: String) -> String:
	role = role.to_lower()
	match role:
		"god", "taara", "divine":
			return "god_glow"
		"player", "you":
			return "player_plain"
		"villager", "npc":
			return "villager_plain"
		"boss", "enemy":
			return "boss_shake"
		_:
			return "narrator_plain"

func _apply_style(style_id: String) -> void:
	$Panel.position = _panel_base_pos

	var text_color := Color(1,1,1,1)

	match style_id:
		"god_glow":
			text_color = Color(1.0, 0.95, 0.6, 1)
		"boss_shake":
			text_color = Color(0.9, 0.5, 0.5, 1)
		"villager_plain", "narrator_plain":
			text_color = Color(0.95, 0.95, 0.95, 1)
		"player_plain":
			text_color = Color(1,1,1,1)
		_:
			text_color = Color(1,1,1,1)

	_text_ctrl.modulate = text_color
	_speaker_label.modulate = text_color

	# Fonts: pick the proper font resource (font resource must already be sized correctly)
	if style_id == "god_glow" and god_font != null:
		_text_ctrl.add_theme_font_override("font", god_font)
		_speaker_label.add_theme_font_override("font", god_font)
	else:
		if normal_font != null:
			_text_ctrl.add_theme_font_override("font", normal_font)
			_speaker_label.add_theme_font_override("font", normal_font)

	# --- speaker name horizontal alignment ---
	# Use numeric values to avoid depending on engine enum constants:
	# 0 = LEFT, 1 = CENTER, 2 = RIGHT
	if style_id == "player_plain":
		# player text: speaker name aligned to left
		_speaker_label.set("horizontal_alignment", 0)
	else:
		# other characters: speaker name aligned to right
		_speaker_label.set("horizontal_alignment", 2)

func _unhandled_input(event: InputEvent) -> void:
	if not _is_showing:
		return
	if event.is_action_pressed("ui_accept"):  # default: Enter/Space if mapped
		if _typing:
			_skip = true
			emit_signal("skipped")
		else:
			_play_next_line()
