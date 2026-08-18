class_name WalkerBody
extends RigidBody3D
## Physics proxy: invisible sphere on a spring ray, feet as sim state.
##
## Locomotion is ONE continuous system, parameterized by actual body speed.
## No modes, no buttons: W asks for speed, the gait organizes itself.
##
##   gait 0..1..2  =  walk .. trot .. gallop   (from measured speed, smoothed)
##
## The foundation is clockless distance-triggered stepping: a foot stays
## planted until the body carries it to the edge of its range, then steps —
## full range every time. What changes along the gait parameter is the RULES:
##
##   WALK    strict 4-beat: one foot in the air at a time. Deliberate.
##   TROT    diagonal pairs swing together; the next pair may lift while the
##           previous is late in its swing -> brief full-suspension windows.
##   GALLOP  rotary, cat-style: hind pair syncs (one hind lifting drops its
##           mate's trigger threshold), fronts stagger via a lead-side bias
##           (lead follows steering). Support floor 0; two short suspension
##           windows per cycle emerge from swing overlap. The body never
##           launches — flight is leg choreography, not ballistics.
##
## Duty factor (fraction of a cycle a foot is planted) is THE gait-blended
## quantity; swing time derives from it, so stride length grows with speed
## through air time — the cat way — instead of legs cycling faster.
##
## Drive force enters only through planted feet, shaped over the stance sweep;
## stride power grows with gait (placeholder scaling) so upper bands are
## reachable. Steering authority remains proportional to planted support.

enum Regime { WALK, TROT, GALLOP }

## ---------------------------------------------------------------------------
## PLACEHOLDER NUMBERS — UNTUNED.
## ---------------------------------------------------------------------------
const RIDE_HEIGHT := 1.05
const SPRING_K := 120.0
const SPRING_D := 18.0
const GROUND_RAY_LEN := 2.5
# Shared leg geometry (visual layer reads these).
const HIP_HEIGHT := 1.25
const UPPER_LEN := 0.72
const LOWER_LEN := 0.78
# Gait bands (m/s) and smoothing.
const WALK_TOP := 1.6
const TROT_TOP := 4.2
const G_SMOOTH := 2.5           # gait parameter chase rate (1/s)
const REGIME_HYST := 0.08
# Stepping.
const STEP_RANGE := 0.55
const OVERSTRETCH := 1.6
const DUTY_WALK := 0.68
const DUTY_TROT := 0.52
const DUTY_GALLOP := 0.32
const MIN_SWING := 0.08
const MAX_SWING := 0.6
# Coordination.
const HIND_SYNC := 0.55         # hind mate's trigger factor once one hind lifts
const LEAD_BIAS := 0.85         # lead front triggers early...
const TRAIL_BIAS := 1.05        # ...trailing front late (rotary stagger)
const TROT_JOIN := 0.65         # trot: co-swing allowed with feet past this swing_t
const GALLOP_JOIN := 0.5
# Force.
const THRUST_PER_LEG := 1.2
const THRUST_GAIT := 0.5        # thrust *= (1 + this * gait)
const BRAKE_PER_LEG := 2.0
const REVERSE_FACTOR := 0.5
const DRAG := 0.7
const GRIP := 6.0
const TURN_RATE := 0.9
## ---------------------------------------------------------------------------

# FL, FR, BL, BR. Diagonals 0-3 / 1-2; lateral pairs 0-1 (front), 2-3 (hind).
const FEET_LOCAL := [Vector3(-0.82, 0, -0.95), Vector3(0.82, 0, -0.95), Vector3(-0.82, 0, 0.95), Vector3(0.82, 0, 0.95)]
const DIAG := [3, 2, 1, 0]
const PAIR := [1, 0, 3, 2]
const IS_HIND := [false, false, true, true]


class Foot:
	extends RefCounted
	var pos := Vector3.ZERO
	var swinging := false
	var swing_t := 0.0
	var swing_dur := 0.3
	var swing_from := Vector3.ZERO
	var swing_to := Vector3.ZERO
	var last_step_len := 0.0


# Optional ground provider (anything with height_at(x, z)). When null the
# world is flat at y=0 — exactly the approved baseline behavior.
var ground: Node3D = null
var heading := 0.0
var feet: Array[Foot] = []
var planted_fraction := 1.0
var grounded := false
var gait := 0.0                 # continuous: 0 walk, 1 trot, 2 gallop
var regime := Regime.WALK
var lead_side := -1             # -1: left front leads, +1: right front
var step_count := 0

var _tick := 0
var _log: FileAccess
var _elog: FileAccess


func _ready() -> void:
	var col := CollisionShape3D.new()
	var s := SphereShape3D.new()
	s.radius = 0.55
	col.shape = s
	add_child(col)
	axis_lock_angular_x = true
	axis_lock_angular_y = true
	axis_lock_angular_z = true
	can_sleep = false
	for i in 4:
		var f := Foot.new()
		f.pos = _home(i)
		feet.append(f)


