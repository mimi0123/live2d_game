## SoftTouch 真机探针（headless · 报告落文件版）
##
## 运行：
##   J:\live2d_game\engine\Godot.exe --headless --path . res://tools\soft_probe.tscn --quit-after 400
##
## 为什么不用 --script 里 load main.tscn：
##   main.tscn 带 GUI / 托盘 / 自动启动等节点，headless 下会成片刷
##   "Object was deleted while awaiting a callback." 并在退出时 SIGSEGV，
##   导致 stdout 丢失。所以这里**只搭一个最小 Live2D 场景**，
##   并把结论写进 res://_probe_report.txt（崩了也不丢数据）。
##
## 两阶段：
##   A（第 1~45 帧）静态体检：ArtMesh 数量 / 材质归属 / 写回可行性 / 命中 / 坐标空间
##   B（第 46~160 帧）端到端形变：喂一个真实触点，看 ArtMesh 顶点是否被推动，
##                     以及「位移是否随距离衰减」（圆形 vs 矩形）的硬指标

extends Node

const MODEL_PATH := "res://models/MO/MO.model3.json"
const REPORT_PATH := "res://_probe_report.txt"
const WAIT_A := 45          # 阶段 A 等待帧数
const PRESS_FRAMES := 90    # 阶段 B 按压帧数

var _lines: Array[String] = []
var _model = null
var _deformer = null
var _touch = null
var _frames := 0
var _phase := 0
var _touch_pt := Vector2.ZERO
var _effective_radius := 0.0
var _sim_time := 0.0      # 累计 delta（headless 不锁帧，必须用真实时间解释收敛程度）
var _press_frames := 0
var _last_delta := 0.0
var _press_start_time := 0.0
var _trace: Array = []
var _probe_key := ""
var _track_state: Array = []
var _track_count: Array = []
var _track_size: Array = []
var _track_distinct := 0
var _drops := 0
## 诊断：cubism_epilogue 实际收到的 delta 累计（验证「弹簧没跑够时间」假设）
var _epi_delta_total := 0.0
var _epi_count := 0
var _epi_delta_last := 0.0
## 按压前抓取的原始静止顶点（用于测「相对静止位置的真实形变」）
var _pristine: Dictionary = {}
var _pristine_center: Vector2 = Vector2.ZERO


func _ready() -> void:
	print("[探针] 搭建最小 Live2D 场景（不加载 main.tscn）")
	_model = GDCubismUserModel.new()
	_model.name = "GDCubismUserModel"
	_model.set("assets", MODEL_PATH)
	add_child(_model)

	_deformer = SoftMeshDeformer.new()
	_deformer.name = "SoftMeshDeformer"
	_deformer.set("enabled", true)
	_model.add_child(_deformer)

	# 诊断：统计插件实际喂给形变器的 delta 总量
	_deformer.cubism_epilogue.connect(_on_epi_delta)

	_touch = TouchManager.new()
	_touch.name = "SoftTouch"
	_touch.set("follow_mouse", false)
	_touch.set("space_node", _model)
	_touch.set("hit_tester", _deformer)
	add_child(_touch)
	_deformer.set("touch", _touch)
	print("[探针] 模型 + SoftMeshDeformer + TouchManager 已入树")


func _on_epi_delta(_m, delta: float) -> void:
	_epi_delta_total += delta
	_epi_count += 1
	_epi_delta_last = delta


func _process(_delta: float) -> void:
	_frames += 1
	_sim_time += _delta
	_last_delta = _delta
	match _phase:
		0:
			if _frames >= WAIT_A:
				_run_static()
				_begin_press()
				_press_start_time = _sim_time
				_phase = 1
		1:
			_press_frames += 1
			_tick_tracked()
			if _press_frames % 5 == 0:
				_trace.append([_press_frames, _peak_now(), _deformer.get("_offsets").size(), _probe_mesh_center()])
			if _frames >= WAIT_A + PRESS_FRAMES:
				_run_press()
				_phase = 2
				_flush()
				print("[探针] 报告已写入 res://_probe_report.txt")
				if is_inside_tree():
					get_tree().quit()


func _say(s: String) -> void:
	_lines.append(s)
	print(s)


