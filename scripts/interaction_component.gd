extends Area2D

var can_interact: Array[Node2D] = []
@onready var player := get_parent()

func _ready():
	connect("body_entered", Callable(self, "_on_body_entered"))
	connect("body_exited", Callable(self, "_on_body_exited"))
	connect("area_entered", Callable(self, "_on_area_entered"))
	connect("area_exited", Callable(self, "_on_area_exited"))
	monitoring = true
	monitorable = true
	print("[InteractArea] ready - player:", player)

func _on_body_entered(body: Node) -> void:
	if _is_valid_interactable(body) and not can_interact.has(body):
		can_interact.append(body)
		print("[InteractArea] body_entered -> added:", body)

func _on_body_exited(body: Node) -> void:
	if can_interact.has(body):
		can_interact.erase(body)
		print("[InteractArea] body_exited -> removed:", body)

func _on_area_entered(area: Area2D) -> void:
	if _is_valid_interactable(area) and not can_interact.has(area):
		can_interact.append(area)
		print("[InteractArea] area_entered -> added:", area)

func _on_area_exited(area: Area2D) -> void:
	if can_interact.has(area):
		can_interact.erase(area)
		print("[InteractArea] area_exited -> removed:", area)

func _is_valid_interactable(node: Node) -> bool:
	if node == null:
		return false
	return node is WorldItem or node.has_method("interact")

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed("interact"):
		return

	if can_interact.is_empty():
		print("[InteractArea] No interactables in range")
		return

	for target in can_interact.duplicate():
		if not is_instance_valid(target):
			can_interact.erase(target)
			continue

		if target is WorldItem:
			player.collect_world_item(target)
		elif target.has_method("interact"):
			target.interact(player)
