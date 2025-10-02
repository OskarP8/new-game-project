extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $NinePatchRect/GridContainer.get_children()

var is_open := false
var drag_layer: CanvasLayer

var ghost_item: ItemStackUI = null
var picked_slot: InvSlot = null

func _ready():
	drag_layer = CanvasLayer.new()
	get_tree().root.call_deferred("add_child", drag_layer)

	# assign index to each slot
	for i in range(slots.size()):
		slots[i].index = i

	if inv:
		inv.inventory_changed.connect(update_slots)
	update_slots()
	close()

func _process(_delta):
	if Input.is_action_just_pressed("i"):
		if is_open:
			close()
		else:
			open()

	_update_item_in_hand()

# -------------------
# SLOT HANDLING
# -------------------
func update_slots() -> void:
	if inv == null:
		return

	for i in range(slots.size()):
		if i >= inv.slots.size():
			break

		var inv_slot: InvSlot = inv.slots[i]

		# 🔑 ensure slot object always exists
		if inv_slot == null:
			inv_slot = InvSlot.new()
			inv.slots[i] = inv_slot

		if inv_slot.item == null:
			if slots[i].item_stack and is_instance_valid(slots[i].item_stack):
				slots[i].item_stack.queue_free()
			slots[i].item_stack = null
			continue

		var item_stack: ItemStackUI = slots[i].item_stack
		if item_stack == null or not is_instance_valid(item_stack):
			item_stack = isgc.instantiate()
			slots[i].insert(item_stack)
			if not item_stack.clicked.is_connected(Callable(self, "_on_item_clicked")):
				item_stack.clicked.connect(Callable(self, "_on_item_clicked"))

		item_stack.slot = inv_slot
		item_stack.update()

func open() -> void:
	visible = true
	is_open = true
	update_slots()

func close() -> void:
	visible = false
	is_open = false

# -------------------
# DRAG & DROP
# -------------------
func _on_item_clicked(item_stack: ItemStackUI) -> void:
	if item_stack == null or not is_instance_valid(item_stack):
		print("⚠️ Tried to click a null item_stack!")
		return

	if ghost_item: # already dragging something
		return

	picked_slot = item_stack.slot

	# create ghost
	ghost_item = isgc.instantiate()
	ghost_item.slot = null
	ghost_item.origin_item = picked_slot.item if picked_slot else null
	ghost_item.origin_amount = picked_slot.amount if picked_slot else 0
	ghost_item.origin_slot = picked_slot

	drag_layer.add_child(ghost_item)
	ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ghost_item.update()

	if is_instance_valid(item_stack):
		item_stack.visible = false

	_update_item_in_hand()

func _unhandled_input(event: InputEvent) -> void:
	if not ghost_item:
		return

	if event is InputEventMouseButton and not event.pressed:
		var mouse_pos = get_viewport().get_mouse_position()
		var dropped = false

		for slot in slots:
			if slot.get_global_rect().has_point(mouse_pos):
				var target_slot: InvSlot = inv.slots[slot.index]

				# 🔑 ensure target_slot always exists
				if target_slot == null:
					target_slot = InvSlot.new()
					inv.slots[slot.index] = target_slot

				if picked_slot and picked_slot.item:
					# --- STACK (if same item type & stackable) ---
					if target_slot.item \
					and target_slot.item.id == picked_slot.item.id \
					and not _is_non_stackable(target_slot.item):
						target_slot.amount += picked_slot.amount
						picked_slot.item = null
						picked_slot.amount = 0

					# --- SWAP (different item or non-stackable) ---
					elif target_slot.item:
						var temp_item = target_slot.item
						var temp_amount = target_slot.amount
						target_slot.item = picked_slot.item
						target_slot.amount = picked_slot.amount
						picked_slot.item = temp_item
						picked_slot.amount = temp_amount

					# --- MOVE (empty slot) ---
					else:
						target_slot.item = picked_slot.item
						target_slot.amount = picked_slot.amount
						picked_slot.item = null
						picked_slot.amount = 0

				dropped = true
				break

		# dropped outside → clear picked slot safely
		if not dropped and picked_slot:
			picked_slot.item = null
			picked_slot.amount = 0

		# cleanup ghost
		if ghost_item:
			ghost_item.queue_free()
			ghost_item = null

		update_slots()

func _update_item_in_hand():
	if ghost_item == null:
		return
	var mouse_pos = get_viewport().get_mouse_position()
	var offset = ghost_item.size * 0.5
	ghost_item.global_position = mouse_pos - offset

func _is_non_stackable(item: InvItem) -> bool:
	if not item:
		return false
	return item.type == "weapon" or item.type == "armor"
