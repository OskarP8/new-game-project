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
var saved_inventory: Array = []
var saved_equipment_inventory: Array = []

# Runtime record of opened chests (keeps in-memory and saved to disk)
var opened_chests: Array = []
# GameState.gd - NEW runtime flags
var intro_shown: bool = false
var greeted_npcs: Dictionary = {}    # npc_id -> true
# runtime helper: set true when load_save() has applied the save to runtime
var applied_save: bool = false
var _save_scheduled: bool = false
var _restoring_inventory: bool = false
var suppress_inventory_autosave: bool = false

func _ready() -> void:
	# load existing save (if any) on startup
	print("[GameState] _ready() -> loading save (if exists) at:", SAVE_PATH)
	load_save()

	# connect quit signal so we can save on exit
	if get_tree().has_signal("about_to_quit"):
		get_tree().connect("about_to_quit", Callable(self, "_on_about_to_quit"))
		print("[GameState] connected to about_to_quit signal")

func _on_about_to_quit() -> void:
	print("[GameState] _on_about_to_quit() -> saving before quit")
	save()

func schedule_save() -> void:
	if _restoring_inventory or suppress_inventory_autosave or _save_scheduled:
		return
	_save_scheduled = true
	call_deferred("_perform_scheduled_save")

func _perform_scheduled_save() -> void:
	_save_scheduled = false
	if not _restoring_inventory:
		save()

func set_checkpoint(scene_path: String, pos: Vector2) -> void:
	checkpoint_scene = scene_path
	checkpoint_position = pos
	push_warning("[GameState] ✅ Checkpoint set: %s %s" % [scene_path, str(pos)])

func has_checkpoint() -> bool:
	return checkpoint_scene != ""

func get_respawn_data() -> Dictionary:
	return {"scene": checkpoint_scene, "position": checkpoint_position}

# change save() to return the ResourceSaver result code (int)
func save() -> int:
	var err := 0
	var scene_path := ""
	var pos := Vector2.ZERO
	if has_checkpoint():
		scene_path = checkpoint_scene
		pos = checkpoint_position
	elif get_tree().current_scene:
		scene_path = get_tree().current_scene.scene_file_path
	err = save_game(scene_path, pos)

	print("[GameState] save() ->", err)
	return err  # now returns int

func _inventory_debug_label(inv_resource) -> String:
	if inv_resource == null or not ("slots" in inv_resource):
		return "missing"
	var labels: Array[String] = []
	for slot in inv_resource.slots:
		if slot != null and "item" in slot and slot.item != null:
			labels.append(str(slot.item.resource_path if slot.item is Resource else slot.item))
		else:
			labels.append("empty")
	return ",".join(labels)

func _saved_item_paths(entries: Array) -> String:
	var labels: Array[String] = []
	for entry in entries:
		var path := str(entry.get("resource_path", entry.get("scene_path", ""))).strip_edges()
		labels.append(path if path != "" else "empty")
	return ",".join(labels)

