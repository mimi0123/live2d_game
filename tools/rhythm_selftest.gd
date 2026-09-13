extends SceneTree

## 音游链路自检（headless 用）
##
## 运行：
##   J:\live2d_game\engine\Godot.exe --headless --script res://tools/rhythm_selftest.gd
##
## 检查项：
##   1) rhythm_game.gd 能否实例化（_ready 通过）
##   2) 默认谱面能否解析，音符数是否 > 0
##   3) 谱面引用的 audio 资源能否 load() 成功
## 说明：headless 下不做真机渲染 / 顶点检查，只验链路。

func _initialize() -> void:
	var ok := true

	var s = load("res://scripts/gd/rhythm/rhythm_game.gd")
	if s == null:
		print("[自检] 失败：无法加载 rhythm_game.gd")
		quit(1)
		return

	var node = s.new()
	root.add_child(node)
	print("[自检] 1) 实例化 OK（_ready 已执行）")

	node._load_chart("res://data/rhythm_charts/demo_beat.json")
	var n_left: int = node._chart[0].size()
	var n_right: int = node._chart[1].size()
	print("[自检] 2) 谱面= " , node._current_chart_name,
		"  左轨=", n_left, " 右轨=", n_right, " 结束时刻=", node._end_time)
	if n_left + n_right <= 0:
		print("[自检] 失败：谱面没有音符")
		ok = false

	var ap: String = node._current_audio_path
	if ap == "":
		print("[自检] 3) 谱面未指定音频（用内部计时）")
	else:
		var st = load(ap)
		if st == null:
			print("[自检] 失败：音频加载不了 -> ", ap)
			ok = false
		else:
			print("[自检] 3) 音频 OK -> ", ap, "  时长=", st.get_length(), " s")

	node.free()
	print("[自检] 结果：", "通过" if ok else "未通过")
	quit(0 if ok else 1)
