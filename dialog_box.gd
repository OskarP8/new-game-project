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

	# --- Outline + color via LabelSettings ---
	var settings := LabelSettings.new()
	settings.font_color = Color(1,1,1)         # white text
	settings.outline_size = 4                 # change to taste
	settings.outline_color = Color(0,0,0)     # black outline
	_text_ctrl.label_settings = settings
	_speaker_label.label_settings = settings

	# Apply fonts from exported resources (if assigned)
	if normal_font != null:
		_text_ctrl.add_theme_font_override("font", normal_font)

	if god_font != null:
		# use the god_font for the speaker label as well (choose a god_font sized for the speaker in inspector)
		_speaker_label.add_theme_font_override("font", god_font)
		# don't pass ints to add_theme_font_override; instead assign a specifically sized font resource in the inspector
	else:
		# if god_font not set, make speaker name slightly larger by a mild scale fallback
		_speaker_label.scale = _text_ctrl.scale * 1.08

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

# -------------------------
# Replace your existing _play_next_line with this:
func _play_next_line() -> void:
	if _line_index >= _lines.size():
		emit_signal("dialog_complete")
		hide_dialog()
		return

	# clear any previous char container/tweens
	_clear_char_container()
	_text_ctrl.visible = true
	_text_ctrl.text = ""

	var entry = _lines[_line_index]
	var txt := ""
	var speaker_role := ""

	# support both string lines and dict lines (your Taara uses dicts)
	if typeof(entry) == TYPE_DICTIONARY:
		txt = str(entry.get("text", ""))
		speaker_role = str(entry.get("speaker_role", ""))
		# update speaker label if supplied
		var spn = entry.get("speaker_name", null)
		if spn != null and spn != "":
			_speaker_label.text = str(spn)
			_current_speaker = str(spn)
	else:
		txt = str(entry)

	_typing = true
	_skip = false

	# if this line is spoken by "god", use the wave-per-letter animation
	if speaker_role.to_lower() == "god":
		_text_ctrl.visible = false
		_play_wave_text(txt)
	else:
		_text_ctrl.visible = true
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

# -------------------------
# NEW: Clear any existing per-letter nodes / tweens
# NEW: Clear any existing per-letter nodes / stop running waves
func _clear_char_container() -> void:
	# Stop per-letter wave loops gracefully
	if has_meta("_wave_running") and get_meta("_wave_running") == true:
		set_meta("_wave_running", false)
	# remove container if present
	if $Panel.has_node("CharContainer"):
		var cc = $Panel.get_node("CharContainer")
		cc.queue_free()

