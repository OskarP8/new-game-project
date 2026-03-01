extends Node2D
class_name TaaraNPC

signal wish_granted(player: Node)

# Basic NPC data
@export var npc_name := "Taara"
@export var greeting_lines := [
	"Who approaches the oak? Speak, child of the land.",
	"Prove your strength and I shall consider your wish."
]
@export var quest_ids := ["taara_quest_1", "taara_quest_2", "taara_quest_3"]

# Interaction / prompt (Chest-style)
@onready var prompt_scene := preload("res://scenes/interact_prompt.tscn")
var prompt: Node2D = null
@export var npc_id: String = ""  # optional stable id

# Area2D for proximity (must exist in the scene under this node)
@onready var area: Area2D = $InteractionArea if has_node("InteractionArea") else null

# runtime
var is_interacting: bool = false
var is_done: bool = false
var _current_player: Node = null

# only show base greeting once per game session (prevents repeating the same lines)
var _greeted_once: bool = false

# dialog instance (cached) — will be resolved at runtime if necessary
var dlg: Node = null
# cache if we've subscribed to quest manager registration
var _connected_to_quest_mgr := false

# Helper: return the best QuestManager instance available, or null.
func _get_quest_mgr() -> Node:
	# 1) If the global var exists (autoload registered as global), return it.
	if typeof(QuestManager) != TYPE_NIL:
		return QuestManager

	# 2) Look for a direct child under the SceneTree root named "QuestManager"
	var root := get_tree().get_root()
	if root.has_node("QuestManager"):
		return root.get_node("QuestManager")

	# 3) Fallback: lightweight recursive search starting at root (safe: iterates children)
	var stack: Array = [ root ]
	while stack.size() > 0:
		var n = stack.pop_back()
		if n == null:
			continue
		if n.name == "QuestManager":
			return n
		for i in range(n.get_child_count()):
			stack.append(n.get_child(i))

	return null

func _ready() -> void:
	# attempt initial resolution & safe connection
	_resolve_and_connect_dialogbox()
	# after _resolve_and_connect_dialogbox() in _ready()
	var QM := _get_quest_mgr()
	if QM != null and not _connected_to_quest_mgr:
		if not QM.is_connected("quests_registered", Callable(self, "_on_quests_registered")):
			QM.connect("quests_registered", Callable(self, "_on_quests_registered"))
		_connected_to_quest_mgr = true
	# connect area signals (proximity prompt) — handle both bodies and areas
	if area:
		if not area.is_connected("body_entered", Callable(self, "_on_area_body_entered")):
			area.body_entered.connect(Callable(self, "_on_area_body_entered"))
		if not area.is_connected("body_exited", Callable(self, "_on_area_body_exited")):
			area.body_exited.connect(Callable(self, "_on_area_body_exited"))
		# Also listen for other Area2D overlaps (the player's InteractionComponent is an Area2D)
		if not area.is_connected("area_entered", Callable(self, "_on_area_area_entered")):
			area.area_entered.connect(Callable(self, "_on_area_area_entered"))
		if not area.is_connected("area_exited", Callable(self, "_on_area_area_exited")):
			area.area_exited.connect(Callable(self, "_on_area_area_exited"))
	else:
		print("[Taara] Warning: InteractionArea Area2D not found. Add a child Area2D named 'InteractionArea' with CollisionShape2D.")

	_update_done_state()
	_debug_interaction_state()

# Try to find DialogBox and connect signals (safe to call any time)
func _resolve_and_connect_dialogbox() -> void:
	# if already have a valid dlg, nothing to do
	if dlg and is_instance_valid(dlg):
		return

	# try current scene first
	dlg = get_tree().current_scene.get_node_or_null("DialogBox")
	if dlg == null:
		# fallback: global search
		dlg = get_tree().root.find_node("DialogBox", true, false)

	if dlg:
		# connect signals if not already connected
		if not dlg.is_connected("line_finished", Callable(self, "_on_line_finished")):
			dlg.connect("line_finished", Callable(self, "_on_line_finished"))
		if not dlg.is_connected("dialog_complete", Callable(self, "_on_dialog_complete")):
			dlg.connect("dialog_complete", Callable(self, "_on_dialog_complete"))
		print("[Taara] DialogBox resolved and signals connected ->", dlg)
	else:
		# don't spam logs, do a single warning
		print("[Taara] DialogBox not found yet (will retry on interact).")

