extends Resource
class_name Inv

signal inventory_changed

const InvSlotRes = preload("res://inventory/inv_slot.gd")

@export var slots: Array[InvSlot] = []

func add_item(entry: InventoryEntry) -> void:
	if entry == null or entry.item == null:
		return

	var remaining = entry.quantity
	var item = entry.item

	# --- NON STACKABLE (weapon / armor) ---
	if _is_non_stackable(item):
		 # Place each item in a separate slot
		for i in range(remaining):
			# Find the first empty slot
			var placed = false
			for slot in slots:
				if slot == null or slot.item == null:
					if slot == null:
						slot = InvSlot.new()
					slot.item = item
					slot.amount = 1
					placed = true
					break

			# Expand inventory if no free slot
			if not placed:
				var new_slot = InvSlot.new()
				new_slot.item = item
				new_slot.amount = 1
				slots.append(new_slot)

		emit_signal("inventory_changed")
		return

	# --- STACKABLE ITEMS ---
	var max_stack = item.max_stack if "max_stack" in item else 99

	# 1. Try stacking into existing slots
	for slot in slots:
		if slot and slot.item and slot.item == item and slot.amount < max_stack:
			var space_left = max_stack - slot.amount
			var to_add = min(space_left, remaining)
			slot.amount += to_add
			remaining -= to_add
			if remaining <= 0:
				emit_signal("inventory_changed")
				return

	# 2. Fill first empty slot
	for i in range(slots.size()):
		if slots[i] == null or slots[i].item == null:
			if slots[i] == null:
				slots[i] = InvSlot.new()
			slots[i].item = item
			slots[i].amount = remaining
			emit_signal("inventory_changed")
			return

	# 3. Expand inventory if no free slot
	var new_slot = InvSlot.new()
	new_slot.item = item
	new_slot.amount = remaining
	slots.append(new_slot)

	emit_signal("inventory_changed")


func _init(slot_count: int = 12):
	slots.resize(slot_count)
	for i in range(slot_count):
		slots[i] = InvSlot.new()

func _is_non_stackable(item: InvItem) -> bool:
	if not item:
		return false
	return item.type == "weapon" or item.type == "armor"