# -------------------------
# NEW: create per-letter labels and start wave animation
func _play_wave_text(full_text: String) -> void:
	# clear old container / stop old coroutines
	_clear_char_container()

	# parse into ordered segments and pause durations
	var segments := []   # each element: { "text":String, "pause": float (0 if none) }
	var i := 0
	while i < full_text.length():
		# if we encounter a pause tag like <pause=1.0>
		if full_text.substr(i, 7) == "<pause=":
			var end_idx := full_text.find(">", i)
			if end_idx != -1:
				var tag := full_text.substr(i + 7, end_idx - (i + 7))
				var pause_val := float(tag)
				# attach pause to previous segment if any, otherwise create empty segment
				if segments.size() == 0:
					segments.append({"text":"", "pause": pause_val})
				else:
					segments[segments.size()-1]["pause"] = pause_val
				i = end_idx + 1
				continue
		# otherwise collect characters until next pause tag or end
		var start := i
		var j := full_text.find("<pause=", i)
		if j == -1:
			j = full_text.length()
		var seg_text := full_text.substr(start, j - start)
		segments.append({"text": seg_text, "pause": 0.0})
		i = j

	# Create container (Control) where the normal label is
	var container := Control.new()
	container.name = "CharContainer"
	container.position = _text_ctrl.position
	container.size = _text_ctrl.size
	$Panel.add_child(container)

	# copy LabelSettings (best-effort)
	# copy LabelSettings (best-effort). Explicitly type for the parser.
	var base_settings: LabelSettings = null
	if _text_ctrl.label_settings != null:
		base_settings = _text_ctrl.label_settings.duplicate(true) as LabelSettings
	# wave params
	var amplitude := 2.2
	var base_period := 1.8
	var omega := TAU / base_period
	var phase_step := 0.28
	var stagger := 0.042
	var letter_fade_in := 0.06

	# layout params - measure char advance using a temporary Label for the chosen font
	var temp := Label.new()
	if god_font != null:
		temp.add_theme_font_override("font", god_font)
	else:
		# try to copy the font used by the main text via theme (safe for Label)
		var theme_font := _text_ctrl.get_theme_font("font")
		if theme_font != null:
			temp.add_theme_font_override("font", theme_font)
		# else leave temp with default font (measurement will be a conservative fallback)
	temp.text = "M"  # sample to measure approximate char width
	container.add_child(temp)
	var sample_w := int(max(6, temp.get_minimum_size().x))
	temp.queue_free()

	# Build labels incrementally per segment so we can pause
	var x_cursor := 0
	set_meta("_wave_running", true)
	var labels := []

	for seg_idx in range(segments.size()):
		var seg: Dictionary = segments[seg_idx] as Dictionary
		var seg_text := str(seg.get("text", ""))
		# create labels for chars in this segment
		for ch in seg_text.split(""):
			# create a char label
			var label := Label.new()
			label.text = ch if ch != "" else " "  # keep spaces visible for layout
			# apply outline settings copy
			if base_settings != null:
				label.label_settings = base_settings.duplicate(true)
			# apply god font / color
			if god_font != null:
				label.add_theme_font_override("font", god_font)
			# preserve outline color from base if present
			label.label_settings.font_color = Color(1.00, 0.95, 0.60)   # bright warm yellow
			# place
			label.position = Vector2(x_cursor, 0)
			# initial alpha 0
			label.modulate = Color(label.modulate.r, label.modulate.g, label.modulate.b, 0.0)
			container.add_child(label)
			labels.append(label)
			x_cursor += sample_w
		# if this segment had a pause time, wait before continuing (so the effect feels like separate sentence-gap)
		if seg.has("pause") and float(seg.get("pause", 0.0)) > 0.0:
			# start per-letter waves for letters created so far (so they animate while we wait)
			for idx in range(labels.size()):
				_start_letter_wave(labels[idx], idx, labels.size(), amplitude, omega, phase_step, stagger, letter_fade_in)
			# wait the pause duration (but keep wave running)
			await get_tree().create_timer(float(seg["pause"])).timeout
			# after pause, continue building next segment (letters already animate)
	# If no pauses existed, start waves now
	if labels.size() > 0:
		for idx in range(labels.size()):
			_start_letter_wave(labels[idx], idx, labels.size(), amplitude, omega, phase_step, stagger, letter_fade_in)

	# done: mark typing finished so dialog continues
	_typing = false
	emit_signal("line_finished")
	_line_index += 1

func _start_letter_wave(label: Label, index: int, total: int, amplitude: float, omega: float, phase_step: float, stagger: float, fade_in: float) -> void:
	var phase_offset := float(index) * phase_step
	var base_y = label.position.y

	# staggered start
	var wait := stagger * float(index)
	var waited := 0.0
	while waited < wait:
		if not (has_meta("_wave_running") and get_meta("_wave_running") == true):
			return
		await get_tree().process_frame
		waited += get_process_delta_time()

	# fade in
	var ft := 0.0
	while ft < fade_in:
		if not (has_meta("_wave_running") and get_meta("_wave_running") == true):
			return
		var a = clamp(ft / fade_in, 0.0, 1.0)
		label.modulate = Color(label.modulate.r, label.modulate.g, label.modulate.b, a)
		await get_tree().process_frame
		ft += get_process_delta_time()

	# smooth continuous sine motion (delta-based time accumulator)
	var time_acc := 0.0
	while true:
		if not (has_meta("_wave_running") and get_meta("_wave_running") == true):
			return

		var dt := get_process_delta_time()
		time_acc += dt

		var y_off := amplitude * sin(omega * time_acc + phase_offset)

		var rp = label.position
		rp.y = base_y + y_off
		label.position = rp

		await get_tree().process_frame

