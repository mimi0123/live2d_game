## STEP 3 真机多触点探针（headless · 报告落文件版）
##
## 运行（默认 3 根手指）：
##   J:\live2d_game\engine\Godot.exe --headless --path . res://tools/hand_probe.tscn --quit-after 900
## 指定手指数：
##   ... res://tools/hand_probe.tscn --quit-after 900 -- --fingers=0
##
## 与 soft_live2d_probe.gd 的关系：
##   那个探针验的是「单触点」（STEP 2），本文件验的是「虚拟手」（STEP 3）。
##   两者都只搭一个最小 Live2D 场景（不加载 main.tscn，避免 headless 崩溃），
##   并把结论写进文件，崩了也不丢数据。原探针保持不动。
##
## 量什么（对应 STEP 3 成功标准的 4/5/6/7/10 项）：
##   · 单顶点最大真实位移（相对原始静止位置 —— 这是肉眼看到的凹陷量）
##   · cross_limit 实测：max(|位移| / 到最近触点的距离)，必须 <= cross_limit
##   · 圈外峰值：离所有触点都 > 2×半径 的顶点残余位移
##   · 三角形翻转数（0 才说明网格没被拉烂）
##   · NaN 数
##   · 多区域证据：每颗接触各自的「压痕覆盖顶点数」→ 证明不是一个大圆
##   · 原动画是否仍在跑（触点注入前，顶点位置是否随时间变化）

extends Node

const MODEL_PATH := "res://models/MO/MO.model3.json"
const WAIT_A := 45            # 静态等待帧数
const PRESS_FRAMES := 90      # 按压帧数
const FLIP_AREA_EPS := 0.01

var _lines: Array[String] = []
var _model = null
var _deformer = null
var _touch = null
var _rig = null

var _frames := 0
var _phase := 0
var _press_frames := 0
var _sim_time := 0.0
var _press_start := 0.0

var _fingers := 3
var _legacy := false          ## true = 关掉 HandRig，走 STEP 2 的单触点回退路径（回归对照）
var _shadow := false          ## STEP 4：true = 同时挂 ShadowField，验证阴影画笔
var _field = null             ## ShadowField（--shadow=1 时创建）
## 半径实验开关（只影响探针，不动出货默认值）
var _palm_r_override := 0.0
var _finger_r_override := 0.0
var _report_path := "res://_hand_probe_report.txt"

var _touch_pt := Vector2.ZERO
var _pristine: Dictionary = {}
var _anim_probe_early: Vector2 = Vector2.INF
var _anim_probe_late: Vector2 = Vector2.INF
var _anim_sample_key := ""


