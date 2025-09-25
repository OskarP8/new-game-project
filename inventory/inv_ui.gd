extends Control

@onready var inv: Inv = preload("res://inventory/playerinv.tres")
@onready var slots: Array = $NinePatchRect/GridContainer.get_children()

var is_open = false

func _ready():
	update_slots()
	close()

func _process(delta):
	if Input.is_action_just_pressed("i"):
		if is_open:
			close()
		else:
			open()

func update_slots() -> void:
	for i in range(slots.size()):
		if i < inv.slots.size():
			slots[i].update(inv.slots[i])
		else:
			slots[i].update(null)  # empty slot

func open() -> void:
	visible = true
	is_open = true
	update_slots()

func close() -> void:
	visible = false
	is_open = false
