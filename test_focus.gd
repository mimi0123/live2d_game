extends Node
# 无头测试：键盘虚拟光标（聚焦位置）初始化与接口
# 运行: engine\Godot.exe --headless --path . res://test_focus_scene.tscn

func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var failures: Array = []
	var log: Array = []

	var RD = get_node_or_null("/root/RegionDetector")
	if RD == null:
		log.append("ERROR: 无法取得 RegionDetector")
		_print(false, log, failures)
		get_tree().quit(1)
		return

	_assert(RD.has_method("_click_at"), "存在 _click_at", failures, log)
	_assert(RD.has_method("_create_focus_cursor"), "存在 _create_focus_cursor", failures, log)

	# window.gd（滚轮缩放改 Camera2D.zoom + zoom-to-cursor）编译校验
	var wscr = load("res://scripts/gd/interact/window.gd")
	_assert(wscr != null, "window.gd 编译通过", failures, log)
	_assert(RD._cursor_node != null, "焦点光标节点已创建（CanvasLayer 下 Node2D）", failures, log)
	_assert(RD._focus_pos.x >= 0 and RD._focus_pos.y >= 0, "焦点位置为有效非负数", failures, log)
	if RD._cursor_node != null:
		_assert(RD._cursor_node.position.is_equal_approx(RD._focus_pos), "光标绘制位置 == 焦点位置", failures, log)

	# _set_focus 应同步更新焦点与光标节点位置
	RD._set_focus(Vector2(123, 456))
	_assert(RD._focus_pos.is_equal_approx(Vector2(123, 456)), "_set_focus 更新焦点位置", failures, log)
	if RD._cursor_node != null:
		_assert(RD._cursor_node.position.is_equal_approx(Vector2(123, 456)), "_set_focus 同步光标位置", failures, log)

	# model 为 null（测试场景无模型）时 _click_at 应安全返回、不崩溃
	RD._click_at(Vector2(10, 10))
	_assert(true, "_click_at 在 model=null 时安全返回（不崩溃）", failures, log)

	# F3 面板默认隐藏
	var DP = get_node_or_null("/root/DebugPanel")
	if DP != null and DP.has_method("_build_ui"):
		# 通过面板可见性间接校验：_panel 应在启动时可见=false
		_assert(DP._panel == null or DP._panel.visible == false, "F3 调试面板默认隐藏", failures, log)
	else:
		_assert(false, "无法取得 DebugPanel._panel", failures, log)

	_print(failures.is_empty(), log, failures)
	get_tree().quit(0 if failures.is_empty() else 1)

func _assert(cond: bool, msg: String, failures: Array, log: Array) -> void:
	if cond:
		log.append("PASS " + msg)
	else:
		failures.append(msg)
		log.append("FAIL " + msg)

func _print(ok: bool, log: Array, failures: Array = []) -> void:
	print("==== 虚拟光标/输入 无头测试 ====")
	for l in log:
		print(l)
	print("==== 结果: " + ("PASS" if ok else "FAIL"))
	if not ok:
		print("失败项: ", failures)