func _update_done_state() -> void:
	var QM := _get_quest_mgr()
	if QM == null:
		is_done = false
		return
	for qid in quest_ids:
		var q = QM.get_quest(qid)
		if q == null:
			is_done = false
			return
		if not ("state" in q) or q.state != "completed":
			is_done = false
			return
	is_done = true

# Called by InteractionComponent / player controller when the player chooses to interact
func interact(player: Node2D) -> void:
	_resolve_and_connect_dialogbox()

	print("[Taara DEBUG] interact() running — resolving QuestManager debug info now")

	# quick QM lookup like before, prefer autoload var
	var QM = null
	if typeof(QuestManager) != TYPE_NIL:
		QM = QuestManager
	elif get_tree().get_root().has_node("QuestManager"):
		QM = get_tree().get_root().get_node("QuestManager")

	if player == null:
		print("[Taara] ⚠ No player supplied to interact()")
		return

	# Build dialog lines
	var lines: Array = []

	# show base greeting only the first time we talk (prevents repeat on every interaction)
	if not _greeted_once:
		for l in greeting_lines:
			lines.append(l)
		_greeted_once = true

	print("[Taara] Debug: Gathering quest info for dialog:")
	var any_quest_lines := false
	for qid in quest_ids:
		var q = null
		if QM != null and QM.has_method("get_quest"):
			q = QM.get_quest(qid)
		if q == null:
			print("  -", qid, " -> NULL")
			continue
		var state_str := str(q.state) if "state" in q else "(no state)"
		var title_str = q.title if "title" in q else qid
		print("  -", qid, "-> state:", state_str, " title:", title_str)

		# inside interact() loop where you handle available quests:
		if q.state == "available":
			# use description as the quest intro (split into paragraphs if you put blank lines)
			if "description" in q and q.description != "":
				var paragraphs := str(q.description).split("\n\n")
				for para in paragraphs:
					if para.strip_edges() != "":
						lines.append(para.strip_edges())
			else:
				lines.append("I ask you to: " + title_str)
			any_quest_lines = true

		elif q.state == "active":
			lines.append("You are working on: " + title_str)
			# optionally include progress if QuestManager exposes progress
			var prog = QM.get_kill_progress(qid) if QM and QM.has_method("get_kill_progress") else 0
			if q.objective != null and q.objective.get("type", "") == "kill":
				lines.append("%s killed %d/%d" % [q.objective.get("target", "").capitalize(), prog, int(q.objective.get("count", 1))])
			any_quest_lines = true

		elif q.state == "completed":
			lines.append("Thank you — you completed: " + title_str)
			any_quest_lines = true

	# fallback
	if not any_quest_lines:
		lines.append("...")
		lines.append("I have no new task for you now.")

	is_interacting = true
	_show_prompt(false)

	print("[Taara] Sending lines to DialogBox (count):", lines.size(), " ->", lines)

	if dlg == null:
		_resolve_and_connect_dialogbox()

	if dlg == null:
		print("[Taara] ⚠ DialogBox still not found — aborting show_dialog()")
		return

	dlg.show_dialog(lines, npc_name, "pop")

# Add this helper to TaaraNPC
func _claim_completed_quests() -> void:
	var QM := _get_quest_mgr()
	if QM == null:
		print("[Taara] No QuestManager found when trying to claim quests.")
		return

	var claimed_any := false
	for qid in quest_ids:
		var q = null
		if QM and QM.has_method("get_quest"):
			q = QM.get_quest(qid)
		if q == null:
			continue
		# only claim those that are completed
		if "state" in q and q.state == "completed":
			# prefer explicit claim_quest API if present
			if QM.has_method("claim_quest"):
				print("[Taara] Claiming quest via QuestManager.claim_quest(", qid, ")")
				QM.claim_quest(qid)
				claimed_any = true
			# fallback attempts (defensive): try some common alternate method names
			elif QM.has_method("set_quest_state"):
				print("[Taara] Claiming quest via QuestManager.set_quest_state(", qid, ", 'claimed')")
				QM.set_quest_state(qid, "claimed")
				claimed_any = true
			elif QM.has_method("update_quest_state"):
				print("[Taara] Claiming quest via QuestManager.update_quest_state(", qid, ", 'claimed')")
				QM.update_quest_state(qid, "claimed")
				claimed_any = true
			else:
				print("[Taara] Warning: QuestManager has no known claim API. You may need to implement QuestManager.claim_quest(qid).")

	# let QuestManager/HUD handle emitting updates. If your QuestManager doesn't emit updates on claim,
	# you could emit a custom signal here or call a HUD refresh directly (not recommended).
	if claimed_any:
		# Refresh our done state after claiming attempt
		_update_done_state()

