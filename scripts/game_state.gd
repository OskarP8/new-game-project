# res://globals/GameState.gd
extends Node

const SAVE_PATH : String = "user://save.tres"
const SaveDataResource := preload("res://scripts/SaveData.gd")  # <-- keep your exact path

# Runtime checkpoint
var checkpoint_scene: String = ""
var checkpoint_position: Vector2 = Vector2.ZERO

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
	# auto-register .tres item resources (so registry resolves saved .tscn -> InvItem resource)
	_auto_register_items_from_folder("res://resources")   # <-- change path if your resources are elsewhere
	print("[GameState] registry sample:", item_registry.keys())

	# optional: existing manual registrations (you can keep or remove)
	register_item("pitchfork", "res://resources/pitchfork_res.tres")
	register_item("sword", "res://resources/sword.tres")

	# now load existing save (with registry ready)
	load_save()

	# Connect to about_to_quit so clicking X triggers a save (defensive)
	var t = get_tree()
	if t and t.has_signal("about_to_quit"):
		if not t.is_connected("about_to_quit", Callable(self, "save")):
			t.connect("about_to_quit", Callable(self, "save"))

# Auto-register .tres item resources from a folder (call this in _ready BEFORE load_save())
# Auto-register .tres item resources from a folder (call this in _ready BEFORE load_save())
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
				var script_path := "NONE"
				if r.has_method("get_script") and r.get_script() != null:
					var sr = r.get_script()
					script_path = sr.resource_path if "resource_path" in sr else str(sr)
				print("[GameState] _auto_register: loaded_as:", r.get_class(), "script:", script_path)
				# try treating it as InvItem if class exists
				if ClassDB.class_exists("InvItem") and r is InvItem:
					item_registry[full] = r
					registered += 1
				# also register by scene_path if present
				if ("scene_path" in r) and str(r.scene_path) != "":
					item_registry[str(r.scene_path)] = r
		fname = dir.get_next()
	dir.list_dir_end()
	print("[GameState] _auto_register_items_from_folder: registered", registered, "items from", folder_path)

