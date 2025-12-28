extends Node2D
class_name LeafSlot

@onready var sprite := $Leaf
@onready var anim_player := $AnimationPlayer if has_node("AnimationPlayer") else null

enum LeafState { EMPTY, GROWING, ALIVE, DYING }
var state: LeafState = LeafState.EMPTY

func set_alive() -> void:
	state = LeafState.ALIVE
	sprite.visible = true
	sprite.modulate.a = 1.0
	sprite.play("idle")

func start_growing() -> void:
	if state != LeafState.EMPTY:
		return

	state = LeafState.GROWING
	sprite.visible = true
	sprite.modulate.a = 0.0
	sprite.play("grow")

	if anim_player and anim_player.has_animation("fade_in"):
		anim_player.play("fade_in")

func kill() -> void:
	if state != LeafState.ALIVE:
		return

	state = LeafState.DYING
	sprite.play("die")

func _on_AnimatedSprite2D_animation_finished() -> void:
	match sprite.animation:
		"grow":
			state = LeafState.ALIVE
			sprite.play("idle")

		"die":
			if anim_player and anim_player.has_animation("fade_out"):
				anim_player.play("fade_out")
			else:
				_reset()

func _on_AnimationPlayer_animation_finished(anim_name: String) -> void:
	if anim_name == "fade_out":
		_reset()

func _reset() -> void:
	state = LeafState.EMPTY
	sprite.visible = false
	sprite.modulate.a = 1.0
