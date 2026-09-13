## ContactBlend —— 多个接触点如何合并成一个顶点位移（SoftTouch 模块 · STEP 3）
##
## 这是 STEP 3 唯一新增的「数学」，纯静态、不依赖 Live2D / Node / 场景。
## 之所以把它单独拿出来而不是塞进 mesh_deformer.gd：
##   1) 合并规则是「危险区」（很容易写出多触点叠加爆炸），必须能被独立测试钉死；
##   2) 测试 tools/hand_contact_test.gd 可以在 headless 下直接调它，
##      不需要真的跑 Live2D 就能验证「4 个触点不会叠成 70px」。
##
## ─────────────────────────────────────────────────────────────
## 合并顺序（严格按 STEP 3 指定的流程，不是每个触点先截断再相加）
## ─────────────────────────────────────────────────────────────
##   raw_sum    ：把每个接触的「凹陷 + 体积补偿」矢量相加
##   drag       ：各接触的拖动量单独累加，最后按最深接触统一限幅
##   cross_limit：**合并之后**才做 —— 逐接触检查「朝内分量」是否超过 dist×cross_limit，
##                超过就沿该接触法线补回去；多轮迭代 + 兜底缩放，
##                保证「顶点永不穿过任何触点」是硬保证而不是运气
##   max_disp   ：最后再做一次全局模长上限
##
## 为什么不能「每个接触先各自截断再相加」：
##   每个接触都截断到 dist*0.8，四个触点相加最坏是 3.2×dist，局部直接塌成一点。
##
## 为什么不能只做「合并后截断到 dist×cross」：
##   多触点法线方向不同，只截一个方向另一个方向仍然可能穿点。
##   所以按接触逐个投影检查（少量迭代即可收敛，因为投影是压缩映射）。

class_name ContactBlend
extends RefCounted

## 与 STEP 2 一致的深度上升下限：depth * lerp(RAMP_FLOOR, 1.0, pressure)
const RAMP_FLOOR := 0.55
## 速度 → 拖动位移的换算系数（与 STEP 2 单触点版本保持一致）
const DRAG_SCALE := 0.045
## 拖动位移上限 = 本顶点最深接触 depth 的多少倍
const DRAG_LIMIT_RATIO := 0.45
## cross_limit 迭代轮数（投影压缩，2~3 轮足够；多留一轮做保险）
const CLAMP_PASSES := 4
## 最多参与合并的接触数（防御性上限，防止以后参数写错炸性能）
const MAX_CONTACTS := 8


