extends Resource
class_name Inv

const InvSlotRes = preload("res://inventory/inv_slot.gd")

@export var slots: Array[InvSlot] = []

# Add an item to the inventory
func add_item(entry: InventoryEntry) -> void:
	# Check if item already exists
	for slot in slots:
		if slot.item == entry.item:
			slot.amount += entry.quantity
			return
	# Otherwise, create new slot
	var new_slot = InvSlot.new()
	new_slot.item = entry.item
	new_slot.amount = entry.quantity
	slots.append(new_slot)
