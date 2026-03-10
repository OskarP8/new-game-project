extends Node2D
class_name TaaraNPC

signal wish_granted(player: Node)

# Basic NPC data
@export var npc_name := "Taara"
# Accept any resource (simplest, inspector lets you create DialogLine)
@export var greeting_lines: Array[DialogLine] = []
@export var wish_lines: Array[DialogLine] = []
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

# temporary flag to avoid showing prompts when teleporting/summoning Taara
var _suppress_prompts: bool = false
# only show base greeting once per game session (prevents repeating the same lines)
var _greeted_once: bool = false

# dialog instance (cached) — will be resolved at runtime if necessary
var dlg: Node = null
# cache if we've subscribed to quest manager registration
var _connected_to_quest_mgr := false
var _expecting_dialog_from_taara: bool = false

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
	print("[Taara DEBUG] greeting_lines size:", greeting_lines.size())
	for i in range(greeting_lines.size()):
		var entry = greeting_lines[i]
		print("  - index", i, "typeof:", typeof(entry), " ->", entry)
		if typeof(entry) == TYPE_OBJECT:
			# Resource / Object: try to show its fields if present
			if "text" in entry:
				print("     .text =", entry.text)
			if "speaker_name" in entry:
				print("     .speaker_name =", entry.speaker_name)
			if "speaker_role" in entry:
				print("     .speaker_role =", entry.speaker_role)
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
		# keep per-line handler if you want
		if not dlg.is_connected("line_finished", Callable(self, "_on_line_finished")):
			dlg.connect("line_finished", Callable(self, "_on_line_finished"))
		# DO NOT connect dialog_complete here globally - we'll connect per-interaction instead
		print("[Taara] DialogBox resolved ->", dlg)
	else:
		print("[Taara] DialogBox not found yet (will retry on interact).")

