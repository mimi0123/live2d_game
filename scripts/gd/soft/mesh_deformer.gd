## Live2D ArtMesh 触摸形变器（SoftTouch 模块 · STEP 3）
##
## 数据流：
##   接触数组 → 逐顶点遍历 contacts（各自算影响场）→ 合并位移 → 统一 cross_limit
##            → 逐顶点弹簧/阻尼 → 写回 ArtMesh 顶点
##
## ─────────────────────────────────────────────────────────────
## STEP 3 改了什么（其它一律没动：_base / _wrote / 动画跟随 / profile / cross_limit）
## ─────────────────────────────────────────────────────────────
## ① 从「一个圆」升级到「一只手」：本脚本不再自己算影响场，而是把每帧的
##    Array[HandContact] 交给 ContactBlend.merge()。合并规则（求和 → 统一夹紧）
##    写在 contact_blend.gd，那里可以被 headless 测试直接钉死。
##    · 单触点回退路径（hand_rig 缺席）走同一套 merge，一颗接触的算式与 STEP 2 逐项相同，
##      所以冻结的 39.03px 手感不会漂移。
## ② 多触点剔除：AABB 早退与状态回收从「离一个圆心远不远」改为
##    「离任意一颗接触的圆远不远」。
## ③ 修正一个隐性 bug：旧版无论 touch.active 与否都传 touching=true，
##    于是松手后仍按 pressure=0 的 0.55 深度下限一直凹着（松手不回弹）。
##    现在 touching 只在「真有接触受力」时为真，对应测试项 J（全 inactive → 归零）。
##
## ─────────────────────────────────────────────────────────────
## STEP 2 修掉的两个根本问题（都有实测数据支撑，此处保留不动）
## ─────────────────────────────────────────────────────────────
## ① 自反馈失控（这是「凹陷只有 1/4」的真正原因，跟参数无关）
##    实测发现：插件并不会每帧重算 ArtMesh 顶点。我们写回去的顶点，
##    就是下一帧 surface_get_arrays() 读到的「基准」。于是同一个顶点被
##    逐帧往触点方向拖，越过触点后方向翻转、来回弹 —— 对「原始静止位置」
##    的真实位移冲到 162px（depth 设的是 42），网格被拉烂；
##    而按「当前基准」量出来的位移只剩 ~11px，于是看起来「只有 1/4 深」。
##    → 现在自己维护一份原始静止基准 _base，并用 _wrote 判断插件是否重算过：
##        本帧读到的顶点 ≈ 上一帧我们写回的值  → 插件没重算，基准不变
##        否则（插件重算了，即角色在动）      → 以读到的顶点作为新基准
##      这样写回是幂等的、不再自反馈，同时角色动画照常跟随。
##
## ② 没有几何上限
##    原来顶点可以一路穿过触点。现在每个顶点的「朝内位移」最多
##    dist * cross_limit（默认 0.80），永不穿过触点，网格不会塌成一个点。
##
## 影响场改用 PressureField.soft_press_profile()（中心整片等强 + 平滑肩），
## 保证是连续的圆形衰减，而不是矩形，也不会看起来像吸进去的黑洞。

class_name SoftMeshDeformer
extends GDCubismEffectCustom

@export var enabled: bool = true
## 旧路径：单一触点。hand_rig 缺席时用它（行为与 STEP 2 完全一致）。
@export var touch: TouchManager = null
## STEP 3 路径：虚拟手（Palm + Fingers）。有它且 use_hand_rig=true 时优先。
@export var hand_rig: HandRig = null
@export var use_hand_rig: bool = true

