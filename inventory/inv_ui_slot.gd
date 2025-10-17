extends TextureButton
class_name PlayerInvSlot

@export var slot_type: String = "generic"  # e.g. "weapon", "armor", "food", "inventory"
@export var slot_icon: Texture2D = null    # optional icon / background for this slot

@onready var container: CenterContainer = $CenterContainer

var item_stack: ItemStackUI = null
var index: int = -1  # assigned externally (e.g. in inv_ui.gd)

signal slot_swapped(from_slot, to_slot)  # ⚡ Notify parent when items are swapped

func _ready() -> void:
	# If slot_icon is provided, use it as the button's normal texture
	if slot_icon:
		texture_normal = slot_icon
		print("[InvUISlot] Applied custom slot icon for:", slot_type)
	else:
		print("[InvUISlot] Using default texture for:", slot_type)

	# Ensure CenterContainer exists
	if not container:
		push_warning("[InvUISlot] Missing CenterContainer in scene!")

	# Optional: remove focus outline for cleaner visuals
	focus_mode = Control.FOCUS_NONE


# ---------------------------
# Insert ItemStackUI visual
# ---------------------------
func insert(isg: ItemStackUI) -> void:
	if isg == null:
		return

	var parent = isg.get_parent()
	if parent:
		parent.remove_child(isg)

	item_stack = isg
	container.add_child(item_stack)


# ---------------------------
# Remove ItemStackUI visual
# ---------------------------
func take_item() -> ItemStackUI:
	if item_stack == null:
		return null

	var item := item_stack
	item.slot = null

	var parent = item.get_parent()
	if parent:
		parent.remove_child(item)

	item_stack = null
	return item


# ----------------------------------------------------------------
# DRAG & DROP SUPPORT
# ----------------------------------------------------------------
func get_drag_data(position):
	if item_stack == null:
		return null

	var data = {
		"from_slot": self,
		"item_stack": item_stack,
		"item": item_stack.item,
		"amount": item_stack.amount,
	}

	set_drag_preview(item_stack.duplicate())
	return data


func can_drop_data(position, data) -> bool:
	if not data.has("item_stack"):
		return false

	var inv_item: InvItem = data["item"]

	# --- Custom rules for slot types ---
	if slot_type == "weapon":
		return inv_item.type == "weapon"
	elif slot_type == "secondary":
		return inv_item.type == "secondary"
	elif slot_type == "armor":
		return inv_item.type == "armor"
	else:
		return true


func drop_data(position, data) -> void:
	print("[InvUISlot] drop_data triggered on:", slot_type)
	if not can_drop_data(position, data):
		return

	var from_slot: InvUISlot = data["from_slot"]
	if from_slot == self:
		return

	# --- Swap the items visually ---
	var temp_stack = item_stack
	item_stack = from_slot.item_stack
	from_slot.item_stack = temp_stack

	# --- Update visuals ---
	if item_stack:
		insert(item_stack)
	if from_slot.item_stack:
		from_slot.insert(from_slot.item_stack)

	# --- Notify parent (inv_ui.gd) ---
	emit_signal("slot_swapped", from_slot, self)

	# --- Handle equip logic if needed ---
	var player := get_tree().get_first_node_in_group("Player")
	if not player:
		push_warning("[InvUISlot] No Player found in scene tree!")
		return

	if slot_type == "weapon" and item_stack and item_stack.item and item_stack.item.scene_path != "":
		print("[InvUISlot] 🗡 Equipping weapon:", item_stack.item.scene_path)
		player.equip_weapon(item_stack.item.scene_path)
	elif slot_type == "weapon" and not item_stack:
		print("[InvUISlot] ⚪ Unequipping weapon")
		player.has_weapon = false
