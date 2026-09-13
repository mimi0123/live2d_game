## 软体网格节点（SoftTouch 模块 · 可视化 + 驱动）
##
## 职责：① 生成规则质点网格与结构约束；② 每帧把触点状态喂给 SoftSolver；
##       ③ 把「当前形状」与「原始形状」同时画出来，让变形肉眼可见。
##
## 画出原始形状（半透明虚线）很重要——否则网格整体跟着鼠标跑时，
## 你分不清到底是「局部凹陷」还是「整块平移」。
##
## 本节点不依赖 Live2D，可单独放进任何场景。

class_name SoftMesh
extends Node2D

# ---------- 网格形状 ----------
@export var columns: int = 20
@export var rows: int = 14
@export var mesh_size: Vector2 = Vector2(500.0, 350.0)
## 是否钉住外圈（true = 像绷在框上的布；false = 自由漂浮，推荐先用 false）
@export var pin_border: bool = false

# ---------- 物理参数 ----------
@export var damping: float = 0.96
@export var gravity: Vector2 = Vector2.ZERO
## 约束迭代次数。⚠ 不要用 8：约束每帧都解算，迭代越多 = 材料越硬，
## 实测 stiffness>=0.2 或 iter>=4 时力道被吃掉 90% 以上（凹陷只剩 0.1px）。
@export_range(1, 24, 1) var constraint_iterations: int = 2
## 约束刚度。⚠ 极软才是对的：0.02~0.05。见 SoftSolver 顶部说明。
@export_range(0.0, 1.0, 0.01) var stiffness: float = 0.03
## 允许压缩（单向约束 / 抗拉不抗压）—— 见 SoftSolver.allow_compression 说明，
## 这是「能不能凹下去」的关键开关，默认开。
@export var allow_compression: bool = true
@export var recovery_strength: float = 3.5
## 锚定半径倍数：圈外锚死、圈内自由（见 SoftSolver.anchor_scale）
@export var anchor_scale: float = 1.6

# ---------- 触点参数 ----------
## "target" 位置式（推荐）/ "force" 速度式
@export var pressure_mode: String = "target"
## 触点中心的**驱动深度**（像素）。
## 注意：实际凹深 ≈ depth × 平衡系数（约 0.4，与 follow_rate / stiffness 有关），
## 实测 depth=25 时凹陷约 9~10px。想更深就加大它。
@export var touch_depth: float = 30.0
## 每秒跟随速率。⚠ 太小凹陷会被约束吃掉（平衡位移 x ≈ D·follow/(follow+c)），
## 实测 40 以上凹陷才接近目标深度。给「慢慢压下去」的观感请靠 pressure 渐变，别压这个值。
@export var follow_rate: float = 40.0
## 仅 force 模式用
@export var touch_strength: float = 80.0
@export_range(1.0, 12.0, 0.25) var touch_power: float = 2.5
@export var drag_strength: float = 60.0

# ---------- 显示 ----------
@export var show_springs: bool = true
@export var show_particles: bool = true
@export var show_original_shape: bool = true
@export var show_touch_field: bool = true

# ---------- 颜色 ----------
@export var color_spring := Color(0.45, 0.85, 0.95, 0.55)
@export var color_particle := Color(0.85, 0.95, 1.0, 1.0)
@export var color_ghost := Color(0.55, 0.6, 0.75, 0.28)
@export var color_touch := Color(1.0, 0.42, 0.42, 0.9)

var particles: Array[SoftParticle] = []
var constraints: Array = []
var solver: SoftSolver = SoftSolver.new()

# 触点状态（由外部每帧 set_touch 注入）
var touch_position: Vector2 = Vector2.ZERO
var touch_active: bool = false
var touch_velocity: Vector2 = Vector2.ZERO
var touch_pressure: float = 0.0
var touch_radius: float = 90.0

var _ready_built: bool = false


func _ready() -> void:
	build()
	_ready_built = true


# =====================================================================
#  网格生成
# =====================================================================
func build() -> void:
	_build_particles()
	_build_constraints()
	_push_params()
	solver.setup(particles, constraints)


func _build_particles() -> void:
	particles = []
	var w: float = maxf(columns - 1, 1)
	var h: float = maxf(rows - 1, 1)
	for y in range(rows):
		for x in range(columns):
			var pos := Vector2(
				float(x) / w * mesh_size.x,
				float(y) / h * mesh_size.y
			)
			var pinned: bool = pin_border and (x == 0 or y == 0 or x == columns - 1 or y == rows - 1)
			particles.append(SoftParticle.new(pos, pinned))


