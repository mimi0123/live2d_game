extends CanvasLayer
## 形变设置菜单（autoload: DeformMenu，F2 开关）
## 用 +/— 按钮 + 取色器调整：形变幅度/大小/透明度/明暗颜色/最大拖拽距离/时间/笔刷文件夹/贴图

const MAG_STEP := 0.005
const RADIUS_STEP := 0.02
const SHADE_STEP := 0.05
const DIST_STEP := 0.05
const TIME_STEP := 0.25

var _panel: Control
var _mag_val: Label
var _radius_val: Label
var _shade_val: Label
var _dist_val: Label
var _time_val: Label
var _deform_btn: Button
var _map_btn: Button
var _map_label: Label
var _dark_picker: ColorPickerButton
var _bright_picker: ColorPickerButton
var _dir_edit: LineEdit


func _ready() -> void:
	layer = 190
	_panel = PanelContainer.new()
	_panel.position = Vector2(8, 8)
	_panel.visible = false
	add_child(_panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_panel.add_child(vbox)

	vbox.add_child(_make_label("形变设置  (F2 关闭)"))

	_deform_btn = Button.new()
	_deform_btn.toggle_mode = true
	_deform_btn.text = "触碰变形"
	_deform_btn.button_pressed = ScreenDeform.enabled
	_deform_btn.pressed.connect(func():
		var on = ScreenDeform.toggle_enabled()
		_deform_btn.button_pressed = on)
	vbox.add_child(_deform_btn)

	# 形变幅度
	vbox.add_child(_make_label("形变幅度"))
	_mag_val = _make_pm_row(vbox, MAG_STEP, 0.0, 0.08,
		func(): return ScreenDeform.mag,
		func(v): ScreenDeform.set_mag(v))

	# 形变大小
	vbox.add_child(_make_label("形变大小"))
	_radius_val = _make_pm_row(vbox, RADIUS_STEP, 0.02, 0.30,
		func(): return ScreenDeform.radius,
		func(v): ScreenDeform.set_radius(v))

	# 透明度
	vbox.add_child(_make_label("变色强度/透明度"))
	_shade_val = _make_pm_row(vbox, SHADE_STEP, 0.0, 1.0,
		func(): return ScreenDeform.shade,
		func(v): ScreenDeform.set_shade(v))

	# 明暗颜色（吸色）
	vbox.add_child(_make_label("左键暗色"))
	_dark_picker = _make_picker(ScreenDeform.dark_color, func(c): ScreenDeform.set_dark_color(c))
	vbox.add_child(_dark_picker)
	vbox.add_child(_make_label("右键亮色"))
	_bright_picker = _make_picker(ScreenDeform.bright_color, func(c): ScreenDeform.set_bright_color(c))
	vbox.add_child(_bright_picker)

	# 最大拖拽距离(占头长比例) / 拖拽时长(按住上限)
	vbox.add_child(_make_label("最大拖拽距离(占头长比)"))
	_dist_val = _make_pm_row(vbox, DIST_STEP, 0.05, 1.0,
		func(): return ScreenDeform.max_dist,
		func(v): ScreenDeform.set_max_dist(v))
	vbox.add_child(_make_label("（1.0 = 正好一头长，随缩放自动变）"))
	vbox.add_child(_make_label("拖拽时长(按住上限)"))
	_time_val = _make_pm_row(vbox, TIME_STEP, 0.1, 6.0,
		func(): return ScreenDeform.drag_time,
		func(v): ScreenDeform.set_drag_time(v))

	# 笔刷文件夹
	vbox.add_child(_make_label("笔刷文件夹"))
	_dir_edit = LineEdit.new()
	_dir_edit.text = ScreenDeform.get_brush_dir()
	_dir_edit.text_submitted.connect(func(t):
		ScreenDeform.set_brush_dir(t)
		_refresh())
	var dir_row := HBoxContainer.new()
	dir_row.add_child(_dir_edit)
	var reload_btn := Button.new()
	reload_btn.text = "重载"
	reload_btn.pressed.connect(func():
		ScreenDeform.set_brush_dir(_dir_edit.text))
	dir_row.add_child(reload_btn)
	vbox.add_child(dir_row)

	# 贴图
	vbox.add_child(_make_label("—— 贴图 ——"))
	_map_btn = Button.new()
	_map_btn.toggle_mode = true
	_map_btn.text = "贴图形变"
	_map_btn.button_pressed = ScreenDeform.use_map
	_map_btn.pressed.connect(func():
		var on = ScreenDeform.toggle_use_map()
		_map_btn.button_pressed = on)
	vbox.add_child(_map_btn)
	var map_row := HBoxContainer.new()
	_map_label = _make_label("")
	_map_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_row.add_child(_map_label)
	map_row.add_child(_make_btn("下一个贴图", func():
		ScreenDeform.next_map()
		_refresh()))
	vbox.add_child(map_row)

	_refresh()


func _make_label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _make_btn(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	return b


func _make_picker(c: Color, cb: Callable) -> ColorPickerButton:
	var p := ColorPickerButton.new()
	p.color = c
	p.color_changed.connect(cb)
	return p


func _make_pm_row(vbox: VBoxContainer, step: float, mn: float, mx: float, getv: Callable, setv: Callable) -> Label:
	var row := HBoxContainer.new()
	row.add_child(_make_btn("-", func():
		setv.call(max(mn, getv.call() - step))
		_refresh()))
	var val := _make_label("0.000")
	row.add_child(val)
	row.add_child(_make_btn("+", func():
		setv.call(min(mx, getv.call() + step))
		_refresh()))
	vbox.add_child(row)
	return val


func _refresh() -> void:
	if _mag_val != null: _mag_val.text = "%.3f" % ScreenDeform.mag
	if _radius_val != null: _radius_val.text = "%.3f" % ScreenDeform.radius
	if _shade_val != null: _shade_val.text = "%d%%" % int(round(ScreenDeform.shade * 100.0))
	if _dist_val != null: _dist_val.text = "%.2f" % ScreenDeform.max_dist
	if _time_val != null: _time_val.text = "%.2fs" % ScreenDeform.drag_time
	if _map_label != null: _map_label.text = ScreenDeform.get_current_map_name()
	if _deform_btn != null: _deform_btn.button_pressed = ScreenDeform.enabled
	if _map_btn != null: _map_btn.button_pressed = ScreenDeform.use_map
	if _dark_picker != null: _dark_picker.color = ScreenDeform.dark_color
	if _bright_picker != null: _bright_picker.color = ScreenDeform.bright_color


func _toggle() -> void:
	if _panel != null:
		_panel.visible = not _panel.visible
		_refresh()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2:
		if _panel != null:
			_panel.visible = not _panel.visible
			_refresh()
		get_viewport().set_input_as_handled()