func _begin_press() -> void:
	# 触点选法：把模型包围盒切成网格，挑「顶点最密」的格子，
	# 用格内顶点均值当触点。这样保证触点处有足够顶点，测出来的位移才有意义
	# （之前用"最大网格的包围盒中心"，落在稀疏区，圈内只有 6 个顶点，数据无效）。
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
		_say("[阶段B] 找不到可用网格，跳过")
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
			var k: int = cy * cols + cx
			count[k] = int(count.get(k, 0)) + 1
			accum[k] = Vector2(accum.get(k, Vector2.ZERO)) + v

	var best_k := -1
	var best_n := -1
	for k in count:
		if int(count[k]) > best_n:
			best_n = int(count[k])
			best_k = int(k)
	if best_k < 0:
		_say("[阶段B] 网格统计失败，跳过")
		return
	_touch_pt = (accum[best_k] as Vector2) / maxf(float(best_n), 1.0)
	_effective_radius = maxf(float(_deformer.get("radius")), float(_touch.get("radius")))
	# 找出「离触点最近的顶点」所属网格，作为跟踪对象
	var best_d := INF
	for key in meshes:
		var mi = meshes[key]
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		var arr: Array = mi.mesh.surface_get_arrays(0)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		for v in (arr[Mesh.ARRAY_VERTEX] as PackedVector2Array):
			var d: float = v.distance_to(_touch_pt)
			if d < best_d:
				best_d = d
				_probe_key = key

	_say("")
	_say("==================== B) 端到端形变实测 ====================")
	_say("  触点(画布px)           : %s" % str(_touch_pt))
	_say("  跟踪网格               : %s（最近顶点 %.1f px）" % [_probe_key, best_d])
	_say("  该处顶点密度           : %d 个/200px 格（最密格）" % best_n)
	_say("  命中检查               : %s" % str(_deformer.is_point_on_model(_touch_pt)))
	_say("  有效半径               : %.1f" % _effective_radius)
	# 径向顶点分布：解释「为什么峰值只有深度的百分之几十」
	var bands := [10.0, 25.0, 50.0, 100.0, 190.0, 380.0]
	var hist := [0, 0, 0, 0, 0, 0]
	var nearest := INF
	for verts in usable:
		for v in verts:
			var d: float = v.distance_to(_touch_pt)
			nearest = minf(nearest, d)
			for bi in bands.size():
				if d <= bands[bi]:
					hist[bi] = int(hist[bi]) + 1
					break
	_say("  最近顶点距离           : %.1f px" % nearest)
	var seg := ""
	for bi in bands.size():
		seg += "<=%.0fpx:%d  " % [bands[bi], int(hist[bi])]
	_say("  径向顶点累计分布       : %s" % seg)
	_say("  已注入触点（force_state 满压），开始按压 %d 帧 ..." % PRESS_FRAMES)
	_snapshot_pristine()
	_touch.force_state(_touch_pt, true, 1.0, 90.0)


