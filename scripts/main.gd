extends Node3D
## Rig A: flat plane, sphere proxy, four-legged visual layer, top-down camera.
##
## Verification-only extra: `godot --path . -- --shot --outdir <dir>` drives
## through all gait bands and saves frames + locomotion CSV logs.

var yard: Yard
var walker: WalkerBody
var visual: WalkerVisual
var cam: Camera3D
var cam_height := 26.0
var cam_pitch := 70.0  # degrees from horizontal; 90 = straight down
var hud: Label
var _cam_focus := Vector3.ZERO
var _cam_manual := false


const PLAYER_SPAWN := Vector3(0, 0, 74)   # hub centre, facing the lanes
const HARNESS_SPAWN := Vector3(-70, 0, 74)  # flat hub strip, eastward run

# Lane stopwatch.
var _lane_times := {}  # name -> {"best": float, "last": float}
var _active_lane := ""
var _lane_t0 := 0
var _prev_z := 0.0


func _ready() -> void:
	_setup_input()
	_setup_world()

	var args := OS.get_cmdline_user_args()
	var gauntlet := args.has("--gauntlet")
	if not gauntlet:
		yard = Yard.new()
		add_child(yard)

	walker = WalkerBody.new()
	walker.ground = yard
	add_child(walker)
	_respawn(PLAYER_SPAWN, 0.0)

	visual = WalkerVisual.new()
	visual.body = walker
	add_child(visual)

	cam = Camera3D.new()
	cam.fov = 35.0
	cam.near = 1.0
	cam.far = 400.0
	add_child(cam)
	cam.rotation_degrees = Vector3(-cam_pitch, 0, 0)
	cam.global_position = walker.global_position + Vector3(0, cam_height, 0)
	cam.current = true

	_setup_hud()

	if args.has("--shot"):
		var outdir := "user://"
		var i := args.find("--outdir")
		if i >= 0 and i + 1 < args.size():
			outdir = args[i + 1]
		walker.enable_logging(outdir)
		_shot_sequence(outdir)
	elif gauntlet:
		_gauntlet_sequence()
	elif args.has("--edgetest"):
		_edge_test()


## End-to-end edge contract on the COMMIT gap: refusal stops before the lip;
## a run-up armed leap clears it onto tower B.
func _edge_test() -> void:
	await _frames(10)
	_respawn(Vector3(0, 0, -18), 0.0)  # tower A top, facing the gap (lip z -28)
	await _frames(5)
	_hold("throttle")
	await _frames(420)
	var pz := walker.global_position.z
	print("EDGE stop: z=%.1f (lip -28) speed=%.2f state=%s" % [pz, walker.linear_velocity.length(), walker.state_name()])
	_unhold("throttle")
	await _frames(30)
	_respawn(Vector3(0, 0, -9), 0.0)  # full runway across the tower top
	await _frames(5)
	_hold("throttle")
	var guard := 0
	while walker.global_position.z > -22.0 and guard < 600:
		await _frames(2)
		guard += 2
	walker.request_leap()
	print("EDGE req: z=%.1f v=%.2f cliff=%s dist=%.1f state=%s" % [walker.global_position.z, walker.linear_velocity.length(), walker.cliff_ahead, walker._cliff_dist, walker.state_name()])
	for k in 20:
		await _frames(15)
		var q := walker.global_position
		print("EDGE t+%d: z=%.1f y=%.1f v=%.2f state=%s cliff=%s" % [(k + 1) * 15, q.z, q.y, walker.linear_velocity.length(), walker.state_name(), walker.cliff_ahead])
	_unhold("throttle")
	var p := walker.global_position
	var landed := p.y > 4.0 and p.z < -32.0
	print("EDGE leap: pos=(%.1f, %.1f, %.1f) %s" % [p.x, p.y, p.z, "LANDED TOWER B" if landed else "FELL"])
	get_tree().quit()


func _respawn(spawn: Vector3, heading: float) -> void:
	var gy: float = yard.height_at(spawn.x, spawn.z) if yard else 0.0
	walker.global_position = Vector3(spawn.x, gy + WalkerBody.RIDE_HEIGHT, spawn.z)
	walker.linear_velocity = Vector3.ZERO
	walker.heading = heading
	walker.reset_state()
	walker.snap_feet()
	_active_lane = ""
	_cam_focus = walker.global_position
	_prev_z = spawn.z


func _process(dt: float) -> void:
	if _cam_manual:
		return
	if Input.is_action_just_pressed("tilt_down"):
		cam_pitch = clampf(cam_pitch - 5.0, 55.0, 90.0)
	if Input.is_action_just_pressed("tilt_up"):
		cam_pitch = clampf(cam_pitch + 5.0, 55.0, 90.0)
	if Input.is_action_just_pressed("reset"):
		_respawn(PLAYER_SPAWN, 0.0)
	var bp := walker.global_position
	var hvel := Vector3(walker.linear_velocity.x, 0, walker.linear_velocity.z)
	var target := bp + hvel * 0.35
	_cam_focus = _cam_focus.lerp(target, 1.0 - exp(-4.0 * dt))
	var p := deg_to_rad(cam_pitch)
	cam.global_position = _cam_focus + Vector3(0, sin(p), cos(p)) * cam_height
	cam.rotation_degrees = Vector3(-cam_pitch, 0, 0)
	_update_stopwatch(bp)
	_update_hud(hvel.length())


