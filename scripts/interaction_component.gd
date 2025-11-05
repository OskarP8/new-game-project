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

func _process(_delta):
	if prompt and is_instance_valid(prompt) and not can_interact.is_empty():
		_update_prompt()

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
	if not prompt or can_interact.is_empty():
		return

	var closest := can_interact[0]
	var closest_dist := global_position.distance_to(closest.global_position)
	for c in can_interact:
		var d := global_position.distance_to(c.global_position)
		if d < closest_dist:
			closest = c
			closest_dist = d

	if not is_instance_valid(closest):
		return

	var player_x := global_position.x
	var item_x := closest.global_position.x
	var offset := Vector2.ZERO

	# determine which side the prompt should be on
	if player_x < item_x:
		offset = Vector2(1, -4)  # player is left -> prompt on right
	else:
		offset = Vector2(-1, -4) # player is right -> prompt on left

	var target_pos := closest.global_position + offset

	# 🌀 Smooth movement using tween
	if not prompt.has_meta("move_tween") or not is_instance_valid(prompt.get_meta("move_tween")):
		var tw := create_tween()
		tw.tween_property(prompt, "global_position", target_pos, 0.15).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		prompt.set_meta("move_tween", tw)
	else:
		var tw: Tween = prompt.get_meta("move_tween")
		if tw.is_running():
			tw.stop()
		tw = create_tween()
		tw.tween_property(prompt, "global_position", target_pos, 0.15).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		prompt.set_meta("move_tween", tw)

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