func _run_static() -> void:
	_say("")
	_say("==================== 1) 节点与初始化 ====================")
	_say("  模型节点               : %s" % ("找到" if _model != null else "缺失"))
	_say("  deformer               : %s" % ("找到" if _deformer != null else "缺失"))
	if _model == null:
		_say("  模型缺失，终止")
		return

	var canvas = _model.get_canvas_info()
	_say("  canvas_info            : %s" % str(canvas))
	_say("  模型 scale             : %s" % str(_model.scale))

	_say("")
	_say("==================== 2) ArtMesh 与材质 ====================")
	var meshes: Dictionary = _model.get_meshes()
	_say("  meshes 总数            : %d" % meshes.size())
	if meshes.is_empty():
		_say("  !! get_meshes() 为空 —— cubism 尚未初始化完成")
		return

	var visible_count := 0
	var deg := 0
	var usable: Array = []
	for key in meshes:
		var mi = meshes[key]
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		if not mi.visible:
			continue
		visible_count += 1
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
			deg += 1
			continue
		usable.append([key, mi, verts, Rect2(mn, mx - mn)])
	_say("  可见网格               : %d" % visible_count)
	_say("  退化(零面积)           : %d" % deg)
	_say("  可用网格               : %d" % usable.size())
	if usable.is_empty():
		_say("  没有可用网格，终止")
		return

	var all_mn: Vector2 = (usable[0][3] as Rect2).position
	var all_mx: Vector2 = (usable[0][3] as Rect2).end
	for item in usable:
		var r: Rect2 = item[3]
		all_mn.x = minf(all_mn.x, r.position.x)
		all_mn.y = minf(all_mn.y, r.position.y)
		all_mx.x = maxf(all_mx.x, r.end.x)
		all_mx.y = maxf(all_mx.y, r.end.y)
	var extent: Vector2 = all_mx - all_mn
	_say("  模型可用范围(画布px)   : min=%s max=%s" % [str(all_mn), str(all_mx)])
	_say("  模型可用尺寸(画布px)   : %s" % str(extent))

	_say("")
	_say("==================== 3) radius / depth 占比 ====================")
	var radius: float = float(_deformer.get("radius"))
	var depth: float = float(_deformer.get("depth"))
	_say("  deformer.radius        : %.1f 画布px" % radius)
	_say("  deformer.depth         : %.1f 画布px" % depth)
	_say("  半径 / 模型宽          : %.1f%%" % (radius / maxf(extent.x, 1.0) * 100.0))
	_say("  半径 / 模型高          : %.1f%%" % (radius / maxf(extent.y, 1.0) * 100.0))
	_say("  深度 / 半径            : %.3f" % (depth / maxf(radius, 1.0)))

	var sample = usable[0]
	var smi = sample[1]
	var smesh: ArrayMesh = smi.mesh
	_say("")
	_say("==================== 4) 材质挂在哪 ====================")
	_say("  样本网格 key           : %s" % str(sample[0]))
	_say("  surface 数量           : %d" % smesh.get_surface_count())
	_say("  surface_get_format(0)  : %d" % smesh.surface_get_format(0))
	_say("  surface_get_material(0): %s" % ("有" if smesh.surface_get_material(0) != null else "null"))
	_say("  MeshInstance2D.material: %s" % ("有" if smi.material != null else "null"))
	var has_tex := false
	if smi is MeshInstance2D:
		has_tex = (smi as MeshInstance2D).texture != null
	_say("  MeshInstance2D.texture : %s" % ("有" if has_tex else "null"))

	_say("")
	_say("==================== 5) 顶点写回实测 ====================")
	var base_verts: PackedVector2Array = sample[2]
	var arr0: Array = smesh.surface_get_arrays(0)
	var fmt: int = smesh.surface_get_format(0)
	var mat_before = smesh.surface_get_material(0)
	var offset := Vector2(7.0, -5.0)
	var before_v: Vector2 = base_verts[0]
	var test_verts: PackedVector2Array = base_verts.duplicate()
	test_verts[0] = before_v + offset
	arr0[Mesh.ARRAY_VERTEX] = test_verts
	smesh.clear_surfaces()
	smesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr0, [], {}, fmt)
	var arr_after: Array = smesh.surface_get_arrays(0)
	var after_v: Vector2 = (arr_after[Mesh.ARRAY_VERTEX] as PackedVector2Array)[0]
	var moved: Vector2 = after_v - before_v
	_say("  写入位移               : %s" % str(offset))
	_say("  读回位移               : %s" % str(moved))
	_say("  位移误差               : %.4f px" % moved.distance_to(offset))
	_say("  重建路径写回           : %s" % ("可行" if moved.distance_to(offset) < 0.01 else "不可行"))
	var mat_after = smesh.surface_get_material(0)
	_say("  surface 材质 重建前后  : %s -> %s" % [
		"有" if mat_before != null else "null", "有" if mat_after != null else "null"])
	if mat_before != null and mat_after == null:
		_say("  ⚠ 重建会丢 surface 材质 —— 写完必须补回")
	_say("  MeshInstance2D.material 重建后: %s" % ("有" if smi.material != null else "null"))

	# 还原
	var arr_reset: Array = smesh.surface_get_arrays(0)
	arr_reset[Mesh.ARRAY_VERTEX] = base_verts
	smesh.clear_surfaces()
	smesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr_reset, [], {}, fmt)
	if mat_before != null:
		smesh.surface_set_material(0, mat_before)

	_say("")
	_say("==================== 6) 三角形命中 ====================")
	var idxs: PackedInt32Array = arr0[Mesh.ARRAY_INDEX]
	var inside_pt := Vector2.ZERO
	var got_tri := false
	var hit_in := false
	if idxs.size() >= 3:
		var ia: int = idxs[0]
		var ib: int = idxs[1]
		var ic: int = idxs[2]
		if ia < base_verts.size() and ib < base_verts.size() and ic < base_verts.size():
			inside_pt = (base_verts[ia] + base_verts[ib] + base_verts[ic]) / 3.0
			got_tri = true
	if got_tri:
		hit_in = _deformer.is_point_on_model(inside_pt)
		_say("  模型内三角形重心 %s" % str(inside_pt))
		_say("    -> 命中             : %s" % str(hit_in))
	var far_pt: Vector2 = all_mx + Vector2(3000.0, 3000.0)
	var hit_out: bool = _deformer.is_point_on_model(far_pt)
	_say("  模型外 %s" % str(far_pt))
	_say("    -> 命中             : %s" % str(hit_out))
	if got_tri:
		_say("  命中判定               : %s" % ("正常" if (hit_in and not hit_out) else "异常"))
	var mid: Vector2 = all_mn + extent * 0.5
	_say("  包围盒中心 %s -> 命中 : %s" % [str(mid), str(_deformer.is_point_on_model(mid))])

	_say("")
	_say("==================== 7) 坐标空间一致性 ====================")
	_say("  RegionDetector._to_canvas_space = canvas_transform.affine_inverse() -> model.to_local")
	_say("  TouchManager.to_space           = 同一套换算")
	_say("  模型 scale = %s（工程强制 1）" % str(_model.scale))
	_say("  结论：touch.position 与 ArtMesh 顶点同为『画布像素』空间")


