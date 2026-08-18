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
const REACH_URGENT := 0.88      # extension fraction at which a leg must step regardless of pattern
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
# Launch authority: legs push hardest against a standing body and lose
# purchase as contact time shrinks with speed (muscle force-velocity).
# Raises standstill acceleration without touching top speed, which is set
# by thrust-vs-drag at the high end.
const LAUNCH_BOOST := 1.8
const LAUNCH_FADE := 2.2        # m/s at which the boost is fully gone
const BRAKE_PER_LEG := 2.0
const REVERSE_FACTOR := 0.5
const DRAG := 0.7
const GRIP := 6.0
const TURN_RATE := 2.7          # user-directed: snappy steering
# Verbs (Courier traversal contract on this model). Stance is a hold: lower,
# grip, sharper turning, lower top speed. On a steep descent with speed it
# becomes a controlled slide with carve steering. Leap is a committed launch:
# brief gather, takeoff along current velocity, minimal air authority.
const STANCE_DRAG_MULT := 1.7
const STANCE_GRIP_MULT := 1.9
const STANCE_TURN_MULT := 1.5
const STANCE_THRUST_MULT := 0.6
const STANCE_CROUCH := 0.22
const SLIDE_MIN_SPEED := 3.0
const SLIDE_ENTER_NY := 0.972   # ground normal.y below this (~13.5 deg) allows slide
const SLIDE_EXIT_NY := 0.985
const SLIDE_DRAG := 0.08
const SLIDE_GRIP := 1.6
const SLIDE_TURN := 2.0
const SLIDE_GRAVITY := 3.0      # extra downhill pull while sliding
const GATHER_TIME := 0.22
const LEAP_UP := 4.5
const LEAP_FWD_BASE := 1.2
const LEAP_FWD_SPEED := 0.35
const LEAP_FWD_MAX := 3.5
const LEAP_COOLDOWN := 0.7
# Edge refusal: the machine will not walk off a real cliff without explicit
# consent. A leap press while an edge is ahead ARMS the leap; the machine
# then times its own takeoff at the lip. Refusal braking is capped, so
# arriving recklessly hot can still carry you over — momentum stays honest.
const CLIFF_DROP := 3.0         # drops deeper than this are refused (one terrace stays free)
const CLIFF_BRAKE := 9.0        # refusal braking (m/s^2 cap)
const CLIFF_STOP_MARGIN := 1.1  # aim to stand this far before the lip
const ARM_SCAN := 12.0          # a leap press with an edge within this arms instead of hopping
const STANDING_JUMP_MAX := 3.0  # guided standing jump clears gaps up to this (measured)
const GAP_SCAN := 6.5           # how far past a lip to look for a landable far side
const GUIDED_UP := 5.2          # guided standing jump gets a taller arc
const GUIDED_VMAX := 7.0        # cap on guided launch speed (legality bound)
const AIR_STEER := 0.15
const LAND_RETENTION_HARD := 0.82  # unbraced hard landing bleeds speed
const HARD_LANDING_VY := 4.0
# Airborne legs. Four phases, all derived from existing state — no new clock:
#   PUSH   feet stay world-locked briefly after launch, so the body rising
#          against them reads as the push-off
#   TUCK   ascending: feet fold under the hips, body-relative (this is what
#          stops the feet being glued to the takeoff point)
#   REACH  descending: feet extend toward the predicted touchdown footprint
#   ABSORB contact: feet plant where they land, body dips on the spring
const TAKEOFF_GRACE := 0.25     # suspension stays released this long after launch
const PUSH_HOLD := 0.10         # of which this much is the push-off
const AIR_FOOT_RATE := 9.0      # how fast feet reach their air pose (1/s)
const TUCK_DROP := 0.45         # tucked foot hangs this far below its hip
const TUCK_GATHER := 0.18       # ...and this much inboard and rearward
const FALL_G := 9.8             # gravity used for touchdown prediction only
# Surfaces (index = Yard.SURF_*): hard, soft, slick.
const SURF_DRAG := [1.0, 2.3, 0.55]
const SURF_GRIP := [1.0, 1.15, 0.22]
const SURF_THRUST := [1.0, 0.75, 0.9]
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
var stance_active := false
var sliding := false
var gathering := false
var surface := 0                # Yard.SURF_* under the body
var cliff_ahead := false
var leap_armed := false
var refusing := false
var edge_hint := ""

