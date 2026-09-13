extends Node2D
# 无头测试：滚轮 zoom-to-cursor 数学正确性（用真实 Camera2D）
# 运行: engine\Godot.exe --headless --path . res://test_zoom_scene.tscn

func _ready() -> void:
	await get_tree().process_frame
	var failures: Array = []
	var log: Array = []

	var cam: Camera2D = $Camera2D
	cam.zoom = Vector2(0.8, 0.8)
	cam.position = Vector2(60, -40)
	await get_tree().process_frame

	var sc: Vector2 = get_viewport().get_visible_rect().size
	var sp: Vector2 = sc * 0.5 + Vector2(37, -19)   # 任意屏幕点（模拟“鼠标当前位置”）

	# 地面真值：canvas_transform（即 Godot 渲染用的 世界->屏幕 变换）
	var world_before: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * sp
	# 交叉验证：屏幕中心应映射到相机位置（确认 canvas_transform 确实包含相机变换）
	var center_world: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * (sc * 0.5)
	_assert(center_world.is_equal_approx(cam.position), "屏幕中心映射到相机位置（canvas_transform 含相机）", failures, log)

	# 放大方向
	var new_zoom: float = clampf(cam.zoom.x * 1.5, 0.3, 6.0)
	var wb: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * sp
	cam.zoom = Vector2(new_zoom, new_zoom)
	await get_tree().process_frame
	var wa: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * sp
	cam.position += wb - wa
	await get_tree().process_frame
	var world_final: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * sp
	_assert(world_final.is_equal_approx(world_before), "放大后鼠标下的世界点保持不变（zoom-to-cursor）", failures, log)
	_assert(abs(cam.zoom.x - new_zoom) < 1e-4, "zoom 已实际应用", failures, log)

	# 缩小方向
	var wb2: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * sp
	cam.zoom = Vector2(clampf(cam.zoom.x * 0.5, 0.3, 6.0), clampf(cam.zoom.x * 0.5, 0.3, 6.0))
	await get_tree().process_frame
	var wa2: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * sp
	cam.position += wb2 - wa2
	await get_tree().process_frame
	var world_final2: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * sp
	_assert(world_final2.is_equal_approx(world_before), "缩小后鼠标下的世界点也保持不变", failures, log)

	# 复现“启动即贴近下限、无法缩小”的场景：从典型适配 zoom≈0.29 往下滚
	cam.zoom = Vector2(0.29, 0.29)
	cam.position = Vector2.ZERO
	await get_tree().process_frame
	var before_out: float = cam.zoom.x
	var wbo: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * sp
	cam.zoom = Vector2(clampf(before_out / 1.1, 0.05, 6.0), clampf(before_out / 1.1, 0.05, 6.0))
	await get_tree().process_frame
	var wao: Vector2 = get_viewport().get_canvas_transform().affine_inverse() * sp
	cam.position += wbo - wao
	await get_tree().process_frame
	_assert(cam.zoom.x < before_out - 1e-4, "从适配 zoom 往下滚能真正缩小（修复『无法缩小』）", failures, log)

	_print(failures.is_empty(), log, failures)
	get_tree().quit(0 if failures.is_empty() else 1)

func _assert(cond: bool, msg: String, failures: Array, log: Array) -> void:
	if cond:
		log.append("PASS " + msg)
	else:
		failures.append(msg)
		log.append("FAIL " + msg)

func _print(ok: bool, log: Array, failures: Array = []) -> void:
	print("==== 滚轮 zoom-to-cursor 测试 ====")
	for l in log:
		print(l)
	print("==== 结果: " + ("PASS" if ok else "FAIL"))
	if not ok:
		print("失败项: ", failures)
