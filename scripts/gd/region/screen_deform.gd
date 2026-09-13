extends CanvasLayer
## 屏幕空间形变（区域限定 + 轨迹，autoload: ScreenDeform）
## 左键=凹陷变暗，右键=凹陷提亮；按住拖动 -> 沿路径形成【连续】凹陷（满强度），松开后由 fade_time 渐隐
## 只作用于"按下的那个部件"；透明度/明暗颜色/大小/幅度/最大拖拽距离/时间可调
## 轨迹为连续管状（shader 把相邻点连成凹槽），不再是离散的点
## 拖拽距离/时间 = 自按下左键起算的预算：累计拖拽长度 或 按住时长 到上限，即停止新增轨迹点（已画的保留，松开后渐隐）
## 长度上限 max_dist 现为"占头长的比例"（1.0 = 正好头长），随模型缩放自动变化，天然"不超过头的长度"

const DEPTH_LAYER := 127
const MAX_POINTS := 48
const SHADER_PATH := "res://scripts/gd/region/screen_deform.gdshader"
const TRAIL_MOVE := 0.01        # 每移动这么多(归一化)加一个轨迹点（密集以保证连续）
const MAG_DEFAULT := 0.018
const RADIUS_DEFAULT := 0.10
const DEFAULT_BRUSH_DIR := "res://data/deform"
const SAVE_PATH := "user://deform_settings.json"

var _rect: ColorRect
var _mat: ShaderMaterial
var enabled := true
var mag := MAG_DEFAULT
var radius := RADIUS_DEFAULT
var shade := 0.55                 # 变色强度/透明度
var dark_color := Color(0.05, 0.05, 0.08)
var bright_color := Color(1.0, 1.0, 1.0)
var max_dist := 1.0              # 拖拽长度上限 = max_dist × 头的屏幕长度（占头长比例；1.0=正好头长）；到上限即停止新增轨迹点
var drag_time := 2.5             # 自按下起按住时长上限（秒）；到上限即停止新增轨迹点
var fade_time := 0.4             # 松开后整体渐隐时长（秒，独立于拖拽上限）
var brush_dir := DEFAULT_BRUSH_DIR   # 形变贴图/笔刷文件夹（可调）
var use_map := false
var _maps: Array = []
var _map_index := 0
var _map_names: Array = []

var _trail: Array = []          # {pos, dir, amount, born}
var _holding := false
var _cur_dir := -1
var _release_time := -1.0        # 松开时间，用于松开后渐隐
var _press_start_pos := Vector2.ZERO   # 按下点（归一化），距离预算起点
var _press_start_time := 0.0           # 按下时刻，时间预算起点
var _dragged := 0.0                    # 自按下起累计拖拽长度（归一化）
var _budget := 0.0                      # 本次按下的长度预算（= max_dist × 头长，归一化）
var _mask := Vector4(0.0, 0.0, 1.0, 1.0)
var _mask_limit := false

var _model = null
var _regions: Dictionary = {}


func _ready() -> void:
	layer = DEPTH_LAYER
	_rect = ColorRect.new()
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.position = Vector2.ZERO
	_rect.color = Color(0, 0, 0, 0)
	add_child(_rect)
	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	_rect.material = _mat
	_resize()
	get_viewport().size_changed.connect(_resize)
	_load_settings()
	_update_uniforms()
	_load_maps()
	_setup.call_deferred()


func _setup() -> void:
	var scene = get_tree().current_scene
	if scene == null:
		_setup.call_deferred()
		return
	_model = scene.get_node_or_null("GDCubismUserModel")
	if FileAccess.file_exists("res://data/regions.json"):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://data/regions.json"))
		if parsed is Dictionary and parsed.has("regions"):
			_regions = parsed["regions"]


func _resize() -> void:
	var s := get_viewport().get_visible_rect().size
	_rect.size = s


func toggle_enabled() -> bool:
	enabled = not enabled
	if not enabled:
		_trail.clear()
		_update_uniforms()
	_save_settings()
	return enabled


func set_mag(v: float) -> void:
	mag = clampf(v, 0.0, 0.08)
	_save_settings()


func set_radius(v: float) -> void:
	radius = clampf(v, 0.02, 0.30)
	_save_settings()


func set_shade(v: float) -> void:
	shade = clampf(v, 0.0, 1.0)
	_save_settings()


func set_dark_color(c: Color) -> void:
	dark_color = c
	_update_uniforms()
	_save_settings()


func set_bright_color(c: Color) -> void:
	bright_color = c
	_update_uniforms()
	_save_settings()


func set_max_dist(v: float) -> void:
	max_dist = clampf(v, 0.05, 1.0)
	_save_settings()


func set_drag_time(v: float) -> void:
	drag_time = clampf(v, 0.1, 6.0)
	_save_settings()


func set_brush_dir(p: String) -> void:
	brush_dir = p
	_load_maps()
	_save_settings()


