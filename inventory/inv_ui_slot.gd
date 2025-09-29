extends Button

@onready var container: CenterContainer = $CenterContainer

var item_stack : ItemStackUI = null

func insert(isg: ItemStackUI) -> void:
	if isg == null:
		return
	# detach from previous parent if necessary
	var p = isg.get_parent()
	if p:
		p.remove_child(isg)
	item_stack = isg
	container.add_child(item_stack)

func take_item() -> ItemStackUI:
	# return null if there is nothing to take
	if item_stack == null:
		return null
	var item = item_stack
	# remove from whatever parent it currently has (safe)
	var p = item.get_parent()
	if p:
		p.remove_child(item)
	item_stack = null
	return item
