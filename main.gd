extends Node2D

# ── constants ────────────────────────────────────────────────────────────────
const NODE_RADIUS     = 55
const ATTACK_INTERVAL = 0.9
const UNIT_HP         = 12
const ATTACK_DMG      = 2
const AI_INTERVAL     = 3.5
const S               = 2.2
const PLAYER_RACE     = "human"
const AI_RACE         = "orc"
const NEUTRAL_RACE    = "neutral_unit"

const MOVE_PX_SOLDIER    = 90.0
const MOVE_SPEED         = MOVE_PX_SOLDIER
const VISION_RADIUS      = 220.0
const ALERT_RADIUS       = 120.0
const ENGAGE_RADIUS      = 60.0
const MELEE_RANGE        = 22.0
const UNIT_RADIUS        = 10.0
const UNIT_SPACING       = 32.0
const ROAD_HIT_WIDTH     = 30.0
const CAPTURE_TIME    = 15.0
const CAPTURE_REVERSE = 7.5
const CAPTURE_VISION  = 280.0

const FOG_HIDDEN   = 0
const FOG_EXPLORED = 1
const FOG_VISIBLE  = 2

const FOG_CELL = 32
var fog_grid: Dictionary = {}

# ── world data ───────────────────────────────────────────────────────────────
var game_nodes: Array     = []
var connections: Array    = []
var units: Array          = []
var squads: Array         = []
var selected_squads: Array = []
var hovered_road: Array   = []   # [] or [conn_idx_a, conn_idx_b]
var selecting             = false
var selection_start       = Vector2.ZERO
var selection_rect        = Rect2()
var ai_timer              = 0.0
var time_elapsed          = 0.0
var next_squad_id         = 0

var road_decor: Array = []
var cam: Camera2D

const WORLD_W = 3200.0
const WORLD_H = 2400.0

# ── ready ─────────────────────────────────────────────────────────────────────
func _ready():
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	await get_tree().process_frame
	var v = get_viewport_rect().size
	_generate_nodes()
	_generate_connections()
	_generate_road_decor()
	_init_fog()
	_spawn_starting_units()
	_setup_camera(v)
	queue_redraw()

func _setup_camera(_viewport: Vector2):
	cam = Camera2D.new()
	add_child(cam)
	cam.zoom = Vector2(2.2, 2.2)
	cam.position = game_nodes[0].pos if game_nodes.size() > 0 else Vector2(WORLD_W * 0.5, WORLD_H * 0.5)
	cam.enabled = true

# ── node generation ───────────────────────────────────────────────────────────
func _generate_nodes():
	var margin = 350.0
	var used: Array = []
	_place_node(Vector2(randf_range(margin, WORLD_W * 0.25), randf_range(margin, WORLD_H - margin)),
		"Fortaleza", PLAYER_RACE, used)
	for label in ["Paso Norte", "Cruce", "Torre Vigía", "Aldea"]:
		var p: Vector2
		var tries = 0
		while tries < 200:
			p = Vector2(randf_range(margin, WORLD_W - margin), randf_range(margin, WORLD_H - margin))
			if _far_from_all(p, used, 500.0): break
			tries += 1
		_place_node(p, label, "neutral", used)
	_place_node(Vector2(randf_range(WORLD_W * 0.75, WORLD_W - margin), randf_range(margin, WORLD_H - margin)),
		"Guarida", AI_RACE, used)
	for n in game_nodes:
		if n.owner == "neutral":
			_generate_clearing(n)

func _place_node(pos: Vector2, label: String, owner_race: String, used: Array):
	game_nodes.append({
		"pos": pos, "label": label, "owner": owner_race,
		"capture_owner":    owner_race,
		"capture_progress": 1.0 if owner_race != "neutral" else 0.0,
		"capturing_race":   owner_race,
		"flag_wave":        randf() * TAU,
		"clearing_type":   "",
		"clearing_seed":   randi(),
		"clearing_decor":  [],
		"clearing_poly":   PackedVector2Array(),
	})
	used.append(pos)

func _far_from_all(p: Vector2, used: Array, min_dist: float) -> bool:
	for u in used:
		if p.distance_to(u) < min_dist: return false
	return true

func _generate_clearing(node: Dictionary):
	var rng = RandomNumberGenerator.new()
	rng.seed = node.clearing_seed

	var cx = node.pos.x / WORLD_W
	var cy = node.pos.y / WORLD_H

	var river_already = false
	for other in game_nodes:
		if other == node: continue
		if other.clearing_type == "river_crossing":
			river_already = true
			break

	var weights = {"forest_camp": 3, "river_crossing": 2, "ruins": 2, "open_field": 1}
	if river_already:
		weights["river_crossing"] = 0
	var is_central = cx > 0.3 and cx < 0.7 and cy > 0.3 and cy < 0.7
	if is_central:
		weights["ruins"] = 4

	var pool: Array = []
	for t in weights:
		for _i in range(weights[t]):
			pool.append(t)
	node.clearing_type = pool[rng.randi() % pool.size()]

	var num_pts = 14
	var base_r  = 110.0
	var poly    = PackedVector2Array()
	for i in range(num_pts):
		var angle = float(i) / float(num_pts) * TAU
		var r = base_r + sin(angle * 3.0 + rng.randf() * TAU) * 22.0 \
					   + sin(angle * 5.0 + rng.randf() * TAU) * 12.0
		poly.append(node.pos + Vector2(cos(angle), sin(angle)) * r)
	node.clearing_poly = poly

	match node.clearing_type:
		"forest_camp":
			node.clearing_decor.append({"type": "campfire", "pos": node.pos, "seed": rng.randi()})
			var tent_count = rng.randi_range(2, 3)
			for _i in range(tent_count):
				var a = rng.randf() * TAU
				var r = rng.randf_range(45.0, 80.0)
				node.clearing_decor.append({"type": "tent",
					"pos": node.pos + Vector2(cos(a), sin(a)) * r,
					"seed": rng.randi()})
			for _i in range(4):
				var a = rng.randf() * TAU
				var r = rng.randf_range(85.0, 120.0)
				node.clearing_decor.append({"type": "tree",
					"pos": node.pos + Vector2(cos(a), sin(a)) * r,
					"seed": rng.randi()})

		"river_crossing":
			var river_angle = rng.randf() * TAU
			var perp = Vector2(cos(river_angle), sin(river_angle))
			node.clearing_decor.append({"type": "river",
				"pos": node.pos, "seed": rng.randi(), "dir": perp})
			for _i in range(6):
				var t = rng.randf_range(-90.0, 90.0)
				var side = 1 if rng.randi() % 2 == 0 else -1
				var reed_pos = node.pos + perp * t + perp.rotated(PI * 0.5) * (18.0 * side + rng.randf_range(-6, 6))
				node.clearing_decor.append({"type": "reed",
					"pos": reed_pos, "seed": rng.randi()})
			if rng.randf() > 0.45:
				node.clearing_decor.append({"type": "bridge",
					"pos": node.pos, "seed": rng.randi(), "dir": perp})

		"ruins":
			var col_count = rng.randi_range(4, 6)
			for _i in range(col_count):
				var a = rng.randf() * TAU
				var r = rng.randf_range(30.0, 85.0)
				node.clearing_decor.append({"type": "column",
					"pos": node.pos + Vector2(cos(a), sin(a)) * r,
					"seed": rng.randi()})
			node.clearing_decor.append({"type": "arch",
				"pos": node.pos + Vector2(rng.randf_range(-30, 30), rng.randf_range(-30, 30)),
				"seed": rng.randi()})
			for _i in range(3):
				var a = rng.randf() * TAU
				var r = rng.randf_range(20.0, 70.0)
				node.clearing_decor.append({"type": "bush",
					"pos": node.pos + Vector2(cos(a), sin(a)) * r,
					"seed": rng.randi()})

		"open_field":
			var rock_count = rng.randi_range(3, 5)
			for _i in range(rock_count):
				var a = rng.randf() * TAU
				var r = rng.randf_range(30.0, 100.0)
				node.clearing_decor.append({"type": "rock",
					"pos": node.pos + Vector2(cos(a), sin(a)) * r,
					"seed": rng.randi()})

