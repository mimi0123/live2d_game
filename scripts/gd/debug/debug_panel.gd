extends CanvasLayer
## Live2D 模型调试面板
## 功能：切模型、切表情、切动作、命中区域显示、台词编辑器（添加/删除台词+语音）
## 快捷键 F3 显示/隐藏

const DIALOGUE_PATH := "res://data/dialogue.json"
const DEFAULT_SPEAKER := "MO"

## 表情列表（与 anim/anim_tree/main.tres 里 Expression 过渡节点的输入名一致）
const EXPRESSIONS := [
	"Idle", "SmileEyeClosed", "Sullen", "Silence", "Amaze", "Bag",
	"Doubt", "Dull", "EyeStar", "Sunglasses", "DockPopAngry",
]

## 动作列表（MotonTransition 的输入名）
const MOTIONS := ["Idle", "Run"]

## 可切换的模型（按钮名 -> model3.json 路径）
const MODELS := {
	"Doro": "res://models/Doro/Doro.model3.json",
	"MO": "res://models/MO/MO.model3.json",
	"欧珀海妖": "res://models/欧珀海妖/欧珀海妖.model3.json",
}

## 基准画布尺寸（Doro 是 2048，其它模型按此归一化缩放）
const BASE_CANVAS := 2048.0

var _model = null            # GDCubismUserModel 节点
var _controller = null       # GDCubismUserModel/Animation 节点（挂 AnimationController 脚本）
var _hit_handler = null      # GDCubismUserModel/HitAreaHandler 节点
var _hit_label: Label = null
var _panel: Control = null

# 台词编辑器状态
var _edit_region: String = "头"
var _edit_list: VBoxContainer = null
var _edit_text: LineEdit = null
var _edit_voice: LineEdit = null


func _ready() -> void:
	layer = 200
	_build_ui()
	_setup.call_deferred()


func _setup() -> void:
	var scene = get_tree().current_scene
	if scene == null:
		_setup.call_deferred()
		return
	_model = scene.get_node_or_null("GDCubismUserModel")
	_controller = scene.get_node_or_null("GDCubismUserModel/Animation")
	_hit_handler = scene.get_node_or_null("GDCubismUserModel/HitAreaHandler")
	if _hit_handler != null and _hit_handler.has_signal("hit"):
		if not _hit_handler.is_connected("hit", Callable(self, "_on_hit")):
			_hit_handler.connect("hit", Callable(self, "_on_hit"))
	_refresh_lines()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.position = Vector2(8, 8)
	_panel.visible = false   # 默认隐藏，按 F3 才显示（避免每次启动直接弹出）
	add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320, 560)
	_panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(vbox)

	var title := Label.new()
	title.text = "调试面板  (F3 开关)"
	vbox.add_child(title)

	vbox.add_child(_make_label("—— 模型 ——"))
	var model_row := HBoxContainer.new()
	vbox.add_child(model_row)
	for mname in MODELS:
		model_row.add_child(_make_button(mname, _switch_model.bind(MODELS[mname])))

	vbox.add_child(_make_label("—— 表情 ——"))
	var exp_grid := GridContainer.new()
	exp_grid.columns = 3
	vbox.add_child(exp_grid)
	for e in EXPRESSIONS:
		exp_grid.add_child(_make_button(e, _set_expression.bind(e)))

	vbox.add_child(_make_label("—— 动作 ——"))
	var mot_row := HBoxContainer.new()
	vbox.add_child(mot_row)
	for m in MOTIONS:
		mot_row.add_child(_make_button(m, _set_motion.bind(m)))
	mot_row.add_child(_make_button("重置", _reset))

	_hit_label = _make_label("命中区域: (无)")
	vbox.add_child(_hit_label)

	vbox.add_child(_make_label("—— 台词编辑 ——"))
	_build_dialogue_editor(vbox)


func _build_dialogue_editor(vbox: VBoxContainer) -> void:
	var region_row := HBoxContainer.new()
	vbox.add_child(region_row)
	for rn in ["头", "胸", "手", "腿", "衣服"]:
		region_row.add_child(_make_button(rn, _select_edit_region.bind(rn)))

	_edit_list = VBoxContainer.new()
	vbox.add_child(_edit_list)

	var add_row := HBoxContainer.new()
	vbox.add_child(add_row)
	_edit_text = LineEdit.new()
	_edit_text.placeholder_text = "输入台词文本…"
	_edit_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_row.add_child(_edit_text)
	var add_btn := Button.new()
	add_btn.text = "添加"
	add_btn.pressed.connect(_add_line)
	add_row.add_child(add_btn)

	var voice_row := HBoxContainer.new()
	vbox.add_child(voice_row)
	_edit_voice = LineEdit.new()
	_edit_voice.placeholder_text = "语音路径(可选, 如 res://audio/head1.ogg)"
	_edit_voice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	voice_row.add_child(_edit_voice)
	var test_btn := Button.new()
	test_btn.text = "试播"
	test_btn.pressed.connect(_test_play)
	voice_row.add_child(test_btn)

	var random_row := HBoxContainer.new()
	vbox.add_child(random_row)
	var random_btn := Button.new()
	random_btn.text = "随机语序: 关"
	random_btn.toggled.connect(func(on): _set_random_order(on))
	random_btn.toggle_mode = true
	random_btn.pressed.connect(func(): random_btn.text = "随机语序: 开" if random_btn.button_pressed else "随机语序: 关")
	random_row.add_child(random_btn)


