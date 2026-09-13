extends Node

@export var enable: bool = true
@export var controller: AnimationController
@export var model: GDCubismUserModel
@export var particle: GPUParticles2D

# 抚摸粒子改成短促脉冲：触发后亮 0.45s 自动关闭，不再常亮
var _off_timer: Timer

func _ready() -> void:
	_off_timer = Timer.new()
	_off_timer.wait_time = 0.45
	_off_timer.one_shot = true
	_off_timer.timeout.connect(_turn_off_particle)
	add_child(_off_timer)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and enable:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_stroke(event.is_pressed())

func _stroke(pressing: bool) -> void:
	if pressing:
		particle.emitting = true
		_off_timer.stop()
	else:
		particle.emitting = false

func _turn_off_particle() -> void:
	particle.emitting = false

func _on_hit_area(id: String, button_id: int) -> void:
	# 鼠标在命中区域内点击 = 抚摸互动 -> 触发对应对话
	if button_id == MOUSE_BUTTON_RIGHT or button_id == MOUSE_BUTTON_LEFT:
		_stroke(true)
		_off_timer.start()
		Dialogue.interact(id)
