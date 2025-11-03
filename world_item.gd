extends Area2D
class_name WorldItem

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
	if _is_valid_interactable(body):
		if body in can_interact:
			return
		can_interact.append(body)
		print("[InteractArea] body_entered -> added:", body)

func _on_body_exited(body: Node) -> void:
	if body in can_interact:
		can_interact.erase(body)
		print("[InteractArea] body_exited -> removed:", body)

func _on_area_entered(area: Area2D) -> void:
	# other Area2D (e.g. WorldItem) enters our area
	if _is_valid_interactable(area):
		if area in can_interact:
			return
		can_interact.append(area)
		print("[InteractArea] area_entered -> added:", area)

func _on_area_exited(area: Area2D) -> void:
	if area in can_interact:
		can_interact.erase(area)
		print("[InteractArea] area_exited -> removed:", area)

func _is_valid_interactable(node: Node) -> bool:
	# Accept objects that have an interact(player) method or are WorldItem areas
	if node == null:
		return false
	if node is WorldItem:
		return true
	if node.has_method("interact"):
		return true
	return false

func _unhandled_key_input(event: InputEvent) -> void:
	# Only handle the mapped "interact" action
	if not event.is_action_pressed("interact"):
		return

	if can_interact.size() > 0:
		print("[InteractArea] No interactables in range")
		return

	# iterate over a shallow copy so handlers can modify can_interact safely
	var snapshot := can_interact.duplicate()
	for target in snapshot:
		if not is_instance_valid(target):
			# clean up stale references
			if target in can_interact:
				can_interact.erase(target)
			continue

		# WorldItem pickup
		if target is WorldItem:
			if player and player.has_method("collect_world_item"):
				print("[InteractArea] interacting: collect WorldItem ->", target.item.name if target.item else "nil")
				player.collect_world_item(target)
			else:
				print("[InteractArea] cannot collect - player missing collect_world_item")
		# other interactables (e.g., chest)
		elif target.has_method("interact"):
			print("[InteractArea] interacting: calling interact() on", target)
			target.interact(player)
		else:
			print("[InteractArea] unknown interactable type:", target)

		# optional: remove the target after interaction (if you want single-use)
		# if target in can_interact:
		#	can_interact.erase(target)
