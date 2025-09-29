extends Panel
class_name ItemStackUI

@onready var item_visual: TextureRect = $ItemDisplay
@onready var quantity_label: Label = $Label

var slot: InvSlot

func update():
	print("Update called, slot:", slot, " item:", slot.item if slot else "nil")
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
