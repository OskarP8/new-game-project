extends Node

signal quest_updated(quest_id:String, new_state:String)
signal all_quests_completed()

# store Resource instances in a Dictionary by id
var quests: Dictionary = {}

func _ready() -> void:
	# call load() on ready so we restore quest states
	_load()

func register_quest(q: Quest) -> void:
	if q and q.id != "":
		quests[q.id] = q

func get_quest(id:String) -> Quest:
	return quests.get(id, null)

func accept_quest(id:String) -> void:
	var q = get_quest(id)
	if q and q.state == "available":
		q.state = "active"
		emit_signal("quest_updated", id, q.state)
		save()

func complete_quest(id:String) -> void:
	var q = get_quest(id)
	if q and q.state == "active":
		q.state = "completed"
		emit_signal("quest_updated", id, q.state)
		_check_all_completed()
		save()

func fail_quest(id:String) -> void:
	var q = get_quest(id)
	if q and (q.state == "active" or q.state == "available"):
		q.state = "failed"
		emit_signal("quest_updated", id, q.state)
		save()

func _check_all_completed() -> void:
	for q in quests.values():
		if q.state != "completed":
			return
	# if we reach here: all are completed
	emit_signal("all_quests_completed")

# --- simple save/load using ConfigFile (small, portable)
const SAVE_PATH := "user://quests.cfg"

func save() -> void:
	var cfg := ConfigFile.new()
	for id in quests.keys():
		var q = quests[id]
		cfg.set_value("quests", id + "/state", q.state)
	cfg.save(SAVE_PATH)

func _load() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SAVE_PATH)
	if err != OK:
		return
	for id in cfg.get_section_keys("quests"):
		# section keys are like "quest_id/state" so split
		var parts = id.split("/")
		if parts.size() >= 2:
			var qid = parts[0]
			var state = cfg.get_value("quests", id, "available")
			if quests.has(qid):
				quests[qid].state = state

# track dynamic progress in-memory (not persisted yet — we'll save)
var _kill_progress := {}  # {"quest_id": current_count}

func notify_enemy_killed(enemy_type: String) -> void:
	# iterate quests to see which active quest cares about this enemy_type
	for qid in quests.keys():
		var q = quests[qid]
		if q == null:
			continue
		if q.state != "active":
			continue
		if q.objective == null:
			continue
		if q.objective.get("type", "") == "kill" and q.objective.get("target", "") == enemy_type:
			var needed := int(q.objective.get("count", 1))
			var key = qid
			if not _kill_progress.has(key):
				_kill_progress[key] = 0
			_kill_progress[key] += 1
			# optional: emit progress signal (you can create one)
			emit_signal("quest_updated", qid, "progress:" + str(_kill_progress[key]) + "/" + str(needed))
			if _kill_progress[key] >= needed:
				complete_quest(qid)