## 把所有 ArtMesh 的顶点抓一份原始静止副本
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
	_say("[阶段B] 已抓取原始静止快照：%d 个网格" % _pristine.size())


## 对 pristine 的真实形变统计
func _report_real_deform() -> void:
	var meshes: Dictionary = _model.get_meshes()
	var mx := 0.0
	var over5 := 0
	var over1 := 0
	var in_r := 0
	var sum_in := 0.0
	var far_mx := 0.0
	var top: Array = []
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
			var dv: float = now_v[i].distance_to(old_v[i])
			var dbase: float = old_v[i].distance_to(_touch_pt)
			mx = maxf(mx, dv)
			if dv > 5.0:
				over5 += 1
			if dv > 1.0:
				over1 += 1
			if dbase <= _effective_radius * 0.5:
				in_r += 1
				sum_in += dv
			if dbase > _effective_radius * 2.0:
				far_mx = maxf(far_mx, dv)
			if dv > 1.0:
				top.append([dv, dbase, k])
	top.sort_custom(func(x, y): return x[0] > y[0])
	_say("  ── 对『原始静止位置』的真实形变（这是肉眼看到的凹陷量）──")
	_say("  全局最大真实位移        : %.2f px" % mx)
	_say("  >5px 顶点数 / >1px 顶点数: %d / %d" % [over5, over1])
	_say("  圈内(<=0.5R) 平均真实位移: %.2f px  (样本 %d)" % [sum_in / maxf(float(in_r), 1.0), in_r])
	_say("  圈外(>2R) 最大真实位移  : %.2f px" % far_mx)
	for q in mini(8, top.size()):
		_say("   #%-2d 真实位移=%7.2f px   离触点=%7.2f px   网格=%s" % [q + 1, top[q][0], top[q][1], str(top[q][2])])

	# ── 网格完整性：三角形有没有被拉翻 / 顶点有没有被压穿触点 ──
	var flipped: int = 0
	var tri_total: int = 0
	var worst_cross: float = 0.0
	var offs_i: Dictionary = _deformer.get("_offsets")
	var bases_i: Dictionary = _deformer.get("_base")
	for k in _pristine:
		var mii = meshes.get(k)
		if not is_instance_valid(mii) or mii.mesh == null or not (mii.mesh is ArrayMesh):
			continue
		var ai: Array = mii.mesh.surface_get_arrays(0)
		if ai.is_empty() or ai[Mesh.ARRAY_VERTEX] == null or ai[Mesh.ARRAY_INDEX] == null:
			continue
		var nv: PackedVector2Array = ai[Mesh.ARRAY_VERTEX]
		var pv2: PackedVector2Array = _pristine[k]
		var idn: PackedInt32Array = ai[Mesh.ARRAY_INDEX]
		if offs_i.has(k) and bases_i.has(k):
			var ov2: PackedVector2Array = offs_i[k]
			var bv2: PackedVector2Array = bases_i[k]
			var nn: int = mini(mini(ov2.size(), bv2.size()), nv.size())
			for i2 in nn:
				var dd2: float = bv2[i2].distance_to(_touch_pt)
				if dd2 > 1.0:
					worst_cross = maxf(worst_cross, ov2[i2].length() / dd2)
		var tc: int = idn.size() / 3
		for t3 in tc:
			var ia3: int = idn[t3 * 3]
			var ib3: int = idn[t3 * 3 + 1]
			var ic3: int = idn[t3 * 3 + 2]
			if ia3 >= nv.size() or ib3 >= nv.size() or ic3 >= nv.size():
				continue
			if ia3 >= pv2.size() or ib3 >= pv2.size() or ic3 >= pv2.size():
				continue
			var an: float = _tri_area(nv[ia3], nv[ib3], nv[ic3])
			var ap: float = _tri_area(pv2[ia3], pv2[ib3], pv2[ic3])
			if absf(ap) < 0.01:
				continue
			tri_total += 1
			if an * ap < 0.0:
				flipped += 1
	_say("  ── 网格完整性 ──")
	_say("  三角形翻转数 / 总数    : %d / %d   ← 0 才说明网格没被拉烂" % [flipped, tri_total])
	_say("  最大『位移 / 到触点距离』: %.3f   ← 必须 < 1（=1 表示顶点正好压到触点）" % worst_cross)