@export_group("接触形变")
## 影响半径（模型画布像素）。工程模型高约 6852px，190 约占身高 2.8%（一根手指）。
## ⚠ STEP 3 起：这条只在「单触点回退路径」生效；走 HandRig 时半径由每颗接触自带
##   （palm_radius / finger_radius），以保证掌心与手指粗细不同、且都是模型空间量。
@export var radius: float = 190.0
## 触点中心的最大凹陷深度（像素）—— 心智模型：我要按出多深的一个坑。
@export var depth: float = 42.0
## 影响场「平顶」半径占 radius 的比例：这片区域内压力恒为满值。
## 0.34 × 190 = 64.6px，使「满压区」刚好覆盖 cross_limit 的饱和点（depth/cross_limit = 58.3px），
## 于是峰值能吃满 depth，而触点附近仍按 cross_limit 线性收，不会塌成一点。
@export_range(0.0, 0.6, 0.01) var flat_top: float = 0.34
## 平顶之外的肩部衰减指数：越小过渡越宽、越大越尖锐。
@export_range(0.5, 6.0, 0.1) var power: float = 1.8
## 几何上限：顶点朝触点方向最多走完「它到触点的距离」的多少（必须 < 1）。
## 0.80 → 触点附近的压缩比约 5 倍：既压得下去，又不会把网格挤成一个点。
@export_range(0.30, 0.98, 0.01) var cross_limit: float = 0.80
## 中心按压的同时给外围一个很轻的外鼓，模拟软组织体积被挤向周围。
@export_range(0.0, 0.5, 0.01) var volume_compensation: float = 0.13
## 鼠标移动时的横向拖拽量；越大越像手指在皮肤上带动表面。
@export_range(0.0, 1.0, 0.01) var drag_amount: float = 0.22

@export_group("弹簧物理")
## 目标位移跟随速度。太高会像硬塑料，太低会拖泥带水。
@export_range(1.0, 80.0, 1.0) var spring_strength: float = 34.0
@export_range(0.0, 1.0, 0.01) var spring_damping: float = 0.78
## 松手后的回弹强度。
@export_range(1.0, 80.0, 1.0) var recovery_strength: float = 22.0
@export_range(0.0, 1.0, 0.01) var recovery_damping: float = 0.82
@export var max_displacement: float = 85.0

@export_group("范围与性能")
@export var only_visible: bool = true
@export var deform_neighbor_meshes: bool = true
## 只处理触点附近的 ArtMesh，避免每帧重建所有空网格。
@export var mesh_search_margin: float = 1.25
## 判定「插件是否重算过这个顶点」的距离容差（像素）。略大于浮点误差即可。
@export var regen_epsilon: float = 0.5

var _meshes: Dictionary = {}
var _offsets: Dictionary = {}       # mesh key -> PackedVector2Array  当前形变位移
var _velocities: Dictionary = {}    # mesh key -> PackedVector2Array  弹簧速度
var _base: Dictionary = {}          # mesh key -> PackedVector2Array  原始静止顶点
var _wrote: Dictionary = {}         # mesh key -> PackedVector2Array  上一帧实际写回的位置
var _aabbs: Dictionary = {}         # mesh key -> Rect2
var _tri_cache: Dictionary = {}     # mesh key -> PackedInt32Array
var _draw_order: Dictionary = {}
var _geometry_ready: bool = false
## 诊断：状态数组被重建的次数（顶点数变化 / 插件重建网格时发生）
var _state_resets: int = 0
## 诊断：重置时「丢掉过非零形变」的次数与样本（>0 说明形变被吃掉）
var _state_lost: int = 0
var _state_lost_samples: Array = []
## 诊断：_ensure_state 被调用总次数
var _ensure_calls: int = 0
var _last_pick_pos: Vector2 = Vector2.INF
var _last_pick_result: bool = false
## STEP 3 诊断：本帧实际参与合并的接触数 / 接触数组（只读快照，给探针用）
var _last_contacts: Array = []
## STEP 3 诊断：本帧单顶点「合并后」目标位移峰值
var _last_target_peak: float = 0.0

const _EMPTY_CONTACTS: Array = []

func _ready() -> void:
	if not cubism_init.is_connected(_on_cubism_init):
		cubism_init.connect(_on_cubism_init)
	if not cubism_epilogue.is_connected(_on_cubism_epilogue):
		cubism_epilogue.connect(_on_cubism_epilogue)

func _on_cubism_init(model) -> void:
	_meshes = model.get_meshes()
	_offsets.clear()
	_velocities.clear()
	_base.clear()
	_wrote.clear()
	_aabbs.clear()
	_tri_cache.clear()
	_draw_order.clear()
	_geometry_ready = false
	_last_pick_pos = Vector2.INF
	print("[SoftMeshDeformer] Live2D ArtMesh: %d meshes" % _meshes.size())

