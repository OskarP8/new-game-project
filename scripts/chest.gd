extends Node2D
class_name Chest

@export var slots: Array[InventoryEntry] = []
@onready var animations: AnimationPlayer = $AnimationPlayer
@onready var item_start_pos: Marker2D = $ItemStartPos
@onready var item_end_pos: Marker2D = $ItemEndPos
@onready var prompt_scene = preload("res://scenes/interact_prompt.tscn")
var prompt: Node2D = null

var is_open: bool = false

func interact(player: Node2D) -> void:
	if is_open:
		print("[Chest] ⚠ Already open, ignoring interact.")
		return

	# --- CHECK INVENTORY SPACE BEFORE OPENING ---
	var inv_ui = get_tree().root.find_child("Inv_UI", true, false)
	var has_space := false

	if inv_ui and inv_ui.inv:
		print("[Chest] 🧭 Checking player inventory slots for space...")
		for slot in inv_ui.inv.slots:
			# Print each slot state
			print("   → Slot:", slot, " item:", slot.item if "item" in slot else "N/A")

			# Some slots may not have an item yet or explicitly have null
			if slot.item == null:
				has_space = true
				print("   ✅ Found empty slot:", slot)
				break
	else:
		print("[Chest] ⚠️ Could not find inventory UI or inv object")

	if not has_space:
		print("[Chest] 🚫 Inventory full — chest won't open")
		_show_inventory_full_message()
		return

	# --- OPEN CHEST ---
	is_open = true
	print("[Chest] ✅ Opened by:", player.name)

	# Hide prompt (if still visible)
	if prompt:
		if prompt.has_method("hide_prompt"):
			prompt.hide_prompt()
			print("[Chest] 🔹 Hiding prompt via hide_prompt()")
		else:
			prompt.visible = false
			print("[Chest] 🔹 Hiding prompt manually")

	# Animation
	if animations and animations.has_animation("open"):
		print("[Chest] ▶ Playing 'open' animation")
		animations.play("open")
		await animations.animation_finished
		print("[Chest] 🎬 Animation finished")
	else:
		print("[Chest] ⚠ No animation or AnimationPlayer missing")

	# --- SPAWN ITEMS VISUALLY ---
	for entry in slots:
		print("[Chest] Spawning item:", entry.item, "x", entry.quantity)
		spawn_and_collect(player, entry)

	# --- GIVE ITEMS TO PLAYER ---
	if player and player.has_method("add_to_inventory"):
		for entry in slots:
			if entry.item == null:
				print("[Chest] ⚠ Empty slot skipped")
				continue

			if player.has_method("_is_non_stackable") and player._is_non_stackable(entry.item):
				print("[Chest] Non-stackable:", entry.item.name, "x", entry.quantity)
				for i in range(entry.quantity):
					if not player.add_to_inventory(entry.item, 1):
						_show_inventory_full_message()
						print("[Chest] 🚫 Inventory full mid-transfer, stopping.")
						return
					print("[Chest] ➕ Added 1x", entry.item.name, "to player inventory")
			else:
				if not player.add_to_inventory(entry.item, entry.quantity):
					_show_inventory_full_message()
					print("[Chest] 🚫 Inventory full mid-transfer, stopping.")
					return
				print("[Chest] ➕ Added", entry.quantity, "x", entry.item.name, "to player inventory")
	else:
		push_warning("[Chest] ⚠ Player missing add_to_inventory() or null")

	# Clear slots after giving items
	slots.clear()
	print("[Chest] 🧹 Slots cleared")

	# Disable collision after opening (optional)
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = true
		print("[Chest] ⛔ Collision disabled")

func spawn_and_collect(player: Node2D, entry: InventoryEntry) -> void:
	if entry.item == null:
		print("[Chest] ⚠ spawn_and_collect called with null item")
		return

	var item: InvItem = entry.item

	for i in range(entry.quantity):
		var sprite := Sprite2D.new()
		sprite.texture = item.texture
		sprite.z_index = int(global_position.y)
		var offset := Vector2(randf_range(-2, 2), randf_range(-2, 2))
		sprite.global_position = item_start_pos.global_position + offset

		var resources_node := get_tree().root.get_node_or_null("world/layers/Resources")
		if resources_node == null:
			push_warning("[Chest] ⚠ Missing world/layers/Resources node — adding to current_scene instead")
			resources_node = get_tree().current_scene
		resources_node.add_child(sprite)

		print("[Chest] ✨ Item sprite spawned at:", sprite.global_position)

		var tween := create_tween()
		tween.tween_property(sprite, "global_position", item_end_pos.global_position + offset, 0.3)
		await tween.finished
		print("[Chest] 📦 Item reached end position")

		var tween_collect := create_tween()
		tween_collect.tween_property(sprite, "global_position", player.global_position, 0.5)
		tween_collect.tween_callback(Callable(sprite, "queue_free"))
		print("[Chest] 💨 Item flying to player")


func _process(delta):
	z_index = int(global_position.y)

func _show_inventory_full_message():
	var ui := get_tree().get_root().get_node("world/UI") # adjust if needed
	if ui and ui.has_method("show_notification"):
		ui.show_notification("Inventory Full")
	else:
		print("[UI] ⚠️ Inventory Full (UI handler missing)")