func _save_settings() -> void:
	var d := {
		"enabled": enabled, "mag": mag, "radius": radius, "shade": shade,
		"dark_color": [dark_color.r, dark_color.g, dark_color.b, dark_color.a],
		"bright_color": [bright_color.r, bright_color.g, bright_color.b, bright_color.a],
		"max_dist": max_dist, "drag_time": drag_time,
		"brush_dir": brush_dir, "use_map": use_map, "map_index": _map_index,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))
		f.close()


func _load_settings() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
	if parsed is Dictionary:
		enabled = bool(parsed.get("enabled", enabled))
		mag = clampf(float(parsed.get("mag", mag)), 0.0, 0.08)
		radius = clampf(float(parsed.get("radius", radius)), 0.02, 0.30)
		shade = clampf(float(parsed.get("shade", shade)), 0.0, 1.0)
		var dc = parsed.get("dark_color", [0.05, 0.05, 0.08, 1.0])
		if dc is Array and dc.size() >= 3:
			dark_color = Color(dc[0], dc[1], dc[2], dc[3] if dc.size() > 3 else 1.0)
		var bc = parsed.get("bright_color", [1.0, 1.0, 1.0, 1.0])
		if bc is Array and bc.size() >= 3:
			bright_color = Color(bc[0], bc[1], bc[2], bc[3] if bc.size() > 3 else 1.0)
		max_dist = clampf(float(parsed.get("max_dist", max_dist)), 0.05, 1.0)
		drag_time = clampf(float(parsed.get("drag_time", drag_time)), 0.1, 6.0)
		brush_dir = str(parsed.get("brush_dir", brush_dir))
		use_map = bool(parsed.get("use_map", use_map))
		_map_index = int(parsed.get("map_index", _map_index))


func get_brush_dir() -> String:
	return brush_dir


func _load_maps() -> void:
	_maps.clear()
	_map_names.clear()
	if brush_dir != "" and DirAccess.dir_exists_absolute(brush_dir):
		var dir := DirAccess.open(brush_dir)
		if dir != null:
			dir.list_dir_begin()
			var f := dir.get_next()
			while f != "":
				if not dir.current_is_dir() and f.to_lower().ends_with(".png"):
					var tex = load(brush_dir + "/" + f)
					if tex is Texture2D:
						_maps.append(tex)
						_map_names.append(f)
				f = dir.get_next()
			dir.list_dir_end()
	if _maps.is_empty():
		use_map = false
	if use_map:
		_update_uniforms()


func next_map() -> int:
	if _maps.is_empty():
		return 0
	_map_index = (_map_index + 1) % _maps.size()
	_update_uniforms()
	_save_settings()
	return _map_index


func toggle_use_map() -> bool:
	if _maps.is_empty():
		use_map = false
		return false
	use_map = not use_map
	_update_uniforms()
	_save_settings()
	return use_map


func get_map_count() -> int:
	return _maps.size()


func get_current_map_name() -> String:
	if _maps.is_empty():
		return "(无贴图)"
	return _map_names[_map_index]


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventMouseButton:
		var btn: int = event.button_index
		if btn == MOUSE_BUTTON_LEFT or btn == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_press(event.position, btn)
			else:
				_release(btn)


func _press(pos: Vector2, btn: int) -> void:
	var vp := get_viewport().get_visible_rect().size
	if vp.x <= 0 or vp.y <= 0:
		return
	var center := Vector2(pos.x / vp.x, pos.y / vp.y)
	_cur_dir = -1 if btn == MOUSE_BUTTON_LEFT else 1
	_holding = true
	_press_start_pos = center
	_press_start_time = _now()
	_dragged = 0.0
	_budget = max_dist * _head_length()
	_trail.clear()
	# 边界取消：不再按部件遮罩（等后续再定），形变全范围不裁剪
	_mask_limit = false
	_mask = Vector4(0.0, 0.0, 1.0, 1.0)
	_trail.append({"pos": center, "dir": _cur_dir, "amount": mag, "born": _now()})
	_update_uniforms()


func _release(_btn: int) -> void:
	_holding = false
	# 松开 -> 开始整体渐隐，时长 = drag_time（拖拽时间）
	_release_time = _now()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## 头的屏幕长度（归一化）：模型缩放时自动变化，用作拖拽长度预算的基准
func _head_length() -> float:
	if _model == null:
		return 0.30
	if _regions.has("头"):
		var rects: Array = _regions["头"].get("rects", [])
		if not rects.is_empty():
			var aabb := Rect2(rects[0][0], rects[0][1], rects[0][2], rects[0][3])
			for r in rects:
				aabb = aabb.merge(Rect2(r[0], r[1], r[2], r[3]))
			var p1 := _canvas_to_screen(Vector2(aabb.position.x, aabb.position.y))
			var p2 := _canvas_to_screen(Vector2(aabb.end.x, aabb.end.y))
			var vp := get_viewport().get_visible_rect().size
			if vp.x > 0 and vp.y > 0:
				var w := absf(p2.x - p1.x) / vp.x
				var h := absf(p2.y - p1.y) / vp.y
				return maxf(w, h)
	return 0.30   # 回退：约 30% 屏幕宽


