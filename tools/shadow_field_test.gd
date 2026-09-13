## STEP 4 阴影画笔验收测试（A~L 十二项 + M/N/O 外部回归）
##
## 运行（主场景模式 —— 不要用 --script 模式，ScreenDeform autoload 在那种模式下
## 会因 current_scene==null 无限 call_deferred 并把进程带崩）：
##   J:\live2d_game\engine\Godot.exe --headless --path . res://tools/shadow_test.tscn
##
## 结果同时 print 并写 res://_shadow_field_test_report.txt（崩溃也不丢数据）。

extends Node

var _ok := true
var _count := 0
var _fails: Array[String] = []


func _check(cond: bool, label: String) -> void:
	_count += 1
	if cond:
		print("  ✓ %s" % label)
	else:
		_ok = false
		_fails.append(label)
		print("  ✗ %s" % label)


func _ready() -> void:
	_test_A_palm_alone()
	_test_B_palm_one_finger()
	_test_C_palm_three_fingers()
	_test_D_follow()
	_test_E_rotation()
	_test_F_no_jitter()
	_test_G_alpha_zero()
	_test_H_alpha_full()
	_test_I_zoom_model_space()
	_test_J_inactive_hidden()
	_test_K_nan_guard()
	_test_L_vertices_untouched()

	print("")
	print("============================================================")
	print("[阴影测试] 结果：%d 项断言，%s" % [
		_count, "全部通过（A~L，M/N/O 由外部回归）" if _ok else "有失败"])
	for f in _fails:
		print("   ✗ %s" % f)
	print("============================================================")

	# 落文件：headless 收尾段错误可能吞掉 stdout 缓冲，文件才是可靠凭证
	var fr := FileAccess.open("res://_shadow_field_test_report.txt", FileAccess.WRITE)
	if fr != null:
		fr.store_line("shadow_field_test: %d assertions, %s" % [_count, "ALL PASS" if _ok else "FAIL"])
		for f2 in _fails:
			fr.store_line("  FAIL: " + f2)
		fr.close()
	get_tree().quit(0 if _ok else 1)


## ── 公共小工具 ──

func _make_field(finger_n: int = 5) -> ShadowField:
	var f := ShadowField.new()
	f.palm_texture = _mk_tex(282)
	for i in finger_n:
		f.finger_textures.append(_mk_tex(97 + i))
	add_child(f)
	return f


## 测试用假纹理：GradientTexture2D 可以指定宽度，笔刷 scale 才算得出来
func _mk_tex(w: int) -> Texture2D:
	var g := GradientTexture2D.new()
	g.width = w
	g.height = w
	g.fill_from = Vector2(0, 0)
	g.fill_to = Vector2(1, 0)
	var gr := Gradient.new()
	gr.colors = PackedColorArray([Color(0, 0, 0, 1), Color(0, 0, 0, 0)])
	g.gradient = gr
	return g


func _contact(p_type: int, pos: Vector2, radius: float, pressure: float,
		dir: Vector2 = Vector2.RIGHT, active: bool = true) -> HandContact:
	return HandContact.make(p_type, pos, radius, pressure, 1.0, dir, Vector2.ZERO, active)


## ── A~C：生成 ──

func _test_A_palm_alone() -> void:
	print("\nA) Palm 单独生成")
	var f := _make_field()
	f.update_contacts([_contact(HandContact.Type.PALM, Vector2(100, 200), 92, 1.0)])
	_check(f.visible_count() == 1, "A: 1 颗掌心接触 → 1 枚可见笔刷")
	var brushes: Array = f.get("_pool")
	_check(brushes[0].texture == f.palm_texture, "A: 掌心笔刷用 palm 纹理")
	_check((brushes[0] as Sprite2D).position.is_equal_approx(Vector2(100, 200)), "A: 笔刷位置 = 接触位置")
	f.free()


func _test_B_palm_one_finger() -> void:
	print("\nB) Palm + 1 Finger")
	var f := _make_field()
	f.update_contacts([
		_contact(HandContact.Type.PALM, Vector2(0, 0), 92, 1.0),
		_contact(HandContact.Type.FINGER, Vector2(92, -40), 25, 1.0),
	])
	var brushes: Array = f.get("_pool")
	_check(f.visible_count() == 2, "B: 2 颗接触 → 2 枚可见笔刷")
	_check(brushes[1].texture == f.finger_textures[0], "B: 指尖用 fingertip_01 纹理")
	_check((brushes[1] as Sprite2D).position.is_equal_approx(Vector2(92, -40)), "B: 指尖笔刷位置正确")
	f.free()


