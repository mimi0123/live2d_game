extends Node
## 部位点击检测器（autoload: RegionDetector）
##
## 点击模型的粗粒度部位（头/胸/手/腿/衣服…）触发对应台词。
## 区域用矩形定义在画布像素坐标系里，配置在 res://data/regions.json，可随意增删改。
## 台词数据在 res://data/dialogue.json（键 = 区域名），由 DialogueManager 播放。
##
## 扩展方式：
##   1. 在 regions.json 里加/改区域矩形（每个区域可多个矩形，如左右手）。
##   2. 在 dialogue.json 里给区域名加台词数组（text 文本 + voice 语音路径，可无限条）。
##   3. regions.json 的 random_order: true 则台词随机顺序播放。

const REGIONS_PATH := "res://data/regions.json"

var _model = null
var _root = null
var _regions: Dictionary = {}
var _random_order: bool = false
var _overlay: Node2D = null
var _poke: Node2D = null

# 键盘虚拟光标（聚焦位置）：视口像素坐标，WASD/方向键移动，空格在焦点处“点击”
var _focus_pos := Vector2.ZERO
var _focus_speed := 650.0
var _cursor_layer: CanvasLayer = null
var _cursor_node: Node2D = null

# 音游模式：进入后屏蔽角色互动输入（点击/poke/键盘焦点），交给 RhythmGame 判定
var _rhythm_mode := false


func _ready() -> void:
	_load_regions()
	_setup.call_deferred()


func _setup() -> void:
	var scene = get_tree().current_scene
	if scene == null:
		_setup.call_deferred()
		return
	_model = scene.get_node_or_null("GDCubismUserModel")
	_root = scene
	_fit_model_to_viewport.call_deferred()
	_create_overlay()
	_create_poke()
	_create_focus_cursor()
	_self_test.call_deferred()


func _load_regions() -> void:
	if not FileAccess.file_exists(REGIONS_PATH):
		push_warning("[RegionDetector] 缺少 regions.json，区域点击不可用")
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(REGIONS_PATH))
	if parsed is Dictionary:
		_regions = parsed.get("regions", {})
		_random_order = bool(parsed.get("random_order", false))
	else:
		push_warning("[RegionDetector] regions.json 解析失败")


func _unhandled_input(event: InputEvent) -> void:
	if _rhythm_mode:
		return
	# 触碰特效：左键凹陷 / 右键凸起（按下出现，松开后至少持续 1 秒再渐隐）
	if event is InputEventMouseButton:
		var btn: int = event.button_index
		if btn == MOUSE_BUTTON_LEFT or btn == MOUSE_BUTTON_RIGHT:
			var dir := -1 if btn == MOUSE_BUTTON_LEFT else 1
			if event.pressed:
				if _poke != null and _model != null:
					_poke.poke_at(_to_canvas_space(event.position), dir)
			else:
				if _poke != null:
					_poke.release(dir)
	# 鼠标左键：在真实鼠标位置触发点击（正常鼠标，不额外冒波纹）
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_click_at(event.position, false)
		return
	# 空格：在键盘虚拟光标（聚焦位置）触发点击，并迸发波纹
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_click_at(_focus_pos, true)
		get_viewport().set_input_as_handled()
		return
	# F4：显示/隐藏区域调试叠加层
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F4:
		if _overlay != null:
			_overlay.visible = not _overlay.visible
			_overlay.queue_redraw()


## 在任意视口坐标点“点击角色”：定位部位 -> 触发互动 / 推进台词
## from_keyboard=true 时（键盘虚拟光标的空格点击）在点击处迸发波纹；真实鼠标点击不冒波纹
func _click_at(vp_pos: Vector2, from_keyboard := false) -> void:
	if _model == null:
		return
	_set_focus(vp_pos)
	if from_keyboard and _cursor_node != null:
		_cursor_node.spawn_ripple(vp_pos)
	var canvas_pos := _to_canvas_space(vp_pos)
	var region := _region_at(canvas_pos)
	if region != "":
		# 每次点击部位都触发互动计分（台词播放中也不丢分，新行会排队在后面）
		# 想跳过/推进当前台词请点击对话框或按 空格/回车/J
		if Dialogue.is_active():
			Dialogue.advance()
		else:
			Dialogue.interact(region, _random_order)
	elif Dialogue.is_active():
		Dialogue.advance()


func _set_focus(p: Vector2) -> void:
	_focus_pos = p
	if _cursor_node != null:
		_cursor_node.set_focus(p)


