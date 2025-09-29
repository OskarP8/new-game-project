extends Button

@onready var container: CenterContainer = $CenterContainer

var item_stack : ItemStackUI

func insert(isg: ItemStackUI):
	item_stack = isg
	container.add_child(item_stack)

func take_item():
	var item = item_stack
	
	container.remove_child(item_stack)
	item_stack = null
	return item
