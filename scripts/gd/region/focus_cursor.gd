extends Node2D
## 键盘虚拟光标（聚焦位置）可视化：只有在“点击”时才迸发一圈快速消散的波纹
## 平时（键盘移动 / 真实鼠标移动）不显示任何额外效果，波纹固定在点击发生的位置

var _color := Color(1.0, 0.45, 0.85, 1.0)

const RIPPLE_LIFETIME := 0.35     # 波纹消散时长（秒）
const RIPPLE_MAX_RADIUS := 40.0   # 波纹扩散到多大（像素）
const RIPPLE_MIN_RADIUS := 4.0    # 波纹起始半径
const MAX_RIPPLES := 8            # 同时存在的波纹上限

var _ripples: Array = []          # {pos: Vector2, born: float}
var _focus_pos := Vector2.ZERO    # 当前焦点位置（仅记录，不用于绘制）


func _process(_delta: float) -> void:
	var now := _now()
	# 清理已消散的波纹
	var i := 0
	while i < _ripples.size():
		var r: Dictionary = _ripples[i]
		var born: float = r.born
		if now - born > RIPPLE_LIFETIME:
			_ripples.remove_at(i)
		else:
			i += 1
	if not _ripples.is_empty():
		queue_redraw()


func _draw() -> void:
	var now := _now()
	for r in _ripples:
		var r_dict: Dictionary = r
		var age: float = now - r_dict.born
		var t := clampf(age / RIPPLE_LIFETIME, 0.0, 1.0)
		var alpha := pow(1.0 - t, 2.0)
		var line_w := 2.0 * (1.0 - t) + 0.5

		# 主环：从小到大、越来越淡
		var radius := RIPPLE_MIN_RADIUS + (RIPPLE_MAX_RADIUS - RIPPLE_MIN_RADIUS) * t
		draw_arc(r_dict.pos - position, radius, 0.0, TAU, 32, Color(_color, alpha), line_w)

		# 内环纹理，延迟出现，形成“波纹状”叠层
		if t < 0.7:
			var t2 := clampf(t / 0.7, 0.0, 1.0)
			var r2 := RIPPLE_MIN_RADIUS + (RIPPLE_MAX_RADIUS * 0.6 - RIPPLE_MIN_RADIUS) * t2
			draw_arc(r_dict.pos - position, r2, 0.0, TAU, 32, Color(_color, alpha * 0.6), line_w * 0.7)


## 只更新焦点位置，不在移动时生成波纹
func set_focus(pos: Vector2) -> void:
	_focus_pos = pos
	if not _ripples.is_empty():
		queue_redraw()


## 在指定位置迸发一圈波纹（由交互点击调用，而非移动）
func spawn_ripple(pos: Vector2) -> void:
	_ripples.append({"pos": pos, "born": _now()})
	if _ripples.size() > MAX_RIPPLES:
		_ripples.remove_at(0)
	queue_redraw()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