func _update_done_state() -> void:
	var QM := _get_quest_mgr()
	if QM == null:
		is_done = false
		return

	var found_any := false
	for qid in quest_ids:
		var q = QM.get_quest(qid)
		if q == null:
			# skip missing quests (do not treat missing as "not completed")
			continue
		found_any = true
		if not ("state" in q) or q.state != "completed":
			is_done = false
			return

	# If we reach here: every existing quest in quest_ids is completed.
	# If none of the quest_ids existed at all, found_any == false -> don't consider "done".
	is_done = found_any
	print("[Taara] _update_done_state -> is_done =", is_done)

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

	# ---------------------------------------------------------
	# Insert this in interact(player) immediately after `_current_player = player`
	# (i.e. before building 'lines' or showing any dialog)
	# ---------------------------------------------------------
	# refresh done-state now — if we're already finished, go straight to wish flow.
	_update_done_state()
	if is_done:
		print("[Taara] interact(): all quests already completed — skipping normal dialog, starting wish flow")
		# prevent other interactions while we run the wish flow
		is_interacting = true
		_show_prompt(false)
		if _current_player:
			_lock_player_controls(_current_player, true)
		# Claim completed quests and persist (safe no-op if nothing to claim)
		_claim_completed_quests()

		# Ensure dlg is resolved so _perform_wish_flow doesn't need to try later
		if dlg == null:
			_resolve_and_connect_dialogbox()

		# start wish flow immediately (use player arg)
		_perform_wish_flow(player)
		return
	# ---------------------------------------------------------
	# then continue with the existing dialog-building code

	var lines: Array = []

	if not _greeted_once:
		for entry in greeting_lines:
			_push_normalized_entry(lines, entry, npc_name, "god")
		print("Taara: prepared lines:", lines)
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
		any_quest_lines = true
	else:
		var q = QM.get_quest(next_qid) if QM and QM.has_method("get_quest") else null
		var title_str = (q.title if q and "title" in q else next_qid)
		if q == null:
			lines.append({"text": "I ask you to: " + title_str, "speaker_name": npc_name, "speaker_role": "god"})
			any_quest_lines = true
		else:
			if q.state == "available":
				# Use same normalizer as greetings so DialogLine resources work, too.
				if "description" in q and q.description != null:
					_append_description_entries(lines, q.description, npc_name, "god")
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

	# lock player controls (movement + attack) immediately for the current player
	if _current_player:
		_lock_player_controls(_current_player, true)

	print("[Taara] Sending lines to DialogBox (count):", lines.size(), " ->", lines)
	if dlg == null:
		_resolve_and_connect_dialogbox()
	if dlg == null:
		print("[Taara] ⚠ DialogBox still not found — aborting show_dialog()")
		_end_interaction_cleanup()
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
	_expecting_dialog_from_taara = true
	if not dlg.is_connected("dialog_complete", Callable(self, "_on_dialog_complete")):
		dlg.connect("dialog_complete", Callable(self, "_on_dialog_complete"))
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

	# Temporarily suppress prompts so area-enter overlap on teleport does not show a prompt.
	_suppress_prompts = true

	# Show Taara (in case we hid it previously)
	_show_for_summon()

	# position Taara exactly at the player's global position (center)
	global_position = player.global_position
	_play_summon()
	# DO NOT call _show_prompt(true) here — prompt should appear only when player approaches.

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
	# Ignore dialog_complete events Taara didn't start
	if not _expecting_dialog_from_taara:
		print("[Taara] dialog_complete received but not expected by Taara -> ignoring")
		return

	# consume the expected event immediately and disconnect our handler
	_expecting_dialog_from_taara = false
	if dlg and dlg.is_connected("dialog_complete", Callable(self, "_on_dialog_complete")):
		dlg.disconnect("dialog_complete", Callable(self, "_on_dialog_complete"))

	print("[Taara] _on_dialog_complete() called — beginning flow")
	var QM := _get_quest_mgr()

	# Always refresh done-state right away to avoid stale info.
	_update_done_state()
	print("[Taara] after _update_done_state -> is_done =", is_done)

	# Debug dump quests so we know what QuestManager actually returns right now
	if QM:
		for qid in quest_ids:
			var q = QM.get_quest(qid)
			print("[Taara DEBUG] quest", qid, "->", q)

	# ---- Guard: don't auto-offer a new quest if player already has one active ----
	var any_active := false
	if QM:
		for qid in quest_ids:
			var q2 = QM.get_quest(qid)
			if q2 != null and "state" in q2 and q2.state == "active":
				any_active = true
				break

	if any_active:
		print("[Taara] Player already has an active quest from me; not auto-offering another.")
		# If not done -> restore UI and return
		if not is_done:
			_end_interaction_cleanup()
			return
		# if done -> fall through to claim + wish below

	# Attempt to auto-offer/accept first available quest
	if QM:
		for qid in quest_ids:
			var q = QM.get_quest(qid)
			if q and "state" in q and q.state == "available":
				var title_str = q.title if "title" in q else qid
				print("[Taara] Offering quest:", qid, "title:", title_str)
				if QM.has_method("accept_quest"):
					QM.accept_quest(qid)
					if dlg == null:
						_resolve_and_connect_dialogbox()
					if dlg:
						dlg.show_dialog(["You accepted: " + title_str], npc_name, "slide_up")
					_end_interaction_cleanup()
					return
				else:
					print("[Taara] ⚠ QuestManager.accept_quest not available")

	# Re-check done-state (safe) and decide wish vs normal end.
	_update_done_state()
	print("[Taara] final is_done after offers check =", is_done)

	if is_done:
		print("[Taara] All my quests are completed -> claiming + performing wish flow")
		_claim_completed_quests()
		# start the wish flow (this will show its own dialog and then run the end sequence)
		_perform_wish_flow(_current_player)
		return

	# Not done and nothing to offer -> normal finish + cleanup
	print("[Taara] No quests to offer and not done -> normal cleanup")
	_end_interaction_cleanup()

func _on_line_finished() -> void:
	# optional: sound/effect per-line
	pass

# place near your other vars
var _wish_dialog_completed: bool = false

func _on_wish_dialog_complete() -> void:
	# mark completed and run end sequence using current player
	_wish_dialog_completed = true
	_run_endgame_sequence(_current_player)

