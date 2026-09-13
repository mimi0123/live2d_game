## HandContact / HandRig / ContactBlend 验收测试（SoftTouch 模块 · STEP 3）
##
## 运行：
##   J:\live2d_game\engine\Godot.exe --headless --path . --script res://tools/hand_contact_test.gd
##
## 为什么要有这个测试：
##   STEP 3 把「一个圆」升级成「一只手」，最大的风险不是「不像手」，
##   而是**多触点叠加爆炸**（Palm 40px + Finger 30px = 70px 局部塌陷）。
##   这种错误在真机上表现为「越按越烂」，很难从截图看出来，
##   所以必须在纯数学层面钉死。
##
## 覆盖 Master 指定的 A~J 十项：
##   A 单 Palm              B Palm + 1 Finger      C Palm + 3 Fingers
##   D 不同 rotation        E 不同 pressure        F 多触点重叠不爆炸
##   G Camera zoom 不影响 model-space radius
##   H 静止时 direction 不抖动                      I velocity=0 不出 NaN
##   J 所有 contact inactive → deformation = 0
##
## 参数来源：SoftMeshDeformer 的**出货默认值**（不硬编码抄一遍），
## 这样以后谁改了默认值，这里会跟着一起变。
##
## 实现注记：测试体必须放在 _initialize ——
## 工程里 legacy 的 ScreenDeform._setup() 在没有 current_scene 时会无限
## call_deferred 重排自己（screen_deform.gd:71），一旦开始跑场景树就必崩
## 段错误。放在 _initialize 里可以在场景树启动前跑完全部断言并 quit。
## 因此本测试**不依赖场景树**（G 项改用 TouchManager.screen_to_model 纯函数）。

extends SceneTree

var fails: Array = []
var ok := true

# 出货参数（_initialize 里从 SoftMeshDeformer 实例读出）
var DEPTH := 42.0
var FLAT := 0.34
var POWER := 1.8
var CROSS := 0.80
var VOL := 0.13
var DRAG := 0.22
var MAXDISP := 85.0


func _initialize() -> void:
	print("======================================================================")
	print("[手部测试] STEP 3 —— HandContact / HandRig / ContactBlend")
	print("======================================================================")
	var d := SoftMeshDeformer.new()
	DEPTH = d.depth
	FLAT = d.flat_top
	POWER = d.power
	CROSS = d.cross_limit
	VOL = d.volume_compensation
	DRAG = d.drag_amount
	MAXDISP = d.max_displacement
	d.free()
	print("出货参数：depth=%.1f flat_top=%.2f power=%.2f cross_limit=%.2f vol=%.2f drag=%.2f max_disp=%.1f"
		% [DEPTH, FLAT, POWER, CROSS, VOL, DRAG, MAXDISP])
	print("（这几项 Master 已冻结，本测试只读不改）")

	_test_A_single_palm()
	_test_B_palm_one_finger()
	_test_C_palm_three_fingers()
	_test_D_rotation()
	_test_E_pressure()
	_test_F_overlap_no_explosion()
	_test_G_camera_zoom()
	_test_H_still_no_jitter()
	_test_I_zero_velocity_nan()
	_test_J_all_inactive_zero()

	_report()
	quit(0 if ok else 1)