var _gather_t := 0.0
var _takeoff_t := 0.0  # suspension released briefly at launch, or the spring damper eats the leap
var _leap_cd := 0.0
var _leap_pressed := false
var _intent_t := 0.0   # sticky leap intent after a press near an edge
var _gather_boost := 0.0  # guided standing jump: computed launch speed
var _edge_dir := Vector3.FORWARD
var _edge_dist12 := INF
var _was_grounded := true
var _prev_vy := 0.0
var _slide_exit_t := 0.0
var _cliff_dist := INF
var sim_max_extension := 0.0  # diagnostic: worst hip-to-foot / leg length, sim side

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


## Clear verb state (teleports, resets).
func reset_state() -> void:
	stance_active = false
	sliding = false
	gathering = false
	leap_armed = false
	refusing = false
	_gather_t = 0.0
	_leap_cd = 0.0
	_leap_pressed = false
	_intent_t = 0.0
	_gather_boost = 0.0
	_takeoff_t = 0.0
	gait = 0.0
	regime = Regime.WALK


## Width of the gap past the sensed lip, or -1.0 when no landable far side
## exists within GAP_SCAN (a sheer drop). Uses bilinear height: crisp cells
## quantize back onto the near lip and hallucinate a tiny gap.
func _measure_gap() -> float:
	if ground == null or _edge_dist12 == INF:
		return -1.0
	var here_h: float = ground.height_at(global_position.x, global_position.z)
	var d := _edge_dist12 + 1.0
	while d <= _edge_dist12 + GAP_SCAN:
		var p := global_position + _edge_dir * d
		if here_h - ground.height_at(p.x, p.z) <= 0.6:
			return d - _edge_dist12
		d += 0.5
	return -1.0


## Leap request — from input or the test harness. Processed after edge
## sensing: with an edge within ARM_SCAN this arms intent (the machine times
## its own takeoff); otherwise it hops immediately.
func request_leap() -> void:
	_leap_pressed = true


func state_name() -> String:
	if not grounded:
		return "air"
	if gathering:
		return "gather"
	if leap_armed:
		return "leap armed"
	if refusing:
		return "refusing edge"
	if sliding:
		return "slide"
	if stance_active:
		return "stance"
	return "run"


func _ground_h(wx: float, wz: float) -> float:
	return ground.height_at(wx, wz) if ground != null else 0.0


## World position of leg i's hip.
func _hip_world(i: int) -> Vector3:
	var anchor: Vector3 = FEET_LOCAL[i]
	var off := Basis(Vector3.UP, heading) * anchor
	return Vector3(global_position.x + off.x,
		global_position.y - RIDE_HEIGHT + HIP_HEIGHT,
		global_position.z + off.z)


## Ballistic touchdown estimate: two passes, because the landing height
## depends on where you land. Prediction only — never feeds the sim.
func _predict_landing(hvel: Vector3) -> Vector3:
	var vy := linear_velocity.y
	var gy := _ground_h(global_position.x, global_position.z)
	var t := 0.0
	for _pass in 2:
		var dy := maxf(global_position.y - RIDE_HEIGHT - gy, 0.0)
		t = clampf((vy + sqrt(maxf(vy * vy + 2.0 * FALL_G * dy, 0.0))) / FALL_G, 0.0, 1.5)
		var lp := global_position + hvel * t
		gy = _ground_h(lp.x, lp.z)
	var land := global_position + hvel * t
	return Vector3(land.x, gy, land.z)


## Pull a foot back inside the leg's horizontal reach envelope, keeping it
## at its own height. A leg cannot be longer than itself — swing targets are
## forecast from instantaneous velocity and frozen, so a deceleration during
## the swing would otherwise strand the foot ahead of the body. This is a
## constraint on the result, NOT a re-target: the swing path stays frozen.
func _clamp_to_reach(i: int, p: Vector3) -> Vector3:
	var hip := _hip_world(i)
	var reach := (UPPER_LEN + LOWER_LEN) * 0.95
	var vert := hip.y - p.y
	var max_h := sqrt(maxf(reach * reach - vert * vert, 0.04))
	var d := Vector2(p.x - hip.x, p.z - hip.z)
	if d.length() <= max_h:
		return p
	d = d.normalized() * max_h
	return Vector3(hip.x + d.x, p.y, hip.z + d.y)


