extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $".".get_children()

var is_open := false
var picked_slot: InvSlot = null
var drag_layer: CanvasLayer
var dragging := false
var ghost_item: ItemStackUI = null

func _ready():
	if inv:
		inv.inventory_changed.connect(update_slots)
	else:
		print("[player_inv] ⚠ No Inv resource assigned!")

	for s in slots:
		if s is InvUISlot:
			s.item_dropped_from_slot.connect(_on_item_dropped_from_slot)

	# create a dedicated CanvasLayer for drag ghosts and ensure it is on top
	drag_layer = CanvasLayer.new()
	# use a high layer so it renders above everything
	drag_layer.layer = 100
	# add to scene root deferred (safe during _ready)
	get_tree().root.call_deferred("add_child", drag_layer)

	update_slots()
	for slot in slots:
		if slot and slot.has_method("update_visual"):
			slot.update_visual()
	close()
func _process(_delta):
	if Input.is_action_just_pressed("i"):
		if is_open:
			close()
		else:
			open()

	# update ghost position if dragging
	if dragging and ghost_item and is_instance_valid(ghost_item):
		if ghost_item.has_method("get_rect"):
			ghost_item.global_position = get_viewport().get_mouse_position() - ghost_item.get_rect().size * 0.5
		else:
			ghost_item.global_position = get_viewport().get_mouse_position()

# --- Inventory toggle ---
func open():
	visible = true
	is_open = true
	update_slots()
	for slot in slots:
		if slot and slot.has_method("update_visual"):
			slot.update_visual()

func close():
	visible = false
	is_open = false

# --- Update UI ---
func update_slots() -> void:
	if inv == null:
		print("[player_inv] ⚠ No inventory resource assigned!")
		return

	print("[player_inv] 🔄 Updating slots — total:", slots.size())

	for i in range(slots.size()):
		var ui_slot: InvUISlot = slots[i]

		# Ensure resource slot exists
		while inv.slots.size() <= i:
			inv.slots.append(InvSlot.new())

		if inv.slots[i] == null:
			inv.slots[i] = InvSlot.new()

		var inv_slot: InvSlot = inv.slots[i]
		# If we're currently dragging from this slot, remove the UI visual so the slot
		# truly looks empty and can be recreated when the drag ends or restored.
		if picked_slot != null and inv_slot == picked_slot and ghost_item and is_instance_valid(ghost_item):
			if ui_slot.item_stack:
				# remove the visual now so it can't remain invisible after the drag
				ui_slot.item_stack.queue_free()
				ui_slot.item_stack = null
			continue

		# Clean up invalid references
		if ui_slot.item_stack and not is_instance_valid(ui_slot.item_stack):
			ui_slot.item_stack = null

		# No item → remove any visuals
		if inv_slot.item == null:
			if ui_slot.item_stack:
				print("[player_inv] 🧹 Clearing slot", i)
				ui_slot.item_stack.queue_free()
				ui_slot.item_stack = null
			continue

		# Create or reuse ItemStackUI
		var item_stack: ItemStackUI = ui_slot.item_stack
		if item_stack == null:
			item_stack = isgc.instantiate()
			ui_slot.insert(item_stack)
			ui_slot.item_stack = item_stack
			print("[player_inv] 🧩 Created new ItemStackUI for slot", i)
		else:
			print("[player_inv] ♻ Reusing existing ItemStackUI for slot", i)

		# Connect the click signal every time (safe rebind)
		if not item_stack.clicked.is_connected(Callable(self, "_on_item_clicked")):
			item_stack.clicked.connect(Callable(self, "_on_item_clicked"))
			print("[player_inv] ✅ Connected clicked signal for slot", i, "→", inv_slot.item.name)
		else:
			print("[player_inv] (already connected) slot", i)

		item_stack.slot = inv_slot
		item_stack.update()