func _process(_delta: float) -> void:
	if not enabled:
		return
	var now := _now()
	var vp := get_viewport().get_visible_rect().size
	if vp.x <= 0:
		return
	var mp := get_viewport().get_mouse_position()
	var mouse_norm := Vector2(mp.x / vp.x, mp.y / vp.y)
	if _holding:
		# 距离/时间预算：自按下起累计拖拽长度 或 按住时长 到上限，即停止新增轨迹点
		var allow := (_dragged < _budget) and ((now - _press_start_time) < drag_time)
		var last: Dictionary = _trail.back() if not _trail.is_empty() else {}
		if allow and (last.is_empty() or last.pos.distance_to(mouse_norm) >= TRAIL_MOVE):
			var seg: float = 0.0
			if not last.is_empty():
				seg = last.pos.distance_to(mouse_norm)
			_trail.append({"pos": mouse_norm, "dir": _cur_dir, "amount": mag, "born": now})
			_dragged += seg
		while _trail.size() > MAX_POINTS:
			_trail.remove_at(0)
		# 按住期间满强度
		for t in _trail:
			t.amount = mag
		_update_uniforms()
	elif _release_time >= 0.0 and not _trail.is_empty():
		# 松开后：整体缓慢渐隐（平滑缓动），时长 = fade_time（与拖拽上限无关）
		var t: float = clampf((now - _release_time) / maxf(fade_time, 0.0001), 0.0, 1.0)
		if t >= 1.0:
			_trail.clear()
			_release_time = -1.0
		else:
			var fade: float = 1.0 - smoothstep(0.0, 1.0, t)   # 平滑缓动，慢慢淡出
			for tp in _trail:
				tp.amount = mag * fade
		_update_uniforms()


func _region_mask(vp_pos: Vector2) -> Vector4:
	if _model == null or _regions.is_empty():
		return Vector4(0.0, 0.0, 0.0, 0.0)
	var canvas_pos := _to_canvas_space(vp_pos)
	var region := _region_at(canvas_pos)
	if region == "":
		return Vector4(0.0, 0.0, 0.0, 0.0)
	var rects: Array = _regions[region].get("rects", [])
	if rects.is_empty():
		return Vector4(0.0, 0.0, 0.0, 0.0)
	var aabb := Rect2(rects[0][0], rects[0][1], rects[0][2], rects[0][3])
	for r in rects:
		aabb = aabb.merge(Rect2(r[0], r[1], r[2], r[3]))
	var p1 := _canvas_to_screen(Vector2(aabb.position.x, aabb.position.y))
	var p2 := _canvas_to_screen(Vector2(aabb.end.x, aabb.end.y))
	var vp := get_viewport().get_visible_rect().size
	return Vector4(
		minf(p1.x, p2.x) / vp.x, minf(p1.y, p2.y) / vp.y,
		maxf(p1.x, p2.x) / vp.x, maxf(p1.y, p2.y) / vp.y)


func _canvas_to_screen(canvas_pt: Vector2) -> Vector2:
	if _model == null:
		return Vector2.ZERO
	var world = _model.to_global(canvas_pt)
	return get_viewport().get_canvas_transform() * world


func _to_canvas_space(vp_pos: Vector2) -> Vector2:
	if _model == null:
		return Vector2.ZERO
	var world = get_viewport().get_canvas_transform().affine_inverse() * vp_pos
	var local = _model.to_local(world)
	var flip = _model.get("flip_h")
	if flip:
		local.x = -local.x
	return local


func _region_at(canvas_pos: Vector2) -> String:
	for region_name in _regions:
		var rects: Array = _regions[region_name].get("rects", [])
		for r in rects:
			if r.size() >= 4 and Rect2(r[0], r[1], r[2], r[3]).has_point(canvas_pos):
				return region_name
	return ""


func _update_uniforms() -> void:
	var c := PackedVector2Array()
	var a := PackedFloat32Array()
	var d := PackedFloat32Array()
	for i in range(MAX_POINTS):
		if i < _trail.size():
			c.append(Vector2(_trail[i].pos))
			a.append(float(_trail[i].amount))
			d.append(float(_trail[i].dir))
		else:
			c.append(Vector2(2.0, 2.0))
			a.append(0.0)
			d.append(-1.0)
	_mat.set_shader_parameter("p_c", c)
	_mat.set_shader_parameter("p_a", a)
	_mat.set_shader_parameter("p_dir", d)
	_mat.set_shader_parameter("p_radius", radius)
	_mat.set_shader_parameter("p_shade", shade)
	_mat.set_shader_parameter("p_dark_color", dark_color)
	_mat.set_shader_parameter("p_bright_color", bright_color)
	_mat.set_shader_parameter("p_mask", _mask)
	_mat.set_shader_parameter("p_mask_limit", 1.0 if _mask_limit else 0.0)
	_mat.set_shader_parameter("p_use_map", 1.0 if use_map else 0.0)
	_mat.set_shader_parameter("p_active", 1.0 if (not _trail.is_empty()) else 0.0)
	if not _maps.is_empty():
		_mat.set_shader_parameter("p_map", _maps[_map_index])