## Where foot i belongs while airborne: folded under the hip while rising,
## reaching for the touchdown footprint while falling. Always inside reach.
func _air_foot_target(i: int, hvel: Vector3) -> Vector3:
	var hip := _hip_world(i)
	var yaw := Basis(Vector3.UP, heading)
	var anchor: Vector3 = FEET_LOCAL[i]
	var target: Vector3
	if linear_velocity.y > 0.0:
		target = hip + Vector3(0.0, -TUCK_DROP, 0.0) \
			+ yaw * Vector3(-signf(anchor.x) * TUCK_GATHER, 0.0, TUCK_GATHER)
	else:
		target = _predict_landing(hvel) + yaw * Vector3(anchor.x, 0.0, anchor.z)
	return hip + (target - hip).limit_length((UPPER_LEN + LOWER_LEN) * 0.95)


func _home(i: int) -> Vector3:
	var off := Basis(Vector3.UP, heading) * (FEET_LOCAL[i] as Vector3)
	var wx := global_position.x + off.x
	var wz := global_position.z + off.z
	return Vector3(wx, _ground_h(wx, wz), wz)


func _physics_process(dt: float) -> void:
	_tick += 1
	_leap_cd = maxf(_leap_cd - dt, 0.0)

	# --- Suspension (stance/gather crouch lowers the ride). ---
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(global_position, global_position + Vector3.DOWN * GROUND_RAY_LEN)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	var ground_dist: float = global_position.y - hit.position.y if not hit.is_empty() else INF
	grounded = ground_dist < RIDE_HEIGHT + 0.4
	_takeoff_t = maxf(_takeoff_t - dt, 0.0)
	if _takeoff_t > 0.0:
		grounded = false  # ballistic: the launch owns the body until clear
	var ride := RIDE_HEIGHT - (STANCE_CROUCH if (stance_active or gathering) else 0.0)
	if grounded:
		apply_central_force(Vector3.UP * maxf(SPRING_K * (ride - ground_dist) - SPRING_D * linear_velocity.y, -40.0))

	# --- Inputs. ---
	var throttle := Input.get_action_strength("throttle")
	var brake := Input.get_action_strength("brake")
	var steer := Input.get_axis("turn_right", "turn_left")
	stance_active = Input.is_action_pressed("stance")
	if Input.is_action_just_pressed("leap"):
		request_leap()
	var hvel := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var hspeed := hvel.length()
	var reversing := brake > 0.0 and hspeed < 0.4

	# --- Ground context. ---
	surface = ground.surface_at(global_position.x, global_position.z) if ground != null else 0
	var gn: Vector3 = ground.normal_at(global_position.x, global_position.z) if ground != null else Vector3.UP

	# --- Landing: unbraced hard landings bleed speed; stance absorbs. ---
	if grounded and not _was_grounded:
		if -_prev_vy > HARD_LANDING_VY and not stance_active and hspeed > 0.05:
			apply_central_impulse(-hvel / hspeed * hspeed * (1.0 - LAND_RETENTION_HARD) * mass)
			_event("hard_land", -1, -_prev_vy, hspeed)

	# --- Edge sense: probe along travel for refused drops (crisp cells). ---
	cliff_ahead = false
	_cliff_dist = INF
	_edge_dist12 = INF
	if grounded and ground != null:
		_edge_dir = hvel / hspeed if hspeed > 0.5 else forward()
		var here_h: float = ground.floor_at(global_position.x, global_position.z)
		var horizon := clampf(hspeed * 1.2 + 1.5, 4.0, 9.0)
		var d := 0.5
		while d <= ARM_SCAN:
			var p := global_position + _edge_dir * d
			if here_h - ground.floor_at(p.x, p.z) > CLIFF_DROP:
				_edge_dist12 = d
				break
			d += 0.5
		if _edge_dist12 <= horizon:
			cliff_ahead = true
			_cliff_dist = _edge_dist12

	# --- Leap intent: held or recently pressed. A press with an edge in
	# reach arms; a press in open ground hops immediately. ---
	_intent_t = maxf(_intent_t - dt, 0.0)
	var leap_intent := Input.is_action_pressed("leap") or _intent_t > 0.0
	if _leap_pressed:
		_leap_pressed = false
		if grounded and not gathering and _leap_cd <= 0.0:
			if _edge_dist12 < ARM_SCAN:
				_intent_t = 1.5
				leap_intent = true
			else:
				gathering = true
				_gather_t = 0.0
	leap_armed = grounded and not gathering and cliff_ahead and leap_intent
	refusing = grounded and not gathering and cliff_ahead and not leap_intent
	edge_hint = "refusing edge — hold Shift to commit" if refusing else ""

	if leap_armed and hspeed >= 1.5:
		# Moving: the machine times its gather so launch happens at the lip
		# (1.6 m pad absorbs the sensor's cell-quantization bias).
		if _cliff_dist <= hspeed * GATHER_TIME + 1.6:
			gathering = true
			_gather_t = 0.0
	elif leap_armed and _cliff_dist < 4.0:
		# Standing at a refused edge: guided jump when the far side is inside
		# the standing envelope; hop-off when it is a sheer drop; otherwise
		# say why not.
		var gap := _measure_gap()
		if gap < 0.0:
			# Sheer drop: consented hop-off, scaled to actually clear the lip.
			_gather_boost = (_cliff_dist + 1.0) / 0.9
			gathering = true
			_gather_t = 0.0
		else:
			var needed := _cliff_dist + gap + 1.0  # GUIDED_UP airtime ~1.0 s
			if needed <= GUIDED_VMAX and gap <= STANDING_JUMP_MAX:
				_gather_boost = needed
				gathering = true
				_gather_t = 0.0
			else:
				edge_hint = "too far from standstill — take a run-up"
	if gathering:
		_intent_t = 0.0

	# --- Gather, then committed launch. ---
	if gathering:
		_gather_t += dt
		if not grounded:
			gathering = false
		elif _gather_t >= GATHER_TIME:
			gathering = false
			_leap_cd = LEAP_COOLDOWN
			var ldir := hvel / hspeed if hspeed > 0.5 else _edge_dir
			var up_imp := LEAP_UP
			var fwd_imp := minf(LEAP_FWD_BASE + LEAP_FWD_SPEED * hspeed, LEAP_FWD_MAX)
			if _gather_boost > 0.0:
				up_imp = GUIDED_UP
				fwd_imp = clampf(_gather_boost - hspeed, LEAP_FWD_BASE, GUIDED_VMAX)
				_gather_boost = 0.0
			apply_central_impulse((Vector3.UP * up_imp + ldir * fwd_imp) * mass)
			_takeoff_t = TAKEOFF_GRACE
			_event("leap", -1, hspeed, 0.0)

	# --- Slide: stance held on a steep descent with speed. ---
	if sliding:
		_slide_exit_t = _slide_exit_t + dt if gn.y > SLIDE_EXIT_NY else 0.0
		if not grounded or not stance_active or brake > 0.3 or hspeed < 2.0 or _slide_exit_t > 0.3:
			sliding = false
	elif grounded and stance_active and not gathering and hspeed > SLIDE_MIN_SPEED and gn.y < SLIDE_ENTER_NY:
		var downhill := (Vector3.DOWN - gn * Vector3.DOWN.dot(gn)).normalized()
		if hvel.dot(downhill) > 0.3 * hspeed:
			sliding = true
			_slide_exit_t = 0.0
			_event("slide_on", -1, hspeed, 0.0)

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

	# --- Support + steering through planted feet. Committed in the air. ---
	var planted := 0
	for f in feet:
		if not f.swinging:
			planted += 1
	# Airborne means unweighted: nothing is carrying load, whatever the feet
	# happen to be doing. Feeds the chassis settle and the spine.
	planted_fraction = (planted / 4.0) if grounded else 0.0
	var turn_rate := TURN_RATE
	if sliding:
		turn_rate = SLIDE_TURN
	elif stance_active and grounded:
		turn_rate = TURN_RATE * STANCE_TURN_MULT
	var authority := planted_fraction if grounded else AIR_STEER
	heading = wrapf(heading + steer * turn_rate * authority * dt, -PI, PI)
	var fwd := forward()

	# --- Feet. Airborne: push, then tuck or reach. Grounded: step. ---
	if not grounded:
		if _takeoff_t <= TAKEOFF_GRACE - PUSH_HOLD:
			for i in 4:
				var f := feet[i]
				f.swinging = false
				f.pos = f.pos.lerp(_air_foot_target(i, hvel), 1.0 - exp(-AIR_FOOT_RATE * dt))
	elif sliding or gathering:
		for i in 4:
			var f := feet[i]
			f.swinging = false
			f.pos = f.pos.lerp(_home(i), 1.0 - exp(-10.0 * dt))
	else:
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

	# Geometric backstop over EVERY foot, planted included: a leg cannot be
	# longer than itself. With the urgent-step rule above this should almost
	# never bind — but a scheduling failure must degrade into a dragged foot,
	# never into a stretched limb.
	for i in 4:
		feet[i].pos = _clamp_to_reach(i, feet[i].pos)

	if grounded:
		if sliding:
			# Carve: glide with extra downhill pull, soft lateral grip.
			var downhill := Vector3.DOWN - gn * Vector3.DOWN.dot(gn)
			if downhill.length() > 0.01:
				apply_central_force(downhill.normalized() * SLIDE_GRAVITY * mass)
			apply_central_force(-hvel * SLIDE_DRAG * mass)
			var lat_s := hvel - fwd * hvel.dot(fwd)
			apply_central_force(-lat_s * SLIDE_GRIP * mass)
		elif gathering:
			apply_central_force(-hvel * DRAG * mass)
		else:
			_step_triggers(hvel)
			var m_drag: float = SURF_DRAG[surface] * (STANCE_DRAG_MULT if stance_active else 1.0)
			var m_grip: float = SURF_GRIP[surface] * (STANCE_GRIP_MULT if stance_active else 1.0)
			var m_thrust: float = SURF_THRUST[surface] * (STANCE_THRUST_MULT if stance_active else 1.0)
			var throttle_eff := throttle
			if refusing:
				# No forward drive toward a refused edge, and brake to stand
				# before the lip. Capped: reckless speed can still carry over.
				throttle_eff = 0.0
				if hspeed > 0.05:
					var stop_d := maxf(_cliff_dist - CLIFF_STOP_MARGIN, 0.1)
					var needed := hspeed * hspeed / (2.0 * stop_d)
					apply_central_force(-hvel / hspeed * minf(needed, CLIFF_BRAKE) * mass)
			_stance_forces(hvel, hspeed, fwd, throttle_eff, brake, reversing, m_thrust)
			# Resistance and grip as forces (never write linear_velocity — the
			# property is a pre-tick cache; writes clobber this tick's forces).
			apply_central_force(-hvel * DRAG * m_drag * planted_fraction * mass)
			var lat := hvel - fwd * hvel.dot(fwd)
			apply_central_force(-lat * GRIP * m_grip * planted_fraction * mass)

	for i in 4:
		sim_max_extension = maxf(sim_max_extension,
			(feet[i].pos - _hip_world(i)).length() / (UPPER_LEN + LOWER_LEN))

	_prev_vy = linear_velocity.y
	_was_grounded = grounded
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
		var drift := _drift(i)
		# A leg at the end of its reach must step, whatever the gait pattern
		# would prefer. The support floor and the co-swing rules are style;
		# leg length is geometry, and geometry wins. Without this a foot can
		# be blocked while the body walks away and the leg stretches.
		var urgent := drift > STEP_RANGE * OVERSTRETCH \
			or _extension(i) > REACH_URGENT
		if not urgent and planted_now - 1 < floor_n:
			continue
		if drift < STEP_RANGE * _trigger_factor(i) and not urgent:
			continue
		if _may_lift(i) or urgent:
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