func _update_stopwatch(p: Vector3) -> void:
	if yard == null:
		return
	if _active_lane == "":
		if _prev_z > Yard.LANE_Z_START and p.z <= Yard.LANE_Z_START:
			for l in Yard.LANES:
				if p.x >= l.x0 and p.x <= l.x1:
					_active_lane = l.name
					_lane_t0 = Time.get_ticks_msec()
	else:
		var lane: Dictionary = {}
		for l in Yard.LANES:
			if l.name == _active_lane:
				lane = l
		if p.x < lane.x0 or p.x > lane.x1 or p.z > Yard.LANE_Z_START + 4.0:
			_active_lane = ""  # left the lane
		elif p.z <= Yard.LANE_Z_END:
			var t := (Time.get_ticks_msec() - _lane_t0) / 1000.0
			if not _lane_times.has(_active_lane):
				_lane_times[_active_lane] = {"best": t, "last": t}
			else:
				_lane_times[_active_lane].last = t
				_lane_times[_active_lane].best = minf(_lane_times[_active_lane].best, t)
			_active_lane = ""
	_prev_z = p.z


func _update_hud(speed: float) -> void:
	if hud == null:
		return
	var lines := PackedStringArray()
	if _active_lane != "":
		lines.append("%s   %5.1f s" % [_active_lane, (Time.get_ticks_msec() - _lane_t0) / 1000.0])
	else:
		lines.append("pick a lane ^   FLOW / COMMIT / GRIND")
	for lane_name in _lane_times:
		lines.append("%s  best %5.1f  last %5.1f" % [lane_name, _lane_times[lane_name].best, _lane_times[lane_name].last])
	var surf_names := ["hard", "soft", "slick"]
	var state := walker.state_name()
	if walker.refusing:
		state += "  —  [Shift] to commit"
	lines.append("speed %4.1f   %s   ground: %s" % [speed, state, surf_names[walker.surface]])
	hud.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed:
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_height = clampf(cam_height * 0.88, 10.0, 60.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_height = clampf(cam_height * 1.14, 10.0, 60.0)


func _setup_input() -> void:
	_add_action("throttle", [KEY_W, KEY_UP])
	_add_action("brake", [KEY_S, KEY_DOWN])
	_add_action("turn_left", [KEY_A, KEY_LEFT])
	_add_action("turn_right", [KEY_D, KEY_RIGHT])
	_add_action("stance", [KEY_SPACE])
	_add_action("leap", [KEY_SHIFT])
	_add_action("reset", [KEY_R])
	_add_action("tilt_down", [KEY_Q])
	_add_action("tilt_up", [KEY_E])


func _add_action(action: String, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


func _setup_world() -> void:
	# Ground: flat, collidable, with a subtle checker so motion is visible
	# from a top-down camera.
	var ground := StaticBody3D.new()
	var col := CollisionShape3D.new()
	col.shape = WorldBoundaryShape3D.new()
	ground.add_child(col)
	add_child(ground)

	var img := Image.create_empty(2, 2, false, Image.FORMAT_RGB8)
	img.set_pixel(0, 0, Color(0.44, 0.45, 0.44))
	img.set_pixel(1, 1, Color(0.44, 0.45, 0.44))
	img.set_pixel(1, 0, Color(0.48, 0.49, 0.48))
	img.set_pixel(0, 1, Color(0.48, 0.49, 0.48))
	var tex := ImageTexture.create_from_image(img)

	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	plane.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.uv1_scale = Vector3(100, 100, 1)  # 2 m checker cells
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.roughness = 1.0
	plane.material_override = mat
	add_child(plane)

	# Sun angled well off vertical: from straight above, the offset shadow is
	# where most of the leg articulation actually shows.
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 35, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.2, 0.21, 0.22)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.76, 0.8)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


# Simulated input can be wiped by focus changes (Godot releases pressed keys
# on focus-out), so the harness re-asserts held actions every frame.
var _held := {}


func _hold(action: String, strength := 1.0) -> void:
	_held[action] = strength
	Input.action_press(action, strength)


func _unhold(action: String) -> void:
	_held.erase(action)
	Input.action_release(action)


func _frames(n: int) -> void:
	for _i in n:
		for a in _held:
			Input.action_press(a, _held[a])
		await get_tree().process_frame


