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

const MOVE_PX_SOLDIER = 90.0
const MOVE_SPEED      = MOVE_PX_SOLDIER
const VISION_RADIUS   = 220.0
const UNIT_SPACING    = 28.0
const ROAD_HIT_WIDTH  = 30.0
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

func _place_node(pos: Vector2, label: String, owner_race: String, used: Array):
	game_nodes.append({
		"pos": pos, "label": label, "owner": owner_race,
		"capture_owner":    owner_race,
		"capture_progress": 1.0 if owner_race != "neutral" else 0.0,
		"capturing_race":   owner_race,
		"flag_wave":        randf() * TAU,
	})
	used.append(pos)

func _far_from_all(p: Vector2, used: Array, min_dist: float) -> bool:
	for u in used:
		if p.distance_to(u) < min_dist: return false
	return true

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
	_spawn_neutral_ambushers()

func _spawn_neutral_ambushers():
	for conn in connections:
		var a     = game_nodes[conn[0]].pos
		var b     = game_nodes[conn[1]].pos
		var t     = randf_range(0.25, 0.75)
		var perp  = (b - a).normalized().rotated(PI * 0.5)
		var center = a.lerp(b, t) + perp * randf_range(-40, 40)
		var count = randi_range(2, 4)
		var sq    = _make_squad_neutral(center)
		for _i in range(count):
			_spawn_neutral_on_road(center, sq)

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
		"path": [],
		"attack_timer": randf() * ATTACK_INTERVAL,
		"combat_target": null, "selected": false,
		"hit_flash": 0.0, "death_alpha": 1.0,
		"idle_offset": randf() * TAU,
	}
	units.append(u)
	if squad != null:
		squad.units.append(u)
	return u

func _spawn_neutral_on_road(center: Vector2, sq: Dictionary):
	var pos = _find_free_position(center, units)
	var u = {
		"pos": pos, "home": null, "race": NEUTRAL_RACE, "squad": sq,
		"hp": UNIT_HP, "max_hp": UNIT_HP,
		"state": "idle",
		"target_node": null, "from_pos": Vector2.ZERO, "move_progress": 0.0,
		"path": [],
		"attack_timer": randf() * ATTACK_INTERVAL,
		"combat_target": null, "selected": false,
		"hit_flash": 0.0, "death_alpha": 1.0,
		"idle_offset": randf() * TAU,
	}
	sq.units.append(u)
	units.append(u)

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
						"combat":  has_combat   = true
						"moving":  has_moving   = true
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

func _process_node_capture(delta):
	for n in game_nodes:
		n.flag_wave += delta

		var humans_here = squads_at(n, PLAYER_RACE).size() > 0
		var orcs_here   = squads_at(n, AI_RACE).size() > 0

		if humans_here and orcs_here:
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
				var enemy_race = _enemy_of(u.race)
				if enemy_race != "":
					var enemies = units_at(u.home, enemy_race) if u.home != null else _nearby_enemies(u)
					if enemies.size() > 0:
						u.state = "combat"
						u.attack_timer = 0.0
						if u.squad != null and u.squad.alert_flash <= 0.0:
							_alert_squad_to_combat(u.squad, u.home)

			"moving":
				var dest   = u.target_node.pos
				var to_go  = dest - u.pos
				var dist   = to_go.length()
				var step   = _unit_move_speed(u) * delta
				if dist <= step:
					u.pos   = dest
					u.state = "idle"
					u.home  = u.target_node
				else:
					u.pos += to_go.normalized() * step
					_check_ambush(u, delta)

			"combat":
				var enemies: Array
				if u.combat_target != null and u.combat_target.state != "dead":
					enemies = [u.combat_target]
				elif u.race == NEUTRAL_RACE:
					enemies = _nearby_enemies_any(u)
				else:
					var enemy_race = _enemy_of(u.race)
					enemies = units_at(u.home, enemy_race)
					if enemies.is_empty(): enemies = _nearby_enemies(u)
				if enemies.is_empty():
					u.state = "idle"
					u.combat_target = null
				else:
					if u.combat_target == null or u.combat_target.state == "dead":
						u.combat_target = enemies[randi() % enemies.size()]
					u.attack_timer -= delta
					if u.attack_timer <= 0.0:
						u.attack_timer = ATTACK_INTERVAL
						u.combat_target.hp -= ATTACK_DMG
						u.combat_target.hit_flash = 0.4
						if u.combat_target.hp <= 0:
							u.combat_target.state = "dead"
							u.combat_target = null

			"dead":
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

