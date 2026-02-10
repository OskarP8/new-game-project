# res://globals/GameState.gd
extends Node

const SAVE_PATH : String = "user://save.tres"
const SaveDataResource := preload("res://scripts/SaveData.gd")  # <-- keep your exact path

# Runtime checkpoint
var checkpoint_scene: String = ""
var checkpoint_position: Vector2 = Vector2.ZERO
# re-entrancy guard to avoid recursive saves
var _saving: bool = false

# Persistent save (what's on disk / last saved)
var saved_scene: String = ""
var saved_position: Vector2 = Vector2.ZERO
# res://globals/GameState.gd (near top)
var saved_inventory: Array = []        # existing (player)
var saved_main_inventory: Array = []   # NEW (main backpack)


# Runtime record of opened chests (keeps in-memory and saved to disk)
var opened_chests: Array = []
# Simple item registry: id -> Resource path (string) OR preloaded Resource
var item_registry : Dictionary = {}
# ---------- near top, helper for safe root access ----------
func _get_root() -> Node:
	var t = get_tree()
	if t == null:
		return null
	return t.root if t.root != null else null

func _ready() -> void:
	# DUPLICATE DETECTION (temporary diagnostic)
	var id_str = "GameState.instance_id:%s" % str(self.get_instance_id())
	print("[GameState] _ready() ->", id_str)
	# look for other GameState nodes anywhere (helps detect accidental multiple instances)
	var found := []
	var root = _get_root()
	if root:
		for n in root.get_children():
			if n.get_class() == get_class() and n != self:
				found.append(n)
	if found.size() > 0:
		print("[GameState] WARNING: found other GameState instances in root -> count:", found.size())
		for o in found:
			print("[GameState] other instance id:", str(o.get_instance_id()), "owner_scene:", (o.get_owner().get_filename() if o.get_owner() else "NO_OWNER"))

	# (rest of your original _ready flow...)
	# auto-register .tres item resources (so registry resolves saved .tscn -> InvItem resource)
	_auto_register_items_from_folder("res://resources")   # <-- change path if your resources are elsewhere
	print("[GameState] registry sample:", item_registry.keys())

	# optional: existing manual registrations (you can keep or remove)
	register_item("pitchfork", "res://resources/pitchfork_res.tres")
	register_item("sword", "res://resources/sword.tres")

	# now load existing save (with registry ready)
	load_save()
	print("[GAMESTATE] saved_main_inventory len:", saved_main_inventory.size())

	# Connect to about_to_quit so clicking X triggers a save (defensive)
	var t = get_tree()
	if t and t.has_signal("about_to_quit"):
		if not t.is_connected("about_to_quit", Callable(self, "save")):
			t.connect("about_to_quit", Callable(self, "save"))

func _save_err_str(code: int) -> String:
	match code:
		OK: return "OK"
		ERR_CANT_OPEN: return "ERR_CANT_OPEN"
		ERR_CANT_CREATE: return "ERR_CANT_CREATE"
		ERR_FILE_CANT_WRITE: return "ERR_FILE_CANT_WRITE"
		ERR_UNAVAILABLE: return "ERR_UNAVAILABLE"
		ERR_INVALID_PARAMETER: return "ERR_INVALID_PARAMETER"
		_:
			return str(code)

# safer auto-register that prints what script a .tres references
func _auto_register_items_from_folder(folder_path: String = "res://resources") -> void:
	var dir := DirAccess.open(folder_path)
	if dir == null:
		print("[GameState] _auto_register_items_from_folder: folder not found:", folder_path)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	var registered := 0
	while fname != "":
		if fname == "." or fname == "..":
			fname = dir.get_next()
			continue
		if not dir.current_is_dir() and fname.to_lower().ends_with(".tres"):
			var full := folder_path
			if not full.ends_with("/"):
				full += "/"
			full += fname
			var r := ResourceLoader.load(full)
			if r == null:
				print("[GameState] _auto_register: failed load:", full)
			else:
				# print diagnostics
				var script_path := "NONE"
				if r.has_method("get_script") and r.get_script() != null:
					var sr = r.get_script()
					script_path = sr.resource_path if "resource_path" in sr else str(sr)
				print("[GameState] _auto_register: loaded_as:", r.get_class(), "script:", script_path)
				# register if resource looks like our InvItem
				if _is_invitem_like(r):
					# register by full resource path
					item_registry[full] = r
					registered += 1
					# also register by scene_path if present
					if ("scene_path" in r) and str(r.scene_path) != "":
						item_registry[str(r.scene_path)] = r
					# *** NEW: register by id if resource exposes it (prefer id lookups) ***
					if "id" in r and str(r.id) != "":
						item_registry[str(r.id)] = r
		fname = dir.get_next()
	dir.list_dir_end()
	print("[GameState] _auto_register_items_from_folder: registered", registered, "items from", folder_path)

