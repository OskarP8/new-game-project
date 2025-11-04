extends Node2D

@onready var sprite := $Sprite2D

func show_prompt(text: String, pos: Vector2):
	global_position = pos + Vector2(0, -24)
	show()

func hide_prompt():
	hide()