# Godot 4 compatible _perform_wish_flow
func _perform_wish_flow(player: Node) -> void:
	print("[Taara] You proved worthy. Granting wish now.")

	# restore UI state so dialog can show
	_unfreeze_game()
	_hide_dim_overlay()
	_restore_all_player_prompts()

	# keep interacting true while running the flow
	is_interacting = true

	# ensure dlg is valid (try to resolve again)
	if dlg == null or not is_instance_valid(dlg):
		print("taara: dlg was null/invalid at wish time — attempting to resolve again.")
		_resolve_and_connect_dialogbox()

	if dlg == null or not is_instance_valid(dlg):
		# no dialog available — skip showing wish dialog and run end sequence
		print("taara: WARNING: DialogBox still null/invalid. Skipping wish dialog and running end sequence.")
		_run_endgame_sequence(player)
		return

	# build lines defensively (your original code)
	var lines: Array = []
	for entry in wish_lines:
		_push_normalized_entry(lines, entry, npc_name, "god")

	if lines.is_empty():
		lines.append({ "text": "Very well. Your wish shall be granted.", "speaker_name": npc_name, "speaker_role": "god" })

	print("taara: Showing wish dialog (count):", lines.size())

	# --- Instrumented show/await block with debug handlers ---
	print("taara: wish flow start — dlg:", dlg)

	# Defensive info about dlg
	if dlg.has_method("get_path"):
		print("taara: dlg path:", dlg.get_path())

	# Connect a one-off debug handler so we always see when this dlg emits dialog_complete.
	if not dlg.is_connected("dialog_complete", Callable(self, "_taara_debug_dialog_complete")):
		dlg.connect("dialog_complete", Callable(self, "_taara_debug_dialog_complete"))
		print("taara: connected debug dialog_complete handler")

	# Temporarily disconnect the generic handler so it doesn't run for the wish dialog.
	var had_general_handler := false
	if dlg.is_connected("dialog_complete", Callable(self, "_on_dialog_complete")):
		dlg.disconnect("dialog_complete", Callable(self, "_on_dialog_complete"))
		had_general_handler = true
		print("taara: disconnected generic _on_dialog_complete (will restore later)")

	# Connect our wish-specific handler (one-shot style)
	if not dlg.is_connected("dialog_complete", Callable(self, "_on_wish_dialog_complete")):
		dlg.connect("dialog_complete", Callable(self, "_on_wish_dialog_complete"))
		print("taara: connected _on_wish_dialog_complete")

	print("taara: calling dlg.show_dialog(lines_count=", lines.size(), ")")
	dlg.show_dialog(lines, npc_name, "slide_up")

	# wait for the dialog_complete signal
	_wish_dialog_completed = false
	print("taara: awaiting dlg.dialog_complete ...")
	await dlg.dialog_complete
	print("taara: await returned from dlg.dialog_complete — _wish_dialog_completed =", _wish_dialog_completed)

	# cleanup: disconnect wish handler and debug handler
	if dlg.is_connected("dialog_complete", Callable(self, "_on_wish_dialog_complete")):
		dlg.disconnect("dialog_complete", Callable(self, "_on_wish_dialog_complete"))
		if dlg.is_connected("dialog_complete", Callable(self, "_taara_debug_dialog_complete")):
			dlg.disconnect("dialog_complete", Callable(self, "_taara_debug_dialog_complete"))
			print("taara: disconnected wish & debug handlers")

	# restore original general handler if we removed it
	if had_general_handler:
		if not dlg.is_connected("dialog_complete", Callable(self, "_on_dialog_complete")):
			dlg.connect("dialog_complete", Callable(self, "_on_dialog_complete"))
		print("taara: restored generic _on_dialog_complete")
	else:
		print("taara: no generic handler to restore")

	# If the wish handler didn't set the flag for some reason, run the end sequence here.
	if not _wish_dialog_completed:
		print("taara: WARNING: _wish_dialog_completed false after await — running end sequence.")
		_run_endgame_sequence(player)
		return

	print("taara: wish flow finished normally.")

