extends CanvasLayer

@onready var resume_button := $VBoxContainer/Resume  # adjust path if needed

func _ready():
	Engine.time_scale = 1.0

	# Ensure GameState autoload exists, then load any on-disk save
	if has_node("/root/GameState"):
		# call via get_node to avoid runtime errors if autoload name changes
		var gs = get_node("/root/GameState")
		if gs and gs.has_method("load_save"):
			gs.load_save()

		# Now check for save presence (safe because we have gs)
		if not gs.has_save():
			resume_button.visible = false
			resume_button.disabled = true
	else:
		# No GameState autoload — hide resume (safe fallback)
		resume_button.visible = false
		resume_button.disabled = true
		push_warning("[StartScreen] /root/GameState not found; resume disabled")

func _on_start_pressed() -> void:
	print("NEW GAME pressed")

	if has_node("/root/GameState"):
		var gs = get_node("/root/GameState")
		# reset canonical save to fresh start (writes start scene)
		if gs.has_method("reset_save"):
			gs.reset_save("res://scenes/world.tscn")
		# clear runtime caches consistently
		gs.checkpoint_scene = ""
		gs.checkpoint_position = Vector2.ZERO
		gs.saved_scene = ""
		gs.saved_position = Vector2.ZERO
		gs.opened_chests = []
		gs.saved_inventory = []
		gs.saved_main_inventory = []
	else:
		push_warning("[StartScreen] New Game: GameState not found; proceeding without clearing save")

	# Transition to gameplay scene (prefer DeathDirector fade if present)
	var dd := get_tree().get_first_node_in_group("DeathDirector")
	if dd:
		dd.fade_to_scene("res://scenes/world.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/world.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()

func _on_resume_pressed() -> void:
	print("CONTINUE pressed")

	if not has_node("/root/GameState"):
		push_warning("[StartScreen] No GameState autoload found; cannot resume")
		return

	var gs = get_node("/root/GameState")
	# ensure we read the latest on-disk save
	if gs.has_method("load_save"):
		if not gs.load_save():
			print("[StartScreen] load_save() returned false; no valid save found")
			return

	# final has_save() check
	if not gs.has_save():
		print("[StartScreen] No save present; ignoring Continue")
		return

	# get the saved data (GameState.get_save_data returns {"scene","position"})
	var data = gs.get_save_data()
	var scene_path := str(data.get("scene", ""))
	var pos: Vector2 = Vector2.ZERO

	# defensively parse position variants
	var raw_pos = data.get("position", Vector2.ZERO)
	if typeof(raw_pos) == TYPE_VECTOR2:
		pos = raw_pos
	elif typeof(raw_pos) == TYPE_DICTIONARY:
		pos = Vector2(raw_pos.get("x", 0.0), raw_pos.get("y", 0.0))
	else:
		pos = Vector2.ZERO

	if scene_path == "":
		push_error("[StartScreen] Resume: saved scene is empty")
		return

	var dd := get_tree().get_first_node_in_group("DeathDirector")
	if dd:
		# use DeathDirector to fade + apply pending spawn pos
		dd.fade_to_scene(scene_path)
		if dd.has_method("set_pending_spawn_position"):
			dd.set_pending_spawn_position(pos)
		else:
			push_error("[StartScreen] DeathDirector missing set_pending_spawn_position — saved position may not be applied")
	else:
		# fallback: change scene and then apply saved position + restore inventories
		var err = get_tree().change_scene_to_file(scene_path)
		if err != OK:
			push_error("[StartScreen] change_scene_to_file failed: %s" % str(err))
			return

		# wait a couple frames so new scene _ready() runs
		await get_tree().process_frame
		await get_tree().process_frame

		# find player and apply saved position + restore inventories
		var player = get_tree().root.find_child("Player", true, false)
		if player:
			player.global_position = pos
			print("[StartScreen] Applied saved player position:", pos)

			# restore player inventory if GameState offers helper
			if gs.has_method("restore_inventory_to_player"):
				gs.restore_inventory_to_player(player)
				print("[StartScreen] restore_inventory_to_player() called")

			if player.has_method("refresh_equipped_weapon_from_inventory"):
				player.call_deferred("refresh_equipped_weapon_from_inventory")
		else:
			push_warning("[StartScreen] Could not find Player node after scene load; saved position not applied")

		# restore main backpack UI (if present)
		if gs.has_method("restore_main_inventory_to_ui"):
			gs.restore_main_inventory_to_ui()
			print("[StartScreen] restore_main_inventory_to_ui() called")
