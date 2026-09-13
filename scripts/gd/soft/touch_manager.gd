## SoftTouch 触点管理器（Live2D 版）
##
## 默认行为改为「鼠标悬停在模型表面 = 手指接触」，不要求按键。
## 若 hover_touch=false，则退回左键按住模式。
## hit_tester 负责回答「鼠标是否真的落在 Live2D 可见网格上」。

class_name TouchManager
extends Node

signal touch_began(position: Vector2)
signal touch_moved(position: Vector2, velocity: Vector2)
signal touch_ended(position: Vector2)
signal touch_held(position: Vector2, pressure: float, duration: float)

@export var enabled: bool = true
@export var follow_mouse: bool = true
@export var space_node: Node2D = null
@export var hit_tester: Node = null
## true = 鼠标碰到模型就接触；false = 必须按住 button。
@export var hover_touch: bool = true
@export var button: MouseButton = MOUSE_BUTTON_LEFT

@export_group("接触手感")
## 接触压力从 0→1 的时间。建议 0.16~0.30，旧版 0.5 太慢。
@export var pressure_ramp_time: float = 0.22
@export var radius_min: float = 72.0
@export var radius_max: float = 150.0

@export_group("鼠标平滑")
@export_range(0.01, 1.0, 0.01) var position_smoothing: float = 0.42
@export_range(0.01, 1.0, 0.01) var velocity_smoothing: float = 0.35
@export var velocity_deadzone: float = 5.0

var active: bool = false
var position: Vector2 = Vector2.ZERO
var velocity: Vector2 = Vector2.ZERO
var pressure: float = 0.0
var duration: float = 0.0
var radius: float = 72.0

var _last_vp_pos: Vector2 = Vector2.ZERO
var _last_space_pos: Vector2 = Vector2.ZERO
var _was_contact: bool = false
var _prev_pressure: float = 0.0

func _ready() -> void:
	set_process(true)

func _process(delta: float) -> void:
	if not enabled:
		if active:
			_ended(_last_vp_pos)
		return

	var vp_pos: Vector2 = get_viewport().get_mouse_position()
	var button_down: bool = Input.is_mouse_button_pressed(button)
	var contact: bool = false

	if follow_mouse:
		if hover_touch:
			var space_pos := to_space(vp_pos)
			contact = _test_contact(space_pos)
		else:
			contact = button_down

	if contact and not _was_contact:
		_began(vp_pos)
	elif not contact and _was_contact:
		_ended(vp_pos)

	if active:
		# ⚠ 只有 follow_mouse 打开时才跟随真实鼠标。
		#   否则（headless / simulate_* / force_state 注入）会把注入的触点
		#   又插值回真实鼠标位置，注入等于失效。
		if follow_mouse:
			var target_pos := to_space(vp_pos)
			if position_smoothing < 1.0:
				position = position.lerp(target_pos, clampf(position_smoothing, 0.0, 1.0))
			else:
				position = target_pos

			var raw_v: Vector2 = (position - _last_space_pos) / maxf(delta, 0.0001)
			velocity = velocity.lerp(raw_v, clampf(velocity_smoothing, 0.0, 1.0))
			if velocity.length() < velocity_deadzone:
				velocity = Vector2.ZERO

		duration += delta
		var ramp: float = maxf(pressure_ramp_time, 0.0001)
		pressure = clampf(duration / ramp, 0.0, 1.0)
		radius = lerpf(radius_min, radius_max, pressure)

		if velocity != Vector2.ZERO:
			touch_moved.emit(position, velocity)
		if pressure >= 1.0 and _prev_pressure < 1.0:
			touch_held.emit(position, pressure, duration)
		_prev_pressure = pressure

	_last_space_pos = position
	_last_vp_pos = vp_pos
	_was_contact = contact

func _test_contact(space_pos: Vector2) -> bool:
	if hit_tester == null or not is_instance_valid(hit_tester):
		return true
	if hit_tester.has_method("is_point_on_model"):
		return bool(hit_tester.call("is_point_on_model", space_pos))
	return true

func _began(vp_pos: Vector2) -> void:
	active = true
	duration = 0.0
	pressure = 0.0
	radius = radius_min
	position = to_space(vp_pos)
	_last_space_pos = position
	velocity = Vector2.ZERO
	touch_began.emit(position)

func _ended(_vp_pos: Vector2) -> void:
	var end_pos := position
	active = false
	pressure = 0.0
	radius = radius_min
	velocity = Vector2.ZERO
	_prev_pressure = 0.0
	touch_ended.emit(end_pos)

## 屏幕坐标 → 模型坐标（STEP 3 抽成纯函数，便于 headless 测试；
## 算式与原来完全一致，只是把两个变换显式传进来）
##   world = canvas_transform.affine_inverse() * vp_pos   ← 相机 / 画布缩放（Camera2D.zoom）
##   model = space_transform.affine_inverse() * world     ← 模型节点自身的 transform
static func screen_to_model(vp_pos: Vector2, canvas_transform: Transform2D,
		space_transform: Transform2D) -> Vector2:
	return space_transform.affine_inverse() * (canvas_transform.affine_inverse() * vp_pos)


func to_space(vp_pos: Vector2) -> Vector2:
	if space_node == null or not is_instance_valid(space_node):
		return vp_pos
	var vp := get_viewport()
	if vp == null:
		return vp_pos
	return screen_to_model(vp_pos, vp.get_canvas_transform(), space_node.get_global_transform())

func simulate_press(vp_pos: Vector2) -> void:
	follow_mouse = false
	_was_contact = true
	_began(vp_pos)

func simulate_move(vp_pos: Vector2, delta: float = 0.016) -> void:
	follow_mouse = false
	var prev: Vector2 = position
	position = to_space(vp_pos)
	var raw_v: Vector2 = (position - prev) / maxf(delta, 0.0001)
	velocity = velocity.lerp(raw_v, clampf(velocity_smoothing, 0.0, 1.0))
	duration += delta
	var ramp: float = maxf(pressure_ramp_time, 0.0001)
	pressure = clampf(duration / ramp, 0.0, 1.0)
	radius = lerpf(radius_min, radius_max, pressure)

func simulate_release() -> void:
	_ended(_last_vp_pos)
	_was_contact = false

## 直接设定触点状态（测试 / 注入用）。
## 会同时关掉 follow_mouse，否则下一帧就会被真实鼠标位置覆盖。
func force_state(pos: Vector2, is_active: bool, press: float = 1.0, r: float = 90.0) -> void:
	follow_mouse = false
	active = is_active
	position = pos
	pressure = press
	radius = r
	if is_active:
		duration = press * pressure_ramp_time
	else:
		duration = 0.0
		velocity = Vector2.ZERO