# change save_game to return the err code from ResourceSaver.save
func save_game(scene_path: String = "", pos: Vector2 = Vector2.ZERO) -> int:
	# Fill defaults
	if scene_path == "":
		if has_checkpoint():
			scene_path = checkpoint_scene
			pos = checkpoint_position
		elif get_tree().current_scene:
			scene_path = get_tree().current_scene.scene_file_path

	# store runtime fields
	saved_scene = scene_path
	saved_position = pos

	# Create SaveData resource instance
	var save_res := SaveDataResource.new()
	save_res.scene_path = saved_scene
	save_res.position = saved_position
	save_res.saved_at_unix = 0  # keep zero to avoid analyzer/OS calls

	# --- Collect player's inventory into a simple serializable array ---
	var inventory_array: Array = []

	# Persist the main inventory used by pickups and Inv_UI. PlayerInv is a
	# separate equipment inventory and must not be used for this save data.
	var inventory_ui = get_tree().root.find_child("Inv_UI", true, false)
	if inventory_ui and "inv" in inventory_ui and inventory_ui.inv != null:
		for s in inventory_ui.inv.slots:
			var entry := {"scene_path": "", "resource_path": "", "amount": 0}
			if s != null:
				if "item" in s and s.item != null:
					if s.item is Resource:
						entry.resource_path = str(s.item.resource_path)
					if "scene_path" in s.item and str(s.item.scene_path) != "":
						entry.scene_path = str(s.item.scene_path)
				if "amount" in s:
					entry.amount = int(s.amount)
			inventory_array.append(entry)

	var equipment_array: Array = []
	var equipment_ui = get_tree().root.find_child("PlayerInv", true, false)
	if equipment_ui and "inv" in equipment_ui and equipment_ui.inv != null:
		print("[GameState] SAVE equipment slots:", _inventory_debug_label(equipment_ui.inv))
		for s in equipment_ui.inv.slots:
			var equipment_entry := {"scene_path": "", "resource_path": "", "amount": 0}
			if s != null:
				if "item" in s and s.item != null:
					if s.item is Resource:
						equipment_entry.resource_path = str(s.item.resource_path)
					if "scene_path" in s.item and str(s.item.scene_path) != "":
						equipment_entry.scene_path = str(s.item.scene_path)
				if "amount" in s:
					equipment_entry.amount = int(s.amount)
			equipment_array.append(equipment_entry)

	# store collected inventory (may be empty)
	save_res.inventory = inventory_array
	save_res.equipment_inventory = equipment_array
	# Keep the in-memory cache synchronized with the same snapshot written to disk.
	# Death respawn can restore before the autoload is reloaded from user://.
	saved_inventory = inventory_array.duplicate(true)
	saved_equipment_inventory = equipment_array.duplicate(true)
	save_res.opened_chests = opened_chests.duplicate(true)
	# --- protect existing on-disk intro_shown so we don't overwrite true with false ---
	# --- protect existing on-disk intro_shown so we don't overwrite true with false ---
	var disk_intro = null
	if FileAccess.file_exists(SAVE_PATH):
		var existing := ResourceLoader.load(SAVE_PATH)
		if existing:
			# prefer generic get() if available
			if existing.has_method("get"):
				disk_intro = existing.get("intro_shown")
			else:
				if "intro_shown" in existing:
					disk_intro = existing.intro_shown

	# final_intro = runtime OR disk truth (preserve any true)
	var final_intro := bool(intro_shown)
	if disk_intro != null:
		final_intro = final_intro or bool(disk_intro)

	save_res.intro_shown = final_intro
	save_res.greeted_npcs = greeted_npcs.duplicate(true)

	# quests snapshot code (if your SaveData has a saved_quests field, populate it here)
	# if Engine.has_singleton("QuestManager") and QuestManager.has_method("snapshot_save"):
	#     save_res.saved_quests = QuestManager.snapshot_save()

	# --- Persist resource to disk (correct order: resource, path) ---
	# Debug: preview and summary before saving
	var inv_count := 0
	if save_res.inventory != null:
		inv_count = save_res.inventory.size()
	var opened_count := 0
	if save_res.opened_chests != null:
		opened_count = save_res.opened_chests.size()
	var greeted_keys := []
	if save_res.greeted_npcs != null:
		for k in save_res.greeted_npcs.keys():
			greeted_keys.append(str(k))
	var saved_at = save_res.saved_at_unix if ("saved_at_unix" in save_res) else "MISSING"

	var preview_intro = "MISSING"
	# robustly extract intro_shown for runtime / resource variants
	if typeof(save_res) == TYPE_OBJECT and save_res.has_method("get"):
		# resource wrapper may expose get()
		# wrap in safe call
		var ok_get := true
		preview_intro = "MISSING"
		# safe-probe
		# (some resource wrapper implementations might throw; guard it)
		if ok_get:
			preview_intro = str(save_res.get("intro_shown"))
	elif "intro_shown" in save_res:
		preview_intro = str(save_res.intro_shown)
	else:
		preview_intro = str(intro_shown)

	var summary := "SCENE:%s POS:%s INTRO:%s INV_COUNT:%d OPENED:%d GREETED:%s SAVED_AT:%s" % [
		saved_scene,
		str(saved_position),
		preview_intro,
		inv_count,
		opened_count,
		str(greeted_keys),
		str(saved_at)
	]
	print("[GameState] (DEBUG) about to ResourceSaver.save; summary ->", summary)

	var err := ResourceSaver.save(save_res, SAVE_PATH)

	if err != OK:
		push_error("[GameState] Save failed (err=%s). SavePath=%s" % [str(err), SAVE_PATH])
	else:
		print("[GameState] 💾 ResourceSaver.save returned OK for", SAVE_PATH)
	print("[GameState] (DEBUG) saved_scene:", saved_scene, " saved_position:", saved_position, " inventory_count:", inv_count, " opened_count:", opened_count, " intro_shown:", preview_intro)
	return err  # <<--- return the error code so callers can inspect it

