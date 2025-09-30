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
func _on_item_clicked(item_stack: ItemStackUI) -> void:
	if item_in_hand: # already holding something
		return

	print("Picked up item:", item_stack.slot.item)

	# detach from slot
	var parent = item_stack.get_parent()
	if parent:
		parent.remove_child(item_stack)

	# move into drag_layer (so it's always on top)
	drag_layer.add_child(item_stack)
	item_stack.set_anchors_preset(Control.PRESET_TOP_LEFT)

	# reset offsets
	item_stack.offset_left = 0
	item_stack.offset_top = 0
	item_stack.offset_right = 0
	item_stack.offset_bottom = 0

	item_in_hand = item_stack
	item_in_hand.visible = true

	_update_item_in_hand()

func _unhandled_input(event: InputEvent) -> void:
	if not item_in_hand:
		return

	if event is InputEventMouseButton and not event.pressed:
		var mouse_pos = get_viewport().get_mouse_position()

		# Try dropping on slots
		for slot in slots:
			if slot.get_global_rect().has_point(mouse_pos):
				drop_into_slot(slot, item_in_hand)
				return

		# Dropped outside inventory → destroy safely
		print("Dropped outside inventory:", item_in_hand.slot.item)

		# clear inventory data if still linked
		if item_in_hand.slot:
			item_in_hand.slot.item = null
			item_in_hand.slot.amount = 0

		if is_instance_valid(item_in_hand):
			item_in_hand.queue_free()
		item_in_hand = null

		update_slots()

func drop_into_slot(slot, item_stack: ItemStackUI):
	# remove from old parent
	if item_stack.get_parent():
		item_stack.get_parent().remove_child(item_stack)

	# insert visually
	slot.insert(item_stack)

	# --- update inventory data ---
	if slot.index < inv.slots.size() and item_stack.slot:
		# move item reference from old slot to new slot
		var old_slot: InvSlot = item_stack.slot
		var new_slot: InvSlot = inv.slots[slot.index]

		new_slot.item = old_slot.item
		new_slot.amount = old_slot.amount

		# clear the old slot
		old_slot.item = null
		old_slot.amount = 0

		# reassign the item_stack to new slot
		item_stack.slot = new_slot

	item_in_hand = null
	update_slots()


func _update_item_in_hand():
	if item_in_hand == null:
		return
	var mouse_pos = get_viewport().get_mouse_position()
	var offset = Vector2.ZERO
	if item_in_hand is Control:
		offset = item_in_hand.size * 0.5
	item_in_hand.global_position = mouse_pos - offset