## 有向面积的两倍（用于判断三角形是否翻转）
func _tri_area(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)


func _run_press() -> void:
	_say("")
	_say("  按压结束，读取 deformer 内部 offset ...")
	var elapsed: float = _sim_time - _press_start_time
	_say("  按压帧数 / 真实经过时间: %d 帧 / %.3f s" % [_press_frames, elapsed])
	_say("  ── epilogue delta 诊断 ──")
	_say("  epilogue 触发次数       : %d  (按压 %d 帧 → 每帧 %.2f 次)" % [
		_epi_count, _press_frames, float(_epi_count) / maxf(float(_press_frames), 1.0)])
	_say("  epilogue delta 累计     : %.3f s   (真实经过 %.3f s → 比值 %.3f)" % [
		_epi_delta_total, _sim_time, _epi_delta_total / maxf(_sim_time, 0.0001)])
	_say("  epilogue delta 最后一次 : %.5f s" % _epi_delta_last)
	_say("  ── TouchManager 运行时真实状态 ──")
	_say("  active                 : %s" % str(_touch.get("active")))
	_say("  position               : %s   (注入点 %s)" % [str(_touch.get("position")), str(_touch_pt)])
	_say("  position 与注入点偏差  : %.3f px" % (_touch.get("position") as Vector2).distance_to(_touch_pt))
	_say("  pressure               : %.3f" % float(_touch.get("pressure")))
	_say("  radius                 : %.1f" % float(_touch.get("radius")))
	_say("  duration               : %.3f" % float(_touch.get("duration")))
	_say("  follow_mouse           : %s" % str(_touch.get("follow_mouse")))
	_report_real_deform()
	_say("  ── Top-12 位移顶点诊断（位移最大者 / 它离触点多远）──")
	var offs_t12: Dictionary = _deformer.get("_offsets")
	var meshes_t12: Dictionary = _model.get_meshes()
	var ents_t12: Array = []
	var cnt_t12: int = 0
	for k2 in offs_t12:
		var mi2 = meshes_t12.get(k2)
		if not is_instance_valid(mi2) or mi2.mesh == null or not (mi2.mesh is ArrayMesh):
			continue
		var a2: Array = mi2.mesh.surface_get_arrays(0)
		if a2.is_empty() or a2[Mesh.ARRAY_VERTEX] == null:
			continue
		var vs2: PackedVector2Array = a2[Mesh.ARRAY_VERTEX]
		var os2: PackedVector2Array = offs_t12[k2]
		var n2: int = mini(vs2.size(), os2.size())
		for j2 in n2:
			var L2: float = os2[j2].length()
			if L2 > 5.0:
				cnt_t12 += 1
			if L2 > 1.0:
				ents_t12.append([L2, vs2[j2].distance_to(_touch_pt), j2, k2, vs2[j2], os2[j2]])
	ents_t12.sort_custom(func(x, y): return x[0] > y[0])
	_say("  位移 >5px 的顶点总数    : %d" % cnt_t12)
	for q in mini(12, ents_t12.size()):
		var post: Vector2 = ents_t12[q][4]
		var offv: Vector2 = ents_t12[q][5]
		var base: Vector2 = post - offv
		var to_c: Vector2 = (_touch_pt - base)
		var db: float = to_c.length()
		var dot: float = 1.0
		if db > 0.001 and offv.length() > 0.001:
			dot = offv.normalized().dot(to_c / db)
		_say("   #%-2d 位移=%7.2f  基准离触点=%7.2f  当前离触点=%7.2f  方向一致性=%.3f  网格=%s" % [q + 1, ents_t12[q][0], db, post.distance_to(_touch_pt), dot, str(ents_t12[q][3])])

	_say("  ── deformer 运行时关键参数 ──")
	_say("  enabled/radius/depth   : %s / %.1f / %.1f" % [
		str(_deformer.get("enabled")), float(_deformer.get("radius")), float(_deformer.get("depth"))])
	_say("  power/vol/drag         : %.2f / %.2f / %.2f" % [
		float(_deformer.get("power")), float(_deformer.get("volume_compensation")), float(_deformer.get("drag_amount"))])
	var offs_all: Dictionary = _deformer.get("_offsets")
	var gm := 0.0
	for k in offs_all:
		for o in (offs_all[k] as PackedVector2Array):
			gm = maxf(gm, o.length())
	_say("  deformer 内部全局峰值  : %.2f px" % gm)
	_say("  offset 状态被重置次数  : %d   ← 0 才正常" % int(_deformer.get("_state_resets")))
	_say("  _ensure_state 调用次数 : %d" % int(_deformer.get("_ensure_calls")))
	_say("  重置时丢掉非零形变   : %d   ← 这个才是致命的" % int(_deformer.get("_state_lost")))
	for s in (_deformer.get("_state_lost_samples") as Array):
		_say("     " + str(s))
	_say("")
	_say("  ── 跟踪网格逐帧诊断（%s）──" % _probe_key)
	_say("  顶点数出现过的种类数   : %d" % _track_distinct)
	_say("  offset 状态数组长度种类: %d" % _track_size.size())
	_say("  offset 峰值「腰斩」次数: %d   ← >0 说明被周期性清零" % _drops)
	var series := ""
	var step: int = maxi(1, _track_state.size() / 24)
	var si := 0
	while si < _track_state.size():
		series += "%.1f " % _track_state[si]
		si += step
	_say("  offset 峰值逐帧序列    : %s" % series)
	_say("  平均 delta             : %.5f s  (%.0f fps)" % [
		elapsed / maxf(float(_press_frames), 1.0),
		float(_press_frames) / maxf(elapsed, 0.0001)])
	var offsets: Dictionary = _deformer.get("_offsets")
	_say("  存有 offset 的网格数   : %d" % offsets.size())

	var peak := 0.0
	var near_sum := 0.0
	var near_n := 0
	var far_peak := 0.0
	var far_n := 0
	var mid_peak := 0.0
	var mid_n := 0
	var r: float = maxf(_effective_radius, 1.0)
	# 矩形度指标：把影响区切成 4 个象限，看是否只在「正对方位」有位移
	var quad := [0.0, 0.0, 0.0, 0.0]

	var meshes: Dictionary = _model.get_meshes()
	for key in offsets:
		var mi = meshes.get(key)
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		var arr: Array = mi.mesh.surface_get_arrays(0)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector2Array = arr[Mesh.ARRAY_VERTEX]
		var offs: PackedVector2Array = offsets[key]
		var n: int = mini(verts.size(), offs.size())
		for i in n:
			var mag: float = offs[i].length()
			if mag > peak:
				peak = mag
			var d: float = verts[i].distance_to(_touch_pt)
			if d <= r * 0.5:
				near_sum += mag
				near_n += 1
			elif d <= r * 1.2:
				mid_peak = maxf(mid_peak, mag)
				mid_n += 1
			elif d > r * 2.0:
				far_peak = maxf(far_peak, mag)
				far_n += 1
			if d <= r:
				var rel: Vector2 = verts[i] - _touch_pt
				var qi: int = (0 if rel.x < 0.0 else 1) + (0 if rel.y < 0.0 else 2)
				quad[qi] = maxf(quad[qi] as float, mag)

	var near_avg: float = near_sum / maxf(float(near_n), 1.0)
	_say("  峰值位移               : %.3f px" % peak)
	_say("  圈内(<=0.5R) 平均位移  : %.3f px  (样本 %d)" % [near_avg, near_n])
	_say("  过渡(0.5R~1.2R) 峰值   : %.3f px  (样本 %d)" % [mid_peak, mid_n])
	_say("  圈外(>2R) 峰值位移     : %.3f px  (样本 %d)" % [far_peak, far_n])
	var far_ratio: float = far_peak / maxf(peak, 0.0001)
	_say("  圈外 / 峰值            : %.1f%%" % (far_ratio * 100.0))
	# 用同一套弹簧公式推算：同样时长、真机 60fps 下中心能达到多深
	var proj60: float = _project_depth(elapsed, 60.0)
	var proj15: float = _project_depth(1.5, 60.0)
	_say("  弹簧理论深度(本次时长,60fps): %.2f px" % proj60)
	_say("  弹簧理论深度(1.5s,60fps)    : %.2f px   ← 真机按 1.5 秒的预期" % proj15)
	_say("")
	_say("  逐帧轨迹（帧号 / 全局峰值offset / 带offset网格数 / 跟踪网格中心x,y）:")
	var tr := ""
	var c_first: Vector2 = Vector2.ZERO
	var c_last: Vector2 = Vector2.ZERO
	var c_travel := 0.0
	var c_prev: Vector2 = Vector2.ZERO
	var c_first_set := false
	for item in _trace:
		var c: Vector2 = item[3]
		if not c_first_set:
			c_first = c
			c_prev = c
			c_first_set = true
		c_travel += c_prev.distance_to(c)
		c_prev = c
		c_last = c
		tr += "%d:%.2f(%d)[%.0f,%.0f]  " % [item[0], item[1], item[2], c.x, c.y]
	_say("    " + tr)
	_say("  跟踪网格中心累计移动   : %.1f px" % c_travel)
	_say("  跟踪网格中心首末位移   : %.1f px  (%s -> %s)" % [c_first.distance_to(c_last), str(c_first), str(c_last)])

	# 诊断：deformer 缓存的 AABB 是不是第 1 帧的旧快照（过期会导致空间过滤选错网格）
	var aabbs: Dictionary = _deformer.get("_aabbs")
	var all_meshes: Dictionary = _model.get_meshes()
	var checked := 0
	var stale := 0
	var max_shift := 0.0
	var in_range := 0
	var search_r: float = _effective_radius * float(_deformer.get("mesh_search_margin"))
	for key in aabbs:
		var mi = all_meshes.get(key)
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
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
		var fresh := Rect2(mn, mx - mn)
		var cached: Rect2 = aabbs[key]
		var shift: float = cached.get_center().distance_to(fresh.get_center())
		max_shift = maxf(max_shift, shift)
		if shift > 30.0:
			stale += 1
		checked += 1
		if fresh.get_center().distance_to(_touch_pt) <= search_r:
			in_range += 1
	_say("")
	_say("  ── AABB 缓存诊断（搜索半径 %.0f）──" % search_r)
	_say("  缓存 AABB 条目         : %d（检查 %d）" % [aabbs.size(), checked])
	_say("  AABB 中心偏移 >30px    : %d 个" % stale)
	_say("  AABB 中心最大偏移      : %.1f px" % max_shift)
	_say("  当前真正落在搜索圈内的 : %d 个网格" % in_range)

	# 定位：离触点最近的顶点属于哪个网格？它有没有被形变处理？
	var closest_key := ""
	var closest_v := -1
	var closest_d := INF
	var closest_count := 0
	var closest_verts := PackedVector2Array()
	for key in all_meshes:
		var mi = all_meshes.get(key)
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		var arr: Array = mi.mesh.surface_get_arrays(0)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector2Array = arr[Mesh.ARRAY_VERTEX]
		for i in verts.size():
			var d: float = verts[i].distance_to(_touch_pt)
			if d < closest_d:
				closest_d = d
				closest_key = key
				closest_v = i
				closest_count = verts.size()
				closest_verts = verts
	var offs: Dictionary = _deformer.get("_offsets")
	var cl_mi = all_meshes.get(closest_key)
	_say("")
	_say("  ── 最近顶点归属 ──")
	_say("  最近顶点               : %.1f px（网格 %s，顶点 #%d，该网格共 %d 顶点）" % [
		closest_d, closest_key, closest_v, closest_count])
	_say("  该网格在 _offsets 中   : %s" % str(offs.has(closest_key)))
	_say("  该网格在 _aabbs 中     : %s" % str(aabbs.has(closest_key)))
	if cl_mi != null:
		_say("  该网格 visible         : %s" % str(cl_mi.visible))
	_say("  该网格 cached AABB     : %s" % str(aabbs.get(closest_key, "无缓存")))
	# 该网格当前 AABB
	if not closest_verts.is_empty():
		var cmn: Vector2 = closest_verts[0]
		var cmx: Vector2 = closest_verts[0]
		for v in closest_verts:
			cmn.x = minf(cmn.x, v.x)
			cmn.y = minf(cmn.y, v.y)
			cmx.x = maxf(cmx.x, v.x)
			cmx.y = maxf(cmx.y, v.y)
		_say("  该网格 fresh  AABB     : %s" % str(Rect2(cmn, cmx - cmn)))
	if offs.has(closest_key):
		var o: PackedVector2Array = offs[closest_key]
		var mx_off := 0.0
		for x in o:
			mx_off = maxf(mx_off, x.length())
		_say("  该网格最大 offset      : %.2f px" % mx_off)
	_say("  四象限峰值(左上/右上/左下/右下): %.2f / %.2f / %.2f / %.2f" % [
		quad[0], quad[1], quad[2], quad[3]])
	var quad_min: float = minf(minf(quad[0] as float, quad[1] as float), minf(quad[2] as float, quad[3] as float))
	var quad_max: float = maxf(maxf(quad[0] as float, quad[1] as float), maxf(quad[2] as float, quad[3] as float))
	_say("  象限均匀度(min/max)    : %.2f  （越接近 1 越圆；矩形变形会明显偏小）" % (quad_min / maxf(quad_max, 0.0001)))
	_say("")
	_say("  ── 判定 ──")
	_say("  顶点被推动             : %s" % ("是" if peak > 0.5 else "否"))
	_say("  位移随距离衰减         : %s" % ("是" if near_avg > far_peak else "否"))
	_say("  圈外基本不动           : %s" % ("是" if far_ratio < 0.25 else "否"))
	_say("  近似圆形（非矩形）     : %s" % ("是" if (quad_min / maxf(quad_max, 0.0001)) > 0.35 else "否"))


