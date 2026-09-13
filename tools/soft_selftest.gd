## SoftTouch 链路自检（headless）
##
## 运行：
##   J:\live2d_game\engine\Godot.exe --headless --script res://tools/soft_selftest.gd
##
## 本工具验证的是 **正式默认参数**（不覆盖 mesh 的 @export 默认值），
## 所以它同时充当「回归测试」：以后谁改了默认参数，跑一遍就知道手感还在不在。
##
## 检查项（纯数学，headless 可验）：
##   1) 五个脚本能否加载（编译通过）
##   2) 压力场衰减是否单调、边界是否为 0
##   3) 网格生成：质点数 / 约束数
##   4) 按压 120 帧：凹陷是否够深、峰值是否在影响圈内、
##      2×半径外是否几乎不动（这是"不再是矩形整体变形"的硬指标）
##   5) 松手 240 帧：残余位移是否 < 峰值的 5%（回弹）
##   6) 全程无 NaN
##
## 真机手感仍需 Master 亲眼看，这里只验链路与数值健全性。

extends SceneTree

const STEPS_PRESS := 120
const STEPS_RELEASE := 240
const DT := 1.0 / 60.0

# 判定门槛
const MIN_DENT := 5.0          # 凹陷至少这么多像素才算"按得动"
const MAX_FAR_RATIO := 0.10    # 圈外位移 / 凹陷 的上限
const MAX_RESIDUAL := 0.05     # 松手后残余 / 峰值 的上限

var fails: Array = []
var ok := true


func _initialize() -> void:
	# ---- 1) 脚本加载 ----
	var paths := [
		"res://scripts/gd/soft/soft_particle.gd",
		"res://scripts/gd/soft/pressure_field.gd",
		"res://scripts/gd/soft/soft_solver.gd",
		"res://scripts/gd/soft/soft_mesh.gd",
		"res://scripts/gd/soft/touch_manager.gd",
	]
	var loaded := 0
	for p in paths:
		if load(p) != null:
			loaded += 1
		else:
			_fail("加载失败: " + p)
	print("[自检] 1) 脚本加载 %d/%d" % [loaded, paths.size()])
	if loaded < paths.size():
		_report()
		return

	var PF = load("res://scripts/gd/soft/pressure_field.gd")
	var SoftMeshScript = load("res://scripts/gd/soft/soft_mesh.gd")

	# ---- 2) 压力场曲线 ----
	print("\n[自检] 2) 压力场衰减（radius=100, power=4）")
	var last := 1.1
	var monotonic := true
	for d in [0.0, 10.0, 25.0, 50.0, 75.0, 90.0, 99.0, 100.0, 101.0, 150.0]:
		var f: float = PF.falloff(d, 100.0, 4.0)
		if f > last + 0.0001:
			monotonic = false
		last = f
		print("     距离 %6.1f -> 影响 %.4f  %s" % [d, f, _bar(f)])
	if not monotonic:
		_fail("压力场不是单调递减")
	if absf(PF.falloff(0.0, 100.0, 4.0) - 1.0) > 0.0001:
		_fail("中心影响不为 1.0")
	if PF.falloff(100.0, 100.0, 4.0) != 0.0 or PF.falloff(150.0, 100.0, 4.0) != 0.0:
		_fail("半径外影响不为 0")

	# ---- 3) 网格生成（用默认参数）----
	var m = SoftMeshScript.new()
	m.build()
	var expect_p: int = m.columns * m.rows
	var expect_c: int = (m.columns - 1) * m.rows + (m.rows - 1) * m.columns \
		+ (m.columns - 1) * (m.rows - 1)
	print("\n[自检] 3) 网格 %d×%d -> 质点 %d（期望 %d）/ 约束 %d（期望 %d）"
		% [m.columns, m.rows, m.particles.size(), expect_p, m.constraints.size(), expect_c])
	if m.particles.size() != expect_p:
		_fail("质点数不符")
	if m.constraints.size() != expect_c:
		_fail("约束数不符")
	print("     出货默认：stiffness=%.2f 迭代=%d 抗压=%s follow=%.0f depth=%.0f 回弹=%.1f 锚定=%.1f"
		% [m.stiffness, m.constraint_iterations, "是" if m.allow_compression else "否",
			m.follow_rate, m.touch_depth, m.recovery_strength, m.anchor_scale])

	# ---- 4) 按压 ----
	var center: Vector2 = m.mesh_size * 0.5
	var R: float = 60.0
	# 与游戏完全同一条路径：set_touch 注入触点 -> push_to_solver 推给求解器
	m.set_touch(center, true, Vector2.ZERO, 1.0, R)
	m.push_to_solver()

	print("\n[自检] 4) 在中心 %s 按住 %d 帧（半径 %.0f，压力满档）" % [str(center), STEPS_PRESS, R])
	var nan_seen := false
	for _s in range(STEPS_PRESS):
		m.push_to_solver()      # 每帧都推，与 _physics_process 完全一致
		m.solver.step(DT)
		if _has_nan(m):
			nan_seen = true
			break

	var dent := 0.0
	var far := 0.0
	var spread := 0.0
	var peak := 0.0
	var peak_dist := 0.0
	for p in m.particles:
		var off: float = p.offset_from_original().length()
		var d: float = p.original_position.distance_to(center)
		if d <= R * 0.5:
			dent = maxf(dent, off)
		elif d > R and d <= R * 1.5:
			spread = maxf(spread, off)
		if d > R * 2.0:
			far = maxf(far, off)
		if off > peak:
			peak = off
			peak_dist = d

	print("     半径带 -> 位移范围(px)")
	for row in _profile(m, center, R):
		print("     %-12s %.2f ~ %.2f" % [row["label"], row["min_off"], row["max_off"]])
	print("\n     变形分布（越亮位移越大；触点行标出）：")
	_heatmap(m, center)

	var far_ratio: float = far / maxf(dent, 0.0001)
	print("\n     凹陷(0~0.5R) = %.2f px     过渡(1~1.5R) = %.2f px     2R外 = %.4f px"
		% [dent, spread, far])
	print("     圈外/凹陷 = %.2f%%（要求 <= %.0f%%）   峰值距离 = %.1f（要求 <= %.0f）"
		% [far_ratio * 100.0, MAX_FAR_RATIO * 100.0, peak_dist, R])
	if nan_seen:
		_fail("按压阶段出现 NaN")
	if dent < MIN_DENT:
		_fail("凹陷太浅（%.2f px < %.0f px）：压力没传导到质点" % [dent, MIN_DENT])
	if far_ratio > MAX_FAR_RATIO:
		_fail("圈外位移过大（%.2f%% > %.0f%%）：又变成整体变形了"
			% [far_ratio * 100.0, MAX_FAR_RATIO * 100.0])
	if peak_dist > R * 1.2:
		_fail("位移峰值跑出影响圈（距离 %.1f > %.1f）" % [peak_dist, R * 1.2])

	# ---- 5) 松手回弹 ----
	print("\n[自检] 5) 松手回弹 %d 帧" % STEPS_RELEASE)
	m.release()
	for _s in range(STEPS_RELEASE):
		m.push_to_solver()      # 松手后同样每帧推：把 touch_active=false 传给求解器
		m.solver.step(DT)
		if _has_nan(m):
			nan_seen = true
			break
	var residual: float = m.solver.max_offset()
	var ratio: float = residual / maxf(peak, 0.0001)
	print("     峰值 %.2f px -> 残余 %.4f px（%.2f%%，要求 <= %.0f%%）"
		% [peak, residual, ratio * 100.0, MAX_RESIDUAL * 100.0])
	if nan_seen:
		_fail("回弹阶段出现 NaN")
	if ratio > MAX_RESIDUAL:
		_fail("回弹不完全（残余 %.1f%%）" % (ratio * 100.0))

	m.free()
	_report()
	quit(0 if ok else 1)


