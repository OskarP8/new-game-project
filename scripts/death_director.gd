extends CanvasLayer

@onready var fade: ColorRect = $Fade
@onready var anim: AnimationPlayer = $AnimationPlayer

var death_started := false
var _target_scene: String = ""
var _transitioning := false
var _pending_spawn_position: Vector2 = Vector2.ZERO
var _use_custom_spawn := false
var _scene_change_started := false
var _threaded_scene_path := ""

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
	print("[DeathDirector] death received; checkpoint:", GameState.has_checkpoint())
	if death_started:
		return
	death_started = true
	# Capture the live inventory before the scene creates empty UI resources.
	GameState.save()
	GameState.suppress_inventory_autosave = true

	print("[DeathDirector] respawn sequence started")

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

func fade_to_scene(scene_path: String, speed_scale: float = 1.0) -> void:
	if _transitioning:
		return

	_transitioning = true
	_scene_change_started = false
	_target_scene = scene_path
	_threaded_scene_path = ""
	if scene_path != "":
		var request_error := ResourceLoader.load_threaded_request(scene_path)
		if request_error == OK:
			_threaded_scene_path = scene_path
	fade.visible = true
	anim.speed_scale = speed_scale
	anim.play("fade")

func _do_scene_change() -> void:
	if _scene_change_started:
		return
	_scene_change_started = true
	print("[StartupTiming] scene change begin ms:", Time.get_ticks_msec(), " target:", _target_scene)
	if _target_scene == "":
		return

	var packed_scene: PackedScene = null
	if _threaded_scene_path == _target_scene:
		while true:
			var load_status := ResourceLoader.load_threaded_get_status(_target_scene)
			if load_status == ResourceLoader.THREAD_LOAD_LOADED:
				packed_scene = ResourceLoader.load_threaded_get(_target_scene) as PackedScene
				break
			if load_status == ResourceLoader.THREAD_LOAD_FAILED or load_status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				break
			await get_tree().process_frame

	if packed_scene != null:
		get_tree().change_scene_to_packed(packed_scene)
	else:
		get_tree().change_scene_to_file(_target_scene)
	print("[StartupTiming] change_scene_to_file returned ms:", Time.get_ticks_msec())
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
	var game_state := get_node_or_null("/root/GameState")
	while game_state == null and attempts < max_attempts:
		await tree.process_frame
		attempts += 1
		game_state = get_node_or_null("/root/GameState")

	if game_state != null:
		print("[DeathDirector] GameState found after frames:", attempts)
		# Defensive call
		if game_state.has_method("load_save"):
			print("[DeathDirector] _apply_gamestate_after_scene_change -> calling GameState.load_save() after %d frames wait" % attempts)
			game_state.load_save()
			# The new Player may have restored before load_save() refreshed the
			# cached inventory. Restore once more with the freshly loaded data.
			var player = tree.root.find_child("Player", true, false)
			if player and game_state.has_method("restore_inventory_to_player"):
				game_state.restore_inventory_to_player(player)
				if player.has_method("refresh_equipped_weapon_from_inventory"):
					player.call_deferred("refresh_equipped_weapon_from_inventory")
			game_state.suppress_inventory_autosave = false
		else:
			print("[DeathDirector] _apply_gamestate_after_scene_change -> GameState exists but has no load_save()")
		return

	# Fallback: GameState never appeared in time — log and return.
	print("[DeathDirector] WARNING: /root/GameState missing after frames:", attempts)

func _on_fade_anim_finished(anim_name: String) -> void:
	if anim_name != "fade":
		return

	if _target_scene != "" and not _scene_change_started:
		await _do_scene_change()

	_transitioning = false
	_target_scene = ""
	anim.speed_scale = 1.0
	fade.visible = false
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _input(_event):
	if _transitioning:
		get_viewport().set_input_as_handled()

func set_pending_spawn_position(pos: Vector2):
	_pending_spawn_position = pos
	_use_custom_spawn = true
