# IntroManager.gd  (verbose, fallback-heavy)
extends Node

@export var intro_lines: Array = [
	"For weeks, the Iron Men have been terrorising the village.",
	"They march without rest, and their metal footsteps echo through the night.",
	"The elders spoke your name.",
	"Not because you were the strongest...<pause=0.5> but because you were the only villager in the village.",
	"You have been chosen to seek the god Taara beneath the great oak.",
	"Follow the road until you reach the big tree."
]

@export var delay_before_show: float = 2.0
@export var dlg_search_tries: int = 60
@export var dlg_search_interval: float = 0.05

var _shown := false

func _ready() -> void:
	print("[IntroManager] _ready() entered")
	call_deferred("_try_show_intro")

# top of file: match this to your SaveData path
const SAVE_DATA_PATH := "res://scripts/SaveData.gd"
const SAVE_FILE := "user://save.tres"
var SaveDataResource := preload(SAVE_DATA_PATH)

# Add this function (non-nested) anywhere in the file:
func _persist_intro_shown_direct() -> void:
	# Try to load existing save resource, otherwise create new one
	var save_res: Resource = null
	if FileAccess.file_exists(SAVE_FILE):
		save_res = ResourceLoader.load(SAVE_FILE)
	# If load failed or it's not the expected type, create a fresh resource
	if not save_res or not (save_res is Resource):
		save_res = SaveDataResource.new()
	# Defensive: if resource lacks the field, add it if possible (resources are dynamic)
	# Set fields we care about (only modify what we intend)
	if save_res.has_method("set"):
		# generic set, works if resource wrapper exposes set()
		save_res.set("intro_shown", true)
	else:
		# in case typed resource, try direct property (some resource classes expose the field)
		save_res.intro_shown = true

	# Keep other fields if present; you could also attempt to preserve inventory/opened_chests if available.
	var err := ResourceSaver.save(save_res, SAVE_FILE)
	if err != OK:
		push_error("[IntroManager] Direct persist FAILED (err=%s)" % str(err))
	else:
		print("[IntroManager] Direct persist succeeded -> wrote intro_shown=true to", SAVE_FILE)

# Safely read the saved intro_shown flag from disk (fallback when GameState not yet available)
func _read_intro_shown_from_save_file() -> bool:
	if not FileAccess.file_exists(SAVE_FILE):
		return false
	var res := ResourceLoader.load(SAVE_FILE)
	if not res:
		print("[IntroManager] _read_intro_shown_from_save_file -> ResourceLoader.load returned null")
		return false

	# try generic get() first (works with Resource wrappers)
	if res.has_method("get"):
		var val = res.get("intro_shown")
		return bool(val) if val != null else false

	# fallback property access
	if "intro_shown" in res:
		return bool(res.intro_shown)
	return false

# find first node in a tree that has the given method name
func _find_node_with_method(root_node: Node, method_name: String) -> Node:
	if root_node == null:
		return null
	# check root_node itself
	if root_node.has_method(method_name):
		return root_node
	# BFS search (limit depth by engine) - use find_node? but we need method check
	var nodes := [root_node]
	while nodes.size() > 0:
		var n = nodes.pop_front()
		# skip null
		if n == null:
			continue
		if n.has_method(method_name):
			return n
		for child in n.get_children():
			# only Node types
			if child is Node:
				nodes.append(child)
	return null

