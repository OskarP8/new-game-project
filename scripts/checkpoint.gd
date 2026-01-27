extends StaticBody2D
class_name Checkpoint

@export var require_button_press: bool = false
# keep this for inspector but we no longer permanently block re-activation
@export var activate_once: bool = false

@onready var interaction_area: Area2D = $Interaction
@onready var anim_player: AnimationPlayer = $AnimationPlayer

var _player_inside: Node = null

func _ready() -> void:
	# register in group so we can toggle other checkpoints' animations
	add_to_group("Checkpoints")

	# connect interaction signals safely
	if interaction_area:
		if not interaction_area.is_connected("body_entered", Callable(self, "_on_interaction_body_entered")):
			interaction_area.body_entered.connect(Callable(self, "_on_interaction_body_entered"))
		if not interaction_area.is_connected("area_entered", Callable(self, "_on_interaction_area_entered")):
			interaction_area.area_entered.connect(Callable(self, "_on_interaction_area_entered"))
		if not interaction_area.is_connected("body_exited", Callable(self, "_on_interaction_body_exited")):
			interaction_area.body_exited.connect(Callable(self, "_on_interaction_body_exited"))
		if not interaction_area.is_connected("area_exited", Callable(self, "_on_interaction_area_exited")):
			interaction_area.area_exited.connect(Callable(self, "_on_interaction_area_exited"))

	# Set animation state according to GameState on load (so active checkpoint shows active anim)
	_update_animation_from_gamestate()

func _process(delta: float) -> void:
	# If we require a button press, allow activation only while player is inside and pressing "interact"
	if require_button_press and _player_inside and Input.is_action_just_pressed("interact"):
		_try_activate(_player_inside)

# body / area enter handlers (cover both CharacterBody2D and Area2D player hitboxes)
func _on_interaction_body_entered(body: Node) -> void:
	if _is_player_node(body):
		_player_inside = body
		if not require_button_press:
			_try_activate(body)

func _on_interaction_area_entered(area: Area2D) -> void:
	var candidate := area.get_parent() if area.get_parent() != null else area
	if _is_player_node(candidate):
		_player_inside = candidate
		if not require_button_press:
			_try_activate(candidate)

func _on_interaction_body_exited(body: Node) -> void:
	if _player_inside == body:
		_player_inside = null

func _on_interaction_area_exited(area: Area2D) -> void:
	var candidate := area.get_parent() if area.get_parent() != null else area
	if _player_inside == candidate:
		_player_inside = null

# activation attempt
func _try_activate(player_node: Node) -> void:
	# If GameState already points here, we still want to refresh animations — allow re-activation.
	var already = (GameState.checkpoint_position == global_position)

	# set the checkpoint in GameState
	GameState.set_checkpoint(get_tree().current_scene.scene_file_path, global_position)
	print("[Checkpoint] Activated at ", global_position)

	# animate this one as active, all others idle
	_set_active_and_deactivate_others()

	# Optionally disable further triggering on this checkpoint if user explicitly set activate_once true.
	# But note: with activate_once=true it will still allow re-activation by turning off monitoring,
	# so you won't be able to "re-activate" this checkpoint unless you re-enable it manually.
	if activate_once:
		if interaction_area:
			interaction_area.monitoring = false
			interaction_area.set_deferred("monitoring", false)

	# Play local activation animation (if present)
	if anim_player and anim_player.has_animation("activate"):
		anim_player.play("activate")

# Set this checkpoint active visually and set every other checkpoint to idle
func _set_active_and_deactivate_others() -> void:
	for cp in get_tree().get_nodes_in_group("Checkpoints"):
		# ensure valid instance and it has an AnimationPlayer
		if not is_instance_valid(cp):
			continue
		var ap: AnimationPlayer = null
		if cp.has_node("AnimationPlayer"):
			ap = cp.get_node("AnimationPlayer") as AnimationPlayer
		# If it's this checkpoint -> active animation
		if cp == self:
			if ap and ap.has_animation("active"):
				ap.play("active")
		else:
			if ap and ap.has_animation("idle"):
				ap.play("idle")

# On load, sync animation state to GameState so the previously active checkpoint shows active
func _update_animation_from_gamestate() -> void:
	var current_pos = GameState.checkpoint_position
	if current_pos == global_position:
		# this one is the saved active checkpoint
		if anim_player and anim_player.has_animation("active"):
			anim_player.play("active")
	else:
		if anim_player and anim_player.has_animation("idle"):
			anim_player.play("idle")

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