func _test_C_palm_three_fingers() -> void:
	print("\nC) Palm + 3 Fingers")
	var f := _make_field()
	var cs: Array[HandContact] = [_contact(HandContact.Type.PALM, Vector2.ZERO, 92, 1.0)]
	for i in 3:
		cs.append(_contact(HandContact.Type.FINGER, Vector2(92, -40.0 + 40.0 * i), 25, 1.0))
	f.update_contacts(cs)
	var brushes: Array = f.get("_pool")
	_check(f.visible_count() == 4, "C: 4 颗接触 → 4 枚可见笔刷")
	var texes: Array = []
	for i in range(1, 4):
		texes.append(brushes[i].texture)
	_check(texes[0] != texes[1] and texes[1] != texes[2], "C: 三根手指用不同纹理（不是一张大图）")
	f.free()


## ── D~F：跟随与防抖 ──

func _test_D_follow() -> void:
	print("\nD) Contact 移动 → Shadow 跟随")
	var f := _make_field()
	f.update_contacts([_contact(HandContact.Type.PALM, Vector2(100, 100), 92, 1.0)])
	f.update_contacts([_contact(HandContact.Type.PALM, Vector2(300, 500), 92, 1.0)])
	var b: Sprite2D = f.get("_pool")[0]
	_check(b.position.is_equal_approx(Vector2(300, 500)), "D: 第二帧笔刷位置 = 新接触位置")
	f.free()


func _test_E_rotation() -> void:
	print("\nE) Rotation 跟随 direction")
	var f := _make_field()
	f.update_contacts([_contact(HandContact.Type.PALM, Vector2.ZERO, 92, 1.0, Vector2.RIGHT)])
	var r1: float = (f.get("_pool")[0] as Sprite2D).rotation
	f.update_contacts([_contact(HandContact.Type.PALM, Vector2.ZERO, 92, 1.0, Vector2.DOWN)])
	var r2: float = (f.get("_pool")[0] as Sprite2D).rotation
	_check(absf(r1) < 0.001, "E: 向右 → rot≈0°")
	_check(absf(r2 - PI * 0.5) < 0.001, "E: 向下 → rot≈90°")
	f.free()


func _test_F_no_jitter() -> void:
	print("\nF) 静止时 rotation 不抖")
	var f := _make_field()
	var dir := Vector2(0.8, 0.6).normalized()
	var rots: Array = []
	for i in 6:
		f.update_contacts([_contact(HandContact.Type.PALM, Vector2.ZERO, 92, 1.0, dir)])
		rots.append((f.get("_pool")[0] as Sprite2D).rotation)
	var same := true
	for r in rots:
		if not is_equal_approx(r, rots[0]):
			same = false
	_check(same, "F: 6 帧同方向 → rotation 恒定（无抖动）")
	f.free()


## ── G~H：压力 → Alpha ──

func _test_G_alpha_zero() -> void:
	print("\nG) pressure=0 → alpha = min_alpha")
	var f := _make_field()
	f.update_contacts([_contact(HandContact.Type.PALM, Vector2.ZERO, 92, 0.0)])
	var b: Sprite2D = f.get("_pool")[0]
	_check(is_equal_approx(b.modulate.a, f.min_alpha), "G: alpha == min_alpha (%.2f)" % f.min_alpha)
	f.free()


func _test_H_alpha_full() -> void:
	print("\nH) pressure=1 → alpha = max_alpha")
	var f := _make_field()
	f.update_contacts([_contact(HandContact.Type.PALM, Vector2.ZERO, 92, 1.0)])
	var b: Sprite2D = f.get("_pool")[0]
	_check(is_equal_approx(b.modulate.a, f.max_alpha), "H: alpha == max_alpha (%.2f)" % f.max_alpha)
	# 手指权重 0.78：alpha 应比掌心低
	f.update_contacts([
		_contact(HandContact.Type.PALM, Vector2.ZERO, 92, 1.0),
		_contact(HandContact.Type.FINGER, Vector2(92, 0), 25, 1.0),
	])
	var bf: Sprite2D = f.get("_pool")[1]
	var bp: Sprite2D = f.get("_pool")[0]
	_check(bf.modulate.a < bp.modulate.a - 0.01,
		"H: 指尖 alpha(%.3f) < 掌心(%.3f)，权重 0.78 生效" % [bf.modulate.a, bp.modulate.a])
	f.free()


