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
	# ✅ Prefer slot data if available, else use ghost origin data
	var the_item: InvItem = null
	var the_amount: int = 0

	if slot != null and slot.item != null:
		the_item = slot.item
		the_amount = slot.amount
	elif origin_item != null:
		the_item = origin_item
		the_amount = origin_amount

	if the_item == null:
		if is_instance_valid(item_visual):
			item_visual.visible = false
		if quantity_label:
			quantity_label.visible = false
		return

	# ✅ Show texture safely
	if is_instance_valid(item_visual):
		item_visual.visible = true
		item_visual.texture = the_item.icon
	if quantity_label:
		quantity_label.visible = true
		quantity_label.text = str(the_amount)

func _gui_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		emit_signal("clicked", self)