func _select_edit_region(name: String) -> void:
	_edit_region = name
	_refresh_lines()


func _refresh_lines() -> void:
	if _edit_list == null:
		return
	for c in _edit_list.get_children():
		c.queue_free()
	var data := _load_dialogue()
	var lines: Array = data.get(_edit_region, [])
	if lines.is_empty():
		_edit_list.add_child(_make_label("（该区域还没有台词）"))
	for i in lines.size():
		var line: Dictionary = lines[i]
		var row := HBoxContainer.new()
		var lab := Label.new()
		lab.text = "%d. %s" % [i + 1, line.get("text", "")]
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lab)
		if line.get("voice", "") != "":
			row.add_child(_make_label("[声]"))
		var del := Button.new()
		del.text = "删"
		del.pressed.connect(_remove_line.bind(i))
		row.add_child(del)
		_edit_list.add_child(row)


func _add_line() -> void:
	var data := _load_dialogue()
	var lines: Array = data.get(_edit_region, [])
	lines.append({
		"name": data.get("speaker", DEFAULT_SPEAKER),
		"text": _edit_text.text,
		"expr": "",
		"voice": _edit_voice.text,
	})
	data[_edit_region] = lines
	_save_dialogue(data)
	_edit_text.text = ""
	_edit_voice.text = ""
	_refresh_lines()


func _remove_line(index: int) -> void:
	var data := _load_dialogue()
	var lines: Array = data.get(_edit_region, [])
	if index >= 0 and index < lines.size():
		lines.remove_at(index)
		data[_edit_region] = lines
		_save_dialogue(data)
		_refresh_lines()


func _test_play() -> void:
	Dialogue.say(_edit_region)


func _set_random_order(on: bool) -> void:
	var f := FileAccess.open("res://data/regions.json", FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		parsed["random_order"] = on
		var w := FileAccess.open("res://data/regions.json", FileAccess.WRITE)
		if w != null:
			w.store_string(JSON.stringify(parsed, "\t"))
			w.close()


func _load_dialogue() -> Dictionary:
	if FileAccess.file_exists(DIALOGUE_PATH):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(DIALOGUE_PATH))
		if parsed is Dictionary:
			return parsed
	return {"speaker": DEFAULT_SPEAKER, "default": []}


func _save_dialogue(data: Dictionary) -> void:
	var f := FileAccess.open(DIALOGUE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
	Dialogue.reload_data()
	_refresh_lines()


func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _make_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b


func _switch_model(path: String) -> void:
	if _model == null:
		return
	_model.assets = path
	# 用 Camera2D 缩放适配新模型画布（保持模型 scale=1.0，坐标换算才精确）
	var canvas = _model.get_canvas_info()
	if canvas.is_empty() != true:
		var size: Vector2 = canvas.size_in_pixels
		var vp_size := Vector2(get_viewport().get_visible_rect().size)
		var zoom: float = vp_size.y / max(size.x, size.y)
		_model.scale = Vector2.ONE
		_model.position = Vector2.ZERO
		var cam = get_tree().current_scene.get_node_or_null("Camera2D")
		if cam != null:
			cam.zoom = Vector2(zoom, zoom)


func _set_expression(e: String) -> void:
	if _controller != null and _controller.has_method("set_expression"):
		_controller.set_expression(e)


func _set_motion(m: String) -> void:
	if _controller == null:
		return
	if m == "Idle" and _controller.has_method("idle"):
		_controller.idle()
	elif m == "Run" and _controller.has_method("run"):
		_controller.run()


func _reset() -> void:
	_set_expression("Idle")
	_set_motion("Idle")


func _on_hit(id, button_id) -> void:
	if _hit_label != null:
		_hit_label.text = "命中区域: " + str(id)


func _process(_delta: float) -> void:
	if _hit_handler != null and _hit_label != null:
		var area = _hit_handler.get("current_area")
		if area != null and area != "":
			_hit_label.text = "命中区域: " + str(area)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		if _panel != null:
			_panel.visible = not _panel.visible
		get_viewport().set_input_as_handled()