## 合并主入口。
##
## base       顶点的**原始静止位置**（不是当前写回位置 —— 必须用 _base）
## contacts   Array[HandContact]（允许含未激活的，内部会跳过）
## depth      触点中心的最大凹陷深度（像素，来自 SoftMeshDeformer.depth）
## flat_top   平顶比例（来自 SoftMeshDeformer.flat_top）
## power      肩部衰减指数（来自 SoftMeshDeformer.power）
## volume_compensation 外围体积补偿强度
## drag_amount 速度→拖动量的手调系数（来自 SoftMeshDeformer.drag_amount）
## cross_limit 几何上限（朝内位移 ≤ dist × cross_limit）
## max_displacement 全局位移模长上限（传 0 = 不在这一步夹，交给弹簧之后的全局夹）
##
## 返回：这个顶点最终应该产生的位移（模型空间）。
##   · 没有任何接触影响 → 严格返回 Vector2.ZERO
##   · 任何一步出 NaN  → 严格返回 Vector2.ZERO（宁可不形变，也不许污染网格）
static func merge(base: Vector2, contacts: Array, depth: float, flat_top: float, power: float,
		volume_compensation: float, drag_amount: float, cross_limit: float,
		max_displacement: float) -> Vector2:
	if contacts == null or contacts.is_empty():
		return Vector2.ZERO

	# ── 预算一遍几何：位置 / 法线 / 距离 / 半径 / 深度 / profile / 速度 ──
	var n: int = mini(contacts.size(), MAX_CONTACTS)
	var nrm := PackedVector2Array()        # 顶点指向外的单位法线
	var dst := PackedFloat32Array()        # 顶点到接触中心的距离
	var rad := PackedFloat32Array()        # 该接触半径
	var dep := PackedFloat32Array()        # 该接触的实际 depth（含权重与压力曲线）
	var prf := PackedFloat32Array()        # 该接触在该顶点的 profile 值
	var vel := PackedVector2Array()        # 该接触的速度
	for j in n:
		var c = contacts[j]
		if c == null or not c.is_on():
			continue
		var off: Vector2 = base - c.position
		var dist: float = off.length()
		if not is_finite(dist):
			continue
		if dist >= c.radius or dist <= 0.001:
			continue
		var prof: float = PressureField.soft_press_profile(dist, c.radius, flat_top, power)
		if prof <= 0.0001:
			continue
		nrm.append(off / dist)
		dst.append(dist)
		rad.append(c.radius)
		dep.append(depth * _depth_factor(c))
		prf.append(prof)
		vel.append(c.velocity)

	if dst.is_empty():
		return Vector2.ZERO

	# ── ① 求和：凹陷 + 体积补偿 + 速度拖动 ──
	var raw := Vector2.ZERO
	var drag := Vector2.ZERO
	var deepest := 0.0
	var count: int = dst.size()
	for k in count:
		var d: float = dep[k]
		deepest = maxf(deepest, d)
		# 中心凹陷
		raw -= nrm[k] * d * prf[k]
		# 外围轻微外鼓（软组织体积被挤向周围）
		if volume_compensation > 0.0:
			var ring_t: float = (dst[k] - rad[k] * 0.48) / (rad[k] * 0.42)
			var ring: float = exp(-ring_t * ring_t * 2.2)
			raw += nrm[k] * d * volume_compensation * ring * prf[k]
		# 拖动携带（速度矢量，多接触各自累加，最后统一限幅）
		if drag_amount > 0.0 and vel[k].length_squared() > 0.01:
			drag += vel[k] * drag_amount * DRAG_SCALE * prf[k]

	# ── ② 拖动限幅后并入 ──
	var drag_limit: float = deepest * DRAG_LIMIT_RATIO
	if drag_limit <= 0.0:
		drag = Vector2.ZERO
	elif drag.length() > drag_limit:
		drag = drag.normalized() * drag_limit
	raw += drag

	# ── ③ cross_limit：合并之后统一夹（硬保证「不穿过任何触点」）──
	if cross_limit > 0.0:
		for _pass in CLAMP_PASSES:
			var worst: float = 0.0
			for k in count:
				var inward: float = -raw.dot(nrm[k])
				var cap: float = dst[k] * cross_limit
				if inward > cap:
					var over: float = inward - cap
					raw += nrm[k] * over
					worst = maxf(worst, over)
			if worst <= 0.0001:
				break
		# 兜底：多触点互拽时极少数情况仍可能越界，整体等比缩回去
		var ratio: float = 0.0
		for k in count:
			var cap2: float = dst[k] * cross_limit
			if cap2 > 0.0001:
				ratio = maxf(ratio, -raw.dot(nrm[k]) / cap2)
		if ratio > 1.0:
			raw /= ratio

	# ── ④ 全局模长上限 ──
	if max_displacement > 0.0 and raw.length() > max_displacement:
		raw = raw.normalized() * max_displacement

	# ── ⑤ NaN 闸门 ──
	if not (is_finite(raw.x) and is_finite(raw.y)):
		return Vector2.ZERO
	return raw


## 诊断用：该顶点被哪些接触影响、各自贡献多少、上限多少。
## 只读、不参与顶点计算，供探针 / 测试打印。
static func explain(base: Vector2, contacts: Array, depth: float, flat_top: float, power: float,
		cross_limit: float) -> Array:
	var out: Array = []
	if contacts == null:
		return out
	for j in mini(contacts.size(), MAX_CONTACTS):
		var c = contacts[j]
		if c == null:
			continue
		var off: Vector2 = base - c.position
		var dist: float = off.length()
		var prof: float = 0.0
		if dist > 0.001 and dist < c.radius:
			prof = PressureField.soft_press_profile(dist, c.radius, flat_top, power)
		var d: float = depth * _depth_factor(c)
		out.append({
			"type": HandContact.TYPE_NAMES.get(c.type, "?"),
			"on": c.is_on(),
			"dist": dist,
			"radius": c.radius,
			"profile": prof,
			"depth": d,
			"inward_raw": d * prof,
			"cap": dist * cross_limit,
		})
	return out


## 单个接触在某个顶点上的「原始凹陷量」（未合并、未夹紧）。
## 测试 F 用它得到「单 Palm = 多少 / 单 Finger = 多少」的对照值。
static func single_inward(base: Vector2, c, depth: float, flat_top: float, power: float) -> float:
	if c == null or not c.is_on():
		return 0.0
	var dist: float = base.distance_to(c.position)
	if dist <= 0.001 or dist >= c.radius:
		return 0.0
	return depth * _depth_factor(c) * PressureField.soft_press_profile(dist, c.radius, flat_top, power)


## 与 HandContact.depth_factor() 同一条公式（此处复制一份：merge 是热路径，
## 每个顶点都会走，避免再绕一层方法调用；两处必须保持一致）
static func _depth_factor(c) -> float:
	return clampf(c.weight, 0.0, 10.0) * lerpf(RAMP_FLOOR, 1.0, clampf(c.pressure, 0.0, 1.0))
