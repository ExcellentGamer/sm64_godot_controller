class_name SophiaSkin extends Node3D

@onready var animation_tree = %AnimationTree
@onready var animation_player: AnimationPlayer = $Mario/AnimationPlayer2
@onready var state_machine : AnimationNodeStateMachinePlayback = animation_tree.get("parameters/StateMachine/playback")
@onready var move_tilt_path : String = "parameters/StateMachine/Move/tilt/add_amount"
@onready var _recovery_timer: Timer = $RecoveryTimer

var run_tilt = 0.0 : set = _set_run_tilt

signal recovered
signal returned_to_idle

func _ready() -> void:
	_recovery_timer.timeout.connect(_on_recovery_timer_timeout)

func _set_run_tilt(value : float):
	run_tilt = clamp(value, -1.0, 1.0)
	animation_tree.set(move_tilt_path, run_tilt)

func punch_1():
	state_machine.travel("Punch1")

func punch_2():
	state_machine.travel("Punch2")

func punch_3():
	state_machine.travel("Punch3")

func idle():
	state_machine.travel("Idle")
	returned_to_idle.emit()

func crouch():
	state_machine.travel("StartCrouch")

func crawl():
	state_machine.travel("Crawl")

func move():
	state_machine.travel("Move")

func set_animation_speed(speed: float):
	animation_tree.set("parameters/StateMachine/Move/TimeScale/scale", speed)

func dive():
	state_machine.travel("Dive")

func roll_out():
	state_machine.travel("Roll")

func dive_recover():
	state_machine.travel("Recover")
	var anim_length = animation_player.get_animation("Dive Recover/Rootbone|Dive Recover").length
	_recovery_timer.start(anim_length)

func _on_recovery_timer_timeout():
	recovered.emit()

func longjump():
	state_machine.travel("Jump") # TODO: Replace with the longjump animation

func jump():
	state_machine.travel("Jump")

func double_jump():
	state_machine.travel("Double")

func triple_jump():
	state_machine.travel("Triple")

func backflip():
	state_machine.travel("Backflip")

func edge_grab():
	state_machine.travel("EdgeGrab")

func wall_slide():
	state_machine.travel("WallSlide")
