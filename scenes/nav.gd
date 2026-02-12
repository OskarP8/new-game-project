extends TileMapLayer

@onready var objects = $"../Y-Sort/Objects"

func _use_tile_data_runtime_update(coords):
	if coords in objects.get_used_cells_by_id(0):
		return true
	if coords in objects.get_used_cells_by_id(1):
		return true
	return false

func _tile_data_runtime_update(coords, tile_data):
	tile_data.set_navigation_polygon(0, null)
