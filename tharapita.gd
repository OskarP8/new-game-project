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
# --- summon/leave animation hookup ---
var _summoned: bool = false
@onready var _taara_anim: AnimatedSprite2D = $AnimatedSprite2D
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

# (pause handling) stash previous paused flag so we can restore it
var _prev_tree_paused: bool = false
# numeric value matching PAUSE_MODE_PROCESS (Engine constant not available via 'Node' in some Godot builds)
const PAUSE_MODE_PROCESS := 2

# ------------------------------------------------------------------
# Helper: return the best QuestManager instance available, or null.
func _get_quest_mgr() -> Node:
	if typeof(QuestManager) != TYPE_NIL:
		return QuestManager
	var root := get_tree().get_root()
	if root.has_node("QuestManager"):
		return root.get_node("QuestManager")
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
	_resolve_and_connect_dialogbox()
	var QM := _get_quest_mgr()
	if QM != null and not _connected_to_quest_mgr:
		if not QM.is_connected("quests_registered", Callable(self, "_on_quests_registered")):
			QM.connect("quests_registered", Callable(self, "_on_quests_registered"))
		_connected_to_quest_mgr = true
	if area:
		if not area.is_connected("body_entered", Callable(self, "_on_area_body_entered")):
			area.body_entered.connect(Callable(self, "_on_area_body_entered"))
		if not area.is_connected("body_exited", Callable(self, "_on_area_body_exited")):
			area.body_exited.connect(Callable(self, "_on_area_body_exited"))
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
	if dlg and is_instance_valid(dlg):
		return
	dlg = get_tree().current_scene.get_node_or_null("DialogBox")
	if dlg == null:
		dlg = get_tree().root.find_node("DialogBox", true, false)
	if dlg:
		if not dlg.is_connected("line_finished", Callable(self, "_on_line_finished")):
			dlg.connect("line_finished", Callable(self, "_on_line_finished"))
		if not dlg.is_connected("dialog_complete", Callable(self, "_on_dialog_complete")):
			dlg.connect("dialog_complete", Callable(self, "_on_dialog_complete"))
		print("[Taara] DialogBox resolved and signals connected ->", dlg)
	else:
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

# Ensure DialogBox (or a CanvasLayer ancestor) has pause_mode set to PROCESS so the dialog UI keeps running.
# Returns true if it managed to set pause_mode on dialog or a parent CanvasLayer.
func _ensure_dialog_process_mode() -> bool:
	if dlg == null or not is_instance_valid(dlg):
		return false

	# Try dialog node itself first
	if _try_set_pause_mode_on(dlg):
		return true

	# Walk up parents and set the first CanvasLayer (or first parent that exposes pause_mode)
	var p := dlg.get_parent()
	while p:
		if p is CanvasLayer:
			if _try_set_pause_mode_on(p):
				return true
		else:
			if _try_set_pause_mode_on(p):
				return true
		p = p.get_parent()

	# Nothing found
	print("[Taara] _ensure_dialog_process_mode: no node with 'pause_mode' property found. " +
		  "Open DialogBox/CanvasLayer in the inspector and set Pause Mode -> Process.")
	return false

func _try_set_pause_mode_on(node: Node) -> bool:
	if node == null:
		return false
	var props := node.get_property_list()
	for p in props:
		if typeof(p) == TYPE_DICTIONARY and p.has("name") and p["name"] == "pause_mode":
			# set using set() to avoid direct member access issues
			node.set("pause_mode", PAUSE_MODE_PROCESS)
			print("[Taara] set pause_mode on", node, "to PAUSE_MODE_PROCESS")
			return true
	return false

# -------------------
# Freeze/unfreeze helpers (use SceneTree.paused)
func _freeze_game() -> void:
	# store the current paused state and pause the tree so gameplay stops.
	_prev_tree_paused = get_tree().paused
	# DialogBox and any UI you want to keep running MUST have pause_mode = PROCESS.
	get_tree().paused = true
	print("[Taara] Game frozen for dialog (tree.paused = true)")

func _unfreeze_game() -> void:
	# restore previous paused state
	get_tree().paused = _prev_tree_paused
	print("[Taara] Game unfrozen (tree.paused restored)")

