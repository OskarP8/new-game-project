extends TextureButton
class_name InvUISlot

signal item_dropped_from_slot(slot: InvUISlot, item: InvItem, amount: int)

@export var slot_type: String = "generic"
@export var slot_icon: Texture2D
@export var empty_texture: Texture2D
@export var filled_texture: Texture2D

@onready var container: CenterContainer = $CenterContainer

var item_stack: ItemStackUI = null
var index: int = -1


func _ready() -> void:
	if empty_texture:
		texture_normal = empty_texture
	elif slot_icon:
		texture_normal = slot_icon
	if not container:
		push_warning("[InvUISlot] Missing CenterContainer!")
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	update_visual()


# ---------------------------
# Insert / remove visuals
# ---------------------------
func insert(isg: ItemStackUI) -> void:
	if isg == null:
		return
	if isg.get_parent():
		isg.get_parent().remove_child(isg)
	item_stack = isg
	container.add_child(item_stack)
	call_deferred("update_visual") # Wait one frame so item_stack is fully initialized

func take_item() -> ItemStackUI:
	if item_stack == null:
		return null
	var it := item_stack
	item_stack = null
	if it.get_parent():
		it.get_parent().remove_child(it)
	call_deferred("update_visual") # Wait one frame so item_stack is fully initialized
	return it

# ----------------------------------------------------------------
# Drag & drop
# ----------------------------------------------------------------
func can_drop_data(_pos, data) -> bool:
	if data is ItemStackUI and (data.slot or data.origin_item):
		var inv_item: InvItem = data.slot.item if data.slot else data.origin_item
		return _can_accept(inv_item)
	return false


func drop_data(_pos, data) -> void:
	if not can_drop_data(_pos, data):
		return
	var inv_item: InvItem = data.slot.item if data.slot else data.origin_item
	insert(data)
	update_visual()

	var player := get_tree().get_first_node_in_group("Player")
	if player == null:
		push_warning("[InvUISlot] Player not found!")
		return

	if slot_type == "weapon" and inv_item.scene_path != "":
		player.equip_weapon(inv_item.scene_path)
	elif slot_type == "armor" and inv_item.scene_path != "":
		if player.has_method("equip_armor"):
			player.equip_armor(inv_item.scene_path)


# ----------------------------------------------------------------
# Begin drag from this slot
# ----------------------------------------------------------------
func get_drag_data(_pos):
	if item_stack == null:
		return null
	var inv_item: InvItem = null
	var amount := 0

	if item_stack.slot:
		inv_item = item_stack.slot.item
		amount = item_stack.slot.amount
	elif item_stack.origin_item:
		inv_item = item_stack.origin_item
		amount = item_stack.origin_amount

	if inv_item == null:
		return null

	# ✅ Create drag preview for nice visuals
	var drag_preview := item_stack.duplicate()
	set_drag_preview(drag_preview)

	# ✅ Emit signal so PlayerInv knows an item left this slot
	emit_signal("item_dropped_from_slot", self, inv_item, amount)

	# ✅ Remove visual from slot
	item_stack.queue_free()
	item_stack = null
	update_visual()

	# ✅ Return actual data object
	return {
		"item": inv_item,
		"amount": amount,
		"from_slot": self
	}


# ----------------------------------------------------------------
func _can_accept(inv_item: InvItem) -> bool:
	if slot_type in ["weapon", "secondary"]:
		return inv_item.type == "weapon"
	if slot_type == "armor":
		return inv_item.type == "armor"
	if slot_type == "consumable":
		return inv_item.type == "consumable"
	return true


# ----------------------------------------------------------------
# ✅ Update the slot appearance
# ----------------------------------------------------------------
func update_visual():
	var has_item := false

	if item_stack and is_instance_valid(item_stack):
		if item_stack.slot and item_stack.slot.item:
			has_item = true
		elif item_stack.origin_item:
			has_item = true

	print("[InvUISlot] update_visual() slot:", slot_type, " has_item:", has_item)

	if has_item:
		texture_normal = filled_texture
		print("[InvUISlot] ✅ Filled texture applied")
	else:
		texture_normal = empty_texture
		print("[InvUISlot] 🩶 Empty texture applied")
