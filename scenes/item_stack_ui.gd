extends Panel
class_name ItemStackUI

signal clicked(item_stack)

@onready var item_visual: TextureRect = $ItemDisplay
@onready var quantity_label: Label = $Label

var slot: InvSlot = null
var origin_slot: InvSlot = null

# Store actual item & amount when dragging so we don't depend on InvSlot existing
var origin_item: InvItem = null
var origin_amount: int = 0

func _on_pressed():
	if slot and slot.item:
		print("Clicked valid stack:", slot.item)
		clicked.emit(self)
	else:
		print("Clicked empty stack – ignoring")

func update():
	if slot == null or slot.item == null:
		item_visual.visible = false
		if quantity_label:
			quantity_label.visible = false
	else:
		item_visual.visible = true
		item_visual.texture = slot.item.icon
		if quantity_label:
			quantity_label.visible = true
			quantity_label.text = str(slot.amount)

func _gui_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		emit_signal("clicked", self)
