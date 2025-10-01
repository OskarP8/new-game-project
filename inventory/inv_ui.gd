extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $NinePatchRect/GridContainer.get_children()

var is_open := false
var drag_layer: CanvasLayer

# Dragging state
var ghost_item: ItemStackUI = null
var picked_slot: InvSlot = null

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

		# clear empty slots
		if inv_slot == null or inv_slot.item == null:
			if slots[i].item_stack and is_instance_valid(slots[i].item_stack):
				slots[i].item_stack.queue_free()
			slots[i].item_stack = null
			continue

		# spawn or update item_stack
		var item_stack: ItemStackUI = slots[i].item_stack
		if item_stack == null or not is_instance_valid(item_stack):
			item_stack = isgc.instantiate()
			slots[i].insert(item_stack)
			if not item_stack.clicked.is_connected(Callable(self, "_on_item_clicked")):
				item_stack.clicked.connect(Callable(self, "_on_item_clicked"))

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
	if not item_stack or not is_instance_valid(item_stack):
		return
	if ghost_item: # already dragging something
		return

	# remember original slot
	picked_slot = item_stack.slot

	# create ghost
	ghost_item = isgc.instantiate()
	ghost_item.origin_item = picked_slot.item
	ghost_item.origin_amount = picked_slot.amount
	ghost_item.origin_slot = picked_slot
	ghost_item.update()

	# add to drag layer
	drag_layer.add_child(ghost_item)
	ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)

	# hide the real one
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
				var target_slot: InvSlot = inv.slots[slot.index]
				if target_slot == null:
					target_slot = InvSlot.new()
					inv.slots[slot.index] = target_slot

				# ✅ use ghost data, not picked_slot
				target_slot.item = ghost_item.origin_item
				target_slot.amount = ghost_item.origin_amount

				# clear original slot
				if picked_slot:
					picked_slot.item = null
					picked_slot.amount = 0

				dropped = true
				break

		# dropped outside → just clear the old slot
		if not dropped:
			if picked_slot:
				picked_slot.item = null
				picked_slot.amount = 0
			print("Dropped outside:", ghost_item.origin_item)

		# cleanup ghost
		if ghost_item:
			ghost_item.queue_free()
			ghost_item = null

		# refresh visuals
		update_slots()
		if inv:
			inv.emit_signal("inventory_changed")


func _update_item_in_hand():
	if ghost_item == null:
		return
	var mouse_pos = get_viewport().get_mouse_position()
	var offset = ghost_item.size * 0.5
	ghost_item.global_position = mouse_pos - offset