func _generate_connections():
	var n = game_nodes.size()
	var connected: Array = [0]
	var remaining: Array = range(1, n)
	while remaining.size() > 0:
		var best_pair = [0, remaining[0]]
		var best_d = INF
		for c in connected:
			for r in remaining:
				var d = game_nodes[c].pos.distance_to(game_nodes[r].pos)
				if d < best_d:
					best_d = d
					best_pair = [c, r]
		connections.append(best_pair)
		connected.append(best_pair[1])
		remaining.erase(best_pair[1])
	for _i in range(2):
		var a = randi() % n
		var b = randi() % n
		if a != b and not _has_connection(a, b):
			connections.append([a, b])

func _has_connection(a: int, b: int) -> bool:
	for c in connections:
		if (c[0] == a and c[1] == b) or (c[0] == b and c[1] == a): return true
	return false

func _generate_road_decor():
	for conn in connections:
		var a = game_nodes[conn[0]].pos
		var b = game_nodes[conn[1]].pos
		var dist = a.distance_to(b)
		var steps = int(dist / 120.0)
		for i in range(1, steps):
			var t = float(i) / float(steps)
			var mid = a.lerp(b, t)
			var perp = (b - a).normalized().rotated(PI * 0.5)
			var pos = mid + perp * randf_range(-110, 110)
			var types = ["tree", "tree", "tree", "rock", "bush", "rock_cluster"]
			road_decor.append({"pos": pos, "type": types[randi() % types.size()], "seed": randi()})

# ── fog ───────────────────────────────────────────────────────────────────────
func _init_fog():
	var cols = int(ceil(WORLD_W / FOG_CELL)) + 1
	var rows = int(ceil(WORLD_H / FOG_CELL)) + 1
	for gy in range(rows):
		for gx in range(cols):
			fog_grid[Vector2i(gx, gy)] = FOG_HIDDEN

func _update_fog():
	var cols = int(ceil(WORLD_W / FOG_CELL)) + 1
	var rows = int(ceil(WORLD_H / FOG_CELL)) + 1
	for gy in range(rows):
		for gx in range(cols):
			var key = Vector2i(gx, gy)
			if fog_grid.get(key, FOG_HIDDEN) == FOG_VISIBLE:
				fog_grid[key] = FOG_EXPLORED

	for u in units:
		if u.race == PLAYER_RACE and u.state != "dead":
			_reveal_fog_circle(u.pos, VISION_RADIUS)

	for n in game_nodes:
		if n.capture_owner == PLAYER_RACE:
			_reveal_fog_circle(n.pos, CAPTURE_VISION)

func _reveal_fog_circle(center: Vector2, radius: float):
	var r = int(ceil(radius / FOG_CELL)) + 1
	var cell = Vector2i(int(center.x / FOG_CELL), int(center.y / FOG_CELL))
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var key = Vector2i(cell.x + dx, cell.y + dy)
			if fog_grid.has(key):
				var world_pos = Vector2((key.x + 0.5) * FOG_CELL, (key.y + 0.5) * FOG_CELL)
				if center.distance_to(world_pos) <= radius:
					fog_grid[key] = FOG_VISIBLE

func _fog_at(pos: Vector2) -> int:
	var key = Vector2i(int(pos.x / FOG_CELL), int(pos.y / FOG_CELL))
	return fog_grid.get(key, FOG_HIDDEN)

# ── squads & units ────────────────────────────────────────────────────────────
func _make_squad(home_node: Dictionary, race: String) -> Dictionary:
	var sq = {
		"id":           next_squad_id,
		"units":        [],
		"home":         home_node,
		"race":         race,
		"state":        "idle",
		"path":         [],
		"target_node":  null,
		"final_node":   null,
		"selected":     false,
		"alert_flash":  0.0,
	}
	next_squad_id += 1
	squads.append(sq)
	return sq

func _spawn_starting_units():
	var sq_human = _make_squad(game_nodes[0], PLAYER_RACE)
	for _i in range(5):
		_spawn_unit(game_nodes[0], PLAYER_RACE, sq_human)
	var last = game_nodes.size() - 1
	var sq_orc = _make_squad(game_nodes[last], AI_RACE)
	for _i in range(5):
		_spawn_unit(game_nodes[last], AI_RACE, sq_orc)
	_spawn_clearing_guards()

func _spawn_clearing_guards():
	for n in game_nodes:
		if n.clearing_type == "": continue
		var rng = RandomNumberGenerator.new()
		rng.seed = n.clearing_seed ^ 0xDEADBEEF
		var count = rng.randi_range(2, 4)
		var sq = _make_squad_neutral(n.pos)
		sq.home = n
		for _i in range(count):
			var a = rng.randf() * TAU
			var r = rng.randf_range(20.0, 70.0)
			var guard_pos = n.pos + Vector2(cos(a), sin(a)) * r
			var u = {
				"pos": _find_free_position(guard_pos, units),
				"home": n, "race": NEUTRAL_RACE, "squad": sq,
				"hp": UNIT_HP, "max_hp": UNIT_HP,
				"state": "idle",
				"target_node": null, "from_pos": Vector2.ZERO, "move_progress": 0.0,
				"move_dest": Vector2.ZERO,
				"formation_offset": Vector2.ZERO,
				"path": [],
				"attack_timer": rng.randf() * ATTACK_INTERVAL,
				"combat_target": null,
				"approach_target": null,
				"engage_pos": Vector2.ZERO,
				"engaged_by": [],
				"selected": false,
				"hit_flash": 0.0, "death_alpha": 1.0,
				"idle_offset": rng.randf() * TAU,
			}
			sq.units.append(u)
			units.append(u)

func _make_squad_neutral(center: Vector2) -> Dictionary:
	var sq = {
		"id":           next_squad_id,
		"units":        [],
		"home":         null,
		"race":         NEUTRAL_RACE,
		"state":        "idle",
		"path":         [],
		"target_node":  null,
		"final_node":   null,
		"selected":     false,
		"alert_flash":  0.0,
	}
	next_squad_id += 1
	squads.append(sq)
	return sq

func _spawn_unit(node: Dictionary, race: String, squad) -> Dictionary:
	var pos = _find_free_position(node.pos, units)
	var u = {
		"pos": pos, "home": node, "race": race, "squad": squad,
		"hp": UNIT_HP, "max_hp": UNIT_HP,
		"state": "idle",
		"target_node": null, "from_pos": Vector2.ZERO, "move_progress": 0.0,
		"move_dest": Vector2.ZERO,
		"formation_offset": Vector2.ZERO,
		"path": [],
		"attack_timer": randf() * ATTACK_INTERVAL,
		"combat_target": null,
		"approach_target": null,
		"engage_pos": Vector2.ZERO,
		"engaged_by": [],
		"selected": false,
		"hit_flash": 0.0, "death_alpha": 1.0,
		"idle_offset": randf() * TAU,
	}
	units.append(u)
	if squad != null:
		squad.units.append(u)
	return u

func _find_free_position(center: Vector2, existing: Array) -> Vector2:
	for ring in range(1, 15):
		var radius = ring * UNIT_SPACING
		var count = max(6, ring * 6)
		for i in range(count):
			var a = float(i) / float(count) * TAU + randf() * 0.2
			var candidate = center + Vector2(cos(a), sin(a)) * radius
			if _position_is_free(candidate, existing): return candidate
	return center + Vector2(randf_range(-60, 60), randf_range(-60, 60))

func _position_is_free(pos: Vector2, existing: Array) -> bool:
	for u in existing:
		if u.state != "dead" and u.pos.distance_to(pos) < UNIT_SPACING * 0.85: return false
	return true

# ── helpers ───────────────────────────────────────────────────────────────────
func units_at(node, race: String = "") -> Array:
	var r = []
	if node == null: return r
	for u in units:
		if u.home == node and u.state != "dead" and u.state != "moving" \
			and (race == "" or u.race == race):
			r.append(u)
	return r

