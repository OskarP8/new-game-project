extends Button

@onready var container: CenterContainer = $CenterContainer
var item_stack: ItemStackUI = null
var index: int = -1   # <-- assigned from inv_ui.gd

func insert(isg: ItemStackUI):
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