func save_game(scene_path: String = "", pos: Vector2 = Vector2.ZERO, force: bool = false) -> void:
	# Guard against re-entry
	if _saving:
		print("[GameState] 🔁 save_game() re-entry detected — skipping")
		return
	_saving = true

	var root = _get_root()
	print_debug("[GameState] save_game() start; looking for inv_ui and player_node")

	var player_node = root.find_child("Player", true, false) if root else null
	print_debug("[GameState] player_node:", str(player_node))
	print_debug("[GameState] current runtime inventory arrays len:", str(saved_inventory.size()), " main:", str(saved_main_inventory.size()))

	var inv_ui = root.find_child("Inv_UI", true, false) if root else null
	# Prefer synchronous flush for deterministic snapshot (avoid call_deferred race)
	var inv_ui_for_save = null
	
	print("[GameState] save_game() snapshot start — GameState id:", self.get_instance_id())
	print_debug("[GameState] found inv_ui node:", inv_ui, " player_node:", player_node)
	if player_node and player_node.has_method("get_inventory"):
		var p_inv = player_node.get_inventory()
		print("[GameState] player.inventory object:", p_inv, "path:", (p_inv.resource_path if p_inv else "NULL"), "slots:", (p_inv.slots.size() if p_inv and 'slots' in p_inv else 0))

	if inv_ui != null:
		# If flush_to_model exists, call it synchronously so data is written to model now.
		if inv_ui.has_method("flush_to_model"):
			inv_ui.flush_to_model()
			# allow a single frame to complete any UI side-effects that flush_to_model may trigger
			await get_tree().process_frame
		inv_ui_for_save = inv_ui
	# debug the authoritative inv resource we will use for saving (after assignment)
	if inv_ui_for_save and inv_ui_for_save.inv:
		var ui_inv = inv_ui_for_save.inv
		print("[GameState] Inv_UI.inv object (authoritative):", ui_inv, "path:", (ui_inv.resource_path if ui_inv else "NULL"), "slots:", (ui_inv.slots.size() if ui_inv and 'slots' in ui_inv else 0))

	var player_snapshot: Array = []
	var player_slot_count: int = 0
	if player_node:
		if player_node.has_method("get_inventory_snapshot") and player_node.has_method("get_inventory_slot_count"):
			player_snapshot = player_node.get_inventory_snapshot().duplicate(true)
			player_slot_count = player_node.get_inventory_slot_count()
			print_debug("[GameState] obtained snapshot from player len:", str(player_snapshot.size()), " slots:", str(player_slot_count))
		else:
			print_debug("[GameState] player_node present but missing snapshot methods")

	if player_snapshot.size() == 0:
		if inv_ui and inv_ui.has_method("flush_to_model"):
			inv_ui.flush_to_model()
			if player_node and player_node.has_method("get_inventory_snapshot") and player_node.has_method("get_inventory_slot_count"):
				player_snapshot = player_node.get_inventory_snapshot().duplicate(true)
				player_slot_count = player_node.get_inventory_slot_count()
				print_debug("[GameState] after flush, snapshot len:", str(player_snapshot.size()), " slots:", str(player_slot_count))

	# Avoid clobbering saved arrays if nothing to snapshot (unless forced)
	if not force and player_snapshot.size() == 0 and inv_ui == null and player_node == null:
		print("[GameState] save_game: no inv_ui and no player_node present, skipping snapshot write to avoid clobbering (use force=true to override)")
		_saving = false
		return

	# derive scene/pos if not provided
	if scene_path == "":
		if has_checkpoint():
			scene_path = checkpoint_scene
			pos = checkpoint_position
		elif get_tree() and get_tree().current_scene:
			scene_path = get_tree().current_scene.scene_file_path

	var save_res := SaveDataResource.new()
	save_res.scene_path = scene_path if scene_path != null else ""
	save_res.position = pos if pos != null else Vector2.ZERO
	save_res.saved_at_unix = Time.get_unix_time_from_system()

	var inventory_array: Array = []

	if player_snapshot and player_snapshot.size() > 0:
		inventory_array = player_snapshot.duplicate(true)
		print_debug("[GameState] using player snapshot for save; len:", inventory_array.size())

	if inventory_array.size() == 0 and inv_ui_for_save and inv_ui_for_save.inv and "slots" in inv_ui_for_save.inv and inv_ui_for_save.inv.slots.size() > 0:
		print_debug("[GameState] building inventory_array from Inv_UI.inv.slots (authoritative)")
		for slot in inv_ui_for_save.inv.slots:
			if slot == null or slot.item == null:
				inventory_array.append({"scene_path":"", "amount":0})
				continue
			# debug: show if slot.item present and its type/path
			if slot.item == null:
				print_debug("[GameState] save: slot.item == NULL (empty slot)")
			else:
				var _it = slot.item
				print_debug("[GameState] save: slot.item present -> class:", (_it.get_class() if _it else "NULL"), "id:", (_it.id if "id" in _it else "NO_ID"), "resource_path:", (_it.resource_path if "resource_path" in _it else "NO_RP"), "scene_path:", (_it.scene_path if "scene_path" in _it else "NO_SCENE"))

			var item_obj = slot.item
			var item_path := ""
			if "id" in item_obj and str(item_obj.id) != "":
				item_path = "id:" + str(item_obj.id)
			elif "resource_path" in item_obj and str(item_obj.resource_path) != "":
				item_path = str(item_obj.resource_path)
			elif "scene_path" in item_obj and str(item_obj.scene_path) != "":
				item_path = str(item_obj.scene_path)
			elif "name" in item_obj:
				item_path = "name:" + str(item_obj.name)
			else:
				item_path = "unknown"
			inventory_array.append({"scene_path": item_path, "amount": int(slot.amount if "amount" in slot else 1)})

	if inventory_array.size() == 0:
		if saved_inventory != null and saved_inventory.size() > 0:
			inventory_array = saved_inventory.duplicate(true)
			print("[GameState] save_game: fallback -> using in-memory saved_inventory to avoid clobbering.")
		elif FileAccess.file_exists(SAVE_PATH):
			var ondisk := ResourceLoader.load(SAVE_PATH)
			if ondisk and typeof(ondisk.inventory) == TYPE_ARRAY and ondisk.inventory.size() > 0:
				inventory_array = ondisk.inventory.duplicate(true)
				print("[GameState] save_game: fallback -> using on-disk inventory to avoid clobbering.")
			else:
				print("[GameState] save_game: WARNING - no inventory data available; will write empties.")

	if player_slot_count > 0 and inventory_array.size() != player_slot_count:
		var new_arr: Array = []
		for i in range(player_slot_count):
			if i < inventory_array.size():
				new_arr.append(inventory_array[i])
			else:
				new_arr.append({"amount":0, "scene_path":""})
		inventory_array = new_arr.duplicate(true)
		print_debug("[GameState] clamped inventory_array to player_slot_count:", player_slot_count)

	save_res.inventory = inventory_array.duplicate(true)

	var main_array: Array = []
	if inv_ui_for_save and inv_ui_for_save.inv and "slots" in inv_ui_for_save.inv and inv_ui_for_save.inv.slots.size() > 0:
		print_debug("[GameState] building main_array from Inv_UI.inv.slots (authoritative)")
		for slot in inv_ui_for_save.inv.slots:
			if slot == null or slot.item == null:
				main_array.append({"scene_path":"", "amount":0})
				continue
			# debug: show if slot.item present and its type/path
			if slot.item == null:
				print_debug("[GameState] save: slot.item == NULL (empty slot)")
			else:
				var _it = slot.item
				print_debug("[GameState] save: slot.item present -> class:", (_it.get_class() if _it else "NULL"), "id:", (_it.id if "id" in _it else "NO_ID"), "resource_path:", (_it.resource_path if "resource_path" in _it else "NO_RP"), "scene_path:", (_it.scene_path if "scene_path" in _it else "NO_SCENE"))

			var item_obj = slot.item
			var item_path := ""
			if "id" in item_obj and str(item_obj.id) != "":
				item_path = "id:" + str(item_obj.id)
			elif "resource_path" in item_obj and str(item_obj.resource_path) != "":
				item_path = str(item_obj.resource_path)
			elif "scene_path" in item_obj and str(item_obj.scene_path) != "":
				var candidate_res := _find_invitem_for_scene(str(item_obj.scene_path))
				if candidate_res != null and "resource_path" in candidate_res and str(candidate_res.resource_path) != "":
					item_path = str(candidate_res.resource_path)
				else:
					item_path = str(item_obj.scene_path)
			elif item_obj is PackedScene:
				var scene_p = item_obj.resource_path
				var mapped := _find_invitem_for_scene(scene_p)
				if mapped != null and "resource_path" in mapped and str(mapped.resource_path) != "":
					item_path = str(mapped.resource_path)
				else:
					item_path = "scene:" + str(scene_p)
			else:
				item_path = "name:" + str(item_obj.name if "name" in item_obj else "unknown")

			main_array.append({"scene_path": item_path, "amount": int(slot.amount if "amount" in slot else 1)})

	else:
		if saved_main_inventory != null and saved_main_inventory.size() > 0:
			main_array = saved_main_inventory.duplicate(true)
			print("[GameState] save_game: fallback -> using in-memory saved_main_inventory to avoid clobbering.")
		elif FileAccess.file_exists(SAVE_PATH):
			var ondisk2 := ResourceLoader.load(SAVE_PATH)
			if ondisk2 and typeof(ondisk2.main_inventory) == TYPE_ARRAY and ondisk2.main_inventory.size() > 0:
				main_array = ondisk2.main_inventory.duplicate(true)
				print("[GameState] save_game: fallback -> using on-disk main_inventory to avoid clobbering.")
			else:
				print("[GameState] save_game: WARNING - no main inventory data available; will write empties.")

	save_res.main_inventory = main_array.duplicate(true)
	save_res.opened_chests = opened_chests.duplicate(true)

	# call it right before ResourceSaver.save(...)
	_dbg_print_save_contents(save_res)

	var bak_path := SAVE_PATH + ".bak"
	var bak_err := ResourceSaver.save(save_res, bak_path)
	if bak_err != OK:
		print("[GameState] WARNING: failed to write save.bak:", _save_err_str(bak_err))

	var err := ResourceSaver.save(save_res, SAVE_PATH)
	print("[GameState] DEBUG ResourceSaver.save returned:", str(err))
	if err != OK:
		push_error("[GameState] Save failed: %s" % _save_err_str(err))
		_saving = false
		return

	var exists := FileAccess.file_exists(SAVE_PATH)
	var size := -1
	if exists:
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f:
			size = f.get_length()
			var read_bytes = f.get_buffer(min(1024, size))
			f.close()
			print("[GameState] DEBUG wrote bytes len:", size, "sample:", str(read_bytes).substr(0, 512))
		else:
			print("[GameState] DEBUG: Couldn't open save file to read back")

	var dbg := {
		"scene": save_res.scene_path,
		"position_x": save_res.position.x,
		"position_y": save_res.position.y,
		"player_slots": save_res.inventory,
		"main_slots": save_res.main_inventory,
		"opened_chests": save_res.opened_chests,
		"timestamp_unix": save_res.saved_at_unix
	}
	var json_str := JSON.stringify(dbg, "\t")
	var dbg_path := "user://save_debug.json"
	var df := FileAccess.open(dbg_path, FileAccess.WRITE)
	if df:
		df.store_string(json_str)
		df.close()
		print("[GameState] DEBUG: wrote JSON debug mirror to", dbg_path, "len:", json_str.length())
	else:
		print("[GameState] DEBUG: Failed to write JSON debug mirror to", dbg_path)

	saved_scene = save_res.scene_path
	saved_position = save_res.position
	saved_inventory = save_res.inventory.duplicate(true)
	saved_main_inventory = save_res.main_inventory.duplicate(true)

	print("[GameState] 💾 Game saved to %s scene:%s pos:%s (player=%d main=%d) file_exists:%s size:%d" %
		[SAVE_PATH, saved_scene, str(saved_position), saved_inventory.size(), saved_main_inventory.size(), str(exists), size])

	_saving = false