func _build_constraints() -> void:
	constraints = []
	for y in range(rows):
		for x in range(columns):
			var index: int = y * columns + x
			if x < columns - 1:
				_add_constraint(index, index + 1)
			if y < rows - 1:
				_add_constraint(index, index + columns)
			# 斜向约束：网格更抗剪切（拉起来不像平行四边形）。先去重，避免重复解算
			if x < columns - 1 and y < rows - 1:
				_add_constraint(index, (y + 1) * columns + x + 1)


func _add_constraint(a: int, b: int) -> void:
	var pa: SoftParticle = particles[a]
	var pb: SoftParticle = particles[b]
	constraints.append({
		"a": a,
		"b": b,
		"rest": pa.position.distance_to(pb.position),
	})


func _push_params() -> void:
	solver.damping = damping
	solver.gravity = gravity
	solver.iterations = constraint_iterations
	solver.stiffness = stiffness
	solver.allow_compression = allow_compression
	solver.recovery = recovery_strength
	solver.anchor_scale = anchor_scale
	solver.pressure_mode = pressure_mode
	solver.follow_rate = follow_rate
	solver.touch_strength = touch_strength
	solver.touch_power = touch_power
	solver.drag_strength = drag_strength
	# 压力越大凹得越深（0.4 → 1.0 倍），按住会慢慢陷进去
	solver.depth = touch_depth * lerpf(0.4, 1.0, clampf(touch_pressure, 0.0, 1.0))


# =====================================================================
#  每帧
# =====================================================================
func _physics_process(delta: float) -> void:
	if not _ready_built:
		return
	push_to_solver()
	solver.step(delta)
	queue_redraw()


## 把「当前触点状态 + 当前参数」推给求解器。
##
## _physics_process 每帧调它；自检工具（tools\soft_selftest.gd）也调它 ——
## 这样"测试跑的路径"和"游戏跑的路径"是同一条，不会出现
## 「参数都对但就是不动」这种测试与运行不一致的坑（踩过一次）。
func push_to_solver() -> void:
	_push_params()
	solver.touch_active = touch_active
	solver.touch_position = touch_position
	solver.touch_radius = touch_radius
	solver.drag_velocity = touch_velocity


## 外部注入触点（TouchManager 调它）。pos 用本节点的局部坐标。
func set_touch(pos: Vector2, active: bool, velocity: Vector2 = Vector2.ZERO,
		pressure: float = 0.0, radius: float = 90.0) -> void:
	touch_position = pos
	touch_active = active
	touch_velocity = velocity
	touch_pressure = pressure
	touch_radius = radius


## 松手
func release() -> void:
	touch_active = false
	touch_velocity = Vector2.ZERO
	touch_pressure = 0.0


## 复位到原始形状
func reset() -> void:
	solver.setup(particles, constraints)
	solver.reset()
	queue_redraw()


## 重建网格（改密度后调）
func rebuild() -> void:
	build()
	queue_redraw()


## 调试：最大位移
func max_offset() -> float:
	return solver.max_offset()


# =====================================================================
#  绘制
# =====================================================================
func _draw() -> void:
	# 1) 原始形状（幽灵网格）——判断「局部变形 vs 整体平移」的参照物
	if show_original_shape:
		for c in constraints:
			var pa: SoftParticle = particles[c["a"]]
			var pb: SoftParticle = particles[c["b"]]
			draw_line(pa.original_position, pb.original_position, color_ghost, 1.0)

	# 2) 当前弹簧
	if show_springs:
		for c in constraints:
			var pa: SoftParticle = particles[c["a"]]
			var pb: SoftParticle = particles[c["b"]]
			# 被拉伸得越厉害，线越亮——一眼能看出力往哪传
			var stretch: float = clampf(
				absf(pa.position.distance_to(pb.position) - float(c["rest"])) / 12.0, 0.0, 1.0)
			var col: Color = color_spring.lerp(color_touch, stretch)
			draw_line(pa.position, pb.position, col, 1.5)

	# 3) 质点
	if show_particles:
		for p in particles:
			var off: float = clampf(p.offset_from_original().length() / 40.0, 0.0, 1.0)
			var col: Color = color_particle.lerp(color_touch, off)
			var r: float = 2.0 + off * 1.5
			draw_circle(p.position, r, col)

	# 4) 触点影响场
	if show_touch_field and touch_active:
		var alpha: float = 0.25 + 0.35 * touch_pressure
		draw_circle(touch_position, touch_radius, Color(color_touch.r, color_touch.g,
			color_touch.b, alpha * 0.25), false, 2.0)
		draw_circle(touch_position, 4.0, Color(1, 1, 1, 0.9))
