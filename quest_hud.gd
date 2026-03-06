extends CanvasLayer

@export var max_visible: int = 6
@export var hud_title_font: Font      # create a font resource sized for "3x" title (e.g. 48px)
@export var hud_objective_font: Font  # create a font resource sized for objective (e.g. 32px)
@export var hud_progress_font: Font   # optional: font for progress (e.g. 32px)

@onready var vbox: VBoxContainer = get_node_or_null("Panel/VBoxContainer")

var _rows: Dictionary = {}  # quest_id -> { title,type,target,count,progress,completed,description_preview, _raw_objective }

func _ready() -> void:
	if vbox == null:
		print("[QuestHUD] WARNING: Panel/VBox node not found as child of this HUD.")
	if typeof(QuestManager) != TYPE_NIL:
		_connect_to_qm()
	else:
		await get_tree().create_timer(0.2).timeout
		if typeof(QuestManager) != TYPE_NIL:
			_connect_to_qm()
	_refresh_ui()

func _connect_to_qm() -> void:
	if typeof(QuestManager) == TYPE_NIL:
		print("[QuestHUD] QuestManager autoload not present.")
		return
	if not QuestManager.is_connected("quest_updated", Callable(self, "_on_quest_updated")):
		QuestManager.connect("quest_updated", Callable(self, "_on_quest_updated"))
	if not QuestManager.is_connected("quests_registered", Callable(self, "_update_all_from_qm")):
		QuestManager.connect("quests_registered", Callable(self, "_update_all_from_qm"))
	_update_all_from_qm()

func _update_all_from_qm() -> void:
	_rows.clear()
	if typeof(QuestManager) == TYPE_NIL:
		return
	for id in QuestManager.quests.keys():
		var q = QuestManager.get_quest(id)
		if q == null:
			continue
		if not ("state" in q):
			continue
		# Only keep active quests in the main list (completed will be set via signal)
		if q.state == "active":
			_rows[id] = _make_row_from_quest(q)
	_refresh_ui()

func _make_row_from_quest(q) -> Dictionary:
	var row: Dictionary = {}
	if "title" in q:
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
	# keep raw objective map for better phrasing later if needed
	row._raw_objective = obj
	return row

func _on_quest_updated(qid: String, new_state: String) -> void:
	# handle progress updates of the form "progress:x/y"
	if typeof(new_state) == TYPE_STRING and new_state.begins_with("progress:"):
		var rest: String = new_state.substr(9)  # "x/y"
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
			# ensure progress shows full count when completed
			_rows[qid].progress = int(_rows[qid].count)
			_rows[qid].completed = true
	elif new_state == "claimed" or new_state == "failed":
		if _rows.has(qid):
			_rows.erase(qid)

	_refresh_ui()

# -----------------------------
# Objective text builder (no ternary operators)
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

	# fallback: prefer description preview if available
	var dp := str(r.get("description_preview", "")).strip_edges()
	if dp != "":
		return dp
	# final fallback
	return "Objective: " + str(r.get("title", "Unknown Quest"))

