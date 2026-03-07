extends Control

# Node paths according to your screenshot:
@onready var title_lbl: Label = get_node_or_null("Title")
@onready var checked_tex: TextureRect = get_node_or_null("RightCol/ObjectiveRow/CheckedBox")
@onready var unchecked_tex: TextureRect = get_node_or_null("RightCol/ObjectiveRow/UncheckedBox")
@onready var objective_lbl: Label = get_node_or_null("RightCol/ObjectiveRow/Objective")
@onready var progress_lbl: Label = get_node_or_null("RightCol/ObjectiveRow/Progress")

# Called by HUD once after instancing so row uses HUD fonts
func set_fonts(title_font: Font, obj_font: Font, prog_font: Font) -> void:
	if title_lbl != null and title_font != null:
		title_lbl.add_theme_font_override("font", title_font)
	if objective_lbl != null and obj_font != null:
		objective_lbl.add_theme_font_override("font", obj_font)
	if progress_lbl != null and prog_font != null:
		progress_lbl.add_theme_font_override("font", prog_font)

func set_data(r: Dictionary) -> void:
	if r == null:
		return

	# --- Title ---
	if title_lbl != null:
		var new_title := str(r.get("title", ""))
		title_lbl.text = new_title
		# ensure visible and on-top
		title_lbl.visible = true
		# explicitly place at top-left of the quest row root (adjust if you want other offsets)
		title_lbl.position = Vector2(0, 0)
		# force a redraw/update
		title_lbl.queue_redraw()
		# debug print to confirm the node and value after assignment
		print("[QuestRow] title_lbl at path:", title_lbl.get_path(), " current text:", title_lbl.text)
	else:
		print("[QuestRow] WARNING: title_lbl is null")

	# --- Objective ---
	var objective_text := str(r.get("objective_text", r.get("description_preview", "")))
	if objective_lbl != null:
		objective_lbl.text = objective_text
		objective_lbl.visible = true
		# place under the title if inspector anchors do not persist
		# compute a simple offset using title height
		var title_h := 0.0
		if title_lbl:
			title_h = float(title_lbl.get_minimum_size().y)
		# small padding
		objective_lbl.position = Vector2(0, title_h + 4)
		objective_lbl.queue_redraw()
	else:
		print("[QuestRow] WARNING: objective_lbl is null")

	# --- Progress ---
	if progress_lbl != null:
		progress_lbl.text = "(%d/%d)" % [int(r.get("progress", 0)), int(r.get("count", 1))]
		progress_lbl.visible = true
		progress_lbl.queue_redraw()

	# --- Checkbox textures (use your two TextureRects) ---
	var quest_done := bool(r.get("completed", false))
	_set_checkbox_visible(quest_done)

	# --- Visual states (keep your existing behavior) ---
	_update_visuals(r)

	# Final debug: list children so we can see if another node might overlap/duplicate
	print("[QuestRow] children:", get_path(), " -> ", get_child_count(), " names:")
	for i in range(get_child_count()):
		var n := get_child(i)
		print("   ", i, n.name, " type:", typeof(n))

func _set_checkbox_visible(checked: bool) -> void:
	if checked:
		if checked_tex: checked_tex.visible = true
		if unchecked_tex: unchecked_tex.visible = false
	else:
		if checked_tex: checked_tex.visible = false
		if unchecked_tex: unchecked_tex.visible = true

func _update_visuals(r: Dictionary) -> void:
	var progress := int(r.get("progress", 0))
	var count := int(r.get("count", 1))
	var objective_done := progress >= count
	var quest_done := bool(r.get("completed", false))

	# color presets
	var normal := Color(1,1,1,1)
	var partial := Color(0.85,0.85,0.85,1)
	var full := Color(0.6,0.6,0.6,1)

	# Title: darken if whole quest done
	if title_lbl:
		if quest_done:
			title_lbl.modulate = full
		else:
			title_lbl.modulate = normal

	# Objective and progress: partial when objective done, full when quest done
	if objective_lbl:
		if quest_done:
			objective_lbl.modulate = full
		elif objective_done:
			objective_lbl.modulate = partial
		else:
			objective_lbl.modulate = normal

	if progress_lbl:
		if quest_done:
			progress_lbl.modulate = full
		elif objective_done:
			progress_lbl.modulate = partial
		else:
			progress_lbl.modulate = normal

	# Ensure checkbox textures also reflect modulate
	if checked_tex:
		if quest_done:
			checked_tex.modulate = full
		elif objective_done:
			checked_tex.modulate = partial
		else:
			checked_tex.modulate = normal

	if unchecked_tex:
		if quest_done:
			unchecked_tex.modulate = full
		elif objective_done:
			unchecked_tex.modulate = partial
		else:
			unchecked_tex.modulate = normal
