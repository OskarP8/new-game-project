extends Node2D
class_name SpawnPoint

# -----------------------------
# CONFIG
# -----------------------------
@export var enemy_scenes: Array[PackedScene] = []          # enemy types
@export var enemy_weights: Array[int] = []                 # weight per enemy type
@export var max_active: int = 2
@export var spawn_radius: float = 320.0
@export var respawn_delay: float = 8.0
@export var despawn_distance: float = 800.0

# -----------------------------
# INTERNAL
# -----------------------------
@onready var notifier: VisibleOnScreenNotifier2D = $Visibility
var active_enemies: Array[Node] = []
var respawn_timer: float = 0.0

# -----------------------------
# READY
# -----------------------------
func _ready() -> void:
	# Ensure weights always match enemy list
	if enemy_weights.size() != enemy_scenes.size():
		enemy_weights.resize(enemy_scenes.size())
		for i in range(enemy_weights.size()):
			if enemy_weights[i] <= 0:
				enemy_weights[i] = 1


# -----------------------------
# PROCESS
# -----------------------------
func _process(delta: float) -> void:

	# --- Clean invalid entries ---
	active_enemies = active_enemies.filter(
		func(e): return e != null and e.is_inside_tree()
	)

	# --------------------------------------------------
	# Try spawning if capacity available
	# --------------------------------------------------
	if active_enemies.size() < max_active:

		var player: Node2D = get_tree().get_root().find_child("Player", true, false)
		if player == null:
			return

		var pdist := global_position.distance_to(player.global_position)

		# player must be close enough
		if pdist <= spawn_radius:

			var visible := false
			if notifier:
				visible = notifier.is_on_screen()

			# only spawn when not visible
			if not visible:
				respawn_timer += delta
				if respawn_timer >= respawn_delay:
					_spawn_enemy()
					respawn_timer = 0.0
			else:
				respawn_timer = 0.0

		else:
			respawn_timer = 0.0

	# --------------------------------------------------
	# Despawn enemies that went too far
	# --------------------------------------------------
	# --- Despawn enemies that went too far ---
	for enemy in active_enemies.duplicate():
		if enemy == null or not enemy.is_inside_tree():
			active_enemies.erase(enemy)
			continue

		var dist := global_position.distance_to(enemy.global_position)
		if dist > despawn_distance:
			# try to get a typed notifier if present
			var e_notifier: VisibleOnScreenNotifier2D = enemy.get_node_or_null("VisibleOnScreenNotifier2D") as VisibleOnScreenNotifier2D
			var visible: bool = false

			if e_notifier != null:
				visible = e_notifier.is_on_screen()

			if not visible:
				enemy.queue_free()
				active_enemies.erase(enemy)

# --------------------------------------------------------------
# SPAWN LOGIC
# --------------------------------------------------------------
func _spawn_enemy() -> void:

	var scene: PackedScene = _pick_weighted_enemy()
	if scene == null:
		return

	var inst: Node2D = scene.instantiate()
	inst.global_position = global_position

	get_tree().current_scene.add_child(inst)
	active_enemies.append(inst)

	# connect death signal (safe)
	if inst.has_signal("enemy_died"):
		inst.enemy_died.connect(_on_enemy_died)

	print("[SpawnPoint] Spawned: ", inst)


# --------------------------------------------------------------
# WEIGHTED RANDOM PICK
# --------------------------------------------------------------
func _pick_weighted_enemy() -> PackedScene:
	if enemy_scenes.is_empty():
		return null

	var total := 0
	for w in enemy_weights:
		total += w

	var rnd := randi() % total
	var accum := 0

	for i in range(enemy_scenes.size()):
		accum += enemy_weights[i]
		if rnd < accum:
			return enemy_scenes[i]

	return enemy_scenes[0]  # fallback


# --------------------------------------------------------------
# ENEMY DEATH
# --------------------------------------------------------------
func _on_enemy_died(enemy: Node) -> void:
	if enemy in active_enemies:
		active_enemies.erase(enemy)
