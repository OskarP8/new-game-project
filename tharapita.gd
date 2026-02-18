extends Node2D
class_name TaaraNPC

signal wish_granted(player: Node)

# Basic NPC data
@export var npc_name := "Taara"
@export var greeting_lines := [
	"Who approaches the oak? Speak, child of the land.",
	"Prove your strength and I shall consider your wish."
]
@export var quest_ids := ["taara_slay_ironmen", "taara_slay_wraith", "taara_slay_troll"]

# Interaction / prompt (Chest-style)
@onready var prompt_scene := preload("res://scenes/interact_prompt.tscn")
var prompt: Node2D = null
@export var npc_id: String = ""  # optional stable id

# Area2D for proximity (must exist in the scene under this node)
@onready var area: Area2D = $InteractionArea if has_node("InteractionArea") else null

# runtime
var is_interacting: bool = false
var is_done: bool = false
var _current_player: Node = null

# dialog instance (cached) — expects a DialogBox at /root/DialogBox or similar
@onready var dlg := get_tree().root.get_node("DialogBox") if get_tree().root.has_node("DialogBox") else null

func _ready() -> void:
	# connect dialog
	if dlg:
		if not dlg.is_connected("line_finished", Callable(self, "_on_line_finished")):
			dlg.connect("line_finished", Callable(self, "_on_line_finished"))
		if not dlg.is_connected("dialog_complete", Callable(self, "_on_dialog_complete")):
			dlg.connect("dialog_complete", Callable(self, "_on_dialog_complete"))

	# connect area signals (proximity prompt) — handle both bodies and areas
	if area:
		if not area.is_connected("body_entered", Callable(self, "_on_area_body_entered")):
			area.body_entered.connect(Callable(self, "_on_area_body_entered"))
		if not area.is_connected("body_exited", Callable(self, "_on_area_body_exited")):
			area.body_exited.connect(Callable(self, "_on_area_body_exited"))

		# Also listen for other Area2D overlaps (the player's InteractionComponent is an Area2D)
		if not area.is_connected("area_entered", Callable(self, "_on_area_area_entered")):
			area.area_entered.connect(Callable(self, "_on_area_area_entered"))
		if not area.is_connected("area_exited", Callable(self, "_on_area_area_exited")):
			area.area_exited.connect(Callable(self, "_on_area_area_exited"))
	else:
		print("[Taara] Warning: InteractionArea Area2D not found. Add a child Area2D named 'InteractionArea' with CollisionShape2D.")

	_update_done_state()
	_debug_interaction_state()

func _update_done_state() -> void:
	# set is_done true if all quest_ids are completed
	if not Engine.has_singleton("QuestManager"):
		is_done = false
		return
	for qid in quest_ids:
		var q := QuestManager.get_quest(qid)
		if q == null:
			is_done = false
			return
		if not ("state" in q) or q.state != "completed":
			is_done = false
			return
	is_done = true

# Called by InteractionComponent / player controller when the player chooses to interact
func interact(player: Node2D) -> void:
	print("[Taara] interact requested by:", player.name if player and "name" in player else player)

	if player == null:
		print("[Taara] ⚠ No player supplied to interact()")
		return

	_update_done_state()

	# if all quests done, run wish flow
	if is_done:
		_perform_wish_flow(player)
		return

	# ignore duplicates
	if is_interacting:
		print("[Taara] ⚠ Already interacting; ignoring duplicate")
		return

	if dlg == null:
		print("[Taara] ⚠ DialogBox not found in root — cannot show dialog")
		return

	# Build dialog
	var lines: Array = []
	lines.append("[b]" + npc_name + "[/b]")
	for l in greeting_lines:
		lines.append(l)

	for qid in quest_ids:
		var q = null
		if Engine.has_singleton("QuestManager"):
			q = QuestManager.get_quest(qid)
		if q and ("state" in q) and q.state == "available":
			lines.append("I ask you to: " + q.title)
		elif q and ("state" in q) and q.state == "active":
			lines.append("You are working on: " + q.title)

	is_interacting = true
	_show_prompt(false)  # hide prompt while dialog visible
	dlg.show_dialog(lines, npc_name, "pop")

func _on_line_finished() -> void:
	# placeholder for sound or per-line effects
	pass