# ---------- save_game(...) ----------
func save_game(scene_path: String = "", pos: Vector2 = Vector2.ZERO) -> void:
	# Defensive root retrieval (safe during shutdown)
	var root = _get_root()

	# Try to flush UI + player deferred changes first (best-effort)
	var inv_ui = root.find_child("Inv_UI", true, false) if root else null
	if inv_ui and inv_ui.has_method("update_slots"):
		inv_ui.update_slots()

	var player_node = root.find_child("Player", true, false) if root else null
	if player_node and player_node.has_method("refresh_equipped_weapon_from_inventory"):
		player_node.refresh_equipped_weapon_from_inventory()
	print("[GameState] save_game ENTER root:", (root != null), " inv_ui:", (inv_ui != null), " player_node:", (player_node != null))

	# Determine scene/path to save (fallbacks)
	if scene_path == "":
		if has_checkpoint():
			scene_path = checkpoint_scene
			pos = checkpoint_position
		elif get_tree() and get_tree().current_scene:
			scene_path = get_tree().current_scene.scene_file_path
	# store runtime
	saved_scene = scene_path
	saved_position = pos
	print("[GameState] DEBUG before collect -> inv_ui.inv slots:", (inv_ui.inv.slots.size() if inv_ui and inv_ui.inv and "slots" in inv_ui.inv else "NO_INV"), " player.inventory slots:", (player_node.inventory.slots.size() if player_node and "inventory" in player_node and player_node.inventory and "slots" in player_node.inventory else "NO_PLAYER_INV"))

	# Create SaveData resource instance
	var save_res := SaveDataResource.new()
	save_res.scene_path = saved_scene if saved_scene != null else ""
	save_res.position = saved_position if saved_position != null else Vector2.ZERO
	# avoid problematic OS calls — keep zero for portability
	save_res.saved_at_unix = 0

	# ---------- Robust SYNC: mirror Inv_UI.inv -> player.inventory (index-assign + per-slot debug) ----------
	if inv_ui and inv_ui.inv and player_node and "inventory" in player_node and player_node.inventory:
		var player_inv_res = player_node.inventory

		# diagnostics
		var ui_slots_count = inv_ui.inv.slots.size() if inv_ui and inv_ui.inv and "slots" in inv_ui.inv else -1
		var player_before = player_inv_res.slots.size() if player_inv_res and "slots" in player_inv_res else -1
		print("[GameState] DEBUG before mirror -> inv_ui.inv slots:%d player.inventory slots:%d" % [ui_slots_count, player_before])

		# ensure player's slots array is exactly the same length
		if not ("slots" in player_inv_res):
			print("[GameState] SYNC: ERROR: player.inventory has no 'slots' property")
		else:
			# resize player slots to match UI slots
			var target = ui_slots_count
			# create missing slots if needed, or truncate
			while player_inv_res.slots.size() < target:
				player_inv_res.slots.append(InvSlot.new())
			while player_inv_res.slots.size() > target:
				player_inv_res.slots.remove(player_inv_res.slots.size() - 1)

			# now assign by index (avoid append semantics)
			for i in range(target):
				var ui_slot = inv_ui.inv.slots[i]
				var new_slot = InvSlot.new()
				# defensive: copy only valid InvItem resources; try to resolve PackedScene to InvItem if required
				if ui_slot != null and ui_slot.item != null:
					var cand = ui_slot.item
					if cand is PackedScene:
						var resolved = null
						if cand.resource_path != "":
							resolved = _find_invitem_for_scene(cand.resource_path)
						if resolved != null:
							new_slot.item = resolved
						else:
							new_slot.item = null
							print("[GameState] DEBUG mirror slot %d: UI had PackedScene (%s) but no InvItem mapped" % [i, str(cand.resource_path)])
					else:
						# normal case
						new_slot.item = cand
				else:
					new_slot.item = null
				new_slot.amount = int(ui_slot.amount if ui_slot and "amount" in ui_slot else 0)

				# assign into player's resource slots by index
				player_inv_res.slots[i] = new_slot

				# immediate per-slot debug
				var it_name = "[empty]"
				if player_inv_res.slots[i].item != null:
					if "name" in player_inv_res.slots[i].item:
						it_name = str(player_inv_res.slots[i].item.name)
					else:
						it_name = str(player_inv_res.slots[i].item)
				print("[GameState] DEBUG wrote player.slot[%d] -> item:%s amount:%d" % [i, it_name, player_inv_res.slots[i].amount])

			# finalize debug
			var player_after = player_inv_res.slots.size()
			print("[GameState] SYNC: mirrored Inv_UI -> player.inventory (player_slots=%d)" % player_after)

	else:
		# helpful debug for troubleshooting
		if not player_node:
			print("[GameState] SYNC: no player_node found to mirror into.")
		elif not (inv_ui and inv_ui.inv):
			print("[GameState] SYNC: no Inv_UI.inv found to mirror from.")
		elif not ("inventory" in player_node and player_node.inventory):
			print("[GameState] SYNC: player_node has no inventory resource to mirror into.")

	# ---------------------------------------------------------
	# Collect SMALL player inventory snapshot (serialize into simple dictionaries)
	# ---------------------------------------------------------
	var inventory_array: Array = []

	# Prefer reading player's resource/API if present
	if player_node:
		var inv_res = null
		if player_node.has_method("get_inventory"):
			inv_res = player_node.get_inventory()
		elif "inventory" in player_node:
			inv_res = player_node.inventory

		if inv_res and "slots" in inv_res and inv_res.slots.size() > 0:
			for slot in inv_res.slots:
				if slot == null or slot.item == null:
					inventory_array.append({"scene_path":"", "amount":0})
					continue
				var item_path := ""
				# Prefer serializing a resource file (.tres) when present, else fall back to scene path/ids/name
				if "resource_path" in slot.item and str(slot.item.resource_path) != "":
					item_path = str(slot.item.resource_path)
				elif "scene_path" in slot.item and str(slot.item.scene_path) != "":
					item_path = str(slot.item.scene_path)
				elif "id" in slot.item and str(slot.item.id) != "":
					item_path = "id:" + str(slot.item.id)
				else:
					item_path = "name:" + str(slot.item.name if "name" in slot.item else "unknown")

				inventory_array.append({"scene_path": item_path, "amount": int(slot.amount if "amount" in slot else 1)})

	# Fallback: if still empty, read directly from UI's inv (this matches what the player actually sees)
	if inventory_array.size() == 0:
		if inv_ui and inv_ui.inv and "slots" in inv_ui.inv:
			for slot in inv_ui.inv.slots:
				if slot == null or slot.item == null:
					inventory_array.append({"scene_path":"", "amount":0})
					continue
				var item_path := ""
				# Prefer serializing a resource file (.tres) when present, else fall back to scene path/ids/name
				if "resource_path" in slot.item and str(slot.item.resource_path) != "":
					item_path = str(slot.item.resource_path)
				elif "scene_path" in slot.item and str(slot.item.scene_path) != "":
					item_path = str(slot.item.scene_path)
				elif "id" in slot.item and str(slot.item.id) != "":
					item_path = "id:" + str(slot.item.id)
				else:
					item_path = "name:" + str(slot.item.name if "name" in slot.item else "unknown")

				inventory_array.append({"scene_path": item_path, "amount": int(slot.amount if "amount" in slot else 1)})
	else:
		# keep empty snapshot (so we don't accidentally write null)
		inventory_array = inventory_array

	save_res.inventory = inventory_array.duplicate(true)

	# ---------------------------------------------------------
	# Collect MAIN backpack inventory from Inv_UI.inv
	# ---------------------------------------------------------
	var main_array: Array = []
	if inv_ui and inv_ui.inv and "slots" in inv_ui.inv:
		for slot in inv_ui.inv.slots:
			if slot == null or slot.item == null:
				main_array.append({"scene_path":"", "amount":0})
				continue
			var item_path := ""
			if "scene_path" in slot.item and str(slot.item.scene_path) != "":
				item_path = str(slot.item.scene_path)
			elif "resource_path" in slot.item and str(slot.item.resource_path) != "":
				item_path = str(slot.item.resource_path)
			elif "id" in slot.item and str(slot.item.id) != "":
				item_path = "id:" + str(slot.item.id)
			else:
				item_path = "name:" + str(slot.item.name if "name" in slot.item else "unknown")
			main_array.append({"scene_path": item_path, "amount": int(slot.amount if "amount" in slot else 1)})
	else:
		main_array = []

	save_res.main_inventory = main_array.duplicate(true)

	# Opened chests
	save_res.opened_chests = opened_chests.duplicate(true)

	# Persist resource to disk (ResourceSaver.save(resource, path))
	var err := ResourceSaver.save(save_res, SAVE_PATH)
	if err != OK:
		push_error("[GameState] Save failed: %s" % str(err))
	else:
		# informative debug: how many slots saved for player vs main UI
		var player_slots = inventory_array.size()
		var main_slots = main_array.size()
		print("[GameState] 💾 Game saved to %s scene:%s pos:%s (player=%d main=%d)" % [SAVE_PATH, saved_scene, str(saved_position), player_slots, main_slots])

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
		return true

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
		# if entry is a path string, try loading it (but avoid repeated loads)
		if typeof(entry) == TYPE_STRING:
			var p = str(entry)
			if p != "" and ResourceLoader.exists(p):
				cand = ResourceLoader.load(p)
		else:
			cand = entry

		# cand must be an InvItem to be valid
		if cand != null and ClassDB.class_exists("InvItem") and cand is InvItem:
			# If candidate has a scene_path property, compare (normalize)
			if "scene_path" in cand and str(cand.scene_path) != "":
				if str(cand.scene_path) == target:
					return cand
			# fallback: compare filename basenames (loose)
			if "resource_path" in cand and str(cand.resource_path) != "":
				var rp := str(cand.resource_path)
				if rp.get_file() == target.get_file():
					return cand
		# otherwise skip this registry entry (it wasn't an InvItem)

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
			if gres != null and ClassDB.class_exists("InvItem") and gres is InvItem:
				# cache into registry for next time
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
					if ("scene_path" in r) and str(r.scene_path) == str(scene_path):
						# cache into registry for faster future lookups
						item_registry[full] = r
						item_registry[str(r.scene_path)] = r
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

	inv_ui.inv.slots.clear()
	for e in saved_main_inventory:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var item_path := str(e.get("scene_path", ""))
		var amount := int(e.get("amount", 0))
		var item_res: Resource = null

		# Try id -> registry
		if item_path.begins_with("id:"):
			item_res = _lookup_item_by_id(item_path.substr(3, item_path.length()))
		elif item_path.begins_with("name:"):
			item_res = _lookup_item_by_name(item_path.substr(5, item_path.length()))
		else:
			# If path points to a resource file (e.g. .tres) - load
			if item_path != "" and ResourceLoader.exists(item_path):
				var loaded = ResourceLoader.load(item_path)
				# If this resolved to a PackedScene (tscn), try to find corresponding InvItem resource
				if loaded is PackedScene:
					# try registry match by scene_path
					item_res = _find_invitem_for_scene(item_path)
					if item_res == null:
						# fallback: we can't directly convert a PackedScene into an InvItem resource
						# leave item_res null (slot will be empty)
						print("[GameState] restore_main_inventory_to_ui: saved path was a PackedScene and no InvItem found for:", item_path)
				else:
					item_res = loaded
			else:
				# path missing or doesn't exist on disk: try name/id heuristics
				item_res = _lookup_item_by_name(item_path) if item_path.begins_with("name:") else null

		# Create slot; only assign item if it's a proper InvItem resource (defensive)
		var slot = InvSlot.new()
		if item_res != null and ClassDB.class_exists("InvItem") and item_res is InvItem:
			slot.item = item_res
			slot.amount = amount
		else:
			# Leave slot empty (keeps spacing) if we couldn't resolve the item
			slot.item = null
			slot.amount = 0
			if item_res != null:
				print("[GameState] restore_main_inventory_to_ui: item_res found but not an InvItem resource for path:", item_path)

		inv_ui.inv.slots.append(slot)

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

