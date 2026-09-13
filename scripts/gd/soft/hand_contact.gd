## HandContact —— 一个「接触点」的纯数据描述（SoftTouch 模块 · STEP 3）
##
## 分层铁律（STEP 3 明确要求）：
##   HandContact      只描述「手」：位置 / 半径 / 压力 / 速度 / 方向 / 开关 / 类型
##   HandRig          只负责摆放出 Palm + Finger（模型空间）
##   ContactBlend     只负责把多个接触合并成一个位移（纯数学）
##   SoftMeshDeformer 才负责 Live2D 顶点：读 contacts → 算场 → 写回 ArtMesh
##
## 所以本文件【不】引用 Live2D、Node、MeshInstance2D、ArrayMesh 中的任何东西。
## 它连 RefCounted 都只是为了让测试里能 new 出来，除此之外没有任何行为。
##
## 坐标单位：一律是模型空间（画布像素）。绝不是屏幕像素 ——
## 这样 Camera2D 怎么缩放，手指的粗细都不会跟着变（STEP 3 测试项 G）。

class_name HandContact
extends RefCounted

## 接触类型。STEP 3 只产出 PALM / FINGER（Thumb 预留，默认不启用）。
enum Type {
	DEFAULT,   ## 旧单触点路径（TouchManager 直接给的那一个点）
	PALM,      ## 手掌——最大的那块
	FINGER,    ## 手指
	THUMB,     ## 拇指（结构已就位，STEP 3 默认关闭）
}

## 类型名（打印 / 报告用）
const TYPE_NAMES := {
	Type.DEFAULT: "DEFAULT",
	Type.PALM: "PALM",
	Type.FINGER: "FINGER",
	Type.THUMB: "THUMB",
}

## 接触类型
var type: int = Type.DEFAULT
## 接触中心（模型空间）
var position: Vector2 = Vector2.ZERO
## 影响半径（模型空间）。与压力无关的固定几何量，不允许由屏幕像素换算。
var radius: float = 90.0
## 压力 0~1（来自 TouchManager 的压力上升曲线，未乘权重）
var pressure: float = 0.0
## 出力权重：等效于「该接触的 depth 倍率」。
##   PALM 1.0 / FINGER 0.78 / THUMB 0.8（STEP 3 起始值，可由 HandRig 导出变量调）
## 之所以作用在 depth 上而不是直接乘 pressure，是为了不和压力上升曲线
## lerp(0.55, 1.0, p) 耦合 —— 否则「手指比掌心浅 22%」会被曲线吃掉一部分。
var weight: float = 1.0
## 该接触自身的移动速度（模型空间 / 秒）。多指可以各自不同。
var velocity: Vector2 = Vector2.ZERO
## 单位方向向量（手的朝向；STEP 3 只做记录与测试，STEP 4 阴影画笔会用到）
var direction: Vector2 = Vector2.RIGHT
## 是否处于接触状态
var active: bool = false


## 是否在参与计算（active + 有压力 + 有半径）
func is_on() -> bool:
	return active and pressure > 0.0001 and radius > 0.0 and weight > 0.0


## 该接触对 depth 的实际倍率（压力上升曲线 × 权重）
func depth_factor() -> float:
	return weight * lerpf(0.55, 1.0, clampf(pressure, 0.0, 1.0))


## 「等效压力」= pressure × weight。仅用于报告 / STEP 4 阴影，不参与顶点计算。
func effective_pressure() -> float:
	return clampf(pressure, 0.0, 1.0) * weight


## 单位化后的方向（零向量时退回 RIGHT，永不返回 NaN）
func safe_direction() -> Vector2:
	if direction.length_squared() < 0.000001:
		return Vector2.RIGHT
	return direction.normalized()


## 浅拷贝（测试里要拿同一份参数反复改，避免互相污染）
func clone() -> HandContact:
	var c := HandContact.new()
	c.type = type
	c.position = position
	c.radius = radius
	c.pressure = pressure
	c.weight = weight
	c.velocity = velocity
	c.direction = direction
	c.active = active
	return c


## 一行摘要（报告用）
func describe() -> String:
	return "%-7s pos=(%8.1f,%8.1f) r=%6.1f p=%.2f w=%.2f dir=(%.2f,%.2f) v=%.1f %s" % [
		TYPE_NAMES.get(type, "?"), position.x, position.y, radius, pressure, weight,
		direction.x, direction.y, velocity.length(), "ON" if active else "off"]


## 静态构造：让 HandRig 的代码短一点，也保证字段不会被漏填
static func make(p_type: int, p_position: Vector2, p_radius: float, p_pressure: float,
		p_weight: float = 1.0, p_direction: Vector2 = Vector2.RIGHT,
		p_velocity: Vector2 = Vector2.ZERO, p_active: bool = true) -> HandContact:
	var c := HandContact.new()
	c.type = p_type
	c.position = p_position
	c.radius = p_radius
	c.pressure = p_pressure
	c.weight = p_weight
	c.direction = p_direction
	c.velocity = p_velocity
	c.active = p_active
	return c


## 静态构造：从 TouchManager 那种「单触点」世界来的一颗接触
static func from_touch(p_position: Vector2, p_radius: float, p_pressure: float,
		p_velocity: Vector2, p_active: bool) -> HandContact:
	return make(Type.DEFAULT, p_position, p_radius, p_pressure, 1.0,
		Vector2.RIGHT if p_velocity.length_squared() < 0.000001 else p_velocity.normalized(),
		p_velocity, p_active)