# =====================================================================
#  A. 单 Palm
# =====================================================================
func _test_A_single_palm() -> void:
	print("\n──────────────────────────────────────────────")
	print("A) 单 Palm")
	var rig := _make_rig(0)                       # 0 根手指 = 只有掌心
	var c: Array = rig.build_contacts(Vector2(1000, 2000), Vector2.RIGHT, 1.0, Vector2.ZERO, true)
	print("  接触数            : %d（期望 1）" % c.size())
	_check(c.size() == 1, "A: 单 Palm 产出 1 颗接触")
	if c.size() != 1:
		rig.free()
		return
	var palm = c[0]
	print("  %s" % palm.describe())
	print("  类型 / 半径       : %s / %.1f（期望 PALM / %.1f）"
		% [HandContact.TYPE_NAMES[palm.type], palm.radius, rig.palm_radius])
	_check(palm.type == HandContact.Type.PALM, "A: 首颗接触类型为 PALM")
	_check(is_equal_approx(palm.radius, rig.palm_radius), "A: 半径等于 palm_radius")
	_check(palm.position.is_equal_approx(Vector2(1000, 2000)), "A: 掌心中心落在触点上")

	# 顶点在掌心正下方 60px：应被压下去，且不超过 dist*cross_limit
	var v := Vector2(1000, 2060)
	var disp: Vector2 = ContactBlend.merge(v, c, DEPTH, FLAT, POWER, VOL, DRAG, CROSS, 0.0)
	var inward: float = -disp.dot((v - palm.position).normalized())
	print("  60px 处位移       : %.2f px（朝内 %.2f px，上限 %.2f px：depth/指半径剖面 / cross_limit）"
		% [disp.length(), inward, 60.0 * CROSS])
	_check(disp.length() > 5.0, "A: 60px 处产生可见凹陷（>5px）")
	_check(inward <= 60.0 * CROSS + 0.01, "A: 朝内位移不超过 dist*cross_limit")
	rig.free()


# =====================================================================
#  B. Palm + 1 Finger
# =====================================================================
func _test_B_palm_one_finger() -> void:
	print("\n──────────────────────────────────────────────")
	print("B) Palm + 1 Finger")
	var rig := _make_rig(1)
	var center := Vector2(1000, 2000)
	var c: Array = rig.build_contacts(center, Vector2.RIGHT, 1.0, Vector2.ZERO, true)
	print("  接触数            : %d（期望 2）" % c.size())
	_check(c.size() == 2, "B: Palm + 1 Finger 共 2 颗")
	for x in c:
		print("  %s" % x.describe())
	if c.size() != 2:
		rig.free()
		return
	var f = c[1]
	var d_f: float = f.position.distance_to(center)
	print("  指尖离掌心        : %.1f px（期望 %.1f）" % [d_f, rig.finger_distance])
	_check(absf(d_f - rig.finger_distance) < 0.01, "B: 指尖距离等于 finger_distance")
	_check(f.weight < c[0].weight, "B: 手指权重小于掌心（更浅）")
	_check(f.type == HandContact.Type.FINGER, "B: 第二颗类型为 FINGER")
	rig.free()


# =====================================================================
#  C. Palm + 3 Fingers —— 必须能同时产生多个局部压力区
# =====================================================================
func _test_C_palm_three_fingers() -> void:
	print("\n──────────────────────────────────────────────")
	print("C) Palm + 3 Fingers —— 多个局部压力区")
	var rig := _make_rig(3)
	var center := Vector2(1000, 2000)
	var c: Array = rig.build_contacts(center, Vector2.RIGHT, 1.0, Vector2.ZERO, true)
	print("  接触数            : %d（期望 4）" % c.size())
	_check(c.size() == 4, "C: Palm + 3 Fingers 共 4 颗")
	if c.size() != 4:
		rig.free()
		return
	print("  参数              : 掌心 r=%.0f  手指 r=%.0f  间距=%.0f  指距掌心=%.0f"
		% [rig.palm_radius, rig.finger_radius, rig.finger_spacing, rig.finger_distance])
	for x in c:
		print("  %s" % x.describe())

	# ── 判据：把「位移 >= 4px」的区域做连通域分析，看能分出几块独立压痕 ──
	var res := _analyze_regions(c)
	print("  采样峰值          : %.2f px（步长 %.0f，%d 个采样点）"
		% [res["peak"], res["step"], res["count"]])
	_check(_as_float(res["peak"]) > 5.0, "C: 手部整体产生可见位移")

	var comps: Array = res["components"]
	print("  独立压痕连通域    : %d 块（判据：位移≥%.0fpx 的连通区域，且 >=%d 个采样格）"
		% [comps.size(), REGION_THRESH, MIN_REGION_CELLS])
	for i in comps.size():
		var comp: Dictionary = comps[i]
		var centroid: Vector2 = comp["centroid"]
		var near := "无"
		var best_d := INF
		for x in c:
			var dd: float = centroid.distance_to(x.position)
			if dd < best_d:
				best_d = dd
				near = HandContact.TYPE_NAMES[x.type] + " r=%.0f" % x.radius
		print("    #%d  峰值=%6.2f px  中心=(%7.1f,%7.1f)  面积=%4d 格  最近接触=%s (%.1fpx)"
			% [i + 1, comp["peak"], centroid.x, centroid.y, comp["cells"], near, best_d])
	_check(comps.size() >= 3, "C: 至少分出 3 块独立压痕（不是一个大圆）")

	# ── 每颗接触各自有没有「自己的地盘」──
	var owner := _region_owner_counts(c, res)
	var owners_with_land := 0
	var owner_line := ""
	for i in c.size():
		var n_own: int = int(owner.get(i, 0))
		if n_own > 0:
			owners_with_land += 1
		owner_line += "#%d %s=%d格  " % [i, HandContact.TYPE_NAMES[c[i].type], n_own]
	print("  各接触「最强贡献」地盘: %s" % owner_line)
	_check(owners_with_land == c.size(), "C: 每颗接触都有各自最强的一片区域（含 3 根手指）")

	# ── 对照实验：把间距压到 34 / 半径放到 30（重叠大）会怎样 ──
	var rig2 := HandRig.new()
	rig2.auto_update = false
	rig2.finger_count = 3
	rig2.finger_spacing = 34.0
	rig2.finger_radius = 30.0
	var c2: Array = rig2.build_contacts(center, Vector2.RIGHT, 1.0, Vector2.ZERO, true)
	var res2 := _analyze_regions(c2)
	print("  对照（间距34/半径30，重叠大）: 只分出 %d 块 —— 所以出货默认取 间距40/半径25"
		% (res2["components"] as Array).size())
	rig2.free()
	rig.free()


