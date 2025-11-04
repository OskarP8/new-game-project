extends Node2D   # or StaticBody2D if you need collisions

@export var slots: Array[InventoryEntry] = []
@onready var animations: AnimationPlayer = $AnimationPlayer
@onready var item_start_pos: Marker2D = $ItemStartPos
@onready var item_end_pos: Marker2D = $ItemEndPos
@onready var prompt_scene = preload("res://scenes/interact_prompt.tscn")
var prompt: Node2D = null

var is_open: bool = false

func interact(player: Node2D) -> void:
	if is_open:
		return
	is_open = true

	animations.play("open")
	await animations.animation_finished

	# Spawn items visually first
	for entry in slots:
		spawn_and_collect(player, entry)  # Pass both player & entry

	# Add items to player inventory
	if player.has_method("add_to_inventory"):
		for entry in slots:
			if entry.item and player.has_method("_is_non_stackable") and player._is_non_stackable(entry.item):
				# Add non-stackable items one by one
				for i in range(entry.quantity):
					player.add_to_inventory(entry.item, 1)
			else:
				# Add stackable items normally
				player.add_to_inventory(entry.item, entry.quantity)

	slots.clear()


func spawn_and_collect(player: Node2D, entry: InventoryEntry) -> void:
	if entry.item == null:
		return

	var item: InvItem = entry.item

	for i in range(entry.quantity):
		var sprite := Sprite2D.new()
		sprite.texture = item.texture

		# Random offset so items don’t stack perfectly
		var offset := Vector2(randf_range(-2, 2), randf_range(-2, 2))

		sprite.global_position = item_start_pos.global_position + offset
		var resources_node = get_tree().get_root().get_node("world/layers/Resources")
		resources_node.add_child(sprite)  # Add it as sibling to chest & player, inside YSort


		# Tween: chest → end position
		var tween := create_tween()
		tween.tween_property(sprite, "global_position", item_end_pos.global_position + offset, 0.3)
		await tween.finished

		# Tween: end position → player
		var tween_collect := create_tween()
		tween_collect.tween_property(sprite, "global_position", player.global_position, 0.5)
		tween_collect.tween_callback(Callable(sprite, "queue_free"))




func _process(delta):
	#print("Chest Y:", global_position.y)
	z_index = int(global_position.y)