func _shot_sequence(outdir: String) -> void:
	# Regression track: flat hub strip, eastward.
	_respawn(HARNESS_SPAWN, -PI * 0.5)
	await _frames(10)
	# Steady-state bands via partial throttle: walk, then trot, then full.
	_hold("throttle", 0.25)
	await _frames(300)
	await _capture(outdir, "walk_steady")
	_hold("throttle", 0.5)
	await _frames(300)
	await _capture(outdir, "trot_steady")
	_hold("throttle", 1.0)
	await _frames(350)
	await _capture(outdir, "gallop")
	_hold("turn_left")
	await _frames(70)
	await _capture(outdir, "gallop_turn")
	_unhold("turn_left")
	await _frames(80)
	await _capture(outdir, "gallop_straight")
	# Verb: stance at speed (expect speed to settle lower, state "stance").
	_hold("stance")
	await _frames(150)
	await _capture(outdir, "stance_hold")
	_unhold("stance")
	await _frames(60)
	# Verb: leap (gather -> flight -> landing).
	walker.request_leap()
	await _frames(30)
	await _capture(outdir, "leap_flight")
	await _frames(80)
	await _capture(outdir, "leap_landed")
	_unhold("throttle")
	await _frames(100)
	_hold("brake")
	await _frames(80)
	await _capture(outdir, "brake")
	_unhold("brake")
	print("ASSERT knee_max_jump=%.3f" % visual.max_knee_frame_jump)
	# Yard overview for geometry integrity checks.
	_cam_manual = true
	cam.global_position = Vector3(0, 130, 80)
	cam.rotation_degrees = Vector3(-62, 0, 0)
	await _frames(5)
	await _capture(outdir, "yard_overview")
	get_tree().quit()


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(14, 10)
	var ls := LabelSettings.new()
	ls.font_size = 16
	ls.shadow_color = Color(0, 0, 0, 0.6)
	ls.shadow_offset = Vector2(1, 1)
	hud.label_settings = ls
	layer.add_child(hud)

	var help := Label.new()
	help.text = "[W/S] drive+brake  [A/D] steer  [Space hold] stance / downhill slide  [Shift] leap  [R] restart  [Q/E] camera pitch  [wheel] zoom"
	var hs := LabelSettings.new()
	hs.font_size = 13
	hs.shadow_color = Color(0, 0, 0, 0.6)
	hs.shadow_offset = Vector2(1, 1)
	help.label_settings = hs
	help.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	help.offset_left = 14
	help.offset_top = -34
	help.offset_bottom = -10
	layer.add_child(help)


# --- Ramp gauntlet: measures what grade the FROZEN movement model climbs. ---
# The kit's ramp grade is chosen from this data; the model is never adapted
# to the world — the world adapts to the model.

const GRADES := [8.0, 12.0, 16.0, 20.0, 24.0]
const RAMP_RISE := 4.0
const RAMP_W := 8.0
const LANE_SPACING := 25.0


func _add_block(pos: Vector3, size: Vector3, rot_x: float, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.rotation.x = rot_x
	add_child(mi)
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	sb.position = pos
	sb.rotation.x = rot_x
	sb.add_child(cs)
	add_child(sb)


func _gauntlet_sequence() -> void:
	for i in GRADES.size():
		var x := i * LANE_SPACING - 50.0
		var th := deg_to_rad(GRADES[i])
		var run := RAMP_RISE / tan(th)
		var slope_len := RAMP_RISE / sin(th)
		_add_block(Vector3(x, RAMP_RISE * 0.5 - 0.25, -run * 0.5), Vector3(RAMP_W, 0.5, slope_len), th, Color(0.55, 0.5, 0.45))
		_add_block(Vector3(x, RAMP_RISE - 0.25, -run - 8.0), Vector3(RAMP_W, 0.5, 16.0), 0.0, Color(0.5, 0.55, 0.5))
	await _frames(10)

	for i in GRADES.size():
		var x := i * LANE_SPACING - 50.0
		walker.global_position = Vector3(x, WalkerBody.RIDE_HEIGHT, 8.0)
		walker.linear_velocity = Vector3.ZERO
		walker.heading = 0.0
		walker.gait = 0.0
		walker.snap_feet()
		await _frames(5)
		_hold("throttle", 1.0)
		var frames_used := 0
		var max_y := 0.0
		var speed_sum := 0.0
		var samples := 0
		while frames_used < 1500:
			await _frames(10)
			frames_used += 10
			max_y = maxf(max_y, walker.global_position.y)
			speed_sum += Vector3(walker.linear_velocity.x, 0, walker.linear_velocity.z).length()
			samples += 1
			if walker.global_position.y > RAMP_RISE - 0.6:
				break
			if walker.global_position.z < -60.0:
				break
		_unhold("throttle")
		var ok := walker.global_position.y > RAMP_RISE - 0.6
		print("GAUNTLET grade=%d climbed=%s max_y=%.2f frames=%d avg_speed=%.2f" % [
			int(GRADES[i]), ok, max_y, frames_used, speed_sum / maxf(samples, 1)])
		await _frames(20)
	get_tree().quit()


func _capture(outdir: String, shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(outdir.path_join("rig_a_%s.png" % shot_name))
	print("SHOT %s speed=%.2f gait=%.2f regime=%d steps=%d" % [shot_name, Vector3(walker.linear_velocity.x, 0, walker.linear_velocity.z).length(), walker.gait, walker.regime, walker.step_count])