# =====================================================================
#  D. 不同 rotation
# =====================================================================
func _test_D_rotation() -> void:
	print("\n──────────────────────────────────────────────")
	print("D) 不同 rotation")
	var rig := _make_rig(3)
	var center := Vector2(1000, 2000)
	var angles := [0.0, 90.0, 180.0, 270.0, 45.0]
	# 基准姿态：手朝右。之后每个角度都应等于「把基准姿态整体旋转该角度」
	var ref: Array = rig.build_contacts(center, Vector2.RIGHT, 1.0, Vector2.ZERO, true)
	var count_ok := true
	var radii_ok := true
	var mid_dot_min := 1.0
	var rigid_err := 0.0
	for a in angles:
		var rad: float = deg_to_rad(a)
		var dir := Vector2.RIGHT.rotated(rad)
		var c: Array = rig.build_contacts(center, dir, 1.0, Vector2.ZERO, true)
		var err := 0.0
		for i in c.size():
			var expect_pos: Vector2 = center + (ref[i].position - center).rotated(rad)
			err = maxf(err, expect_pos.distance_to(c[i].position))
		rigid_err = maxf(rigid_err, err)
		var mid_dot: float = (c[2].position - center).normalized().dot(dir)
		mid_dot_min = minf(mid_dot_min, mid_dot)
		var r_ok: bool = is_equal_approx(c[0].radius, rig.palm_radius) \
			and is_equal_approx(c[1].radius, rig.finger_radius)
		print("  angle=%6.1f°  接触=%d  中指指尖·dir=%.4f  刚性旋转误差=%.4f px  掌心/指半径=(%.0f/%.0f) 正确=%s"
			% [a, c.size(), mid_dot, err, c[0].radius, c[1].radius, "是" if r_ok else "否"])
		if c.size() != 4:
			count_ok = false
		if not r_ok:
			radii_ok = false
	_check(count_ok, "D: 各朝向下接触数恒为 4")
	_check(rigid_err < 0.01, "D: 手部几何随方向刚性旋转（各接触相对位置不变）")
	_check(mid_dot_min > 0.99, "D: 中指指尖方向与手方向一致")
	_check(radii_ok, "D: 各朝向下半径不变")

	# 真实方向状态机：给速度 → 方向应转向
	rig.hand_direction = Vector2.RIGHT
	rig.has_direction = true
	rig.update_direction(Vector2(0, 200))
	print("  给速度 (0,200) 后手方向: (%.3f, %.3f)" % [rig.hand_direction.x, rig.hand_direction.y])
	_check(rig.hand_direction.dot(Vector2(0, 1)) > 0.0, "D: 方向朝下移动时转向下方")
	rig.free()


