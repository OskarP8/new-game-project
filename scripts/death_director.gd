extends CanvasLayer

@onready var fade: ColorRect = $Fade
@onready var anim: AnimationPlayer = $AnimationPlayer

var death_started := false
var _target_scene: String = ""
var _transitioning := false
var _pending_spawn_position: Vector2 = Vector2.ZERO
var _use_custom_spawn := false

func _ready():
	add_to_group("DeathDirector")

	fade.visible = false
	fade.color = Color(0, 0, 0, 0)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE

	anim.animation_finished.connect(_on_fade_anim_finished)

	var player = get_tree().root.find_child("Player", true, false)
	if player:
		player.player_died.connect(_on_player_died)

func _on_player_died():
	print("[DeathDirector] 🔹 _on_player_died() called")
	if death_started:
		return
	death_started = true

	print("[DeathDirector] ☠ Death sequence started")

	await get_tree().create_timer(0.2).timeout
	Engine.time_scale = 0.35
	_disable_enemy_ai()
	await get_tree().create_timer(0.6).timeout
	Engine.time_scale = 1.0
	await get_tree().process_frame

	var player = get_tree().root.find_child("Player", true, false)
	if player:
		if player.has_node("Graphics/Body"):
			player.get_node("Graphics/Body").stop()
		if player.has_node("Head"):
			player.get_node("Head").stop()
		if player.weapon_sprite:
			player.weapon_sprite.stop()

		if player.has_node("AnimationPlayer"):
			var ap: AnimationPlayer = player.get_node("AnimationPlayer")
			ap.stop(true)
			ap.play("death")
			await ap.animation_finished
	# 🔁 USE SAME FADE SYSTEM
	if GameState.has_checkpoint():
		var data = GameState.get_respawn_data()
		fade_to_scene(data.scene)
	else:
		fade_to_scene(get_tree().current_scene.scene_file_path)

func _disable_enemy_ai():
	for enemy in get_tree().get_nodes_in_group("Enemy"):
		if enemy.has_method("disable_ai_and_idle"):
			enemy.disable_ai_and_idle()

func fade_to_scene(scene_path: String) -> void:
	if _transitioning:
		return

	_transitioning = true
	_target_scene = scene_path
	fade.visible = true
	anim.play("fade")

	# Disconnect previous connection safely
	if get_tree().scene_changed.is_connected(_on_scene_changed):
		get_tree().scene_changed.disconnect(_on_scene_changed)

	print("[DeathDirector] 🔹 Connecting scene_changed signal")
	get_tree().scene_changed.connect(_on_scene_changed)

func _do_scene_change() -> void:
	print("[DeathDirector] 🔹 _do_scene_change() called, target_scene:", _target_scene)
	if _target_scene == "":
		return

	get_tree().change_scene_to_file(_target_scene)
	print("[DeathDirector] 🔹 change_scene_to_file called")

	call_deferred("_apply_checkpoint")

func _on_fade_anim_finished(anim_name: String) -> void:
	if anim_name != "fade":
		return

	var current := get_tree().current_scene
	if _target_scene != "" and (not current or _target_scene != current.scene_file_path):
		await _do_scene_change()

	_transitioning = false
	_target_scene = ""
	fade.visible = false
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _input(event):
	if _transitioning:
		get_viewport().set_input_as_handled()

func _apply_checkpoint():
	print("[DeathDirector] 🔹 _apply_checkpoint() called")
	var scene := get_tree().current_scene
	if not scene:
		print("[DeathDirector] ❌ Scene not ready yet")
		return

	var player := scene.get_node_or_null("Player")
	if not player:
		print("[DeathDirector] ❌ Player not found in scene")
		return

	if _use_custom_spawn:
		print("[DeathDirector] ✅ Using custom spawn:", _pending_spawn_position)
		player.global_position = _pending_spawn_position
		_use_custom_spawn = false
	elif GameState.has_checkpoint():
		print("[DeathDirector] ✅ Respawning at checkpoint:", GameState.checkpoint_position)
		player.global_position = GameState.checkpoint_position
	elif GameState.has_save():
		var data = GameState.get_save_data()
		print("[DeathDirector] ✅ Loading saved game position:", data.position)
		player.global_position = data.position
	else:
		print("[DeathDirector] ❌ No checkpoint or save, spawning at default")

func set_pending_spawn_position(pos: Vector2):
	_pending_spawn_position = pos
	_use_custom_spawn = true

func _on_scene_changed(new_scene: Node) -> void:
	# Disconnect immediately to avoid multiple calls
	if get_tree().scene_changed.is_connected(_on_scene_changed):
		get_tree().scene_changed.disconnect(_on_scene_changed)

	print("[DeathDirector] ✅ New scene loaded:", new_scene.name)
	_apply_checkpoint()