func squads_at(node: Dictionary, race: String = "") -> Array:
	var r = []
	for sq in squads:
		if sq.home == node and sq.state == "idle" \
			and (race == "" or sq.race == race) \
			and _squad_alive_count(sq) > 0:
			r.append(sq)
	return r

func _squad_alive_count(sq: Dictionary) -> int:
	var c = 0
	for u in sq.units:
		if u.state != "dead": c += 1
	return c

func get_neighbors(idx: int) -> Array:
	var r = []
	for conn in connections:
		if conn[0] == idx: r.append(conn[1])
		elif conn[1] == idx: r.append(conn[0])
	return r

func node_index(node) -> int:
	if node == null: return -1
	for i in range(game_nodes.size()):
		if game_nodes[i] == node: return i
	return -1

func _path_between(from_idx: int, to_idx: int) -> Array:
	var dist = {}
	var prev = {}
	var queue = []
	for i in range(game_nodes.size()): dist[i] = INF
	dist[from_idx] = 0
	queue.append(from_idx)
	while queue.size() > 0:
		queue.sort_custom(func(a, b): return dist[a] < dist[b])
		var cur = queue.pop_front()
		if cur == to_idx: break
		for nb in get_neighbors(cur):
			var nd = dist[cur] + 1
			if nd < dist[nb]:
				dist[nb] = nd
				prev[nb] = cur
				queue.append(nb)
	var path = []
	var c = to_idx
	while prev.has(c):
		path.push_front(c)
		c = prev[c]
	return path

