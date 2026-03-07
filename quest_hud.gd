extends CanvasLayer

@export var max_visible: int = 6
@export var hud_title_font: Font      # assign FontFile/FontVariation in inspector
@export var hud_objective_font: Font
@export var hud_progress_font: Font
@export var row_scene: PackedScene    # assign your QuestRow.tscn here

@onready var vbox: VBoxContainer = get_node_or_null("Panel/VBoxContainer")
@export var row_height: int = 48   # tune to your pixel font + outline (increase if overlap)
var _rows: Dictionary = {}

# <-- new: exposed offset so you can tweak the gap in the Inspector
@export var row_rightcol_offset := Vector2(0, 12)  # x = right offset, y = down offset (increased gap)

func _ready() -> void:
	if vbox == null:
		print("[QuestHUD] Panel/VBoxContainer not found.")
	if typeof(QuestManager) != TYPE_NIL:
		_connect_to_qm()
	else:
		await get_tree().create_timer(0.2).timeout
		if typeof(QuestManager) != TYPE_NIL:
			_connect_to_qm()
	_refresh_ui()

func _connect_to_qm() -> void:
	if typeof(QuestManager) == TYPE_NIL:
		print("[QuestHUD] QuestManager autoload missing.")
		return
	if not QuestManager.is_connected("quest_updated", Callable(self, "_on_quest_updated")):
		QuestManager.connect("quest_updated", Callable(self, "_on_quest_updated"))
	if not QuestManager.is_connected("quests_registered", Callable(self, "_update_all_from_qm")):
		QuestManager.connect("quests_registered", Callable(self, "_update_all_from_qm"))
	_update_all_from_qm()

func _make_row_from_quest(q) -> Dictionary:
	var row: Dictionary = {}
	if "title" in q and str(q.title).strip_edges() != "":
		row.title = q.title
	else:
		row.title = q.id
	var obj = q.objective if q.objective != null else {}
	row.type = str(obj.get("type", "")).to_lower()
	row.target = str(obj.get("target", ""))
	row.count = int(obj.get("count", 1))
	if typeof(QuestManager) != TYPE_NIL and QuestManager.has_method("get_kill_progress"):
		row.progress = int(QuestManager.get_kill_progress(q.id))
	else:
		row.progress = 0
	row.completed = (q.state == "completed")
	# description preview as fallback
	var desc_preview := ""
	if "description" in q:
		if typeof(q.description) == TYPE_ARRAY and q.description.size() > 0:
			desc_preview = str(q.description[0])
		else:
			var s := str(q.description)
			var parts := s.split("\n\n")
			if parts.size() > 0:
				desc_preview = parts[0].strip_edges()
	row.description_preview = desc_preview
	row._raw_objective = obj
	return row

func _on_quest_updated(qid: String, new_state: String) -> void:
	if typeof(new_state) == TYPE_STRING and new_state.begins_with("progress:"):
		var rest: String = new_state.substr(9)
		var parts: Array = rest.split("/")
		var cur: int = 0
		if parts.size() >= 1:
			cur = int(parts[0])
		if _rows.has(qid):
			_rows[qid].progress = cur
			_refresh_ui()
			return

	if new_state == "active":
		var q = QuestManager.get_quest(qid)
		if q:
			_rows[qid] = _make_row_from_quest(q)
			_rows[qid].completed = false
	elif new_state == "completed":
		var q = QuestManager.get_quest(qid)
		if q:
			_rows[qid] = _make_row_from_quest(q)
			_rows[qid].progress = int(_rows[qid].count)
			_rows[qid].completed = true
	elif new_state == "claimed" or new_state == "failed":
		if _rows.has(qid):
			_rows.erase(qid)

	_refresh_ui()