# =====================================================================
#  E. 不同 pressure
# =====================================================================
func _test_E_pressure() -> void:
	print("\n──────────────────────────────────────────────")
	print("E) 不同 pressure")
	var rig := _make_rig(3)
	var center := Vector2(1000, 2000)
	var v := Vector2(1000, 2040)
	var prev := -1.0
	var monotone := true
	var deepest := 0.0
	for p in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var c: Array = rig.build_contacts(center, Vector2.RIGHT, p, Vector2.ZERO, true)
		var disp: float = ContactBlend.merge(v, c, DEPTH, FLAT, POWER, VOL, DRAG, CROSS, 0.0).length()
		var f: float = c[0].depth_factor()
		print("  pressure=%.2f  →  掌心 depth 倍率=%.3f   40px 处位移=%.2f px" % [p, f, disp])
		if disp < prev - 0.0001:
			monotone = false
		prev = disp
		deepest = maxf(deepest, disp)
	_check(monotone, "E: 位移随压力单调不减")
	_check(deepest > 5.0, "E: 满压时产生可见位移")
	_check(is_equal_approx(HandContact.make(HandContact.Type.PALM, Vector2.ZERO, 90.0, 0.0).depth_factor(), 0.55),
		"E: 压力为 0 时 depth 倍率为下限 0.55")
	var cw: float = rig.finger_weight
	print("  手指/掌心 depth 倍率比: %.2f（STEP 3 要求 0.70~0.85）" % cw)
	_check(cw >= 0.70 and cw <= 0.85, "E: finger_weight 落在 0.70~0.85")
	_check(rig.thumb_weight >= 0.70 and rig.thumb_weight <= 0.90, "E: thumb_weight 落在 0.70~0.90")
	rig.free()


# =====================================================================
#  F. 多触点重叠 —— 不许爆炸
# =====================================================================
func _test_F_overlap_no_explosion() -> void:
	print("\n──────────────────────────────────────────────")
	print("F) 多触点重叠（1/2/3/4 颗完全叠在同一处）")
	var center := Vector2(1000, 2000)
	var v := Vector2(1000, 2040)          # 距接触中心 40px
	var cap: float = 40.0 * CROSS
	print("  顶点距中心 40px，cross_limit 上限 = %.2f px" % cap)
	print("  数量   合并后位移   合并前逐接触原始和   是否越界")
	var merged_peak := 0.0
	var prev_merged := -1.0
	var growth := 0.0
	var raw_by_n := {}
	for n in [1, 2, 3, 4]:
		var rig := _make_rig(0)
		var c: Array = []
		c.append(HandContact.make(HandContact.Type.PALM, center, rig.palm_radius, 1.0, rig.palm_weight))
		for _i in range(n - 1):
			c.append(HandContact.make(HandContact.Type.FINGER, center, rig.finger_radius, 1.0, rig.finger_weight))
		var raw_sum := 0.0
		for x in c:
			raw_sum += ContactBlend.single_inward(v, x, DEPTH, FLAT, POWER)
		raw_by_n[n] = raw_sum
		var disp: Vector2 = ContactBlend.merge(v, c, DEPTH, FLAT, POWER, VOL, DRAG, CROSS, 0.0)
		var inward: float = disp.dot((center - v).normalized())
		var over: bool = inward > cap + 0.01
		print("  %d 颗    %8.2f px   %14.2f px      %s" % [n, disp.length(), raw_sum, "越界 ✗" if over else "受控 ✓"])
		_check(not over, "F: %d 颗重叠时朝内位移不超过 cross_limit" % n)
		if n > 1:
			growth = maxf(growth, disp.length() / maxf(prev_merged, 0.0001))
		prev_merged = disp.length()
		merged_peak = maxf(merged_peak, disp.length())
		rig.free()
	print("  原始和从 1 颗的 %.2f px 涨到 4 颗的 %.2f px（×%.2f），"
		% [raw_by_n[1], raw_by_n[4], float(raw_by_n[4]) / maxf(float(raw_by_n[1]), 0.0001)])
	print("  但合并后位移始终被 cross_limit(%.2f px) 夹住 → 最大仅 ×%.2f。" % [cap, growth])
	print("  即「Palm 40 + Finger 30 不会变成 70」。")
	_check(growth < 1.35, "F: 叠加到 4 颗后位移仍在原量级（不允许线性叠加）")
	_check(merged_peak <= MAXDISP + 0.01, "F: 合并后位移不超过 max_displacement")