func _point_to_segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab = b - a
	var len2 = ab.length_squared()
	if len2 == 0.0: return p.distance_to(a)
	var t = clamp((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)

func _mouse_world() -> Vector2:
	var vp_size = get_viewport_rect().size
	return cam.get_screen_center_position() \
		+ (get_viewport().get_mouse_position() - vp_size * 0.5) / cam.zoom.x

func _squad_centroid(sq: Dictionary) -> Vector2:
	var sum = Vector2.ZERO
	var count = 0
	for u in sq.units:
		if u.state != "dead":
			sum += u.pos
			count += 1
	if count == 0: return sq.home.pos
	return sum / count

func _squad_at_point(world_pos: Vector2):
	var best_sq   = null
	var best_dist = INF
	for sq in squads:
		if sq.race != PLAYER_RACE: continue
		for u in sq.units:
			if u.state != "dead" and _fog_at(u.pos) == FOG_VISIBLE:
				var d = u.pos.distance_to(world_pos)
				if d < 20.0 and d < best_dist:
					best_dist = d
					best_sq   = sq
	return best_sq

# ── _process ──────────────────────────────────────────────────────────────────
func _process(delta):
	time_elapsed += delta
	ai_timer     += delta

	_process_squads(delta)
	_process_units(delta)
	_resolve_collisions()

	if ai_timer >= AI_INTERVAL:
		ai_timer = 0.0
		run_ai()

	_update_hover_road()
	_update_fog()
	_scroll_camera(delta)
	queue_redraw()

# ── squad processing ──────────────────────────────────────────────────────────
func _process_squads(delta):
	var dead_squads = []
	for sq in squads:
		if _squad_alive_count(sq) == 0:
			dead_squads.append(sq)
			continue

		sq.alert_flash = maxf(0.0, sq.alert_flash - delta)

		match sq.state:
			"idle":
				pass

			"moving", "committed":
				var has_combat   = false
				var has_moving   = false
				var has_idle_mid = false
				for u in sq.units:
					if u.state == "dead": continue
					match u.state:
						"combat", "approach": has_combat   = true
						"moving":             has_moving   = true
						"idle":
							if u.home != sq.target_node:
								has_idle_mid = true

				if has_combat:
					pass
				elif has_moving:
					pass
				elif has_idle_mid:
					for u in sq.units:
						if u.state != "dead":
							_unit_start_move_to(u, sq.target_node)
				else:
					sq.home = sq.target_node
					for u in sq.units:
						if u.state != "dead":
							u.home = sq.target_node

					if sq.path.size() > 0:
						var next_idx = sq.path.pop_front()
						sq.target_node = game_nodes[next_idx]
						for u in sq.units:
							if u.state != "dead":
								_unit_start_move_to(u, sq.target_node)
					else:
						sq.state = "idle"
						sq.target_node = null
						sq.final_node  = null
						var placed: Array = []
						for u in sq.units:
							if u.state != "dead":
								u.pos = _find_free_position(sq.home.pos, placed)
								placed.append(u)

	for sq in dead_squads:
		squads.erase(sq)
		selected_squads.erase(sq)

	_process_node_capture(delta)

func _neutrals_in_combat_at(n: Dictionary) -> bool:
	for u in units:
		if u.race != NEUTRAL_RACE: continue
		if u.state != "combat" and u.state != "approach": continue
		if u.pos.distance_to(n.pos) <= NODE_RADIUS + ALERT_RADIUS:
			return true
	return false

func _process_node_capture(delta):
	for n in game_nodes:
		n.flag_wave += delta

		var humans_here   = squads_at(n, PLAYER_RACE).size() > 0
		var orcs_here     = squads_at(n, AI_RACE).size() > 0
		var neutrals_here = _neutrals_in_combat_at(n)

		if (humans_here and orcs_here) or neutrals_here:
			continue

		if not humans_here and not orcs_here:
			continue

		var attacker = PLAYER_RACE if humans_here else AI_RACE

		if n.capture_owner == attacker:
			continue

		if n.capturing_race != attacker:
			n.capturing_race = attacker

		if n.capture_owner == "" or n.capture_owner == attacker:
			n.capture_progress = minf(1.0, n.capture_progress + delta / CAPTURE_TIME)
			if n.capture_progress >= 1.0:
				n.capture_owner = attacker
		else:
			n.capture_progress = maxf(0.0, n.capture_progress - delta / CAPTURE_REVERSE)
			if n.capture_progress <= 0.0:
				n.capture_owner    = ""
				n.capturing_race   = attacker

# ── unit processing ───────────────────────────────────────────────────────────
func _process_units(delta):
	var to_remove: Array = []
	for u in units:
		match u.state:
			"idle":
				var spotted = _enemies_in_radius(u, ALERT_RADIUS)
				if spotted.size() > 0:
					_start_approach(u, _pick_engagement_target(u, spotted))
					if u.squad != null and u.squad.alert_flash <= 0.0:
						_alert_squad_to_combat(u.squad, u.home)

			"approach":
				if u.approach_target == null or u.approach_target.state == "dead":
					_release_engagement(u)
					var spotted = _enemies_in_radius(u, ALERT_RADIUS)
					if spotted.is_empty():
						u.state = "idle"
					else:
						_start_approach(u, _pick_engagement_target(u, spotted))
				else:
					var to_target = u.approach_target.pos - u.pos
					var dist_to_target = to_target.length()
					var step = _unit_move_speed(u) * delta
					var engage_dist = MELEE_RANGE + UNIT_RADIUS
					u.engage_pos = u.approach_target.pos - to_target.normalized() * engage_dist
					if dist_to_target <= engage_dist + step:
						u.pos             = u.engage_pos
						u.state           = "combat"
						u.combat_target   = u.approach_target
						u.attack_timer    = 0.0
						u.approach_target = null
					else:
						u.pos += (u.engage_pos - u.pos).normalized() * step

			"moving":
				var road_a    = u.from_pos
				var road_b    = u.target_node.pos
				var on_road   = _project_to_segment(u.pos - u.formation_offset, road_a, road_b)
				var to_go     = road_b - on_road
				var dist      = to_go.length()
				var step      = _unit_move_speed(u) * delta
				if dist <= step:
					u.pos   = road_b + u.formation_offset
					u.state = "idle"
					u.home  = u.target_node
				else:
					var new_on_road = on_road + to_go.normalized() * step
					u.pos = new_on_road + u.formation_offset
					_check_ambush(u, delta)
					var spotted = _enemies_in_radius(u, ALERT_RADIUS)
					if spotted.size() > 0:
						_start_approach(u, _pick_engagement_target(u, spotted))
						if u.squad != null and u.squad.alert_flash <= 0.0:
							_alert_squad_to_combat(u.squad, u.home)

			"combat":
				if u.combat_target == null or u.combat_target.state == "dead":
					_release_engagement(u)
					var nearby = _enemies_in_radius(u, MELEE_RANGE * 2.0)
					if not nearby.is_empty():
						u.combat_target = _pick_engagement_target(u, nearby)
						u.combat_target.engaged_by.append(u)
						u.attack_timer = 0.0
					else:
						var wider = _enemies_in_radius(u, ALERT_RADIUS)
						if wider.is_empty():
							u.state = "idle"
						else:
							_start_approach(u, _pick_engagement_target(u, wider))
				else:
					u.attack_timer -= delta
					if u.attack_timer <= 0.0:
						u.attack_timer = ATTACK_INTERVAL
						u.combat_target.hp -= ATTACK_DMG
						u.combat_target.hit_flash = 0.4
						if u.combat_target.hp <= 0:
							u.combat_target.state = "dead"
							u.combat_target = null

			"dead":
				_release_engagement(u)
				u.death_alpha -= delta * 1.5
				if u.death_alpha <= 0:
					to_remove.append(u)

		if u.hit_flash > 0:
			u.hit_flash -= delta * 3.0

	for u in to_remove:
		if u.squad != null:
			u.squad.units.erase(u)
		units.erase(u)

func _unit_move_speed(u: Dictionary) -> float:
	return MOVE_PX_SOLDIER

func _project_to_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab = b - a
	var len_sq = ab.length_squared()
	if len_sq < 0.001: return a
	var t = clamp((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t

func _unit_start_move_to(u: Dictionary, target: Dictionary):
	_release_engagement(u)
	u.state           = "moving"
	u.from_pos        = _project_to_segment(u.pos, u.pos, target.pos)
	u.target_node     = target
	u.move_progress   = 0.0
	u.combat_target   = null
	u.approach_target = null
	u.path            = []
	var road_dir = (target.pos - u.pos)
	var road_len = road_dir.length()
	if road_len > 0.1:
		road_dir = road_dir / road_len
	else:
		road_dir = Vector2(1, 0)
	var perp = road_dir.rotated(PI * 0.5)
	var sq = u.squad
	if sq != null:
		var alive = sq.units.filter(func(x): return x.state != "dead")
		var idx   = alive.find(u)
		var cnt   = alive.size()
		var lane  = (float(idx) - float(cnt - 1) * 0.5) * UNIT_RADIUS * 2.2
		u.formation_offset = perp * lane
	else:
		u.formation_offset = Vector2.ZERO
	u.move_dest = target.pos + u.formation_offset

func _enemy_of(race: String) -> String:
	if race == PLAYER_RACE: return AI_RACE
	if race == AI_RACE:     return PLAYER_RACE
	return ""

func _enemies_in_radius(u: Dictionary, radius: float) -> Array:
	var r = []
	for other in units:
		if other == u or other.state == "dead": continue
		var d = u.pos.distance_to(other.pos)
		if d >= radius: continue
		if u.race == NEUTRAL_RACE:
			if other.race != NEUTRAL_RACE:
				r.append(other)
		else:
			var enemy_race = _enemy_of(u.race)
			if other.race == enemy_race or other.race == NEUTRAL_RACE:
				r.append(other)
	return r

func _nearby_enemies(u: Dictionary) -> Array:
	return _enemies_in_radius(u, ALERT_RADIUS)

func _nearby_enemies_any(u: Dictionary) -> Array:
	return _enemies_in_radius(u, ALERT_RADIUS)

func _pick_engagement_target(u: Dictionary, enemies: Array) -> Dictionary:
	var free: Array = []
	for e in enemies:
		if e.engaged_by.size() == 0:
			free.append(e)
	if free.size() > 0:
		return free[randi() % free.size()]
	var sorted = enemies.duplicate()
	sorted.sort_custom(func(a, b): return a.engaged_by.size() < b.engaged_by.size())
	return sorted[0]

func _start_approach(u: Dictionary, target: Dictionary):
	_release_engagement(u)
	u.state           = "approach"
	u.approach_target = target
	u.combat_target   = null
	target.engaged_by.append(u)
	u.engage_pos      = _assign_engage_pos(u, target)

func _assign_engage_pos(attacker: Dictionary, target: Dictionary) -> Vector2:
	var count = target.engaged_by.size()
	var idx   = count - 1
	var angle = float(idx) / float(max(1, count)) * TAU + randf() * 0.3
	return target.pos + Vector2(cos(angle), sin(angle)) * (MELEE_RANGE + UNIT_RADIUS)

func _release_engagement(u: Dictionary):
	if u.approach_target != null:
		u.approach_target.engaged_by.erase(u)
		u.approach_target = null
	if u.combat_target != null:
		u.combat_target.engaged_by.erase(u)
		u.combat_target = null

func _resolve_collisions():
	var min_d = UNIT_RADIUS * 2.0
	for i in range(units.size()):
		var a = units[i]
		if a.state == "dead": continue
		for j in range(i + 1, units.size()):
			var b = units[j]
			if b.state == "dead": continue
			var d = a.pos.distance_to(b.pos)
			if d < min_d and d > 0.001:
				var push = (a.pos - b.pos).normalized() * (min_d - d) * 0.5
				a.pos += push
				b.pos -= push

func _check_ambush(mover: Dictionary, _delta: float):
	if mover.race != PLAYER_RACE and mover.race != AI_RACE: return
	for u in units:
		if u.race == NEUTRAL_RACE and (u.state == "idle") \
			and u.pos.distance_to(mover.pos) < ALERT_RADIUS:
			_start_approach(u, mover)
			if u.squad != null and u.squad.alert_flash <= 0.0:
				_squad_enter_combat_ambush(u.squad, mover)
			if mover.squad != null and mover.squad.alert_flash <= 0.0:
				_squad_enter_combat_ambush(mover.squad, u)

func _squad_enter_combat_ambush(sq, enemy_unit: Dictionary):
	if sq == null: return
	sq.alert_flash = 1.2
	for u in sq.units:
		if u.state == "dead": continue
		if u.state != "combat" and u.state != "approach":
			_start_approach(u, enemy_unit)
			u.path = []
	_alert_nearby_squads(sq, sq.home)

func _alert_squad_to_combat(sq: Dictionary, combat_node):
	if sq == null: return
	sq.alert_flash = 1.2
	var spotted: Array = []
	for u in sq.units:
		if u.state == "dead": continue
		if u.state == "idle" or u.state == "moving":
			spotted = _enemies_in_radius(u, ALERT_RADIUS)
			if spotted.size() > 0:
				_start_approach(u, _pick_engagement_target(u, spotted))
				u.path = []
	_alert_nearby_squads(sq, combat_node)

func _alert_nearby_squads(alerter: Dictionary, combat_node):
	for other_sq in squads:
		if other_sq == alerter: continue
		if other_sq.race != alerter.race: continue
		if other_sq.state == "combat": continue

		var centroid = _squad_centroid(other_sq)
		var in_range = false
		for u in alerter.units:
			if u.state != "dead" and u.pos.distance_to(centroid) <= VISION_RADIUS:
				in_range = true
				break
		if not in_range: continue

		other_sq.alert_flash = 1.8

		var combat_idx = node_index(combat_node)
		if combat_idx == -1: continue

		if other_sq.state == "idle":
			var from_idx = node_index(other_sq.home)
			if from_idx != -1 and from_idx != combat_idx:
				_squad_start_move(other_sq, from_idx, combat_idx)
		elif other_sq.state == "moving" or other_sq.state == "committed":
			var from_idx = node_index(other_sq.home)
			if from_idx != -1 and from_idx != combat_idx:
				_squad_start_move(other_sq, from_idx, combat_idx)

# ── hover road detection ──────────────────────────────────────────────────────
func _update_hover_road():
	var mp = _mouse_world()
	hovered_road = []
	for conn in connections:
		var a = game_nodes[conn[0]].pos
		var b = game_nodes[conn[1]].pos
		if _point_to_segment_dist(mp, a, b) < ROAD_HIT_WIDTH:
			hovered_road = conn
			break
	if hovered_road.size() > 0 and selected_squads.size() > 0:
		Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)
	else:
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)

# ── camera scroll ─────────────────────────────────────────────────────────────
func _scroll_camera(_delta: float):
	if not cam: return
	var spd    = 22.0
	var zoom_f = 1.0 / cam.zoom.x

	if Input.is_key_pressed(KEY_LEFT)  or Input.is_key_pressed(KEY_A): cam.position.x -= spd * zoom_f
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D): cam.position.x += spd * zoom_f
	if Input.is_key_pressed(KEY_UP)    or Input.is_key_pressed(KEY_W): cam.position.y -= spd * zoom_f
	if Input.is_key_pressed(KEY_DOWN)  or Input.is_key_pressed(KEY_S): cam.position.y += spd * zoom_f

	cam.position.x = clamp(cam.position.x, 0, WORLD_W)
	cam.position.y = clamp(cam.position.y, 0, WORLD_H)

