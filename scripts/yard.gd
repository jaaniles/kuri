class_name Yard
extends Node3D
## Playable-slice map: a hub and three lanes with opposite demands.
##   FLOW    rolling terraced crests and ramps - reward for never braking,
##           reading ground for free speed.
##   COMMIT  climb, choke, leap gap, drops - reward for braking early and
##           committing; failing the leap drops you to a slow ground route.
##   GRIND   soft field crossed by a firm winding ribbon with slick patches -
##           momentum is a resource; the fast line must be read.
## Grammar per the readability learnings: flat floor, rectangular plateaus,
## vertical faces, explicit ramps, faceted per-face shading, zero ink.

## ---------------------------------------------------------------------------
## PLACEHOLDER NUMBERS - UNTUNED (layout deliberate, values not).
## ---------------------------------------------------------------------------
const SIZE := 192.0
const RES := 193
const STEP := 2.5
## ---------------------------------------------------------------------------

enum { SURF_HARD, SURF_SOFT, SURF_SLICK }

const LANES := [
	{"name": "FLOW", "x0": -84.0, "x1": -52.0},
	{"name": "COMMIT", "x0": -16.0, "x1": 16.0},
	{"name": "GRIND", "x0": 52.0, "x1": 84.0},
]
const LANE_Z_START := 52.0
const LANE_Z_END := -76.0

const WALL_COLOR := Color(0.30, 0.27, 0.26)
const RAMP_COLOR := Color(0.63, 0.59, 0.52)
const LEVEL_COLORS := [Color(0.45, 0.50, 0.40), Color(0.55, 0.59, 0.47), Color(0.66, 0.68, 0.55), Color(0.72, 0.70, 0.58)]
const SOFT_COLOR := Color(0.47, 0.38, 0.28)
const SLICK_COLOR := Color(0.60, 0.68, 0.74)

var heights := PackedFloat32Array()
var surfaces := PackedByteArray()


func _ready() -> void:
	heights.resize(RES * RES)
	heights.fill(0.05)  # floor sits proud of the backdrop plane
	surfaces.resize(RES * RES)
	surfaces.fill(SURF_HARD)

	_build_perimeter()
	_build_lane_walls()
	_build_flow()
	_build_commit()
	_build_grind()
	_build_labels()

	_build_mesh()
	_build_collision()


