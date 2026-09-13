## ShadowField —— 接触 → 阴影画笔 的分配台（SoftTouch 模块 · STEP 4）
##
## 数据流（Master STEP 4 指令的架构）：
##   Mouse → TouchManager → HandRig(HandContact[]) → ShadowField → ShadowBrush[]
##         → 位置/旋转/缩放/Alpha → 模型空间 Shadow → 显示在 Live2D 模型附近
##
## 职责边界：
##   · 只消费 HandContact（数据），为每颗接触维护一枚 ShadowBrush
##   · 掌心配掌纹理，手指按序配 fingertip_01~05，绝不合并成一张大图
##   · 笔刷是本节点的 Sprite2D 子节点 —— 本节点必须挂在「模型空间」下
##     （生产环境挂在 GDCubismUserModel 下面，随模型一起被 Camera2D 缩放）
##   · 不碰 MeshInstance2D / 顶点 / 弹簧 —— 与 SoftMeshDeformer 完全解耦
##
## 不做（留 STEP 5）：SKIN/THIN_CLOTH/THICK_CLOTH 分类、摩擦、褶皱、区域判定。

class_name ShadowField
extends Node2D

## 数据源（二选一，hand_rig 优先）
@export var hand_rig: HandRig = null
## hand_rig 缺席时的兜底：把 TouchManager 的单触点转成一颗 DEFAULT 接触
@export var touch: TouchManager = null
@export var enabled: bool = true

@export_group("纹理（STEP 4 第一阶段 · common）")
## 掌心阴影。palm_soft 优先，palm_pressure_soft 备用
@export var palm_texture: Texture2D = null
## 手指阴影池（按指序 01~05 轮换，不重复用同一张）
@export var finger_textures: Array[Texture2D] = []
## 拇指（预留，STEP 3 默认不出拇指）
@export var thumb_texture: Texture2D = null

@export_group("渲染层")
## z_index：要压过 Live2D 网格的绘制。gd_cubism 网格在模型节点自身绘制，
## 子节点默认画在父节点之后，这里再垫一层保险。⚠ 真机需复核是否被模型覆盖。
@export_range(0, 4096, 1) var brush_z_index: int = 100

@export_group("兜底单触点")
## touch 兜底路径的接触半径（模型空间）
@export_range(10.0, 400.0, 1.0) var fallback_radius: float = 190.0

## 笔刷对象池（复用，不逐帧 new/free —— 防止 GC 抖动与「闪烁」）
var _pool: Array[ShadowBrush] = []
## 诊断：总创建数 / 当前激活数 / NaN 拦截数
var brushes_created: int = 0
var active_count: int = 0
var nan_rejects: int = 0


func _ready() -> void:
	z_index = brush_z_index


func _process(delta: float) -> void:
	if not enabled:
		_sleep_all()
		return
	var contacts: Array[HandContact] = _gather_contacts()
	update_contacts(contacts, delta)


## 收集本帧接触：HandRig 优先；否则 TouchManager 单触点兜底
func _gather_contacts() -> Array[HandContact]:
	var out: Array[HandContact] = []
	if hand_rig != null and is_instance_valid(hand_rig):
		return hand_rig.contacts
	if touch != null and is_instance_valid(touch):
		out.append(HandContact.from_touch(touch.position, fallback_radius,
			clampf(touch.pressure, 0.0, 1.0), touch.velocity, bool(touch.active)))
	return out


## 核心：把一组接触同步到笔刷池。公开给测试直接调（绕过 _process，确定性）。
func update_contacts(contacts: Array[HandContact], delta: float = 0.0) -> void:
	active_count = 0
	if contacts == null:
		contacts = []
	var shown: int = 0
	for c in contacts:
		if c == null:
			continue
		# 只支持 PALM / FINGER（+THUMB 预留）；DEFAULT 走掌纹理
		var brush: ShadowBrush = _acquire(shown)
		brush.texture = _pick_texture(c, shown)
		var ok: bool = brush.apply_contact(c, delta)
		if not ok:
			nan_rejects += 1
			brush.sleep()
			continue
		shown += 1
		if c.is_on():
			active_count += 1
	# 多余的笔刷全部收回（测试项 J：接触灭 → 笔刷藏）
	for i in range(shown, _pool.size()):
		_pool[i].sleep()


## 取第 idx 枚笔刷（池不够就造）
func _acquire(idx: int) -> ShadowBrush:
	while _pool.size() <= idx:
		var b := ShadowBrush.new()
		b.visible = false
		add_child(b)
		_pool.append(b)
		brushes_created += 1
	var b: ShadowBrush = _pool[idx]
	b.in_use = true
	b.visible = false          # apply_contact 内部再点亮，避免一帧闪现
	return b


## 纹理选择：PALM/DEFAULT → 掌纹理；FINGER → 指池按序取模；THUMB → 拇指
func _pick_texture(c: HandContact, idx: int) -> Texture2D:
	match c.type:
		HandContact.Type.PALM, HandContact.Type.DEFAULT:
			return palm_texture
		HandContact.Type.FINGER:
			# idx-1：第 0 枚是掌心，手指从 idx=1 起；取模防止指池比手指数少
			var fi: int = maxi(idx - 1, 0)
			if finger_textures.is_empty():
				return palm_texture
			return finger_textures[fi % finger_textures.size()]
		HandContact.Type.THUMB:
			return thumb_texture if thumb_texture != null else palm_texture
	return palm_texture


func _sleep_all() -> void:
	for b in _pool:
		b.sleep()
	active_count = 0


## 当前可见笔刷数（报告用）
func visible_count() -> int:
	var n := 0
	for b in _pool:
		if b.visible:
			n += 1
	return n


## 一行摘要（报告用）
func describe() -> String:
	return "ShadowField pool=%d visible=%d active=%d created=%d nan_rejects=%d z=%d" % [
		_pool.size(), visible_count(), active_count, brushes_created, nan_rejects, z_index]