# Build display text for the objective; HUD puts objective_text into dict for rows
func _build_objective_text(r: Dictionary) -> String:
	var obj = r.get("_raw_objective", {})
	var ttype := str(obj.get("type", "")).to_lower()
	var target := str(obj.get("target", "")).strip_edges()
	var count := int(obj.get("count", 1))

	if ttype == "kill":
		var tn := ""
		if target != "":
			tn = target.capitalize()
		else:
			tn = "Target"
		var plural := ""
		if count > 1:
			plural = "s"
		return "Kill %d %s%s" % [count, tn, plural]
	elif ttype == "collect":
		var tn2 := ""
		if target != "":
			tn2 = target.capitalize()
		else:
			tn2 = "Item"
		var plural2 := ""
		if count > 1:
			plural2 = "s"
		return "Collect %d %s%s" % [count, tn2, plural2]
	elif ttype == "visit":
		var tn3 := ""
		if target != "":
			tn3 = target.capitalize()
		else:
			tn3 = "Place"
		return "Visit: %s" % tn3

	var dp := str(r.get("description_preview", "")).strip_edges()
	if dp != "":
		return dp
	return "Objective: " + str(r.get("title", "Unknown Quest"))

# -------------------------
# Render UI: instantiate the QuestRow scene and call its API.
func _update_all_from_qm() -> void:
	# Rebuild the _rows map from QuestManager but only take active quests.
	_rows.clear()
	if typeof(QuestManager) == TYPE_NIL:
		return
	for id in QuestManager.quests.keys():
		var q = QuestManager.get_quest(id)
		if q == null:
			continue
		if not ("state" in q):
			continue
		# DEBUG: log states so you can track why a quest appears
		# (you can remove or lower this after you verify behavior)
		print("[QuestHUD] scan quest:", id, "state:", str(q.state))
		if q.state == "active":
			_rows[id] = _make_row_from_quest(q)
	# refresh after rebuild
	_refresh_ui()


