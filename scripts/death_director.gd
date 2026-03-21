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

	if GameState.has_checkpoint():
		var data = GameState.get_respawn_data()
		# read from dict safely
		var scene_path := ""
		var pos := Vector2.ZERO
		if typeof(data) == TYPE_DICTIONARY:
			scene_path = str(data.get("scene", ""))
			pos = data.get("position", Vector2.ZERO)
		# fallback to current scene if empty
		if scene_path == "":
			scene_path = get_tree().current_scene.scene_file_path if get_tree().current_scene else ""
		# remember pending spawn pos so Player can be placed after load if desired
		if pos != Vector2.ZERO:
			set_pending_spawn_position(pos)
		fade_to_scene(scene_path)
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

func _do_scene_change() -> void:
	print("[DeathDirector] 🔹 _do_scene_change() called, target_scene:", _target_scene)
	if _target_scene == "":
		return

	get_tree().change_scene_to_file(_target_scene)
	print("[DeathDirector] 🔹 change_scene_to_file called")
	# ensure GameState applies saved data to the newly loaded scene:
	call_deferred("_apply_gamestate_after_scene_change")

# DeathDirector.gd
func _apply_gamestate_after_scene_change() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		print("[DeathDirector] WARNING: Engine.get_main_loop() returned null; skipping GameState load")
		return

	# Wait a couple frames so the scene/autoloads can finish instancing.
	await tree.process_frame
	await tree.process_frame

	# Wait for GameState to exist, but be patient (cap to avoid infinite wait).
	var attempts := 0
	var max_attempts := 120  # ~2 seconds at 60 FPS; increase if your scene init is heavy
	while not Engine.has_singleton("GameState") and attempts < max_attempts:
		await tree.process_frame
		attempts += 1

	if Engine.has_singleton("GameState"):
		# Defensive call
		if GameState.has_method("load_save"):
			print("[DeathDirector] _apply_gamestate_after_scene_change -> calling GameState.load_save() after %d frames wait" % attempts)
			GameState.load_save()
		else:
			print("[DeathDirector] _apply_gamestate_after_scene_change -> GameState exists but has no load_save()")
		return

	# Fallback: GameState never appeared in time — log and return.
	print("[DeathDirector] WARNING: GameState singleton not present after waiting %d frames; skipping load_save()" % attempts)

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

func set_pending_spawn_position(pos: Vector2):
	_pending_spawn_position = pos
	_use_custom_spawn = true
