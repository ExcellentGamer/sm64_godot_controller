class_name Player
extends CharacterBody3D

@export_group("Camera")
@export_range(0.0, 1.0) var mouse_sensitivity := 0.25
@export var tilt_upper_limit := PI / 3.0
@export var tilt_lower_limit := -PI / 4.0
@export var _zoom_distances := [4.0, 8.0, 12.0]
@export var _zoom_speed := 5.0

@export_group("Movement")
@export var move_speed := 12.5
@export var acceleration := 50.0
@export var jump_impulse := 22.5
@export var rotation_speed := 30.0
@export var stopping_speed := 1.0
@export var _jump_chain_time := 0.2 # Time window to chain jumps
@export var _jump_power_increase := 1.2 # Multiplier for chained jump height

@export_group("Dive")
@export var _dive_speed_threshold := 7.25 # Min speed to initiate a dive
@export var _dive_boost_force := 8.0 # Forward boost on dive
@export var _dive_upward_lift := 10.0 # Upward boost on dive
@export var _dive_friction_rate := 20.0 # Rate of speed loss during slide
@export var _get_up_speed_threshold := 1.0 # Speed at which to transition to get up

@export_group("Punch")
@export var _punch_forward_force := 7.5
@export var _punch_duration := 0.45
@onready var _punch_timer: Timer = $PunchTimer
@onready var _punch_box: Area3D = $Mario/PunchBox

enum State {
	STATE_NORMAL,
	STATE_DIVE,
	STATE_SLIDE,
	STATE_ROLLOUT,
	STATE_DIVE_RECOVER,
	STATE_PUNCH,
	STATE_JUMP_KICK,
	STATE_CROUCH,
	STATE_CROUCH_SLIDE
}
var _current_state := State.STATE_NORMAL

var _punch_index := 0
var _can_punch := true
var _queued_next_punch := false
var _cached_punch_direction: Vector3 = Vector3.ZERO

var ground_height := 0.0
var _gravity := -50.0
var _was_on_floor_last_frame := true
var _camera_input_direction := Vector2.ZERO
var _target_camera_input := Vector2.ZERO

var _current_zoom_state := 2
var _target_zoom_distance := 0.0

var _jump_count := 0 # Tracks consecutive jumps
var _time_since_landed := 0.0 # Timer to track time on the ground

var _is_backflipping := false
var _is_dive_rollout := false

@onready var _last_input_direction := global_basis.z
@onready var _start_position := global_position
@onready var _camera_pivot: Node3D = %CameraPivot
@onready var _camera: Camera3D = %Camera3D
@onready var _skin: SophiaSkin = %Mario
@onready var _landing_sound: AudioStreamPlayer3D = %LandingSound
@onready var _jump_sound: AudioStreamPlayer3D = %JumpSound
@onready var _camera_sound: AudioStreamPlayer = $CameraSound
@onready var _dust_particles: GPUParticles3D = %DustParticles
@onready var _spring_arm: SpringArm3D = $CameraPivot/SpringArm3D

func _on_dive_recover_finished() -> void:
	if _current_state == State.STATE_DIVE_RECOVER:
		_current_state = State.STATE_NORMAL

func _on_idle_animation_returned() -> void:
	if _punch_index == 0:
		_can_punch = true

func _on_punch_finished() -> void:
	if _current_state == State.STATE_PUNCH:
		if _punch_index >= 3:
			_current_state = State.STATE_NORMAL
			_skin.idle()
			_punch_index = 0
			_queued_next_punch = false
		elif _queued_next_punch:
			_punch_index += 1
			_queued_next_punch = false
			_punch_timer.start(_punch_duration)
		else:
			_current_state = State.STATE_NORMAL
			_skin.idle()
			_punch_index = 0
			_can_punch = true  # Allow punching again early if combo ends early

func _on_punch_force_delay() -> void:
	if _current_state == State.STATE_PUNCH:
		velocity = _cached_punch_direction.normalized() * _punch_forward_force