# ── AI ────────────────────────────────────────────────────────────────────────
func run_ai():
	for i in range(game_nodes.size()):
		var node = game_nodes[i]
		var ai_squads = squads_at(node, AI_RACE)
		if ai_squads.is_empty(): continue
		var neighbors = get_neighbors(i)
		if neighbors.size() == 0: continue
		neighbors.shuffle()
		var target_idx = neighbors[0]
		for n_idx in neighbors:
			if squads_at(game_nodes[n_idx], PLAYER_RACE).size() > 0:
				target_idx = n_idx
				break
		for sq in ai_squads:
			_squad_start_move(sq, i, target_idx)

func _squad_start_move(sq: Dictionary, from_idx: int, to_idx: int):
	var path = _path_between(from_idx, to_idx)
	if path.is_empty(): return
	sq.state       = "moving"
	sq.final_node  = game_nodes[to_idx]
	sq.path        = path.slice(1)
	sq.target_node = game_nodes[path[0]]
	for u in sq.units:
		if u.state != "dead":
			_unit_start_move_to(u, sq.target_node)

func _squad_commit(sq: Dictionary):
	if sq.state != "moving": return
	sq.state = "committed"
	sq.path  = []
	sq.final_node = sq.target_node

# ── input ─────────────────────────────────────────────────────────────────────
var _mmb_dragging  = false
var _mmb_drag_from = Vector2.ZERO
var _cam_pos_from  = Vector2.ZERO

func _input(event):
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				if selected_squads.size() > 0:
					for sq in selected_squads:
						_squad_commit(sq)
				else:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

	# ── left mouse: selection only ────────────────────────────────────────────
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var world_pos = _event_world(event.position)
		if event.pressed:
			selecting       = true
			selection_start = world_pos
			selection_rect  = Rect2(selection_start, Vector2.ZERO)
			for sq in squads: sq.selected = false
			selected_squads = []
			queue_redraw()
		else:
			selecting = false
			selected_squads = []
			var drag_size = selection_rect.size.length()
			if drag_size < 6.0:
				var clicked_sq = _squad_at_point(world_pos)
				if clicked_sq != null:
					clicked_sq.selected = true
					selected_squads.append(clicked_sq)
			else:
				for sq in squads:
					if sq.race != PLAYER_RACE: continue
					for u in sq.units:
						if u.state != "dead" and selection_rect.has_point(u.pos):
							sq.selected = true
							selected_squads.append(sq)
							break
			queue_redraw()

	# ── right mouse: squad orders ─────────────────────────────────────────────
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT \
		and event.pressed and selected_squads.size() > 0:
		var world_pos = _event_world(event.position)
		for i in range(game_nodes.size()):
			var n = game_nodes[i]
			if _fog_at(n.pos) != FOG_HIDDEN \
				and n.pos.distance_to(world_pos) < NODE_RADIUS + 12:
				_order_squads_to_node(i)
				return
		if hovered_road.size() == 2:
			_order_squads_via_road(hovered_road[0], hovered_road[1], world_pos)

	# ── middle mouse: camera pan ──────────────────────────────────────────────
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			_mmb_dragging  = true
			_mmb_drag_from = event.position
			_cam_pos_from  = cam.position
		else:
			_mmb_dragging = false

	elif event is InputEventMouseMotion:
		if _mmb_dragging:
			var delta_screen = event.position - _mmb_drag_from
			cam.position = _cam_pos_from - delta_screen / cam.zoom.x
			cam.position.x = clamp(cam.position.x, 0, WORLD_W)
			cam.position.y = clamp(cam.position.y, 0, WORLD_H)
		elif selecting:
			var e = _event_world(event.position)
			selection_rect = Rect2(
				Vector2(min(selection_start.x, e.x), min(selection_start.y, e.y)),
				Vector2(abs(e.x - selection_start.x), abs(e.y - selection_start.y))
			)

	# ── trackpad: two-finger pan ───────────────────────────────────────────────
	elif event is InputEventPanGesture:
		var zoom_f = 1.0 / cam.zoom.x
		cam.position += event.delta * zoom_f * 5.0
		cam.position.x = clamp(cam.position.x, 0, WORLD_W)
		cam.position.y = clamp(cam.position.y, 0, WORLD_H)

	# ── trackpad: pinch to zoom ────────────────────────────────────────────────
	elif event is InputEventMagnifyGesture:
		cam.zoom = (cam.zoom * event.factor).clamp(Vector2(0.5, 0.5), Vector2(6.0, 6.0))

	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			cam.zoom = (cam.zoom * 1.1).clamp(Vector2(0.5, 0.5), Vector2(6.0, 6.0))
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			cam.zoom = (cam.zoom * 0.9).clamp(Vector2(0.5, 0.5), Vector2(6.0, 6.0))

func _event_world(screen_pos: Vector2) -> Vector2:
	return cam.get_screen_center_position() \
		+ (screen_pos - get_viewport_rect().size * 0.5) / cam.zoom.x

func _order_squads_to_node(target_idx: int):
	for sq in selected_squads:
		if sq.state == "dead": continue
		var from_idx = node_index(sq.home)
		if from_idx == -1 or from_idx == target_idx: continue
		_squad_start_move(sq, from_idx, target_idx)
	selected_squads = []
	for sq in squads: sq.selected = false
	queue_redraw()

func _order_squads_via_road(node_a: int, node_b: int, click_pos: Vector2):
	for sq in selected_squads:
		var from_idx = node_index(sq.home)
		if from_idx == -1: continue
		var da = game_nodes[node_a].pos.distance_to(click_pos)
		var db = game_nodes[node_b].pos.distance_to(click_pos)
		var target_idx = node_b if da < db else node_a
		if from_idx == target_idx:
			target_idx = node_a if target_idx == node_b else node_b
		if from_idx == target_idx: continue
		var path = _path_between(from_idx, target_idx)
		if path.is_empty(): continue
		sq.state       = "moving"
		sq.final_node  = game_nodes[target_idx]
		sq.path        = path.slice(1)
		sq.target_node = game_nodes[path[0]]
		for u in sq.units:
			if u.state != "dead":
				_unit_start_move_to(u, sq.target_node)
	selected_squads = []
	for sq in squads: sq.selected = false
	queue_redraw()

# ── _draw ─────────────────────────────────────────────────────────────────────
func _draw():
	if game_nodes.is_empty(): return

	draw_rect(Rect2(Vector2.ZERO, Vector2(WORLD_W, WORLD_H)), Color(0.12, 0.17, 0.09))

	for i in range(connections.size()):
		var conn = connections[i]
		var a = game_nodes[conn[0]].pos
		var b = game_nodes[conn[1]].pos
		var is_hovered = (hovered_road.size() == 2 and
			((hovered_road[0] == conn[0] and hovered_road[1] == conn[1]) or
			 (hovered_road[0] == conn[1] and hovered_road[1] == conn[0])))
		_draw_road(a, b, is_hovered)

	for d in road_decor:
		_draw_road_decor(d)

	for n in game_nodes:
		draw_game_node(n)

	for u in units:
		if u.death_alpha > 0 and _fog_at(u.pos) == FOG_VISIBLE:
			draw_unit(u)

	_draw_squad_overlays()

	if selecting:
		draw_rect(selection_rect, Color(0.4, 1.0, 0.4, 0.12))
		draw_rect(selection_rect, Color(0.4, 1.0, 0.4, 0.85), false, 1.5)

	_draw_fog()