# -------------------------
# Optional: call this to instantly show full god line and stop tweens (e.g. when user presses skip)
# Optional: call this to instantly show full god line and stop waves (e.g. when user presses skip)
func _skip_wave_and_show_full() -> void:
	# stop waves and remove char container
	_clear_char_container()
	_text_ctrl.visible = true
	# show full text of current line (safe)
	if _line_index < _lines.size():
		var entry = _lines[_line_index]
		var text = entry if typeof(entry) != TYPE_DICTIONARY else entry.get("text", "")
		_text_ctrl.text = str(text)
	else:
		_text_ctrl.text = ""
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

# helper: apply a simple style by changing label colors / small tweens (lightweight)
func _apply_style(style_id: String) -> void:
	# Kill previous tweens we created (if any)
	for t in _active_tweens:
		if t != null:
			# SceneTreeTween exposes kill(). Safe to call even if already finished.
			t.kill()
	_active_tweens.clear()

	# reset panel position so each style starts from a consistent baseline
	$Panel.position = _panel_base_pos

	# default visual resets
	_text_ctrl.modulate = Color(1,1,1,1)
	_speaker_label.modulate = Color(1,1,1,1)

	match style_id:
		"god_glow":
			# yellow-ish bigger text, slight vertical float
			_text_ctrl.modulate = Color(1.0, 0.95, 0.6, 1)
			_speaker_label.modulate = Color(1.0, 0.95, 0.6, 1)

			# float tween (looping)
			var tw = get_tree().create_tween()
			_active_tweens.append(tw)
			tw.set_loops()  # ← pane see Tweenile, mitte tween_property ahelasse

			tw.tween_property($Panel, "position:y", _panel_base_pos.y - 6, 1.0)\
				.set_trans(Tween.TRANS_SINE)\
				.set_ease(Tween.EASE_IN_OUT)

			tw.tween_property($Panel, "position:y", _panel_base_pos.y, 1.0)\
				.set_trans(Tween.TRANS_SINE)\
				.set_ease(Tween.EASE_IN_OUT)

		"boss_shake":
			_text_ctrl.modulate = Color(0.9, 0.5, 0.5, 1)
			_speaker_label.modulate = Color(0.9, 0.5, 0.5, 1)

			# small shake sequence (non-looping quick shake then reset)
			var tw2 = get_tree().create_tween()
			_active_tweens.append(tw2)
			# move left quickly a few times (using loops) then return
			tw2.tween_property($Panel, "position:x", _panel_base_pos.x - 3, 0.05).set_trans(Tween.TRANS_LINEAR).set_loops(6, true)
			tw2.tween_property($Panel, "position:x", _panel_base_pos.x, 0.05)

		"player_plain":
			_text_ctrl.modulate = Color(1,1,1,1)
			_speaker_label.modulate = Color(1,1,1,1)
			$Panel.position = _panel_base_pos

		"villager_plain", "narrator_plain":
			_text_ctrl.modulate = Color(0.95,0.95,0.95,1)
			_speaker_label.modulate = Color(0.95,0.95,0.95,1)

		_:
			_text_ctrl.modulate = Color(1,1,1,1)
			_speaker_label.modulate = Color(1,1,1,1)

func _unhandled_input(event: InputEvent) -> void:
	if not _is_showing:
		return
	if event.is_action_pressed("ui_accept"):  # default: Enter/Space if mapped
		if _typing:
			_skip = true
			emit_signal("skipped")
		else:
			_play_next_line()
