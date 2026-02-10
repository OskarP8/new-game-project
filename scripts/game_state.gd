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
	var player := get_tree().root.find_child("Player", true, false)
	if player:
		var inv_res = null
		if player.has_method("get_inventory"):
			inv_res = player.get_inventory()
		elif "inventory" in player:
			inv_res = player.inventory

		if inv_res and "slots" in inv_res:
			for slot in inv_res.slots:
				if slot != null and "item" in slot and slot.item != null:
					var item_path := ""
					# prefer scene_path or resource_path depending on how your InvItem is saved
					if "scene_path" in slot.item:
						item_path = str(slot.item.scene_path)
					elif "resource_path" in slot.item:
						item_path = str(slot.item.resource_path)
					inventory_array.append({"scene_path": item_path, "amount": int(slot.amount if "amount" in slot else 1)})

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

	var inv_res = null
	if player.has_method("get_inventory"):
		inv_res = player.get_inventory()
	elif "inventory" in player:
		inv_res = player.inventory

	# Prefer player's public API if available
	if player.has_method("add_to_inventory"):
		for e in saved_inventory:
			if ("scene_path" in e) and ("amount" in e):
				var amount_val := int(e["amount"])
				var item_path := str(e["scene_path"])
				var item_res: Resource = null
				if item_path != "" and ResourceLoader.exists(item_path):
					item_res = ResourceLoader.load(item_path)
				if item_res != null:
					# expects an InvItem resource (or whatever your add_to_inventory accepts)
					player.add_to_inventory(item_res, amount_val)
				else:
					# fallback: try passing the path itself if your API accepts an identifier
					player.add_to_inventory(item_path, amount_val)
	else:
		# fallback: try to populate inv resource slots directly (less preferred)
		if inv_res != null and "slots" in inv_res:
			inv_res.slots.clear()
			for e in saved_inventory:
				if ("scene_path" in e) and ("amount" in e):
					var item_path := str(e["scene_path"])
					var item_res = null
					if item_path != "" and ResourceLoader.exists(item_path):
						item_res = ResourceLoader.load(item_path)
					# create InvSlot only if class exists
					if ClassDB.class_exists("InvSlot"):
						var slot = InvSlot.new()
						slot.item = item_res
						slot.amount = int(e["amount"])
						inv_res.slots.append(slot)

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
