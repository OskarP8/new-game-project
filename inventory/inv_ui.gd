extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $NinePatchRect/GridContainer.get_children()

var is_open := false
var item_in_hand: ItemStackUI = null
var drag_layer: CanvasLayer

func _ready():
	drag_layer = CanvasLayer.new()
	get_tree().root.call_deferred("add_child", drag_layer)

	# assign index to each slot
	for i in range(slots.size()):
		slots[i].index = i

	if inv:
		inv.inventory_changed.connect(update_slots)
	update_slots()
	close()


func _process(_delta):
	if Input.is_action_just_pressed("i"):
		if is_open:
			close()
		else:
			open()

	_update_item_in_hand()

# -------------------
# SLOT HANDLING
# -------------------
func update_slots() -> void:
	if inv == null:
		return

	for i in range(slots.size()):
		if i >= inv.slots.size():
			break

		var inv_slot: InvSlot = inv.slots[i]
		if inv_slot == null or inv_slot.item == null:
			# clear the slot if empty
			if slots[i].item_stack and is_instance_valid(slots[i].item_stack):
				slots[i].item_stack.queue_free()
				slots[i].item_stack = null
			continue

		var item_stack: ItemStackUI = slots[i].item_stack
		if item_stack == null or not is_instance_valid(item_stack):
			item_stack = isgc.instantiate()
			slots[i].insert(item_stack)
			item_stack.clicked.connect(_on_item_clicked)

		item_stack.slot = inv_slot
		item_stack.update()

func open() -> void:
	visible = true
	is_open = true
	update_slots()

func close() -> void:
	visible = false
	is_open = false

# -------------------
# DRAG & DROP
# -------------------
var ghost_item: Control = null
var picked_slot: InvSlot = null

func _on_item_clicked(item_stack: ItemStackUI) -> void:
	if item_stack == null or not is_instance_valid(item_stack):
		print("⚠️ Tried to click a null item_stack!")
		return

	if ghost_item: # already dragging something
		return

	# remember which slot we picked from
	picked_slot = item_stack.slot

	# create ghost first (but don't call update yet)
	ghost_item = isgc.instantiate()

	# copy concrete item data into ghost so it doesn't depend on InvSlot
	ghost_item.origin_item = picked_slot.item if picked_slot else null
	ghost_item.origin_amount = picked_slot.amount if picked_slot else 0
	ghost_item.origin_slot = picked_slot

	# add ghost to drag_layer (now _ready has run and onready nodes are valid)
	drag_layer.add_child(ghost_item)
	ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)

	# now it's safe to call update (do deferred to be extra safe)
	ghost_item.call_deferred("update")

	# hide the real slot's UI so it looks picked up (safe check)
	if is_instance_valid(item_stack):
		item_stack.visible = false

	_update_item_in_hand()

func _unhandled_input(event: InputEvent) -> void:
	if not ghost_item:
		return

	if event is InputEventMouseButton and not event.pressed:
		var mouse_pos = get_viewport().get_mouse_position()

		var dropped = false
		for slot in slots:
			if slot.get_global_rect().has_point(mouse_pos):
				# move inventory data to target slot
				var target_slot: InvSlot = inv.slots[slot.index]
				if target_slot == null:
					target_slot = InvSlot.new()
					inv.slots[slot.index] = target_slot
				if picked_slot != null and picked_slot.item != null:
					target_slot.item = picked_slot.item
					target_slot.amount = picked_slot.amount

					# clear old slot
					picked_slot.item = null
					picked_slot.amount = 0

				dropped = true
				break

		# cleanup ghost
		if ghost_item:
			ghost_item.queue_free()
			ghost_item = null

		# un-hide the original item UI if it still exists
		# (update_slots() will recreate visuals; keep this safe)
		update_slots()



func _update_item_in_hand():
	if ghost_item == null:
		return
	var mouse_pos = get_viewport().get_mouse_position()
	var offset = ghost_item.size * 0.5
	ghost_item.global_position = mouse_pos - offset


func drop_into_slot(slot_button, item_stack: ItemStackUI) -> void:
	if item_stack == null:
		return
	if inv == null:
		# safety
		print("No inv resource")
		return

	# ensure inv.slots array is large enough
	var dest_idx = int(slot_button.index)
	if dest_idx >= inv.slots.size():
		# expand and fill with new InvSlot objects up to dest_idx
		var needed = dest_idx + 1 - inv.slots.size()
		for i in range(needed):
			inv.slots.append(InvSlot.new())

	# ensure the destination slot object exists
	var new_slot: InvSlot = inv.slots[dest_idx]
	if new_slot == null:
		new_slot = InvSlot.new()
		inv.slots[dest_idx] = new_slot

	# move UI node visually into the slot
	if item_stack.get_parent():
		item_stack.get_parent().remove_child(item_stack)
	slot_button.insert(item_stack)

	# write item data into destination using the stored origin_item/amount
	new_slot.item = item_stack.origin_item
	new_slot.amount = item_stack.origin_amount

	# clear the origin slot if it still exists and isn't the same as new_slot
	if item_stack.origin_slot and item_stack.origin_slot != new_slot:
		item_stack.origin_slot.item = null
		item_stack.origin_slot.amount = 0

	# reassign item_stack bookkeeping
	item_stack.slot = new_slot
	item_stack.origin_slot = new_slot
	item_stack.origin_item = new_slot.item
	item_stack.origin_amount = new_slot.amount

	item_in_hand = null

	# refresh UI / inventory
	update_slots()
	if inv:
		inv.emit_signal("inventory_changed")