func _draw_road(a: Vector2, b: Vector2, hovered: bool = false):
	draw_line(a, b, Color(0.28, 0.21, 0.13), 48)
	draw_line(a, b, Color(0.33, 0.26, 0.17), 34)
	if hovered and selected_squads.size() > 0:
		draw_line(a, b, Color(0.85, 0.80, 0.30, 0.55), 36)
	draw_line(a, b, Color(0.36, 0.29, 0.20), 20)

func _draw_squad_overlays():
	for sq in squads:
		if sq.race != PLAYER_RACE: continue
		var alive = _squad_alive_count(sq)
		if alive == 0: continue

		var centroid = _squad_centroid(sq)
		var fog = _fog_at(centroid)
		if fog != FOG_VISIBLE: continue

		if sq.selected:
			draw_arc(centroid, 38, 0, TAU, 36, Color(1.0, 0.95, 0.2, 0.8), 2.5)
			draw_string(ThemeDB.fallback_font, centroid + Vector2(-10, -46),
				str(alive), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.95, 0.2))

		if sq.state == "moving" or sq.state == "committed":
			_draw_route(sq)

		if sq.alert_flash > 0.0:
			_draw_alert_bang(centroid, sq.alert_flash)

func _draw_alert_bang(centroid: Vector2, flash: float):
	var t    = flash / 1.2
	var base = centroid + Vector2(0, -52)
	draw_circle(base, 10, Color(0.0, 0.0, 0.0, 0.75 * t))
	draw_circle(base, 9,  Color(1.0, 0.88, 0.0, t))
	draw_string(ThemeDB.fallback_font, base + Vector2(-3, 5),
		"!", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.0, 0.0, 0.0, t))

func _draw_route(sq: Dictionary):
	var route_col = Color(1.0, 0.95, 0.2, 0.75) if sq.state == "moving" else Color(0.9, 0.5, 0.2, 0.75)
	var pts: Array = [sq.home.pos]
	if sq.target_node != null:
		pts.append(sq.target_node.pos)
	for idx in sq.path:
		pts.append(game_nodes[idx].pos)

	for i in range(pts.size() - 1):
		_draw_dashed_line(pts[i], pts[i + 1], route_col, 2.5, 14.0, 7.0)

	var dest = sq.final_node.pos if sq.final_node != null else pts[pts.size() - 1]
	_draw_x(dest, route_col, 12.0)

func _draw_dashed_line(a: Vector2, b: Vector2, col: Color, width: float, dash: float, gap: float):
	var total = a.distance_to(b)
	if total < 1.0: return
	var dir = (b - a) / total
	var t = 0.0
	while t < total:
		var t2 = min(t + dash, total)
		draw_line(a + dir * t, a + dir * t2, col, width)
		t += dash + gap

func _draw_x(center: Vector2, col: Color, size: float):
	draw_line(center + Vector2(-size, -size), center + Vector2(size, size), col, 2.5)
	draw_line(center + Vector2(size, -size),  center + Vector2(-size, size), col, 2.5)
	draw_circle(center, 5, col)

func _draw_road_decor(d: Dictionary):
	var p = d.pos
	var fog = _fog_at(p)
	if fog == FOG_HIDDEN: return
	var alpha: float = 0.45 if fog == FOG_EXPLORED else 1.0
	var rng = RandomNumberGenerator.new()
	rng.seed = d.seed
	match d.type:
		"tree":
			var g     = 0.32 + rng.randf() * 0.12
			var crown = Color(0.12 + rng.randf() * 0.08, g, 0.10, alpha)
			var dark  = Color(crown.r * 0.6, crown.g * 0.6, crown.b * 0.6, alpha)
			draw_circle(p + Vector2(3, 4), 18, Color(0, 0, 0, 0.25 * alpha))
			draw_circle(p, 16, dark)
			draw_circle(p + Vector2(-4, -4), 11, crown)
			draw_circle(p + Vector2(4, 3), 8, crown.lightened(0.08))
			draw_circle(p + Vector2(-2, 5), 6, dark)
		"rock":
			var base  = 0.48 + rng.randf() * 0.10
			var rc    = Color(base, base * 0.96, base * 0.90, alpha)
			var light = rc.lightened(0.18)
			draw_circle(p + Vector2(3, 4), 20, Color(0, 0, 0, 0.22 * alpha))
			draw_circle(p, 17, rc)
			draw_circle(p + Vector2(8, 5), 11, rc)
			draw_circle(p + Vector2(-7, 6), 9, rc)
			draw_circle(p + Vector2(-4, -5), 7, light)
		"bush":
			var bush_col = Color(0.20, 0.35 + rng.randf() * 0.10, 0.12, alpha)
			var dark     = bush_col.darkened(0.25)
			draw_circle(p + Vector2(2, 3), 14, Color(0, 0, 0, 0.18 * alpha))
			draw_circle(p, 12, dark)
			draw_circle(p + Vector2(-6, -3), 8, bush_col)
			draw_circle(p + Vector2(6, -2),  7, bush_col)
			draw_circle(p + Vector2(0, 5),   7, bush_col.lightened(0.06))
		"rock_cluster":
			var base = 0.46 + rng.randf() * 0.08
			var rc   = Color(base, base * 0.95, base * 0.88, alpha)
			draw_circle(p + Vector2(3, 4), 28, Color(0, 0, 0, 0.18 * alpha))
			for _i in range(4):
				var off = Vector2(rng.randf_range(-18, 18), rng.randf_range(-18, 18))
				var r   = rng.randf_range(7, 14)
				draw_circle(p + off, r, rc)
				draw_circle(p + off + Vector2(-2, -2), r * 0.4, rc.lightened(0.15))

func _draw_clearing_floor(n: Dictionary, alpha: float):
	if n.clearing_poly.size() < 3: return
	var floor_col: Color
	match n.clearing_type:
		"river_crossing": floor_col = Color(0.22, 0.28, 0.16, alpha)
		"ruins":          floor_col = Color(0.27, 0.24, 0.18, alpha)
		"open_field":     floor_col = Color(0.26, 0.30, 0.17, alpha)
		_:                floor_col = Color(0.20, 0.26, 0.13, alpha)
	draw_colored_polygon(n.clearing_poly, floor_col)
	draw_polyline(n.clearing_poly + PackedVector2Array([n.clearing_poly[0]]),
		Color(0.15, 0.20, 0.10, alpha * 0.6), 2.0)