# =====================================================================
#  G. Camera zoom 不影响 model-space radius
# =====================================================================
func _test_G_camera_zoom() -> void:
	print("\n──────────────────────────────────────────────")
	print("G) Camera zoom 不影响 model-space radius")
	print("   走 TouchManager.screen_to_model()（生产路径同一条算式）：")
	print("     world = canvas_transform⁻¹ * vp_pos ；  model = space_transform⁻¹ * world")
	print("   本工程出货 Camera2D.zoom = 0.3，下面用与 Camera2D 等价的画布变换逐个验证。")

	var rig := _make_rig(3)
	var vp_size := Vector2(1152, 648)
	var cam_pos := Vector2.ZERO
	var screen_pt := Vector2(400, 300)

	var radii_seen: Array = []
	var lateral_seen: Array = []
	var dist_seen: Array = []
	var models: Array = []
	var radii_ok := true
	var lateral_ok := true
	var invariant_ok := true
	for z in [0.3, 1.0, 2.5]:
		var ct := _camera_canvas_transform(z, vp_size, cam_pos)
		var model_pt: Vector2 = TouchManager.screen_to_model(screen_pt, ct, Transform2D.IDENTITY)
		var c: Array = rig.build_contacts(model_pt, Vector2.RIGHT, 1.0, Vector2.ZERO, true)
		var palm_r: float = c[0].radius
		var f_r: float = c[1].radius
		var lateral: float = absf(c[2].position.y - c[1].position.y)     # 手朝右 → 侧向即 y
		var step_dist: float = c[2].position.distance_to(c[1].position)
		models.append(model_pt)
		radii_seen.append(palm_r)
		lateral_seen.append(lateral)
		dist_seen.append(step_dist)
		print("  zoom=%.1f  模型点=(%9.1f,%9.1f)  掌心半径=%.1f  指半径=%.1f  指侧向间距=%.2f  指距=%.2f  屏幕可见掌心=%6.1f px"
			% [z, model_pt.x, model_pt.y, palm_r, f_r, lateral, step_dist, palm_r * z])
		if not (is_equal_approx(palm_r, rig.palm_radius) and is_equal_approx(f_r, rig.finger_radius)):
			radii_ok = false
		if absf(lateral - rig.finger_spacing) > 0.01:
			lateral_ok = false
		if absf(step_dist - float(dist_seen[0])) > 0.0001:
			invariant_ok = false
	_check(radii_ok, "G: 三个 zoom 下半径恒为模型空间常量（没有用屏幕像素）")
	_check(lateral_ok, "G: 三个 zoom 下指侧向间距恒为 finger_spacing（模型空间常量）")
	_check(invariant_ok, "G: 三个 zoom 下手部几何完全相同（只有屏幕可见尺寸在变）")
	print("  掌心半径取值      : %s（期望三个都是 %.0f）" % [str(radii_seen), rig.palm_radius])
	print("  指侧向间距取值    : %s（期望三个都是 %.0f）" % [str(lateral_seen), rig.finger_spacing])
	print("  屏幕可见掌心      : %.1f / %.1f / %.1f px ← zoom 只改变「看起来多大」"
		% [radii_seen[0] * 0.3, radii_seen[1] * 1.0, radii_seen[2] * 2.5])

	# zoom 确实生效：同一屏幕点在不同 zoom 下映射到的模型点，应满足 1/z 关系
	var a0: float = absf((models[0] as Vector2).x)
	var a1: float = absf((models[1] as Vector2).x)
	var ratio: float = a0 / maxf(a1, 0.0001)
	print("  zoom0.3 vs zoom1.0 的模型点 x 比值 : %.4f（期望 %.4f = 1/0.3）" % [ratio, 1.0 / 0.3])
	_check(absf(ratio - 1.0 / 0.3) < 0.02, "G: 屏幕→模型 换算确实随 zoom 变化（缩放真的生效）")

	# 第二重：模型节点自身的 transform（另一种等价的「缩放」表达）
	var ct1 := _camera_canvas_transform(1.0, vp_size, cam_pos)
	var space_scaled := Transform2D(Vector2(0.5, 0), Vector2(0, 0.5), Vector2.ZERO)
	var m2: Vector2 = TouchManager.screen_to_model(screen_pt, ct1, space_scaled)
	var c2: Array = rig.build_contacts(m2, Vector2.RIGHT, 1.0, Vector2.ZERO, true)
	print("  模型节点 scale=0.5 → 模型点=(%.1f, %.1f)（应为无缩放时的 2 倍）"
		% [m2.x, m2.y])
	_check(absf(m2.x - (models[1] as Vector2).x * 2.0) < 0.01, "G: 模型节点 transform 同样被正确处理")
	_check(is_equal_approx(c2[0].radius, rig.palm_radius), "G: 模型节点缩放不影响半径")
	rig.free()