# Then modify your existing _on_dialog_complete() — replace the 'if is_done: _perform_wish_flow(null)' block
# with this safer logic (keep the rest of your function unchanged):
func _on_dialog_complete() -> void:
	print("[Taara] _on_dialog_complete() called — checking quests to offer/accept")
	var QM := _get_quest_mgr()
	# debug states
	for qid in quest_ids:
		var q = null
		if QM:
			q = QM.get_quest(qid)
		if q == null:
			print("  -", qid, " -> NULL")
			continue
		var state_str := str(q.state) if "state" in q else "(no state)"
		print("  -", qid, "-> state:", state_str)

	# Attempt to auto-offer/accept first available quest
	for qid in quest_ids:
		var q = null
		if QM:
			q = QM.get_quest(qid)
		if q and "state" in q and q.state == "available":
			var title_str = q.title if "title" in q else qid
			print("[Taara] Offering quest:", qid, "title:", title_str)
			if QM and QM.has_method("accept_quest"):
				print("[Taara] Calling QuestManager.accept_quest(", qid, ")")
				QM.accept_quest(qid)
				if dlg == null:
					_resolve_and_connect_dialogbox()
				if dlg:
					dlg.show_dialog(["You accepted: " + title_str], npc_name, "slide_up")
				is_interacting = false
				_show_prompt(true)
				return
			else:
				print("[Taara] ⚠ QuestManager.accept_quest not available")
	# none to offer — re-check done
	_update_done_state()

	# If quests are done (completed), claim them now (player is talking to Taara to claim)
	if is_done:
		# Attempt to mark completed quests as claimed via QuestManager API (safe fallback)
		_claim_completed_quests()
		# After claiming we do the wish flow for the player
		_perform_wish_flow(_current_player)
	else:
		is_interacting = false
		_show_prompt(true)

func _on_line_finished() -> void:
	# optional: sound/effect per-line
	pass

func _perform_wish_flow(player: Node) -> void:
	print("[Taara] You proved worthy. Granting wish now.")
	if dlg:
		dlg.show_dialog(["You have proven yourself. Speak your wish."], npc_name, "slide_up")
	emit_signal("wish_granted", player)
	is_done = true
	_show_prompt(false)

# ----- Area2D handlers (connect these) -----
func _on_area_body_entered(body: Node) -> void:
	if body == null:
		return
	print("[Taara] Area body_entered:", body.name if "name" in body else body)
	if body is Node and (body.is_in_group("player") or body.is_in_group("Player")):
		_current_player = body
		var interactor = body.find_child("InteractionComponent", true, false)
		if interactor:
			if "can_interact" in interactor and self not in interactor.can_interact:
				interactor.can_interact.append(self)
				if interactor.has_method("_update_prompt"):
					interactor._update_prompt()
				return
			if interactor.has_method("_update_prompt"):
				interactor._update_prompt()
				return
			if interactor.has_method("show_prompt_for"):
				interactor.show_prompt_for(self)
				return
			if interactor.has_method("show_prompt"):
				interactor.show_prompt("Press E", global_position)
				return
		_show_prompt(true)

func _on_area_body_exited(body: Node) -> void:
	if body == null:
		return
	print("[Taara] Area body_exited:", body.name if "name" in body else body)
	if body is Node and (body.is_in_group("player") or body.is_in_group("Player")):
		var interactor = body.find_child("InteractionComponent", true, false)
		if interactor:
			if "can_interact" in interactor and self in interactor.can_interact:
				interactor.can_interact.erase(self)
				if interactor.has_method("_update_prompt"):
					interactor._update_prompt()
				return
			if interactor.has_method("_update_prompt"):
				interactor._update_prompt()
			elif interactor.has_method("hide_prompt_for"):
				interactor.hide_prompt_for(self)
			elif interactor.has_method("hide_prompt"):
				interactor.hide_prompt()
		else:
			_show_prompt(false)
		_current_player = null

