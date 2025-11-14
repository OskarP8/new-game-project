extends Node2D
class_name SpawnPoint

# -----------------------------
# CONFIG
# -----------------------------
@export var enemy_scenes: Array[PackedScene] = []               # enemy types
@export var enemy_weights: Array[int] = []                      # weight per enemy type
@export var max_active: int = 2
@export var spawn_radius: float = 320.0
@export var respawn_delay: float = 8.0
@export var despawn_distance: float = 800.0

# -----------------------------
# INTERNAL
# -----------------------------
@onready var notifier: VisibleOnScreenNotifier2D = $VisibleOnScreenNotifier2D
var active_enemies: Array = []
var respawn_timer: float = 0.0


func _ready():
	# Ensure weights match list size
	if enemy_weights.size() != enemy_scenes.size():
		enemy_weights.resize(enemy_scenes.size())
		for i in range(enemy_weights.size()):
			if enemy_weights[i] <= 0:
				enemy_weights[i] = 1  # default weight


func _process(delta: float) -> void:

	# --- Clean enemy list ---
	active_enemies = active_enemies.filter(func(e): return e and e.is_inside_tree())

	# --- Check respawn conditions ---
	if active_enemies.size() < max_active:

		var player := get_tree().get_root().find_child("Player", true, false)
		if player == null:
			return

		# player close enough?
		var pdist := global_position.distance_to(player.global_position)
		if pdist <= spawn_radius:

			# Spawn point invisible?
			if not notifier.is_on_screen():
				respawn_timer += delta
				if respawn_timer >= respawn_delay:
					_spawn_enemy()
					respawn_timer = 0.0
			else:
				respawn_timer = 0.0
		else:
			respawn_timer = 0.0

	# --- Despawn if too far ---
	for enemy in active_enemies.duplicate():
		if enemy == null or not enemy.is_inside_tree():
			active_enemies.erase(enemy)
			continue

		var dist := global_position.distance_to(enemy.global_position)
		if dist > despawn_distance:

			var e_notifier = enemy.get_node_or_null("VisibleOnScreenNotifier2D")
			var visible: bool = e_notifier and e_notifier.is_on_screen()

			if not visible:
				enemy.queue_free()
				active_enemies.erase(enemy)


# --------------------------------------------------------------
# SPAWN LOGIC (WITH WEIGHTED RANDOM)
# --------------------------------------------------------------
func _spawn_enemy():

	var scene := _pick_weighted_enemy()
	if scene == null:
		return

	var inst = scene.instantiate()
	inst.global_position = global_position

	get_tree().current_scene.add_child(inst)
	active_enemies.append(inst)

	# Listen for enemy death
	if inst.has_signal("enemy_died"):
		inst.enemy_died.connect(_on_enemy_died)

	print("[SpawnPoint] Spawned: ", inst)


# --------------------------------------------------------------
# weighted random pick
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

	return enemy_scenes[0]   # fallback


func _on_enemy_died(enemy):
	if enemy in active_enemies:
		active_enemies.erase(enemy)
	# respawn timer will tick normally