# Helper: place a world item under the world's Resources/YSort node and set z_index
func _spawn_world_item(world_item: Node2D, spawn_pos: Vector2) -> void:
	# set global position first (so Y calculations use world coords)
	world_item.global_position = spawn_pos

	# choose parent using helper
	var parent := _get_world_ysort_parent()
	if parent == null:
		parent = get_tree().current_scene if get_tree().current_scene else get_tree().root

	# Robust YSort detection: check class name, heuristic method, or node name
	var parent_is_ysort := false
	if parent != null:
		var cls := ""
		if parent.has_method("get_class"):
			cls = parent.get_class()
		# check common indicators
		parent_is_ysort = (cls == "YSort") or parent.has_method("sort_children") or (str(parent.name).to_lower().find("y-sort") != -1)

	# If parent is NOT a YSort, set z_index so manual ordering still works.
	if not parent_is_ysort:
		# prefer a z_index near the y to keep visual ordering; +1 to avoid being behind ground
		if "z_index" in world_item:
			world_item.z_index = int(spawn_pos.y) + 1

	# add to chosen parent (YSort will sort automatically by global y)
	parent.add_child(world_item)

func _on_item_clicked(item_stack: ItemStackUI) -> void:
	# Basic guard
	if item_stack == null or not is_instance_valid(item_stack):
		print("[player_inv][_on_item_clicked] ❌ item_stack invalid or null")
		return

	# Already dragging? ignore extra clicks
	if ghost_item:
		print("[player_inv][_on_item_clicked] ❌ already dragging a ghost:", ghost_item)
		return

	# Report click
	print("[player_inv][_on_item_clicked] clicked ItemStackUI:", item_stack, " parent:", item_stack.get_parent())

	# Resolve origin slot reference
	picked_slot = item_stack.slot
	print("[player_inv][_on_item_clicked] picked_slot:", picked_slot)

	if picked_slot == null:
		print("[player_inv][_on_item_clicked] ⚠ picked_slot is null — aborting")
		return

	# Print slot contents before clearing
	print("[player_inv][_on_item_clicked] origin slot BEFORE clear -> item:", picked_slot.item, " amount:", picked_slot.amount)

	# === Create ghost ===
	# Reuse the visual node if possible (keeps same scene)
	ghost_item = item_stack.duplicate() if item_stack else isgc.instantiate()
	# Ensure the ghost has no live slot reference (it's a visual only)
	ghost_item.slot = null

	# Preserve concrete origin data on ghost so update() shows texture/amount
	ghost_item.origin_item = picked_slot.item
	ghost_item.origin_amount = picked_slot.amount
	ghost_item.origin_slot = picked_slot

	# Force ghost to show the correct visual immediately
	ghost_item.call_deferred("update")
	ghost_item.visible = true

	# Defensive: ensure the ItemDisplay texture is set even if update delayed
	if ghost_item.item_visual and ghost_item.origin_item:
		ghost_item.item_visual.texture = ghost_item.origin_item.icon
		ghost_item.item_visual.visible = true

	# Make the ghost ignore mouse so it doesn't block events below
	ghost_item.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Give a reasonable size so it isn't tiny due to layout changes.
	# Try to size to the icon texture if available, fallback to 48x48.
	var tex_size = Vector2(48,48)
	if ghost_item.item_visual and ghost_item.item_visual.texture:
		tex_size = ghost_item.item_visual.texture.get_size()
	# clamp or scale down if extremely large
	var max_size = Vector2(96,96)
	if tex_size.x > max_size.x or tex_size.y > max_size.y:
		tex_size = tex_size.clamped(max_size)
	# Apply rect_size if available (Control)
	if "rect_size" in ghost_item:
		ghost_item.rect_size = tex_size
	# reset scale
	ghost_item.scale = Vector2.ONE

	# Immediately clear the origin slot so UI shows empty while dragging
	# NOTE: do NOT clear the underlying InvSlot resource here — keep the concrete
	# InvSlot data so inventory-refreshes don't treat the item as removed (which
	# causes equip/unequip races). We still want the visual to appear empty while
	# dragging, so hide the UI visual below in update_slots() when needed.
	print("[player_inv][_on_item_clicked] keeping origin InvSlot intact while dragging (picked_slot preserved)")

	# Refresh visuals so the original slot immediately appears empty
	update_slots()
	for slot in slots:
		if slot and slot.has_method("update_visual"):
			slot.update_visual()
	print("[player_inv][_on_item_clicked] update_slots() called")

	# Add ghost to our drag_layer (ensures it renders above UI/world)
	if drag_layer and is_instance_valid(drag_layer):
		# ensure ghost is not already parented
		if is_instance_valid(ghost_item.get_parent()):
			ghost_item.get_parent().remove_child(ghost_item)
		drag_layer.add_child(ghost_item)
	else:
		# fallback to root if something weird happens
		if is_instance_valid(ghost_item.get_parent()):
			ghost_item.get_parent().remove_child(ghost_item)
		get_tree().root.call_deferred("add_child", ghost_item)

	# position and z
	if ghost_item is Control:
		ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)
		ghost_item.z_index = 9999
		_update_ghost_position()

	# Force update/redraw to avoid delayed invisibility
	ghost_item.call_deferred("update")
	ghost_item.queue_redraw()

	print("[player_inv][_on_item_clicked] ghost created:", ghost_item, "at", ghost_item.global_position)
	dragging = true