func interact(player: Node2D) -> void:
	# don't start a new interaction while one is already running
	if is_interacting:
		print("[Taara] interact() ignored: already in a conversation")
		return

	_resolve_and_connect_dialogbox()
	print("[Taara DEBUG] interact() running — resolving QuestManager debug info now")
	var QM = null
	if typeof(QuestManager) != TYPE_NIL:
		QM = QuestManager
	elif get_tree().get_root().has_node("QuestManager"):
		QM = get_tree().get_root().get_node("QuestManager")
	if player == null:
		print("[Taara] ⚠ No player supplied to interact()")
		return

	_current_player = player

	var lines: Array = []
	if not _greeted_once:
		for l in greeting_lines:
			lines.append({
				"text": l,
				"speaker_name": npc_name,
				"speaker_role": "god"
			})
		_greeted_once = true

	print("[Taara] Debug: Gathering quest info for dialog:")
	var any_quest_lines := false
	var next_qid: String = ""
	for qid in quest_ids:
		var q = null
		if QM != null and QM.has_method("get_quest"):
			q = QM.get_quest(qid)
		if q == null:
			continue
		if "state" in q and q.state == "completed":
			continue
		next_qid = qid
		break

	if next_qid == "":
		lines.append({"text":"...", "speaker_name": npc_name, "speaker_role": "god"})
		lines.append({"text":"I have no new task for you now.", "speaker_name": npc_name, "speaker_role": "god"})
	else:
		var q = QM.get_quest(next_qid) if QM and QM.has_method("get_quest") else null
		var title_str = (q.title if q and "title" in q else next_qid)
		if q == null:
			lines.append({"text": "I ask you to: " + title_str, "speaker_name": npc_name, "speaker_role": "god"})
			any_quest_lines = true
		else:
			if q.state == "available":
				if "description" in q and q.description != null:
					if typeof(q.description) == TYPE_ARRAY:
						var nonempty := []
						for elem in q.description:
							var line := str(elem).strip_edges()
							if line != "":
								nonempty.append(line)
						if nonempty.size() > 0:
							for para in nonempty:
								lines.append({"text": para, "speaker_name": npc_name, "speaker_role": "god"})
						else:
							lines.append({"text": "I ask you to: " + title_str, "speaker_name": npc_name, "speaker_role": "god"})
					elif typeof(q.description) == TYPE_STRING:
						var sdesc := str(q.description).strip_edges()
						if sdesc != "":
							var paragraphs := sdesc.split("\n\n")
							for para in paragraphs:
								var p := para.strip_edges()
								if p != "":
									lines.append({"text": p, "speaker_name": npc_name, "speaker_role": "god"})
						else:
							lines.append({"text": "I ask you to: " + title_str, "speaker_name": npc_name, "speaker_role": "god"})
					else:
						var fallback := str(q.description).strip_edges()
						if fallback != "":
							lines.append({"text": fallback, "speaker_name": npc_name, "speaker_role": "god"})
						else:
							lines.append({"text": "I ask you to: " + title_str, "speaker_name": npc_name, "speaker_role": "god"})
				else:
					lines.append({"text": "I ask you to: " + title_str, "speaker_name": npc_name, "speaker_role": "god"})
				any_quest_lines = true
			elif q.state == "active":
				lines.append({"text": "You are working on: " + title_str, "speaker_name": npc_name, "speaker_role": "god"})
				var prog = QM.get_kill_progress(next_qid) if QM and QM.has_method("get_kill_progress") else 0
				if q.objective != null and q.objective.get("type", "") == "kill":
					lines.append({"text": "%s killed %d/%d" % [q.objective.get("target", "").capitalize(), prog, int(q.objective.get("count", 1))], "speaker_name": "", "speaker_role": "villager"})
				any_quest_lines = true
			elif q.state == "completed":
				lines.append({"text": "Thank you — you completed: " + title_str, "speaker_name": npc_name, "speaker_role": "god"})
				any_quest_lines = true

	if not any_quest_lines:
		lines.append({"text":"...", "speaker_name": npc_name, "speaker_role": "god"})
		lines.append({"text":"I have no new task for you now.", "speaker_name": npc_name, "speaker_role": "god"})

	# mark interacting and freeze game so gameplay stops while dialog runs
	is_interacting = true
	_show_prompt(false)

	print("[Taara] Sending lines to DialogBox (count):", lines.size(), " ->", lines)
	if dlg == null:
		_resolve_and_connect_dialogbox()
	if dlg == null:
		print("[Taara] ⚠ DialogBox still not found — aborting show_dialog()")
		is_interacting = false
		_show_prompt(true)
		return

	# hide EVERY player's prompts so dialog gets input focus (best-effort)
	_hide_all_player_prompts()

	# Make dialog UI process while paused if possible.
	var dialog_process_ok := _ensure_dialog_process_mode()

	# If we could set process mode on dialog/UI, it's safe to pause the tree.
	# Otherwise do NOT pause — show dialog normally so it runs.
	if dialog_process_ok:
		_freeze_game()
	else:
		print("[Taara] Warning: couldn't make dialog UI process while paused — running dialog without pausing.")

	# Finally show the dialog (dialog will remain interactive because we forced PROCESS mode if available)
	dlg.show_dialog(lines, npc_name, "pop")
	# ensure dialog UI is process-mode capable (best-effort)
	_ensure_dialog_process_mode()
	# Bring dialog to front (if parent exists) and ensure visible
	if dlg.get_parent():
		var parent = dlg.get_parent()
		parent.move_child(dlg, parent.get_child_count() - 1)
	# ensure Control-level focus / raise (best-effort)
	if dlg is Control:
		dlg.raise()
		dlg.grab_focus()

	# show dim overlay after dialog is visible (dim ignores mouse)
	_show_dim_overlay()

