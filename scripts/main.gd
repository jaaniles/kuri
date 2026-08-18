extends Node3D
## Rig A: flat plane, sphere proxy, four-legged visual layer, top-down camera.
##
## Verification-only extra: `godot --path . -- --shot --outdir <dir>` drives
## through all gait bands and saves frames + locomotion CSV logs.

var walker: WalkerBody
var visual: WalkerVisual
var cam: Camera3D
var cam_height := 26.0
var _cam_focus := Vector3.ZERO


func _ready() -> void:
	_setup_input()
	_setup_world()

	walker = WalkerBody.new()
	add_child(walker)
	walker.global_position = Vector3(0, WalkerBody.RIDE_HEIGHT, 0)

	visual = WalkerVisual.new()
	visual.body = walker
	add_child(visual)

	cam = Camera3D.new()
	cam.fov = 35.0
	cam.near = 1.0
	cam.far = 300.0
	add_child(cam)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.global_position = Vector3(0, cam_height, 0)
	cam.current = true

	var args := OS.get_cmdline_user_args()
	if args.has("--shot"):
		var outdir := "user://"
		var i := args.find("--outdir")
		if i >= 0 and i + 1 < args.size():
			outdir = args[i + 1]
		walker.enable_logging(outdir)
		_shot_sequence(outdir)


func _process(dt: float) -> void:
	var bp := walker.global_position
	var hvel := Vector3(walker.linear_velocity.x, 0, walker.linear_velocity.z)
	var target := Vector3(bp.x, 0, bp.z) + hvel * 0.35
	_cam_focus = _cam_focus.lerp(target, 1.0 - exp(-4.0 * dt))
	cam.global_position = _cam_focus + Vector3(0, cam_height, 0)


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
	get_tree().quit()


func _capture(outdir: String, shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(outdir.path_join("rig_a_%s.png" % shot_name))
	print("SHOT %s speed=%.2f gait=%.2f regime=%d steps=%d" % [shot_name, Vector3(walker.linear_velocity.x, 0, walker.linear_velocity.z).length(), walker.gait, walker.regime, walker.step_count])
