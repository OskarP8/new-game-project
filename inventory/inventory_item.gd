extends Resource
class_name InvItem

@export var id: String            # unique identifier, e.g. "potion_health"
@export var name: String          # display name, e.g. "Health Potion"
@export var icon: Texture2D       # item icon
@export var type: String = "misc" # "consumable", "weapon", "armor", etc.
@export var max_stack: int = 99   # how many can stack (1 for weapons/armor)