func _unit_start_move_to(u: Dictionary, target: Dictionary):
	u.state         = "moving"
	u.from_pos      = u.pos
	u.target_node   = target
	u.move_progress = 0.0
	u.combat_target = null
	u.path          = []

func _enemy_of(race: String) -> String:
	if race == PLAYER_RACE: return AI_RACE
	if race == AI_RACE:     return PLAYER_RACE
	return ""

func _nearby_enemies(u: Dictionary) -> Array:
	var r = []
	var enemy_race = _enemy_of(u.race)
	if enemy_race == "": return r
	for other in units:
		if other.race == enemy_race and other.state != "dead" \
			and u.pos.distance_to(other.pos) < 80.0:
			r.append(other)
	return r

func _nearby_enemies_any(u: Dictionary) -> Array:
	var r = []
	for other in units:
		if other != u and other.race != NEUTRAL_RACE and other.state != "dead" \
			and u.pos.distance_to(other.pos) < 80.0:
			r.append(other)
	return r

func _check_ambush(mover: Dictionary, _delta: float):
	if mover.race != PLAYER_RACE and mover.race != AI_RACE: return
	for u in units:
		if u.race == NEUTRAL_RACE and u.state == "idle" \
			and u.pos.distance_to(mover.pos) < 55.0:
			u.state = "combat"
			u.combat_target = mover
			u.attack_timer  = 0.0
			if mover.squad != null:
				_squad_enter_combat_ambush(mover.squad, u)
			else:
				mover.state = "combat"
				mover.combat_target = u
				mover.attack_timer  = 0.0
				mover.path = []

func _squad_enter_combat_ambush(sq: Dictionary, neutral_unit: Dictionary):
	sq.alert_flash = 1.2
	for u in sq.units:
		if u.state == "dead": continue
		u.combat_target = neutral_unit
		u.attack_timer  = randf() * ATTACK_INTERVAL
		u.state         = "combat"
		u.path          = []
	_alert_nearby_squads(sq, sq.home)

func _alert_squad_to_combat(sq: Dictionary, combat_node):
	if sq == null: return
	sq.alert_flash = 1.2
	for u in sq.units:
		if u.state == "idle" and (combat_node == null or u.home == combat_node):
			u.state = "combat"
			u.attack_timer = 0.0
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
	var v = get_viewport_rect().size
	var mouse = get_viewport().get_mouse_position()
	var edge   = 60.0
	var spd    = 22.0
	var zoom_f = 1.0 / cam.zoom.x

	if mouse.x < edge:       cam.position.x -= spd * zoom_f
	if mouse.x > v.x - edge: cam.position.x += spd * zoom_f
	if mouse.y < edge:       cam.position.y -= spd * zoom_f
	if mouse.y > v.y - edge: cam.position.y += spd * zoom_f

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
			var trunk_col = Color(0.35, 0.25, 0.12, alpha)
			var leaf_col  = Color(0.15 + rng.randf() * 0.1, 0.40 + rng.randf() * 0.2, 0.12, alpha)
			draw_rect(Rect2(p + Vector2(-5, 0), Vector2(10, 20)), trunk_col)
			draw_circle(p + Vector2(0, -8),  22, leaf_col)
			draw_circle(p + Vector2(-10, 2), 14, leaf_col)
			draw_circle(p + Vector2(10, 2),  14, leaf_col)
		"rock":
			var rock_col = Color(0.52 + rng.randf() * 0.1, 0.50, 0.46, alpha)
			draw_circle(p,                   18, rock_col)
			draw_circle(p + Vector2(14, 6),  13, rock_col)
			draw_circle(p + Vector2(-10, 8), 11, rock_col)
		"bush":
			var bush_col = Color(0.22, 0.38 + rng.randf() * 0.1, 0.15, alpha)
			draw_circle(p,                    14, bush_col)
			draw_circle(p + Vector2(12, 4),   10, bush_col)
			draw_circle(p + Vector2(-10, 4),  10, bush_col)
		"rock_cluster":
			var rc = Color(0.48, 0.45, 0.42, alpha)
			for _i in range(4):
				var off = Vector2(rng.randf_range(-20, 20), rng.randf_range(-20, 20))
				draw_circle(p + off, rng.randf_range(8, 16), rc)

