# res://scripts/SaveData.gd
extends Resource
class_name SaveData

@export var scene_path: String = ""
@export var position: Vector2 = Vector2.ZERO
@export var saved_at_unix: int = 0

# New: persisted gameplay state
@export var inventory: Array = []        # Array of dictionaries: { "scene_path": String, "amount": int }
@export var opened_chests: Array = []    # Array of Strings (unique chest IDs)
