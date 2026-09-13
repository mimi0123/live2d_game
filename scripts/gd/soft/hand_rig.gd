## HandRig —— 一只「虚拟手」的摆放器（SoftTouch 模块 · STEP 3）
##
## 职责（只有这一件事）：
##   把 TouchManager 的单一触点，摊开成 Palm + 3 Fingers（可选 Thumb）的接触数组。
##   它【不】碰 Live2D，【不】碰顶点，【不】碰 MeshInstance2D。
##
## 第一版的手不是解剖学的手，而是「一眼能看出不是一个圆」的最小结构：
##
##              F1    F2    F3
##               ○     ○     ○        <- 指尖，排在掌心前方，带一点点弧度
##            ┌───────────────┐
##            │     PALM      │        <- 掌心，中心 = 鼠标/模型位置
##            └───────────────┘
##                    \
##                   THUMB             <- 预留，默认关闭
##
## 三条 STEP 3 硬约束都在这里落地：
##   ① 全部尺寸是**模型空间**（画布像素），与屏幕像素 / Camera2D.zoom 无关；
##   ② 手的方向跟随移动方向，但速度低于死区时**沿用上次方向**（不抖动）；
##   ③ 参数全部 @export，方便 Master 在 Inspector 里直接调。

class_name HandRig
extends Node

## 数据源：由它提供 position / pressure / velocity / active
@export var touch: TouchManager = null
@export var enabled: bool = true
## 是否每帧自动从 touch 重建 contacts（测试里会关掉，手动调用）
@export var auto_update: bool = true

@export_group("手掌 Palm")
## 掌心影响半径（模型空间）。STEP 3 起始区间 80~100。
@export_range(20.0, 300.0, 1.0) var palm_radius: float = 92.0
## 掌心沿手方向的额外前移量（一般 0：掌心就在鼠标处）
@export_range(-120.0, 120.0, 1.0) var palm_forward_offset: float = 0.0
## 掌心的出力权重（depth 倍率），1.0 = 满深
@export_range(0.0, 1.5, 0.01) var palm_weight: float = 1.0

@export_group("手指 Finger")
## 手指数量（STEP 3 用 3；最大 8，方便以后加）
@export_range(0, 8, 1) var finger_count: int = 3
## 单根手指的影响半径（模型空间）。STEP 3 起始区间 25~35。
@export_range(8.0, 120.0, 1.0) var finger_radius: float = 25.0
## 相邻手指间距（模型空间）。STEP 3 起始区间 25~40。
## ⚠ 必须 > finger_radius，否则相邻两根手指的压力场会互相抵消、
##   三根手指融成一坨（实测：34/30 时只测得出 1 个局部区域；40/25 时能分出 4 个）。
@export_range(0.0, 160.0, 1.0) var finger_spacing: float = 40.0
## 掌心中心到指根的距离（模型空间）
@export_range(0.0, 300.0, 1.0) var finger_distance: float = 92.0
## 两侧手指相对中指的「回收量」，造出一点点弧线（0 = 完全平排）
@export_range(0.0, 80.0, 1.0) var finger_fan_back: float = 10.0
## 手指的出力权重（depth 倍率）。STEP 3 起始区间 0.70~0.85。
@export_range(0.0, 1.5, 0.01) var finger_weight: float = 0.78

@export_group("拇指 Thumb")
## STEP 3 默认关闭 —— 只把结构留好，不做完整五指。
@export var thumb_enabled: bool = false
@export_range(8.0, 120.0, 1.0) var thumb_radius: float = 30.0
## 拇指相对掌心沿手方向的偏移（负 = 靠后）
@export_range(-200.0, 200.0, 1.0) var thumb_along: float = -26.0
## 拇指相对掌心沿侧向的偏移（正 = 手掌侧面）
@export_range(-200.0, 200.0, 1.0) var thumb_side: float = 62.0
@export_range(0.0, 1.5, 0.01) var thumb_weight: float = 0.8
## 拇指自身朝向相对手方向的夹角（度）。仅记录，STEP 4 阴影用。
@export_range(-180.0, 180.0, 1.0) var thumb_direction_deg: float = 135.0

@export_group("方向")
## 方向平滑系数（0~1）：越大越跟手、越小越稳
@export_range(0.01, 1.0, 0.01) var direction_smoothing: float = 0.18
## 速度死区（模型空间/秒）：低于它就不更新方向，直接用上次方向
@export_range(0.0, 200.0, 0.5) var direction_deadzone: float = 14.0
## 开天辟地第一次接触时的默认朝向
@export var fallback_direction: Vector2 = Vector2.RIGHT

## 本帧的接触数组（Palm + Fingers[+ Thumb]）。SoftMeshDeformer 只读它。
var contacts: Array[HandContact] = []
## 当前手方向（单位向量）。静止时保持不变。
var hand_direction: Vector2 = Vector2.RIGHT
## 是否已经确立过方向（第一次接触前为 false）
var has_direction: bool = false
## 诊断：方向被速度更新过多少次（静止时不变 → 抖动测试看它）
var direction_updates: int = 0


