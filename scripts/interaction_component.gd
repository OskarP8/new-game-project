extends Area2D

@onready var player: Node2D = get_parent()
@onready var prompt_scene = preload("res://scenes/interact_prompt.tscn")

var can_interact: Array[Node] = []
var prompt: Node2D = null

func _ready() -> void:
	connect("body_entered", Callable(self, "_on_body_entered"))
	connect("body_exited", Callable(self, "_on_body_exited"))
	connect("area_entered", Callable(self, "_on_area_entered"))
	connect("area_exited", Callable(self, "_on_area_exited"))
	set_process(true)
	print("[InteractArea] ready - player:", player)


func _process(_delta: float) -> void:
	_update_prompt()


# ---------------------------------------------------------------------
# SIGNALS
# ---------------------------------------------------------------------
func _on_body_entered(body: Node) -> void:
	if _is_valid_interactable(body) and body not in can_interact:
		can_interact.append(body)
		print("[InteractArea] body_entered ->", body)


func _on_body_exited(body: Node) -> void:
	if body in can_interact:
		can_interact.erase(body)
		print("[InteractArea] body_exited ->", body)
	_update_prompt()


func _on_area_entered(area: Area2D) -> void:
	if _is_valid_interactable(area) and area not in can_interact:
		can_interact.append(area)
		print("[InteractArea] area_entered ->", area)
	_update_prompt()


func _on_area_exited(area: Area2D) -> void:
	if area in can_interact:
		can_interact.erase(area)
		print("[InteractArea] area_exited ->", area)
	_update_prompt()


# ---------------------------------------------------------------------
# VALIDATION
# ---------------------------------------------------------------------
func _is_valid_interactable(node: Node) -> bool:
	if node == null:
		return false
	if node is WorldItem:
		return true
	if node.has_method("interact"):
		return true
	return false


# ---------------------------------------------------------------------
# FIND CLOSEST INTERACTABLE
# ---------------------------------------------------------------------
func _get_closest_interactable() -> Node:
	if can_interact.is_empty():
		return null

	var closest: Node = null
	var best_dist := INF

	for obj in can_interact:
		if not is_instance_valid(obj):
			continue

		# Skip opened chests (if they have an is_open property)
		if "is_open" in obj and obj.is_open:
			continue

		var obj_pos: Vector2
		if "global_position" in obj:
			obj_pos = obj.global_position
		elif "global_transform" in obj:
			obj_pos = obj.global_transform.origin
		else:
			continue

		var d := obj_pos.distance_to(player.global_position)
		if d < best_dist:
			best_dist = d
			closest = obj

	return closest


# ---------------------------------------------------------------------
# PROMPT HANDLING
# ---------------------------------------------------------------------
func _update_prompt() -> void:
	# find closest interactable (your existing helper)
	var closest: Node = _get_closest_interactable()

	# If nothing nearby -> hide prompt (if valid) and return
	if closest == null:
		if prompt:
			# only call methods on the prompt if it's a valid instance
			if is_instance_valid(prompt):
				if prompt.has_method("hide_prompt"):
					prompt.hide_prompt()
				else:
					prompt.visible = false
			# if prompt is invalid, drop the reference
			else:
				prompt = null
		return

	# If prompt reference exists but was freed, nil it so we recreate
	if prompt and not is_instance_valid(prompt):
		print("[InteractArea] prompt reference was freed — clearing reference")
		prompt = null

	# Ensure prompt exists and is valid
	if prompt == null:
		prompt = prompt_scene.instantiate()
		# Use deferred add to avoid tree modification during physics/frame callbacks
		get_tree().current_scene.call_deferred("add_child", prompt)
		print("[InteractArea] prompt created:", prompt, "id:", str(prompt.get_instance_id()))

	# Now it's safe to call methods (again verify validity)
	if prompt and is_instance_valid(prompt):
		var offset := Vector2(10, 6)
		var target_pos: Vector2 = closest.global_position + offset

		if prompt.has_method("show_prompt"):
			prompt.show_prompt("Press E", target_pos)
		else:
			prompt.global_position = target_pos
			prompt.visible = true
	else:
		# very defensive fallback
		prompt = null

# ---------------------------------------------------------------------
# INPUT HANDLING
# ---------------------------------------------------------------------
func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed("interact"):
		return

	if can_interact.is_empty():
		return

	var snapshot := can_interact.duplicate()

	for target in snapshot:
		if not is_instance_valid(target):
			can_interact.erase(target)
			continue

		# ---- WorldItem pickup ----
		if target is WorldItem:
			if player.has_method("collect_world_item"):
				var before_count := can_interact.size()
				player.collect_world_item(target)

				# only erase if the item was actually picked up (freed)
				if not is_instance_valid(target):
					can_interact.erase(target)
				else:
					print("[InteractArea] ⚠ Item still valid — inventory full, keeping in list (retry allowed)")
			else:
				print("[InteractArea] ⚠ Player missing collect_world_item()")
			continue

		# ---- Chest or other interactable ----
		if target.has_method("interact"):
			var was_open_before = ("is_open" in target and target.is_open)
			target.interact(player)

			# Only mark as open if the interaction actually succeeded
			if "is_open" in target and target.is_open and not was_open_before:
				# Interaction succeeded — hide prompt
				if prompt:
					if prompt.has_method("hide_prompt"):
						prompt.hide_prompt()
					else:
						prompt.hide()
				if target in can_interact:
					can_interact.erase(target)
			else:
				# Interaction failed (e.g. inventory full) — keep target interactable
				if "is_open" in target and not target.is_open:
					if target not in can_interact:
						can_interact.append(target)
					_update_prompt()
					print("[InteractArea] 🔄 Chest reopen allowed — kept in interact list")

			continue
