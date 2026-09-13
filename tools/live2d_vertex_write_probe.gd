## 顶点写回诊断（headless）
##
## surface_update_vertex_region 在插件网格上没生效，本工具分三步定位原因：
##   A) 先在一张「自己造的 ArrayMesh」上测这个 API —— 判断是 API 用法问题还是插件网格的问题
##   B) 打印插件网格的 surface 格式 / 顶点数 / 索引数 / 材质，看清能不能照着重建
##   C) 试 add_surface_from_arrays 重建 surface 0，再读回 —— 这是写回失败时的兜底方案
##
## 运行：
##   J:\live2d_game\engine\Godot.exe --headless --script res://tools/_probe_vertex_write.gd

extends SceneTree

const MODEL := "res://models/MO/MO.model3.json"


func _initialize() -> void:
	print("\n===== A) 自造 ArrayMesh 上测 surface_update_vertex_region =====")
	_synthetic_test()

	print("\n===== B) 插件网格的 surface 情况 =====")
	var model = ClassDB.instantiate("GDCubismUserModel")
	root.add_child(model)
	model.set_assets(MODEL)
	model.advance(0.1)
	var meshes: Dictionary = model.get_meshes()

	var checked := 0
	var sample_key = null
	var sample_mi = null
	for k in meshes:
		var mi = meshes[k]
		if mi == null or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		var am = mi.mesh
		if am.get_surface_count() <= 0:
			continue
		var arr: Array = am.surface_get_arrays(0)
		var v = arr[Mesh.ARRAY_VERTEX]
		if v == null or (v as PackedVector2Array).is_empty():
			continue
		if checked < 3:
			print("  网格[%s]  surf=%d  format=%d  array_len=%d  index_len=%d  属性数=%d"
				% [str(k), am.get_surface_count(), am.surface_get_format(0),
					am.surface_get_array_len(0), am.surface_get_array_index_len(0), arr.size()])
			print("       ARRAY_VERTEX 类型=%s  size=%d"
				% [type_string(typeof(v)), (v as PackedVector2Array).size()])
			print("       含索引=%s   有UV=%s   有颜色=%s"
				% [arr[Mesh.ARRAY_INDEX] != null, arr[Mesh.ARRAY_TEX_UV] != null,
					arr[Mesh.ARRAY_COLOR] != null])
			print("       MeshInstance2D: texture=%s material=%s visible=%s"
				% [str(mi.texture), str(mi.material), str(mi.visible)])
		if sample_key == null:
			sample_key = k
			sample_mi = mi
		checked += 1
	print("  共 %d 个可用网格，样例键 = %s" % [checked, str(sample_key)])

	print("\n===== C) 用 add_surface_from_arrays 重建 surface 0 =====")
	if sample_mi != null:
		var am2 = sample_mi.mesh
		var arr2: Array = am2.surface_get_arrays(0)
		var before: PackedVector2Array = arr2[Mesh.ARRAY_VERTEX]
		var fmt: int = am2.surface_get_format(0)
		# 造一份「被推动过」的顶点
		var moved := PackedVector2Array()
		moved.resize(before.size())
		for i in before.size():
			moved[i] = before[i] + Vector2(12.0, -9.0)
		var new_arr := arr2.duplicate()
		new_arr[Mesh.ARRAY_VERTEX] = moved
		am2.clear_surfaces()
		am2.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, new_arr, [], {}, fmt)
		var after: PackedVector2Array = am2.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		print("  重建前 v0 = %s" % str(before[0]))
		print("  重建后 v0 = %s   （期望 %s）" % [str(after[0]), str(before[0] + Vector2(12.0, -9.0))])
		var ok: bool = after[0].distance_to(before[0] + Vector2(12.0, -9.0)) < 0.01
		print("  add_surface_from_arrays 重建 = %s" % ("可行 ✓" if ok else "不可行 ✗"))
		print("  重建后 surf 数 = %d  format = %d" % [am2.get_surface_count(), am2.surface_get_format(0)])

	model.free()
	quit(0)


## A) 在自造网格上验证 API 用法
func _synthetic_test() -> void:
	var verts := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)])
	var idx := PackedInt32Array([0, 1, 2])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_INDEX] = idx

	var am := ArrayMesh.new()
	# 带 2D 顶点标志，和插件网格同构
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
		Mesh.ARRAY_FLAG_USE_2D_VERTICES)
	print("  造好：surf=%d format=%d 顶点=%d 索引=%d"
		% [am.get_surface_count(), am.surface_get_format(0),
			am.surface_get_array_len(0), am.surface_get_array_index_len(0)])

	# 尝试 1：Vector2 打包（8 字节/顶点）
	var f32 := PackedFloat32Array([100.0, 100.0, 10.0, 0.0, 0.0, 10.0])
	am.surface_update_vertex_region(0, 0, f32.to_byte_array())
	var got1: PackedVector2Array = am.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	print("  尝试1 (Vector2 打包) 读回 v0 = %s" % str(got1[0]))

	# 尝试 2：Vector3 打包（12 字节/顶点，Godot 内部可能按 Vector3 存）
	var f32b := PackedFloat32Array([200.0, 200.0, 0.0, 10.0, 0.0, 0.0, 0.0, 10.0, 0.0])
	am.surface_update_vertex_region(0, 0, f32b.to_byte_array())
	var got2: PackedVector2Array = am.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	print("  尝试2 (Vector3 打包) 读回 v0 = %s" % str(got2[0]))

	if got1[0].distance_to(Vector2(100, 100)) < 0.01:
		print("  -> API 可用，Vector2 打包正确")
	elif got2[0].distance_to(Vector2(200, 200)) < 0.01:
		print("  -> API 可用，但必须按 Vector3 打包（12 字节/顶点）")
	else:
		print("  -> 本地 API 完全没生效，说明 surface_update_vertex_region 在此引擎版本不可用")