func has_save() -> bool:
	return saved_scene != ""

func load_save() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		print("[GameState] No save file found at %s" % SAVE_PATH)
		return false

	var res := ResourceLoader.load(SAVE_PATH)
	if not res:
		push_error("[GameState] Failed to load save resource at: %s" % SAVE_PATH)
		return false

	if res is SaveData:
		# load_save() inside the SaveData branch:
		# --- existing code ---
		saved_scene = res.scene_path
		saved_position = res.position
		opened_chests = res.opened_chests.duplicate(true) if res.opened_chests != null else []
		saved_inventory = res.inventory.duplicate(true) if res.inventory != null else []
		saved_equipment_inventory = res.equipment_inventory.duplicate(true) if res.equipment_inventory != null else []
		print("[GameState] LOAD cache main:", saved_inventory.size(), " equipment:", saved_equipment_inventory.size(), " paths:", _saved_item_paths(saved_equipment_inventory))

		# --- new: load intro/greet fields safely (defensive) ---
		var maybe_intro = null
		var maybe_g = null

		# Prefer the generic get() method if available (works for un-typed Resource wrappers)
		if res.has_method("get"):
			maybe_intro = res.get("intro_shown")
			maybe_g = res.get("greeted_npcs")
		else:
			# fallback: try direct property access if the object exposes it
			if "intro_shown" in res:
				maybe_intro = res.intro_shown
			if "greeted_npcs" in res:
				maybe_g = res.greeted_npcs

		intro_shown = bool(maybe_intro) if maybe_intro != null else false
		greeted_npcs = maybe_g.duplicate(true) if maybe_g != null else {}
		print("[GameState] load() finished; intro_shown ->", intro_shown)
		# --- Restore quests into QuestManager if data present ---
		if Engine.has_singleton("QuestManager") and res.saved_quests != null:
			# prefer new API name apply_save_snapshot(snapshot)
			if QuestManager.has_method("apply_save_snapshot"):
				QuestManager.apply_save_snapshot(res.saved_quests)
			# backward compatibility: some older code used load_from_save
			elif QuestManager.has_method("load_from_save"):
				QuestManager.load_from_save(res.saved_quests)
			else:
				print("[GameState] Save contains quest data but QuestManager lacks apply_save_snapshot/load_from_save")
		applied_save = true
		print("[GameState] load_save() finished; applied_save ->", applied_save)
		print("[GameState] ✅ Save loaded: %s %s" % [saved_scene, str(saved_position)])
		print("[GameState] Loaded persisted flags -> intro_shown:", intro_shown, " greeted_npcs keys:", greeted_npcs.keys())
		return true

	push_error("[GameState] Unexpected save resource type")
	return false

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
	print("[StartupTiming] inventory restore begin ms:", Time.get_ticks_msec())
	_restoring_inventory = true

	# Restore the main inventory used by pickups and Inv_UI. PlayerInv is the
	# separate equipment inventory and should remain independent.
	var inventory_ui := get_tree().root.find_child("Inv_UI", true, false)
	var target_inv_res = inventory_ui.inv if inventory_ui and "inv" in inventory_ui else null

	if target_inv_res != null:
		print("[GameState] Restoring saved inventory -> Inv_UI.inv (saved slots:", saved_inventory.size(), ")")
		# Clear existing and re-populate
		target_inv_res.slots.clear()
		for e in saved_inventory:
			var scene_path := str(e.get("resource_path", e.get("scene_path", ""))).strip_edges()
			var amount := int(e.get("amount", 0))

			var item_res: Resource = null
			var base := ""   # ensure defined for later use

			# try load directly (may return InvItem resource or PackedScene)
			if scene_path != "" and ResourceLoader.exists(scene_path):
				item_res = ResourceLoader.load(scene_path)

			# if we loaded a PackedScene, try to map to a likely InvItem resource
			if item_res != null and item_res.get_class() == "PackedScene":
				# derive basename for guess attempts
				base = scene_path.get_file().get_basename() # e.g. "pitchfork"
				var guessed := "res://resources/%s_res.tres" % base
				if ResourceLoader.exists(guessed):
					var alt := ResourceLoader.load(guessed)
					if alt != null:
						item_res = alt
						print("[GameState] Found InvItem resource via guessed path:", guessed)
				else:
					var guessed2 := "res://resources/%s.tres" % base
					if ResourceLoader.exists(guessed2):
						var alt2 := ResourceLoader.load(guessed2)
						if alt2 != null:
							item_res = alt2
							print("[GameState] Found InvItem resource via guessed path:", guessed2)

			# never keep a PackedScene as the item_res
			if item_res != null and item_res.get_class() == "PackedScene":
				item_res = null

			# If we still don't have an InvItem resource, create a lightweight placeholder (if class exists)
			if item_res == null:
				if ClassDB.class_exists("InvItem"):
					var placeholder = InvItem.new()
					# try to set useful fields so UI/logic can use it
					if "scene_path" in placeholder:
						placeholder.scene_path = scene_path
					# ensure base is available for name fallback
					if base == "" and scene_path != "":
						base = scene_path.get_file().get_basename()
					if "name" in placeholder:
						placeholder.name = base if base != "" else "unknown_item"
					item_res = placeholder
					print("[GameState] Created placeholder InvItem for scene_path:", scene_path)
				else:
					print("[GameState] WARNING: No InvItem class available; saved item skipped:", scene_path)

			# Append slot (either populated or empty to keep inventory size)
			var slot := InvSlot.new()
			if item_res != null:
				slot.item = item_res
				slot.amount = amount
			else:
				slot.item = null
				slot.amount = 0
			target_inv_res.slots.append(slot)

		# Notify UI
		if inventory_ui.has_method("update_slots"):
			inventory_ui.update_slots()

		var equipment_ui := get_tree().root.find_child("PlayerInv", true, false)
		if equipment_ui and "inv" in equipment_ui and equipment_ui.inv != null:
			equipment_ui.inv.slots.clear()
			for e in saved_equipment_inventory:
				var item_path := str(e.get("resource_path", e.get("scene_path", ""))).strip_edges()
				var item_res: Resource = null
				if item_path != "":
					item_res = load(item_path)
				print("[GameState] RESTORE equipment item:", item_path if item_path != "" else "empty", " loaded:", item_res != null)
				if item_res != null and item_res.get_class() != "PackedScene":
					var equipment_slot := InvSlot.new()
					equipment_slot.item = item_res
					equipment_slot.amount = int(e.get("amount", 0))
					equipment_ui.inv.slots.append(equipment_slot)
			if equipment_ui.has_method("update_slots"):
				equipment_ui.update_slots()
			print("[GameState] RESTORE equipment slots:", _inventory_debug_label(equipment_ui.inv))

			# Re-equip the primary weapon from the restored resource slot. This
			# avoids depending on UI visuals or an earlier refresh during respawn.
			if equipment_ui.slots.size() > 0 and equipment_ui.inv.slots.size() > 0:
				var primary_item = equipment_ui.inv.slots[0].item
				if primary_item != null and "scene_path" in primary_item and str(primary_item.scene_path) != "":
					if player.has_method("equip_weapon"):
						player.equip_weapon(primary_item.scene_path)
						player.using_secondary = false
		_restoring_inventory = false
		print("[StartupTiming] inventory restore end ms:", Time.get_ticks_msec())
		return

	# Fallback: try player's public API (add_to_inventory) — this is safer for player-side logic
	if player.has_method("add_to_inventory"):
		print("[GameState] Restoring saved inventory -> player.add_to_inventory()")
		for e in saved_inventory:
			var item_path := str(e.get("scene_path", ""))
			var amount := int(e.get("amount", 0))
			var item_res: Resource = null
			if item_path != "" and ResourceLoader.exists(item_path):
				item_res = ResourceLoader.load(item_path)
			if item_res != null:
				player.add_to_inventory(item_res, amount)
			else:
				# if not able to load, try passing path as fallback
				player.add_to_inventory(item_path, amount)
		_restoring_inventory = false
		return

	# Last resort: populate the player's inventory resource directly
	var inv_res = null
	if player.has_method("get_inventory"):
		inv_res = player.get_inventory()
	elif "inventory" in player:
		inv_res = player.inventory

	if inv_res != null and "slots" in inv_res:
		inv_res.slots.clear()
		for e in saved_inventory:
			var item_path := str(e.get("scene_path", ""))
			var amount := int(e.get("amount", 0))
			var item_res = null
			if item_path != "" and ResourceLoader.exists(item_path):
				item_res = ResourceLoader.load(item_path)
			if ClassDB.class_exists("InvSlot"):
				var slot = InvSlot.new()
				slot.item = item_res
				slot.amount = amount
				inv_res.slots.append(slot)
		print("[GameState] Restored saved inventory into fallback player.inv")
	_restoring_inventory = false

