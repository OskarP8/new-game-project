extends Camera2D

func _ready():
	enabled = true
	add_to_group("Camera")
	print("[CAM TEST] Camera ready")

func _process(delta):
	# FORCE visible movement every frame
	offset = Vector2(30, 0)
