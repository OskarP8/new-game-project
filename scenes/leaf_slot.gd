extends Node2D
class_name LeafSlot

signal became_empty(slot: LeafSlot)

enum LeafState { EMPTY, GROWING, ALIVE, DYING }
var state: LeafState = LeafState.EMPTY

@onready var sprite := $Leaf
@onready var anim := $AnimationPlayer

func _ready() -> void:
	var e := $Explosion
	e.emitting = false
	e.restart()   # <- THIS IS IMPORTANT
	var c := $Crack
	c.emitting = false
	c.restart()   # <- THIS IS IMPORTANT

	if not anim.animation_finished.is_connected(_on_AnimationPlayer_animation_finished):
		anim.animation_finished.connect(_on_AnimationPlayer_animation_finished)

func _state_name(s: int) -> String:
	return ["EMPTY", "GROWING", "ALIVE", "DYING"][s]

func set_alive() -> void:
	state = LeafState.ALIVE
	sprite.visible = true
	sprite.modulate.a = 1.0
	print("[LeafSlot]", name, "→ set_alive")
	if anim.has_animation("alive"):
		anim.play("alive")

func start_growing() -> void:
	if state != LeafState.EMPTY:
		print("[LeafSlot]", name, "❌ start_growing ignored, state =", _state_name(state))
		return

	state = LeafState.GROWING
	sprite.visible = true

	# 🔧 HARD RESET VISUAL STATE
	sprite.frame = 0                     # or first grow frame
	sprite.scale = Vector2.ONE           # if you animate scale
	sprite.modulate = Color(1, 1, 1, 0.5)

	print("[LeafSlot]", name, "🌱 start_growing")
	anim.stop()
	anim.play("grow")

func kill() -> void:
	if state != LeafState.ALIVE:
		print("[LeafSlot]", name, "❌ kill ignored, state =", _state_name(state))
		return

	state = LeafState.DYING
	print("[LeafSlot]", name, "💀 kill → playing 'die'")
	anim.play("die")

func _on_AnimationPlayer_animation_finished(anim_name: String) -> void:
	print("[LeafSlot]", name, "🎞 animation_finished:", anim_name)

	match anim_name:
		"grow":
			state = LeafState.ALIVE
			sprite.modulate.a = 1.0
			print("[LeafSlot]", name, "🌿 grown → ALIVE")
			if anim.has_animation("alive"):
				anim.play("alive")

		"die":
			print("[LeafSlot]", name, "☠ die finished → reset")
			_reset()

func _reset() -> void:
	state = LeafState.EMPTY

	anim.stop()

	sprite.visible = false
	sprite.modulate = Color(1, 1, 1, 1)
	sprite.frame = 0          # ⬅ VERY IMPORTANT

	print("[LeafSlot]", name, "🫥 reset → EMPTY")
