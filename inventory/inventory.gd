extends Resource
class_name Inv

signal inventory_changed

const InvSlotRes = preload("res://inventory/inv_slot.gd")

@export var slots: Array[InvSlot] = []

# Add an InventoryEntry (expects .item and .quantity)
func add_item(entry: InventoryEntry) -> void:
	if entry == null or entry.item == null:
		return

	var remaining := int(entry.quantity)
	var item := entry.item

	# --- NON STACKABLE (weapon / armor) ---
	if _is_non_stackable(item):
		for i in range(remaining):
			var placed := false
			# search for first empty slot by index and write into slots[] directly
			for j in range(slots.size()):
				if slots[j] == null or slots[j].item == null:
					if slots[j] == null:
						# instantiate using preloaded resource so class matches project expectations
						slots[j] = InvSlotRes.new()
					slots[j].item = item
					slots[j].amount = 1
					placed = true
					break

			# if still not placed, append a new slot instance
			if not placed:
				var new_slot := InvSlotRes.new()
				new_slot.item = item
				new_slot.amount = 1
				slots.append(new_slot)

		emit_signal("inventory_changed")
		return

	# --- STACKABLE ITEMS ---
	var max_stack := 99
	if "max_stack" in item:
		max_stack = int(item.max_stack)

	# 1) Try stacking into existing slots
	for j in range(slots.size()):
		var s = slots[j]
		if s != null and s.item != null and s.item == item and s.amount < max_stack:
			var space_left = max_stack - s.amount
			var to_add = min(space_left, remaining)
			s.amount += to_add
			remaining -= to_add
			if remaining <= 0:
				emit_signal("inventory_changed")
				return

	# 2) Fill first empty slot (by index)
	for j in range(slots.size()):
		if slots[j] == null or slots[j].item == null:
			if slots[j] == null:
				slots[j] = InvSlotRes.new()
			slots[j].item = item
			slots[j].amount = remaining
			emit_signal("inventory_changed")
			return

	# 3) Expand inventory if no free slot
	var append_slot := InvSlotRes.new()
	append_slot.item = item
	append_slot.amount = remaining
	slots.append(append_slot)

	emit_signal("inventory_changed")


# initialize with slot_count new slots
func _init(slot_count: int = 12):
	slots.resize(slot_count)
	for i in range(slot_count):
		if slots[i] == null:
			slots[i] = InvSlotRes.new()


func _is_non_stackable(item: InvItem) -> bool:
	if not item:
		return false
	# adjust these strings to match your InvItem.type values
	return item.type == "weapon" or item.type == "armor"