## ── I：zoom 模型空间恒定 ──

func _test_I_zoom_model_space() -> void:
	print("\nI) zoom 0.3 / 1.0 / 2.5 → 模型空间尺寸恒定")
	var holder := Node2D.new()
	add_child(holder)
	var f := ShadowField.new()
	f.palm_texture = _mk_tex(282)
	f.finger_textures.append(_mk_tex(97))
	holder.add_child(f)
	var palm := _contact(HandContact.Type.PALM, Vector2(500, 500), 92, 1.0)
	var sizes: Array = []
	var b: Sprite2D = null
	for z in [0.3, 1.0, 2.5]:
		holder.scale = Vector2(z, z)
		f.update_contacts([palm])
		b = f.get("_pool")[0]
		var world_d: float = b.scale.x * b.texture.get_width() * holder.scale.x   # 屏幕直径
		var model_d: float = world_d / z                                          # 还原到模型空间
		sizes.append(model_d)
		print("  zoom=%.1f  屏幕直径=%7.1f px  模型直径=%7.1f px（期望 %.1f）"
			% [z, world_d, model_d, 2.0 * 92.0 * b.diameter_factor])
	_check(is_equal_approx(sizes[0], sizes[1]) and is_equal_approx(sizes[1], sizes[2]),
		"I: 三个 zoom 下模型空间直径恒定（不用屏幕像素）")
	f.free()
	holder.free()


## ── J：inactive 隐藏 ──

func _test_J_inactive_hidden() -> void:
	print("\nJ) inactive contact → 正确隐藏")
	var f := _make_field()
	f.update_contacts([_contact(HandContact.Type.PALM, Vector2.ZERO, 92, 1.0, Vector2.RIGHT, true)])
	_check(f.visible_count() == 1, "J: active 时可见")
	f.update_contacts([_contact(HandContact.Type.PALM, Vector2.ZERO, 92, 1.0, Vector2.RIGHT, false)])
	_check(f.visible_count() == 0, "J: inactive 后全部隐藏")
	f.update_contacts([])
	_check(f.visible_count() == 0 and f.active_count == 0, "J: contacts 清空后仍为 0")
	f.free()


## ── K：NaN 防护 ──

func _test_K_nan_guard() -> void:
	print("\nK) 不产生 NaN")
	var f := _make_field()
	var bad := _contact(HandContact.Type.PALM, Vector2(NAN, 100), 92, 1.0)
	f.update_contacts([bad])
	_check(f.visible_count() == 0, "K: NaN 位置的笔刷被拒显")
	_check(int(f.get("nan_rejects")) >= 1, "K: NaN 拦截计数生效")
	var b: Sprite2D = f.get("_pool")[0]
	_check(is_finite(b.position.x) and is_finite(b.position.y), "K: 笔刷 transform 无 NaN 残留")
	f.free()


## ── L：MeshDeformer 顶点零改动 ──

func _test_L_vertices_untouched() -> void:
	print("\nL) 不修改 MeshDeformer 顶点")
	# 造一个假 ArtMesh（ArrayMesh + MeshInstance2D），跑满阴影系统，
	# 若 ShadowBrush 有任何顶点写入，这里会第一时间暴露
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(0, 100)])
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance2D.new()
	mi.mesh = mesh
	add_child(mi)

	var before: Array = mesh.surface_get_arrays(0)

	var f := _make_field()
	f.update_contacts([
		_contact(HandContact.Type.PALM, Vector2(50, 50), 92, 1.0),
		_contact(HandContact.Type.FINGER, Vector2(60, 60), 25, 1.0),
	])
	f.update_contacts([])      # 再走一遍回收路径
	var ran: bool = f.get("_pool").size() > 0
	f.free()

	var after: Array = mesh.surface_get_arrays(0)
	var verts_b: PackedVector2Array = before[Mesh.ARRAY_VERTEX]
	var verts_a: PackedVector2Array = after[Mesh.ARRAY_VERTEX]
	var same := verts_b.size() == verts_a.size()
	if same:
		for i in verts_b.size():
			if not verts_b[i].is_equal_approx(verts_a[i]):
				same = false
				break
	_check(same, "L: 阴影系统跑过后 Mesh 顶点逐位不变")
	_check(ran, "L: （对照）阴影系统确实运行过")
	mi.free()
