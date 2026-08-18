class_name WalkerVisual
extends Node3D
## Pure presentation. Reads WalkerBody (position, heading, feet, gait), never
## writes back.
##
## The jaguar identity lives in the spine: the chassis is two segments around
## a central pivot. Flex is derived from where the feet actually are — hinds
## gathered under the body + fronts pulled back = arch; fronts reaching +
## hinds trailing = extension. No clock, no keyframes: the spine follows the
## legs, so it engages automatically as the gait opens up and blends smoothly
## through transitions. Weight cues: support settle, lean over the loaded
## side, yaw lag, nose pitch under acceleration.

var body: WalkerBody

## ---------------------------------------------------------------------------
## PLACEHOLDER NUMBERS — UNTUNED.
## ---------------------------------------------------------------------------
const SEG_SIZE := Vector3(1.5, 0.66, 1.24)  # each spine segment's hull
const CHASSIS_HEIGHT := 1.5
const HIP_HEIGHT := 1.25
const UPPER_LEN := 0.72
const LOWER_LEN := 0.78
const STEP_HEIGHT := 0.28
const FLEX_K := 0.55            # spine flex per metre of front/hind asymmetry
const FLEX_MAX := 0.38
const FLEX_GAIT_ON := 0.8       # spine engages as gait passes this...
const FLEX_GAIT_FULL := 2.0     # ...fully by this
const FLEX_SMOOTH := 10.0
const SETTLE_DEPTH := 0.09      # chassis sink at zero support
const DIP_K := 70.0
const DIP_D := 11.0
## Chassis yaw lag behind heading, in radians at full steering deflection.
## The follow rate is DERIVED from the sim's turn rate (steady-state lag =
## turn_rate / follow_rate) so that retuning steering cannot silently leave
## the body pointing the wrong way — which is what happened when TURN_RATE
## was tripled against a follow rate tuned for the old value.
const YAW_LAG_RAD := 0.22
const LEAN_K := 0.22            # roll toward the support centroid (rad/m)
const PITCH_ACCEL := 0.035
## ---------------------------------------------------------------------------


class LegMeshes:
	extends RefCounted
	var upper: MeshInstance3D
	var lower: MeshInstance3D
	var pad: MeshInstance3D


# Output-side assertion: worst single-frame knee position jump (metres),
# teleports excluded. A snap in the rendered legs shows here even when every
# sim-side metric looks clean.
var max_knee_frame_jump := 0.0

# Output-side assertion: worst hip-to-foot distance as a fraction of total
# leg length. Must stay <= 1.0 — anything above means the sim asked for a
# foot the leg cannot reach, which renders as a stretched limb.
var max_leg_extension := 0.0
var max_leg_extension_state := ""

var _legs: Array[LegMeshes] = []
var _prev_knees: Array = []
var _prev_body_pos := Vector3.INF
var _settle_frames := 0  # grace after a teleport; both metrics are meaningless there
var _chassis: Node3D
var _fore: Node3D
var _hind: Node3D
var _yaw := 0.0
var _dip := 0.0
var _dip_vel := 0.0
var _lean := 0.0
var _flex := 0.0
var _acc_smooth := Vector3.ZERO
var _prev_hvel := Vector3.ZERO


func _ready() -> void:
	_build_chassis()
	var leg_mat := StandardMaterial3D.new()
	leg_mat.albedo_color = Color(0.28, 0.29, 0.31)
	leg_mat.roughness = 0.7
	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color = Color(0.16, 0.17, 0.18)
	pad_mat.roughness = 0.9
	for i in 4:
		var lm := LegMeshes.new()
		lm.upper = _make_limb_mesh(0.2, leg_mat)
		lm.lower = _make_limb_mesh(0.15, leg_mat)
		var pm := BoxMesh.new()
		pm.size = Vector3(0.3, 0.12, 0.38)
		lm.pad = MeshInstance3D.new()
		lm.pad.mesh = pm
		lm.pad.material_override = pad_mat
		add_child(lm.pad)
		_legs.append(lm)
	_yaw = body.heading