func save() -> void:
	var scene_path := ""
	var pos := Vector2.ZERO
	if has_checkpoint():
		scene_path = checkpoint_scene
		pos = checkpoint_position
	elif get_tree().current_scene:
		scene_path = get_tree().current_scene.scene_file_path
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
			var item_res: Resource = null

			if item_path.begins_with("id:"):
				# handle id lookups if you have an item registry (optional)
				var id_str := item_path.substr(3, item_path.length())
				item_res = _lookup_item_by_id(id_str) # implement if you have registry
			elif item_path.begins_with("name:"):
				# could try to find by name in a registry, else skip
				var name_str := item_path.substr(5, item_path.length())
				item_res = _lookup_item_by_name(name_str) # optional
			elif item_path != "" and ResourceLoader.exists(item_path):
				item_res = ResourceLoader.load(item_path)

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
				if typeof(item_res) == TYPE_OBJECT and ClassDB.class_exists("InvItem") and item_res is InvItem:
					player.add_to_inventory(item_res, amount_val)
				else:
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
	var blank := SaveDataResource.new()
	blank.scene_path = ""
	blank.position = Vector2.ZERO
	blank.inventory = []
	blank.main_inventory = []
	blank.opened_chests = []
	var err := ResourceSaver.save(blank, SAVE_PATH)
	if err != OK:
		push_error("[GameState] Failed to overwrite save file: %s" % str(err))
	else:
		print("[GameState] Overwrote save file with empty SaveData:", SAVE_PATH)

	saved_scene = ""
	saved_position = Vector2.ZERO
	saved_inventory = []
	saved_main_inventory = []
	opened_chests = []

# Convenience: reset runtime and on-disk save, used by New Game
func reset_save(start_scene: String = "res://scenes/world.tscn") -> void:
	# clear runtime caches
	checkpoint_scene = ""
	checkpoint_position = Vector2.ZERO
	saved_scene = start_scene
	saved_position = Vector2.ZERO
	saved_inventory = []
	saved_main_inventory = []
	opened_chests.clear()

	# persist cleared state but include start_scene so continue resumes at start
	save_game(start_scene, Vector2.ZERO)
	print("[GameState] Reset save and wrote fresh start scene:", start_scene)

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
		player_node.refresh_equipped_weapon_from_inventory()

	# Finally call save() which wraps save_game()
	save()
