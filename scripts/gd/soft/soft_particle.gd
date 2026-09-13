## 软体质点（SoftTouch 模块 · 最底层数据单元）
##
## 每个质点用 Verlet 积分保存「当前位置 / 上一帧位置 / 原始位置」三个量：
##   位置差 (position - previous_position) 即当前速度，不需要单独存速度变量，
##   这是 Verlet 比欧拉法更稳的原因（约束修正会自然转成速度）。
##
## original_position 是「未受力时的静止位置」，回弹力就是朝它拉。
##
## 本文件不引用任何 Live2D / UI 系统，可独立使用。

class_name SoftParticle
extends RefCounted

## 当前位置（求解器的工作坐标，会被约束不断修正）
var position: Vector2 = Vector2.ZERO

## 上一帧位置：Verlet 用它推算速度
var previous_position: Vector2 = Vector2.ZERO

## 静止位置：回弹力的目标
var original_position: Vector2 = Vector2.ZERO

## 质量与质量倒数。inv_mass = 0 表示「不可移动」（等价于 pinned），
## 约束求解时按 inv_mass 加权分配修正量，这样重的地方动得少。
var mass: float = 1.0
var inv_mass: float = 1.0

## 钉住的质点不参与积分，也不会被约束推动
var pinned: bool = false

## 累计位移标量（仅用于调试显示 / 自检断言，不影响物理）
var max_offset_seen: float = 0.0


func _init(pos: Vector2 = Vector2.ZERO, is_pinned: bool = false) -> void:
	position = pos
	previous_position = pos
	original_position = pos
	pinned = is_pinned
	inv_mass = 0.0 if is_pinned else 1.0 / maxf(mass, 0.0001)


## 相对原始位置的总位移（当前偏离静止状态多少）
func offset_from_original() -> Vector2:
	return position - original_position


## 当前速度（每帧位移，未除以 delta —— Verlet 的固有表示）
func velocity() -> Vector2:
	return position - previous_position


## 把质点瞬移回静止位置（复位用）
func reset_to_original() -> void:
	position = original_position
	previous_position = original_position
	max_offset_seen = 0.0


## 设置钉住状态并同步 inv_mass
func set_pinned(value: bool) -> void:
	pinned = value
	inv_mass = 0.0 if pinned else 1.0 / maxf(mass, 0.0001)


## 换一个静止位置（例如网格整体搬家后）
func set_original(pos: Vector2) -> void:
	original_position = pos