func _refresh_ui() -> void:
	if vbox == null:
		return

	# clear previous children
	for child in vbox.get_children():
		vbox.remove_child(child)
		child.queue_free()

	# hide HUD if nothing to show
	if _rows.size() == 0:
		visible = false
		return
	else:
		visible = true

	var ids: Array = _rows.keys()
	ids.sort_custom(Callable(self, "_sort_by_title"))

	var shown: int = 0
	for id in ids:
		if shown >= max_visible:
			break
		var r: Dictionary = _rows[id]

		# prepare data copy and objective_text
		var copy := {}
		for k in r.keys():
			copy[k] = r[k]
		copy["objective_text"] = _build_objective_text(r)

		if row_scene == null:
			# fallback minimal: two labels
			var title_lbl := _make_label_with_outline(r.title)
			if hud_title_font != null:
				title_lbl.add_theme_font_override("font", hud_title_font)
			vbox.add_child(title_lbl)

			var obj_lbl := _make_label_with_outline(copy["objective_text"])
			if hud_objective_font != null:
				obj_lbl.add_theme_font_override("font", hud_objective_font)
			vbox.add_child(obj_lbl)
		else:
			# instantiate row (DO NOT add it twice)
			var inst = row_scene.instantiate()
			if inst == null:
				print("[QuestHUD] ERROR: row_scene.instantiate() returned null for", id)
			else:
				# Add once to the vbox now so its onready vars initialize.
				# (we only add *one* time here)
				vbox.add_child(inst)

				# Debug print to help trace why a quest appears and whether instance API exists
				print("[QuestHUD] instanced QuestRow for:", id, " set_data:", inst.has_method("set_data"), " set_fonts:", inst.has_method("set_fonts"))

				# Preferred API route: call instance methods if available
				if inst.has_method("set_fonts"):
					inst.set_fonts(hud_title_font, hud_objective_font, hud_progress_font)
				if inst.has_method("set_data"):
					inst.set_data(copy)
					# enforce fixed height so vbox stacking doesn't shift slightly
					if inst is Control:
						# set a minimum height so different text sizes don't move later rows
						inst.custom_minimum_size = Vector2(inst.custom_minimum_size.x, row_height)
						# ensure the Control recalculates layout/minimum
						inst.queue_redraw()
						# Optionally: if your row contains internal containers, you can also set their rect_min_size:
						# var rightcol = inst.get_node_or_null("RightCol")
						# if rightcol: rightcol.custom_minimum_size = Vector2(rightcol.custom_minimum_size.x, row_height - 16)
				else:
					# fallback direct node writes (keep as before)
					var title_node : Label = inst.get_node_or_null("Title")
					var rightcol : Control = inst.get_node_or_null("RightCol")
					var objective_node : Label = inst.get_node_or_null("RightCol/ObjectiveRow/Objective")
					var progress_node : Label = inst.get_node_or_null("RightCol/ObjectiveRow/Progress")
					var checked_tex : TextureRect = inst.get_node_or_null("RightCol/ObjectiveRow/CheckedBox")
					var unchecked_tex : TextureRect = inst.get_node_or_null("RightCol/ObjectiveRow/UncheckedBox")

					if title_node:
						title_node.text = str(copy.get("title", ""))
						if hud_title_font != null:
							title_node.add_theme_font_override("font", hud_title_font)

					if objective_node:
						objective_node.text = str(copy.get("objective_text", copy.get("description_preview", "")))
						if hud_objective_font != null:
							objective_node.add_theme_font_override("font", hud_objective_font)

					if progress_node:
						progress_node.text = "(%d/%d)" % [int(copy.get("progress", 0)), int(copy.get("count", 1))]
						if hud_progress_font != null:
							progress_node.add_theme_font_override("font", hud_progress_font)

					var quest_done := bool(copy.get("completed", false))
					if checked_tex:
						checked_tex.visible = quest_done
					if unchecked_tex:
						unchecked_tex.visible = not quest_done

				# After API/fallback, enforce RightCol placement (avoid overlap)
				var title_node2 : Label = inst.get_node_or_null("Title")
				var rightcol2 : Control = inst.get_node_or_null("RightCol")
				var objective_node2 : Label = inst.get_node_or_null("RightCol/ObjectiveRow/Objective")

				var title_height := 0.0
				if title_node2 != null:
					var min_sz := title_node2.get_minimum_size()
					title_height = float(min_sz.y)
					title_node2.position = Vector2(0, 0)
				else:
					title_height = 24.0

				if rightcol2 != null:
					# use exported offset (row_rightcol_offset) so you can tweak gap
					rightcol2.position = Vector2(row_rightcol_offset.x, title_height + row_rightcol_offset.y)

				# enforce visuals (modulate/checkbox) in case instance didn't
				var checked_tex2 : TextureRect = inst.get_node_or_null("RightCol/ObjectiveRow/CheckedBox")
				var unchecked_tex2 : TextureRect = inst.get_node_or_null("RightCol/ObjectiveRow/UncheckedBox")
				var progress_node2 : Label = inst.get_node_or_null("RightCol/ObjectiveRow/Progress")

				var progress := int(copy.get("progress", 0))
				var count := int(copy.get("count", 1))
				var objective_done := progress >= count
				var quest_done := bool(copy.get("completed", false))

				var normal := Color(1,1,1,1)
				var partial := Color(0.85,0.85,0.85,1)
				var full := Color(0.6,0.6,0.6,1)

				if title_node2:
					title_node2.modulate = full if quest_done else normal
				if objective_node2:
					objective_node2.modulate = full if quest_done else (partial if objective_done else normal)
				if progress_node2:
					progress_node2.modulate = full if quest_done else (partial if objective_done else normal)
				if checked_tex2:
					checked_tex2.modulate = full if quest_done else (partial if objective_done else normal)
				if unchecked_tex2:
					unchecked_tex2.modulate = full if quest_done else (partial if objective_done else normal)

		shown += 1

	var remaining: int = _rows.size() - shown
	if remaining > 0:
		var more := _make_label_with_outline("+%d more" % remaining)
		if hud_objective_font != null:
			more.add_theme_font_override("font", hud_objective_font)
		vbox.add_child(more)

func _sort_by_title(a, b) -> int:
	var ta: String = str(_rows.get(a, {}).get("title", ""))
	var tb: String = str(_rows.get(b, {}).get("title", ""))
	if ta < tb:
		return -1
	elif ta == tb:
		return 0
	return 1

func _make_label_with_outline(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	var settings := LabelSettings.new()
	settings.font_color = Color(1, 1, 1)
	settings.outline_size = 4
	settings.outline_color = Color(0, 0, 0)
	lbl.label_settings = settings
	return lbl