func call_to(player: Node2D, auto_open_dialog: bool = true) -> void:
	# don't teleport/interact if Taara is already in a conversation
	if is_interacting:
		print("[Taara] call_to ignored: already interacting")
		return
	if player == null:
		return

	# Show Taara (in case we hid it previously)
	_show_for_summon()

	# position Taara exactly at the player's global position (center)
	global_position = player.global_position
	_play_summon()
	_show_prompt(true)
	# optionally immediately start the interaction
	if auto_open_dialog:
		interact(player)

# Add this helper to TaaraNPC
func _claim_completed_quests() -> bool:
	var QM := _get_quest_mgr()
	if QM == null:
		print("[Taara] No QuestManager found when trying to claim quests.")
		return false
	var claimed_any := false
	for qid in quest_ids:
		var q = null
		if QM and QM.has_method("get_quest"):
			q = QM.get_quest(qid)
		if q == null:
			continue
		if "state" in q and q.state == "completed":
			if QM.has_method("claim_quest"):
				print("[Taara] Claiming quest via QuestManager.claim_quest(", qid, ")")
				QM.claim_quest(qid)
				claimed_any = true
			elif QM.has_method("set_quest_state"):
				print("[Taara] Claiming quest via QuestManager.set_quest_state(", qid, ", 'claimed')")
				QM.set_quest_state(qid, "claimed")
				claimed_any = true
			elif QM.has_method("update_quest_state"):
				print("[Taara] Claiming quest via QuestManager.update_quest_state(", qid, ", 'claimed')")
				QM.update_quest_state(qid, "claimed")
				claimed_any = true
			else:
				print("[Taara] Fallback: emitting quest_updated for", qid, "-> 'claimed'")
				if QM.has_signal("quest_updated"):
					QM.emit_signal("quest_updated", qid, "claimed")
				claimed_any = true
	if claimed_any:
		if QM.has_method("save"):
			print("[Taara] Calling QuestManager.save() to persist quest state.")
			QM.save()
		_update_done_state()
	return claimed_any

# Modified _on_dialog_complete to ensure we unfreeze and proceed to offer next quest.
func _on_dialog_complete() -> void:
	print("[Taara] _on_dialog_complete() called — checking quests to offer/accept")
	var QM := _get_quest_mgr()

	# debug states (unchanged)
	for qid in quest_ids:
		var q = null
		if QM:
			q = QM.get_quest(qid)
		if q == null:
			print("  -", qid, " -> NULL")
			continue
		var state_str := str(q.state) if "state" in q else "(no state)"
		print("  -", qid, "-> state:", state_str)

	# ---- NEW GUARD: if the player already has ANY active quest from this NPC,
	# ---- do not auto-offer/accept a second one now.
	var any_active := false
	if QM:
		for qid in quest_ids:
			var q2 = QM.get_quest(qid)
			if q2 != null and "state" in q2 and q2.state == "active":
				any_active = true
				break
	if any_active:
		print("[Taara] Player already has an active quest from me; not auto-offering another.")
		_update_done_state()
		# If all are completed, claim / wish flow will still run below; otherwise return to normal dialog behavior.
		if is_done:
			_claim_completed_quests()
			_perform_wish_flow(_current_player)
		else:
			_unfreeze_game()
			_hide_dim_overlay()
			_restore_all_player_prompts()
			is_interacting = false
			_show_prompt(true)
		return
	# ---- END NEW GUARD ----

	# Attempt to auto-offer/accept first available quest (unchanged logic)
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
				# restore game and UI
				_unfreeze_game()
				_hide_dim_overlay()
				_restore_all_player_prompts()
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
		_unfreeze_game()
		_hide_dim_overlay()
		_restore_all_player_prompts()
		is_interacting = false
		_show_prompt(true)