func _ready() -> void:
	_parse_args()
	print("[手部探针] 搭建最小 Live2D 场景（不加载 main.tscn）")

	_model = GDCubismUserModel.new()
	_model.name = "GDCubismUserModel"
	_model.set("assets", MODEL_PATH)
	add_child(_model)

	_deformer = SoftMeshDeformer.new()
	_deformer.name = "SoftMeshDeformer"
	_deformer.set("enabled", true)
	_model.add_child(_deformer)

	_touch = TouchManager.new()
	_touch.name = "SoftTouch"
	_touch.set("follow_mouse", false)
	_touch.set("space_node", _model)
	_touch.set("hit_tester", _deformer)
	add_child(_touch)

	_rig = HandRig.new()
	_rig.name = "HandRig"
	_rig.set("finger_count", _fingers)
	_rig.set("touch", _touch)
	if _palm_r_override > 0.0:
		_rig.set("palm_radius", _palm_r_override)
	if _finger_r_override > 0.0:
		_rig.set("finger_radius", _finger_r_override)
	add_child(_rig)

	_deformer.set("touch", _touch)
	_deformer.set("hand_rig", _rig)
	_deformer.set("use_hand_rig", not _legacy)

	if _shadow:
		_field = ShadowField.new()
		_field.name = "ShadowField"
		# ⚠ 模型空间硬要求：ShadowField 必须是模型节点的子节点，
		#    这样笔刷的 position/scale 就是模型空间（画布像素），随模型一起被 Camera2D 缩放
		_field.set("palm_texture", load("res://assets/touch_shadows/common/palm_soft.png"))
		var fts: Array[Texture2D] = []
		for i in range(1, 6):
			fts.append(load("res://assets/touch_shadows/common/fingertip_0%d.png" % i))
		_field.set("finger_textures", fts)
		_model.add_child(_field)
		_field.set("hand_rig", _rig)
		_field.set("touch", _touch)
	print("[手部探针] 模型 + SoftMeshDeformer + TouchManager + HandRig(%d 指) 已入树%s"
		% [_fingers, "  ［legacy 模式：关闭 HandRig，走单触点回退路径］" if _legacy else ""])
	if _shadow:
		print("[手部探针] ShadowField 已挂到模型节点下（模型空间），纹理 %s"
			% ["OK" if _field.get("palm_texture") != null else "加载失败"])


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fingers="):
			_fingers = int(a.split("=")[1])
		elif a.begins_with("--legacy="):
			_legacy = int(a.split("=")[1]) == 1
		elif a.begins_with("--palm="):
			_palm_r_override = float(a.split("=")[1])
		elif a.begins_with("--frad="):
			_finger_r_override = float(a.split("=")[1])
		elif a.begins_with("--shadow="):
			_shadow = int(a.split("=")[1]) == 1
		elif a.begins_with("--report="):
			_report_path = a.split("=")[1]
	if _report_path == "res://_hand_probe_report.txt":
		if _shadow:
			_report_path = "res://_shadow_probe_report.txt"
		elif _legacy:
			_report_path = "res://_hand_probe_report_legacy.txt"
		elif _palm_r_override > 0.0:
			_report_path = "res://_hand_probe_report_palm%d.txt" % int(_palm_r_override)
		else:
			_report_path = "res://_hand_probe_report_%df.txt" % _fingers


func _process(delta: float) -> void:
	_frames += 1
	_sim_time += delta
	match _phase:
		0:
			# 原动画是否在跑：第 10 帧与第 40 帧各采一次，比较顶点是否移动
			if _frames == 10:
				_anim_probe_early = _anim_sample()
			elif _frames == 40:
				_anim_probe_late = _anim_sample()
			if _frames >= WAIT_A:
				_begin_press()
				_press_start = _sim_time
				_phase = 1
		1:
			_press_frames += 1
			if _frames >= WAIT_A + PRESS_FRAMES:
				_report()
				_phase = 2
				_flush()
				print("[手部探针] 报告已写入 %s" % _report_path)
				if is_inside_tree():
					get_tree().quit()


## 取一个稳定网格的顶点位置当「动画时间戳」
func _anim_sample() -> Vector2:
	var meshes: Dictionary = _model.get_meshes()
	for k in meshes:
		var mi = meshes[k]
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		if not mi.visible:
			continue
		var a: Array = mi.mesh.surface_get_arrays(0)
		if a.is_empty() or a[Mesh.ARRAY_VERTEX] == null:
			continue
		var v: PackedVector2Array = a[Mesh.ARRAY_VERTEX]
		if v.size() > 0:
			_anim_sample_key = k
			return v[0]
	return Vector2.INF