func _update_ghost_position():
	if not ghost_item or not is_instance_valid(ghost_item):
		return
	var mouse_pos = get_viewport().get_mouse_position()
	var offset = Vector2.ZERO
	# prefer using rect_size if available
	if "rect_size" in ghost_item and ghost_item.rect_size != Vector2.ZERO:
		offset = ghost_item.rect_size * 0.5
	elif ghost_item is Control and ghost_item.size != Vector2.ZERO:
		offset = ghost_item.size * 0.5
	elif ghost_item.item_visual and ghost_item.item_visual.texture:
		offset = ghost_item.item_visual.texture.get_size() * 0.5
	else:
		offset = Vector2(24,24)
	ghost_item.global_position = mouse_pos - offset
# --- Drop handling ---
func _unhandled_input(event: InputEvent) -> void:
	# prefer group lookup (more robust across scenes)
	var player_node: Node = get_tree().get_first_node_in_group("Player")
	if player_node == null:
		player_node = get_tree().root.find_child("Player", true, false)
	print("[player_inv][DBG] resolved player_node ->", player_node, " groups(if node):", (player_node.get_groups() if player_node else "NULL"))

	if ghost_item == null or picked_slot == null:
		return

	if event is InputEventMouseButton and not event.pressed:
		var mouse_pos = get_viewport().get_mouse_position()
		var dropped := false
		var moving_item := ghost_item.origin_item
		var moving_amount := ghost_item.origin_amount
		var inv_ui := get_tree().root.find_child("Inv_UI", true, false)
		var player := get_tree().root.find_child("Player", true, false)

		# --- 1️⃣ Drop inside player equipment (PlayerInv) ---
		for idx in range(slots.size()):
			var slot_node = slots[idx]
			if not slot_node.get_global_rect().has_point(mouse_pos):
				continue

			var slot_type = slot_node.slot_type
			print("[player_inv][DBG] Hovered slot idx:", idx, "type:", slot_type, "→ moving_item:", moving_item, "moving_type:", moving_item.type if moving_item else "NULL")

			# guard: moving_item must exist
			if moving_item == null:
				print("[player_inv][ERR] moving_item is null, cancelling drop here")
				continue

			if not _can_accept_item(slot_type, moving_item.type):
				print("[player_inv] ❌ Can't place", moving_item.type, "into", slot_type)
				continue

			var target_slot: InvSlot = null
			if inv.slots.size() > idx:
				target_slot = inv.slots[idx]
			if target_slot == null:
				target_slot = InvSlot.new()
				inv.slots[idx] = target_slot

			# DEBUG helper print of player state before equip
			if player_node:
				_debug_player_state(player_node, "before equip")

			# helper to pick equip arg (PackedScene or resource)
			var equip_arg = null
			if moving_item and moving_item.scene_path != "" and ResourceLoader.exists(moving_item.scene_path):
				print("[player_inv][DBG] moving_item.scene_path exists:", moving_item.scene_path)
				equip_arg = ResourceLoader.load(moving_item.scene_path)
			else:
				print("[player_inv][DBG] no valid scene_path; using InvItem resource as equip_arg")
				equip_arg = moving_item

			# Place or swap
			if target_slot.item == null:
				print("[player_inv] ✅ Placed", moving_item.name, "in", slot_type)
				target_slot.item = moving_item
				target_slot.amount = moving_amount

				# ensure target_slot.item = moving_item (already set above)
				if player_node and slot_type.to_lower() == "weapon":
					if moving_item and moving_item.scene_path != "" and ResourceLoader.exists(moving_item.scene_path):
						var scene_path = moving_item.scene_path
						# set suppression immediately so refresh won't unequip
						player_node.set_meta("suppress_unequip", true)
						# deferred equip with the same call style as swap path
						player_node.call_deferred("equip_weapon", scene_path)
						# clear suppression next frame
						player_node.call_deferred("set_meta", "suppress_unequip", false)
						# immediate UI refresh deferred
						player_node.call_deferred("refresh_equipped_weapon_from_inventory")
						if ghost_item and is_instance_valid(ghost_item):
							if moving_item.icon and "item_visual" in ghost_item:
								ghost_item.item_visual.texture = moving_item.icon
							elif moving_item.texture and "item_visual" in ghost_item:
								ghost_item.item_visual.texture = moving_item.texture
							ghost_item.call_deferred("update")
							_update_item_in_hand()
						print("[player_inv][DBG] scheduled deferred equip_weapon with scene_path:", scene_path)

			elif target_slot.item:
				# swap: put moving_item into target; return existing item to picked_slot
				print("[player_inv] 🔄 Swapped", moving_item.name, "with existing item")
				var tmp_item = target_slot.item
				var tmp_amt = target_slot.amount
				target_slot.item = moving_item
				target_slot.amount = moving_amount
				picked_slot.item = tmp_item
				picked_slot.amount = tmp_amt

				# equip new item if weapon
				# ensure target_slot.item = moving_item (already set above)
				if player_node and slot_type.to_lower() == "weapon":
					if moving_item and moving_item.scene_path != "" and ResourceLoader.exists(moving_item.scene_path):
						var scene_path = moving_item.scene_path
						# set suppression immediately so refresh won't unequip
						player_node.set_meta("suppress_unequip", true)
						# deferred equip with the same call style as swap path
						player_node.call_deferred("equip_weapon", scene_path)
						# clear suppression next frame
						player_node.call_deferred("set_meta", "suppress_unequip", false)
						# immediate UI refresh deferred
						player_node.call_deferred("refresh_equipped_weapon_from_inventory")
						if ghost_item and is_instance_valid(ghost_item):
							if moving_item.icon and "item_visual" in ghost_item:
								ghost_item.item_visual.texture = moving_item.icon
							elif moving_item.texture and "item_visual" in ghost_item:
								ghost_item.item_visual.texture = moving_item.texture
							ghost_item.call_deferred("update")
							_update_item_in_hand()
						print("[player_inv][DBG] scheduled deferred equip_weapon with scene_path:", scene_path)

			# AFTER equip: more debugging to catch race/overwrite
			if player_node:
				_debug_player_state(player_node, "after equip")
				# print the player's current_weapon_scene if present
				if "current_weapon_scene" in player_node:
					print("[player_inv][DBG] player.current_weapon_scene:", player_node.current_weapon_scene, "parent:", (player_node.current_weapon_scene.get_parent() if player_node.current_weapon_scene and is_instance_valid(player_node.current_weapon_scene) else "NULL"))
				elif player_node.has_method("get_current_weapon_scene"):
					# optional method name
					print("[player_inv][DBG] player.get_current_weapon_scene() ->", player_node.get_current_weapon_scene())

			dropped = true
			break

		# --- 2️⃣ Drop into main inventory (Inv_UI) ---
		if not dropped and inv_ui and inv_ui.visible:
			for inv_slot_node in inv_ui.slots:
				if inv_slot_node.get_global_rect().has_point(mouse_pos):
					var idx = inv_ui.slots.find(inv_slot_node)
					if idx == -1:
						continue
					var target_slot: InvSlot = inv_ui.inv.slots[idx]
					if target_slot == null:
						target_slot = InvSlot.new()
						inv_ui.inv.slots[idx] = target_slot

					if target_slot.item == null:
						print("[player_inv] ✅ Moved", moving_item.name, "to inventory")
						target_slot.item = moving_item
						target_slot.amount = moving_amount
					else:
						print("[player_inv] 🔄 Swapped", moving_item.name, "with inventory item")
						var tmp_item = target_slot.item
						var tmp_amt = target_slot.amount
						target_slot.item = moving_item
						target_slot.amount = moving_amount
						picked_slot.item = tmp_item
						picked_slot.amount = tmp_amt
					dropped = true
					break

		# --- 3️⃣ Drop to world (outside both inventories) ---
		if not dropped and moving_item:
			var over_slot := false
			for s in slots:
				if s.get_global_rect().has_point(mouse_pos):
					over_slot = true
			if inv_ui:
				for s in inv_ui.slots:
					if s.get_global_rect().has_point(mouse_pos):
						over_slot = true

			if not over_slot:
				print("[player_inv] 🌍 Dropping item into world:", moving_item.name)
				var world_item_scene = preload("res://scenes/world_item.tscn")
				var world_item: Node2D = world_item_scene.instantiate()

				# Assign item + quantity
				if "item" in world_item:
					world_item.item = moving_item
				if "quantity" in world_item:
					world_item.quantity = moving_amount

				# Set correct texture (prefer 'texture' over 'icon')
				if moving_item.texture and world_item.has_node("Sprite2D"):
					world_item.get_node("Sprite2D").texture = moving_item.texture
				elif moving_item.icon and world_item.has_node("Sprite2D"):
					world_item.get_node("Sprite2D").texture = moving_item.icon

				# Compute spawn position (prefer near player)
				var spawn_pos: Vector2
				if player:
					spawn_pos = player.global_position + Vector2(0, -16)
				else:
					spawn_pos = mouse_pos


				# Use helper that picks Y-Sort parent and sets z_index when needed
				_spawn_world_item(world_item, spawn_pos)

				# Ensure the resource slot stays cleared (defensive). This prevents UI/refresh
				# race conditions that can "restore" the item visually back into the slot.
				if picked_slot:
					picked_slot.item = null
					picked_slot.amount = 0

				print("[player_inv] ✅ Spawned world item at (via _spawn_world_item):", world_item.global_position)
				dropped = true

		# --- 4️⃣ If not dropped anywhere, restore item back ---
		if not dropped:
			print("[player_inv] 🗑 Dropped outside UI, restoring item")
			picked_slot.item = moving_item
			picked_slot.amount = moving_amount

		# --- 5️⃣ Refresh equipped items ---
		# --- 5️⃣ Refresh equipped items (deferred to avoid race) ---
		if player_node:
			if player_node.has_method("refresh_equipped_weapon_from_inventory"):
				player_node.call_deferred("refresh_equipped_weapon_from_inventory")
			# optionally deferred armor refresh
			# if player_node.has_method("refresh_equipped_armor_from_inventory"):
			#     player_node.call_deferred("refresh_equipped_armor_from_inventory")

		# --- Cleanup ---
		dragging = false
		if ghost_item and is_instance_valid(ghost_item):
			ghost_item.queue_free()
			ghost_item = null
		picked_slot = null
		# Defensive cleanup: remove any leftover invisible item_stack nodes so
		# UI == data after the drag finishes.
		for s in slots:
			if s.item_stack and not is_instance_valid(s.item_stack):
				s.item_stack = null
			elif s.item_stack and not s.item_stack.visible:
				# if somehow an invisible visual stayed, free it
				s.item_stack.queue_free()
				s.item_stack = null

		update_slots()
		for slot in slots:
			if slot and slot.has_method("update_visual"):
				slot.update_visual()
		if inv_ui:
			inv_ui.update_slots()

		# --- Force a deferred re-apply of equipped visuals on the player ---
		var _dbg_player := get_tree().root.find_child("Player", true, false)
		if _dbg_player:
			print("[player_inv][DBG] scheduling deferred player refresh (to avoid UI race)")
			# call_deferred ensures the player's refresh runs after the UI node tree changes complete
			if _dbg_player.has_method("refresh_equipped_weapon_from_inventory"):
				_dbg_player.call_deferred("refresh_equipped_weapon_from_inventory")
			else:
				print("[player_inv][DBG] player has no refresh_equipped_weapon_from_inventory() method")

			if _dbg_player.has_method("update_weapon_visuals"):
				_dbg_player.call_deferred("update_weapon_visuals")

