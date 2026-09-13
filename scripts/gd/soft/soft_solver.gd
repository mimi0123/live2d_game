## 软体求解器（SoftTouch 模块 · STEP 3 核心）
##
## 一帧的固定顺序（顺序错了会抖 / 会炸）：
##   ① _integrate()         Verlet 惯性推进（含阻尼、重力）
##   ② apply_pressure()     触点压力场：径向压入 + 拖动携带
##      或 apply_recovery() 松手后用弹力拉回静止位置
##   ③ solve_constraints()  迭代 N 次距离约束 —— 这一步才是「周边传播」的来源
##   ④ _clamp_displacement() 单帧位移限幅，防数值爆炸
##
## 关键：③ 不是装饰。没有它，按哪只有哪动（像抹布上的一个洞）；
## 有了它，A—B—C 连成的网会把力传出去，才是「软组织」。
##
## 本文件只做数学，不含渲染、不含 Live2D。

class_name SoftSolver
extends RefCounted

## 默认迭代次数：越高越「硬/越不可拉长」，8 次是 2D 网格的常用值
const DEFAULT_ITERATIONS := 8

## 约束里存 {"a": 索引, "b": 索引, "rest": 静止长度}
var particles: Array[SoftParticle] = []
var constraints: Array = []

# ---------- 全局物理参数 ----------
## 速度阻尼（每帧乘一次）。0.96 ≈ 明显有黏性，1.0 = 无摩擦会一直晃
var damping: float = 0.96
## 重力（2D 向量）。桌面软体一般留 ZERO，交给回弹力收场
var gravity: Vector2 = Vector2.ZERO
## 约束迭代次数
var iterations: int = DEFAULT_ITERATIONS
## 约束刚度 0~1：1 = 完全不可拉伸（硬），0.5 = 有弹性
var stiffness: float = 1.0

## ★ 允许压缩（单向约束 / 像布与皮肤）
##
## 这是整套物理能否「凹下去」的关键开关。原因：
##   径向向内压 = 把影响圈往中心挤。若约束是双向的（既抗拉又抗压），
##   圆周方向的弹簧会被压到崩溃，约束必然奋力反抗 ——
##   实测无论怎么调刚度/迭代，凹陷都只有 0.1px（等于压不动）。
##   真实皮肤与布料是「抗拉不抗压」的：拉长会弹回，压短不反抗（会起褶）。
##   所以这里默认 true：只做 max 距离约束（dist > rest 才拉回），允许局部压缩。
##   形状的回弹交给 recovery 弹力与松手后的约束，不靠抗压。
var allow_compression: bool = true

## 核心半径：质点最多被压到离触点这么近，防止压成一个点（塌缩奇点）
var core_radius: float = 8.0

## ★ 锚定半径倍数（常驻回弹的"掩膜"范围）
##
## 这是让形变「局部化」的关键。理由：
##   一个自由漂浮的网格被往里压时，单向约束会把邻点一个个拽进来，
##   一路传到边界 —— 整块一起动（实测远端也动 8px = 整体收缩）。
##   真实皮肤是长在身体上的：离触点远的地方几乎不动。
##   所以回弹力改成「常驻 + 按离触点远近加权」：
##     圈内(k≈0)  → 压力说了算，自由凹陷
##     圈外(k=全额) → 牢牢锚在静止位置，谁也别想拖走它
##     中间过渡带  → 两边都受力 = 自然的"周边被带动"
##   松手后 infl=0，全场全额回弹 → 自动复原
var anchor_scale: float = 1.6
## 回弹强度（松手后朝静止位置拉的速度系数）
var recovery: float = 4.0
## 单帧位移上限（像素）。防止强参数下数值发散
var max_step: float = 60.0
## 压力场是否启用（关掉就纯弹性网格，可对比手感）
var pressure_enabled: bool = true

# ---------- 触点状态（由 SoftMesh / TouchManager 每帧喂进来）----------
var touch_position: Vector2 = Vector2.ZERO
var touch_active: bool = false
var touch_radius: float = 100.0
## 衰减指数，见 PressureField.falloff 说明
var touch_power: float = 4.0
## 拖动方向的「携带力」：抚摸时把网格顺着鼠标带过去
var drag_velocity: Vector2 = Vector2.ZERO
var drag_strength: float = 0.0
## 向外推（true）还是向内压（false）。右键可用它做「揉开」
var push_outward: bool = false