func _try_show_intro() -> void:
	print("[IntroManager] _try_show_intro() start - _shown =", _shown)

	if _shown:
		print("[IntroManager] already shown -> returning")
		return

	# wait a frame for autoloads to run
	await get_tree().process_frame

	# wait for GameState to be present and for load to finish (short loop)
	var attempts := 0
	while not Engine.has_singleton("GameState") and attempts < 50:
		await get_tree().create_timer(0.02).timeout
		attempts += 1
	if not Engine.has_singleton("GameState"):
		print("[IntroManager] WARNING: GameState not present after wait; continuing but GameState calls will be skipped")

	# If GameState says intro already shown, skip and log
	if Engine.has_singleton("GameState") and GameState.has_method("is_intro_shown") and GameState.is_intro_shown():
		_shown = true
		print("[IntroManager] skipping intro: GameState.is_intro_shown() returned true")
		return

	# If GameState is missing, check on-disk save as a fallback
	if not Engine.has_singleton("GameState"):
		var disk_intro := _read_intro_shown_from_save_file()
		if disk_intro:
			_shown = true
			print("[IntroManager] skipping intro: on-disk save says intro_shown == true")
			return
		else:
			print("[IntroManager] on-disk save reports intro_shown == false (or missing); will attempt to show intro")

	# try to find a DialogBox-like node in multiple places
	var dlg: Node = null

	# 1) direct current_scene child named DialogBox
	if get_tree().current_scene != null:
		dlg = get_tree().current_scene.get_node_or_null("DialogBox")
		if dlg:
			print("[IntroManager] Found DialogBox as direct child of current_scene:", dlg)

	# 2) search root for node named DialogBox
	if dlg == null:
		dlg = get_tree().root.find_node("DialogBox", true, false)
		if dlg:
			print("[IntroManager] Found DialogBox via root.find_node:", dlg)

	# 3) search for node that has common dialog methods
	var candidate_methods := ["show_dialog", "start_dialog", "open_dialog", "show_lines", "show"]
	if dlg == null:
		for m in candidate_methods:
			# search current_scene then entire root
			if get_tree().current_scene != null:
				var n := _find_node_with_method(get_tree().current_scene, m)
				if n != null:
					dlg = n
					print("[IntroManager] Found node in current_scene with method '%s': %s" % [m, dlg])
					break
			var n2 := _find_node_with_method(get_tree().root, m)
			if n2 != null:
				dlg = n2
				print("[IntroManager] Found node in root with method '%s': %s" % [m, dlg])
				break

	# 4) last attempt: find any node with a 'dialog_complete' signal (heuristic)
	if dlg == null:
		var all_nodes := []
		# gather first-level children of current scene and root to avoid massive loops
		if get_tree().current_scene != null:
			all_nodes += get_tree().current_scene.get_children()
		all_nodes += get_tree().root.get_children()
		for n in all_nodes:
			if n is Node and n.has_signal("dialog_complete"):
				dlg = n
				print("[IntroManager] Found node with 'dialog_complete' signal as fallback:", dlg)
				break

	# Retry loop if still null (some UIs are created later)
	var tries := 0
	while dlg == null and tries < dlg_search_tries:
		await get_tree().create_timer(dlg_search_interval).timeout
		# re-run same search (compact)
		if get_tree().current_scene != null:
			dlg = get_tree().current_scene.get_node_or_null("DialogBox")
		if dlg == null:
			dlg = get_tree().root.find_node("DialogBox", true, false)
		if dlg == null:
			for m in candidate_methods:
				if get_tree().current_scene != null:
					var n := _find_node_with_method(get_tree().current_scene, m)
					if n != null:
						dlg = n
						break
				var n2 := _find_node_with_method(get_tree().root, m)
				if n2 != null:
					dlg = n2
					break
		tries += 1

	if dlg == null:
		push_warning("[IntroManager] DialogBox not found after retries; will print intro lines to console as fallback.")
		# fallback: print lines to console so at least we confirm the text
		print("[IntroManager] --- INTRO LINES (fallback) ---")
		for l in intro_lines:
			print(l)
		print("[IntroManager] ----------------------------")
		# mark shown so it won't keep retrying in a loop
		_shown = true
		# persist that we showed it (best-effort)
		_mark_intro_shown_and_persist()
		return

	# We have a dlg node. Print its type + what methods/signals it has (debug)
	print("[IntroManager] Using dialog node:", dlg, " class:", dlg.get_class())
	for m in candidate_methods:
		if dlg.has_method(m):
			print("[IntroManager] dialog node HAS method:", m)
	if dlg.has_signal("dialog_complete"):
		print("[IntroManager] dialog node HAS signal: dialog_complete")

	# optional tiny delay before showing
	if delay_before_show > 0.0:
		await get_tree().create_timer(delay_before_show).timeout

	# Attempt to call typical dialog methods with a few arg patterns using callv (safe)
	var shown_success := false
	var tried_calls := []

	# 1) try show_dialog(intro_lines, "", "pop")
	if dlg.has_method("show_dialog"):
		tried_calls.append("show_dialog([lines, '', 'pop'])")
		var ok := false
		# try different argument patterns
		for args in [[intro_lines, "", "pop"], [intro_lines, ""], [intro_lines]]:
			var res = dlg.callv("show_dialog", args)
			print("[IntroManager] callv show_dialog with args count %d returned: %s" % [args.size(), str(res)])
			shown_success = true
			ok = true
			break
		if ok:
			# we called it
			pass

	# 2) try start_dialog / open_dialog / show_lines / show
	if not shown_success:
		for mname in ["start_dialog", "open_dialog", "show_lines", "show"]:
			if dlg.has_method(mname):
				tried_calls.append(mname + "(lines)")
				var res = dlg.callv(mname, [intro_lines])
				print("[IntroManager] callv %s returned: %s" % [mname, str(res)])
				shown_success = true
				break

	# Final check: if shown_success is still false, attempt to set a property 'lines' then call 'play' or 'start'
	if not shown_success:
		if dlg.has_method("set_lines") or "lines" in dlg:
			print("[IntroManager] Trying to set lines via property/method fallback")
			if dlg.has_method("set_lines"):
				dlg.callv("set_lines", [intro_lines])
			else:
				# try to set a simple property if exposed, or use generic set() if available
				if dlg.has_method("set"):
					# generic setter often takes (name, value)
					dlg.callv("set", ["lines", intro_lines])
				elif "lines" in dlg:
					dlg.lines = intro_lines
				else:
					print("[IntroManager] No 'set' method or 'lines' property available on dlg; skipping direct lines set")

			# attempt a 'play' or 'start' call
			for m2 in ["play", "start", "open"]:
				if dlg.has_method(m2):
					dlg.callv(m2, [])
					print("[IntroManager] called fallback method:", m2)
					shown_success = true
					break

	# If we still failed to show, print fallback and stop retrying
	if not shown_success:
		push_warning("[IntroManager] Failed to call any dialog show method. Tried: %s" % str(tried_calls))
		print("[IntroManager] As fallback printing the intro lines (again):")
		for l in intro_lines:
			print(l)
		_shown = true
		_mark_intro_shown_and_persist()
		return

	# If we get here, we attempted to show the dialog. Mark shown runtime now.
	_shown = true
	print("[IntroManager] dialog show attempted -> marking shown and persisting")

	# Persist after showing
	_mark_intro_shown_and_persist()

	# If dialog emits dialog_complete, wait for it and then log, otherwise just return
	if dlg.has_signal("dialog_complete"):
		print("[IntroManager] waiting for dlg.dialog_complete signal")
		await dlg.dialog_complete
		print("[IntroManager] dialog_complete received")
	else:
		print("[IntroManager] dlg had no dialog_complete signal; not waiting")

func _mark_intro_shown_and_persist() -> void:
	# Prefer GameState if available, otherwise fall back to direct disk write
	if Engine.has_singleton("GameState") and GameState.has_method("set_intro_shown"):
		print("[IntroManager] Marking intro shown via GameState")
		GameState.set_intro_shown(true)
		if GameState.has_method("save"):
			var rc := GameState.save()
			print("[IntroManager] GameState.save() returned:", rc)
	else:
		_persist_intro_shown_direct()