func _on_cubism_epilogue(_model, delta: float) -> void:
	if not enabled:
		_step(delta, false, _EMPTY_CONTACTS)
		return

	# Cubism 会重新生成当前动画后的网格（但没有变化时不会重算，
	# 所以我们自己用 _base + _wrote 把「原始基准」和「我们写回的值」分开记）。
	_refresh_geometry()

	var contacts: Array = _collect_contacts()
	_last_contacts = contacts
	# STEP 3：形变强度只在「真的有接触在受力」时才走 spring 分支。
	# 旧版这里恒传 true，导致松手（active=false）后仍按 pressure=0 的
	# 0.55 深度下限一直凹着 —— 松手不回弹的隐性 bug，顺手修正（对应测试项 J）。
	_step(delta, _any_contact_on(contacts), contacts)

## 收集本帧的接触数组。
##   ① HandRig 在场 → 它给出 Palm + Fingers（每颗自带模型空间半径与权重）
##   ② 否则退回单触点（半径 = max(本脚本 radius, touch.radius)），
##      数值路径与 STEP 2 逐项一致，保证冻结的手感不漂移。
func _collect_contacts() -> Array:
	if use_hand_rig and hand_rig != null and is_instance_valid(hand_rig) and hand_rig.enabled:
		var rigs: Array = hand_rig.contacts
		if not rigs.is_empty():
			return rigs
	if touch == null or not is_instance_valid(touch):
		return _EMPTY_CONTACTS
	var c := HandContact.from_touch(touch.position, maxf(radius, touch.radius),
		clampf(touch.pressure, 0.0, 1.0), touch.velocity, bool(touch.active))
	return [c]

## 是否至少有一颗接触正在受力（决定走 spring 还是 recovery）
func _any_contact_on(contacts: Array) -> bool:
	for c in contacts:
		if c != null and c.is_on():
			return true
	return false

## 所有接触的影响半径最大值（外圈剔除的保守范围）
func _max_contact_radius(contacts: Array) -> float:
	var best := 0.0
	for c in contacts:
		if c != null and c.is_on():
			best = maxf(best, c.radius)
	return best

## 某个 AABB 是否落在任意一颗接触的影响范围内
func _rect_near_contacts(rect: Rect2, contacts: Array, margin: float) -> bool:
	for c in contacts:
		if c == null or not c.is_on():
			continue
		if _rect_near(rect, c.position, c.radius * margin):
			return true
	return false

## 统一的每帧步进（按压 / 松手回弹都走这里，保证两条路径完全一致）
##
## STEP 3 与 STEP 2 的唯一结构差异：
##   单触点 `target = f(一个中心)`  →  `target = ContactBlend.merge(contacts)`
## contacts 只有一颗时，ContactBlend 的算式与 STEP 2 逐项相同（含拖动限幅与
## cross_limit 的施加顺序），所以单触点手感不会有任何漂移。
func _step(delta: float, touching: bool, contacts: Array) -> void:
	if _meshes.is_empty():
		return
	var search_radius: float = _max_contact_radius(contacts)
	_last_target_peak = 0.0

	for key in _meshes:
		var mi = _meshes[key]
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		if only_visible and not mi.visible:
			continue

		var arr: Array = mi.mesh.surface_get_arrays(0)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var live: PackedVector2Array = arr[Mesh.ARRAY_VERTEX]
		if live.is_empty():
			continue

		# 远处网格：既没有形变残留就不必处理（STEP 3：对任意一颗接触都远才算远）
		if _aabbs.has(key):
			if not _rect_near_contacts(_aabbs[key] as Rect2, contacts, mesh_search_margin):
				if not _has_nonzero_offset(key):
					continue

		_ensure_state(key, live.size())
		var offsets: PackedVector2Array = _offsets[key]
		var velocities: PackedVector2Array = _velocities[key]
		var bases: PackedVector2Array = _base[key]
		var wrote: PackedVector2Array = _wrote[key]
		var moved := PackedVector2Array()
		moved.resize(live.size())

		var touched_any: bool = false
		var eps2: float = regen_epsilon * regen_epsilon

		for i in live.size():
			var lb: Vector2 = live[i]

			# ── 基准跟踪：插件这一帧有没有重算这个顶点？──
			#   wrote 是「上一帧我们写回去的位置」。若读到的顶点仍等于它，
			#   说明插件没有重算（我们的形变还在），基准保持原样；
			#   否则说明插件重算过（角色在动 / 网格重建），以读到的顶点作为新基准。
			var w: Vector2 = wrote[i]
			if w == Vector2.INF or lb.distance_squared_to(w) > eps2:
				bases[i] = lb
			var bp: Vector2 = bases[i]

			# ── 多触点合并：Palm + 各 Finger 全部算完再统一夹 cross_limit ──
			#    （单触点回退时，merge 内部算式与 STEP 2 逐项相同）
			var target: Vector2 = Vector2.ZERO
			if touching:
				target = ContactBlend.merge(bp, contacts, depth, flat_top, power,
					volume_compensation, drag_amount, cross_limit, 0.0)
				var tlen: float = target.length()
				if tlen > _last_target_peak:
					_last_target_peak = tlen

			var v: Vector2 = velocities[i]
			var cur: Vector2 = offsets[i]
			var strength: float = spring_strength if touching else recovery_strength
			var damp: float = spring_damping if touching else recovery_damping
			# 半隐式弹簧：比单纯 lerp 更接近「肉」的响应
			v += (target - cur) * strength * delta
			v *= pow(clampf(damp, 0.0, 0.9999), delta * 60.0)
			cur += v * delta

			if cur.length() > max_displacement:
				cur = cur.normalized() * max_displacement
				v *= 0.25

			offsets[i] = cur
			velocities[i] = v
			moved[i] = bp + cur

			if cur.length_squared() > 0.0001:
				touched_any = true

		if touched_any:
			_offsets[key] = offsets
			_velocities[key] = velocities
			_base[key] = bases
			_wrote[key] = moved
			_write_vertices(mi.mesh, moved)

	_cleanup_resting_states(touching, contacts, search_radius)