func _begin_press() -> void:
	# 触点：把模型包围盒切 200px 格，取顶点最密的格子中心（保证有足够顶点可测）
	var meshes: Dictionary = _model.get_meshes()
	var usable: Array = []
	var all_mn := Vector2(INF, INF)
	var all_mx := Vector2(-INF, -INF)
	for key in meshes:
		var mi = meshes[key]
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		if not mi.visible:
			continue
		var arr: Array = mi.mesh.surface_get_arrays(0)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector2Array = arr[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var mn: Vector2 = verts[0]
		var mx: Vector2 = verts[0]
		for v in verts:
			mn.x = minf(mn.x, v.x)
			mn.y = minf(mn.y, v.y)
			mx.x = maxf(mx.x, v.x)
			mx.y = maxf(mx.y, v.y)
		if (mx - mn).length_squared() < 0.0001:
			continue
		usable.append(verts)
		all_mn.x = minf(all_mn.x, mn.x)
		all_mn.y = minf(all_mn.y, mn.y)
		all_mx.x = maxf(all_mx.x, mx.x)
		all_mx.y = maxf(all_mx.y, mx.y)

	if usable.is_empty():
		_say("[手部探针] 找不到可用网格")
		return

	const CELL := 200.0
	var span: Vector2 = all_mx - all_mn
	var cols: int = maxi(1, int(span.x / CELL) + 1)
	var rows: int = maxi(1, int(span.y / CELL) + 1)
	var count := {}
	var accum := {}
	for verts in usable:
		for v in verts:
			var cx: int = clampi(int((v.x - all_mn.x) / CELL), 0, cols - 1)
			var cy: int = clampi(int((v.y - all_mn.y) / CELL), 0, rows - 1)
			var kk: int = cy * cols + cx
			count[kk] = int(count.get(kk, 0)) + 1
			accum[kk] = Vector2(accum.get(kk, Vector2.ZERO)) + v
	var best_k := -1
	var best_n := -1
	for kk in count:
		if int(count[kk]) > best_n:
			best_n = int(count[kk])
			best_k = int(kk)
	if best_k < 0:
		_say("[手部探针] 网格统计失败")
		return
	_touch_pt = (accum[best_k] as Vector2) / maxf(float(best_n), 1.0)

	_say("")
	_say("==================== STEP 3 虚拟手 · 真机实测 ====================")
	if _legacy:
		_say("  模式              : legacy 单触点回退（= STEP 2 路径，用于回归对照）")
	else:
		_say("  模式              : HandRig 虚拟手")
		_say("  手指数            : %d（手指 + 1 掌心 = %d 颗接触）" % [_fingers, _fingers + 1])
	_say("  触点(画布px)      : (%.1f, %.1f)   [该处 %d 个顶点/200px 格]" % [_touch_pt.x, _touch_pt.y, best_n])
	_say("  命中检查          : %s" % str(_deformer.is_point_on_model(_touch_pt)))
	if not _legacy:
		_say("  掌心半径/指半径   : %.0f / %.0f   指间距 %.0f   指距掌心 %.0f"
			% [float(_rig.get("palm_radius")), float(_rig.get("finger_radius")),
				float(_rig.get("finger_spacing")), float(_rig.get("finger_distance"))])
	else:
		_say("  有效半径(单触点)  : %.1f（deformer.radius 与 touch.radius 取大）" % float(_deformer.get("radius")))

	# ── 原动画是否仍在跑 ──
	_say("  ── 原 Live2D 动画 ──")
	if _anim_probe_early == Vector2.INF or _anim_probe_late == Vector2.INF:
		_say("  取样失败（未取到网格顶点）")
	else:
		var moved: float = _anim_probe_early.distance_to(_anim_probe_late)
		_say("  网格[%s] 首顶点在第10帧→第40帧位移: %.4f px" % [_anim_sample_key, moved])
		_say("  动画状态          : %s" % ("仍在播放 ✓" if moved > 0.001 else "疑似静止（该网格可能本来就不动）"))

	_snapshot_pristine()
	_touch.force_state(_touch_pt, true, 1.0, 90.0)
	_say("  已注入虚拟手（force_state 满压），按压 %d 帧 ..." % PRESS_FRAMES)


func _snapshot_pristine() -> void:
	_pristine.clear()
	var meshes: Dictionary = _model.get_meshes()
	for k in meshes:
		var mi = meshes[k]
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		if not mi.visible:
			continue
		var a: Array = mi.mesh.surface_get_arrays(0)
		if a.is_empty() or a[Mesh.ARRAY_VERTEX] == null:
			continue
		var v: PackedVector2Array = a[Mesh.ARRAY_VERTEX]
		if v.size() > 0:
			_pristine[k] = v.duplicate()
	_say("  已抓取原始静止快照：%d 个网格" % _pristine.size())


func _report() -> void:
	var contacts: Array = _deformer.get("_last_contacts")
	_say("")
	_say("  ── 运行时接触状态 ──")
	_say("  实际接触数        : %d" % contacts.size())
	for c in contacts:
		if c != null:
			_say("    %s" % c.describe())
	if not _legacy:
		var bc: Array = _rig.bounding_circle()
		_say("  手包围圆          : 中心(%.1f,%.1f) 半径 %.1f" % [bc[0].x, bc[0].y, bc[1]])
		_say("  手方向            : (%.3f, %.3f)  方向更新次数 %d"
			% [_rig.hand_direction.x, _rig.hand_direction.y, int(_rig.get("direction_updates"))])
	_say("  本帧合并位移峰值  : %.2f px" % float(_deformer.get("_last_target_peak")))

	# ── 真实位移 & 完整性 ──
	var meshes: Dictionary = _model.get_meshes()
	var mx := 0.0
	var over5 := 0
	var over1 := 0
	var far_mx := 0.0
	var worst_cross := 0.0
	var worst_inward := 0.0
	var nan_count := 0
	var top: Array = []
	var cover := {}            # 接触序号 -> >5px 顶点数
	for c_i in contacts.size():
		cover[c_i] = 0

	for k in _pristine:
		var mi = meshes.get(k)
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		var a: Array = mi.mesh.surface_get_arrays(0)
		if a.is_empty() or a[Mesh.ARRAY_VERTEX] == null:
			continue
		var now_v: PackedVector2Array = a[Mesh.ARRAY_VERTEX]
		var old_v: PackedVector2Array = _pristine[k]
		var n: int = mini(now_v.size(), old_v.size())
		for i in n:
			var off_vec: Vector2 = now_v[i] - old_v[i]
			var dv: float = off_vec.length()
			if is_nan(now_v[i].x) or is_nan(now_v[i].y):
				nan_count += 1
				continue
			mx = maxf(mx, dv)
			if dv > 5.0:
				over5 += 1
			if dv > 1.0:
				over1 += 1
			# 到最近接触的距离 / 最近接触序号
			var dmin := INF
			var ci_best := -1
			for c_i in contacts.size():
				var c = contacts[c_i]
				if c == null:
					continue
				var d: float = old_v[i].distance_to(c.position)
				if d < dmin:
					dmin = d
					ci_best = c_i
			if dmin < INF:
				# ① cross_limit 的硬保证：对**每一颗**接触，朝内位移 ≤ dist*cross_limit
				for c in contacts:
					if c == null:
						continue
					var d2: float = old_v[i].distance_to(c.position)
					if d2 > 1.0:
						var nrm: Vector2 = (old_v[i] - c.position) / d2
						var inward: float = -off_vec.dot(nrm)
						if inward > 0.0:
							worst_inward = maxf(worst_inward, inward / d2)
				# ② 参考量：位移 / 到最近触点距离（半径差异大时它可以 >1）
				worst_cross = maxf(worst_cross, dv / maxf(dmin, 0.0001))
				# 圈外：离所有触点都超过 2 倍半径
				var outside: bool = true
				for c in contacts:
					if c != null and old_v[i].distance_to(c.position) <= c.radius * 2.0:
						outside = false
						break
				if outside:
					far_mx = maxf(far_mx, dv)
			if dv > 5.0 and ci_best >= 0:
				cover[ci_best] = int(cover.get(ci_best, 0)) + 1
			if dv > 1.0:
				top.append([dv, dmin, k])

	top.sort_custom(func(x, y): return x[0] > y[0])
	_say("")
	_say("  ── 对『原始静止位置』的真实形变 ──")
	_say("  全局最大真实位移        : %.2f px" % mx)
	_say("  >5px 顶点数 / >1px 顶点数: %d / %d" % [over5, over1])
	_say("  最大『朝内位移/该接触距离』: %.3f   ← cross_limit 的硬保证，必须 <= %.2f"
		% [worst_inward, float(_deformer.get("cross_limit"))])
	_say("  最大『位移/到最近触点距离』: %.3f   ← 仅参考：半径差异大时可能 >1"
		% worst_cross)
	_say("  圈外(离所有触点>2R)最大位移: %.4f px" % far_mx)
	_say("  NaN 数                  : %d" % nan_count)
	for q in mini(8, top.size()):
		_say("   #%-2d 真实位移=%7.2f px  离最近触点=%7.2f px  网格=%s" % [q + 1, top[q][0], top[q][1], str(top[q][2])])
	_say("  ── 多区域证据（每颗接触各自的压痕覆盖）──")
	var active_regions := 0
	for c_i in contacts.size():
		var n_cover: int = int(cover.get(c_i, 0))
		if n_cover > 0:
			active_regions += 1
		_say("   <%s> >5px 顶点数: %d" % [contacts[c_i].describe().substr(0, 24), n_cover])
	_say("  形成独立压痕的接触数    : %d / %d" % [active_regions, contacts.size()])

	# ── 三角形翻转 ──
	var flipped := 0
	var tri_total := 0
	var flip_details: Array = []
	for k in _pristine:
		var mii = meshes.get(k)
		if not is_instance_valid(mii) or mii.mesh == null or not (mii.mesh is ArrayMesh):
			continue
		var ai: Array = mii.mesh.surface_get_arrays(0)
		if ai.is_empty() or ai[Mesh.ARRAY_VERTEX] == null or ai[Mesh.ARRAY_INDEX] == null:
			continue
		var nv: PackedVector2Array = ai[Mesh.ARRAY_VERTEX]
		var pv: PackedVector2Array = _pristine[k]
		var idn: PackedInt32Array = ai[Mesh.ARRAY_INDEX]
		var tc: int = idn.size() / 3
		for t3 in tc:
			var ia: int = idn[t3 * 3]
			var ib: int = idn[t3 * 3 + 1]
			var ic: int = idn[t3 * 3 + 2]
			if ia >= nv.size() or ib >= nv.size() or ic >= nv.size():
				continue
			if ia >= pv.size() or ib >= pv.size() or ic >= pv.size():
				continue
			var an: float = _tri_area(nv[ia], nv[ib], nv[ic])
			var ap: float = _tri_area(pv[ia], pv[ib], pv[ic])
			if absf(ap) < FLIP_AREA_EPS:
				continue
			tri_total += 1
			if an * ap < 0.0:
				flipped += 1
				# 记录翻转三角形的严重度：原始面积、当前面积、质心离最近触点距离、最大顶点位移
				var cen: Vector2 = (pv[ia] + pv[ib] + pv[ic]) / 3.0
				var dmin := INF
				for c in contacts:
					if c != null:
						dmin = minf(dmin, cen.distance_to(c.position))
				var mv := 0.0
				for idx in [ia, ib, ic]:
					mv = maxf(mv, nv[idx].distance_to(pv[idx]))
				var e1: float = pv[ia].distance_to(pv[ib])
				var e2: float = pv[ib].distance_to(pv[ic])
				var e3: float = pv[ic].distance_to(pv[ia])
				flip_details.append({
					"key": k, "orig_area": absf(ap) * 0.5, "now_area": absf(an) * 0.5,
					"dist": dmin, "move": mv,
					"e1": e1, "e2": e2, "e3": e3,
				})
	_say("")
	_say("  ── 网格完整性 ──")
	_say("  三角形翻转数 / 总数    : %d / %d   ← 0 才说明网格没被拉烂" % [flipped, tri_total])
	if not flip_details.is_empty():
		flip_details.sort_custom(func(x, y): return x["orig_area"] > y["orig_area"])
		_say("  翻转明细（按原始面积从大到小，最多 6 条）:")
		for i in mini(6, flip_details.size()):
			var fd: Dictionary = flip_details[i]
			var emax: float = maxf(fd["e1"], maxf(fd["e2"], fd["e3"]))
			var emin: float = minf(fd["e1"], minf(fd["e2"], fd["e3"]))
			_say("    #%d 网格=%s  原始面积=%.3f px²  当前面积=%.3f px²  质心离最近触点=%.1f px  最大顶点位移=%.2f px"
				% [i + 1, str(fd["key"]), fd["orig_area"], fd["now_area"], fd["dist"], fd["move"]])
			_say("        原始三边长=%.1f / %.1f / %.1f px（最长/最短=%.1f → %s）"
				% [fd["e1"], fd["e2"], fd["e3"], emax / maxf(emin, 0.0001),
					"窄条三角形（近退化）" if emax / maxf(emin, 0.0001) > 3.0 else "正常三角形"])
	_say("  offset 状态重置次数    : %d" % int(_deformer.get("_state_resets")))
	_say("  offset 状态丢失次数    : %d" % int(_deformer.get("_state_lost")))
	_say("  诊断 meshes/aabbs/ready/ensure/target_peak: %d / %d / %s / %d / %.2f" % [
		int((_deformer.get("_meshes") as Dictionary).size()),
		int((_deformer.get("_aabbs") as Dictionary).size()),
		str(_deformer.get("_geometry_ready")),
		int(_deformer.get("_ensure_calls")),
		float(_deformer.get("_last_target_peak")),
	])
	_say("  按压帧数 / 真实时长    : %d 帧 / %.3f s" % [_press_frames, _sim_time - _press_start])

	# ── STEP 4：阴影画笔验证 ──
	if _shadow and _field != null:
		_say("")
		_say("  ── STEP 4 ShadowField 验证 ──")
		_say("  %s" % _field.describe())
		var brushes: Array = _field.get("_pool")
		for b in brushes:
			if b != null and is_instance_valid(b):
				_say("    %s" % b.describe())
		# 模型空间位置复核：笔刷位置必须与对应接触一致（同一坐标系）
		var contacts_rt: Array = _deformer.get("_last_contacts")
		var pos_err := 0.0
		for i in mini(mini(brushes.size(), contacts_rt.size()), 99):
			if brushes[i].visible and contacts_rt[i] != null:
				pos_err = maxf(pos_err, (brushes[i] as Node2D).position.distance_to(contacts_rt[i].position))
		_say("  笔刷位置 vs 接触位置最大偏差 : %.4f px（应为 0，同坐标系）" % pos_err)
		# 在模型范围内：用 pristine 包围盒
		var mn := Vector2(INF, INF)
		var mx2 := Vector2(-INF, -INF)
		for k in _pristine:
			for v in _pristine[k]:
				mn.x = minf(mn.x, v.x)
				mn.y = minf(mn.y, v.y)
				mx2.x = maxf(mx2.x, v.x)
				mx2.y = maxf(mx2.y, v.y)
		var inside := 0
		var outside := 0
		for b in brushes:
			if b != null and (b as Node2D).visible:
				var p: Vector2 = (b as Node2D).position
				if p.x >= mn.x - 1.0 and p.x <= mx2.x + 1.0 and p.y >= mn.y - 1.0 and p.y <= mx2.y + 1.0:
					inside += 1
				else:
					outside += 1
		_say("  笔刷在模型包围盒内/外        : %d / %d" % [inside, outside])
		# 顶点零改动证明：ShadowField/ShadowBrush 全部是 Sprite2D，
		# 模型网格数与按压前一致、且顶点统计不含阴影节点
		_say("  笔刷节点类型                 : %s（Sprite2D，无 mesh 访问）"
			% (str(brushes[0].get_class()) if brushes.size() > 0 else "-"))
		# z 序记录
		var kids: Array = _model.get_children()
		var order := ""
		for k2 in kids:
			order += "%s(z=%d) " % [k2.name, k2.z_index if k2 is CanvasItem else 0]
		_say("  模型子节点顺序               : %s" % order)
		_say("  NaN 拦截数                   : %d" % int(_field.get("nan_rejects")))

	_say("")
	_say("  ── 判定 ──")
	_say("  1) 朝内位移受 cross_limit 控制 : %s" % ("通过 ✓" if worst_inward <= float(_deformer.get("cross_limit")) + 0.02 else "未通过 ✗"))
	_say("  2) 圈外接近 0               : %s" % ("通过 ✓" if far_mx < 1.0 else "未通过 ✗"))
	_say("  3) 无三角形翻转             : %s" % ("通过 ✓" if flipped == 0 else "未通过 ✗"))
	_say("  4) 无 NaN                   : %s" % ("通过 ✓" if nan_count == 0 else "未通过 ✗"))
	_say("  5) 多区域（>=2 个独立压痕） : %s" % ("通过 ✓" if active_regions >= 2 or contacts.size() < 2 else "未通过 ✗"))


func _tri_area(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)


func _say(s: String) -> void:
	_lines.append(s)
	print(s)


func _flush() -> void:
	var f := FileAccess.open(_report_path, FileAccess.WRITE)
	if f == null:
		print("[手部探针] 报告写入失败: %s" % _report_path)
		return
	for l in _lines:
		f.store_line(l)
	f.close()
