extends Area2D

var can_interact: Array[Node2D] = []

@onready var player := get_parent()
@onready var prompt_scene = preload("res://scenes/interact_prompt.tscn")
var prompt: Node2D = null

func _ready():
	connect("body_entered", Callable(self, "_on_body_entered"))
	connect("body_exited", Callable(self, "_on_body_exited"))
	connect("area_entered", Callable(self, "_on_area_entered"))
	connect("area_exited", Callable(self, "_on_area_exited"))
	monitoring = true
	monitorable = true
	print("[InteractArea] ready - player:", player)

func _on_body_entered(body: Node) -> void:
	if _is_valid_interactable(body):
		if body not in can_interact:
			can_interact.append(body)
			print("[InteractArea] added interactable:", body)
		_update_prompt()

func _on_body_exited(body: Node) -> void:
	if body in can_interact:
		can_interact.erase(body)
		print("[InteractArea] removed interactable:", body)
		_update_prompt()

func _on_area_entered(area: Area2D) -> void:
	if _is_valid_interactable(area):
		if area not in can_interact:
			can_interact.append(area)
			print("[InteractArea] added interactable area:", area)
		_update_prompt()

func _on_area_exited(area: Area2D) -> void:
	if area in can_interact:
		can_interact.erase(area)
		print("[InteractArea] removed interactable area:", area)
		_update_prompt()

func _is_valid_interactable(node: Node) -> bool:
	if node == null:
		return false
	if node is WorldItem:
		return true
	if node.has_method("interact"):
		return true
	return false

func _update_prompt():
	if can_interact.is_empty():
		if prompt:
			prompt.hide_prompt()
		return

	var closest := _get_closest_interactable()
	if not closest:
		if prompt:
			prompt.hide_prompt()
		return

	if not prompt:
		prompt = prompt_scene.instantiate()
		get_tree().current_scene.add_child(prompt)

	# position the prompt near the closest interactable
	# you can offset or adjust here as needed
	prompt.show_prompt("Press E", closest.global_position)

func _get_closest_interactable() -> Node2D:
	var closest: Node2D = null
	var min_dist := 1e20
	for node in can_interact:
		if not is_instance_valid(node):
			continue
		if not node.has_method("global_position") and not node.has_method("get_global_position"):
			# defensive: skip nodes without position
			continue
		var node_pos: Vector2 = node.global_position if "global_position" in node else node.get_global_position()
		var dist = global_position.distance_to(node_pos)
		if dist < min_dist:
			min_dist = dist
			closest = node
	return closest

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed("interact"):
		return

	if can_interact.is_empty():
		print("[InteractArea] No interactables in range")
		return

	var snapshot := can_interact.duplicate()
	for target in snapshot:
		if not is_instance_valid(target):
			if target in can_interact:
				can_interact.erase(target)
			continue

		if target is WorldItem:
			if player and player.has_method("collect_world_item"):
				print("[InteractArea] interacting: collect WorldItem ->", target.item.name if target.item else "nil")
				player.collect_world_item(target)
				# remove picked world item from list and update prompt
				if target in can_interact:
					can_interact.erase(target)
				_update_prompt()
			else:
				print("[InteractArea] cannot collect - player missing collect_world_item")
		elif target.has_method("interact"):
			print("[InteractArea] interacting: calling interact() on", target)
			target.interact(player)
			# keep/update can_interact as the interactable might remain or be consumed
