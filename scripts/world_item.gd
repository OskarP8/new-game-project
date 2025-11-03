extends Area2D
class_name WorldItem

@export var item: InvItem
@export var quantity: int = 1
@export var world_texture: Texture2D

@onready var sprite: Sprite2D = $Sprite2D

func _ready():
	if item:
		if item.icon:
			sprite.texture = item.icon
		name = item.name
		connect("body_entered", Callable(self, "_on_body_entered"))
	if world_texture:
		sprite.texture = world_texture
	elif item and item.texture:
		sprite.texture = item.texture

	z_index = int(position.y)

func _on_body_entered(body):
	if body.is_in_group("player"):
		body.nearby_item = self

func _on_body_exited(body):
	if body.is_in_group("player") and body.nearby_item == self:
		body.nearby_item = null

func collect(player):
	if player and player.has_method("add_to_inventory"):
		player.add_to_inventory(item, quantity)
	queue_free()