## 按 mesh_deformer 的逐顶点弹簧公式，推算给定时长下中心能达到的位移深度。
## 目的：headless 不锁帧，实测时长与 60fps 差很多，必须换算才有可比性。
func _project_depth(seconds: float, fps: float) -> float:
	var h := 1.0 / fps
	var strength: float = float(_deformer.get("spring_strength"))
	var damp: float = float(_deformer.get("spring_damping"))
	var depth: float = float(_deformer.get("depth"))
	var c := 0.0
	var v := 0.0
	var target: float = -depth
	var n: int = maxi(1, int(seconds * fps))
	for _i in n:
		v += (target - c) * strength * h
		v *= pow(clampf(damp, 0.0, 0.9999), h * 60.0)
		c += v * h
	return absf(c)


## 逐帧跟踪「离触点最近的那个网格」的 offset 峰值与顶点数，
## 用来判断 _ensure_state 是否在周期性把 offset 清零（顶点数变化会触发重置）。
func _tick_tracked() -> void:
	if _probe_key == "":
		return
	var meshes: Dictionary = _model.get_meshes()
	var mi = meshes.get(_probe_key)
	if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
		return
	var arr: Array = mi.mesh.surface_get_arrays(0)
	if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
		return
	var vcount: int = (arr[Mesh.ARRAY_VERTEX] as PackedVector2Array).size()
	var offs: Dictionary = _deformer.get("_offsets")
	var peak := 0.0
	var scount := -1
	if offs.has(_probe_key):
		var o: PackedVector2Array = offs[_probe_key]
		scount = o.size()
		for x in o:
			peak = maxf(peak, x.length())
	_track_count.append(vcount)
	_track_state.append(peak)
	_track_size.append(scount)
	if _track_state.size() >= 2:
		var prev: float = _track_state[_track_state.size() - 2]
		if peak < prev * 0.5 and prev > 1.0:
			_drops += 1
	var seen := {}
	for c in _track_count:
		seen[c] = true
	_track_distinct = seen.size()


