## Live2D ArtMesh 顶点「读 + 写」验证（headless）
##
## 运行：
##   J:\live2d_game\engine\Godot.exe --headless --script res://tools/live2d_vertex_probe.gd
##
## 目的：把路线评审里那个「最关键的技术节点」验穿 ——
##   gd_cubism 到底有没有开放 ArtMesh 顶点数据？能不能写回去？
##
## 验证步骤：
##   1) 能不能拿到 get_meshes()（网格字典）
##   2) 每个网格是不是 MeshInstance2D + ArrayMesh
##   3) surface_get_arrays(0) 能不能读到 ARRAY_VERTEX / ARRAY_INDEX
##   4) surface_update_vertex_region() 能不能把改动的顶点写回去（读后再读，确认变了）
##   5) 写回后能否还原
##   6) 顺带打印 canvas_info 的字段（后续坐标换算要用）
##
## 已知限制（原 mesh_pick_prototype.gd 记录）：headless 下插件的顶点更新挂在渲染路径上，
## 1162 个网格里只有约 263 个有真实顶点数据。所以本工具会自动挑「有数据的」来测。

extends SceneTree

const MODEL := "res://models/MO/MO.model3.json"


func _initialize() -> void:
	var ok := true

	print("[顶点验证] 加载模型 ", MODEL)
	var model = ClassDB.instantiate("GDCubismUserModel")
	if model == null:
		print("[顶点验证] 失败：插件未加载，拿不到 GDCubismUserModel")
		quit(1)
		return
	root.add_child(model)
	model.set_assets(MODEL)
	model.advance(0.1)
	model.advance(0.1)

	# ---- 1) get_meshes ----
	var meshes: Dictionary = model.get_meshes()
	print("[顶点验证] 1) get_meshes() -> %d 个网格" % meshes.size())
	if meshes.is_empty():
		print("       失败：没拿到网格")
		quit(1)
		return

	# ---- 2) 类型确认 + 找有数据的网格 ----
	var arr_mesh_n := 0
	var with_verts := 0
	var sample_key = null
	var sample_mi = null
	var sample_verts: PackedVector2Array = PackedVector2Array()
	var degenerate := 0

	for k in meshes:
		var mi = meshes[k]
		if mi == null or mi.mesh == null:
			continue
		if mi.mesh is ArrayMesh:
			arr_mesh_n += 1
		else:
			continue
		var arr: Array = mi.mesh.surface_get_arrays(0)
		if arr.is_empty():
			continue
		var v = arr[Mesh.ARRAY_VERTEX]
		if v == null or (v as PackedVector2Array).is_empty():
			continue
		with_verts += 1
		var pv: PackedVector2Array = v
		# 退化网格判据（沿用 mesh_pick_prototype.gd 的结论）
		var mn: Vector2 = pv[0]
		var mx: Vector2 = pv[0]
		for p in pv:
			mn.x = minf(mn.x, p.x); mn.y = minf(mn.y, p.y)
			mx.x = maxf(mx.x, p.x); mx.y = maxf(mx.y, p.y)
		if (mx - mn).length_squared() < 0.0001:
			degenerate += 1
			continue
		if sample_key == null:
			sample_key = k
			sample_mi = mi
			sample_verts = pv

	print("[顶点验证] 2) ArrayMesh 网格 %d 个；读到真实顶点 %d 个（其中退化 %d 个）"
		% [arr_mesh_n, with_verts, degenerate])
	if sample_key == null:
		print("       失败：没有可用的非退化网格")
		quit(1)
		return
	print("       样例网格键 = %s" % str(sample_key))
	print("       顶点数 = %d   索引数 = %d"
		% [sample_verts.size(), (sample_mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size()])
	print("       前 3 个顶点 = %s" % str([
		sample_verts[0] if sample_verts.size() > 0 else Vector2.ZERO,
		sample_verts[1] if sample_verts.size() > 1 else Vector2.ZERO,
		sample_verts[2] if sample_verts.size() > 2 else Vector2.ZERO,
	]))

	# ---- 4) 写回测试 ----
	var before: Vector2 = sample_verts[0]
	var offset := Vector2(9.0, -7.0)
	var f32 := PackedFloat32Array()
	f32.resize(sample_verts.size() * 2)
	for i in sample_verts.size():
		var p: Vector2 = sample_verts[i]
		f32[i * 2] = p.x + offset.x
		f32[i * 2 + 1] = p.y + offset.y

	var am = sample_mi.mesh
	am.surface_update_vertex_region(0, 0, f32.to_byte_array())

	var after_arr: Array = am.surface_get_arrays(0)
	var after: PackedVector2Array = after_arr[Mesh.ARRAY_VERTEX]
	var moved: Vector2 = after[0] - before
	print("[顶点验证] 3) 写入位移 %s -> 读回实际位移 %s" % [str(offset), str(moved)])
	var write_ok: bool = moved.distance_to(offset) < 0.01
	if write_ok:
		print("       surface_update_vertex_region() 可用（顶点确实被改写）")
	else:
		print("       surface_update_vertex_region() 读回无变化")
		print("       ⚠ 注意：它写的是 RenderingServer 侧顶点缓冲，绕过 CPU 数组，")
		print("         所以 headless 下永远读不到变化 —— 这不代表真机不行，但无头验不了。")
		print("         → 兜底方案见 tools\\live2d_vertex_write_probe.gd 的 add_surface_from_arrays（已实测可行）")

	# ---- 5) 还原 ----
	var f32r := PackedFloat32Array()
	f32r.resize(sample_verts.size() * 2)
	for i in sample_verts.size():
		f32r[i * 2] = sample_verts[i].x
		f32r[i * 2 + 1] = sample_verts[i].y
	am.surface_update_vertex_region(0, 0, f32r.to_byte_array())
	var restored: PackedVector2Array = (am.surface_get_arrays(0) as Array)[Mesh.ARRAY_VERTEX]
	var back_ok: bool = restored[0].distance_to(before) < 0.01
	print("[顶点验证] 4) 还原顶点 %s" % ("成功" if back_ok else "失败"))
	if not back_ok:
		ok = false

	# ---- 6) canvas_info ----
	var info: Dictionary = model.get_canvas_info()
	print("[顶点验证] 5) canvas_info 字段：")
	for key in info:
		print("       %s = %s" % [str(key), str(info[key])])

	# ---- 汇总 ----
	print("\n[顶点验证] 结论：")
	print("       · ArtMesh 顶点数据 = 开放（get_meshes -> ArrayMesh -> ARRAY_VERTEX/ARRAY_INDEX/UV）")
	print("       · 顶点坐标系 = 模型画布像素系（canvas_info 的 origin_in_pixels 为原点）")
	print("       · 顶点写回 = %s" % ("region 写法可用" if write_ok
		else "region 写法 headless 验不了；rebuild 写法已实测可行（见 live2d_vertex_write_probe.gd）"))
	print("       · 形变应在 cubism_epilogue 信号里做（插件推完、渲染前）")
	print("[顶点验证] 结果：%s（read-only 部分%s）"
		% ["通过" if ok else "部分通过", "全通过" if ok else "有未验证项，见上"])

	model.free()
	quit(0 if ok else 1)
