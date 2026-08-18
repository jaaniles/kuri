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
var _cam_focus := Vector3.ZERO
var _cam_manual := false


func _ready() -> void:
	_setup_input()
	_setup_world()

	yard = Yard.new()
	add_child(yard)

	walker = WalkerBody.new()
	walker.ground = yard
	add_child(walker)
	# Spawn on the flat east corridor (clear run for regression harness).
	walker.global_position = Vector3(60, WalkerBody.RIDE_HEIGHT, 72)
	walker.snap_feet()

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

	var args := OS.get_cmdline_user_args()
	if args.has("--shot"):
		var outdir := "user://"
		var i := args.find("--outdir")
		if i >= 0 and i + 1 < args.size():
			outdir = args[i + 1]
		walker.enable_logging(outdir)
		_shot_sequence(outdir)
	elif args.has("--gauntlet"):
		_gauntlet_sequence()


func _process(dt: float) -> void:
	if _cam_manual:
		return
	if Input.is_action_just_pressed("tilt_down"):
		cam_pitch = clampf(cam_pitch - 5.0, 55.0, 90.0)
	if Input.is_action_just_pressed("tilt_up"):
		cam_pitch = clampf(cam_pitch + 5.0, 55.0, 90.0)
	var bp := walker.global_position
	var hvel := Vector3(walker.linear_velocity.x, 0, walker.linear_velocity.z)
	var target := bp + hvel * 0.35
	_cam_focus = _cam_focus.lerp(target, 1.0 - exp(-4.0 * dt))
	var p := deg_to_rad(cam_pitch)
	cam.global_position = _cam_focus + Vector3(0, sin(p), cos(p)) * cam_height
	cam.rotation_degrees = Vector3(-cam_pitch, 0, 0)


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
	await _frames(10)
	# Steady-state bands via partial throttle: walk, then trot, then full.
	_hold("throttle", 0.25)
	await _frames(300)
	await _capture(outdir, "walk_steady")
	_hold("throttle", 0.5)
	await _frames(300)
	await _capture(outdir, "trot_steady")
	_hold("throttle", 1.0)
	await _frames(400)
	await _capture(outdir, "gallop")
	_hold("turn_left")
	await _frames(70)
	await _capture(outdir, "gallop_turn")
	_unhold("turn_left")
	await _frames(150)
	await _capture(outdir, "gallop_straight")
	_unhold("throttle")
	await _frames(120)
	await _capture(outdir, "coast_down")
	_hold("brake")
	await _frames(80)
	await _capture(outdir, "brake")
	_unhold("brake")
	# Yard overview for geometry integrity checks.
	_cam_manual = true
	cam.global_position = Vector3(0, 110, 75)
	cam.rotation_degrees = Vector3(-60, 0, 0)
	await _frames(5)
	await _capture(outdir, "yard_overview")
	get_tree().quit()


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
