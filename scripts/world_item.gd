extends Area2D
class_name WorldItem

@export var item: InvItem
@export var quantity: int = 1
@export var world_texture: Texture2D

@onready var sprite: Sprite2D = $Sprite2D
@onready var prompt_scene = preload("res://scenes/interact_prompt.tscn")
var prompt: Node2D = null

func _ready():
	print("[WorldItem] _ready() called for:", name)
	print("[WorldItem] item:", item, "quantity:", quantity)
	
	# Texture selection debug
	if item:
		if item.texture:
			sprite.texture = item.texture
			print("[WorldItem] using item.texture for sprite")
		elif world_texture:
			sprite.texture = world_texture
			print("[WorldItem] using world_texture for sprite")
		elif item.icon:
			sprite.texture = item.icon
			print("[WorldItem] using item.icon as fallback")
		else:
			print("[WorldItem] ⚠ item has no texture or icon")
	else:
		print("[WorldItem] ⚠ item is null")

	name = item.name if item else name
	z_index = int(position.y)

	# Check that signal connections exist
	if not is_connected("body_entered", Callable(self, "_on_body_entered")):
		connect("body_entered", Callable(self, "_on_body_entered"))
	if not is_connected("body_exited", Callable(self, "_on_body_exited")):
		connect("body_exited", Callable(self, "_on_body_exited"))

	print("[WorldItem] ready with sprite:", sprite.texture)

func _on_body_entered(body: Node):
	print("[WorldItem] body_entered:", body.name, " groups:", body.get_groups())

	if body.is_in_group("Player"):
		print("[WorldItem] ✅ player entered, showing prompt")
		if prompt == null:
			print("[WorldItem] instantiating prompt...")
			prompt = prompt_scene.instantiate()
			get_tree().current_scene.add_child(prompt)
			print("[WorldItem] prompt instance added to current scene:", prompt)
		else:
			print("[WorldItem] prompt already exists")

		prompt.show_prompt("Press E", global_position)
	else:
		print("[WorldItem] ❌ body is not in 'player' group")

func _on_body_exited(body: Node):
	print("[WorldItem] body_exited:", body.name)
	if body.is_in_group("player") and prompt:
		print("[WorldItem] hiding prompt")
		prompt.hide_prompt()

func collect(player):
	if player and player.has_method("add_to_inventory"):
		player.add_to_inventory(item, quantity)
	queue_free()
