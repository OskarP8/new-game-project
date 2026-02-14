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

# Runtime record of opened chests (keeps in-memory and saved to disk)
var opened_chests: Array = []

func _ready() -> void:
	load_save()

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

# ---------- Save / Load ----------
func save_game(scene_path: String = "", pos: Vector2 = Vector2.ZERO) -> void:
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

	# Prefer the runtime UI inventory (PlayerInv) if present — that is the 4-slot one you manipulate.
	var player_inv_ui := get_tree().root.find_child("PlayerInv", true, false)
	var inv_res = null
	if player_inv_ui and "inv" in player_inv_ui and player_inv_ui.inv != null:
		inv_res = player_inv_ui.inv
		print("[GameState] Using PlayerInv.inv for save (runtime UI inventory) slots:", inv_res.slots.size())
	else:
		# fallback to reading player's inventory resource (legacy / inspector-held)
		var player := get_tree().root.find_child("Player", true, false)
		if player:
			if player.has_method("get_inventory"):
				inv_res = player.get_inventory()
			elif "inventory" in player:
				inv_res = player.inventory
		print("[GameState] Using Player.inventory (fallback) for save:", inv_res)

	if inv_res and "slots" in inv_res:
		for slot in inv_res.slots:
			if slot != null and "item" in slot and slot.item != null:
				var item_path := ""
				if "scene_path" in slot.item:
					item_path = str(slot.item.scene_path)
				elif "resource_path" in slot.item:
					item_path = str(slot.item.resource_path)
				inventory_array.append({"scene_path": item_path, "amount": int(slot.amount if "amount" in slot else 1)})
	else:
		print("[GameState] WARNING: no valid inventory resource found to snapshot.")

	save_res.inventory = inventory_array
	# --- Save opened chests list ---
	save_res.opened_chests = opened_chests.duplicate(true)

	# Persist resource to disk (correct order: path, resource)
	var err := ResourceSaver.save(save_res, SAVE_PATH)
	if err != OK:
		push_error("[GameState] Save failed: %s" % str(err))
	else:
		print("[GameState] 💾 Game saved to %s scene:%s pos:%s" % [SAVE_PATH, saved_scene, str(saved_position)])

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
		# store raw inventory array so player can restore it later
		saved_inventory = res.inventory.duplicate(true) if res.inventory != null else []
		print("[GameState] ✅ Save loaded: %s %s" % [saved_scene, str(saved_position)])
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
	if saved_inventory == null or saved_inventory.size() == 0:
		return

	# Try to find the runtime PlayerInv UI (prefer this — it's the 4-slot runtime inv)
	var player_inv_ui := get_tree().root.find_child("PlayerInv", true, false)
	var target_inv_res = null

	if player_inv_ui and "inv" in player_inv_ui and player_inv_ui.inv != null:
		target_inv_res = player_inv_ui.inv
		print("[GameState] Restoring saved inventory -> PlayerInv.inv (slots:", target_inv_res.slots.size(), ")")
		# Clear existing and re-populate
		# inside the PlayerInv.inv restore branch (replace the existing loop)
		target_inv_res.slots.clear()
		for e in saved_inventory:
			var scene_path := str(e.get("scene_path", "")).strip_edges()
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
		if player_inv_ui.has_method("update_slots"):
			player_inv_ui.update_slots()
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

# Overwrite save with an empty SaveData resource (safer than attempting to delete file)
func delete_save_file() -> void:
	# write an empty SaveData resource to represent "no save"
	var blank := SaveDataResource.new()
	blank.scene_path = ""
	blank.position = Vector2.ZERO
	blank.inventory = []
	blank.opened_chests = []
	var err := ResourceSaver.save(blank, SAVE_PATH)
	if err != OK:
		push_error("[GameState] Failed to overwrite save file: %s" % str(err))
	else:
		print("[GameState] Overwrote save file with empty SaveData:", SAVE_PATH)

	# always clear runtime caches after overwrite
	saved_scene = ""
	saved_position = Vector2.ZERO
	saved_inventory = []
	opened_chests = []

# Convenience: reset runtime and on-disk save, used by New Game
func reset_save(start_scene: String = "res://scenes/world.tscn") -> void:
	checkpoint_scene = ""
	checkpoint_position = Vector2.ZERO
	saved_scene = ""
	saved_position = Vector2.ZERO
	saved_inventory = []
	opened_chests.clear()
	# persist cleared state (write start scene so resume doesn't resurrect old save)
	save_game(start_scene, Vector2.ZERO)
	print("[GameState] Reset save and wrote fresh start scene:", start_scene)