## 与 Godot Camera2D（zoom = z, position = cam_pos, 视口中心为锚）等价的画布变换：
##   screen = (world - cam_pos) * z + 视口中心
##   ⇒ canvas_transform = Transform2D 基 = z，原点 = 视口中心 - z * cam_pos
##   ⇒ 反过来 world = (screen - 视口中心) / z + cam_pos
## 这正是 main.tscn 里 Camera2D(zoom=0.3) + TouchManager.space_node=GDCubismUserModel 的路径。
func _camera_canvas_transform(zoom: float, vp_size: Vector2, cam_pos: Vector2) -> Transform2D:
	var z: float = maxf(zoom, 0.0001)
	var center: Vector2 = vp_size * 0.5
	return Transform2D(Vector2(z, 0), Vector2(0, z), center - cam_pos * z)


# =====================================================================
#  H. 静止时 direction 不抖动
# =====================================================================
func _test_H_still_no_jitter() -> void:
	print("\n──────────────────────────────────────────────")
	print("H) 静止时 direction 不抖动")
	var rig := _make_rig(3)
	rig.update_direction(Vector2(0, 120))
	var settled: Vector2 = rig.hand_direction
	var updates_before: int = rig.direction_updates
	var max_jitter := 0.0
	for _i in 120:
		rig.update_direction(Vector2.ZERO)          # 完全静止
		max_jitter = maxf(max_jitter, rig.hand_direction.distance_to(settled))
	for _i in 120:
		rig.update_direction(Vector2(6, 6))         # 速度低于死区 14
		max_jitter = maxf(max_jitter, rig.hand_direction.distance_to(settled))
	print("  确立方向          : (%.4f, %.4f)" % [settled.x, settled.y])
	print("  240 帧后偏差      : %.6f 像素（必须为 0）" % max_jitter)
	print("  direction_updates : %d -> %d（静止期间不应增加）" % [updates_before, rig.direction_updates])
	_check(max_jitter < 0.000001, "H: 静止/低速时手方向零抖动")
	_check(rig.direction_updates == updates_before, "H: 死区内不更新方向")
	_check(absf(rig.current_direction().length() - 1.0) < 0.0001, "H: 方向始终是单位向量")

	rig.update_direction(Vector2(-120, 0))
	print("  给速度 (-120,0) 后: (%.4f, %.4f)" % [rig.hand_direction.x, rig.hand_direction.y])
	_check(rig.hand_direction.dot(Vector2(-1, 0)) > 0.0, "H: 有效速度下手方向转向")
	rig.free()