func _ready() -> void:
	set_process(auto_update)


func _process(_delta: float) -> void:
	if not auto_update:
		return
	update()


## 每帧入口：读数 → 定方向 → 摆接触
func update() -> void:
	if not enabled or touch == null or not is_instance_valid(touch):
		contacts.clear()
		return
	var active: bool = bool(touch.active)
	# 沿用 TouchManager 自己的死区速度（它已经滤过一轮），这里再过一道
	update_direction(touch.velocity)
	contacts = build_contacts(touch.position, hand_direction, clampf(touch.pressure, 0.0, 1.0),
		touch.velocity, active)


## 方向状态机：带死区 + 角度平滑。
##   · velocity 长度 < direction_deadzone  → 完全不动 hand_direction（防抖动）
##   · 第一次有效速度                      → 直接采用，不做平滑（避免从默认方向慢慢转）
##   · 之后                                → 按最短角差平滑转向
func update_direction(velocity: Vector2) -> void:
	if velocity.length() < direction_deadzone:
		return
	var target := velocity.normalized()
	if not has_direction:
		hand_direction = target
		has_direction = true
		direction_updates += 1
		return
	var a: float = hand_direction.angle()
	var b: float = target.angle()
	var diff: float = wrapf(b - a, -PI, PI)
	hand_direction = Vector2.RIGHT.rotated(a + diff * clampf(direction_smoothing, 0.0, 1.0))
	if hand_direction.length_squared() < 0.000001:
		hand_direction = target
	hand_direction = hand_direction.normalized()
	direction_updates += 1


## 当前朝向（永不返回零向量 / NaN）
func current_direction() -> Vector2:
	if hand_direction.length_squared() < 0.000001:
		return fallback_direction.normalized()
	return hand_direction.normalized()


## 摆出接触数组。纯几何，不读任何全局状态 —— 测试可以直接调。
##
## center     模型空间触点（掌心中心）
## dir        手朝向（单位向量；非单位会自动归一）
## pressure   0~1 压力（三项接触共用，出力差异由 weight 体现）
## velocity   手的速度（模型空间/秒）
## active     是否接触中
func build_contacts(center: Vector2, dir: Vector2, pressure: float, velocity: Vector2,
		active: bool) -> Array[HandContact]:
	var out: Array[HandContact] = []
	var fwd: Vector2 = dir
	if fwd.length_squared() < 0.000001:
		fwd = fallback_direction
	fwd = fwd.normalized()
	var side := Vector2(-fwd.y, fwd.x)          # 手方向的左手侧（Godot Y 向下，纯几何垂直）
	var p: float = clampf(pressure, 0.0, 1.0)

	# ── 掌心 ──
	out.append(HandContact.make(HandContact.Type.PALM,
		center + fwd * palm_forward_offset, palm_radius, p, palm_weight, fwd, velocity, active))

	# ── 手指：横排在掌心前方，外侧两根略回收，形成浅弧 ──
	var n: int = maxi(finger_count, 0)
	if n > 0:
		var half: float = float(n - 1) * 0.5
		for i in n:
			var t: float = float(i) - half                       # -1 … +1
			var along: float = finger_distance - absf(t) * finger_fan_back
			var lateral: float = t * finger_spacing
			out.append(HandContact.make(HandContact.Type.FINGER,
				center + fwd * along + side * lateral, finger_radius, p, finger_weight,
				fwd, velocity, active))

	# ── 拇指（默认关闭）──
	if thumb_enabled:
		var tdir: Vector2 = fwd.rotated(deg_to_rad(thumb_direction_deg))
		out.append(HandContact.make(HandContact.Type.THUMB,
			center + fwd * thumb_along + side * thumb_side, thumb_radius, p, thumb_weight,
			tdir, velocity, active))

	return out


## 所有接触的影响半径（模型空间），用于外圈剔除
func max_radius() -> float:
	var best := 0.0
	for c in contacts:
		best = maxf(best, c.radius)
	return best


## 所有接触的包围圆：返回 [center, radius]；无接触时 radius = 0
func bounding_circle() -> Array:
	if contacts.is_empty():
		return [Vector2.ZERO, 0.0]
	var c0: Vector2 = contacts[0].position
	var mn: Vector2 = c0
	var mx: Vector2 = c0
	for c in contacts:
		mn.x = minf(mn.x, c.position.x)
		mn.y = minf(mn.y, c.position.y)
		mx.x = maxf(mx.x, c.position.x)
		mx.y = maxf(mx.y, c.position.y)
	var center: Vector2 = (mn + mx) * 0.5
	var r: float = 0.0
	for c in contacts:
		r = maxf(r, c.position.distance_to(center) + c.radius)
	return [center, r]


## 一行摘要（诊断 / 报告用）
func describe_layout() -> String:
	return "hand dir=(%.2f,%.2f) contacts=%d palm_r=%.0f finger_r=%.0f spacing=%.0f distance=%.0f thumb=%s" % [
		hand_direction.x, hand_direction.y, contacts.size(), palm_radius, finger_radius,
		finger_spacing, finger_distance, "on" if thumb_enabled else "off"]