# ----- Area2D handlers (connect these) -----
func _on_area_body_entered(body: Node) -> void:
	if body == null:
		return
	# top of _on_area_body_entered
	if _suppress_prompts or is_interacting or not visible:
		_current_player = body if (body is Node and (body.is_in_group("player") or body.is_in_group("Player"))) else _current_player
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
			# Prefer explicit hide while interactor still references this NPC
			if interactor.has_method("hide_prompt_for"):
				print("[Taara] calling interactor.hide_prompt_for(self) on body_exited")
				interactor.hide_prompt_for(self)
			elif interactor.has_method("hide_prompt"):
				print("[Taara] calling interactor.hide_prompt() on body_exited")
				interactor.hide_prompt()

			# Now remove from can_interact and ask for an update
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
	# If suppressed, avoid adding to area/interactor prompt lists
	# top of _on_area_area_entered
	if _suppress_prompts or is_interacting or not visible:
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
		# try to hide first
		if a.has_method("hide_prompt_for"):
			print("[Taara] calling area.hide_prompt_for(self) on area_exited")
			a.hide_prompt_for(self)
		elif a.has_method("hide_prompt"):
			print("[Taara] calling area.hide_prompt() on area_exited")
			a.hide_prompt()

		# then remove reference and update
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
	# ---- clear suppression next idle (one-shot) ----
	if _suppress_prompts:
		call_deferred("_clear_suppress_prompts")

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
	# DO NOT show prompt when summoned by other systems (checkpoint). Prompt should appear only
	# when player enters the InteractionArea or their interactor decides to show it.
	# _show_prompt(true)

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
		if interactor:
			# 1) ask interactor to hide any prompt for this NPC first (preferred)
			if interactor.has_method("hide_prompt_for"):
				print("[Taara] asking interactor to hide_prompt_for(self)")
				interactor.hide_prompt_for(self)
			elif interactor.has_method("hide_prompt"):
				print("[Taara] asking interactor to hide_prompt()")
				interactor.hide_prompt()
			# 2) then remove from can_interact so it won't be suggested again
			if "can_interact" in interactor and self in interactor.can_interact:
				interactor.can_interact.erase(self)
			# 3) force an update so the interactor can clean up any lingering UI
			if interactor.has_method("_update_prompt"):
				interactor._update_prompt()

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
	# 1) Hide (don't free) the local prompt instance so other code never gets a freed object.
	if prompt:
		if is_instance_valid(prompt):
			if prompt.has_method("hide_prompt"):
				prompt.hide_prompt()
			else:
				# safe fallback: hide visually
				if prompt is CanvasItem:
					prompt.visible = false
		# keep the instance around for reuse (do not queue_free)
		# we still notify players below.

	# 2) DO NOT queue_free() scene-wide prompt nodes. ONLY hide them.
	var cs := get_tree().current_scene
	if cs:
		for child in cs.get_children():
			# best-effort: only hide nodes that look like prompts, do NOT free them
			if typeof(child) == TYPE_OBJECT:
				var nm := str(child.name).to_lower()
				if nm.find("prompt") != -1 or nm.find("interact") != -1:
					if is_instance_valid(child):
						if child.has_method("hide_prompt"):
							child.hide_prompt()
						elif child is CanvasItem:
							child.visible = false

	# 3) Ask any Player InteractionComponent to hide references to this NPC and remove this NPC from can_interact
	var players := get_tree().get_nodes_in_group("Player") + get_tree().get_nodes_in_group("player")
	for p in players:
		if p == null:
			continue
		var interactor := p.find_child("InteractionComponent", true, false)
		if not interactor:
			continue
		# remove this NPC from can_interact if present (so it won't be suggested any more)
		if "can_interact" in interactor and self in interactor.can_interact:
			interactor.can_interact.erase(self)
		# prefer targeted hide call if component provides it
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

func _clear_suppress_prompts() -> void:
	# simple one-shot clear — don't loop here
	_suppress_prompts = false