# ---------- 压力模式 ----------
## "target" = 位置式（推荐）：直接把受影响质点朝「凹陷目标位置」拉。
##            凹陷深度 = depth 像素，与约束刚度无关，好调、稳定。
## "force"  = 速度式：每帧注入速度。更「流体」，但实测在刚性约束网里
##            99% 会被约束抵消（累计推 31px 只凹 1.3px），不推荐。
var pressure_mode: String = "target"
## target 模式下：触点中心的目标凹陷深度（画布像素）
var depth: float = 42.0
## target 模式下：每秒的跟随速率（越大越"瞬间凹进去"，越小越"慢慢压下去"）
var follow_rate: float = 9.0
## force 模式下的每帧推力（仅 pressure_mode == "force" 时有效）
var touch_strength: float = 80.0


## 绑定数据（每次都传引用，不复制数组——求解器必须直接改质点）
func setup(particle_list: Array[SoftParticle], constraint_list: Array) -> void:
	particles = particle_list
	constraints = constraint_list


## 一帧求解
func step(delta: float) -> void:
	if particles.is_empty():
		return
	_integrate(delta)
	if touch_active and pressure_enabled:
		apply_pressure(delta)
	# 回弹是「常驻」的：按住时按影响场加权（圈外锚定、圈内自由），
	# 松手后全额生效 → 自动复原。
	apply_recovery(delta)
	for _i in range(maxi(1, iterations)):
		solve_constraints()
	_clamp_displacement()


# =====================================================================
#  ① Verlet 惯性
# =====================================================================
func _integrate(delta: float) -> void:
	var dt2: float = delta * delta
	for p in particles:
		if p.pinned:
			p.previous_position = p.position
			continue
		var vel: Vector2 = p.position - p.previous_position
		p.previous_position = p.position
		p.position += vel * damping + gravity * dt2


# =====================================================================
#  ② 压力场（按住时）
# =====================================================================
## 两种模式，默认位置式。
##
## 【位置式 target】为什么要配 PBD 技巧：
##   直接改 position 会让 Verlet 把「这一跳」当成速度，下一帧继续往前冲、来回震荡。
##   所以移动多少，previous_position 也同步移动多少 —— 等于「这一帧不产生速度」，
##   按下过程干净利落没有抖动；回弹完全交给松手后的弹簧与 recovery。
func apply_pressure(delta: float) -> void:
	var r: float = maxf(touch_radius, 0.0001)
	var follow: float = clampf(1.0 - exp(-follow_rate * delta), 0.0, 1.0)
	var sign_depth: float = depth if push_outward else -depth

	for p in particles:
		if p.pinned:
			continue
		var offset: Vector2 = p.position - touch_position
		var d: float = offset.length()
		if d >= r:
			continue

		var influence: float = PressureField.falloff(d, r, touch_power)
		if influence <= 0.0:
			continue

		if pressure_mode == "target":
			var dir := Vector2.ZERO
			if d > 0.001:
				dir = offset / d
			# 目标半径：向内收 depth*衰减，但不小于 core_radius（防塌缩成一点）
			var target_radius: float = maxf(d + sign_depth * influence, core_radius)
			var target: Vector2 = touch_position + dir * target_radius
			var move: Vector2 = (target - p.position) * follow
			p.position += move
			p.previous_position += move     # PBD：不注入虚假速度
		else:
			if d < 0.001:
				continue
			var dir2: Vector2 = offset / d
			var sign_dir: float = 1.0 if push_outward else -1.0
			p.position += dir2 * (sign_dir * touch_strength * influence * delta)

		# 拖动携带：抚摸时顺鼠标方向带一小段（这一项是速度式的，故意保留惯性）
		if drag_strength > 0.0 and drag_velocity != Vector2.ZERO:
			p.position += drag_velocity * drag_strength * influence * delta

		var off: float = p.offset_from_original().length()
		if off > p.max_offset_seen:
			p.max_offset_seen = off