# =====================================================================
#  工具
# =====================================================================
func _fail(msg: String) -> void:
	fails.append(msg)
	ok = false


func _report() -> void:
	if fails.is_empty():
		print("\n[自检] 结果：通过")
	else:
		print("\n[自检] 结果：未通过")
		for f in fails:
			print("       ✗ ", f)


func _has_nan(m) -> bool:
	for p in m.particles:
		if is_nan(p.position.x) or is_nan(p.position.y):
			return true
	return false


func _profile(m, center: Vector2, R: float) -> Array:
	var bands := [
		{"label": "0~0.25R", "lo": 0.0, "hi": 0.25},
		{"label": "0.25~0.5R", "lo": 0.25, "hi": 0.5},
		{"label": "0.5~0.75R", "lo": 0.5, "hi": 0.75},
		{"label": "0.75~1R", "lo": 0.75, "hi": 1.0},
		{"label": "1R~1.5R", "lo": 1.0, "hi": 1.5},
		{"label": "1.5~2R", "lo": 1.5, "hi": 2.0},
		{"label": "2R 外", "lo": 2.0, "hi": 99.0},
	]
	var out: Array = []
	for b in bands:
		var lo: float = b["lo"] * R
		var hi: float = b["hi"] * R
		var mn := INF
		var mx := 0.0
		var n := 0
		for p in m.particles:
			var d: float = p.original_position.distance_to(center)
			if d < lo or d >= hi:
				continue
			var off: float = p.offset_from_original().length()
			mn = minf(mn, off)
			mx = maxf(mx, off)
			n += 1
		if n == 0:
			continue
		out.append({"label": b["label"], "min_off": mn, "max_off": mx})
	return out


func _heatmap(m, center: Vector2) -> void:
	var ramp := " .:-=+*#%@"
	var peak := 0.0001
	for p in m.particles:
		peak = maxf(peak, p.offset_from_original().length())
	var ty: int = int(round((center.y / m.mesh_size.y) * float(m.rows - 1)))
	var tx: int = int(round((center.x / m.mesh_size.x) * float(m.columns - 1)))
	for y in range(m.rows):
		var line := "     "
		for x in range(m.columns):
			var p = m.particles[y * m.columns + x]
			var t: float = clampf(p.offset_from_original().length() / peak, 0.0, 1.0)
			line += ramp[int(round(t * float(ramp.length() - 1)))]
		if y == ty:
			line += "   <- 触点行(触点列 %d)" % tx
		print(line)


func _bar(f: float) -> String:
	var n: int = int(round(f * 20.0))
	return "[" + "#".repeat(n) + ".".repeat(20 - n) + "]"
