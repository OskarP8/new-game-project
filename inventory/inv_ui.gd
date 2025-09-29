extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $NinePatchRect/GridContainer.get_children()

var is_open = false
var item_in_hand: ItemStackUI = null

func _ready():
	if inv:
		inv.inventory_changed.connect(update_slots)
	update_slots()
	close()

func _process(delta):
	if Input.is_action_just_pressed("i"):
		if is_open:
			close()
		else:
			open()

	_update_item_in_hand()

func update_slots() -> void:
	for i in range(slots.size()):
		if i >= inv.slots.size():
			break
		var inv_slot: InvSlot = inv.slots[i]
		if inv_slot == null or inv_slot.item == null:
			continue
		var item_stack: ItemStackUI = slots[i].item_stack
		if item_stack == null:
			item_stack = isgc.instantiate()
			slots[i].insert(item_stack)
			item_stack.clicked.connect(_on_item_clicked)
		item_stack.slot = inv_slot
		item_stack.update()

func open() -> void:
	visible = true
	is_open = true
	update_slots()

func close() -> void:
	visible = false
	is_open = false

# --- Picking up item ---
func _on_item_clicked(item_stack: ItemStackUI) -> void:
	print("Picked up item:", item_stack.slot.item)

	# detach from old parent
	var parent = item_stack.get_parent()
	if parent:
		parent.remove_child(item_stack)

	# reparent to the *canvas layer* so it stays visible above UI
	get_tree().root.add_child(item_stack)

	# reset anchors so it doesn't stretch weirdly
	item_stack.anchor_left = 0
	item_stack.anchor_top = 0
	item_stack.anchor_right = 0
	item_stack.anchor_bottom = 0

	item_in_hand = item_stack
	item_in_hand.visible = true

	_update_item_in_hand()


# --- Place item on release ---
func _unhandled_input(event: InputEvent) -> void:
	if item_in_hand and event is InputEventMouseButton and not event.pressed:
		# Mouse released
		for slot in slots:
			if slot.get_global_rect().has_point(get_viewport().get_mouse_position()):
				# place into this slot
				get_tree().root.remove_child(item_in_hand)
				slot.insert(item_in_hand)
				item_in_hand = null
				return
		# If not dropped on slot → put back into first free slot
		for slot in slots:
			if slot.item_stack == null:
				get_tree().root.remove_child(item_in_hand)
				slot.insert(item_in_hand)
				item_in_hand = null
				return

func _update_item_in_hand():
	if item_in_hand == null:
		return
	var mouse_pos = get_viewport().get_mouse_position()
	var offset = Vector2.ZERO
	if item_in_hand is Control:
		offset = item_in_hand.size * 0.5
	item_in_hand.global_position = mouse_pos - offset

func drop_into_slot(slot, item_stack):
	if item_stack.get_parent():
		item_stack.get_parent().remove_child(item_stack)
	slot.insert(item_stack)
	item_in_hand = null