# Helper: normalize an entry and append to out array.
# Accepts:
#  - String -> becomes dict with default speaker/role
#  - Dictionary -> uses its fields but fills missing/empty ones with defaults
#  - DialogLine (Resource) -> uses its exported fields
func _push_normalized_entry(out: Array, entry, default_speaker: String, default_role: String = "narrator") -> void:
	# String
	if typeof(entry) == TYPE_STRING:
		out.append({"text": str(entry), "speaker_name": default_speaker, "speaker_role": default_role})
		return

	# Dictionary
	if typeof(entry) == TYPE_DICTIONARY:
		var e = entry.duplicate(true)
		if not e.has("text"):
			e["text"] = ""
		if not e.has("speaker_name") or str(e["speaker_name"]).strip_edges() == "":
			e["speaker_name"] = default_speaker
		if not e.has("speaker_role") or str(e["speaker_role"]).strip_edges() == "":
			e["speaker_role"] = default_role
		out.append(e)
		return

	# Object / Resource (e.g. DialogLine)
	if typeof(entry) == TYPE_OBJECT:
		var text_val := ""
		var sp_name := default_speaker
		var sp_role := default_role

		# 1) If it's a Dictionary-like object (some resources can behave that way), prefer that.
		if entry is Dictionary:
			# defensive, though this branch rarely triggers for Resource
			var d = entry
			if d.has("text"):
				text_val = str(d["text"])
			if d.has("speaker_name") and str(d["speaker_name"]).strip_edges() != "":
				sp_name = str(d["speaker_name"])
			if d.has("speaker_role") and str(d["speaker_role"]).strip_edges() != "":
				sp_role = str(d["speaker_role"])
		else:
			# 2) Try single-arg get(...) (safe for Resource/Object)
			#    Note: Object.get expects 1 arg — DO NOT pass a default value here.
			if entry.has_method("get"):
				var t = entry.get("text")
				if t != null and str(t).strip_edges() != "":
					text_val = str(t)
				var n = entry.get("speaker_name")
				if n != null and str(n).strip_edges() != "":
					sp_name = str(n)
				var r = entry.get("speaker_role")
				if r != null and str(r).strip_edges() != "":
					sp_role = str(r)

			# 3) Fallback to direct property access (works for exported Resource vars)
			#    (only if we still don't have values)
			if text_val == "" and "text" in entry:
				text_val = str(entry.text)
			if sp_name == default_speaker and "speaker_name" in entry and str(entry.speaker_name).strip_edges() != "":
				sp_name = str(entry.speaker_name)
			if sp_role == default_role and "speaker_role" in entry and str(entry.speaker_role).strip_edges() != "":
				sp_role = str(entry.speaker_role)

		# Final fallback for text
		if text_val == "":
			text_val = str(entry)

		out.append({"text": text_val, "speaker_name": sp_name, "speaker_role": sp_role})
		return

	# Anything else -> coerce to string
	out.append({"text": str(entry), "speaker_name": default_speaker, "speaker_role": default_role})

# Helper: append quest description(s) to out using the same normalizer used for greetings.
# Accepts: Array[DialogLine] OR Array[String] OR single String/Dictionary/Resource
func _append_description_entries(out: Array, desc, default_speaker: String, default_role: String = "god") -> void:
	# if null -> nothing
	if desc == null:
		return

	# If it's an Array, iterate elements and normalize each
	if typeof(desc) == TYPE_ARRAY:
		for elem in desc:
			_push_normalized_entry(out, elem, default_speaker, default_role)
		return

	# If it's a string or dict or resource, just normalize one entry
	_push_normalized_entry(out, desc, default_speaker, default_role)

# ---- Endgame / wish sequence helpers ----

# Try to lock or unlock player controls using a few common APIs.
func _lock_player_controls(player: Node, locked: bool) -> void:
	if player == null:
		return
	# 1) explicit API
	if player.has_method("set_control_enabled"):
		player.call("set_control_enabled", not locked)
	# 2) boolean flags (movement)
	elif "can_move" in player:
		player.can_move = not locked
	elif "controls_enabled" in player:
		player.controls_enabled = not locked
	# 3) fallback: toggle process/physics_process (may disable animations too)
	if player.has_method("set_physics_process"):
		player.set_physics_process(not locked)
	if player.has_method("set_process"):
		player.set_process(not locked)

	# 4) common attack flags / API (try to disable attacking)
	if "can_attack" in player:
		player.can_attack = not locked
	if "attack_enabled" in player:
		player.attack_enabled = not locked
	if player.has_method("set_attack_enabled"):
		player.call("set_attack_enabled", not locked)


# Create (or reuse) a simple endgame overlay in the current scene:
func _create_endgame_overlay() -> CanvasLayer:
	var cs := get_tree().current_scene
	if cs == null:
		cs = get_tree().get_root()

	# reuse if present
	var existing := cs.get_node_or_null("_TaaraEndgameOverlay")
	if existing and is_instance_valid(existing):
		return existing as CanvasLayer

	var overlay := CanvasLayer.new()
	overlay.name = "_TaaraEndgameOverlay"
	# ensure it draws on top
	if overlay.has_method("set"):
		overlay.set("layer", 1000)

	# full-screen ColorRect (fade)
	var cr := ColorRect.new()
	cr.name = "Fade"
	cr.color = Color(0,0,0,0) # start transparent
	# stretch full rect
	if cr.has_method("set_anchors_preset"):
		cr.set_anchors_preset(Control.PRESET_FULL_RECT)
	else:
		cr.anchor_left = 0
		cr.anchor_top = 0
		cr.anchor_right = 1
		cr.anchor_bottom = 1
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(cr)

	# CenterContainer + RichTextLabel so we can control size easily via bbcode
	var center := CenterContainer.new()
	center.name = "Center"
	if center.has_method("set_anchors_preset"):
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
	else:
		center.anchor_left = 0
		center.anchor_top = 0
		center.anchor_right = 1
		center.anchor_bottom = 1
	overlay.add_child(center)

	# Use RichTextLabel (bbcode) so we can set a large font size and center reliably
	var rtl := RichTextLabel.new()

	var font_file := load("res://exepixelperfect.medium.ttf") as FontFile
	rtl.add_theme_font_override("normal_font", font_file)
	rtl.add_theme_font_size_override("normal_font_size", 56)

	rtl.name = "ThankYou"
	rtl.visible = false
	rtl.bbcode_enabled = true
	rtl.scroll_active = false            # no scrolling
	# (removed invalid: rtl.fit_content_height = true)
	rtl.custom_minimum_size = Vector2(900, 200)
	rtl.bbcode_text = "[center]Thank you for playing![/center]"
	rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(rtl)

	cs.add_child(overlay)
	return overlay