# =====================================================================
#  ②' 常驻锚定 / 回弹
# =====================================================================
## 朝静止位置拉回，强度按「离触点多远」加权（见 anchor_scale 说明）。
## 系数乘 delta 后夹到 1，避免低帧率 / 大 delta 时一步拉过头来回振荡。
func apply_recovery(delta: float) -> void:
	var base: float = clampf(recovery * delta, 0.0, 1.0)
	if base <= 0.0:
		return
	var touching: bool = touch_active and pressure_enabled

	for p in particles:
		if p.pinned:
			continue
		var off: Vector2 = p.original_position - p.position
		if off.length_squared() < 0.000001:
			continue

		var k: float = base
		if touching:
			var d: float = p.original_position.distance_to(touch_position)
			k = base * _anchor_mask(d)
			if k <= 0.0:
				continue
		p.position += off * k


## 锚定掩膜：圈内(<=R)完全不锚，圈外(>=R*anchor_scale)全额锚定，中间 smoothstep 过渡。
##
## 为什么不用压力场那条 falloff 曲线：那条曲线在 d=0.3R 处已有 0.5 的强度，
## 会把「本该凹得最深」的中心区也锚住（实测凹陷只剩 0.2px）。
## 锚定要的是「圈外才管」，所以必须是 0 → 1 的硬边界 + 平滑过渡带。
func _anchor_mask(d: float) -> float:
	var r0: float = maxf(touch_radius, 0.0001)
	var r1: float = maxf(touch_radius * anchor_scale, r0 + 0.001)
	if d <= r0:
		return 0.0
	if d >= r1:
		return 1.0
	var t: float = (d - r0) / (r1 - r0)
	return t * t * (3.0 - 2.0 * t)


# =====================================================================
#  ③ 距离约束（周边传播）
# =====================================================================
func solve_constraints() -> void:
	var s: float = clampf(stiffness, 0.0, 1.0)
	if s <= 0.0:
		return
	for c in constraints:
		var ia: int = c["a"]
		var ib: int = c["b"]
		var rest: float = c["rest"]

		var a: SoftParticle = particles[ia]
		var b: SoftParticle = particles[ib]

		var wsum: float = a.inv_mass + b.inv_mass
		if wsum <= 0.0:
			continue   # 两端都钉死，这条约束无自由度

		var d: Vector2 = b.position - a.position
		var dist: float = d.length()
		if dist < 0.0001:
			continue   # 完全重合，方向无意义（避免除零炸出 NaN）

		# 单向（布/皮肤）：被压短时不反抗，只在被拉长时拉回
		if allow_compression and dist < rest:
			continue

		var diff: float = (dist - rest) / dist
		var correction: Vector2 = d * diff * s

		if not a.pinned:
			a.position += correction * (a.inv_mass / wsum)
		if not b.pinned:
			b.position -= correction * (b.inv_mass / wsum)


# =====================================================================
#  ④ 限幅（防炸）
# =====================================================================
func _clamp_displacement() -> void:
	if max_step <= 0.0:
		return
	var m2: float = max_step * max_step
	for p in particles:
		if p.pinned:
			continue
		var d: Vector2 = p.position - p.previous_position
		if d.length_squared() > m2:
			p.position = p.previous_position + d.normalized() * max_step


# =====================================================================
#  对外工具
# =====================================================================

## 全部质点复位到静止位置，并清速度
func reset() -> void:
	for p in particles:
		p.reset_to_original()


## 当前最大位移（调试 / 自检用）
func max_offset() -> float:
	var m: float = 0.0
	for p in particles:
		m = maxf(m, p.offset_from_original().length())
	return m


## 触点处质点的平均位移方向（可用于驱动 Live2D 参数，如身体歪斜）
func mean_offset_near(center: Vector2, radius: float) -> Vector2:
	var sum: Vector2 = Vector2.ZERO
	var n: int = 0
	for p in particles:
		if p.position.distance_to(center) < radius:
			sum += p.offset_from_original()
			n += 1
	return Vector2.ZERO if n == 0 else sum / float(n)