# =====================================================================
#  I. velocity=0 不出 NaN（含极端速度）
# =====================================================================
func _test_I_zero_velocity_nan() -> void:
	print("\n──────────────────────────────────────────────")
	print("I) velocity=0 / 极端速度 不出 NaN")
	var rig := _make_rig(3)
	var center := Vector2(1000, 2000)
	var bad := 0
	var worst := 0.0
	var cases := [
		{"name": "静止", "v": Vector2.ZERO},
		{"name": "极快", "v": Vector2(100000, -80000)},
		{"name": "极小", "v": Vector2(0.000001, 0.0)},
		{"name": "竖直", "v": Vector2(0, 5000)},
	]
	for cs in cases:
		var c: Array = rig.build_contacts(center, Vector2.RIGHT, 1.0, cs["v"], true)
		var case_bad := 0
		for k in 72:
			var a: float = TAU * float(k) / 72.0
			for r in [0.0, 1.0, 20.0, 60.0, 92.0, 200.0]:
				var v: Vector2 = center + Vector2.RIGHT.rotated(a) * r
				var disp: Vector2 = ContactBlend.merge(v, c, DEPTH, FLAT, POWER, VOL, DRAG, CROSS, 0.0)
				if not (is_finite(disp.x) and is_finite(disp.y)):
					case_bad += 1
					bad += 1
				worst = maxf(worst, disp.length())
		print("  %-4s velocity=%-22s NaN 数=%d" % [cs["name"], str(cs["v"]), case_bad])
	_check(bad == 0, "I: 各种速度下都不产生 NaN")
	print("  全程最大位移      : %.2f px" % worst)
	_check(worst <= MAXDISP + 0.01, "I: 极端速度下仍受 max_displacement 约束")

	# 退化输入：位置本身就是 NaN
	var zero_base: Vector2 = ContactBlend.merge(Vector2(NAN, NAN), c0_dummy(),
		DEPTH, FLAT, POWER, VOL, DRAG, CROSS, 0.0)
	_check(is_finite(zero_base.x) and is_finite(zero_base.y), "I: 输入 NaN 位置时输出仍为有限值")
	rig.free()


func c0_dummy() -> Array:
	var rig := _make_rig(3)
	var c: Array = rig.build_contacts(Vector2.ZERO, Vector2.RIGHT, 1.0, Vector2.ZERO, true)
	rig.free()
	return c


# =====================================================================
#  J. 全部 inactive → deformation 回到 0
# =====================================================================
func _test_J_all_inactive_zero() -> void:
	print("\n──────────────────────────────────────────────")
	print("J) 所有 contact inactive → deformation 严格为 0")
	var rig := _make_rig(3)
	var center := Vector2(1000, 2000)
	var c: Array = rig.build_contacts(center, Vector2.RIGHT, 1.0, Vector2.ZERO, false)
	var on_count := 0
	for x in c:
		if x.is_on():
			on_count += 1
	var max_len := 0.0
	for k in 36:
		var a: float = TAU * float(k) / 36.0
		for r in [0.0, 10.0, 40.0, 90.0]:
			var v: Vector2 = center + Vector2.RIGHT.rotated(a) * r
			max_len = maxf(max_len, ContactBlend.merge(v, c, DEPTH, FLAT, POWER, VOL, DRAG, CROSS, 0.0).length())
	print("  接触数 / 其中 is_on(): %d / %d（期望 4 / 0）" % [c.size(), on_count])
	print("  全 inactive 最大位移: %.6f px（必须为 0）" % max_len)
	_check(c.size() == 4, "J: inactive 时结构仍在（4 颗）")
	_check(on_count == 0, "J: inactive 时没有 is_on 的接触")
	_check(max_len == 0.0, "J: inactive 时位移严格为 0（对应 deformer 走 recovery 路径）")

	var empty_disp: Vector2 = ContactBlend.merge(center, [], DEPTH, FLAT, POWER, VOL, DRAG, CROSS, 0.0)
	_check(empty_disp == Vector2.ZERO, "J: 空接触数组返回零位移")
	var zero_r = HandContact.make(HandContact.Type.PALM, center, 0.0, 1.0, 1.0)
	var zr: Vector2 = ContactBlend.merge(center + Vector2(5, 0), [zero_r], DEPTH, FLAT, POWER, VOL, DRAG, CROSS, 0.0)
	_check(zr == Vector2.ZERO, "J: 半径 0 的接触不产生位移")
	rig.free()


