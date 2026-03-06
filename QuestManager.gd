extends Node

signal quest_updated(quest_id:String, new_state:String)
signal all_quests_completed()
signal quests_registered()

# store Resource/Node instances in a Dictionary by id
var quests: Dictionary = {}
var _saved_states: Dictionary = {}  # cache loaded from disk so we can apply later
# track dynamic progress in-memory
var _kill_progress := {}  # {"quest_id": current_count}

const SAVE_PATH := "user://quests.cfg"
# Add near top of QuestManager.gd
const QUESTS_FOLDER := "res://quests"

func _ready() -> void:
	# DEBUG: print autoload / root info so we can confirm QuestManager autoload at boot
	print("[QuestManager] _ready() start --- Engine.has_singleton('QuestManager') ->", Engine.has_singleton("QuestManager"))
	print("[QuestManager] global var typeof(QuestManager) ->", typeof(QuestManager))
	# list children of the SceneTree root for clarity
	var root := get_tree().get_root()
	var names := []
	for i in range(root.get_child_count()):
		var c = root.get_child(i)
		names.append(c.get_class() + ":" + c.name)
	print("[QuestManager] root children:", names)
	# --- end debug ---

	_load()                     # existing load for saved states (keep)
	_register_quest_resources() # auto-register any .tres quest resources
	debug_list_quests()         # optional: show what's registered on startup
	print("[QuestManager] READY: registered quests count:", quests.size())
	emit_signal("quests_registered")

func _register_quest_resources() -> void:
	var dir := DirAccess.open(QUESTS_FOLDER)
	if not dir:
		print("[QuestManager] No quests folder at", QUESTS_FOLDER, "(create it and put .tres quest resources there)")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			if fname.ends_with(".tres") or fname.ends_with(".res"):
				var full := QUESTS_FOLDER + "/" + fname
				var res := ResourceLoader.load(full)
				if res:
					# assume your Quest resource script uses `class_name Quest`
					if res.get_class() == "Quest" or res is Quest:
						if res.id == "" or res.id == null:
							print("[QuestManager] WARNING: quest resource", full, "has empty id; set its id property.")
						else:
							quests[res.id] = res
							print("[QuestManager] Registered quest resource:", res.id)
					else:
						print("[QuestManager] Skipping non-Quest resource:", full, "class:", res.get_class())
				else:
					print("[QuestManager] Failed to load resource:", full)
		fname = dir.get_next()
	dir.list_dir_end()
	print("[QuestManager] _register_quest_resources: done. total registered:", quests.size())

# Called by each Quest instance (resource or node) to register itself
func register_quest(q) -> void:
	if q == null:
		print("[QuestManager] register_quest: got null")
		return
	if not ("id" in q) or q.id == "":
		print("[QuestManager] register_quest: quest has no id or id is empty ->", q)
		return

	quests[q.id] = q
	# apply saved state if there was one
	if _saved_states.has(q.id):
		var old_state = q.state if "state" in q else "(no state)"
		q.state = _saved_states[q.id]
		print("[QuestManager] register_quest: applied saved state for", q.id, "->", q.state, "(was:", old_state, ")")
	else:
		print("[QuestManager] register_quest: registered", q.id, " state:", (q.state if "state" in q else "(no state)"))
	# helpful debug: show title if present
	if "title" in q:
		print("   title:", q.title)

func get_quest(id:String) -> Variant:
	return quests.get(id, null)

func accept_quest(id:String) -> void:
	var q = get_quest(id)
	if q == null:
		print("[QuestManager] accept_quest:", id, "-> quest not found")
		return
	if not ("state" in q):
		print("[QuestManager] accept_quest:", id, "-> quest has no state field")
		return
	if q.state != "available":
		print("[QuestManager] accept_quest:", id, "-> invalid state:", q.state)
		return
	q.state = "active"
	print("[QuestManager] accept_quest: accepted", id)

	# reset in-memory progress for kill objectives when (re)accepted
	if q.objective != null and q.objective.get("type", "") == "kill":
		_kill_progress[id] = 0

	emit_signal("quest_updated", id, q.state)
	save()

func notify_enemy_killed(enemy_type: String) -> void:
	var et := str(enemy_type).to_lower()
	for qid in quests.keys():
		var q = quests[qid]
		if q == null:
			continue
		if not ("state" in q) or q.state != "active":
			continue
		if q.objective == null:
			continue
		var obj_type := str(q.objective.get("type", "")).to_lower()
		var obj_target := str(q.objective.get("target", "")).to_lower()
		if obj_type == "kill" and obj_target != "" and obj_target == et:
			var needed := int(q.objective.get("count", 1))
			var key = qid
			if not _kill_progress.has(key):
				_kill_progress[key] = 0
			_kill_progress[key] += 1
			emit_signal("quest_updated", qid, "progress:" + str(_kill_progress[key]) + "/" + str(needed))
			if _kill_progress[key] >= needed:
				complete_quest(qid)