func _can_accept_item(slot_type: String, item_type: String) -> bool:
	if slot_type == null or item_type == null:
		return false
	slot_type = slot_type.to_lower()
	item_type = item_type.to_lower()
	match slot_type:
		"weapon", "secondary":
			return item_type == "weapon"
		"armor":
			return item_type == "armor"
		"consumable":
			return item_type == "consumable"
		_:
			# generic fallback for non-restricted slots
			return true

func get_slots_rects() -> Array[Rect2]:
	var rects := []
	for s in slots:
		if s and s is Control:
			rects.append(s.get_global_rect())
	return rects

func get_slot_under_mouse(pos: Vector2) -> int:
	for i in range(slots.size()):
		if slots[i].get_global_rect().has_point(pos):
			return i
	return -1

func is_mouse_over_ui(mouse_pos: Vector2) -> bool:
	return get_global_rect().has_point(mouse_pos)

func _on_item_dropped_from_slot(slot: InvUISlot, item: InvItem, amount: int) -> void:
	print("[player_inv] Item dragged out from", slot.slot_type, ":", item.name)

	# Determine which resource slot (InvSlot) this UI slot corresponds to
	var idx := slots.find(slot)
	if idx == -1:
		push_warning("[player_inv] ❌ Could not find UI slot index for: " + str(slot))
		return

	# store the InvSlot resource so subsequent drop logic can restore if needed
	picked_slot = inv.slots[idx]
	if picked_slot == null:
		# create a placeholder slot if resource missing
		picked_slot = InvSlot.new()
		inv.slots[idx] = picked_slot

	# DEBUG
	print("[player_inv] _on_item_dropped_from_slot -> ui_index:", idx, " picked_slot:", picked_slot, " item:", item, "amount:", amount)

	# Unequip logic when dragging from equipped slots
	var player := get_tree().get_first_node_in_group("Player")
	if player == null:
		print("[player_inv] ⚠ Player node not found")
	else:
		match slot.slot_type:
			"weapon":
				# skip unequip if UI flow set suppression meta
				if player.has_meta("suppress_unequip") and player.get_meta("suppress_unequip") == true:
					print("[player_inv] suppress_unequip active — skipping unequip()")
				else:
					if player.has_method("unequip_weapon"):
						player.unequip_weapon()
					else:
						player.equip_weapon(null)

			"armor":
				if player.has_method("equip_armor"):
					player.equip_armor(null)

	# Create ghost item so player can drag it to inventory
	var ghost := preload("res://scenes/item_stack_ui.tscn").instantiate()
	ghost.origin_item = item
	ghost.origin_amount = amount
	ghost.slot = null

	# Put the ghost into our drag_layer (preferred) so it always renders above UI
	if drag_layer and is_instance_valid(drag_layer):
		if is_instance_valid(ghost.get_parent()):
			ghost.get_parent().remove_child(ghost)
		drag_layer.add_child(ghost)
	else:
		# fallback to root
		if is_instance_valid(ghost.get_parent()):
			ghost.get_parent().remove_child(ghost)
		get_tree().root.call_deferred("add_child", ghost)

	ghost.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ghost.global_position = get_viewport().get_mouse_position() - ghost.size * 0.5

	# Clear the underlying InvSlot now so the resource and UI match.
	# We keep picked_slot reference for potential restore if the drop is cancelled.
	if picked_slot:
		picked_slot.item = null
		picked_slot.amount = 0
		# Immediately refresh visuals so slot shows empty
		update_slots()
		for s in slots:
			if s and s.has_method("update_visual"):
				s.update_visual()

	# store it so the rest of your _unhandled_input logic can use it
	ghost_item = ghost

	print("[player_inv] ghost created and picked_slot stored.")

