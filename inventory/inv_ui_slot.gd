extends TextureButton
class_name InvUISlot

signal item_dropped_from_slot(slot: InvUISlot, item: InvItem, amount: int)

@export var slot_type: String = "generic"
@export var slot_icon: Texture2D

@onready var container: CenterContainer = $CenterContainer

var item_stack: ItemStackUI = null
var index: int = -1

func _ready() -> void:
	if slot_icon:
		texture_normal = slot_icon
	if not container:
		push_warning("[InvUISlot] Missing CenterContainer!")
	focus_mode = Control.FOCUS_NONE

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

func take_item() -> ItemStackUI:
	if item_stack == null:
		return null
	var it := item_stack
	item_stack = null
	if it.get_parent():
		it.get_parent().remove_child(it)
	return it

# ----------------------------------------------------------------
# Drag & drop
# ----------------------------------------------------------------
func can_drop_data(_pos, data) -> bool:
	if data is ItemStackUI and data.item:
		var inv_item: InvItem = data.item
		return _can_accept(inv_item)
	return false

func drop_data(_pos, data) -> void:
	if not can_drop_data(_pos, data):
		return
	var inv_item: InvItem = data.item
	insert(data)

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
	if item_stack == null or not item_stack.item:
		return null

	# Set the drag preview (optional but good UX)
	var drag_preview := item_stack.duplicate()
	set_drag_preview(drag_preview)

	# Store this reference before we clear it
	var dragged_stack := item_stack

	# Emit optional signal (if you want to handle custom logic)
	emit_signal("item_dropped_from_slot", self, dragged_stack.item, dragged_stack.slot.amount)

	# Clear from slot visually
	item_stack.queue_free()
	item_stack = null

	# Return the ItemStackUI node directly — this makes data.is ItemStackUI true
	return dragged_stack

# ----------------------------------------------------------------
func _can_accept(inv_item: InvItem) -> bool:
	if slot_type in ["weapon", "secondary"]:
		return inv_item.type == "weapon"
	if slot_type == "armor":
		return inv_item.type == "armor"
	if slot_type == "consumable":
		return inv_item.type == "consumable"
	return true
