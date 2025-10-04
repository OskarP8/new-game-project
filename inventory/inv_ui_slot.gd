extends TextureButton
class_name InvUISlot

@export var slot_type: String = "generic"  # "weapon", "armor", "food", "inventory"
@export var slot_icon: Texture2D = null    # custom background/icon for this slot

@onready var container: CenterContainer = $CenterContainer
@onready var background: TextureRect = $Background  # <-- add a TextureRect node in your scene for visuals

var item_stack: ItemStackUI = null
var index: int = -1   # assigned from inv_ui.gd

func _ready() -> void:
	# Set background texture if assigned
	if slot_icon and background:
		background.texture = slot_icon
	print("Normal texture:", texture_normal)



func insert(isg: ItemStackUI) -> void:
	if isg == null:
		return

	var p = isg.get_parent()
	if p:
		p.remove_child(isg)

	item_stack = isg
	container.add_child(item_stack)


func take_item() -> ItemStackUI:
	if item_stack == null:
		return null

	var item := item_stack
	item.slot = null

	var p = item.get_parent()
	if p:
		p.remove_child(item)

	item_stack = null
	return item