# Overwrite save with an empty SaveData resource (safer than attempting to delete file)
# in GameState.gd (replace existing delete_save_file)
func delete_save_file() -> void:
	print("[GameState] delete_save_file() called. STACK from here:")
	print_stack()
	# keep existing behavior (overwrite with blank SaveData)
	var blank := SaveDataResource.new()
	blank.scene_path = ""
	blank.position = Vector2.ZERO
	blank.inventory = []
	blank.equipment_inventory = []
	blank.opened_chests = []
	blank.intro_shown = false
	blank.greeted_npcs = {}
	var err := ResourceSaver.save(blank, SAVE_PATH)
	if err != OK:
		push_error("[GameState] Failed to overwrite save file: %s" % str(err))
	else:
		print("[GameState] Overwrote save file with empty SaveData:", SAVE_PATH)

	# clear runtime caches after overwrite
	saved_scene = ""
	saved_position = Vector2.ZERO
	saved_inventory = []
	saved_equipment_inventory = []
	opened_chests = []
	set_intro_shown(false)   # use setter so debug/emit_signal runs
	greeted_npcs = {}

# Convenience: reset runtime and on-disk save, used by New Game
func reset_save(start_scene: String = "res://scenes/world.tscn") -> void:
	checkpoint_scene = ""
	checkpoint_position = Vector2.ZERO
	saved_scene = ""
	saved_position = Vector2.ZERO
	saved_inventory = []
	saved_equipment_inventory = []
	opened_chests.clear()
	intro_shown = false
	# persist cleared state (write start scene so resume doesn't resurrect old save)
	save_game(start_scene, Vector2.ZERO)
	print("[GameState] Reset save and wrote fresh start scene:", start_scene)