func _create_focus_cursor() -> void:
	_cursor_layer = CanvasLayer.new()
	_cursor_layer.layer = 250   # 高于角色与对话框，始终可见
	get_tree().root.add_child(_cursor_layer)
	_cursor_node = load("res://scripts/gd/region/focus_cursor.gd").new()
	_cursor_node.name = "FocusCursor"
	_cursor_layer.add_child(_cursor_node)
	var vp := get_viewport().get_visible_rect()
	_focus_pos = vp.size * 0.5 if vp.size.x > 0 else Vector2(320, 240)
	_cursor_node.set_focus(_focus_pos)


## 键盘移动虚拟光标：WASD 与 方向键（上下左右）均可
func _process(delta: float) -> void:
	if _rhythm_mode:
		if _cursor_node != null:
			_cursor_node.visible = false
		return
	# 正在输入框打字时不抢键盘（避免打字时准星乱飘）
	var fo = get_viewport().gui_get_focus_owner()
	if fo != null and (fo is LineEdit or fo is TextEdit):
		return
	# 准星跟随鼠标位置（鼠标位置 = 准星/点击位置）
	var r := get_viewport().get_visible_rect()
	var mouse := get_viewport().get_mouse_position()
	_focus_pos = Vector2(clampf(mouse.x, 0.0, r.size.x), clampf(mouse.y, 0.0, r.size.y))
	# WASD 手动微调（在鼠标基础上，可选）
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):    dir.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):  dir.y += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):  dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): dir.x += 1
	if dir != Vector2.ZERO:
		_focus_pos += dir.normalized() * _focus_speed * delta
		_focus_pos.x = clamp(_focus_pos.x, 0.0, r.size.x)
		_focus_pos.y = clamp(_focus_pos.y, 0.0, r.size.y)
	if _cursor_node != null:
		_cursor_node.set_focus(_focus_pos)


func _region_at(canvas_pos: Vector2) -> String:
	for region_name in _regions:
		var rects: Array = _regions[region_name].get("rects", [])
		for r in rects:
			if r.size() >= 4:
				var rect := Rect2(r[0], r[1], r[2], r[3])
				if rect.has_point(canvas_pos):
					return region_name
	return ""


## 视口坐标 -> 模型局部画布坐标（画布变换含相机 + to_local，兼容任意模型缩放/位置）
func _to_canvas_space(vp_pos: Vector2) -> Vector2:
	var world = get_viewport().get_canvas_transform().affine_inverse() * vp_pos
	var local = _model.to_local(world)
	var flip = _model.get("flip_h")
	if flip:
		local.x = -local.x
	return local


## 用 Camera2D 缩放适配画布，保持模型 scale=1.0（坐标换算在 scale=1.0 时才精确）
func _fit_model_to_viewport() -> void:
	if _model == null:
		return
	var canvas = _model.get_canvas_info()
	if canvas.is_empty() != true:
		var size: Vector2 = canvas.size_in_pixels
		var vp_size := Vector2(_root.get_viewport_rect().size)
		var zoom: float = vp_size.y / max(size.x, size.y)
		_model.scale = Vector2.ONE
		_model.position = Vector2.ZERO
		var cam = _root.get_node_or_null("Camera2D")
		if cam != null:
			cam.zoom = Vector2(zoom, zoom)
		print("[RegionDetector] 适配视口: canvas=", size, " zoom=", zoom)


func _create_overlay() -> void:
	if _model == null:
		return
	_overlay = Node2D.new()
	_overlay.name = "RegionOverlay"
	_overlay.set_script(load("res://scripts/gd/region/region_overlay.gd"))
	_overlay.set("regions", _regions)
	_overlay.visible = false
	_model.add_child(_overlay)


func _create_poke() -> void:
	if _model == null:
		return
	_poke = Node2D.new()
	_poke.name = "PokeEffect"
	_poke.set_script(load("res://scripts/gd/region/poke_effect.gd"))
	_model.add_child(_poke)


func _self_test() -> void:
	if _model == null:
		return
	print("[RegionDetector] 自检: 视口中心(320,320) -> canvas ", _to_canvas_space(Vector2(320, 320)))
	print("[RegionDetector] 自检: 视口(0,0) -> canvas ", _to_canvas_space(Vector2(0, 0)))
	print("[RegionDetector] 自检: 视口(640,640) -> canvas ", _to_canvas_space(Vector2(640, 640)))
	print("[RegionDetector] 已加载区域: ", _regions.keys())


## 音游模式开关（由 RhythmGame 调用）：进入后屏蔽角色互动输入，退出恢复
func set_rhythm_mode(v: bool) -> void:
	_rhythm_mode = v
	if _cursor_node != null:
		_cursor_node.visible = not v
