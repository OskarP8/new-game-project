extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $NinePatchRect/GridContainer.get_children()

var is_open = false
var item_in_hand: ItemStackUI

func _ready():
	inv.inventory_changed.connect(update_slots)
	print("Inv slots on ready:", inv.slots.size())
	update_slots()
	connect_slots()
	close()

func _process(delta):
	if Input.is_action_just_pressed("i"):
		if is_open:
			close()
		else:
			open()

func update_slots() -> void:
	for i in range(slots.size()):
		if i >= inv.slots.size():
			break

		var inv_slot: InvSlot = inv.slots[i]
		if inv_slot == null or inv_slot.item == null:
			continue

		var item_stack: ItemStackUI = slots[i].item_stack
		if item_stack == null:
			item_stack = isgc.instantiate()
			slots[i].insert(item_stack)

		item_stack.slot = inv_slot
		item_stack.update()



func open() -> void:
	visible = true
	is_open = true
	update_slots()

func close() -> void:
	visible = false
	is_open = false

func connect_slots():
	for slot in slots:
		var callable = Callable(on_slot_clicked)
		callable = callable.bind(slot)
		slot.pressed.connect(callable)

func on_slot_clicked(slot):
	item_in_hand = slot.take_item()
	add_child(item_in_hand)