func _process(dt: float) -> void:
	if body == null:
		return
	var hvel := Vector3(body.linear_velocity.x, 0.0, body.linear_velocity.z)

	_yaw = lerp_angle(_yaw, body.heading, 1.0 - exp(-(body.TURN_RATE / YAW_LAG_RAD) * dt))
	if dt > 0.0001:
		_acc_smooth = _acc_smooth.lerp((hvel - _prev_hvel) / dt, 1.0 - exp(-6.0 * dt))
	_prev_hvel = hvel

	# Support settle: sink when support is thin, through an overdamped spring.
	var settle_target := -SETTLE_DEPTH * (1.0 - body.planted_fraction)
	_dip_vel += (DIP_K * (settle_target - _dip) - DIP_D * _dip_vel) * dt
	_dip += _dip_vel * dt

	# Lean over the side that carries the weight.
	var centroid := Vector3.ZERO
	var planted := 0
	for i in 4:
		if not body.feet[i].swinging:
			centroid += body.feet[i].pos
			planted += 1
	var lean_target := 0.0
	if planted > 0:
		centroid /= planted
		var side := (centroid - body.global_position).dot(Basis(Vector3.UP, _yaw).x)
		lean_target = clampf(-side * LEAN_K, -0.12, 0.12)
	_lean = lerpf(_lean, lean_target, 1.0 - exp(-5.0 * dt))

	# Spine flex from the feet themselves: gathered = arch, reaching = extend.
	var inv := Basis(Vector3.UP, -_yaw)
	var front_dz := 0.0
	var hind_dz := 0.0
	for i in 4:
		var local := inv * (body.feet[i].pos - Vector3(body.global_position.x, 0, body.global_position.z))
		var rest_z: float = body.FEET_LOCAL[i].z
		if body.IS_HIND[i]:
			hind_dz += (local.z - rest_z) * 0.5
		else:
			front_dz += (local.z - rest_z) * 0.5
	var engage := clampf((body.gait - FLEX_GAIT_ON) / (FLEX_GAIT_FULL - FLEX_GAIT_ON), 0.0, 1.0)
	var flex_target := clampf((front_dz - hind_dz) * FLEX_K, -FLEX_MAX, FLEX_MAX) * engage
	if not body.grounded:
		flex_target = 0.0  # no in-flight spine pose is authored; don't let feet invent one
	_flex = lerpf(_flex, flex_target, 1.0 - exp(-FLEX_SMOOTH * dt))

	var fwd := body.forward()
	var pitch := clampf(_acc_smooth.dot(fwd) * PITCH_ACCEL, -0.12, 0.12)
	var xf := Transform3D(Basis.from_euler(Vector3(pitch, _yaw, _lean)),
		Vector3(body.global_position.x, body.global_position.y + (CHASSIS_HEIGHT - body.RIDE_HEIGHT) + _dip, body.global_position.z))
	_chassis.global_transform = xf
	_fore.rotation.x = -_flex * 0.5
	_hind.rotation.x = _flex * 0.5

	if not _prev_body_pos.is_finite() or (body.global_position - _prev_body_pos).length() > 2.0:
		_settle_frames = 4
	else:
		_settle_frames = maxi(_settle_frames - 1, 0)

	for i in 4:
		var foot_state: WalkerBody.Foot = body.feet[i]
		var foot := foot_state.pos
		if foot_state.swinging:
			foot.y += sin(foot_state.swing_t * PI) * STEP_HEIGHT
		var anchor: Vector3 = body.FEET_LOCAL[i]
		var seg := _hind if body.IS_HIND[i] else _fore
		var hip := seg.global_transform * Vector3(anchor.x, HIP_HEIGHT - CHASSIS_HEIGHT, anchor.z)
		# Measure what the sim asked for, then render only what the leg can
		# actually do. Without the clamp an unreachable foot renders as a
		# stretched shin; without the measurement the stretch is invisible.
		var reach := UPPER_LEN + LOWER_LEN
		var ext := (foot - hip).length() / reach
		if ext > max_leg_extension and _settle_frames == 0:
			max_leg_extension = ext
			var horiz := Vector2(foot.x - hip.x, foot.z - hip.z).length()
			max_leg_extension_state = "%s leg%d %s horiz=%.2f vert=%.2f gait=%.2f" % [
				body.state_name(), i, "swing" if foot_state.swinging else "plant",
				horiz, hip.y - foot.y, body.gait]
		foot = hip + (foot - hip).limit_length(reach * 0.99)
		_render_leg(_legs[i], hip, foot, signf(anchor.x), i)
	_prev_body_pos = body.global_position


