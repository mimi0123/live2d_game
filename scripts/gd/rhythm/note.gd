extends Node2D
class_name RhythmNote

# 单个「光圈」音符：自绘为圆环，随时间从大半径收缩到目标半径。
# 在 ideal_time 时刻，圆环半径恰好等于目标半径（与固定目标环重合）。
# 位置由 RhythmGame 固定在对应轨道的目标中心，逐帧把 cur_time 注入这里。

var lane: int = 0
var ideal_time: float = 0.0
var duration: float = 0.0      # 保留字段，光圈模式按单点音符处理
var is_long: bool = false
var judged: bool = false
var result_text: String = ""
var judge_time: float = -1.0   # 被判定（命中或 Miss）的时刻，用于淡出动画

# 由 RhythmGame 每帧注入
var cur_time: float = 0.0
var lead_time: float = 1.6
var target_r: float = 46.0
var spawn_r: float = 190.0

var color_left := Color(0.45, 0.75, 1.0)
var color_right := Color(1.0, 0.55, 0.82)


func _draw() -> void:
	var col := color_left if lane == 0 else color_right
	# 进度 p：0 = 出生（最大半径），1 = 理想命中时刻（= 目标半径）
	var p := (cur_time - (ideal_time - lead_time)) / lead_time
	if p < 0.0:
		p = 0.0

	if judged:
		var t := clampf(p - 1.0, 0.0, 1.0)
		if result_text == "Perfect" or result_text == "Good":
			# 命中：向外爆开并淡出
			var r := target_r + t * 46.0
			draw_arc(Vector2.ZERO, r, 0, TAU, 36, Color(col.r, col.g, col.b, 1.0 - t), 6)
		else:
			# Miss：继续向内收缩穿过目标并淡出
			var r := maxf(2.0, target_r * (1.0 - t))
			draw_arc(Vector2.ZERO, r, 0, TAU, 36, Color(col.r, col.g, col.b, 1.0 - t), 5)
		return

	# 未判定：收缩中的光圈
	var r := spawn_r + (target_r - spawn_r) * p
	draw_arc(Vector2.ZERO, r, 0, TAU, 48, col, 6)
