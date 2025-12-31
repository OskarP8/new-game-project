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

	# 1. Pause the entire game
	get_tree().paused = true

	# 2. Allow THIS node to keep running
	process_mode = Node.PROCESS_MODE_ALWAYS

	# 3. Start fade / animation
	$AnimationPlayer.play("fade_to_black")

func start_death_sequence():
	fade.visible = true

	if anim.has_animation("fade_in"):
		anim.play("fade_in")
	else:
		# fallback if animation missing
		fade.color = Color(0, 0, 0, 1)
		_finish_death()

func _finish_death():
	# pause AFTER visuals finish
	get_tree().paused = true

	# show death menu here
	#var death_menu = preload("res://ui/DeathMenu.tscn").instantiate()
	#add_child(death_menu)