func _on_line_finished() -> void:
	# optional: sound/effect per-line
	pass

func _perform_wish_flow(player: Node) -> void:
	print("[Taara] You proved worthy. Granting wish now.")
	if dlg:
		# during this show_dialog the tree may be paused; DialogBox must be PROCESS during pause
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
		_play_summon()
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
		_play_leave()
		_current_player = null

func _on_area_area_entered(a: Area2D) -> void:
	if a == null:
		return
	_play_summon()
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
		a.show_prompt("Press E", global_position)
		return
	var owner_player := _find_owner_player_from_node(a)
	if owner_player:
		_on_area_body_entered(owner_player)

func _on_area_area_exited(a: Area2D) -> void:
	if a == null:
		return
	_play_leave()
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

func _play_summon() -> void:
	print("playing summon")
	if _taara_anim == null:
		return
	if not _summoned:
		if _taara_anim.sprite_frames and _taara_anim.sprite_frames.has_animation("summon"):
			_taara_anim.play("summon")
		_summoned = true

func _play_leave() -> void:
	print("playing leave")
	if _taara_anim == null:
		return
	if _summoned:
		if _taara_anim.sprite_frames and _taara_anim.sprite_frames.has_animation("leave"):
			_taara_anim.play("leave")
		_summoned = false

func _show_dim_overlay() -> void:
	var cs := get_tree().current_scene
	if cs == null:
		return

	var overlay := cs.get_node_or_null("_TaaraDialogDim")
	if overlay == null:
		overlay = CanvasLayer.new()
		overlay.name = "_TaaraDialogDim"

		# ColorRect sits in UI; make it ignore mouse so clicks go through to dialog.
		var cr := ColorRect.new()
		cr.name = "Dim"
		cr.color = Color(0,0,0,0.45) # tweak alpha here

		# stretch full rect safely (cross-version)
		if cr.has_method("set_anchors_preset"):
			cr.set_anchors_preset(Control.PRESET_FULL_RECT)
		else:
			# fallback - set anchors and offsets directly if preset API missing
			if cr.has_meta("anchor_left"): # just a defensive guard; harmless if false
				pass
			cr.anchor_left = 0
			cr.anchor_top = 0
			cr.anchor_right = 1
			cr.anchor_bottom = 1
			# offsets (in case engine uses them)
			if cr.has_method("set_margin"):
				# some engines expose set_margin, but avoid MARGIN_* constants
				cr.set_margin(0, 0) # not all builds use this; ignore if missing
		# IMPORTANT: ignore mouse so it doesn't block clicks to dialog controls.
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE

		overlay.add_child(cr)
		cs.add_child(overlay)

	# Defensive: if overlay supports pause_mode, set it
	var prop_list := overlay.get_property_list()
	for p in prop_list:
		if typeof(p) == TYPE_DICTIONARY and p.has("name") and p["name"] == "pause_mode":
			if overlay.has_method("set"):
				overlay.set("pause_mode", PAUSE_MODE_PROCESS)
				print("[Taara] set pause_mode on overlay to PAUSE_MODE_PROCESS")
			break

	# Ensure overlay visible
	overlay.visible = true

	# layer management: try to put overlay lower and dialog higher
	if overlay.has_method("set"):
		overlay.set("layer", 0)

	if dlg != null and is_instance_valid(dlg):
		# find an ancestor CanvasLayer for the dialog (or itself)
		var canv := dlg
		while canv and not (canv is CanvasLayer):
			canv = canv.get_parent()
		if canv and canv is CanvasLayer:
			# give dialog layer a higher value than overlay so it draws on top
			var overlay_layer := 0
			if overlay.has_method("get"):
				overlay_layer = overlay.get("layer") if overlay.has_method("get") else 0
			if canv.has_method("set"):
				canv.set("layer", overlay_layer + 1)
				print("[Taara] bumped dialog CanvasLayer to layer", overlay_layer + 1)

		# Also ensure dialog control is front-most and receives focus
		if dlg is Control:
			dlg.raise()
			dlg.grab_focus()

func _hide_dim_overlay() -> void:
	var cs := get_tree().current_scene
	if cs == null:
		return
	var overlay := cs.get_node_or_null("_TaaraDialogDim")
	if overlay:
		overlay.visible = false
	# restore prompts and finish hide flow
	_restore_all_player_prompts()
	_hide_after_dialog()

