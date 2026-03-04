extends Resource
class_name Quest

@export_category("Quest")

@export var id: String = ""
@export var title: String = ""
@export var description: Array[String] = []
# possible states: "available", "active", "completed", "failed"
@export var state: String = "available"
@export var objective: Dictionary = {
	"type": "kill",
	"target": "",
	"count": 1
}
@export var reward: Dictionary = {}

func is_active() -> bool:
	return state == "active"

func is_completed() -> bool:
	return state == "completed"