func _track_knee(i: int, knee: Vector3) -> void:
	if _prev_knees.size() < 4:
		_prev_knees.resize(4)
		for k in 4:
			_prev_knees[k] = Vector3.INF
	var prev: Vector3 = _prev_knees[i]
	if prev.is_finite() and _settle_frames == 0:
		max_knee_frame_jump = maxf(max_knee_frame_jump, (knee - prev).length())
	_prev_knees[i] = knee


func _render_leg(lm: LegMeshes, hip: Vector3, foot: Vector3, side: float, leg_index: int) -> void:
	# Knees bow mostly rearward, slightly outward.
	var hint := _chassis.global_transform.basis * Vector3(side * 0.25, 0.0, 0.9)
	var knee := _solve_knee(hip, foot, hint)
	_track_knee(leg_index, knee)
	_place_limb(lm.upper, hip, knee)
	_place_limb(lm.lower, knee, foot + Vector3(0, 0.06, 0))
	lm.pad.global_position = foot + Vector3(0, 0.06, 0)
	lm.pad.global_transform.basis = Basis(Vector3.UP, _yaw)


## Closed-form two-bone IK: returns the knee position, bowing toward `hint`.
func _solve_knee(hip: Vector3, foot: Vector3, hint: Vector3) -> Vector3:
	var to_foot := foot - hip
	var d := clampf(to_foot.length(), 0.05, UPPER_LEN + LOWER_LEN - 0.01)
	var dir := to_foot.normalized()
	var cos_a := clampf((UPPER_LEN * UPPER_LEN + d * d - LOWER_LEN * LOWER_LEN) / (2.0 * UPPER_LEN * d), -1.0, 1.0)
	var a := acos(cos_a)
	var axis := dir.cross(hint)
	if axis.length() < 0.001:
		axis = dir.cross(Vector3.RIGHT)
		if axis.length() < 0.001:
			axis = dir.cross(Vector3.FORWARD)
	axis = axis.normalized()
	return hip + dir.rotated(axis, a) * UPPER_LEN


func _make_limb_mesh(thickness: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(thickness, thickness, 1.0)
	m.mesh = box
	m.material_override = mat
	add_child(m)
	return m


## Stretch a unit-Z box between two points.
func _place_limb(m: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var seg := from - to
	var seg_len := seg.length()
	if seg_len < 0.01:
		return
	var zaxis := seg / seg_len
	var helper := Vector3.UP if absf(zaxis.y) < 0.9 else Vector3(0, 0, 1)
	var xaxis := helper.cross(zaxis).normalized()
	var yaxis := zaxis.cross(xaxis)
	m.global_transform = Transform3D(Basis(xaxis, yaxis, zaxis).scaled(Vector3(1, 1, seg_len)), (from + to) * 0.5)


func _build_chassis() -> void:
	_chassis = Node3D.new()
	add_child(_chassis)
	_fore = Node3D.new()
	_hind = Node3D.new()
	_chassis.add_child(_fore)
	_chassis.add_child(_hind)

	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.5, 0.51, 0.53)
	body_mat.roughness = 0.65

	var fore_hull := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = SEG_SIZE
	fore_hull.mesh = fm
	fore_hull.position = Vector3(0, 0, -SEG_SIZE.z * 0.5)
	fore_hull.material_override = body_mat
	_fore.add_child(fore_hull)

	var hind_hull := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = SEG_SIZE
	hind_hull.mesh = hm
	hind_hull.position = Vector3(0, 0, SEG_SIZE.z * 0.5)
	hind_hull.material_override = body_mat
	_hind.add_child(hind_hull)

	# Orientation marker on the fore segment.
	var nose_mat := StandardMaterial3D.new()
	nose_mat.albedo_color = Color(0.85, 0.6, 0.2)
	var nose := MeshInstance3D.new()
	var nm := BoxMesh.new()
	nm.size = Vector3(0.6, 0.2, 0.45)
	nose.mesh = nm
	nose.position = Vector3(0, SEG_SIZE.y * 0.5 + 0.1, -SEG_SIZE.z + 0.25)
	nose.material_override = nose_mat
	_fore.add_child(nose)

	# Cargo deck on the hind segment.
	var deck_mat := StandardMaterial3D.new()
	deck_mat.albedo_color = Color(0.38, 0.39, 0.41)
	var deck := MeshInstance3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(1.1, 0.25, 1.0)
	deck.mesh = dm
	deck.position = Vector3(0, SEG_SIZE.y * 0.5 + 0.12, SEG_SIZE.z * 0.55)
	deck.material_override = deck_mat
	_hind.add_child(deck)