func _on_dialog_complete() -> void:
	# after dialog finishes, offer first available quest automatically
	for qid in quest_ids:
		var q = null
		if Engine.has_singleton("QuestManager"):
			q = QuestManager.get_quest(qid)
		if q and ("state" in q) and q.state == "available":
			QuestManager.accept_quest(qid)
			if dlg:
				dlg.show_dialog(["You accepted: " + q.title], npc_name, "slide_up")
			is_interacting = false
			_show_prompt(true)
			return

	# none to offer — re-check done
	_update_done_state()
	if is_done:
		_perform_wish_flow(null)
	else:
		is_interacting = false
		_show_prompt(true)

func _perform_wish_flow(player: Node) -> void:
	print("[Taara] You proved worthy. Granting wish now.")
	if dlg:
		dlg.show_dialog(["You have proven yourself. Speak your wish."], npc_name, "slide_up")
	emit_signal("wish_granted", player)
	is_done = true
	_show_prompt(false)

# ----- Area2D handlers (connect these) -----
# When a PhysicsBody2D (CharacterBody2D) enters
func _on_area_body_entered(body: Node) -> void:
	if body == null:
		return
	print("[Taara] Area body_entered:", body.name if "name" in body else body)
	# accept either "player" or "Player"
	if body is Node and (body.is_in_group("player") or body.is_in_group("Player")):
		_current_player = body
		# prefer to use the player's InteractionComponent methods (if present)
		var interactor = body.find_child("InteractionComponent", true, false)
		if interactor:
			# prefer the InteractArea's update method (safe)
			if interactor.has_method("_update_prompt"):
				interactor._update_prompt()
				return
			if interactor.has_method("show_prompt_for"):
				interactor.show_prompt_for(self)
				return
			if interactor.has_method("show_prompt"):
				interactor.show_prompt(self)
				return
		# fallback to our own prompt if no interactor or no matching method
		_show_prompt(true)

func _on_area_body_exited(body: Node) -> void:
	if body == null:
		return
	print("[Taara] Area body_exited:", body.name if "name" in body else body)
	if body is Node and (body.is_in_group("player") or body.is_in_group("Player")):
		var interactor = body.find_child("InteractionComponent", true, false)
		if interactor:
			if interactor.has_method("_update_prompt"):
				interactor._update_prompt()
			elif interactor.has_method("hide_prompt_for"):
				interactor.hide_prompt_for(self)
			elif interactor.has_method("hide_prompt"):
				interactor.hide_prompt(self)
		else:
			_show_prompt(false)
		_current_player = null

# When another Area2D overlaps (this is the player's InteractionComponent case)
func _on_area_area_entered(a: Area2D) -> void:
	if a == null:
		return
	print("[Taara] Area area_entered:", a.name if "name" in a else a, "class:", a.get_class())
	# If the overlapping area *is* the InteractionComponent (or provides the same interface), use it directly
	if a.has_method("_update_prompt") or a.has_method("show_prompt_for") or a.has_method("show_prompt"):
		# try to find owning player body by walking up parents
		var owner_player := _find_owner_player_from_node(a)
		if owner_player:
			_current_player = owner_player
			# call the interactor methods if available (prefer the safe _update_prompt)
			if a.has_method("_update_prompt"):
				a._update_prompt()
				return
			if a.has_method("show_prompt_for"):
				a.show_prompt_for(self)
				return
			if a.has_method("show_prompt"):
				a.show_prompt()
				return
			# If area itself doesn't show prompt, try the player's InteractionComponent on player node (fallback)
			var interactor = owner_player.find_child("InteractionComponent", true, false)
			if interactor:
				if interactor.has_method("_update_prompt"):
					interactor._update_prompt()
					return
				if interactor.has_method("show_prompt_for"):
					interactor.show_prompt_for(self)
					return
	# If not recognized as an interactor area, attempt to treat it like a body overlap (search up for player)
	var p = _find_owner_player_from_node(a)
	if p:
		_on_area_body_entered(p)

