extends CanvasLayer
## 右上角悬浮设置区（autoload: HoverPanel）
## 平时自动隐藏/堆积在右上角，鼠标移到右上角区域才显示；内容自适应撑开。
## 状态按钮 + 对话框透明度；形变设置请在 F2（DeformMenu）里调。

const ZONE_SIZE := Vector2(230, 360)
const BOX_TOP := 6.0

var _ui: Control
var _box: VBoxContainer
var _pause_btn: Button
var _op_box_slider: HSlider
var _op_text_slider: HSlider
var _expanded: bool = false
var _scene = null


func _ready() -> void:
	layer = 150
	_ui = Control.new()
	_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ui)
	_build_ui()
	_setup.call_deferred()


func _build_ui() -> void:
	_box = VBoxContainer.new()
	_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_box.offset_right = -8.0
	_box.offset_top = BOX_TOP
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.visible = false
	_ui.add_child(_box)

	_pause_btn = Button.new()
	_pause_btn.text = "暂停"
	_pause_btn.pressed.connect(_on_pause)
	_box.add_child(_pause_btn)

	_box.add_child(_make_label("—— 状态 ——"))
	var stick_btn := Button.new()
	stick_btn.toggle_mode = true
	stick_btn.text = "置顶"
	stick_btn.pressed.connect(func():
		get_tree().root.always_on_top = stick_btn.button_pressed
		_save_common("stick", stick_btn.button_pressed))
	_box.add_child(stick_btn)

	var stroll_btn := Button.new()
	stroll_btn.toggle_mode = true
	stroll_btn.text = "散步"
	stroll_btn.pressed.connect(func():
		var rm = _rand_move()
		if rm != null:
			rm.enable = stroll_btn.button_pressed
			_save_common("stroll", stroll_btn.button_pressed))
	_box.add_child(stroll_btn)

	var follow_btn := Button.new()
	follow_btn.toggle_mode = true
	follow_btn.text = "跟随鼠标"
	follow_btn.pressed.connect(func():
		var mf = _mouse_follow()
		if mf != null:
			mf.enable = follow_btn.button_pressed
			_save_common("follow_mouse", follow_btn.button_pressed))
	_box.add_child(follow_btn)

	var deform_hint := Button.new()
	deform_hint.text = "形变设置 (F2)"
	deform_hint.pressed.connect(func(): _toggle_deform_menu())
	_box.add_child(deform_hint)

	_box.add_child(_make_label("—— 对话框 ——"))
	_op_box_slider = _make_slider("对话透明度", 0.2, 1.0, 0.05, 1.0, func(v): Dialogue.set_box_opacity(v))
	_op_text_slider = _make_slider("文字透明度", 0.2, 1.0, 0.05, 1.0, func(v): Dialogue.set_text_opacity(v))

	var exit_btn := Button.new()
	exit_btn.text = "退出"
	exit_btn.pressed.connect(func(): get_tree().quit())
	_box.add_child(exit_btn)

	_resize_box()


func _toggle_deform_menu() -> void:
	var menu = get_node_or_null("/root/DeformMenu")
	if menu != null and menu.has_method("_toggle"):
		menu._toggle()


func _make_label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.modulate.a = 0.6
	return l


func _make_slider(label: String, mn: float, mx: float, step: float, val: float, cb: Callable) -> HSlider:
	var row := HBoxContainer.new()
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.value = val
	s.custom_minimum_size = Vector2(110.0, 0.0)
	row.add_child(s)
	var vlabel := Label.new()
	vlabel.custom_minimum_size = Vector2(46.0, 0.0)
	row.add_child(vlabel)
	var lab := Label.new()
	lab.text = label
	lab.modulate.a = 0.7
	row.add_child(lab)
	_box.add_child(row)
	s.value_changed.connect(func(v):
		cb.call(v)
		vlabel.text = _fmt_slider(v))
	vlabel.text = _fmt_slider(val)
	return s


func _fmt_slider(v: float) -> String:
	if v <= 1.0 + 0.001:
		return "%d%%" % int(round(v * 100.0))
	return "%.2f" % v


func _resize_box() -> void:
	if _box != null:
		_box.size = _box.get_combined_minimum_size()


func _setup() -> void:
	var scene = get_tree().current_scene
	if scene == null:
		_setup.call_deferred()
		return
	_scene = scene
	if _box == null:
		return
	for k in _box.get_children():
		if k is Button and k.toggle_mode:
			match k.text:
				"置顶": k.button_pressed = get_tree().root.always_on_top
				"散步":
					var rm = _rand_move()
					if rm != null:
						k.button_pressed = rm.enable
				"跟随鼠标":
					var mf = _mouse_follow()
					if mf != null:
						k.button_pressed = mf.enable
	if _op_box_slider != null: _op_box_slider.value = Dialogue.get_box_opacity()
	if _op_text_slider != null: _op_text_slider.value = Dialogue.get_text_opacity()
	_resize_box()


func _rand_move():
	return _scene.get_node_or_null("GDCubismUserModel/Animation/EffectRandMove") if _scene else null


func _mouse_follow():
	return _scene.get_node_or_null("GDCubismUserModel/Animation/EffectMouseFollow") if _scene else null


func _save_common(key: String, value: bool) -> void:
	var config = get_node_or_null("/root/Config")
	if config != null and config.has_method("on_common_config_change"):
		config.on_common_config_change(key, value)


func _on_pause() -> void:
	var paused: bool = Dialogue.toggle_pause()
	if _pause_btn != null:
		_pause_btn.text = "继续" if paused else "暂停"


func _process(_delta: float) -> void:
	if _box == null:
		return
	var size := get_viewport().get_visible_rect().size
	var zone := Rect2(size.x - ZONE_SIZE.x, 0.0, ZONE_SIZE.x, ZONE_SIZE.y)
	var m := _ui.get_global_mouse_position()
	var in_zone := zone.has_point(m)
	if in_zone and not _expanded:
		_expanded = true
		_box.visible = true
		_resize_box()
	elif not in_zone and _expanded:
		_expanded = false
		_box.visible = false