func _ready() -> void:
	Events.kill_plane_touched.connect(func on_kill_plane_touched() -> void:
		global_position = _start_position
		velocity = Vector3.ZERO
		_skin.idle()
		set_physics_process(true)
	)
	Events.flag_reached.connect(func on_flag_reached() -> void:
		set_physics_process(false)
		_skin.idle()
		_dust_particles.emitting = false
	)
	
	_target_zoom_distance = _zoom_distances[_current_zoom_state]
	_spring_arm.spring_length = _target_zoom_distance
	_skin.recovered.connect(_on_dive_recover_finished)
	_punch_timer.timeout.connect(_on_punch_finished)
	_punch_box.set_deferred("monitoring", false)
	_punch_box.set_deferred("monitorable", false)
	_skin.returned_to_idle.connect(_on_idle_animation_returned)
	$PunchForceDelayTimer.timeout.connect(_on_punch_force_delay)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("left_click"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	if event.is_action_pressed("camera_zoom_cycle"):
		_camera_sound.play()
		_current_zoom_state = (_current_zoom_state + 1) % _zoom_distances.size()
		_target_zoom_distance = _zoom_distances[_current_zoom_state]

	# --- Camera input (right stick) ---
	var joypad_id := 0
	var raw_look := Vector2(
		Input.get_joy_axis(joypad_id, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(joypad_id, JOY_AXIS_RIGHT_Y)
	)

	var deadzone := 0.5
	var stick_scale := 5.0

	if raw_look.length() > deadzone:
		var adjusted := raw_look.normalized() * ((raw_look.length() - deadzone) / (1.0 - deadzone))
		_target_camera_input = -adjusted * mouse_sensitivity * stick_scale * 1.25
	else:
		_target_camera_input = Vector2.ZERO

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("dive") and _current_state == State.STATE_PUNCH and _punch_index < 3:
		_queued_next_punch = true

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_camera_input_direction.x = -event.relative.x * mouse_sensitivity
		_camera_input_direction.y = -event.relative.y * mouse_sensitivity

func _physics_process(delta: float) -> void:
	# --- Smooth the camera zoom ---
	_spring_arm.spring_length = lerp(_spring_arm.spring_length, _target_zoom_distance, delta * _zoom_speed)

	# --- Smooth and apply camera input ---
	_camera_input_direction = _camera_input_direction.lerp(_target_camera_input, 0.25)

	_camera_pivot.rotation.x += _camera_input_direction.y * delta
	_camera_pivot.rotation.x = clamp(_camera_pivot.rotation.x, tilt_lower_limit, tilt_upper_limit)
	_camera_pivot.rotation.y += _camera_input_direction.x * delta

	# --- Dive, Move, and Jump Logic based on State ---
	
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	var is_just_jumping := Input.is_action_just_pressed("jump")
	var is_just_diving := Input.is_action_just_pressed("dive")
	var jump_initiated_this_frame := false
	var dive_initiated_this_frame := false

	match _current_state:
		State.STATE_NORMAL:
			var joypad_id := 0
			var left_x := Input.get_joy_axis(joypad_id, JOY_AXIS_LEFT_X)
			var left_y := Input.get_joy_axis(joypad_id, JOY_AXIS_LEFT_Y)
			var left_stick := Vector2(left_x, left_y)
			var deadzone := 0.025
			var move_input := Vector2.ZERO
			if left_stick.length() > deadzone:
				move_input = left_stick.normalized() * ((left_stick.length() - deadzone) / (1.0 - deadzone))
			else:
				move_input = Input.get_vector("move_left", "move_right", "move_up", "move_down", 0.4)
			var forward := _camera.global_basis.z
			var right := _camera.global_basis.x
			var move_direction := (forward * move_input.y + right * move_input.x)
			move_direction.y = 0.0
			move_direction = move_direction.normalized()
			if move_direction.length() > 0.2:
				_last_input_direction = move_direction.normalized()
			var target_angle := Vector3.BACK.signed_angle_to(_last_input_direction, Vector3.UP)
			_skin.global_rotation.y = lerp_angle(_skin.rotation.y, target_angle, rotation_speed * delta)
			var input_strength: float = clamp(move_input.length(), 0.0, 1.0)
			var y_velocity := velocity.y
			velocity.y = 0.0
			velocity = velocity.move_toward(move_direction * move_speed * input_strength, acceleration * delta)
			if is_equal_approx(move_direction.length_squared(), 0.0) and velocity.length_squared() < stopping_speed:
				velocity = Vector3.ZERO
			velocity.y = y_velocity + _gravity * delta
			_time_since_landed += delta

			# === Enter crouch or crouch slide ===
			if is_on_floor() and Input.is_action_pressed("crouch"):
				if ground_speed > 0.25:
					_current_state = State.STATE_CROUCH_SLIDE
					_skin.crouch() # <-- call your crouch-slide anim
				else:
					_current_state = State.STATE_CROUCH
					velocity = Vector3.ZERO
					_skin.crouch()
				return

			# -- Jump, Dive, and Punch Initiation --
			if is_just_jumping and is_on_floor():
				jump_initiated_this_frame = true
				if _time_since_landed < _jump_chain_time and _jump_count < 3:
					# Only allow triple jump if Mario has horizontal movement
					if _jump_count == 2:
						if ground_speed > 0.25:
							_jump_count += 1
						else:
							_jump_count = 1
					else:
						_jump_count += 1
				else:
					_jump_count = 1
				var jump_power = jump_impulse * pow(_jump_power_increase, _jump_count - 1)
				
				# JUMP ANIMATION CALLS ARE MOVED HERE
				if _jump_count == 1:
					_skin.jump()
					$"Sounds3D/Mario Wah".play()
				elif _jump_count == 2:
					_skin.double_jump()
					$"Sounds3D/Mario Hoohoo".play()
				elif _jump_count == 3:
					_skin.triple_jump()
					$"Sounds3D/Mario Yahoo".play()
				
				velocity.y = jump_power
				_jump_sound.play()
			# Dive input midair with no valid dive → jump kick
			elif is_just_diving and not is_on_floor() and ground_speed <= _dive_speed_threshold and _is_backflipping == false and _is_dive_rollout == false:
				_current_state = State.STATE_JUMP_KICK
				_skin.punch_3()
				$"Sounds3D/Mario Hoo".play()
				velocity.y = jump_impulse * 0.6
				var kick_forward = _last_input_direction
				if kick_forward.length_squared() == 0.0:
					kick_forward = -global_basis.z
				velocity += kick_forward * 2.5
				return
			elif is_just_diving and is_on_floor() and ground_speed <= _dive_speed_threshold and _can_punch:
				_current_state = State.STATE_PUNCH
				_punch_index = 1
				_can_punch = false
				_queued_next_punch = false
				_punch_timer.start(_punch_duration)
				_punch_box.set_deferred("monitoring", true)
				_punch_box.set_deferred("monitorable", true)

				# Cache the punch direction
				_cached_punch_direction = _last_input_direction
				if _cached_punch_direction.length_squared() == 0.0:
					_cached_punch_direction = -global_basis.z

				# Delay applying the forward force
				$PunchForceDelayTimer.start()
			elif is_just_diving and ground_speed > _dive_speed_threshold and _current_state != State.STATE_ROLLOUT:
				dive_initiated_this_frame = true
				_current_state = State.STATE_DIVE
				_skin.dive()
				$"Sounds3D/Mario Yah".play()
				var dive_velocity_boost = _last_input_direction * _dive_boost_force
				velocity = velocity + dive_velocity_boost
				velocity.y = _dive_upward_lift
				_jump_count = 0
			
			# This animation logic is now integrated into the movement checks
			# IT WILL BE SKIPPED IF A JUMP OR PUNCH WAS INITIATED
			if not _is_backflipping:
				if not jump_initiated_this_frame and not dive_initiated_this_frame:
					if input_strength > 0.0:
						if is_on_floor():
							_skin.move()
							_skin.set_animation_speed(input_strength * 1.25)
					else:
						if is_on_floor():
							_skin.idle()
			
		State.STATE_DIVE:
			velocity.y += _gravity * delta
			_dust_particles.emitting = false
			if is_on_floor():
				_current_state = State.STATE_SLIDE
				
		State.STATE_SLIDE:
			velocity.y += _gravity * delta
			_dust_particles.emitting = ground_speed > _get_up_speed_threshold
			var horizontal_velocity = Vector3(velocity.x, 0, velocity.z)
			horizontal_velocity = horizontal_velocity.move_toward(Vector3.ZERO, _dive_friction_rate * delta)
			velocity.x = horizontal_velocity.x
			velocity.z = horizontal_velocity.z

			if ground_speed <= _get_up_speed_threshold:
				_skin.dive_recover()
				_current_state = State.STATE_DIVE_RECOVER
				velocity = Vector3.ZERO
				_jump_count = 0

			elif is_just_jumping or is_just_diving:
				$"Sounds3D/Mario Wah".play()
				#set skin for dive rollout here
				velocity.y = _dive_upward_lift
				if not is_on_floor():
					_is_dive_rollout = true
				else:
					_is_dive_rollout = false
					_current_state = State.STATE_NORMAL
				_jump_count = 0
				
		State.STATE_ROLLOUT:
			velocity.y += _gravity * delta
			_dust_particles.emitting = false
			if ground_speed > 0.0:
				var horizontal_velocity = Vector3(velocity.x, 0, velocity.z)
				horizontal_velocity = horizontal_velocity.move_toward(Vector3.ZERO, _dive_friction_rate * delta)
				velocity.x = horizontal_velocity.x
				velocity.z = horizontal_velocity.z
			else:
				_current_state = State.STATE_NORMAL
				_skin.idle()
				_jump_count = 0

		State.STATE_DIVE_RECOVER:
			velocity = Vector3.ZERO

		State.STATE_PUNCH:
			velocity.y += _gravity * delta
			var horizontal_velocity = Vector3(velocity.x, 0, velocity.z)
			horizontal_velocity = horizontal_velocity.move_toward(Vector3.ZERO, _dive_friction_rate * 2.0 * delta)
			velocity.x = horizontal_velocity.x
			velocity.z = horizontal_velocity.z

			# Play appropriate animation based on index
			match _punch_index:
				1:
					_skin.punch_1()
					$"Sounds3D/Mario Yah".play()
				2:
					_skin.punch_2()
					$"Sounds3D/Mario Wah".play()
				3:
					_skin.punch_3()
					$"Sounds3D/Mario Hoo".play()

			# If final punch, ignore input and wait to return to idle
			if _queued_next_punch:
				_punch_index += 1
				_queued_next_punch = false
				_punch_timer.start(_punch_duration)

				# Apply forward force again for follow-up punches
				var punch_direction = _last_input_direction
				if punch_direction.length_squared() == 0.0:
					punch_direction = -global_basis.z
				_cached_punch_direction = punch_direction
				$PunchForceDelayTimer.start()

		State.STATE_JUMP_KICK:
			velocity.y += _gravity * delta
			if is_on_floor():
				_current_state = State.STATE_NORMAL
				_skin.idle()

		State.STATE_CROUCH:
			# If not on floor, cancel crouch
			if not is_on_floor():
				_current_state = State.STATE_NORMAL
				_skin.idle()
				return

			# Movement input
			var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down", 0.4)
			var forward := _camera.global_basis.z
			var right := _camera.global_basis.x
			var move_direction := (forward * move_input.y + right * move_input.x)
			move_direction.y = 0.0
			move_direction = move_direction.normalized()

			# Exit crouch if input released
			if not Input.is_action_pressed("crouch"):
				_current_state = State.STATE_NORMAL
				_skin.idle()
				return

			# Crouch jump
			if Input.is_action_just_pressed("jump") and move_direction.length() < 0.25:
				_current_state = State.STATE_NORMAL
				velocity.y = jump_impulse * 1.2
				var back_force := -_skin.global_transform.basis.z.normalized() * move_speed
				velocity.x = back_force.x
				velocity.z = back_force.z
				_is_backflipping = true  # <-- Track backflip animation
				_skin.backflip()
				return

			# Apply gravity
			velocity.y += _gravity * delta

			if move_direction.length() > 0.25:
				_last_input_direction = move_direction
				rotation_speed = 5.0
				velocity = velocity.move_toward(
					move_direction * (move_speed * 0.15),
					acceleration * delta
				)
				_skin.crawl()
				var target_angle := Vector3.BACK.signed_angle_to(_last_input_direction, Vector3.UP)
				_skin.global_rotation.y = lerp_angle(_skin.rotation.y, target_angle, rotation_speed * delta)
			else:
				rotation_speed = 30.0
				velocity = velocity.move_toward(Vector3.ZERO, acceleration * delta)
				_skin.crouch()

		State.STATE_CROUCH_SLIDE:
			# If not on floor, cancel slide
			if not is_on_floor():
				_current_state = State.STATE_NORMAL
				_skin.idle()
				return

			velocity.y += _gravity * delta

			# Apply sliding friction
			var horizontal_velocity = Vector3(velocity.x, 0, velocity.z)
			horizontal_velocity = horizontal_velocity.move_toward(Vector3.ZERO, _dive_friction_rate * 0.75 * delta)
			velocity.x = horizontal_velocity.x
			velocity.z = horizontal_velocity.z

			# Stay in slide animation
			_skin.crouch()

			# If crouch released, go back to normal
			if not Input.is_action_pressed("crouch"):
				_current_state = State.STATE_NORMAL
				_skin.idle()
				return

			# If we slowed down enough, transition to crouch
			if horizontal_velocity.length() <= _get_up_speed_threshold:
				_current_state = State.STATE_CROUCH
				velocity.x = 0
				velocity.z = 0
				_skin.crouch()
				return

	# Stop backflip animation once player starts falling
	if _is_backflipping and velocity.y < 0.0:
		_is_backflipping = false
		# eventually add a fall animation here

	# --- CommPlayer3DTemplateon logic outside the state machine ---
	if is_on_floor() and not _was_on_floor_last_frame:
		_landing_sound.play()
		_time_since_landed = 0.0

	_dust_particles.emitting = is_on_floor() and ground_speed > 0.0 and (_current_state == State.STATE_NORMAL or _current_state == State.STATE_SLIDE)

	_was_on_floor_last_frame = is_on_floor()
	move_and_slide()