## 收集每个 ArtMesh 的 AABB / 绘制顺序 / 三角形索引。
##
## ⚠ 这里有一个 STEP 2 就存在的隐藏坑：如果第一帧 epilogue 早于插件生成 ArtMesh，
##   扫描会一个网格都拿不到，却仍把 _geometry_ready 设成 true —— 于是 _aabbs
##   永远是空的，AABB 早退彻底失效：每帧都要处理全部 1162 个网格
##   （实测 90 帧 22.8 秒，_state_resets 冲到 12 万次）。
##   现在改成「没扫到东西就不置位」，下一帧会自然重试。
func _refresh_geometry() -> void:
	if _geometry_ready and not _aabbs.is_empty():
		return
	for key in _meshes:
		var mi = _meshes[key]
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
		if not (is_finite(mn.x) and is_finite(mn.y) and is_finite(mx.x) and is_finite(mx.y)):
			continue
		# ⚠ 退化网格（所有顶点挤在同一点）也照样缓存：它的 AABB 就是一个点，
		#   _rect_near 的「最近点」判距依然成立，于是远离手时同样能被早退跳过。
		#   早先这里 continue 掉了 ~899 个退化网格，导致它们每帧都走全套流程，
		#   _state_resets 白白涨到 12 万次（功能没错，纯浪费）。
		_aabbs[key] = Rect2(mn, mx - mn)
		_draw_order[key] = mi.get_index()
		if arr[Mesh.ARRAY_INDEX] != null:
			_tri_cache[key] = (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).duplicate()
	if _aabbs.is_empty():
		return          # 插件还没生成 ArtMesh → 保持未就绪，下一帧重试
	_geometry_ready = true

func _ensure_state(key: String, count: int) -> void:
	_ensure_calls += 1
	if _offsets.has(key) and (_offsets[key] as PackedVector2Array).size() == count:
		return
	var old_size: int = -1
	var lost: float = 0.0
	if _offsets.has(key):
		var prev: PackedVector2Array = _offsets[key]
		old_size = prev.size()
		for x in prev:
			lost = maxf(lost, x.length())
	_state_resets += 1
	if lost > 0.5:
		_state_lost += 1
		if _state_lost_samples.size() < 6:
			_state_lost_samples.append("%s old=%d new=%d lost=%.2f" % [key, old_size, count, lost])

	var o := PackedVector2Array()
	var v := PackedVector2Array()
	var b := PackedVector2Array()
	var wr := PackedVector2Array()
	o.resize(count)
	v.resize(count)
	b.resize(count)
	wr.resize(count)
	for i in count:
		o[i] = Vector2.ZERO
		v[i] = Vector2.ZERO
		b[i] = Vector2.INF      # INF = 尚未建立基准 → 首帧以读到的顶点为基准
		wr[i] = Vector2.INF
	_offsets[key] = o
	_velocities[key] = v
	_base[key] = b
	_wrote[key] = wr