## ------------------------------------------------------------ QUERIES -----
func height_at(wx: float, wz: float) -> float:
	var fx := clampf(wx + SIZE * 0.5, 0.0, RES - 1.001)
	var fz := clampf(wz + SIZE * 0.5, 0.0, RES - 1.001)
	var x0 := int(fx)
	var z0 := int(fz)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var h00 := heights[z0 * RES + x0]
	var h10 := heights[z0 * RES + x0 + 1]
	var h01 := heights[(z0 + 1) * RES + x0]
	var h11 := heights[(z0 + 1) * RES + x0 + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func surface_at(wx: float, wz: float) -> int:
	var xi := clampi(roundi(wx + SIZE * 0.5), 0, RES - 1)
	var zi := clampi(roundi(wz + SIZE * 0.5), 0, RES - 1)
	return surfaces[zi * RES + xi]


func normal_at(wx: float, wz: float) -> Vector3:
	var e := 0.6
	var hx := height_at(wx - e, wz) - height_at(wx + e, wz)
	var hz := height_at(wx, wz - e) - height_at(wx, wz + e)
	return Vector3(hx, 2.0 * e, hz).normalized()


## ------------------------------------------------------------- STAMPS -----
func _cells(r: Rect2) -> Rect2i:
	var half := SIZE * 0.5
	return Rect2i(
		Vector2i(clampi(roundi(r.position.x + half), 0, RES - 1), clampi(roundi(r.position.y + half), 0, RES - 1)),
		Vector2i(0, 0)).expand(
		Vector2i(clampi(roundi(r.end.x + half), 0, RES - 1), clampi(roundi(r.end.y + half), 0, RES - 1)))


func _plateau(r: Rect2, level: int) -> void:
	var c := _cells(r)
	for z in range(c.position.y, c.end.y + 1):
		for x in range(c.position.x, c.end.x + 1):
			heights[z * RES + x] = maxf(level * STEP, 0.05)


## Height lerps from `from_level` (min index side) to `to_level` (max index
## side) along x (axis_x) or z.
func _ramp(r: Rect2, from_level: int, to_level: int, axis_x: bool) -> void:
	var c := _cells(r)
	for z in range(c.position.y, c.end.y + 1):
		for x in range(c.position.x, c.end.x + 1):
			var t: float
			if axis_x:
				t = float(x - c.position.x) / maxf(c.end.x - c.position.x, 1)
			else:
				t = float(z - c.position.y) / maxf(c.end.y - c.position.y, 1)
			heights[z * RES + x] = maxf(lerpf(from_level * STEP, to_level * STEP, t), 0.05)


func _paint(r: Rect2, surf: int) -> void:
	var c := _cells(r)
	for z in range(c.position.y, c.end.y + 1):
		for x in range(c.position.x, c.end.x + 1):
			surfaces[z * RES + x] = surf


## -------------------------------------------------------------- LAYOUT ----
func _build_perimeter() -> void:
	_plateau(Rect2(-96, -96, 192, 8), 2)
	_plateau(Rect2(-96, 88, 192, 8), 2)
	_plateau(Rect2(-96, -96, 8, 192), 2)
	_plateau(Rect2(88, -96, 8, 192), 2)


func _build_lane_walls() -> void:
	for pair in [[-88.0, -84.0], [-52.0, -48.0], [-20.0, -16.0], [16.0, 20.0], [48.0, 52.0], [84.0, 88.0]]:
		_plateau(Rect2(pair[0], -88, pair[1] - pair[0], 146), 2)


func _build_flow() -> void:
	# Three rollers; the middle one climbs two levels and pays out a long
	# double-length descent. 14 degree grades (run 10 m per level).
	_ramp(Rect2(-84, 30, 32, 10), 1, 0, false)   # up A (north side high)
	_plateau(Rect2(-84, 24, 32, 6), 1)           # crest A
	_ramp(Rect2(-84, 14, 32, 10), 0, 1, false)   # down A
	_ramp(Rect2(-84, -2, 32, 10), 1, 0, false)   # up B1
	_plateau(Rect2(-84, -6, 32, 4), 1)
	_ramp(Rect2(-84, -16, 32, 10), 2, 1, false)  # up B2
	_plateau(Rect2(-84, -20, 32, 4), 2)          # crest B (L2)
	_ramp(Rect2(-84, -36, 32, 16), 0, 2, false)  # long descent, ~18 deg: slide payoff
	_ramp(Rect2(-84, -58, 32, 10), 1, 0, false)  # up C
	_plateau(Rect2(-84, -60, 32, 2), 1)
	_ramp(Rect2(-84, -70, 32, 10), 0, 1, false)  # down C


func _build_commit() -> void:
	# Ramp up to tower A (L2), choke on top, 5 m leap gap to tower B,
	# then a 5 m drop to the floor sprint. Failing the leap lands in the
	# pit at floor level - side corridors let you continue, slowly.
	_ramp(Rect2(-6, -8, 12, 16), 2, 0, false)    # 18 degree, two levels
	_plateau(Rect2(-12, -28, 24, 20), 2)         # tower A
	_plateau(Rect2(-12, -16, 8, 3), 3)           # choke block west
	_plateau(Rect2(4, -16, 8, 3), 3)             # choke block east
	_plateau(Rect2(-12, -53, 24, 20), 2)         # tower B (gap z -33..-28)


func _build_grind() -> void:
	_paint(Rect2(52, -70, 32, 118), SURF_SOFT)
	# Firm ribbon, 5 m wide, winding; two slick crossings.
	_paint(Rect2(62, 30, 5, 18), SURF_HARD)
	_paint(Rect2(62, 26, 17, 4), SURF_HARD)
	_paint(Rect2(74, 6, 5, 20), SURF_HARD)
	_paint(Rect2(56, 2, 23, 4), SURF_HARD)
	_paint(Rect2(56, -18, 5, 20), SURF_HARD)
	_paint(Rect2(56, -22, 19, 4), SURF_SLICK)
	_paint(Rect2(70, -42, 5, 20), SURF_HARD)
	_paint(Rect2(60, -46, 15, 4), SURF_SLICK)
	_paint(Rect2(60, -66, 5, 20), SURF_HARD)
	_paint(Rect2(52, -76, 32, 10), SURF_HARD)


func _build_labels() -> void:
	for l in LANES:
		var cx: float = (l.x0 + l.x1) * 0.5
		_label(l.name, Vector3(cx, 0.3, 49.0))


func _label(text: String, pos: Vector3) -> void:
	var lb := Label3D.new()
	lb.text = text
	lb.font_size = 320
	lb.pixel_size = 0.02
	lb.modulate = Color(0.15, 0.15, 0.14)
	lb.rotation_degrees = Vector3(-90, 0, 0)
	lb.position = pos
	add_child(lb)


## ---------------------------------------------------------------- MESH ----
func _build_mesh() -> void:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var colors := PackedColorArray()
	var half := SIZE * 0.5
	for z in RES - 1:
		for x in RES - 1:
			var p00 := Vector3(x - half, heights[z * RES + x], z - half)
			var p10 := Vector3(x + 1 - half, heights[z * RES + x + 1], z - half)
			var p01 := Vector3(x - half, heights[(z + 1) * RES + x], z + 1 - half)
			var p11 := Vector3(x + 1 - half, heights[(z + 1) * RES + x + 1], z + 1 - half)
			var surf := surfaces[z * RES + x]
			_add_face(verts, norms, colors, p00, p10, p01, surf)
			_add_face(verts, norms, colors, p10, p11, p01, surf)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = colors
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 1.0
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	add_child(mi)


func _add_face(verts: PackedVector3Array, norms: PackedVector3Array, colors: PackedColorArray, a: Vector3, b: Vector3, c: Vector3, surf: int) -> void:
	var n := (c - a).cross(b - a).normalized()
	if n.y < 0.0:
		n = -n
	var col: Color
	if n.y < 0.55:
		col = WALL_COLOR
	elif n.y < 0.97:
		col = RAMP_COLOR
	elif surf == SURF_SOFT:
		col = SOFT_COLOR
	elif surf == SURF_SLICK:
		col = SLICK_COLOR
	else:
		var lv := clampi(roundi((a.y + b.y + c.y) / 3.0 / STEP), 0, LEVEL_COLORS.size() - 1)
		col = LEVEL_COLORS[lv]
	verts.append(a)
	verts.append(b)
	verts.append(c)
	for i in 3:
		norms.append(n)
		colors.append(col)


func _build_collision() -> void:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := HeightMapShape3D.new()
	shape.map_width = RES
	shape.map_depth = RES
	shape.map_data = heights
	col.shape = shape
	body.add_child(col)
	add_child(body)
