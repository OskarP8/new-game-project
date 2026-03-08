extends StaticBody2D
class_name Checkpoint

@export var require_button_press: bool = false
@export var activate_once: bool = false

@onready var interaction_area: Area2D = $Interaction
@onready var anim_player: AnimationPlayer = $AnimationPlayer

# optional: show an "E" prompt similar to Taara/chest
@onready var prompt_scene := preload("res://scenes/interact_prompt.tscn")
var prompt: Node2D = null

var _player_inside: Node = null

func _ready() -> void:
	# keep group for toggling other checkpoints
	add_to_group("Checkpoints")

	# connect signals safely (same as before)
	if interaction_area:
		if not interaction_area.is_connected("body_entered", Callable(self, "_on_interaction_body_entered")):
			interaction_area.body_entered.connect(Callable(self, "_on_interaction_body_entered"))
		if not interaction_area.is_connected("area_entered", Callable(self, "_on_interaction_area_entered")):
			interaction_area.area_entered.connect(Callable(self, "_on_interaction_area_entered"))
		if not interaction_area.is_connected("body_exited", Callable(self, "_on_interaction_body_exited")):
			interaction_area.body_exited.connect(Callable(self, "_on_interaction_body_exited"))
		if not interaction_area.is_connected("area_exited", Callable(self, "_on_interaction_area_exited")):
			interaction_area.area_exited.connect(Callable(self, "_on_interaction_area_exited"))

	_update_animation_from_gamestate()

func _process(delta: float) -> void:
	# If player is inside and pressed the interact key -> call Taara
	if _player_inside and Input.is_action_just_pressed("interact"):
		# If require_button_press is true we still want the same behaviour:
		# pressing 'interact' here will call Taara but activation on enter is unchanged.
		_call_taara_to_player(_player_inside)

# body / area enter handlers (cover both CharacterBody2D and Area2D player hitboxes)
func _on_interaction_body_entered(body: Node) -> void:
	if _is_player_node(body):
		_player_inside = body
		_show_prompt(true)
		# preserve original behavior: auto-activate on enter when require_button_press==false
		if not require_button_press:
			_try_activate(body)

func _on_interaction_area_entered(area: Area2D) -> void:
	var candidate := area.get_parent() if area.get_parent() != null else area
	if _is_player_node(candidate):
		_player_inside = candidate
		_show_prompt(true)
		if not require_button_press:
			_try_activate(candidate)

func _on_interaction_body_exited(body: Node) -> void:
	if _player_inside == body:
		_player_inside = null
		_show_prompt(false)

func _on_interaction_area_exited(area: Area2D) -> void:
	var candidate := area.get_parent() if area.get_parent() != null else area
	if _player_inside == candidate:
		_player_inside = null
		_show_prompt(false)

# activation attempt (keeps your original logic)
func _try_activate(player_node: Node) -> void:
	# If already the checkpoint in GameState, still run activation visual/logic but make sure state is normal.
	var already = (GameState.checkpoint_position == global_position)

	# set the checkpoint in GameState (same as before)
	GameState.set_checkpoint(get_tree().current_scene.scene_file_path, global_position)
	print("[Checkpoint] Activated at ", global_position)

	# update visuals on all checkpoints
	_set_active_and_deactivate_others()

	# play activation animation
	if anim_player and anim_player.has_animation("activate"):
		anim_player.play("activate")

	# If activate_once is requested, disable the interaction area so it truly becomes single-use.
	if activate_once and interaction_area:
		# disable now (deferred to be safe from signal stack)
		interaction_area.set_deferred("monitoring", false)

	# IMPORTANT: clear local player reference and hide the prompt so the player's interaction component
	# will recompute the closest interactable on the next frame and won't hold a stale reference.
	_player_inside = null
	_show_prompt(false)

func _set_active_and_deactivate_others() -> void:
	for cp in get_tree().get_nodes_in_group("Checkpoints"):
		if not is_instance_valid(cp):
			continue
		var ap: AnimationPlayer = null
		if cp.has_node("AnimationPlayer"):
			ap = cp.get_node("AnimationPlayer") as AnimationPlayer
		if cp == self:
			if ap and ap.has_animation("active"):
				ap.play("active")
		else:
			if ap and ap.has_animation("idle"):
				ap.play("idle")