func forward() -> Vector3:
	return Vector3(-sin(heading), 0.0, -cos(heading))


## Test-harness support: plant all feet at their homes after a teleport.
## Never called during normal play.
func snap_feet() -> void:
	for i in 4:
		feet[i].swinging = false
		feet[i].swing_t = 0.0
		feet[i].pos = _home(i)


func _ground_h(wx: float, wz: float) -> float:
	return ground.height_at(wx, wz) if ground != null else 0.0


func _home(i: int) -> Vector3:
	var off := Basis(Vector3.UP, heading) * (FEET_LOCAL[i] as Vector3)
	var wx := global_position.x + off.x
	var wz := global_position.z + off.z
	return Vector3(wx, _ground_h(wx, wz), wz)


func _physics_process(dt: float) -> void:
	_tick += 1

	# --- Suspension. ---
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(global_position, global_position + Vector3.DOWN * GROUND_RAY_LEN)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	grounded = not hit.is_empty() and global_position.y - hit.position.y < RIDE_HEIGHT + 0.4
	if grounded:
		var compression: float = RIDE_HEIGHT - (global_position.y - hit.position.y)
		apply_central_force(Vector3.UP * maxf(SPRING_K * compression - SPRING_D * linear_velocity.y, -40.0))

	# --- Inputs. ---
	var throttle := Input.get_action_strength("throttle")
	var brake := Input.get_action_strength("brake")
	var steer := Input.get_axis("turn_right", "turn_left")
	var hvel := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var hspeed := hvel.length()
	var reversing := brake > 0.0 and hspeed < 0.4

	# --- Gait parameter follows MEASURED speed. Input never touches it. ---
	var g_target: float
	if hspeed <= WALK_TOP:
		g_target = hspeed / WALK_TOP
	else:
		g_target = 1.0 + clampf((hspeed - WALK_TOP) / (TROT_TOP - WALK_TOP), 0.0, 1.0)
	gait = move_toward(gait, g_target, G_SMOOTH * dt)
	match regime:
		Regime.WALK:
			if gait > 0.5 + REGIME_HYST:
				regime = Regime.TROT
		Regime.TROT:
			if gait < 0.5 - REGIME_HYST:
				regime = Regime.WALK
			elif gait > 1.5 + REGIME_HYST:
				regime = Regime.GALLOP
		Regime.GALLOP:
			if gait < 1.5 - REGIME_HYST:
				regime = Regime.TROT
	if absf(steer) > 0.3:
		lead_side = -1 if steer > 0.0 else 1  # lead into the turn

	# --- Support + steering through planted feet. ---
	var planted := 0
	for f in feet:
		if not f.swinging:
			planted += 1
	planted_fraction = planted / 4.0
	heading = wrapf(heading + steer * TURN_RATE * planted_fraction * dt, -PI, PI)
	var fwd := forward()

	# --- Advance swings. ---
	for i in 4:
		var f := feet[i]
		if f.swinging:
			f.swing_t += dt / f.swing_dur
			if f.swing_t >= 1.0:
				f.swinging = false
				f.pos = f.swing_to
				_event("footfall", i, f.last_step_len, hspeed)
			else:
				var t := f.swing_t * f.swing_t * (3.0 - 2.0 * f.swing_t)
				f.pos = f.swing_from.lerp(f.swing_to, t)

	if grounded:
		_step_triggers(hvel)
		_stance_forces(hvel, hspeed, fwd, throttle, brake, reversing)
		# Resistance and grip as forces (never write linear_velocity — the
		# property is a pre-tick cache; writes clobber this tick's forces).
		apply_central_force(-hvel * DRAG * planted_fraction * mass)
		var lat := hvel - fwd * hvel.dot(fwd)
		apply_central_force(-lat * GRIP * planted_fraction * mass)

	_log_tick(hspeed, throttle)


## ------------------------------------------------------------- STEPPING ---
func _support_floor() -> int:
	match regime:
		Regime.WALK:
			return 3  # strict 4-beat: one foot in the air at a time
		Regime.TROT:
			return 1
		_:
			return 0


func _trigger_factor(i: int) -> float:
	if regime != Regime.GALLOP:
		return 1.0
	if IS_HIND[i]:
		# Hind pair syncs: once one lifts, its mate follows almost at once.
		return HIND_SYNC if feet[PAIR[i]].swinging else 1.0
	var is_lead := (i == 0 and lead_side == -1) or (i == 1 and lead_side == 1)
	return LEAD_BIAS if is_lead else TRAIL_BIAS


func _may_lift(i: int) -> bool:
	for j in 4:
		if j == i or not feet[j].swinging:
			continue
		match regime:
			Regime.WALK:
				if j != DIAG[i]:
					return false
			Regime.TROT:
				if j != DIAG[i] and feet[j].swing_t < TROT_JOIN:
					return false
			Regime.GALLOP:
				if j != PAIR[i] and feet[j].swing_t < GALLOP_JOIN:
					return false
	return true


