class_name Yard
extends Node3D
## Hand-authored terraced graybox: an abandoned industrial yard.
## The grammar from the readability learnings: flat floor by default,
## elevation as rectangular plateaus with vertical faces, explicit ramps at
## the gauntlet-measured grade, container blocks as walls. Rendered FACETED —
## per-face normals and flat per-face colors — so every plane reads as one
## tone and every edge draws itself. No contour lines, no gradients.
##
## Exposes height_at(x, z); bakes into a heightfield for collision.

## ---------------------------------------------------------------------------
## PLACEHOLDER NUMBERS — UNTUNED (layout is deliberate, values are not).
## ---------------------------------------------------------------------------
const SIZE := 160.0
const RES := 161
const STEP := 2.5              # metres per level
const RAMP_GRADE_DEG := 18.0   # from the ramp gauntlet: frozen model climbs this easily
## ---------------------------------------------------------------------------

const WALL_COLOR := Color(0.30, 0.27, 0.26)
const RAMP_COLOR := Color(0.60, 0.54, 0.44)
const LEVEL_COLORS := [Color(0.45, 0.50, 0.40), Color(0.55, 0.59, 0.47), Color(0.66, 0.68, 0.55)]

var heights := PackedFloat32Array()


func _ready() -> void:
	heights.resize(RES * RES)
	heights.fill(0.05)  # floor sits proud of the backdrop plane (no z-fight)

	var run := STEP / tan(deg_to_rad(RAMP_GRADE_DEG))  # ~7.7 m per level

	# Plateau A with a second storey B on top; plateau C across the yard.
	_plateau(Rect2(10, -40, 40, 40), 1)
	_plateau(Rect2(25, -35, 20, 20), 2)
	_plateau(Rect2(-45, 15, 30, 30), 1)

	# Ramps (explicit, readable, all at the measured grade).
	_ramp(Rect2(10.0 - run, -30, run, 8), 0, 1, true)    # floor -> A, up eastward
	_ramp(Rect2(25.0 - run, -30, run, 8), 1, 2, true)    # A -> B, up eastward
	_ramp(Rect2(-35, 45, 8, run), 1, 0, false)           # C south edge down to floor

	# Container blocks: an alley chokepoint and a lone crate.
	_plateau(Rect2(-6, -8, 3, 16), 1)
	_plateau(Rect2(6, -8, 3, 16), 1)
	_plateau(Rect2(0, 30, 8, 3), 1)

	_build_mesh()
	_build_collision()


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
			heights[z * RES + x] = level * STEP


## Height interpolates from `from_level` to `to_level` across the rect along
## x (axis_x true) or z.
func _ramp(r: Rect2, from_level: int, to_level: int, axis_x: bool) -> void:
	var c := _cells(r)
	for z in range(c.position.y, c.end.y + 1):
		for x in range(c.position.x, c.end.x + 1):
			var t: float
			if axis_x:
				t = float(x - c.position.x) / maxf(c.end.x - c.position.x, 1)
			else:
				t = float(z - c.position.y) / maxf(c.end.y - c.position.y, 1)
			heights[z * RES + x] = lerpf(from_level * STEP, to_level * STEP, t)


func _build_mesh() -> void:
	# Faceted: unique vertices per triangle, one normal and one flat color
	# per face. Edges appear as shading breaks — no ink required.
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
			_add_face(verts, norms, colors, p00, p10, p01)
			_add_face(verts, norms, colors, p10, p11, p01)

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


func _add_face(verts: PackedVector3Array, norms: PackedVector3Array, colors: PackedColorArray, a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (c - a).cross(b - a).normalized()
	if n.y < 0.0:
		n = -n
	var col: Color
	if n.y < 0.55:
		col = WALL_COLOR
	elif n.y < 0.97:
		col = RAMP_COLOR
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
