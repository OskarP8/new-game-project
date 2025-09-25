extends Panel

@onready var item_visual: Sprite2D = $CenterContainer/Panel/item_display      # adjust path to your Sprite2D
@onready var quantity_label: Label = $QuantityLabel # optional, for showing amounts

func update(slot: InvSlot):
	if slot == null or slot.item == null:
		item_visual.visible = false
		if quantity_label:
			quantity_label.visible = false
	else:
		item_visual.visible = true
		item_visual.texture = slot.item.icon   # use icon for inventory display
		if quantity_label:
			quantity_label.visible = true
			quantity_label.text = str(slot.amount)
