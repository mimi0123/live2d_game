## 软体参数扫描（调参用 · headless）
##
## 运行：
##   J:\live2d_game\engine\Godot.exe --headless --script res://tools/soft_param_sweep.gd
##
## 五次失败换来的经验：
##   ① 速度式压力：刚性约束网里 99% 被抵消（累计推 31px 只凹 1.3px）
##   ② 位置式 + 双向约束：径向内向压 → 圆周弹簧崩溃 → 约束反抗，凹陷 0.1px
##   ③ 位置式 + 单向约束 + 自由网格：邻点被拽到边界 → 整块收缩（远端动 8px）
##   ④ 位置式 + 单向约束 + 钉边框：膜绷太紧，凹陷 0.7px
##   ⑤ 常驻锚定但 stiffness>=0.3：约束每帧解算等于刚度极高，力道被吃掉
##   ⑥ 低刚度(0.02~0.05)+迭代1 才真正软下来；再靠 follow_rate 把凹陷推到目标深度
##
## 结论公式（平衡位移）：x ≈ D * follow / (follow + c)
##   D = depth*衰减，follow = 1-exp(-follow_rate*dt)，c ≈ 约束每帧吃掉的拉伸比例
##   → 想让凹陷接近 D，就得让 follow >> c，即 follow_rate 要高（40+）。

extends SceneTree

const DT := 1.0 / 60.0
const STEPS := 120
const COLS := 20
const ROWS := 14
const SIZE := Vector2(500.0, 350.0)
const R := 60.0


func _initialize() -> void:
	var SoftMeshScript = load("res://scripts/gd/soft/soft_mesh.gd")
	var center: Vector2 = SIZE * 0.5

	print("\n===== follow_rate 扫描（R=%.0f, power=2.5, %d 帧, 锚定 1.6, 回弹 3）=====" % [R, STEPS])
	print("%-6s %-4s %-5s %-6s | %8s %8s %8s %7s %8s | %s" % [
		"stiff", "iter", "follow", "depth", "凹陷", "过渡", "远处", "拉伸", "峰值距离", "判定"])

	for stiff in [0.02, 0.05]:
		for iters in [1, 2]:
			for flw in [20.0, 40.0, 80.0]:
				for dep in [25.0, 45.0]:
					var r: Dictionary = _run(SoftMeshScript, center, stiff, iters, flw, dep)
					var verdict: String = "OK"
					if r["dent"] < 8.0:
						verdict = "凹太浅 ✗"
					elif r["far"] > r["dent"] * 0.10:
						verdict = "远处在动 ✗"
					elif r["stretch"] > 1.8:
						verdict = "网格拉坏 ✗"
					elif r["spread"] > r["dent"]:
						verdict = "整块动 ✗"
					print("%-6.3f %-4d %-5.0f %-6.0f | %8.2f %8.2f %8.3f %7.2f %8.1f | %s" % [
						stiff, iters, flw, dep, r["dent"], r["spread"], r["far"],
						r["stretch"], r["peak_dist"], verdict])

	print("\n判据：凹陷>=8px ｜ 远处<=凹陷10%% ｜ 拉伸<=1.8 ｜ 过渡<凹陷 ｜ 峰值距离<=%.0f" % R)
	quit(0)


func _run(SoftMeshScript, center: Vector2, stiff: float, iters: int,
		flw: float, dep: float) -> Dictionary:
	var m = SoftMeshScript.new()
	m.columns = COLS
	m.rows = ROWS
	m.mesh_size = SIZE
	m.pin_border = false
	m.constraint_iterations = iters
	m.stiffness = stiff
	m.allow_compression = true
	m.recovery_strength = 3.0
	m.anchor_scale = 1.6
	m.touch_power = 2.5
	m.build()

	m.solver.touch_active = true
	m.solver.touch_position = center
	m.solver.touch_radius = R
	m.solver.touch_power = 2.5
	m.solver.pressure_mode = "target"
	m.solver.depth = dep
	m.solver.follow_rate = flw
	m.solver.drag_strength = 0.0

	for _s in range(STEPS):
		m.solver.step(DT)

	var dent := 0.0
	var spread := 0.0
	var far := 0.0
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

	var stretch := 0.0
	for c in m.constraints:
		var pa = m.particles[c["a"]]
		var pb = m.particles[c["b"]]
		var rest: float = c["rest"]
		if rest <= 0.0001:
			continue
		stretch = maxf(stretch, pa.position.distance_to(pb.position) / rest)

	m.free()
	return {"dent": dent, "spread": spread, "far": far, "peak": peak,
		"peak_dist": peak_dist, "stretch": stretch}