# =====================================================================
#  工具
# =====================================================================
const REGION_THRESH := 4.0        # 判定「有压痕」的位移阈值（px）
const MIN_REGION_CELLS := 12      # 一个连通域至少这么多采样格才算一块压痕
const SAMPLE_STEP := 6.0

func _make_rig(fingers: int) -> HandRig:
	var rig := HandRig.new()
	rig.finger_count = fingers
	rig.auto_update = false
	return rig


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("      ✓ %s" % msg)
	else:
		print("      ✗ %s" % msg)
		fails.append(msg)
		ok = false


func _as_float(v) -> float:
	return float(v)


## 逐点采样 |displacement| 场，并做连通域分析
func _analyze_regions(contacts: Array) -> Dictionary:
	# 采样范围：以掌心为心，覆盖所有接触圆
	var center: Vector2 = contacts[0].position
	var reach := 0.0
	for c in contacts:
		if not c.is_on():
			continue
		reach = maxf(reach, c.position.distance_to(center) + c.radius)
	reach += 12.0
	var mn: Vector2 = center - Vector2(reach, reach)
	var cols: int = int((reach * 2.0) / SAMPLE_STEP) + 1
	var rows: int = cols
	var grid := {}
	var peak := 0.0
	for iy in rows:
		for ix in cols:
			var p := Vector2(mn.x + float(ix) * SAMPLE_STEP, mn.y + float(iy) * SAMPLE_STEP)
			var d: float = ContactBlend.merge(p, contacts, DEPTH, FLAT, POWER, VOL, DRAG, CROSS, 0.0).length()
			if d >= REGION_THRESH:
				grid[Vector2i(ix, iy)] = d
			peak = maxf(peak, d)

	# 4-连通域
	var comps: Array = []
	var seen := {}
	for key in grid:
		if seen.has(key):
			continue
		var stack: Array = [key]
		seen[key] = true
		var cells := 0
		var cpeak := 0.0
		var sum := Vector2.ZERO
		while not stack.is_empty():
			var k: Vector2i = stack.pop_back()
			var val: float = grid[k]
			cells += 1
			cpeak = maxf(cpeak, val)
			sum += Vector2(mn.x + float(k.x) * SAMPLE_STEP, mn.y + float(k.y) * SAMPLE_STEP)
			for n in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var k2: Vector2i = k + n
				if grid.has(k2) and not seen.has(k2):
					seen[k2] = true
					stack.append(k2)
		if cells >= MIN_REGION_CELLS:
			comps.append({"cells": cells, "peak": cpeak, "centroid": sum / float(cells)})
	comps.sort_custom(func(x, y): return x["cells"] > y["cells"])
	return {"components": comps, "peak": peak, "step": SAMPLE_STEP,
		"count": grid.size(), "origin": mn, "cols": cols}


## 每颗接触「贡献最强」的采样格数量 → 说明它有没有自己的地盘。
## 返回 {接触序号: 格数}
func _region_owner_counts(contacts: Array, res: Dictionary) -> Dictionary:
	var mn: Vector2 = res["origin"]
	var cols: int = int(res["cols"])
	var counts := {}
	for iy in cols:
		for ix in cols:
			var p := Vector2(mn.x + float(ix) * SAMPLE_STEP, mn.y + float(iy) * SAMPLE_STEP)
			var best := 0.0
			var best_i := -1
			for i in contacts.size():
				var s: float = ContactBlend.single_inward(p, contacts[i], DEPTH, FLAT, POWER)
				if s > best:
					best = s
					best_i = i
			if best_i >= 0 and best >= REGION_THRESH:
				counts[best_i] = int(counts.get(best_i, 0)) + 1
	return counts


func _report() -> void:
	print("\n======================================================================")
	if fails.is_empty():
		print("[手部测试] 结果：全部通过（A~J）")
	else:
		print("[手部测试] 结果：未通过 —— %d 项失败" % fails.size())
		for f in fails:
			print("       ✗ ", f)
	print("======================================================================")
