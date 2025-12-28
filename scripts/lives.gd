extends CanvasLayer

@onready var leaf_slots: Array = $Leaves.get_children()
@onready var anim_player := $AnimationPlayer if has_node("AnimationPlayer") else null
@onready var particles := $Particles if has_node("Particles") else null

func _ready() -> void:
	var player = get_tree().root.find_child("Player", true, false)
	if not player:
		push_warning("[Lives] Player not found")
		return

	# Initialize lives visually
	if "default_lives" in player:
		_set_initial_lives(player.default_lives)

	# Signals from player
	if player.has_signal("life_lost"):
		player.life_lost.connect(_on_life_lost)

	if player.has_signal("player_died"):
		player.player_died.connect(_on_player_died)

# ----------------------
# INITIAL SETUP
# ----------------------
func _set_initial_lives(count: int) -> void:
	for i in range(leaf_slots.size()):
		if i < count:
			leaf_slots[i].set_alive()
		else:
			leaf_slots[i].state = leaf_slots[i].LeafState.EMPTY

# ----------------------
# LIFE LOSS
# ----------------------
func _on_life_lost(_current_lives: int) -> void:
	# Kill the RIGHTMOST alive leaf
	for i in range(leaf_slots.size() - 1, -1, -1):
		if leaf_slots[i].state == leaf_slots[i].LeafState.ALIVE:
			leaf_slots[i].kill()
			break

	# Optional UI effects
	if anim_player and anim_player.has_animation("life_lost"):
		anim_player.play("life_lost")

	if particles:
		particles.emitting = false
		particles.emitting = true

# ----------------------
# REGROWTH (call from timer / checkpoint)
# ----------------------
func try_regrow_leaf() -> void:
	for slot in leaf_slots:
		if slot.state == slot.LeafState.EMPTY:
			slot.start_growing()
			return

# ----------------------
# DEATH
# ----------------------
func _on_player_died() -> void:
	if anim_player and anim_player.has_animation("death"):
		anim_player.play("death")
