extends Node

## InputManager - routes grid cursor and action input per player.
## P1: WASD + Space/E/Q/Tab/F + gamepad device 0
## P2: Arrow keys + Enter/Backspace/F1/End + gamepad device 1

const DEADZONE: float = 0.2

# Returns a Vector2i direction (-1/0/1 each axis) for cursor movement this frame.
# Called once per process tick; callers should apply repeat-delay themselves.
func get_cursor_dir(player_index: int) -> Vector2:
	var prefix := "p1_" if player_index == 0 else "p2_"
	var dir := Vector2.ZERO
	if Input.is_action_pressed(prefix + "cursor_up"):    dir.y -= 1.0
	if Input.is_action_pressed(prefix + "cursor_down"):  dir.y += 1.0
	if Input.is_action_pressed(prefix + "cursor_left"):  dir.x -= 1.0
	if Input.is_action_pressed(prefix + "cursor_right"): dir.x += 1.0
	if dir == Vector2.ZERO:
		var device := 0 if player_index == 0 else 1
		dir = _get_stick(device, 0)
	return dir.normalized() if dir.length() > DEADZONE else Vector2.ZERO

func is_confirm_pressed(player_index: int) -> bool:
	var prefix := "p1_" if player_index == 0 else "p2_"
	return Input.is_action_just_pressed(prefix + "confirm")

func is_cancel_pressed(player_index: int) -> bool:
	var prefix := "p1_" if player_index == 0 else "p2_"
	return Input.is_action_just_pressed(prefix + "cancel")

func is_shop_pressed(player_index: int) -> bool:
	var prefix := "p1_" if player_index == 0 else "p2_"
	return Input.is_action_just_pressed(prefix + "shop")

func is_sell_pressed(player_index: int) -> bool:
	var prefix := "p1_" if player_index == 0 else "p2_"
	return Input.is_action_just_pressed(prefix + "sell")

func _get_stick(device: int, stick: int) -> Vector2:
	var x_axis := JOY_AXIS_LEFT_X if stick == 0 else JOY_AXIS_RIGHT_X
	var y_axis := JOY_AXIS_LEFT_Y if stick == 0 else JOY_AXIS_RIGHT_Y
	return Vector2(
		Input.get_joy_axis(device, x_axis),
		Input.get_joy_axis(device, y_axis)
	)