func _draw_clearing_decor(n: Dictionary, alpha: float):
	var rng = RandomNumberGenerator.new()
	for d in n.clearing_decor:
		rng.seed = d.seed
		var p: Vector2 = d.pos
		match d.type:
			"campfire":
				draw_circle(p, 13, Color(0.14, 0.10, 0.06, alpha * 0.5))
				draw_circle(p, 10, Color(0.22, 0.16, 0.08, alpha))
				draw_circle(p, 7,  Color(0.85, 0.38, 0.04, alpha))
				draw_circle(p, 4,  Color(1.00, 0.72, 0.08, alpha))
				draw_circle(p, 2,  Color(1.00, 0.95, 0.60, alpha))
				for i in range(6):
					var a = float(i) / 6.0 * TAU
					draw_line(p, p + Vector2(cos(a), sin(a)) * rng.randf_range(5, 9),
						Color(0.75, 0.32, 0.02, alpha * 0.7), 1)

			"tent":
				var w = 30.0
				var h = 24.0
				var tent_pts = PackedVector2Array([
					p + Vector2(-w * 0.5,  h * 0.3),
					p + Vector2(-w * 0.15, -h * 0.5),
					p + Vector2(w * 0.15,  -h * 0.5),
					p + Vector2(w * 0.5,   h * 0.3),
				])
				draw_colored_polygon(tent_pts, Color(0.42, 0.30, 0.15, alpha))
				draw_polyline(tent_pts + PackedVector2Array([tent_pts[0]]),
					Color(0.28, 0.18, 0.07, alpha), 2.0)
				draw_line(p + Vector2(-w * 0.15, -h * 0.5), p + Vector2(w * 0.15, -h * 0.5),
					Color(0.28, 0.18, 0.07, alpha), 2.0)
				draw_circle(p + Vector2(0, -h * 0.5), 3, Color(0.58, 0.44, 0.22, alpha))

			"tree":
				var g     = 0.32 + rng.randf() * 0.12
				var crown = Color(0.12 + rng.randf() * 0.08, g, 0.10, alpha)
				var dark  = Color(crown.r * 0.6, crown.g * 0.6, crown.b * 0.6, alpha)
				draw_circle(p + Vector2(3, 4), 18, Color(0, 0, 0, 0.25 * alpha))
				draw_circle(p, 16, dark)
				draw_circle(p + Vector2(-4, -4), 11, crown)
				draw_circle(p + Vector2(4, 3), 8, crown.lightened(0.08))
				draw_circle(p + Vector2(-2, 5), 6, dark)

			"river":
				var dir: Vector2 = d.dir
				var perp = dir.rotated(PI * 0.5)
				var w = 22.0
				var length = 130.0
				var river_pts = PackedVector2Array([
					p + dir * (-length) + perp * w,
					p + dir * (-length) - perp * w,
					p + dir * (length)  - perp * w,
					p + dir * (length)  + perp * w,
				])
				draw_colored_polygon(river_pts, Color(0.25, 0.45, 0.65, alpha * 0.75))
				draw_line(p + dir * (-length) + perp * (w - 5),
					p + dir * (length) + perp * (w - 5),
					Color(0.35, 0.60, 0.80, alpha * 0.4), 3.0)

			"reed":
				var rc = Color(0.32, 0.52, 0.22, alpha)
				draw_line(p, p + Vector2(rng.randf_range(-3, 3), -14), rc, 2.0)
				draw_circle(p + Vector2(0, -14), 3, Color(0.50, 0.38, 0.12, alpha))

			"bridge":
				var dir: Vector2 = d.dir
				var perp = dir.rotated(PI * 0.5)
				var bc = Color(0.48, 0.38, 0.22, alpha)
				draw_rect(Rect2(p + dir * (-55) + perp * (-16), Vector2(40, 32)), bc)
				draw_rect(Rect2(p + dir * (15)  + perp * (-16), Vector2(40, 32)), bc)

			"column":
				var fallen = rng.randf() > 0.5
				var stone_col = Color(0.58 + rng.randf() * 0.08, 0.55, 0.50, alpha)
				if fallen:
					draw_rect(Rect2(p + Vector2(-6, -20), Vector2(12, 22)), stone_col)
					draw_rect(Rect2(p + Vector2(-8, -22), Vector2(16, 5)),  stone_col)
					draw_rect(Rect2(p + Vector2(-8, -3),  Vector2(16, 5)),  stone_col)
				else:
					draw_rect(Rect2(p + Vector2(-5, -18), Vector2(10, 22)), stone_col)
					draw_rect(Rect2(p + Vector2(-7, -20), Vector2(14, 4)),  stone_col)

			"arch":
				var stone_col = Color(0.55, 0.52, 0.46, alpha)
				draw_arc(p, 32, PI, 2 * PI, 20, stone_col, 8)
				draw_line(p + Vector2(-32, 0), p + Vector2(-32, 20), stone_col, 8)
				draw_line(p + Vector2(32,  0), p + Vector2(32,  20), stone_col, 8)

			"bush":
				var bush_col = Color(0.20, 0.35 + rng.randf() * 0.10, 0.12, alpha)
				var dark     = bush_col.darkened(0.25)
				draw_circle(p + Vector2(2, 3), 14, Color(0, 0, 0, 0.18 * alpha))
				draw_circle(p, 12, dark)
				draw_circle(p + Vector2(-6, -3), 8, bush_col)
				draw_circle(p + Vector2(6, -2),  7, bush_col)
				draw_circle(p + Vector2(0, 5),   7, bush_col.lightened(0.06))

			"rock":
				var base  = 0.48 + rng.randf() * 0.10
				var rc    = Color(base, base * 0.96, base * 0.90, alpha)
				var light = rc.lightened(0.18)
				draw_circle(p + Vector2(3, 4), 20, Color(0, 0, 0, 0.22 * alpha))
				draw_circle(p, 17, rc)
				draw_circle(p + Vector2(8, 5), 11, rc)
				draw_circle(p + Vector2(-7, 6), 9, rc)
				draw_circle(p + Vector2(-4, -5), 7, light)

func draw_game_node(n: Dictionary):
	var p   = n.pos
	var fog = _fog_at(p)
	if fog == FOG_HIDDEN: return
	var alpha: float = 0.5 if fog == FOG_EXPLORED else 1.0

	if n.clearing_type != "":
		_draw_clearing_floor(n, alpha)
		if fog == FOG_VISIBLE:
			_draw_clearing_decor(n, alpha)

	if n.capture_owner == PLAYER_RACE and fog == FOG_VISIBLE:
		draw_circle(p, CAPTURE_VISION, Color(0.3, 0.55, 1.0, 0.05))
		draw_arc(p, CAPTURE_VISION, 0, TAU, 64, Color(0.3, 0.55, 1.0, 0.12), 1.5)

	draw_circle(p + Vector2(4, 6), NODE_RADIUS + 6, Color(0, 0, 0, 0.3 * alpha))
	draw_circle(p, NODE_RADIUS,     Color(0.20, 0.18, 0.13, alpha))
	draw_circle(p, NODE_RADIUS - 5, Color(0.30, 0.27, 0.19, alpha))
	var ring_col = Color(0.3, 0.65, 0.3, alpha)  if n.owner == PLAYER_RACE \
		else (Color(0.65, 0.25, 0.15, alpha) if n.owner == AI_RACE \
		else Color(0.5, 0.5, 0.42, alpha))
	draw_arc(p, NODE_RADIUS - 3, 0, TAU, 48, ring_col, 5)

	if n.capturing_race != "" and n.capture_progress > 0.0 and n.capture_progress < 1.0:
		var arc_col = Color(0.3, 0.65, 0.3, alpha) if n.capturing_race == PLAYER_RACE \
			else Color(0.65, 0.25, 0.15, alpha)
		draw_arc(p, NODE_RADIUS + 12, -PI * 0.5,
			-PI * 0.5 + TAU * n.capture_progress, 48, arc_col, 6)

	if n.owner == PLAYER_RACE:
		draw_rect(Rect2(p + Vector2(-18, -38), Vector2(36, 42)), Color(0.55, 0.52, 0.44, alpha))
		draw_rect(Rect2(p + Vector2(-23, -43), Vector2(46, 10)), Color(0.45, 0.42, 0.34, alpha))
		for i in range(4):
			draw_rect(Rect2(p + Vector2(-23 + i*13, -54), Vector2(9, 13)), Color(0.45, 0.42, 0.34, alpha))
		draw_line(p + Vector2(0, -54), p + Vector2(0, -72), Color(0.6, 0.5, 0.3, alpha), 2)
		draw_circle(p + Vector2(0, -72), 5, Color(0.3, 0.5, 0.95, alpha))
	elif n.owner == AI_RACE:
		draw_rect(Rect2(p + Vector2(-22, -33), Vector2(44, 38)), Color(0.32, 0.22, 0.12, alpha))
		draw_rect(Rect2(p + Vector2(-27, -38), Vector2(54, 10)), Color(0.27, 0.18, 0.09, alpha))
		for i in range(6):
			var sx = p.x - 24 + i * 10
			draw_line(Vector2(sx, p.y - 38), Vector2(sx + 3, p.y - 54), Color(0.5, 0.28, 0.08, alpha), 3)
		draw_line(p + Vector2(0, -54), p + Vector2(0, -72), Color(0.4, 0.25, 0.1, alpha), 2)
		draw_circle(p + Vector2(0, -72), 5, Color(0.7, 0.15, 0.1, alpha))
	else:
		draw_circle(p, 22, Color(0.38, 0.35, 0.28, alpha))
		draw_arc(p, 22, 0, TAU, 24, Color(0.6, 0.57, 0.48, alpha), 2)

	if n.capture_owner != "" and fog == FOG_VISIBLE:
		_draw_flag(p, n.capture_owner, n.flag_wave, alpha)

	if fog == FOG_VISIBLE:
		draw_string(ThemeDB.fallback_font, p + Vector2(-35, NODE_RADIUS + 18), n.label)
		var h = units_at(n, PLAYER_RACE).size()
		var o = units_at(n, AI_RACE).size()
		if h > 0:
			draw_rect(Rect2(p + Vector2(-52, NODE_RADIUS + 22), Vector2(46, 16)), Color(0.15, 0.25, 0.55, 0.85))
			draw_string(ThemeDB.fallback_font, p + Vector2(-50, NODE_RADIUS + 34), str(h) + " Hum")
		if o > 0:
			draw_rect(Rect2(p + Vector2(6, NODE_RADIUS + 22), Vector2(46, 16)), Color(0.38, 0.12, 0.08, 0.85))
			draw_string(ThemeDB.fallback_font, p + Vector2(8, NODE_RADIUS + 34), str(o) + " Orc")
	else:
		draw_string(ThemeDB.fallback_font, p + Vector2(-35, NODE_RADIUS + 18), n.label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.7, 0.7, 0.7, 0.5))

