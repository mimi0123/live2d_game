## SoftPhysicsTest 场景控制器（SoftTouch 模块 · STEP 1 的验证场）
##
## 这一版**完全不碰 Live2D**：只有一个 2D 网格 + 鼠标。
## 目的只有一个 —— 验证「按哪里，哪里变形」。
## 如果这个基础物理都不自然，把 Live2D 搬进来也救不了。
##
## 全部节点在代码里搭（不依赖 .tscn 里的节点连线），所以这个场景很稳。
##
## 运行：
##   J:\live2d_game\engine\Godot.exe --path J:\live2d_game res://scenes/SoftPhysicsTest.tscn
## 或双击 J:\live2d_game\run_softtest.bat

extends Node2D

const GRID_SIZE := Vector2(500.0, 350.0)
const VIEW := Vector2(640.0, 640.0)

var mesh: SoftMesh
var touch: TouchManager
var hud: Label
var bg: ColorRect

# 对比开关
var gravity_on: bool = false
var field_on: bool = true


func _ready() -> void:
	_build_background()
	_build_mesh()
	_build_touch()
	_build_hud()
	print("[SoftPhysicsTest] 就绪：%d×%d 网格，%d 质点 / %d 约束"
		% [mesh.columns, mesh.rows, mesh.particles.size(), mesh.constraints.size()])


func _build_background() -> void:
	bg = ColorRect.new()
	bg.color = Color(0.055, 0.06, 0.085)
	bg.size = VIEW
	bg.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var cl := CanvasLayer.new()
	cl.layer = -10
	add_child(cl)
	cl.add_child(bg)


func _build_mesh() -> void:
	mesh = SoftMesh.new()
	mesh.name = "SoftMesh"
	mesh.columns = 20
	mesh.rows = 14
	mesh.mesh_size = GRID_SIZE
	# 让网格居中（视图 640×640）
	mesh.position = (VIEW - GRID_SIZE) * 0.5
	mesh.pin_border = false
	mesh.show_original_shape = true
	add_child(mesh)


func _build_touch() -> void:
	touch = TouchManager.new()
	touch.name = "TouchManager"
	touch.space_node = mesh          # 坐标换算到网格局部坐标
	touch.button = MOUSE_BUTTON_LEFT
	touch.radius_min = 70.0
	touch.radius_max = 150.0
	touch.pressure_ramp_time = 0.45
	add_child(touch)


func _build_hud() -> void:
	var cl := CanvasLayer.new()
	cl.layer = 500
	add_child(cl)
	hud = Label.new()
	hud.position = Vector2(14, 10)
	hud.add_theme_font_size_override("font_size", 15)
	hud.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	cl.add_child(hud)


func _process(_delta: float) -> void:
	# 触点状态 -> 网格
	if touch.active:
		mesh.set_touch(touch.position, true, touch.velocity, touch.pressure, touch.radius)
	else:
		mesh.release()
	_update_hud()


func _update_hud() -> void:
	var t: TouchManager = touch
	var m: SoftMesh = mesh
	var max_off: float = m.max_offset()
	# 远端位移：触点影响半径之外应恒为 0（证明「不再整块矩形一起动」）
	var far_off: float = _far_offset(t.position, t.radius * 1.5)
	hud.text = "\n".join([
		"SoftPhysicsTest   —   SoftTouch 软体原型 (STEP 1~3)",
		"",
		"按住鼠标左键 → 局部凹陷；松手 → 回弹",
		"R 复位   G 重力=%s   P 钉边框=%s   C 压力场=%s" % [
			"ON" if gravity_on else "OFF",
			"ON" if m.pin_border else "OFF",
			"ON" if field_on else "OFF"],
		", / .  影响半径 = %.0f      - / =  衰减指数 = %.1f" % [t.radius, m.touch_power],
		"[ / ]  网格密度 %d×%d      ESC 退出" % [m.columns, m.rows],
		"",
		"触点  模式=%s  压力=%.2f  半径=%.0f  速度=%.0f px/s" % [
			"按下" if t.active else "松开", t.pressure, t.radius, t.velocity.length() * 60.0],
		"变形  最大位移=%.1f px     半径外位移=%.2f px (应≈0)" % [max_off, far_off],
		"网格  %d 质点 / %d 约束 / 迭代 %d 次" % [
			m.particles.size(), m.constraints.size(), m.constraint_iterations],
	])


## 触点影响半径之外的质点的最大位移 —— 用于证明变形是局部的
func _far_offset(center: Vector2, beyond: float) -> float:
	var worst: float = 0.0
	for p in mesh.particles:
		if p.original_position.distance_to(center) <= beyond:
			continue
		worst = maxf(worst, p.offset_from_original().length())
	return worst


# =====================================================================
#  交互
# =====================================================================
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := (event as InputEventKey).keycode
	match k:
		KEY_ESCAPE:
			get_tree().quit()
		KEY_R:
			mesh.reset()
			print("[SoftPhysicsTest] 已复位")
		KEY_G:
			gravity_on = not gravity_on
			mesh.gravity = Vector2(0, 900.0) if gravity_on else Vector2.ZERO
		KEY_P:
			mesh.pin_border = not mesh.pin_border
			mesh.rebuild()
		KEY_C:
			field_on = not field_on
			mesh.solver.pressure_enabled = field_on
		KEY_COMMA:
			touch.radius_min = maxf(20.0, touch.radius_min - 10.0)
			touch.radius_max = maxf(touch.radius_min + 10.0, touch.radius_max - 10.0)
		KEY_PERIOD:
			touch.radius_min += 10.0
			touch.radius_max += 10.0
		KEY_MINUS:
			mesh.touch_power = maxf(1.0, mesh.touch_power - 0.5)
		KEY_EQUAL:
			mesh.touch_power = minf(12.0, mesh.touch_power + 0.5)
		KEY_BRACKETLEFT:
			_resize_grid(-4)
		KEY_BRACKETRIGHT:
			_resize_grid(4)
		_:
			return
	get_viewport().set_input_as_handled()


func _resize_grid(d: int) -> void:
	mesh.columns = clampi(mesh.columns + d, 6, 48)
	mesh.rows = clampi(mesh.rows + int(round(float(d) * 0.7)), 4, 36)
	mesh.rebuild()
	print("[SoftPhysicsTest] 网格 -> %d×%d（%d 质点 / %d 约束）"
		% [mesh.columns, mesh.rows, mesh.particles.size(), mesh.constraints.size()])
