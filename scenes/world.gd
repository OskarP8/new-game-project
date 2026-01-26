extends Node

@export var visual_blocker_layer_path: NodePath  # the TileMapLayer (Y-sorted) that contains tree/obstacle tiles
@export var obstacle_parent_path: NodePath = NodePath("") # optional parent to hold created obstacles; defaults to auto-created NavObstacles
@export var tile_size: Vector2 = Vector2(16, 16) # your tile size (16x16)
@export var source_id: int = 1 # your tiles are stored under source id 1
@export var radius_scale: float = 0.95 # scale the circle so it covers cluster (tweak if agents still slip through)

func _ready() -> void:
	print("[NavDebug] ClusterSpawner starting")
	if not visual_blocker_layer_path or visual_blocker_layer_path == NodePath(""):
		print("[NavDebug] ERROR: visual_blocker_layer_path not set")
		return
	if not has_node(visual_blocker_layer_path):
		print("[NavDebug] ERROR: visual_blocker_layer_path not found:", visual_blocker_layer_path)
		return

	var visual_layer: Node = get_node(visual_blocker_layer_path)

	# prepare parent for obstacles: prefer explicit path, else create/attach a NavObstacles Node2D sibling
	var parent_node: Node = null
	if obstacle_parent_path and obstacle_parent_path != NodePath("") and has_node(obstacle_parent_path):
		parent_node = get_node(obstacle_parent_path)
	else:
		# create or find a NavObstacles child under the same parent as visual_layer
		var world_parent := get_tree().current_scene if get_tree().current_scene else get_tree().get_root()
		var nav_parent_name := "NavObstacles"
		# try to find sibling under the scene root
		if world_parent.has_node(nav_parent_name):
			parent_node = world_parent.get_node(nav_parent_name)
		else:
			parent_node = Node2D.new()
			parent_node.name = nav_parent_name
			world_parent.add_child(parent_node)
			parent_node.owner = get_tree().current_scene
			print("[NavDebug] created NavObstacles node at root for spawned obstacles")

	# collect used cells for the configured source id
	var used_cells_raw: Array = []
	if visual_layer.has_method("get_used_cells_by_id"):
		used_cells_raw = visual_layer.get_used_cells_by_id(source_id)
	else:
		if visual_layer.has_method("get_used_cells"):
			used_cells_raw = visual_layer.get_used_cells()
	print("[NavDebug] found used_cells_raw count:", used_cells_raw.size())

	if used_cells_raw.size() == 0:
		print("[NavDebug] no used tiles found; nothing to spawn")
		return

	# assume each returned cell is already Vector2i; normalize to Vector2i list
	var used_cells: Array = []
	for cell in used_cells_raw:
		used_cells.append(Vector2i(int(cell.x), int(cell.y)))

	# build set for fast lookup and flood-fill connected components (4-neighbour)
	var used_set: Dictionary = {}
	for cell in used_cells:
		used_set[cell] = true

	var visited: Dictionary = {}
	var components: Array = []

	for cell in used_cells:
		if cell in visited:
			continue
		var comp := _flood_fill_component(cell, used_set, visited)
		if comp.size() > 0:
			components.append(comp)

	print("[NavDebug] components found:", components.size())

	# spawn circle obstacle per component
	for comp in components:
		# compute bounding box AND centroid in tile coordinates
		var min_x := 1000000000
		var min_y := 1000000000
		var max_x := -1000000000
		var max_y := -1000000000
		var sum_x := 0.0
		var sum_y := 0.0
		for c in comp:
			var cx := int(c.x)
			var cy := int(c.y)
			if cx < min_x:
				min_x = cx
			if cy < min_y:
				min_y = cy
			if cx > max_x:
				max_x = cx
			if cy > max_y:
				max_y = cy
			# add tile center in tile-space (cell + 0.5)
			sum_x += (cx + 0.5)
			sum_y += (cy + 0.5)

		var count_tiles = comp.size()
		var avg_tile_x := sum_x / float(count_tiles)
		var avg_tile_y := sum_y / float(count_tiles)

		# convert average tile-center to world once (uses layer cell_size)
		var cs: Vector2 = tile_size
		if "cell_size" in visual_layer:
			cs = visual_layer.cell_size
		var center_world := (visual_layer as Node2D).to_global(Vector2(avg_tile_x * cs.x, avg_tile_y * cs.y))

		# radius: half of diagonal of bounding box in world units * scale
		var width_tiles := max_x - min_x + 1
		var height_tiles := max_y - min_y + 1
		var diag_world := sqrt(pow(width_tiles * cs.x, 2) + pow(height_tiles * cs.y, 2))
		var radius := (diag_world * 0.5) * radius_scale

		# ensure a minimum radius (half a tile)
		var min_radius := cs.x * 0.5
		if radius < min_radius:
			radius = min_radius

		print("[NavDebug] component size (tiles):", width_tiles, "x", height_tiles, "centroid (world):", center_world, "radius:", radius)
		_spawn_circular_obstacle(center_world, radius, parent_node)

	print("[NavDebug] ClusterSpawner done")

# ---------------- helpers ----------------

func _flood_fill_component(start_cell: Vector2i, used_set: Dictionary, visited: Dictionary) -> Array:
	var queue: Array = [start_cell]
	var comp: Array = []

	while queue.size() > 0:
		var cur: Vector2i = queue.pop_front()
		if cur in visited:
			continue
		visited[cur] = true
		if not (cur in used_set):
			continue

		comp.append(Vector2i(cur.x, cur.y))

		var neigh := [
			Vector2i(1,0),
			Vector2i(-1,0),
			Vector2i(0,1),
			Vector2i(0,-1)
		]
		for off in neigh:
			var ncell := Vector2i(cur.x + off.x, cur.y + off.y)
			if ncell in used_set and not (ncell in visited):
				queue.append(ncell)

	return comp

func _spawn_circular_obstacle(world_pos: Vector2, radius: float, parent_node: Node) -> void:
	var obs := NavigationObstacle2D.new()
	# position relative to parent_node if Node2D (obs.position is center)
	if parent_node is Node2D:
		obs.position = parent_node.to_local(world_pos)
	else:
		obs.position = world_pos

	# create CollisionShape2D with CircleShape2D
	var shape := CollisionShape2D.new()
	var circ := CircleShape2D.new()
	circ.radius = radius
	shape.shape = circ
	shape.position = Vector2.ZERO
	obs.add_child(shape)

	# attempt common carving flags (guarded)
	if "carve_navigation_mesh" in obs:
		obs.set("carve_navigation_mesh", true)
	if "affect_navigation_mesh" in obs:
		obs.set("affect_navigation_mesh", true)
	if "affect_navigation" in obs:
		obs.set("affect_navigation", true)

	# add to scene, set owner so it persists in tree properly
	parent_node.add_child(obs)
	obs.owner = get_tree().current_scene
	# defer enabling to next idle/frame to avoid earlier assignment errors and give engine a tick to register
	if obs.has_method("set_deferred"):
		obs.set_deferred("enabled", true)
	else:
		if "enabled" in obs:
			obs.set("enabled", true)

	print("[NavDebug] spawned circular obstacle at", world_pos, "radius:", radius, "parent:", parent_node.name)
