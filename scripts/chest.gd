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
	print("[Chest] Attempting interaction with:", player)
	
	# Defensive: player must exist
	if player == null:
		print("[Chest] ⚠ No player passed to interact().")
		return

	# Prevent double opening while animation plays
	if is_open:
		print("[Chest] ⚠ Already open, ignoring interact.")
		return

	# Get inventory resource
	var player_inv_res = null
	if player.has_method("get_inventory"):
		player_inv_res = player.get_inventory()
	elif "inventory" in player:
		player_inv_res = player.inventory

	if player_inv_res == null:
		print("[Chest] ⚠ Player inventory resource not found, cannot open chest.")
		return

	# Gather required items
	var required: Array = []
	for entry in slots:
		if entry and entry.item:
			required.append({"item": entry.item, "quantity": entry.quantity})

	if required.size() == 0:
		print("[Chest] ⚠ Chest empty, skipping.")
		return

	print("[Chest] 🧭 Checking player inventory for required space...")

	# Check if inventory has room
	var has_space: bool = _player_has_space_for(player_inv_res, required)
	if not has_space:
		print("[Chest] 🚫 Inventory full — chest won't open")
		var inv_ui = get_tree().root.find_child("Inv_UI", true, false)
		if inv_ui and inv_ui.has_method("show_message"):
			inv_ui.show_message("Inventory Full")
		is_open = false # ✅ ensure it doesn’t mark itself open
		return

	# ✅ Passed space check
	is_open = true
	print("[Chest] ✅ Opened by:", player.name if "name" in player else player)

	# Hide prompt
	if prompt:
		if prompt.has_method("hide_prompt"):
			prompt.hide_prompt()
		else:
			prompt.visible = false

	# Animation
	if animations and animations.has_animation("open"):
		animations.play("open")
		await animations.animation_finished

	# Spawn items visually
	for entry in slots:
		if entry and entry.item:
			spawn_and_collect(player, entry)

	# Give items
	if player.has_method("add_to_inventory"):
		for entry in slots:
			if entry.item == null:
				continue

			if player.has_method("_is_non_stackable") and player._is_non_stackable(entry.item):
				for i in range(entry.quantity):
					player.add_to_inventory(entry.item, 1)
			else:
				player.add_to_inventory(entry.item, entry.quantity)
	else:
		print("[Chest] ⚠ Player missing add_to_inventory()")

	# Clean up
	slots.clear()
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = true
	print("[Chest] 🧹 Chest cleared and disabled")


func _player_has_space_for(player_inv_res, required: Array) -> bool:
	if player_inv_res == null or not ("slots" in player_inv_res):
		return false

	var sim_slots: Array = []
	for s in player_inv_res.slots:
		var entry = {"item": null, "amount": 0, "max_stack": 1}
		if s != null:
			if "item" in s and s.item != null:
				entry.item = s.item
			if "amount" in s:
				entry.amount = s.amount
		sim_slots.append(entry)

	for need in required:
		var item = need["item"]
		var qty = int(need["quantity"])

		# Determine stacking rule
		var item_max_stack := 1
		if "max_stack" in item:
			item_max_stack = int(item.max_stack)
		elif "stackable" in item:
			item_max_stack = 99 if item.stackable else 1

		# ✅ If no empty slots and no stack space, fail
		var total_free := 0
		for s in sim_slots:
			if s["item"] == null:
				total_free += item_max_stack
			elif s["item"] == item and s["amount"] < item_max_stack:
				total_free += item_max_stack - s["amount"]

		if total_free < qty:
			print("[Chest] ✖ Not enough room for", item.name if "name" in item else "unknown", "needs:", qty, "has:", total_free)
			return false

		# ✅ Simulate filling slots (so future items also count)
		var remaining = qty
		for s in sim_slots:
			if remaining <= 0:
				break
			if s["item"] == item and s["amount"] < item_max_stack:
				var can_put = min(item_max_stack - s["amount"], remaining)
				s["amount"] += can_put
				remaining -= can_put
			elif s["item"] == null:
				var put = min(item_max_stack, remaining)
				s["item"] = item
				s["amount"] = put
				remaining -= put

	return true

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