func draw_game_node(n: Dictionary):
	var p   = n.pos
	var fog = _fog_at(p)
	if fog == FOG_HIDDEN: return
	var alpha: float = 0.5 if fog == FOG_EXPLORED else 1.0

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
	var p       = u.pos
	var al      = u.death_alpha
	var human   = u.race == PLAYER_RACE
	var neutral = u.race == NEUTRAL_RACE
	var bob     = sin(time_elapsed * 2.2 + u.idle_offset) * 1.5 if u.state == "idle" else 0.0
	if u.state == "combat" and u.combat_target != null:
		p += (u.combat_target.pos - u.pos).normalized() * sin(time_elapsed * 9.0 + u.idle_offset) * 3.5
	p.y += bob

	var fl        = clamp(u.hit_flash, 0.0, 1.0)
	var body_col  : Color
	var skin_col  : Color
	var armor_col : Color

	if neutral:
		body_col  = Color(0.55, 0.30, 0.10, al)
		skin_col  = Color(0.80, 0.65, 0.45, al)
		armor_col = Color(0.40, 0.28, 0.12, al)
	elif human:
		body_col  = Color(0.28, 0.48, 0.92, al)
		skin_col  = Color(0.95, 0.82, 0.70, al)
		armor_col = Color(0.62, 0.66, 0.76, al)
	else:
		body_col  = Color(0.22, 0.62, 0.18, al)
		skin_col  = Color(0.42, 0.62, 0.28, al)
		armor_col = Color(0.58, 0.32, 0.10, al)

	if fl > 0:
		body_col  = body_col.lerp(Color(1, 1, 1, al), fl)
		skin_col  = skin_col.lerp(Color(1, 1, 1, al), fl)
		armor_col = armor_col.lerp(Color(1, 1, 1, al), fl)

	if u.state == "dead":
		draw_circle(p + Vector2(8, 2),  int(5 * S), skin_col)
		draw_rect(Rect2(p + Vector2(-4, 0), Vector2(int(9 * S), int(4 * S))), body_col)
		return

	var squad_selected = u.squad != null and u.squad.selected
	if squad_selected:
		draw_arc(p + Vector2(0, 4), int(12 * S), 0, TAU, 24, Color(1.0, 0.95, 0.2, 0.50 * al), 1.5)

	var sh_pts = PackedVector2Array()
	for i in range(16):
		var a = float(i) / 16.0 * TAU
		sh_pts.append(p + Vector2(0, int(9 * S)) + Vector2(cos(a) * int(7 * S), sin(a) * int(3 * S)))
	draw_colored_polygon(sh_pts, Color(0, 0, 0, 0.22 * al))

	if neutral:
		draw_rect(Rect2(p + Vector2(int(-5*S), int(4*S)),  Vector2(int(4*S), int(7*S))), armor_col)
		draw_rect(Rect2(p + Vector2(int(1*S),  int(4*S)),  Vector2(int(4*S), int(7*S))), armor_col)
		draw_rect(Rect2(p + Vector2(int(-6*S), int(-5*S)), Vector2(int(12*S), int(10*S))), body_col)
		draw_rect(Rect2(p + Vector2(int(-10*S),int(-5*S)), Vector2(int(4*S), int(7*S))), body_col)
		draw_rect(Rect2(p + Vector2(int(6*S),  int(-5*S)), Vector2(int(4*S), int(7*S))), body_col)
		draw_circle(p + Vector2(0, int(-9*S)), int(5*S), skin_col)
		draw_line(p + Vector2(int(10*S), int(-3*S)), p + Vector2(int(10*S), int(-18*S)), Color(0.7, 0.6, 0.3, al), 2)
	elif human:
		draw_rect(Rect2(p + Vector2(int(-4*S), int(4*S)),  Vector2(int(4*S), int(6*S))), armor_col)
		draw_rect(Rect2(p + Vector2(int(1*S),  int(4*S)),  Vector2(int(4*S), int(6*S))), armor_col)
		draw_rect(Rect2(p + Vector2(int(-5*S), int(-4*S)), Vector2(int(10*S), int(9*S))), body_col)
		draw_rect(Rect2(p + Vector2(int(-5*S), int(-4*S)), Vector2(int(10*S), int(5*S))), armor_col)
		draw_rect(Rect2(p + Vector2(int(-9*S), int(-4*S)), Vector2(int(4*S), int(7*S))), armor_col)
		draw_rect(Rect2(p + Vector2(int(5*S),  int(-4*S)), Vector2(int(4*S), int(7*S))), armor_col)
		draw_line(p + Vector2(int(9*S), int(-2*S)),  p + Vector2(int(9*S),  int(-16*S)), Color(0.8, 0.8, 0.85, al), 2)
		draw_line(p + Vector2(int(6*S), int(-9*S)),  p + Vector2(int(12*S), int(-9*S)),  Color(0.7, 0.55, 0.3, al), 2)
		draw_circle(p + Vector2(0, int(-8*S)), int(5*S), skin_col)
		draw_arc(p   + Vector2(0, int(-8*S)), int(5*S), PI, 2*PI, 16, armor_col, int(4*S))
		draw_rect(Rect2(p + Vector2(int(-6*S), int(-15*S)), Vector2(int(12*S), int(4*S))), armor_col)
		draw_line(p + Vector2(int(-3*S), int(-9*S)), p + Vector2(int(3*S), int(-9*S)), Color(0.1, 0.1, 0.15, al), 1)
	else:
		draw_rect(Rect2(p + Vector2(int(-7*S), int(4*S)),  Vector2(int(5*S), int(8*S))), Color(0.32, 0.22, 0.10, al))
		draw_rect(Rect2(p + Vector2(int(2*S),  int(4*S)),  Vector2(int(5*S), int(8*S))), Color(0.32, 0.22, 0.10, al))
		draw_rect(Rect2(p + Vector2(int(-8*S), int(-6*S)), Vector2(int(16*S), int(11*S))), body_col)
		draw_rect(Rect2(p + Vector2(int(-8*S), int(-6*S)), Vector2(int(16*S), int(5*S))), armor_col)
		draw_rect(Rect2(p + Vector2(int(-13*S),int(-6*S)), Vector2(int(5*S), int(9*S))), body_col)
		draw_rect(Rect2(p + Vector2(int(8*S),  int(-6*S)), Vector2(int(5*S), int(9*S))), body_col)
		draw_line(p + Vector2(int(13*S), int(-14*S)), p + Vector2(int(13*S), int(3*S)),   Color(0.55, 0.45, 0.35, al), 3)
		draw_arc(p  + Vector2(int(17*S), int(-14*S)), int(6*S), PI*0.5, PI*1.5, 8, Color(0.72, 0.67, 0.6, al), int(4*S))
		draw_circle(p + Vector2(0, int(-11*S)), int(7*S), skin_col)
		draw_line(p + Vector2(int(-4*S), int(-7*S)), p + Vector2(int(-7*S), int(-2*S)), Color(0.9, 0.85, 0.7, al), 2)
		draw_line(p + Vector2(int(4*S),  int(-7*S)), p + Vector2(int(7*S),  int(-2*S)), Color(0.9, 0.85, 0.7, al), 2)
		draw_line(p + Vector2(int(-5*S), int(-12*S)), p + Vector2(int(-2*S), int(-12*S)), Color(0.8, 0.1, 0.1, al), 2)
		draw_line(p + Vector2(int(2*S),  int(-12*S)), p + Vector2(int(5*S),  int(-12*S)), Color(0.8, 0.1, 0.1, al), 2)
		draw_rect(Rect2(p + Vector2(int(-8*S), int(-19*S)), Vector2(int(16*S), int(4*S))), armor_col)
		draw_line(p + Vector2(int(-7*S), int(-18*S)), p + Vector2(int(-12*S), int(-27*S)), Color(0.85, 0.8, 0.65, al), 3)
		draw_line(p + Vector2(int(7*S),  int(-18*S)), p + Vector2(int(12*S),  int(-27*S)), Color(0.85, 0.8, 0.65, al), 3)

	if u.hp < u.max_hp or u.state == "combat":
		var bw = int(22 * S)
		var bp = p + Vector2(-bw / 2, int(-26 * S))
		draw_rect(Rect2(bp, Vector2(bw, 3)), Color(0.2, 0.0, 0.0, al))
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