## Hip-to-foot distance as a fraction of total leg length. 1.0 = straight.
func _extension(i: int) -> float:
	return (feet[i].pos - _hip_world(i)).length() / (UPPER_LEN + LOWER_LEN)


## ---------------------------------------------------------------- FORCE ---
func _stance_forces(hvel: Vector3, hspeed: float, fwd: Vector3, throttle: float, brake: float, reversing: bool, thrust_mult := 1.0) -> void:
	var travel := hvel / hspeed if hspeed > 0.15 else fwd
	var launch := lerpf(LAUNCH_BOOST, 1.0, clampf(hspeed / LAUNCH_FADE, 0.0, 1.0))
	var thrust := THRUST_PER_LEG * (1.0 + THRUST_GAIT * gait) * thrust_mult * launch
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
	_log.store_line("tick,gait,regime,speed,vy,y,support,throttle,l0s,l0x,l0z,l0st,l1s,l1x,l1z,l1st,l2s,l2x,l2z,l2st,l3s,l3x,l3z,l3st,stance,slide,gather,surf")
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
	parts.append("%d,%d,%d,%d" % [1 if stance_active else 0, 1 if sliding else 0, 1 if gathering else 0, surface])
	_log.store_line(",".join(parts))
	if _tick % 120 == 0:
		_log.flush()
		if _elog:
			_elog.flush()