# Query/set helpers for other scripts to call
func set_intro_shown(value: bool) -> void:
	# Print on every attempt to change the flag
	if intro_shown == value:
		print("[GameState] set_intro_shown called but no change ->", value)
		return
	print("[GameState] intro_shown changing:", intro_shown, "->", value)
	# show the call stack so we can trace who changed it
	print("[GameState] call stack for intro_shown change:")
	print_stack()
	intro_shown = value

func is_intro_shown() -> bool:
	# small debug whenever someone queries it
	# (callers already expect a boolean; we still return it)
	print("[GameState] is_intro_shown() ->", intro_shown)
	return intro_shown

func is_npc_greeted(npc_id: String) -> bool:
	if npc_id == "":
		return false
	return greeted_npcs.has(npc_id) and greeted_npcs[npc_id] == true

# in GameState.gd
func register_npc_greeted(npc_id: String, persist: bool = true) -> int:
	if npc_id == "":
		push_warning("[GameState] register_npc_greeted called with empty npc_id -> ignored")
		return ERR_INVALID_PARAMETER

	# avoid re-adding and re-saving if already present
	if greeted_npcs.has(npc_id) and greeted_npcs[npc_id] == true:
		print("[GameState] register_npc_greeted -> already registered:", npc_id)
		return OK

	greeted_npcs[npc_id] = true
	print("[GameState] register_npc_greeted -> new entry:", npc_id, " persist:", persist)

	if persist:
		var err := save()
		print("[GameState] register_npc_greeted: GameState.save() returned:", err)
		return err

	return OK
