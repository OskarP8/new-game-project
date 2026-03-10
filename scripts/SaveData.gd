# res://scripts/SaveData.gd
extends Resource
class_name SaveData

@export var scene_path: String = ""
@export var position: Vector2 = Vector2.ZERO
@export var saved_at_unix: int = 0

# New: persisted gameplay state
@export var inventory: Array = []        # Array of dictionaries: { "scene_path": String, "amount": int }
@export var opened_chests: Array = []    # Array of Strings (unique chest IDs)
@export var saved_quests: Dictionary = {}  # { "states": {quest_id: state}, "kill_progress": {quest_id: count} }
# SaveData.gd (add these exports near the top of the resource)
@export var intro_shown: bool = false
@export var greeted_npcs: Dictionary = {} # maps npc_id -> true
