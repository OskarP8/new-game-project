extends CanvasLayer

@onready var fade: ColorRect = $Fade
@onready var anim: AnimationPlayer = $AnimationPlayer

var death_started := false

func _ready():
	fade.visible = false
	fade.color = Color(0, 0, 0, 0)

	var player = get_tree().root.find_child("Player", true, false)
	if player:
		player.player_died.connect(_on_player_died)

func _on_player_died():
	if death_started:
		return
	death_started = true

	print("[DeathDirector] ☠ Death sequence started")

	# 1️⃣ LET HIT FINISH
	await get_tree().create_timer(0.2).timeout

	# 2️⃣ NOW slow time (leaf dying moment)
	Engine.time_scale = 0.35

	# 3️⃣ Freeze enemies into idle
	_disable_enemy_ai()

	# 4️⃣ Wait for leaf death to finish
	await get_tree().create_timer(0.6).timeout

	# 5️⃣ Restore time for player death animation
	Engine.time_scale = 1.0

	# 6️⃣ Fade
	fade.visible = true
	anim.play("fade_in")

func _disable_enemy_ai():
	for enemy in get_tree().get_nodes_in_group("Enemy"):
		if enemy.has_method("disable_ai_and_idle"):
			enemy.disable_ai_and_idle()
