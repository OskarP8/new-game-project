extends Area2D

var can_interact: Array[Node2D] = []

@onready var player := get_parent()

func _ready():
	monitoring = true
	monitorable = true
	connect("body_entered", Callable(self, "_on_body_entered"))
	connect("body_exited", Callable(self, "_on_body_exited"))

func _on_body_entered(body: Node2D) -> void:
	if body.has_method("interact") or body is WorldItem:
		can_interact.append(body)

func _on_body_exited(body: Node2D) -> void:
	if body in can_interact:
		can_interact.erase(body)

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		for target in can_interact:
			# World item pickup
			if target is WorldItem:
				player.collect_world_item(target)
			# Other interactables
			elif target.has_method("interact"):
				target.interact(player)