# ---------- load_save() - ensure we store both arrays ----------
func load_save() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		print("[GameState] No save file found at %s" % SAVE_PATH)
		return false

	var res := ResourceLoader.load(SAVE_PATH)
	if not res:
		push_error("[GameState] Failed to load save resource at: %s" % SAVE_PATH)
		return false

	if res is SaveData:
		saved_scene = res.scene_path
		saved_position = res.position
		opened_chests = res.opened_chests.duplicate(true) if res.opened_chests != null else []
		saved_inventory = res.inventory.duplicate(true) if res.inventory != null else []
		saved_main_inventory = res.main_inventory.duplicate(true) if res.main_inventory != null else []
		print("[GameState] ✅ Save loaded: %s %s (player_items=%d main_items=%d)" % [saved_scene, str(saved_position), saved_inventory.size(), saved_main_inventory.size()])
		# inside load_save() after copying saved_inventory & saved_main_inventory:
		print("[GameState DEBUG] loaded saved_inventory len:", saved_inventory.size())
		for i in range(min(32, saved_inventory.size())):
			print("  [loaded inv][%d] %s" % [i, str(saved_inventory[i])])
		print("[GameState DEBUG] loaded saved_main_inventory len:", saved_main_inventory.size())
		for i in range(min(32, saved_main_inventory.size())):
			print("  [loaded main][%d] %s" % [i, str(saved_main_inventory[i])])

		return true
	if res is SaveData:
		print("[GameState] DEBUG loaded SaveData fields -> scene_path:", res.scene_path, "position:", res.position,
			"inventory_size:", (res.inventory.size() if res.inventory != null else "NULL"),
			"main_inventory_size:", (res.main_inventory.size() if res.main_inventory != null else "NULL"),
			"opened_chests:", (res.opened_chests if res.opened_chests != null else []))

	push_error("[GameState] Unexpected save resource type")
	return false

