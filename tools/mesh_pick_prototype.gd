## 大部件拾取原型（未接入游戏，仅用于验证算法与性能）
##
## 用法：Godot.exe --headless --path <工程> --script res://tools/mesh_pick_prototype.gd
##
## 已验证的三件事：
##   1. 三角形级命中可行：surface_get_arrays(0) 能拿到 ARRAY_VERTEX / ARRAY_INDEX。
##   2. 必须跳过「退化网格」：有些 ArtMesh 顶点全为 0（AABB 面积为 0），
##      退化三角形会让「任意点都算命中」，而这些空网格往往 drawable 序号很大、
##      排在最上层，会把所有点击截胡。判据：(max-min).length_squared() < 0.0001 就跳过。
##   3. 必须按部件不透明度过滤：get_part_opacities() 返回的是 GDCubismPartOpacity
##      资源对象（有 id / value / get_value() / set_value()），不是 float 数组。
##      value <= 0.001 的部件是换装里没启用的，不该被点到。
##
## 尚未验证（受无头模式限制，必须开真机测）：
##   gd_cubism 的顶点缓冲更新挂在渲染路径上，--headless 下 _draw() 不执行，
##   1162 个网格里恒定只有 263 个有真实顶点数据，advance() 调多少次都不变。
##   -> 正式实现里，缓存必须在「第一帧渲染之后」再建立，且允许后续刷新。
##
extends SceneTree

const MODEL := "res://models/MO/MO.model3.json"

var _region: Dictionary = {}
var _part_idx: Dictionary = {}
var _draw_idx: Dictionary = {}
var _meshes: Dictionary = {}
var _opac_by_id: Dictionary = {}   # Part Id -> 不透明度(float)
var _part_id_of_index: Dictionary = {}
var _cache: Dictionary = {}
var _skipped_degenerate: int = 0
var _skipped_hidden: int = 0


func _tri(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
	var d2 := (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)
	var d3 := (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)
	var neg := (d1 < 0.0) or (d2 < 0.0) or (d3 < 0.0)
	var pos := (d1 > 0.0) or (d2 > 0.0) or (d3 > 0.0)
	return not (neg and pos)


## 预热：缓存每个网格的顶点/索引/AABB，并跳过退化网格与隐藏部件
func warmup() -> void:
	for k in _meshes:
		var pi: int = _part_idx.get(k, -1)
		if pi >= 0:
			var pid: String = _part_id_of_index.get(pi, "")
			if pid != "" and _opac_by_id.has(pid):
				var o: float = _opac_by_id[pid]
				if o <= 0.001:
					_skipped_hidden += 1
					continue
		var mi = _meshes[k]
		if not mi.visible:
			continue
		var arr: Array = mi.mesh.surface_get_arrays(0)
		var verts: PackedVector2Array = arr[Mesh.ARRAY_VERTEX]
		var idxs: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var mn := verts[0]
		var mx := verts[0]
		for v in verts:
			mn.x = minf(mn.x, v.x); mn.y = minf(mn.y, v.y)
			mx.x = maxf(mx.x, v.x); mx.y = maxf(mx.y, v.y)
		if (mx - mn).length_squared() < 0.0001:
			_skipped_degenerate += 1
			continue
		_cache[k] = {"v": verts, "i": idxs, "mn": mn, "mx": mx,
			"d": _draw_idx.get(k, mi.get_index())}


func pick(pt: Vector2) -> String:
	var best_d: float = -1.0
	var best: String = ""
	for k in _cache:
		var e: Dictionary = _cache[k]
		var mn: Vector2 = e["mn"]
		var mx: Vector2 = e["mx"]
		if pt.x < mn.x or pt.x > mx.x or pt.y < mn.y or pt.y > mx.y:
			continue
		var verts: PackedVector2Array = e["v"]
		var idxs: PackedInt32Array = e["i"]
		var n: int = idxs.size() / 3
		for t in range(n):
			if _tri(pt, verts[idxs[t * 3]], verts[idxs[t * 3 + 1]], verts[idxs[t * 3 + 2]]):
				var d: float = e["d"]
				if d > best_d:
					best_d = d
					best = k
				break
	return best


func _initialize() -> void:
	var f := FileAccess.open("res://data/body_regions_MO.json", FileAccess.READ)
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	_region = d["mesh_to_region"]
	_part_idx = d["mesh_to_part_index"]
	_draw_idx = d["mesh_to_drawable_index"]

	# 部件 id -> index（来自 parts json）
	var pf := FileAccess.open("res://data/parts_MO.json", FileAccess.READ)
	var pd: Dictionary = JSON.parse_string(pf.get_as_text())
	pf.close()
	for p in pd["parts"]:
		_part_id_of_index[p["index"]] = p["id"]

	var m = ClassDB.instantiate("GDCubismUserModel")
	root.add_child(m)
	m.set_assets(MODEL)
	m.advance(0.1)
	m.advance(0.1)
	_meshes = m.get_meshes()
	var o = m.get_part_opacities()
	if typeof(o) == TYPE_ARRAY:
		var arr: Array = o
		for e in arr:
			var pid: String = e.get_id()
			_opac_by_id[pid] = float(e.get_value())
	print("[i] 部件不透明度读取 %d 个，样例：" % _opac_by_id.size())
	var shown: int = 0
	for pid in _opac_by_id:
		if (_opac_by_id[pid] as float) > 0.001:
			shown += 1
	print("[i] 当前可见部件 %d / %d（其余是换装未启用的）" % [shown, _opac_by_id.size()])

	var t0 := Time.get_ticks_usec()
	warmup()
	var t1 := Time.get_ticks_usec()
	print("[i] meshes=%d  缓存=%d  跳过退化=%d  跳过隐藏部件=%d  预热 %.1f ms"
		% [_meshes.size(), _cache.size(), _skipped_degenerate, _skipped_hidden, (t1 - t0) / 1000.0])

	# 每个大部件取一个自己的网格，用它的重心当探针
	var probe: Dictionary = {}
	for k in _cache:
		var r: String = _region.get(k, "")
		if r != "" and not probe.has(r):
			probe[r] = k
	print("\n%-10s %-14s %-14s %-10s %s" % ["目标区", "探针网格", "命中网格", "命中区", "判定"])
	var ok_n: int = 0
	var t2 := Time.get_ticks_usec()
	for r in probe:
		var k: String = probe[r]
		var e: Dictionary = _cache[k]
		var verts: PackedVector2Array = e["v"]
		var c := Vector2.ZERO
		for v in verts:
			c += v
		c /= float(verts.size())
		var hit: String = pick(c)
		var got: String = _region.get(hit, "(未知)")
		var ok: bool = (got == r)
		if ok:
			ok_n += 1
		print("%-10s %-14s %-14s %-10s %s" % [r, k, hit, got, "OK" if ok else "被上层覆盖"])
	var t3 := Time.get_ticks_usec()
	print("\n[结果] %d/%d 探针命中自身区域（其余是被别的部位正常遮挡）" % [ok_n, probe.size()])
	print("[perf] %d 次拾取共 %.2f ms -> 单次约 %.3f ms" % [probe.size(), (t3 - t2) / 1000.0, (t3 - t2) / 1000.0 / float(maxi(1, probe.size()))])
	quit()
