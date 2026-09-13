## ShadowBrush —— 一枚「接触阴影画笔」（SoftTouch 模块 · STEP 4）
##
## 分层铁律（STEP 4 明确要求）：
##   HandContact   只描述「手」（纯数据）
##   HandRig       只负责摆放接触
##   ShadowBrush   只负责【画】：纹理 / 位置 / 旋转 / 缩放 / Alpha / 可见性 / 生命周期
##   ShadowField   只负责「哪颗接触配哪枚笔刷」
##
## 本文件【不】碰 MeshInstance2D / ArrayMesh / 顶点 / 弹簧 —— 与 SoftMeshDeformer 完全解耦。
## 它只是一枚挂在模型子树里的 Sprite2D，视觉上叠在模型表面附近。
##
## 坐标系：父节点 = 模型节点（或任何「模型空间」Node2D），所以 position/scale
## 全是模型空间（画布像素）。Camera2D.zoom 只改屏幕视觉大小，不改这里的任何数值。
##
## 禁止事项对照（Master STEP 4 指令）：
##   ✗ 不当固定位置的贴纸      —— 位置/旋转/缩放/Alpha 全部由接触数据逐帧驱动
##   ✗ 不逐帧播放序列动画      —— 纹理是静态 PNG，动态感来自压力映射
##   ✗ 不写进 Live2D 顶点      —— 本类没有任何 mesh 访问代码
##   ✗ 不做材质判断            —— SKIN/CLOTH 留给 STEP 5

class_name ShadowBrush
extends Sprite2D

## ── 压力 → Alpha 映射（全部 @export，不写死视觉参数）──
@export_group("Alpha")
## 压力为 0 时的透明度（0 = 完全透明）
@export_range(0.0, 1.0, 0.01) var min_alpha: float = 0.0
## 压力满格时的透明度。0.55 起步：阴影要「垫在角色下面」而不是糊成黑块
@export_range(0.0, 1.0, 0.01) var max_alpha: float = 0.55
## 压力响应曲线指数：<1 = 轻压就有明显阴影；>1 = 重压才显影
@export_range(0.1, 4.0, 0.05) var pressure_gamma: float = 0.8

## ── 压力 → 缩放 映射 ──
@export_group("Scale")
## 压力对尺寸的增益（0.05~0.15 区间起步）：scale = 1.0 + gain × pressure
## Master 指令：变化控制在 5%~15%，禁止夸张膨胀
@export_range(0.0, 0.3, 0.01) var scale_pressure_gain: float = 0.10

## ── 尺寸换算 ──
@export_group("尺寸")
## 接触半径 → 精灵宽度的倍率：精灵宽 = 2 × contact.radius × diameter_factor。
## 素材是柔边椭圆（越往外越透明），1.15 让「肉眼可见的深色核心」大致等于接触半径。
@export_range(0.5, 3.0, 0.05) var diameter_factor: float = 1.15

## ── 旋转微调 ──
@export_group("旋转")
## 纹理作者的「手朝向」与素材原始朝向的夹角（度）。素材没有约定朝向时保持 0。
@export_range(-180.0, 180.0, 1.0) var rotation_offset_deg: float = 0.0

## ── 平滑 ──
@export_group("平滑")
## Alpha / 缩放的趋近速率（1/秒）。0 = 不平滑（直接跳变，测试用）
@export_range(0.0, 30.0, 0.5) var smoothing: float = 10.0

## 生命周期标记：false = 空闲待回收（ShadowField 复用池）
var in_use: bool = false
## 首次赋值跳过平滑（否则笔刷会从旧值慢慢飘到新值，看起来像「闪一下」）
var _primed: bool = false
var _cur_alpha: float = 0.0
var _cur_grow: float = 1.0
## 诊断：本笔刷一生被应用过多少次接触
var apply_count: int = 0


func _init() -> void:
	# 阴影垫在角色表面附近：中心在接触点上，纹理以中心对齐。
	# 注：Sprite2D 属 Node2D 系，不参与 Control 的 mouse_filter 拾取，天然不挡命中测试。
	centered = true


## 用一颗接触刷新本笔刷。纯视觉，不读任何物理状态。
## 返回是否成功（NaN / 非有限输入 → 立即隐藏并返回 false，宁可不显示也不渲染垃圾）。
func apply_contact(c: HandContact, delta: float) -> bool:
	apply_count += 1
	if c == null or not is_instance_valid(c):
		visible = false
		return false

	# ── NaN / 非有限输入防护（测试项 K）──
	var pos: Vector2 = c.position
	var dir: Vector2 = c.safe_direction()
	if not is_finite(pos.x) or not is_finite(pos.y) or not is_finite(c.radius) \
			or not is_finite(dir.x) or not is_finite(dir.y) or c.radius <= 0.0:
		visible = false
		return false

	# ── 接触已结束 → 隐藏（测试项 J；返回 true 表示「合法处理」，不算 NaN 拦截）──
	if not c.active:
		visible = false
		return true

	# ── 位置（模型空间，逐帧跟随接触）──
	position = pos

	# ── 旋转（跟随接触方向；方向本身由 HandRig 的死区保证静止不抖）──
	rotation = dir.angle() + deg_to_rad(rotation_offset_deg)

	# ── 压力 → Alpha ──
	# 用 effective_pressure()（pressure × weight）：指尖权重 0.78，阴影天然比掌心淡
	var eff: float = clampf(c.effective_pressure(), 0.0, 1.0)
	var target_alpha: float = lerpf(min_alpha, max_alpha, pow(eff, pressure_gamma))

	# ── 压力 → 缩放（5%~15% 轻微胀缩）──
	var target_grow: float = 1.0 + scale_pressure_gain * eff

	# ── 平滑（首帧直接落位）──
	if not _primed or smoothing <= 0.0 or delta <= 0.0:
		_cur_alpha = target_alpha
		_cur_grow = target_grow
		_primed = true
	else:
		var w: float = 1.0 - exp(-smoothing * delta)
		_cur_alpha = lerpf(_cur_alpha, target_alpha, w)
		_cur_grow = lerpf(_cur_grow, target_grow, w)

	modulate.a = clampf(_cur_alpha, 0.0, 1.0)

	# ── 尺寸：接触半径（模型空间）→ 精灵宽（模型空间）──
	var tex_w: float = 1.0
	if texture != null:
		tex_w = float(texture.get_width())
	var want: float = 2.0 * c.radius * diameter_factor * _cur_grow
	var s: float = want / maxf(tex_w, 1.0)
	if not is_finite(s) or s <= 0.0:
		visible = false
		return false
	scale = Vector2(s, s)

	visible = true
	return true


## 隐藏并回到池里
func sleep() -> void:
	in_use = false
	visible = false
	_primed = false
	_cur_alpha = 0.0
	_cur_grow = 1.0


## 一行摘要（诊断 / 报告用）
func describe() -> String:
	var tex_name := "<null>"
	if texture != null:
		tex_name = texture.resource_path.get_file()
	return "brush tex=%-24s pos=(%8.1f,%8.1f) rot=%6.1f° scale=%.3f alpha=%.3f visible=%s" % [
		tex_name, position.x, position.y, rad_to_deg(rotation), scale.x, modulate.a, visible]