func complete_quest(id:String) -> void:
	var q = get_quest(id)
	if q == null:
		print("[QuestManager] complete_quest:", id, "-> quest not found")
		return
	if not ("state" in q):
		print("[QuestManager] complete_quest:", id, "-> quest has no state field")
		return
	if q.state != "active":
		print("[QuestManager] complete_quest:", id, "-> invalid state:", q.state)
		return
	q.state = "completed"
	print("[QuestManager] complete_quest: completed", id)
	emit_signal("quest_updated", id, q.state)
	_check_all_completed()
	save()

func fail_quest(id:String) -> void:
	var q = get_quest(id)
	if q == null:
		print("[QuestManager] fail_quest:", id, "-> quest not found")
		return
	if not ("state" in q):
		print("[QuestManager] fail_quest:", id, "-> quest has no state field")
		return
	if q.state != "active" and q.state != "available":
		print("[QuestManager] fail_quest:", id, "-> invalid state:", q.state)
		return
	q.state = "failed"
	print("[QuestManager] fail_quest: failed", id)
	emit_signal("quest_updated", id, q.state)
	save()

func _check_all_completed() -> void:
	for q in quests.values():
		if not ("state" in q) or q.state != "completed":
			return
	emit_signal("all_quests_completed")

# --- save/load using ConfigFile ---
func save() -> void:
	var cfg := ConfigFile.new()
	for id in quests.keys():
		var q = quests[id]
		if "state" in q:
			cfg.set_value("quests", id + "/state", q.state)
	cfg.save(SAVE_PATH)

func _load() -> void:
	_saved_states.clear()
	var cfg := ConfigFile.new()
	var err := cfg.load(SAVE_PATH)
	if err != OK:
		# no saved file — fine
		return
	for key in cfg.get_section_keys("quests"):
		# section keys are like "quest_id/state"
		var parts = key.split("/")
		if parts.size() >= 2:
			var qid = parts[0]
			var state = cfg.get_value("quests", key, "available")
			_saved_states[qid] = state
	print("[QuestManager] _load: loaded saved quest states for:", _saved_states.keys())

# --- Add after your existing _load()/save() functions ---

# Return a Dictionary snapshot suitable for storing in SaveData.saved_quests
func get_save_snapshot() -> Dictionary:
	# states: { quest_id: state }
	# kill_progress: { quest_id: int }
	var states: Dictionary = {}
	for id in quests.keys():
		var q = quests[id]
		if q != null and "state" in q:
			states[id] = q.state

	# copy progress map
	var kp: Dictionary = {}
	for k in _kill_progress.keys():
		kp[k] = int(_kill_progress[k])

	return {
		"states": states,
		"kill_progress": kp
	}

# Apply a snapshot dictionary (as returned by get_save_snapshot())
func apply_save_snapshot(snapshot: Dictionary) -> void:
	if snapshot == null:
		return
	var states = snapshot.get("states", {})
	var kills = snapshot.get("kill_progress", {})

	# apply states to registered quests if they exist, otherwise cache them so register_quest() will apply
	for qid in states.keys():
		var q = get_quest(qid)
		if q != null and "state" in q:
			q.state = str(states[qid])
		else:
			# cache to apply later when resource registers
			_saved_states[qid] = str(states[qid])

	# apply kill progress to runtime map
	_kill_progress.clear()
	for qid in kills.keys():
		_kill_progress[qid] = int(kills[qid])

	# emit updates for any active quests so UI updates
	for qid in quests.keys():
		var q = quests[qid]
		if q != null and "state" in q and q.state == "active":
			emit_signal("quest_updated", qid, "active")
	# also update progress signals
	for qid in _kill_progress.keys():
		var needed := int(quests.get(qid, {}).get("objective", {}).get("count", 1)) if quests.has(qid) else 0
		emit_signal("quest_updated", qid, "progress:%d/%d" % [_kill_progress[qid], needed])

# debug helper
func debug_list_quests() -> void:
	print("---- QuestManager registered quests ----")
	if quests.size() == 0:
		print(" (none)")
	for id in quests.keys():
		var q = quests[id]
		var state = str(q.state) if "state" in q else "(no state)"
		var title = str(q.title) if "title" in q else "(no title)"
		print(" ", id, " state:", state, " title:", title)
	print("----------------------------------------")

# returns integer progress for a quest id (0 if none)
func get_kill_progress(qid: String) -> int:
	return int(_kill_progress.get(qid, 0))

func claim_quest(id:String) -> void:
	var q = get_quest(id)
	if q == null:
		print("[QuestManager] claim_quest:", id, "-> quest not found")
		return
	if not ("state" in q):
		print("[QuestManager] claim_quest:", id, "-> quest has no state field")
		return
	# Allow claiming only if completed (defensive) - you can relax this if needed
	if q.state != "completed":
		print("[QuestManager] claim_quest:", id, "-> cannot claim from state:", q.state)
		# still allow forced claim if you'd like: uncomment next two lines
		# q.state = "claimed"
		# emit_signal("quest_updated", id, "claimed")
		return

	q.state = "claimed"
	print("[QuestManager] claim_quest: claimed", id)
	# optionally clear runtime progress for this quest
	if _kill_progress.has(id):
		_kill_progress.erase(id)

	emit_signal("quest_updated", id, "claimed")
	save()