# Run the full endgame sequence.
func _run_endgame_sequence(player: Node) -> void:
	# safety guards
	if is_instance_valid(player) == false:
		player = null

	# Ensure dialog is closed / UI restored and game unpaused
	_unfreeze_game()
	_hide_dim_overlay()
	_restore_all_player_prompts()
	is_interacting = false

	# Lock player's controls so they can't move while we do the fade
	_lock_player_controls(player, true)

	# create overlay
	var overlay := _create_endgame_overlay()
	var fade_rect := overlay.get_node("Fade") as ColorRect
	var center := overlay.get_node("Center") as CenterContainer
	var thank_lbl := center.get_node("ThankYou") as RichTextLabel if center and center.has_node("ThankYou") else null
	# Short delay so the player sees dialog close
	await get_tree().create_timer(0.35).timeout

	# Fade to black (0 => 1 alpha over 1.0s)
	if fade_rect:
		fade_rect.visible = true
		var tw = get_tree().create_tween()
		tw.tween_property(fade_rect, "color", Color(0,0,0,1.0), 1.0).from(Color(0,0,0,0))
		await tw.finished

	# Show thank you text with a fade-in
	if thank_lbl:
		thank_lbl.visible = true
		var tw2 = get_tree().create_tween()
		tw2.tween_property(thank_lbl, "modulate", Color(1,1,1,1), 0.6).from(Color(1,1,1,0))
		await tw2.finished

	# --- CHANGE SCENE WHILE THANK YOU IS VISIBLE ---
	# Give a short readable pause (optional), then change scene immediately while overlay is still on screen.
	# Adjust "delay_seconds" to keep the text on-screen longer before switching.
	var delay_seconds := 3
	await get_tree().create_timer(delay_seconds).timeout

	# Unlock controls & cleanup AFTER initiating scene change (optional; change happens immediately)
	# If scene switch is instantaneous for you, you can do cleanup before or after — this keeps it tidy.
	_lock_player_controls(player, false)

	# Change to main menu while the thank you is visible
	var menu_path := "res://scenes/start_screen.tscn"
	if ResourceLoader.exists(menu_path):
		get_tree().change_scene_to_file(menu_path)
	else:
		print("[Taara] _run_endgame_sequence: main menu scene not found at", menu_path, "- not changing scene.")

	# (optional) don't run the fade-back in this branch because we already changed scene
	# Cleanup overlay if the scene didn't change
	if not ResourceLoader.exists(menu_path):
		# fade overlay back to transparent (0.8s) before cleaning up
		if fade_rect:
			var tw3 = get_tree().create_tween()
			tw3.tween_property(fade_rect, "color", Color(0,0,0,0), 0.8).from(Color(0,0,0,1))
			await tw3.finished

		_lock_player_controls(player, false)
		if overlay and is_instance_valid(overlay):
			overlay.queue_free()

# debug helper — puts "taara" at start so your log filter catches it
func _taara_debug_dialog_complete() -> void:
	print("taara: _taara_debug_dialog_complete() fired on dlg ->", dlg)

func _end_interaction_cleanup() -> void:
	# Save the current player reference now because _hide_dim_overlay()
	# (-> _hide_after_dialog()) may clear _current_player.
	var player_to_unlock := _current_player

	# restore pause/UI state first
	_unfreeze_game()
	_hide_dim_overlay()
	_restore_all_player_prompts()

	# unlock the player we saved (if any)
	if player_to_unlock:
		_lock_player_controls(player_to_unlock, false)

	is_interacting = false
