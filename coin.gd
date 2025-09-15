extends Area3D

@export var spin_speed: float = 10.0

func _physics_process(delta: float) -> void:
	$coin.rotate_y(spin_speed * delta)

func _on_body_entered(body: Node) -> void:
	if body is Player:
		print("Collected!")
		queue_free()