func _on_area_area_exited(a: Area2D) -> void:
	if a == null:
		return
	print("[Taara] Area area_exited:", a.name if "name" in a else a, "class:", a.get_class())
	# if the area was the InteractionComponent, try to hide via its methods or the player's interactor
	if a.has_method("hide_prompt") or a.has_method("hide_prompt_for") or a.has_method("_update_prompt"):
		var owner_player := _find_owner_player_from_node(a)
		if owner_player:
			var interactor = a
			# call area hide if it has it
			if a.has_method("hide_prompt"):
				a.hide_prompt()
				_current_player = null
				return
			if a.has_method("hide_prompt_for"):
				a.hide_prompt_for(self)
				_current_player = null
				return
			# fallback to player's InteractionComponent
			var ip = owner_player.find_child("InteractionComponent", true, false)
			if ip:
				if ip.has_method("hide_prompt_for"):
					ip.hide_prompt_for(self)
					_current_player = null
					return
				if ip.has_method("hide_prompt"):
					ip.hide_prompt()
					_current_player = null
					return
	# otherwise, try to detect player parent and forward to body_exited
	var p = _find_owner_player_from_node(a)
	if p:
		_on_area_body_exited(p)

# helper: walk up parent chain to find a node in "Player" or "player" group
func _find_owner_player_from_node(node: Node) -> Node:
	if node == null:
		return null
	var p := node
	while p:
		if p.is_in_group("Player") or p.is_in_group("player"):
			return p
		p = p.get_parent()
	return null

# show/hide prompt local fallback (same pattern as Chest)
func _show_prompt(visible: bool) -> void:
	if visible:
		# lazy instantiate
		if prompt == null and prompt_scene:
			prompt = prompt_scene.instantiate()
			get_tree().current_scene.add_child(prompt)
			if prompt.has_method("attach_to_target"):
				prompt.attach_to_target(self)
		if prompt:
			if prompt.has_method("show_prompt"):
				prompt.show_prompt()
			else:
				prompt.visible = true
	else:
		if prompt:
			if prompt.has_method("hide_prompt"):
				prompt.hide_prompt()
			else:
				prompt.visible = false

func _make_npc_id() -> String:
	if npc_id != "":
		return npc_id
	var scene_path := get_tree().current_scene.scene_file_path if get_tree().current_scene else ""
	return "%s::%s" % [scene_path, str(global_position)]

# DEBUG helper: prints Area2D / CollisionShape / layer/mask status so we can see why signals don't occur
func _debug_interaction_state() -> void:
	print("---- Taara DEBUG START ----")
	print("Taara node:", self.name, "global_pos:", global_position)
	# area variable (onready) may be null if node path differs
	print("area (onready) is null?:", area == null)
	if has_node("InteractionArea"):
		var a = $InteractionArea
		print(" InteractionArea node exists (path $InteractionArea). monitoring:", a.monitoring, " monitorable:", a.monitorable)
		print("  collision_layer:", a.collision_layer, " collision_mask:", a.collision_mask)
		# list children of area
		print("  InteractionArea children count:", a.get_child_count())
		for i in range(a.get_child_count()):
			var ch = a.get_child(i)
			print("   child:", i, ch.name, "class:", ch.get_class())
			if ch is CollisionShape2D:
				print("    CollisionShape2D disabled?:", ch.disabled, " shape class:", (ch.shape.get_class() if ch.shape else "null"))
				# if Circle/Rect, print extents/radius where possible
				if ch.shape is CircleShape2D:
					print("     Circle radius:", ch.shape.radius)
				elif ch.shape is RectangleShape2D:
					print("     Rect extents:", ch.shape.extents)
	else:
		print(" No node named InteractionArea found as direct child. Listing children of Taara:")
		for i in range(get_child_count()):
			var c = get_child(i)
			print("  child:", i, c.name, "class:", c.get_class())

	# check if area variable resolved to something else (maybe named differently)
	if area != null:
		print(" onready 'area' resolved to node:", area.name, "path:", area.get_path())
	# print collision layers of Taara root node (if it has collision nodes)
	if has_node("CollisionShape2D"):
		print("Taara has CollisionShape2D as direct child and it's present")
	# print Player group membership (best-effort)
	var players := get_tree().get_nodes_in_group("Player") + get_tree().get_nodes_in_group("player")
	print("Players found by groups: Player count:", get_tree().get_nodes_in_group("Player").size(), " player count:", get_tree().get_nodes_in_group("player").size(), " total detect:", players.size())
	for p in players:
		print("  - player node:", p.name, "pos:", p.global_position)
	print("---- Taara DEBUG END ----")
