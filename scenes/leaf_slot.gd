extends Node2D
class_name LeafSlot

signal became_empty(slot: LeafSlot)
signal became_alive(slot: LeafSlot)

enum LeafState { EMPTY, GROWING, ALIVE, DYING }
var state: LeafState = LeafState.EMPTY

@onready var sprite := $Leaf
@onready var anim := $AnimationPlayer

func _ready() -> void:
	if not anim.animation_finished.is_connected(_on_AnimationPlayer_animation_finished):
		anim.animation_finished.connect(_on_AnimationPlayer_animation_finished)

func _process(_delta):
	if state == LeafState.GROWING and anim.current_animation == "grow":
		if anim.current_animation_position > 0.05:
			sprite.visible = true

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
	sprite.visible = false
	sprite.modulate.a = 0.5
	print("[LeafSlot]", name, "🌱 start_growing")
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
			emit_signal("became_alive", self)

			if anim.has_animation("alive"):
				anim.play("alive")

		"die":
			print("[LeafSlot]", name, "☠ die finished → reset")
			_reset()

func _reset() -> void:
	state = LeafState.EMPTY
	sprite.visible = false
	sprite.modulate.a = 1.0
	print("[LeafSlot]", name, "🫥 reset → EMPTY")
	emit_signal("became_empty", self)