# ---------- Restore helper for main backpack ----------
# --- Helper: try to resolve an InvItem resource given a scene path (tscn) ---
# --- Helper: try to resolve an InvItem resource given a scene path (tscn) ---
func _find_invitem_for_scene(scene_path: String) -> Resource:
	if scene_path == "":
		return null

	# normalize incoming path
	var target := str(scene_path)

	# 1) Check registry entries: prefer values that are actual InvItem resources
	for k in item_registry.keys():
		var entry = item_registry[k]
		var cand = null
		if typeof(entry) == TYPE_STRING:
			var p = str(entry)
			if p != "" and ResourceLoader.exists(p):
				cand = ResourceLoader.load(p)
		else:
			cand = entry

		# accept any resource that looks like an inventory item
		if cand != null and _is_invitem_like(cand):
			# If candidate has a scene_path property, compare (normalize)
			if "scene_path" in cand and str(cand.scene_path) != "":
				if str(cand.scene_path) == target:
					return cand
			# fallback: compare resource_path file basename to scene basename (loose)
			if "resource_path" in cand and str(cand.resource_path) != "":
				var rp := str(cand.resource_path)
				if rp.get_file() == target.get_file():
					return cand

	# 2) Try loading a few common .tres names next to the resources folder
	var scene_basename := target.get_file().get_basename()
	var guesses := [
		"res://resources/%s.tres" % scene_basename,
		"res://resources/%s_res.tres" % scene_basename,
		"res://resources/%s_item.tres" % scene_basename
	]
	for g in guesses:
		if ResourceLoader.exists(g):
			var gres := ResourceLoader.load(g)
			if gres != null and _is_invitem_like(gres):
				item_registry[g] = gres
				if ("scene_path" in gres) and str(gres.scene_path) != "":
					item_registry[str(gres.scene_path)] = gres
				return gres

	# 3) Last-resort: scan resources folder for .tres files and compare their scene_path (expensive)
	var scanned = _scan_resources_for_invitem(target)
	if scanned != null:
		return scanned

	# not found
	return null

func _scan_resources_for_invitem(scene_path: String) -> Resource:
	var folder := "res://resources"
	var dir := DirAccess.open(folder)
	if dir == null:
		return null
	dir.list_dir_begin() # files only, not recursive by default (set true,true if you want recursion)
	var fname := dir.get_next()
	while fname != "":
		# skip directories and non .tres files (we used files-only mode but double-check)
		if fname.to_lower().ends_with(".tres"):
			var full := folder
			if not full.ends_with("/"):
				full += "/"
			full += fname
			if ResourceLoader.exists(full):
				var r := ResourceLoader.load(full)
				if r != null and ClassDB.class_exists("InvItem") and r is InvItem:
					# cache into registry for faster future lookups
					item_registry[full] = r
					if ("scene_path" in r) and str(r.scene_path) != "":
						item_registry[str(r.scene_path)] = r
					# also cache id if present
					if "id" in r and str(r.id) != "":
						item_registry[str(r.id)] = r
					dir.list_dir_end()
					return r

		fname = dir.get_next()
	dir.list_dir_end()
	return null