func _on_area_area_entered(a: Area2D) -> void:
	if a == null:
		return
	print("[Taara] Area area_entered:", a.name if "name" in a else a, "class:", a.get_class())
	if "can_interact" in a:
		if self not in a.can_interact:
			a.can_interact.append(self)
			if a.has_method("_update_prompt"):
				a._update_prompt()
				return
	if a.has_method("_update_prompt"):
		a._update_prompt()
		return
	if a.has_method("show_prompt_for"):
		a.show_prompt_for(self)
		return
	if a.has_method("show_prompt"):
		# pass expected args
		a.show_prompt("Press E", global_position)
		return

	var owner_player := _find_owner_player_from_node(a)
	if owner_player:
		_on_area_body_entered(owner_player)

func _on_area_area_exited(a: Area2D) -> void:
	if a == null:
		return
	print("[Taara] Area area_exited:", a.name if "name" in a else a, "class:", a.get_class())
	if "can_interact" in a and self in a.can_interact:
		a.can_interact.erase(self)
		if a.has_method("_update_prompt"):
			a._update_prompt()
		return

	if a.has_method("hide_prompt_for"):
		a.hide_prompt_for(self)
		return
	if a.has_method("hide_prompt"):
		a.hide_prompt()
		return

	var owner_player := _find_owner_player_from_node(a)
	if owner_player:
		_on_area_body_exited(owner_player)

func _find_owner_player_from_node(node: Node) -> Node:
	if node == null:
		return null
	var p := node
	while p:
		if p.is_in_group("Player") or p.is_in_group("player"):
			return p
		p = p.get_parent()
	return null

func _show_prompt(visible: bool) -> void:
	if visible:
		if prompt == null and prompt_scene:
			prompt = prompt_scene.instantiate()
			get_tree().current_scene.add_child(prompt)
		if prompt:
			var offset := Vector2(10, 6)
			var target_pos := global_position + offset
			if prompt.has_method("show_prompt"):
				prompt.show_prompt("Press E", target_pos)
			else:
				prompt.global_position = target_pos
				prompt.visible = true
	else:
		if prompt:
			if prompt.has_method("hide_prompt"):
				prompt.hide_prompt()
			else:
				prompt.visible = false

func _make_npc_id() -> String:
	if npc_id != "":
		return npc_id
	var scene_path := get_tree().current_scene.scene_file_path if get_tree().current_scene else ""
	return "%s::%s" % [scene_path, str(global_position)]

# DEBUG helper...
func _debug_interaction_state() -> void:
	print("---- Taara DEBUG START ----")
	print("Taara node:", self.name, "global_pos:", global_position)
	print("area (onready) is null?:", area == null)
	if has_node("InteractionArea"):
		var a = $InteractionArea
		print(" InteractionArea node exists (path $InteractionArea). monitoring:", a.monitoring, " monitorable:", a.monitorable)
		print("  collision_layer:", a.collision_layer, " collision_mask:", a.collision_mask)
		print("  InteractionArea children count:", a.get_child_count())
		for i in range(a.get_child_count()):
			var ch = a.get_child(i)
			print("   child:", i, ch.name, "class:", ch.get_class())
			if ch is CollisionShape2D:
				print("    CollisionShape2D disabled?:", ch.disabled, " shape class:", (ch.shape.get_class() if ch.shape else "null"))
				if ch.shape is CircleShape2D:
					print("     Circle radius:", ch.shape.radius)
				elif ch.shape is RectangleShape2D:
					print("     Rect extents:", ch.shape.extents)
	else:
		print(" No node named InteractionArea found as direct child. Listing children of Taara:")
		for i in range(get_child_count()):
			var c = get_child(i)
			print("  child:", i, c.name, "class:", c.get_class())

	if area != null:
		print(" onready 'area' resolved to node:", area.name, "path:", area.get_path())
	var players := get_tree().get_nodes_in_group("Player") + get_tree().get_nodes_in_group("player")
	print("Players found by groups: Player count:", get_tree().get_nodes_in_group("Player").size(), " player count:", get_tree().get_nodes_in_group("player").size(), " total detect:", players.size())
	for p in players:
		print("  - player node:", p.name, "pos:", p.global_position)
	print("---- Taara DEBUG END ----")

func _on_quests_registered() -> void:
	print("[Taara] Received quests_registered from QuestManager — re-checking done state")
	_update_done_state()