## 清掉已经静止的状态，避免 Dictionary 无限增长。
## 注意：触点在附近时不要清 —— 否则那些「本帧恰好压力为 0」的网格会被反复
## 建了又删（实测一帧能有 200+ 次无意义重建）。只有离开影响范围才回收。
## STEP 3：判定条件从「一个圆心」变成「任意一颗接触的圆」。
func _cleanup_resting_states(touching: bool, contacts: Array, search_radius: float) -> void:
	if _offsets.is_empty():
		return
	var remove_keys: Array[String] = []
	for key in _offsets:
		var offsets: PackedVector2Array = _offsets[key]
		var moving: bool = false
		for o in offsets:
			if o.length_squared() > 0.01:
				moving = true
				break
		if moving:
			continue
		if touching and search_radius > 0.0 and _aabbs.has(key):
			if _rect_near_contacts(_aabbs[key] as Rect2, contacts, mesh_search_margin):
				continue        # 还在影响范围内，留着复用
		remove_keys.append(key)
	for key in remove_keys:
		_offsets.erase(key)
		_velocities.erase(key)
		_base.erase(key)
		_wrote.erase(key)

func _write_vertices(am: ArrayMesh, verts: PackedVector2Array) -> void:
	if am == null or am.get_surface_count() <= 0:
		return
	var arr: Array = am.surface_get_arrays(0)
	if arr.is_empty():
		return
	arr[Mesh.ARRAY_VERTEX] = verts
	var fmt: int = am.surface_get_format(0)
	am.clear_surfaces()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, fmt)

func _rect_near(rect: Rect2, center: Vector2, r: float) -> bool:
	var closest := Vector2(
		clampf(center.x, rect.position.x, rect.end.x),
		clampf(center.y, rect.position.y, rect.end.y)
	)
	return closest.distance_squared_to(center) <= r * r

func _has_nonzero_offset(key: String) -> bool:
	if not _offsets.has(key):
		return false
	for o in (_offsets[key] as PackedVector2Array):
		if o.length_squared() > 0.01:
			return true
	return false

## 精确三角形拾取：TouchManager 用它判断鼠标是否真的碰到 Live2D。
func is_point_on_model(pt: Vector2) -> bool:
	if _meshes.is_empty():
		return false

	# 鼠标不动时不重复做整模型三角形测试。
	if pt.distance_squared_to(_last_pick_pos) < 1.0:
		return _last_pick_result
	_last_pick_pos = pt

	var best_order: int = -1
	var hit: bool = false
	for key in _meshes:
		var mi = _meshes[key]
		if not is_instance_valid(mi) or mi.mesh == null or not (mi.mesh is ArrayMesh):
			continue
		if only_visible and not mi.visible:
			continue
		var arr: Array = mi.mesh.surface_get_arrays(0)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null or arr[Mesh.ARRAY_INDEX] == null:
			continue
		var verts: PackedVector2Array = arr[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		if not _point_in_aabb(pt, verts):
			continue
		var idxs: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var tri_count: int = idxs.size() / 3
		for t in tri_count:
			var ia: int = idxs[t * 3]
			var ib: int = idxs[t * 3 + 1]
			var ic: int = idxs[t * 3 + 2]
			if ia < 0 or ib < 0 or ic < 0 or ia >= verts.size() or ib >= verts.size() or ic >= verts.size():
				continue
			if _point_in_triangle(pt, verts[ia], verts[ib], verts[ic]):
				var order: int = mi.get_index()
				if order >= best_order:
					best_order = order
					hit = true
				break
	_last_pick_result = hit
	return hit

func _point_in_aabb(pt: Vector2, verts: PackedVector2Array) -> bool:
	var mn: Vector2 = verts[0]
	var mx: Vector2 = verts[0]
	for v in verts:
		mn.x = minf(mn.x, v.x)
		mn.y = minf(mn.y, v.y)
		mx.x = maxf(mx.x, v.x)
		mx.y = maxf(mx.y, v.y)
	return pt.x >= mn.x and pt.x <= mx.x and pt.y >= mn.y and pt.y <= mx.y

func _point_in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1: float = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
	var d2: float = (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)
	var d3: float = (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)
	var neg: bool = d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var pos: bool = d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (neg and pos)