# ---------- Restore helper for main backpack ----------
func restore_main_inventory_to_ui() -> void:
	# Apply saved_main_inventory into the Inv_UI.inv resource (used by UI on screen)
	if saved_main_inventory == null or saved_main_inventory.size() == 0:
		print("[GameState] no saved_main_inventory to restore")
		return

	var root = _get_root()
	if root == null:
		print("[GameState] restore_main_inventory_to_ui: root is null, deferring")
		return

	var inv_ui = root.find_child("Inv_UI", true, false)
	if inv_ui == null:
		print("[GameState] restore_main_inventory_to_ui: Inv_UI not found in scene tree")
		return

	# Ensure resource slots exist
	if not inv_ui.inv:
		print("[GameState] restore_main_inventory_to_ui: Inv_UI.inv missing")
		return

	# Ensure inv resource exists and we mutate its slots in-place (preserve resource identity)
	var inv_res = inv_ui.inv
	if inv_res == null:
		print("[GameState] restore_main_inventory_to_ui: inv_ui.inv missing")
		return

	# Prepare slots array to exact target length (preserve instance, set empty slots as needed)
	var target_len := saved_main_inventory.size()
	while inv_res.slots.size() < target_len:
		inv_res.slots.append(InvSlot.new())
	while inv_res.slots.size() > target_len:
		inv_res.slots.pop_back()

	for i in range(target_len):
		var e = saved_main_inventory[i]
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var item_path := str(e.get("scene_path", ""))
		var amount := int(e.get("amount", 0))
		var item_res: Resource = null
		# (resolve item_res same as before...)
		# [keep your lookup code]
		var slot = inv_res.slots[i]
		if item_res != null and _is_invitem_like(item_res):
			slot.item = item_res
			slot.amount = amount
		else:
			slot.item = null
			slot.amount = 0
			if item_res != null:
				print("[GameState] restore_main_inventory_to_ui: item_res found but not inv-like for path:", item_path, "loaded_as:", (item_res.get_class() if item_res else "NULL"))

	# refresh UI
	if inv_ui.has_method("update_slots"):
		inv_ui.update_slots()
	# emit inventory_changed so any listeners (autosave) respond
	if inv_ui.has_signal("inventory_changed"):
		inv_ui.emit_signal("inventory_changed")
	print("[GameState] restore_main_inventory_to_ui: applied", saved_main_inventory.size(), "items")

# Register an item so lookups work (call from _ready or editor initialization)
func register_item(id: String, item_res_or_path) -> void:
	if typeof(item_res_or_path) == TYPE_STRING:
		item_registry[id] = str(item_res_or_path)
	else:
		item_registry[id] = item_res_or_path

# Lookup by id (returns Resource or null)
func _lookup_item_by_id(id_str: String) -> Resource:
	if id_str == "":
		return null
	if not item_registry.has(id_str):
		return null
	var entry = item_registry[id_str]
	# if it's a path, try loading; if already Resource, return it
	if typeof(entry) == TYPE_STRING:
		var p = str(entry)
		if ResourceLoader.exists(p):
			return ResourceLoader.load(p)
		else:
			return null
	else:
		return entry

# Lookup by name (tries to find a registered item whose resource has a name property or matches)
func _lookup_item_by_name(name_str: String) -> Resource:
	if name_str == "":
		return null
	for id_key in item_registry.keys():
		var entry = item_registry[id_key]
		var res = null
		if typeof(entry) == TYPE_STRING:
			if ResourceLoader.exists(str(entry)):
				res = ResourceLoader.load(str(entry))
		else:
			res = entry
		if res != null:
			# defensive: check common properties
			if ("name" in res and str(res.name).to_lower() == name_str.to_lower()) or (res.resource_name and str(res.resource_name).to_lower() == name_str.to_lower()):
				return res
			# as a weaker fallback, compare filename
			var pth = res.resource_path if "resource_path" in res else ""
			if pth != "" and pth.get_file().get_basename().to_lower() == name_str.to_lower():
				return res
	return null


func set_checkpoint(scene_path: String, pos: Vector2) -> void:
	checkpoint_scene = scene_path
	checkpoint_position = pos
	push_warning("[GameState] ✅ Checkpoint set: %s %s" % [scene_path, str(pos)])

func has_checkpoint() -> bool:
	return checkpoint_scene != ""

func get_respawn_data() -> Dictionary:
	return {"scene": checkpoint_scene, "position": checkpoint_position}

# Simplified save() — do not set the _saving guard here.
func save() -> void:
	# avoid kicking off another save while one is in progress
	if _saving:
		print("[GameState] save(): save already in progress — skipping new save request")
		return

	# choose scene/pos now (no heavy work on this stack)
	var scene_path := ""
	var pos := Vector2.ZERO
	if has_checkpoint():
		scene_path = checkpoint_scene
		pos = checkpoint_position
	elif get_tree() and get_tree().current_scene:
		scene_path = get_tree().current_scene.scene_file_path

	# Call the real saver synchronously — keep re-entrancy guard inside save_game()
	save_game(scene_path, pos)

func has_save() -> bool:
	return saved_scene != ""