# -----------------------------
# Render function — layout:
# Title (3x)
# Under it: single HBox containing: [Check visual] [Objective text (font-sized)] [small gap] [Progress (font-sized)]
func _refresh_ui() -> void:
	if vbox == null:
		return

	# clear existing children
	for child in vbox.get_children():
		vbox.remove_child(child)
		child.queue_free()

	# hide HUD if nothing to show
	if _rows.size() == 0:
		self.visible = false
		return
	else:
		self.visible = true

	var ids: Array = _rows.keys()
	ids.sort_custom(Callable(self, "_sort_by_title"))

	var shown: int = 0
	for id in ids:
		if shown >= max_visible:
			break
		var r: Dictionary = _rows[id]

		# Title line (use title font resource; do NOT scale)
		var title_lbl := _make_label_with_outline(r.title)
		if hud_title_font != null:
			title_lbl.add_theme_font_override("font", hud_title_font)
		vbox.add_child(title_lbl)

		# Objective row (checkbox visual + objective + small gap + progress)
		var obj_row := HBoxContainer.new()

		# checkbox visual (non-interactive)
		var pressed_flag := false
		if r.has("completed") and r.completed:
			pressed_flag = true
		var chk_visual := _make_checkbox_visual(pressed_flag)
		obj_row.add_child(chk_visual)

		# objective label (uses objective font and expands)
		var objective_text := _build_objective_text(r)
		var obj_lbl := _make_label_with_outline(objective_text)
		if hud_objective_font != null:
			obj_lbl.add_theme_font_override("font", hud_objective_font)
		obj_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		obj_row.add_child(obj_lbl)

		# slight gap
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(8, 0)
		obj_row.add_child(gap)

		# progress label (keeps close to objective)
		var prog_lbl := _make_label_with_outline("(%d/%d)" % [int(r.progress), int(r.count)])
		if hud_progress_font != null:
			prog_lbl.add_theme_font_override("font", hud_progress_font)
		# default size flags keep it tight to its content
		obj_row.add_child(prog_lbl)

		vbox.add_child(obj_row)

		# completed note (optional)
		if r.has("completed") and r.completed:
			var comp_lbl := _make_label_with_outline("Completed - return to NPC to claim reward")
			if hud_objective_font != null:
				comp_lbl.add_theme_font_override("font", hud_objective_font)
			vbox.add_child(comp_lbl)

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

func _make_checkbox_visual(pressed: bool) -> Control:
	# Returns a small Control node that looks like an outlined empty box (like ☐),
	# with a thin black outer outline and a white inner border (center empty).
	# Non-interactive (mouse ignored).

	var wrapper := Control.new()
	wrapper.name = "checkbox_visual"
	# Use Vector2 (not Vector2i) so math stays consistent
	wrapper.custom_minimum_size = Vector2(28, 28)  # tweak size here

	# Outer panel -> black outline
	var outer := Panel.new()
	outer.name = "cb_outer"
	outer.custom_minimum_size = wrapper.custom_minimum_size

	var outer_style := StyleBoxFlat.new()
	outer_style.bg_color = Color(0, 0, 0, 0)        # transparent interior
	outer_style.border_width_all = 2.0             # outer outline thickness (float ok)
	outer_style.border_color = Color(0, 0, 0)      # black outline
	outer.add_theme_stylebox_override("panel", outer_style)

	# Inner panel -> white border (transparent center)
	var inner := Panel.new()
	# compute inner size using Vector2 so subtraction is valid
	var inset := Vector2(8, 8)                     # total inset (4 px each side)
	inner.custom_minimum_size = wrapper.custom_minimum_size - inset

	var inner_style := StyleBoxFlat.new()
	inner_style.bg_color = Color(0, 0, 0, 0)       # keep center transparent (not filled)
	inner_style.border_width_all = 2.0             # visible white border thickness
	inner_style.border_color = Color(1, 1, 1)      # white border color
	inner.add_theme_stylebox_override("panel", inner_style)

	# Layout: place outer and center inner on top of it
	var place := MarginContainer.new()
	place.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place.custom_minimum_size = wrapper.custom_minimum_size
	place.add_child(outer)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.custom_minimum_size = wrapper.custom_minimum_size
	center.add_child(inner)
	place.add_child(center)

	wrapper.add_child(place)

	# Optional check mark placed centered on top when pressed
	if pressed:
		var check_lbl := Label.new()
		check_lbl.text = "✓"
		check_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if hud_progress_font != null:
			check_lbl.add_theme_font_override("font", hud_progress_font)
		# center mark
		var c2 := CenterContainer.new()
		c2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c2.custom_minimum_size = wrapper.custom_minimum_size
		c2.add_child(check_lbl)
		wrapper.add_child(c2)

	# Make non-interactive
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return wrapper