func _draw_flag(node_pos: Vector2, owner: String, wave: float, alpha: float):
	var flag_col = Color(0.2, 0.4, 0.9, alpha) if owner == PLAYER_RACE else Color(0.8, 0.2, 0.1, alpha)
	var pole_top = node_pos + Vector2(NODE_RADIUS - 2, -NODE_RADIUS - 35)
	var pole_bot = node_pos + Vector2(NODE_RADIUS - 2, -NODE_RADIUS + 5)
	draw_line(pole_bot, pole_top, Color(0.7, 0.65, 0.5, alpha), 3)

	var fw = 22.0
	var fh = 14.0
	var w1 = sin(wave * 3.5) * 5.0
	var w2 = sin(wave * 3.5 + 1.2) * 4.0
	var pts = PackedVector2Array([
		pole_top,
		pole_top + Vector2(fw + w1, fh * 0.0),
		pole_top + Vector2(fw + w2, fh * 0.5),
		pole_top + Vector2(fw + w1, fh * 1.0),
		pole_top + Vector2(0.0,     fh * 1.0),
	])
	draw_colored_polygon(pts, flag_col)

func draw_unit(u: Dictionary):
	var p   = u.pos
	var al  = u.death_alpha
	var fl  = clamp(u.hit_flash, 0.0, 1.0)

	var human   = u.race == PLAYER_RACE
	var neutral = u.race == NEUTRAL_RACE

	var body_col  : Color
	var detail_col: Color
	var rim_col   : Color

	if neutral:
		body_col   = Color(0.55, 0.32, 0.10, al)
		detail_col = Color(0.38, 0.22, 0.06, al)
		rim_col    = Color(0.70, 0.48, 0.18, al)
	elif human:
		body_col   = Color(0.28, 0.48, 0.92, al)
		detail_col = Color(0.18, 0.32, 0.70, al)
		rim_col    = Color(0.72, 0.76, 0.88, al)
	else:
		body_col   = Color(0.22, 0.55, 0.16, al)
		detail_col = Color(0.14, 0.38, 0.10, al)
		rim_col    = Color(0.68, 0.42, 0.14, al)

	if fl > 0:
		body_col   = body_col.lerp(Color(1, 1, 1, al), fl)
		detail_col = detail_col.lerp(Color(1, 1, 1, al), fl)
		rim_col    = rim_col.lerp(Color(1, 1, 1, al), fl)

	var face_tgt = u.combat_target if u.state == "combat" else u.approach_target
	var facing   = Vector2(0, -1)
	if face_tgt != null and face_tgt.state != "dead" and u.pos.distance_to(face_tgt.pos) > 1.0:
		facing = (face_tgt.pos - u.pos).normalized()
	elif u.state == "moving" or u.state == "approach":
		var dest = u.move_dest if u.state == "moving" else u.engage_pos
		if u.pos.distance_to(dest) > 1.0:
			facing = (dest - u.pos).normalized()

	if u.state == "dead":
		draw_circle(p + Vector2(3, 3), 7, Color(0, 0, 0, 0.18 * al))
		draw_circle(p, 7, detail_col)
		draw_circle(p, 4, body_col)
		return

	var squad_selected = u.squad != null and u.squad.selected
	if squad_selected:
		draw_circle(p, 14, Color(1.0, 0.95, 0.2, 0.30 * al))

	draw_circle(p + Vector2(2, 3), 9, Color(0, 0, 0, 0.22 * al))

	if neutral:
		draw_circle(p, 9, body_col)
		draw_circle(p, 5, detail_col)
		var spear_end = p + facing * 14
		draw_line(p - facing * 3, spear_end, Color(0.70, 0.60, 0.30, al), 2)
		draw_circle(spear_end, 2, Color(0.78, 0.78, 0.72, al))
	elif human:
		draw_circle(p, 9, body_col)
		var shield_pos = p + facing.rotated(PI * 0.5) * 5 - facing * 2
		draw_circle(shield_pos, 5, rim_col)
		draw_circle(shield_pos, 3, detail_col)
		var sword_end = p + facing * 13
		draw_line(p + facing * 4, sword_end, Color(0.82, 0.82, 0.88, al), 2)
		draw_circle(sword_end, 1, Color(0.72, 0.72, 0.78, al))
		draw_arc(p, 9, 0, TAU, 20, rim_col, 2)
	else:
		draw_circle(p, 10, body_col)
		var axe_end = p + facing * 14
		draw_line(p + facing * 3, axe_end, Color(0.55, 0.45, 0.30, al), 3)
		draw_arc(axe_end, 5, facing.angle() - PI * 0.4, facing.angle() + PI * 0.4, 8, rim_col, 4)
		draw_arc(p, 10, 0, TAU, 20, rim_col, 2)

	if u.hp < u.max_hp or u.state == "combat" or u.state == "approach":
		var bw = 18
		var bp = p + Vector2(-bw / 2, -16)
		draw_rect(Rect2(bp, Vector2(bw, 3)), Color(0.15, 0.0, 0.0, al))
		var pct = float(u.hp) / float(u.max_hp)
		var hc  = Color(0.1, 0.9, 0.1, al) if pct > 0.5 else (Color(0.9, 0.9, 0.1, al) if pct > 0.25 else Color(0.9, 0.1, 0.1, al))
		draw_rect(Rect2(bp, Vector2(int(bw * pct), 3)), hc)

# ── fog drawing ───────────────────────────────────────────────────────────────
func _draw_fog():
	var cols = int(ceil(WORLD_W / FOG_CELL)) + 1
	var rows = int(ceil(WORLD_H / FOG_CELL)) + 1
	for gy in range(rows):
		for gx in range(cols):
			var key = Vector2i(gx, gy)
			var state = fog_grid.get(key, FOG_HIDDEN)
			if state == FOG_VISIBLE: continue
			var cell_pos = Vector2(gx * FOG_CELL, gy * FOG_CELL)
			var col = Color(0.0, 0.0, 0.0, 1.0) if state == FOG_HIDDEN else Color(0.0, 0.0, 0.0, 0.55)
			draw_rect(Rect2(cell_pos, Vector2(FOG_CELL + 1, FOG_CELL + 1)), col)