func get_save_data() -> Dictionary:
	return {
		"scene": saved_scene,
		"position": Vector2(saved_position.x, saved_position.y)
	}

# Called by chests to register themselves as opened
func register_opened_chest(chest_id: String) -> void:
	if chest_id == "":
		return
	if not opened_chests.has(chest_id):
		opened_chests.append(chest_id)
		print("[GameState] Registered opened chest:", chest_id)

func is_chest_opened(chest_id: String) -> bool:
	if chest_id == "":
		return false
	return opened_chests.has(chest_id)

# Restore saved inventory array (call from Player._ready when player exists)
func restore_inventory_to_player(player: Node) -> void:
	if player == null:
		return
	if saved_inventory == null or saved_inventory.size() == 0:
		print("[GameState] no saved_inventory to restore")
		return

	var inv_res = null
	if player.has_method("get_inventory"):
		inv_res = player.get_inventory()
	elif "inventory" in player:
		inv_res = player.inventory

	# Prefer player's public API if available
	if player.has_method("add_to_inventory"):
		for e in saved_inventory:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var amount_val := int(e.get("amount", 0))
			var item_path := str(e.get("scene_path", ""))
			# resolve item_path robustly (drop into restore_inventory_to_player and restore_main_inventory_to_ui)
			var item_res: Resource = null
			if item_path.begins_with("id:"):
				item_res = _lookup_item_by_id(item_path.substr(3, item_path.length()))
			elif item_path.begins_with("name:"):
				item_res = _lookup_item_by_name(item_path.substr(5, item_path.length()))
			elif item_path.begins_with("scene:"):
				# saved explicit scene path, try to map to an InvItem resource
				var scene_p := item_path.substr(6, item_path.length())
				item_res = _find_invitem_for_scene(scene_p)
				if item_res == null:
					# maybe there is an actual .tres next to the scene with a known naming pattern
					item_res = _find_invitem_for_scene(scene_p) # second attempt (keeps behavior consistent)
			elif item_path != "" and ResourceLoader.exists(item_path):
				var loaded = ResourceLoader.load(item_path)
				if loaded is PackedScene:
					# saved a scene file by accident - try to map to a .tres InvItem
					item_res = _find_invitem_for_scene(item_path)
					if item_res == null:
						print("[GameState.restore] WARNING: saved item was a PackedScene and no matching InvItem resource found for:", item_path)
				else:
					item_res = loaded
			else:
				# as last resort try name lookup
				item_res = _lookup_item_by_name(item_path)

			# --- Robust restore: safe-call player.add_to_inventory only with proper InvItem resource ---
			if item_res != null:
				# If we accidentally loaded a PackedScene (scene file), avoid passing it to add_to_inventory().
				# Prefer to call a fallback API on the player if available that accepts a path/scene.
				if item_res is PackedScene:
					# Prefer a player API that accepts a path/identifier if present
					if player.has_method("add_to_inventory_by_path"):
						player.add_to_inventory_by_path(item_path, amount_val)
						continue
					else:
						print("[GameState.restore] WARNING: item_path resolved to PackedScene, skipping direct add_to_inventory():", item_path)
						# optionally try to find an InvItem inside the scene? Skip for now.
						continue

				# Otherwise it's a resource that should be compatible (InvItem)
				# Defensive type-check: if it's not the expected resource type, try fallback
				# (you can replace "InvItem" with your actual class name if different)
				if typeof(item_res) == TYPE_OBJECT and _is_invitem_like(item_res):
					player.add_to_inventory(item_res, amount_val)
				else:
					# fallback...

					# If player's API accepts an identifier string, try that
					if player.has_method("add_to_inventory_by_path"):
						player.add_to_inventory_by_path(item_path, amount_val)
					else:
						# Final fallback: try to pass resource but warn if it fails at runtime
						print("[GameState.restore] WARNING: item_res not an InvItem and no add_to_inventory_by_path available:", item_path)

	else:
		# direct population fallback: replace inv.slots contents
		if inv_res != null and "slots" in inv_res:
			inv_res.slots.clear()
			for e in saved_inventory:
				if typeof(e) != TYPE_DICTIONARY:
					continue
				var item_path := str(e.get("scene_path", ""))
				var item_res = null
				# Try to resolve to an InvItem resource (resource path .tres) OR use registry lookup by id/name
				if item_path.begins_with("id:"):
					item_res = _lookup_item_by_id(item_path.substr(3, item_path.length()))
				elif item_path.begins_with("name:"):
					item_res = _lookup_item_by_name(item_path.substr(5, item_path.length()))
				elif item_path != "" and ResourceLoader.exists(item_path):
					var loaded = ResourceLoader.load(item_path)
					if loaded is PackedScene:
						# saved a scene path — try to find InvItem resource mapped to that scene
						item_res = _find_invitem_for_scene(item_path)
						if item_res == null:
							print("[GameState.restore] WARNING: saved item was a PackedScene and no matching InvItem resource found for:", item_path)
					else:
						item_res = loaded

				var slot = InvSlot.new()
				if item_res != null and ClassDB.class_exists("InvItem") and item_res is InvItem:
					slot.item = item_res
					slot.amount = int(e.get("amount", 0))
				else:
					slot.item = null
					slot.amount = int(e.get("amount", 0)) if item_res != null else 0
				inv_res.slots.append(slot)
	# after restoring, update the player's UI & equipment
	if player.has_method("refresh_equipped_weapon_from_inventory"):
		player.call_deferred("refresh_equipped_weapon_from_inventory")
	if player.has_method("update_weapon_visuals"):
		player.call_deferred("update_weapon_visuals")
	# If you have an inventory UI instance, call its update_slots() too (or rely on its signal)
	print("[GameState] restore_inventory_to_player: applied", saved_inventory.size(), "items")