func get_slot_by_type(slot_type: String) -> InvUISlot:
	for slot in slots:
		if slot and slot.has_meta("slot_type"):  # optional, if you store slot_type as metadata
			if str(slot.get_meta("slot_type")).to_lower() == slot_type.to_lower():
				return slot
		elif "slot_type" in slot and slot.slot_type != null:
			if str(slot.slot_type).to_lower() == slot_type.to_lower():
				return slot
	push_warning("[PlayerInv] ❌ No slot of type %s found" % slot_type)
	return null

func _debug_player_state(player_node: Node, tag: String) -> void:
	# Defensive prints of available properties/methods on player
	var has_equip = player_node.has_method("equip_weapon")
	var has_unequip = player_node.has_method("unequip_weapon")
	var has_refresh = player_node.has_method("refresh_equipped_weapon_from_inventory")
	var has_update_visuals = player_node.has_method("update_weapon_visuals")
	var has_has_weapon = "has_weapon" in player_node
	var has_current_weapon = "current_weapon_scene" in player_node

	print("[player_inv][PLAYER_DBG - %s] node=%s has_equip=%s has_unequip=%s has_refresh=%s has_update_visuals=%s has_has_weapon=%s has_current_weapon=%s" % [tag, player_node, has_equip, has_unequip, has_refresh, has_update_visuals, has_has_weapon, has_current_weapon])

	if has_has_weapon:
		print("[player_inv][PLAYER_DBG - %s] has_weapon flag=%s" % [tag, player_node.has_weapon])