# Make Taara visible & interactive (called when summoned / teleporting)
func _show_for_summon() -> void:
	self.visible = true
	# restore area interaction so player can interact while present
	if area:
		area.monitoring = true
		area.monitorable = true
	# ensure prompt can appear again
	_show_prompt(true)

func _hide_after_dialog() -> void:
	# play leave animation if you have it
	_play_leave()

	# hide visuals
	self.visible = false

	# remove prompt node entirely so it won't linger
	_clear_all_taara_prompts()

	# remove Taara from current player's interactor so the "Press E" prompt disappears
	if _current_player:
		var interactor = _current_player.find_child("InteractionComponent", true, false)
		if interactor and "can_interact" in interactor and self in interactor.can_interact:
			interactor.can_interact.erase(self)
			if interactor.has_method("_update_prompt"):
				interactor._update_prompt()
			elif interactor.has_method("hide_prompt_for"):
				interactor.hide_prompt_for(self)

	# make absolutely sure the Taara area cannot trigger
	if area:
		area.monitoring = false
		area.monitorable = false

	# clear interacting flag (just in case)
	is_interacting = false

	# clear cached current player reference (prevents stale references)
	_current_player = null

# Call when you want all prompts for Taara to disappear immediately.
func _clear_all_taara_prompts() -> void:
	# 1) Free local prompt node if we created one
	# TaaraNPC._clear_all_taara_prompts() — minimal change: hide prompt instead of freeing
	if prompt:
		if is_instance_valid(prompt):
			# hide the prompt so it won't be visible or interactive
			if prompt.has_method("hide_prompt"):
				prompt.hide_prompt()
			else:
				prompt.visible = false
		# keep the instance around for reuse (no queue_free)
		# But still notify all player Interactors to clear/hide references to this NPC
		var players := get_tree().get_nodes_in_group("Player") + get_tree().get_nodes_in_group("player")
		for p in players:
			if p == null:
				continue
			var interactor := p.find_child("InteractionComponent", true, false)
			if interactor:
				# ask it to hide any prompt for this NPC
				if interactor.has_method("hide_prompt_for"):
					interactor.hide_prompt_for(self)
				elif interactor.has_method("_update_prompt"):
					interactor._update_prompt()

	# 2) If there is a global prompt instance on the scene with a name pattern, remove it.
	var cs := get_tree().current_scene
	if cs:
		for child in cs.get_children():
			if typeof(child) == TYPE_OBJECT:
				var nm := str(child.name).to_lower()
				if nm.find("prompt") != -1 or nm.find("interact") != -1:
					# only remove if it's clearly a UI/control (safety)
					if child is Control or child is Node2D:
						if is_instance_valid(child):
							child.queue_free()

	# 3) Ask any Player InteractionComponent to hide references to this NPC
	var players := get_tree().get_nodes_in_group("Player") + get_tree().get_nodes_in_group("player")
	for p in players:
		if p == null:
			continue
		var interactor := p.find_child("InteractionComponent", true, false)
		if interactor:
			# remove this NPC from can_interact if present
			if "can_interact" in interactor and self in interactor.can_interact:
				interactor.can_interact.erase(self)
			# call typical hide methods if they exist
			if interactor.has_method("hide_prompt_for"):
				interactor.hide_prompt_for(self)
			elif interactor.has_method("_update_prompt"):
				interactor._update_prompt()
			elif interactor.has_method("hide_prompt"):
				interactor.hide_prompt()

# hide every player's prompts (best-effort)
func _hide_all_player_prompts() -> void:
	var players := get_tree().get_nodes_in_group("Player") + get_tree().get_nodes_in_group("player")
	for p in players:
		if p == null:
			continue
		var interactor := p.find_child("InteractionComponent", true, false)
		if interactor:
			if interactor.has_method("hide_all_prompts"):
				interactor.hide_all_prompts()
			elif interactor.has_method("hide_prompt"):
				interactor.hide_prompt()
			elif interactor.has_method("hide_prompt_for"):
				interactor.hide_prompt_for(self)
			elif interactor.has_method("_update_prompt"):
				interactor._update_prompt()

# restore prompts by calling each interactor's update (they'll show prompt if still in range)
func _restore_all_player_prompts() -> void:
	var players := get_tree().get_nodes_in_group("Player") + get_tree().get_nodes_in_group("player")
	for p in players:
		if p == null:
			continue
		var interactor := p.find_child("InteractionComponent", true, false)
		if interactor:
			if interactor.has_method("_update_prompt"):
				interactor._update_prompt()
			elif interactor.has_method("show_prompt"):
				interactor.show_prompt() # best-effort