func _step_triggers(hvel: Vector3) -> void:
	var order := [0, 1, 2, 3]
	order.sort_custom(func(a, b): return _drift(a) > _drift(b))
	var planted_now := 0
	for f in feet:
		if not f.swinging:
			planted_now += 1
	var floor_n := _support_floor()
	for i in order:
		var f := feet[i]
		if f.swinging:
			continue
		if planted_now - 1 < floor_n:
			continue
		var drift := _drift(i)
		if drift < STEP_RANGE * _trigger_factor(i):
			continue
		if _may_lift(i) or drift > STEP_RANGE * OVERSTRETCH:
			_begin_step(i, hvel)
			planted_now -= 1


func _duty() -> float:
	if gait <= 1.0:
		return lerpf(DUTY_WALK, DUTY_TROT, clampf(gait, 0.0, 1.0))
	return lerpf(DUTY_TROT, DUTY_GALLOP, clampf(gait - 1.0, 0.0, 1.0))


func _begin_step(i: int, hvel: Vector3) -> void:
	var f := feet[i]
	var home := _home(i)
	var vlen := hvel.length()
	var vdir := hvel / vlen if vlen > 0.15 else Vector3.ZERO
	# Swing time from duty: stance sweeps the full range at body speed; the
	# swing takes (1-duty)/duty of that. Air time is where stride length
	# grows with speed.
	var d := _duty()
	var stance_time := (STEP_RANGE * 1.9) / maxf(vlen, 0.3)
	var swing_time := clampf(stance_time * (1.0 - d) / d, MIN_SWING, MAX_SWING)
	var target := home + hvel * swing_time + vdir * STEP_RANGE * 0.9
	f.swinging = true
	f.swing_t = 0.0
	f.swing_from = f.pos
	f.swing_to = Vector3(target.x, _ground_h(target.x, target.z), target.z)
	f.swing_dur = swing_time
	f.last_step_len = (f.swing_to - f.pos).length()
	step_count += 1
	_event("liftoff", i, _drift(i), gait)


func _drift(i: int) -> float:
	var d := feet[i].pos - _home(i)
	return Vector2(d.x, d.z).length()


## ---------------------------------------------------------------- FORCE ---
func _stance_forces(hvel: Vector3, hspeed: float, fwd: Vector3, throttle: float, brake: float, reversing: bool) -> void:
	var travel := hvel / hspeed if hspeed > 0.15 else fwd
	var thrust := THRUST_PER_LEG * (1.0 + THRUST_GAIT * gait)
	for i in 4:
		var f := feet[i]
		if f.swinging:
			continue
		var d_along := (f.pos - _home(i)).dot(travel)
		var p := clampf((d_along + STEP_RANGE) / (2.0 * STEP_RANGE), 0.0, 1.0)
		var shape := sin(p * PI)
		if reversing:
			apply_central_force(-fwd * thrust * REVERSE_FACTOR * brake * shape * mass)
		elif brake > 0.0:
			if hspeed > 0.05:
				apply_central_force(-hvel / hspeed * BRAKE_PER_LEG * brake * shape * mass)
		elif throttle > 0.0:
			apply_central_force(fwd * thrust * throttle * shape * mass)


## ------------------------------------------------------- INSTRUMENTATION --
func enable_logging(dir: String) -> void:
	_log = FileAccess.open(dir.path_join("loco_ticks.csv"), FileAccess.WRITE)
	_log.store_line("tick,gait,regime,speed,vy,y,support,throttle,l0s,l0x,l0z,l0st,l1s,l1x,l1z,l1st,l2s,l2x,l2z,l2st,l3s,l3x,l3z,l3st")
	_elog = FileAccess.open(dir.path_join("loco_events.csv"), FileAccess.WRITE)
	_elog.store_line("tick,event,leg,a,b")


func _event(kind: String, leg: int, a: float, b: float) -> void:
	if _elog:
		_elog.store_line("%d,%s,%d,%.3f,%.3f" % [_tick, kind, leg, a, b])


func _log_tick(hspeed: float, throttle: float) -> void:
	if _log == null:
		return
	var inv := Basis(Vector3.UP, -heading)
	var max_leg := UPPER_LEN + LOWER_LEN
	var parts := PackedStringArray()
	parts.append("%d,%.3f,%d,%.3f,%.3f,%.3f,%.2f,%.2f" % [
		_tick, gait, regime, hspeed, linear_velocity.y, global_position.y, planted_fraction, throttle])
	for i in 4:
		var f := feet[i]
		var local := inv * (f.pos - Vector3(global_position.x, 0, global_position.z))
		var hip := Vector3(FEET_LOCAL[i].x, HIP_HEIGHT, FEET_LOCAL[i].z)
		var stretch := (Vector3(local.x, f.pos.y, local.z) - hip).length() / max_leg
		parts.append("%d,%.2f,%.2f,%.2f" % [1 if f.swinging else 0, local.x, local.z, stretch])
	_log.store_line(",".join(parts))
	if _tick % 120 == 0:
		_log.flush()
		if _elog:
			_elog.flush()