## 跟踪网格的中心（用于判断模型是否在动画中"扫过"触点）
func _probe_mesh_center() -> Vector2:
	if _probe_key == "":
		return Vector2.ZERO
	var meshes: Dictionary = _model.get_meshes()
	var mi = meshes.get(_probe_key)
	if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
		return Vector2.ZERO
	var arr: Array = mi.mesh.surface_get_arrays(0)
	if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
		return Vector2.ZERO
	var verts: PackedVector2Array = arr[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return Vector2.ZERO
	var mn: Vector2 = verts[0]
	var mx: Vector2 = verts[0]
	for v in verts:
		mn.x = minf(mn.x, v.x)
		mn.y = minf(mn.y, v.y)
		mx.x = maxf(mx.x, v.x)
		mx.y = maxf(mx.y, v.y)
	return (mn + mx) * 0.5


## 当前 deformer 内部所有 offset 的最大模长（用于看弹簧是否在收敛）
func _peak_now() -> float:
	var offsets: Dictionary = _deformer.get("_offsets")
	var best := 0.0
	for key in offsets:
		for o in (offsets[key] as PackedVector2Array):
			var m: float = o.length()
			if m > best:
				best = m
	return best


func _flush() -> void:
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f == null:
		print("[探针] 报告写入失败")
		return
	for l in _lines:
		f.store_line(l)
	f.close()
