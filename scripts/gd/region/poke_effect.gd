extends Node2D
## 触碰凹陷/凸起特效（作为 GDCubismUserModel 的子节点，画在模型坐标系里）
## 左键=凹陷（中心暗 + 边缘受光亮环），右键=凸起（中心亮 + 边缘投影暗环）
## 持续时间：至少 1 秒，按住越久越久（最长跟按住时长挂钩），松开后渐隐

const FADE_IN := 0.08
const MIN_HOLD := 1.0
const FADE_OUT := 0.35
const RADIUS_RATIO := 0.06   # 半径 = 画布长边 * 6%

var _radius := 240.0
var _tex_dent: GradientTexture2D = null
var _tex_bulge: GradientTexture2D = null
var _pokes: Array = []   # {pos, dir, press, released, release, alpha}


func _ready() -> void:
	# 根据模型画布尺寸确定半径，保证不同模型视觉大小一致
	var model = get_parent()
	if model != null and model.has_method("get_canvas_info"):
		var ci: Dictionary = model.get_canvas_info()
		if not ci.is_empty():
			var size: Vector2 = ci.size_in_pixels
			_radius = maxf(size.x, size.y) * RADIUS_RATIO
	# 凹陷：中心暗(凹陷) -> 边缘一圈亮(受光边缘) -> 透明
	_tex_dent = _make_radial([
		[0.00, Color(0.06, 0.06, 0.10, 0.78)],
		[0.60, Color(0.08, 0.08, 0.12, 0.72)],
		[0.82, Color(0.38, 0.42, 0.52, 0.45)],
		[0.90, Color(0.85, 0.88, 0.95, 0.42)],
		[1.00, Color(0.0, 0.0, 0.0, 0.0)],
	])
	# 凸起：中心亮(隆起) -> 边缘一圈阴影(投影) -> 透明
	_tex_bulge = _make_radial([
		[0.00, Color(1.00, 0.97, 0.88, 0.88)],
		[0.62, Color(0.95, 0.92, 0.85, 0.55)],
		[0.82, Color(0.24, 0.24, 0.30, 0.40)],
		[0.90, Color(0.05, 0.05, 0.08, 0.35)],
		[1.00, Color(0.0, 0.0, 0.0, 0.0)],
	])


func _make_radial(stops: Array) -> GradientTexture2D:
	var g := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for s in stops:
		offsets.append(float(s[0]))
		colors.append(s[1])
	g.offsets = offsets
	g.colors = colors
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 256
	tex.height = 256
	return tex


func poke_at(pos: Vector2, dir: int) -> void:
	_pokes.append({
		"pos": pos, "dir": dir,
		"press": _now(), "released": false, "release": 0.0, "alpha": 0.0,
	})
	queue_redraw()


func release(dir: int) -> void:
	var now := _now()
	for p in _pokes:
		if p.dir == dir and not p.released:
			p.released = true
			p.release = now


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	var now := _now()
	var changed := false
	for i in range(_pokes.size() - 1, -1, -1):
		var p: Dictionary = _pokes[i]
		if not p.released:
			p.alpha = minf(1.0, (now - p.press) / FADE_IN)
			changed = true
		else:
			var hold: float = maxf(MIN_HOLD, p.release - p.press)
			var fade_start: float = p.press + hold
			if now >= fade_start:
				p.alpha = maxf(0.0, 1.0 - (now - fade_start) / FADE_OUT)
				if p.alpha <= 0.0:
					_pokes.remove_at(i)
				changed = true
			else:
				p.alpha = 1.0
				changed = true
	if changed:
		queue_redraw()


func _draw() -> void:
	for p in _pokes:
		var tex = _tex_dent if p.dir < 0 else _tex_bulge
		var a: float = p.alpha
		var size := Vector2(_radius * 2.0, _radius * 2.0)
		var rect := Rect2(p.pos - size / 2.0, size)
		draw_texture_rect(tex, rect, false, Color(1, 1, 1, a))