# Overwrite save with an empty SaveData resource (safer than attempting to delete file)
func delete_save_file() -> void:
	# Backup existing canonical save and then write an explicitly-empty SaveData
	# atomically to the canonical path (this is the "destructive" delete).
	# Use this when you really want to clobber the save (NEW GAME confirmed).

	# 1) backup if exists
	if FileAccess.file_exists(SAVE_PATH):
		var ts := str(Time.get_unix_time_from_system())
		var bak := SAVE_PATH + ".backup_%s.tres" % ts
		# create backup by renaming if possible, otherwise fall back to manual copy
		var dir := DirAccess.open("user://")
		var src_name := SAVE_PATH.get_file()          # "save.tres"
		var bak_name := bak.get_file()                # e.g. "save.tres.pre_reset_1234.tres"
		var rename_ok: bool = false
		if dir:
			# DirAccess.rename expects *names* relative to that dir,
			# so make sure both are relative (or use absolute methods if you prefer).
			# We try rename first (fast, atomic on most FS).
			rename_ok = dir.rename(src_name, bak_name)  # returns true/false
			if rename_ok:
				print("[GameState] reset_save: backed up existing save to", bak)
			else:
				# fallback: manual copy / write bytes
				var rf := FileAccess.open(SAVE_PATH, FileAccess.READ)
				if rf:
					var buf := rf.get_buffer(rf.get_length())
					rf.close()
					var wf := FileAccess.open("user://" + bak_name, FileAccess.WRITE)
					if wf:
						wf.store_buffer(buf)
						wf.close()
						# if manual copy succeeded, attempt to remove original
						if dir:
							if dir.remove(src_name):
								print("[GameState] reset_save: backed up existing save to", bak)
							else:
								push_error("[GameState] reset_save: copied backup but failed to remove original " + src_name)
					else:
						push_error("[GameState] reset_save: failed to write backup %s" % bak)
				else:
					push_error("[GameState] reset_save: failed to open existing save for backup")
		else:
			push_error("[GameState] reset_save: could not open user:// dir for backup operations")

	# 2) write an empty SaveData to SAVE_PATH atomically
	var blank := SaveDataResource.new()
	blank.scene_path = ""
	blank.position = Vector2.ZERO
	blank.inventory = []
	blank.main_inventory = []
	blank.opened_chests = []
	var err := _atomic_save_resource(blank, SAVE_PATH)
	if err != OK:
		push_error("[GameState] delete_save_file: failed to write empty save: %s" % _save_err_str(err))
	else:
		print("[GameState] delete_save_file: canonical save overwritten (empty) ->", SAVE_PATH)

	# clear runtime values after successful overwrite
	if err == OK:
		saved_scene = ""
		saved_position = Vector2.ZERO
		saved_inventory = []
		saved_main_inventory = []
		opened_chests = []

# ---------- filesystem helpers ----------
func _safe_remove(path: String) -> bool:
	# Remove file at path. Returns true on success.
	if path == "":
		return false
	# If path refers to user://, use DirAccess on that root
	if path.begins_with("user://"):
		var dir := DirAccess.open("user://")
		if dir:
			return dir.remove(path.get_file())
		return false
	# Otherwise open the parent dir and remove by filename
	var base := path.get_base_dir()
	var fname := path.get_file()
	var dir2 := DirAccess.open(base)
	if dir2:
		return dir2.remove(fname)
	return false

func _safe_rename(src_path: String, dst_path: String) -> bool:
	# Try to rename atomically. If rename isn't possible, fallback to copy-then-remove.
	if src_path == "" or dst_path == "":
		return false

	# If both are in the same DirAccess root, try DirAccess.rename (fast)
	# For typical case user:// we open user:// and pass filenames.
	if src_path.begins_with("user://") and dst_path.begins_with("user://"):
		var dir := DirAccess.open("user://")
		if dir:
			return dir.rename(src_path.get_file(), dst_path.get_file())

	# Otherwise, try rename via parent dir(s) if same base dir
	var src_base := src_path.get_base_dir()
	var dst_base := dst_path.get_base_dir()
	if src_base == dst_base and src_base != "":
		var d := DirAccess.open(src_base)
		if d:
			return d.rename(src_path.get_file(), dst_path.get_file())

	# Fallback: copy bytes and remove source
	var rf := FileAccess.open(src_path, FileAccess.READ)
	if not rf:
		return false
	var buf := rf.get_buffer(rf.get_length())
	rf.close()
	var wf := FileAccess.open(dst_path, FileAccess.WRITE)
	if not wf:
		return false
	wf.store_buffer(buf)
	wf.close()
	# attempt remove of original, ignore result but return true if copy succeeded
	_safe_remove(src_path)
	return true


