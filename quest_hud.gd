extends CanvasLayer

@export var max_visible: int = 6  # how many quest rows to show before "+N more"

# safe onready - use get_node_or_null so we don't crash if path differs
@onready var vbox: VBoxContainer = get_node_or_null("Panel/VBoxContainer")

# local cache: quest_id -> Dictionary{ title, type, target, count, progress }
var _rows: Dictionary = {}

func _ready() -> void:
	# sanity check vbox
	if vbox == null:
		print("[QuestHUD] WARNING: Panel/VBox node not found as child of this HUD. Please ensure the scene has Panel/VBox or update the path.")
	# try to connect to QuestManager if present; otherwise wait briefly and try again
	# prefer checking the global var directly because Engine.has_singleton can be unreliable in some setups
	if typeof(QuestManager) != TYPE_NIL:
		_connect_to_qm()
	else:
		# short wait then try again (non-blocking)
		await get_tree().create_timer(0.2).timeout
		if typeof(QuestManager) != TYPE_NIL:
			_connect_to_qm()
	# initial render (safe even if vbox is null)
	_refresh_ui()

func _connect_to_qm() -> void:
	# make sure the global exists and exposes the signals / helpers
	if typeof(QuestManager) == TYPE_NIL:
		print("[QuestHUD] QuestManager autoload not present (global var missing).")
		return

	# connect to quest_updated if not connected
	if not QuestManager.is_connected("quest_updated", Callable(self, "_on_quest_updated")):
		QuestManager.connect("quest_updated", Callable(self, "_on_quest_updated"))

	# ALSO listen for 'quests_registered' (emitted when QuestManager finishes loading or registering all quests)
	if not QuestManager.is_connected("quests_registered", Callable(self, "_update_all_from_qm")):
		QuestManager.connect("quests_registered", Callable(self, "_update_all_from_qm"))

	# populate initial rows from QuestManager (safe even if QuestManager has no quests yet)
	_update_all_from_qm()

func _update_all_from_qm() -> void:
	_rows.clear()
	# make sure global exists
	if typeof(QuestManager) == TYPE_NIL:
		return
	# iterate registered quests
	for id in QuestManager.quests.keys():
		var q = QuestManager.get_quest(id)
		if q == null:
			continue
		if not ("state" in q):
			continue
		if q.state == "active":
			_rows[id] = _make_row_from_quest(q)
	_refresh_ui()

func _make_row_from_quest(q) -> Dictionary:
	# produce a typed row dictionary
	var row: Dictionary = {}
	row.title = (q.title if "title" in q else q.id)
	# objective may be null or a Dictionary
	var obj = q.objective if q.objective != null else {}
	row.type = str(obj.get("type", "")).to_lower()
	row.target = str(obj.get("target", ""))
	row.count = int(obj.get("count", 1))
	# progress from QuestManager helper (safe)
	if Engine.has_singleton("QuestManager") and typeof(QuestManager) != TYPE_NIL and QuestManager.has_method("get_kill_progress"):
		row.progress = int(QuestManager.get_kill_progress(q.id))
	else:
		row.progress = 0

	# optional: collect description preview (works with String or Array)
	var desc_preview := ""
	if "description" in q:
		if typeof(q.description) == TYPE_ARRAY:
			# description is already an array of lines/paragraphs
			if q.description.size() > 0:
				desc_preview = str(q.description[0])
		else:
			# description is a string - take first paragraph (split on blank line)
			var s := str(q.description)
			var parts := s.split("\n\n")
			if parts.size() > 0:
				desc_preview = parts[0].strip_edges()
	row.description_preview = desc_preview

	return row

func _on_quest_updated(qid: String, new_state: String) -> void:
	# new_state may be "active"/"completed"/"progress:x/y"/"claimed"
	if typeof(new_state) == TYPE_STRING and new_state.begins_with("progress:"):
		var rest: String = new_state.substr(9)  # "x/y"
		var parts: Array = rest.split("/")
		var cur: int = int(parts[0]) if parts.size() >= 1 else 0
		if _rows.has(qid):
			_rows[qid].progress = cur
			_refresh_ui()
			return

	# If quest became active, add it (or refresh)
	if new_state == "active":
		var q = QuestManager.get_quest(qid)
		if q:
			_rows[qid] = _make_row_from_quest(q)
			_rows[qid].completed = false
	# If quest completed, mark as completed (do NOT erase)
	elif new_state == "completed":
		var q = QuestManager.get_quest(qid)
		if q:
			# ensure we keep the row around to show the completed state
			_rows[qid] = _make_row_from_quest(q)
			_rows[qid].completed = true
	# If quest was claimed (explicit removal), erase
	elif new_state == "claimed" or new_state == "failed":
		if _rows.has(qid):
			_rows.erase(qid)

	_refresh_ui()

func _refresh_ui() -> void:
	# if vbox missing, don't try to update UI; print helpful message once
	if vbox == null:
		print("[QuestHUD] _refresh_ui: vbox is null; skipping UI refresh.")
		return

	# clear vbox safely
	for child in vbox.get_children():
		vbox.remove_child(child)
		child.queue_free()

	# header
	var header: Label = Label.new()
	header.text = "Quests"
	vbox.add_child(header)

	# gather and sort ids by title
	var ids: Array = _rows.keys()
	ids.sort_custom(Callable(self, "_sort_by_title"))

	var shown: int = 0
	for id in ids:
		if shown >= max_visible:
			break
		var r: Dictionary = _rows[id]
		# title
		var title_lbl: Label = Label.new()
		title_lbl.text = r.title
		vbox.add_child(title_lbl)

		# progress / description / completed line
		var prog_lbl: Label = Label.new()
		if r.type == "kill":
			var target_name = r.target.capitalize() if r.target != "" else "Target"
			prog_lbl.text = "%s killed %d/%d" % [target_name, int(r.progress), int(r.count)]
		else:
			prog_lbl.text = "Progress: %d/%d" % [int(r.progress), int(r.count)]
		vbox.add_child(prog_lbl)

		# show completed marker if completed (quest remains until claimed)
		if r.get("completed", false):
			var comp_lbl: Label = Label.new()
			comp_lbl.text = "Completed — return to NPC to claim reward"
			# optional: smaller font or style can be applied in your theme; leave plain for safety
			vbox.add_child(comp_lbl)

		shown += 1

	var remaining: int = _rows.size() - shown
	if remaining > 0:
		var more: Label = Label.new()
		more.text = "+%d more" % remaining
		vbox.add_child(more)

func _sort_by_title(a, b) -> int:
	var ta: String = str(_rows.get(a, {}).get("title", ""))
	var tb: String = str(_rows.get(b, {}).get("title", ""))
	if ta < tb:
		return -1
	elif ta == tb:
		return 0
	return 1
