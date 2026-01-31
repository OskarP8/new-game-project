# res://scripts/SaveData.gd
extends Resource
class_name SaveData

@export var scene_path: String = ""
@export var position: Vector2 = Vector2.ZERO
@export var saved_at_unix: int = 0

# persisted gameplay state
@export var inventory: Array = []        # player's equipment/quick inventory (Array of dicts)
@export var main_inventory: Array = []   # NEW: main backpack (Array of dicts)
@export var opened_chests: Array = []