# ---------- atomic save (replace existing) ----------
func _atomic_save_resource(res: Resource, target_path: String) -> int:
	var tmp := target_path + ".tmp"
	var err := ResourceSaver.save(res, tmp)
	if err != OK:
		push_error("[GameState] _atomic_save_resource: failed to write temp save %s: %s" % [tmp, _save_err_str(err)])
		# attempt to cleanup temp
		if FileAccess.file_exists(tmp):
			_safe_remove(tmp)
		return err

	# Attempt atomic rename (fast path)
	var rename_ok: bool = _safe_rename(tmp, target_path)
	if rename_ok:
		print("[GameState] _atomic_save_resource: saved atomically to", target_path)
		return OK

	# If rename failed for some reason (shouldn't often happen), fallback to manual copy
	var f := FileAccess.open(tmp, FileAccess.READ)
	if f:
		var buf := f.get_buffer(f.get_length())
		f.close()
		var w := FileAccess.open(target_path, FileAccess.WRITE)
		if w:
			w.store_buffer(buf)
			w.close()
			# cleanup tmp
			_safe_remove(tmp)
			print("[GameState] _atomic_save_resource: rename failed, copied bytes to", target_path)
			return OK
		else:
			push_error("[GameState] _atomic_save_resource: failed to open target for write %s" % target_path)
			return ERR_CANT_CREATE
	else:
		push_error("[GameState] _atomic_save_resource: failed to open temp for fallback read: %s" % tmp)
		return ERR_CANT_OPEN


# ---------- reset_save (New Game) ----------
func reset_save(start_scene: String = "res://scenes/world.tscn") -> void:
	# 1) backup current save if present
	if FileAccess.file_exists(SAVE_PATH):
		var ts := str(Time.get_unix_time_from_system())
		var bak := SAVE_PATH + ".pre_reset_%s.tres" % ts
		var backed_up: bool = false

		# Try fast rename using helpers (handles user:// correctly)
		backed_up = _safe_rename(SAVE_PATH, bak)
		if backed_up:
			print("[GameState] reset_save: backed up existing save to", bak)
		else:
			# fallback copy bytes manually
			var rf := FileAccess.open(SAVE_PATH, FileAccess.READ)
			if rf:
				var buf := rf.get_buffer(rf.get_length())
				rf.close()
				var wf := FileAccess.open(bak, FileAccess.WRITE)
				if wf:
					wf.store_buffer(buf)
					wf.close()
					# remove original
					_safe_remove(SAVE_PATH)
					print("[GameState] reset_save: backed up existing save to", bak)
				else:
					push_error("[GameState] reset_save: failed to write backup %s" % bak)
			else:
				push_error("[GameState] reset_save: failed to open existing save for backup")

	# 2) clear runtime caches to reflect New Game
	checkpoint_scene = ""
	checkpoint_position = Vector2.ZERO
	saved_scene = start_scene
	saved_position = Vector2.ZERO
	saved_inventory = []
	saved_main_inventory = []
	opened_chests.clear()

	# 3) write start save atomically to canonical save path
	var blank := SaveDataResource.new()
	blank.scene_path = start_scene
	blank.position = Vector2.ZERO
	blank.inventory = []
	blank.main_inventory = []
	blank.opened_chests = []
	var err := _atomic_save_resource(blank, SAVE_PATH)
	if err != OK:
		push_error("[GameState] reset_save: failed to write canonical start save: %s" % _save_err_str(err))
	else:
		print("[GameState] Reset save and wrote fresh start scene to", SAVE_PATH)

func _exit_tree() -> void:
	# Defensive: get_tree() may be null during shutdown in some embeddings
	var tree = get_tree()
	if tree == null:
		print("[GameState] _exit_tree(): get_tree() == null, skipping save")
		return

	var root = tree.root
	# root can be null in some shutdown orders
	if root == null:
		print("[GameState] _exit_tree(): tree.root == null, skipping save")
		return

	print("[GameState] _exit_tree() called — attempting to save before exit")

	# Try to flush UI/main-inventory first (if present)
	var inv_ui = root.find_child("Inv_UI", true, false)
	if inv_ui and inv_ui.has_method("update_slots"):
		inv_ui.update_slots()
	# Try to flush player deferred equipment changes (if Player still exists)
	var player_node = root.find_child("Player", true, false)
	if player_node and player_node.has_method("refresh_equipped_weapon_from_inventory"):
		player_node.call_deferred("refresh_equipped_weapon_from_inventory")

	# Finally call save() which wraps save_game()
	save()

# Helper: accepts true if resource "looks like" your InvItem (flexible)
func _is_invitem_like(res: Resource) -> bool:
	if res == null:
		return false
	# If a real typed class exists and matches, prefer that
	if ClassDB.class_exists("InvItem") and res is InvItem:
		return true
	# Flexible heuristics: many inv item resources define scene_path / id / type / name
	if ("scene_path" in res and str(res.scene_path) != ""):
		return true
	if ("id" in res and str(res.id) != ""):
		return true
	if ("type" in res and str(res.type) != ""):
		return true
	# fallback: check resource has any property you'd expect (name)
	if ("name" in res and str(res.name) != ""):
		return true
	return false

# near the end of save_game(), after save_res prepared but before writing:
func _dbg_print_save_contents(save_res):
	# pretty small helper to print first N entries
	var N = min(16, save_res.inventory.size())
	print("[GameState DEBUG] save_res.inventory size:", save_res.inventory.size())
	for i in range(N):
		print("  [inv][%d] %s" % [i, str(save_res.inventory[i])])
	var M = min(16, save_res.main_inventory.size())
	print("[GameState DEBUG] save_res.main_inventory size:", save_res.main_inventory.size())
	for j in range(M):
		print("  [main][%d] %s" % [j, str(save_res.main_inventory[j])])
