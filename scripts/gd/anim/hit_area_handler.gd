extends GDCubismEffectHitArea

@export var model:GDCubismUserModel
@export var root:Node2D

@onready var canvas_info: Dictionary = model.get_canvas_info()

var pressed: bool = false
var local_pos: Vector2 = Vector2.ZERO
var current_button_id: int
var current_area: String = ""

signal hit

func _input(event):
	if event as InputEventMouseButton:
		pressed = event.is_pressed()
		current_button_id = event.button_index
		# 仅在「命中区域内按下」时触发一次互动（一次按下只发一次 hit）
		if pressed and current_area != "":
			hit.emit(current_area, current_button_id)

	if event as InputEventMouseMotion:
		local_pos = model.to_local(event.position)

func _process(delta):
	if pressed == true:
		set_target(recalc_mouse_position(local_pos))
		
func recalc_mouse_position(position):
	if model.flip_h:
		position.x = -position.x
	
	if canvas_info.is_empty() != true:
		var vct_viewport_size = Vector2(root.get_viewport_rect().size)
		var scale: float = vct_viewport_size.y / max(canvas_info.size_in_pixels.x, canvas_info.size_in_pixels.y)
		position -= vct_viewport_size / 2.0
		position /= Vector2(scale, scale)
		if model.flip_h:
			position.x = -position.x
		
	return position

# 进入命中区域：只记录当前区域，不在进入时发射，避免与「按下」重复触发
func _on_hit_area_entered(model: GDCubismUserModel, id: String) -> void:
	current_area = id

# 离开命中区域：清空当前区域，修复「current_area 永久不清除导致之后每次点击都触发互动」的泄漏
func _on_hit_area_exited(model: GDCubismUserModel, id: String) -> void:
	if current_area == id:
		current_area = ""
