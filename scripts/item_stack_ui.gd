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

func _ready() -> void:
	print("[ItemStackUI] Ready — initialized for slot:", slot)
	if item_visual:
		item_visual.visible = true
	if quantity_label:
		quantity_label.visible = true

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if slot and slot.item:
			print("[ItemStackUI] clicked valid item:", slot.item.name if "name" in slot.item else slot.item)
			clicked.emit(self)
		elif origin_item:
			print("[ItemStackUI] clicked ghost/origin item:", origin_item.name if "name" in origin_item else origin_item)
			clicked.emit(self)
		else:
			print("[ItemStackUI] clicked empty stack — ignoring")

func update() -> void:
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
		print("[ItemStackUI] updating visual for:", the_item, " amount:", the_amount)

	# ✅ Update the quantity label (hide if only one)
	if quantity_label:
		if the_amount <= 1:
			quantity_label.visible = false
		else:
			quantity_label.visible = true
			quantity_label.text = str(the_amount)

@onready var amount_label: Label = $Label

func hide_amount() -> void:
	if amount_label:
		amount_label.visible = false

func show_amount() -> void:
	if amount_label:
		amount_label.visible = true
