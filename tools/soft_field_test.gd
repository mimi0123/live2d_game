## SoftTouch STEP 2 验收测试（纯数学，headless 可跑）
##
## 运行：
##   J:\live2d_game\engine\Godot.exe --headless --script res://tools/soft_field_test.gd
##
## 为什么要有这个测试：
##   STEP 2 换掉了「径向速度式压力 + smooth_falloff」的旧场，改成
##   「平顶平滑肩 profile + 朝内位移几何上限」。这两条是纯数学，
##   不需要 Live2D、不需要 GPU，所以必须在这里把它们钉死，
##   免得以后有人调参把「不穿过触点」这条底线调没了。
##
## 检查项：
##   1) 参数取自 SoftMeshDeformer 实例（保证与出货默认值同步，而不是硬编码抄一遍）
##   2) profile：中心=1、平顶内恒 1、半径处=0、半径外=0、全程单调不增、无 NaN
##   3) 位移场 A(d) = min(depth*prof, cross_limit*d)：
##        · A(d)/d <= cross_limit 恒成立  ← 「顶点永不穿过触点」
##        · 峰值必须达到 depth 的 85% 以上 ← 「凹陷真的压得下去」
##        · 峰值半径之外单调衰减           ← 「不是矩形、不是黑洞」
##   4) 影响半径外位移严格为 0（局部化）

extends SceneTree

const SAMPLE_N := 400


func _init() -> void:
	print("[场测试] STEP 2 影响场 / 几何上限验收")
	var ok := true

	# ── 1) 从出货实例读参数，避免测试和代码脱节 ──
	var d := SoftMeshDeformer.new()
	var R: float = d.radius
	var depth: float = d.depth
	var flat: float = d.flat_top
	var power: float = d.power
	var cross: float = d.cross_limit
	d.free()
	print("  参数(来自 SoftMeshDeformer 默认值): R=%.1f depth=%.1f flat_top=%.2f power=%.2f cross_limit=%.2f"
		% [R, depth, flat, power, cross])

	# ── 2) profile 性质 ──
	var f0: float = PressureField.soft_press_profile(0.0, R, flat, power)
	var f_flat: float = PressureField.soft_press_profile(R * flat * 0.999, R, flat, power)
	var f_edge: float = PressureField.soft_press_profile(R, R, flat, power)
	var f_out: float = PressureField.soft_press_profile(R * 1.5, R, flat, power)
	print("  profile: f(0)=%.4f  f(平顶内)=%.4f  f(R)=%.4f  f(1.5R)=%.4f" % [f0, f_flat, f_edge, f_out])
	if absf(f0 - 1.0) > 0.0001 or absf(f_flat - 1.0) > 0.0001:
		print("  ✗ 平顶区压力不为 1"); ok = false
	if f_edge > 0.0001 or f_out > 0.0001:
		print("  ✗ 影响半径处/外不为 0"); ok = false

	var prev := 1.0
	var monotone := true
	var nan_seen := false
	for i in SAMPLE_N + 1:
		var dist: float = R * 1.2 * float(i) / float(SAMPLE_N)
		var f: float = PressureField.soft_press_profile(dist, R, flat, power)
		if is_nan(f):
			nan_seen = true
		if f > prev + 0.000001:
			monotone = false
		prev = f
	print("  单调不增         : %s" % ("是 ✓" if monotone else "否 ✗"))
	print("  无 NaN           : %s" % ("是 ✓" if not nan_seen else "否 ✗"))
	if not monotone or nan_seen:
		ok = false

	# ── 3) 位移场与几何上限 ──
	var peak := 0.0
	var peak_d := 0.0
	var worst_ratio := 0.0
	var outside_moved := 0.0
	for i in SAMPLE_N * 2 + 1:
		var dist: float = R * 1.2 * float(i) / float(SAMPLE_N * 2)
		var amp: float = depth * PressureField.soft_press_profile(dist, R, flat, power)
		var limit_amp: float = dist * cross
		if amp > limit_amp:
			amp = limit_amp
		if dist > 0.001:
			worst_ratio = maxf(worst_ratio, amp / dist)
		if amp > peak:
			peak = amp
			peak_d = dist
		if dist >= R:
			outside_moved = maxf(outside_moved, amp)

	print("  位移场峰值       : %.2f px @ d=%.1f px  (depth 的 %.0f%%)" % [peak, peak_d, peak / maxf(depth, 0.001) * 100.0])
	print("  最大 A(d)/d      : %.3f   （cross_limit=%.2f，必须 <= 它）" % [worst_ratio, cross])
	print("  半径外最大位移   : %.4f px" % outside_moved)
	if worst_ratio > cross + 0.0001:
		print("  ✗ 有顶点会穿过触点"); ok = false
	if peak < depth * 0.85:
		print("  ✗ 峰值不足 depth 的 85%%（凹陷压不下去）"); ok = false
	if outside_moved > 0.0001:
		print("  ✗ 影响半径外出现位移（局部化被破坏）"); ok = false

	# ── 4) 关键半径的位移剖面（人眼可读）──
	print("  ── 径向位移剖面（离触点距离 -> 实际位移）──")
	var line := ""
	for dist2 in [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.7, 0.9, 1.0, 1.2, 1.5]:
		var dd: float = R * float(dist2)
		var a2: float = depth * PressureField.soft_press_profile(dd, R, flat, power)
		a2 = minf(a2, dd * cross)
		line += "  %.1fR=%.1f" % [dist2, a2]
	print(line)

	print("[场测试] 结果：%s" % ("通过" if ok else "未通过"))
	quit(0 if ok else 1)
