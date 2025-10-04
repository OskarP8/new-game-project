extends Control

var is_open := false

func _ready():
	close()

func _process(_delta):
	# Toggle with the "i" key (same as main inv)
	if Input.is_action_just_pressed("i"):
		if is_open:
			close()
		else:
			open()

func open():
	visible = true
	is_open = true
	# optional: refresh slot visuals if needed
	# update_slots()

func close():
	visible = false
	is_open = false