func _update_animation_from_gamestate() -> void:
	var current_pos = GameState.checkpoint_position
	if current_pos == global_position:
		if anim_player and anim_player.has_animation("active"):
			anim_player.play("active")
	else:
		if anim_player and anim_player.has_animation("idle"):
			anim_player.play("idle")

# show/hide the interact prompt (uses same prompt scene as other interactables)
func _show_prompt(visible: bool) -> void:
	if visible:
		if prompt == null and prompt_scene:
			prompt = prompt_scene.instantiate()
			get_tree().current_scene.add_child(prompt)
		if prompt:
			var offset := Vector2(10, 6)
			var target_pos := global_position + offset
			if prompt.has_method("show_prompt"):
				prompt.show_prompt("Press E", target_pos)
			else:
				prompt.global_position = target_pos
				prompt.visible = true
	else:
		if prompt:
			if prompt.has_method("hide_prompt"):
				prompt.hide_prompt()
			else:
				prompt.visible = false

# safe Taara lookup + call helper (replace your old _call_taara_to_player)
func _call_taara_to_player(player_node: Node) -> void:
	if player_node == null:
		return

	# 1) Try current scene direct child named "Taara"
	var taara = null
	var cs := get_tree().current_scene
	if cs != null:
		taara = cs.get_node_or_null("Taara")
		# also try find_node on the current_scene (safe: current_scene is a Node)
		if taara == null and cs.has_method("find_node"):
			taara = cs.find_node("Taara", true, false)

	# 2) Try a global recursive search starting from current_scene if not found
	if taara == null and cs != null:
		taara = _recursive_find_by_name(cs, "Taara")

	# 3) As a last resort, scan the whole tree but do it safely (avoid calling find_node on Window)
	if taara == null:
		var root := get_tree().get_root()
		# prefer iterating children if possible
		if root != null:
			taara = _recursive_find_by_name(root, "Taara")

	# 4) fallback: find any node that provides a call_to(player, bool) method
	if taara == null:
		for n in _iter_all_nodes():
			if n != null and n.has_method("call_to"):
				taara = n
				break

	if taara == null:
		print("[Checkpoint] Taara not found in scene tree.")
		return

	# If Taara provides call_to(player, auto_open_dialog), call it.
	if taara.has_method("call_to"):
		print("[Checkpoint] Calling Taara.call_to() to teleport Taara to player.")
		taara.call("call_to", player_node, true)
	else:
		print("[Checkpoint] Found Taara-like node but it has no call_to(player, ...) method.")


# Recursively search children for a node with given name.
# Starts from `start_node` and searches depth-first. Safe: checks for child iteration methods.
func _recursive_find_by_name(start_node: Node, target_name: String) -> Node:
	if start_node == null:
		return null
	# direct match
	if "name" in start_node and start_node.name == target_name:
		return start_node
	# iterate children if available
	if start_node.has_method("get_child_count"):
		for i in range(start_node.get_child_count()):
			var child = start_node.get_child(i)
			if child == null:
				continue
			if "name" in child and child.name == target_name:
				return child
			var res := _recursive_find_by_name(child, target_name)
			if res != null:
				return res
	return null


# Fallback: return array of all nodes in the tree (used only if other lookups fail)
func _iter_all_nodes() -> Array:
	var out := []
	var stack := [ get_tree().get_root() ]
	while stack.size() > 0:
		var n = stack.pop_back()
		if n == null:
			continue
		out.append(n)
		if n.has_method("get_child_count"):
			for i in range(n.get_child_count()):
				stack.append(n.get_child(i))
	return out

# robust player detection helper (group preferred)
func _is_player_node(n: Node) -> bool:
	if n == null:
		return false
	if n.is_in_group("Player"):
		return true
	if "name" in n and n.name == "Player":
		return true
	var p = n.get_parent()
	if p and (p.is_in_group("Player") or ("name" in p and p.name == "Player")):
		return true
	return false