func _update_item_in_hand():
	# Ensures compatibility with older calls to _update_item_in_hand()
	# and centralizes ghost updates. Handles texture, visibility and position.
	if ghost_item == null or not is_instance_valid(ghost_item):
		return

	# Ensure ghost has the expected fields
	if ghost_item.item_visual and ghost_item.origin_item:
		# prefer icon then texture
		if ghost_item.origin_item.icon:
			ghost_item.item_visual.texture = ghost_item.origin_item.icon
		elif ghost_item.origin_item.texture:
			ghost_item.item_visual.texture = ghost_item.origin_item.texture
		ghost_item.item_visual.visible = true

	# keep ghost non-interactive
	ghost_item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ensure it's rendered on top
	if ghost_item is Control:
		ghost_item.z_index = 9999
		ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)

	# position
	_update_ghost_position()

	# force visual update just in case (avoids frame ordering issues)
	ghost_item.call_deferred("update")

# Preferred parent for world drops: prefer current_scene/Y-Sort -> root/world/Y-Sort -> world/layers/Resources -> current_scene -> root
func _get_world_ysort_parent() -> Node:
	var world_scene := get_tree().current_scene
	if world_scene:
		var ysort := world_scene.get_node_or_null("Y-Sort")
		if ysort:
			return ysort

	# fallback to root path "world/Y-Sort"
	var root_ysort := get_tree().root.get_node_or_null("world/Y-Sort")
	if root_ysort:
		return root_ysort

	# older project layout fallback
	var resources_node := get_tree().root.get_node_or_null("world/layers/Resources")
	if resources_node:
		return resources_node

	# last resorts
	if world_scene:
		return world_scene
	return get_tree().root
