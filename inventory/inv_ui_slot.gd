extends TextureButton
class_name InvUISlot

@export var slot_type: String = "generic"  # e.g. "weapon", "armor", "food", "inventory"
@export var slot_icon: Texture2D = null    # optional icon / background for this slot

@onready var container: CenterContainer = $CenterContainer

var item_stack: ItemStackUI = null
var index: int = -1  # assigned externally (e.g. in inv_ui.gd)

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
