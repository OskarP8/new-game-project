extends Resource
class_name Inv

signal inventory_changed

const InvSlotRes = preload("res://inventory/inv_slot.gd")

@export var slots: Array[InvSlot] = []

func add_item(entry: InventoryEntry) -> void:
	for slot in slots:
		if slot.item == entry.item:
			slot.amount += entry.quantity
			emit_signal("inventory_changed")
			return
	var new_slot = InvSlot.new()
	new_slot.item = entry.item
	new_slot.amount = entry.quantity
	slots.append(new_slot)
	emit_signal("inventory_changed")

func _init(slot_count: int = 20):
	slots.resize(slot_count)
	for i in range(slot_count):
		slots[i] = InvSlot.new()
