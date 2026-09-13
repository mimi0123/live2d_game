extends Control
class_name InteractionEditor

## 运行时「互动编辑器」（autoload Dialogue 在 F5 时切换可见）
##
## 功能：查看当前阶段/好感；添加/修改 阶段（含解锁分）、部位（含得分±、随机）、
##       对话行、解锁台词；保存到 user://interaction_data.json（回退 res://data/）。
## 部位下拉来自 Dialogue.list_zone_ids()：自动包含 regions.json 的区域名 +
##       模型真实命中区，所以新增身体部位只需在 regions.json 画矩形即可出现在下拉里。

var _phases_opt: OptionButton
var _zone_opt: OptionButton
var _phase_id_ed: LineEdit
var _phase_name_ed: LineEdit
var _phase_unlock_ed: SpinBox
var _zone_label_ed: LineEdit
var _zone_score_ed: SpinBox
var _zone_random_chk: CheckButton
var _line_text_ed: LineEdit
var _line_expr_ed: LineEdit
var _line_voice_ed: LineEdit
var _unlock_text_ed: LineEdit
var _unlock_expr_ed: LineEdit
var _status: Label
var _score_label: Label
var _prog_bar: ProgressBar

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	if not Dialogue.score_changed.is_connected(_on_score_changed):
		Dialogue.score_changed.connect(_on_score_changed)
	if not Dialogue.phase_changed.is_connected(_on_phase_changed):
		Dialogue.phase_changed.connect(_on_phase_changed)
	refresh()

func _build_ui() -> void:
	var panel := Panel.new()
	panel.name = "Panel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -410.0
	panel.offset_top = 8.0
	panel.offset_right = -8.0
	panel.offset_bottom = 8.0 + 560.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.modulate.a = 0.96
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 8.0; scroll.offset_top = 8.0
	scroll.offset_right = -8.0; scroll.offset_bottom = -8.0
	panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	var title := Label.new()
	title.text = "互动编辑器 (F5 关闭)"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	_score_label = Label.new()
	_score_label.text = "好感: 0   阶段: -"
	vbox.add_child(_score_label)

	_prog_bar = ProgressBar.new()
	_prog_bar.min_value = 0.0
	_prog_bar.max_value = 1.0
	_prog_bar.value = 0.0
	_prog_bar.show_percentage = true
	vbox.add_child(_prog_bar)

	vbox.add_child(_sep("阶段（打boss式解锁）"))

	var h1 := HBoxContainer.new(); vbox.add_child(h1)
	h1.add_child(_lab("id"))
	_phase_id_ed = LineEdit.new(); _phase_id_ed.placeholder_text = "如 p5"; _phase_id_ed.custom_minimum_size = Vector2(60,0); h1.add_child(_phase_id_ed)
	h1.add_child(_lab("名"))
	_phase_name_ed = LineEdit.new(); _phase_name_ed.placeholder_text = "如 终幕"; _phase_name_ed.custom_minimum_size = Vector2(90,0); h1.add_child(_phase_name_ed)
	h1.add_child(_lab("解锁分"))
	_phase_unlock_ed = SpinBox.new(); _phase_unlock_ed.min_value = 0; _phase_unlock_ed.max_value = 99999; _phase_unlock_ed.step = 10; _phase_unlock_ed.value = 0; h1.add_child(_phase_unlock_ed)

	var add_phase_btn := Button.new(); add_phase_btn.text = "添加/更新阶段"; vbox.add_child(add_phase_btn)
	add_phase_btn.pressed.connect(_on_add_phase)

	vbox.add_child(_sep("选择阶段"))
	_phases_opt = OptionButton.new(); vbox.add_child(_phases_opt)
	_phases_opt.item_selected.connect(_on_phase_selected)

	vbox.add_child(_sep("部位（点击身体区域）"))
	var h2 := HBoxContainer.new(); vbox.add_child(h2)
	h2.add_child(_lab("标签"))
	_zone_label_ed = LineEdit.new(); _zone_label_ed.placeholder_text = "如 头部"; _zone_label_ed.custom_minimum_size = Vector2(90,0); h2.add_child(_zone_label_ed)
	h2.add_child(_lab("分"))
	_zone_score_ed = SpinBox.new(); _zone_score_ed.min_value = -999; _zone_score_ed.max_value = 999; _zone_score_ed.step = 1; _zone_score_ed.value = 10; h2.add_child(_zone_score_ed)
	_zone_random_chk = CheckButton.new(); _zone_random_chk.text = "随机"; h2.add_child(_zone_random_chk)

	_zone_opt = OptionButton.new(); vbox.add_child(_zone_opt)
	var add_zone_btn := Button.new(); add_zone_btn.text = "添加/更新 选中部位"; vbox.add_child(add_zone_btn)
	add_zone_btn.pressed.connect(_on_add_zone)
	var new_zone_btn := Button.new(); new_zone_btn.text = "新建部位（用下拉里输入的新id，回车确定）"; vbox.add_child(new_zone_btn)
	new_zone_btn.pressed.connect(_on_new_zone)

	vbox.add_child(_sep("对话行（当前阶段+选中部位）"))
	_line_text_ed = LineEdit.new(); _line_text_ed.placeholder_text = "台词文本"; _line_text_ed.custom_minimum_size = Vector2(300,0); vbox.add_child(_line_text_ed)
	var h3 := HBoxContainer.new(); vbox.add_child(h3)
	h3.add_child(_lab("表情"))
	_line_expr_ed = LineEdit.new(); _line_expr_ed.placeholder_text = "SmileEyeClosed"; _line_expr_ed.custom_minimum_size = Vector2(140,0); h3.add_child(_line_expr_ed)
	h3.add_child(_lab("语音"))
	_line_voice_ed = LineEdit.new(); _line_voice_ed.placeholder_text = "留空"; _line_voice_ed.custom_minimum_size = Vector2(120,0); h3.add_child(_line_voice_ed)
	var add_line_btn := Button.new(); add_line_btn.text = "添加对话行"; vbox.add_child(add_line_btn)
	add_line_btn.pressed.connect(_on_add_line)

	vbox.add_child(_sep("阶段解锁台词"))
	_unlock_text_ed = LineEdit.new(); _unlock_text_ed.placeholder_text = "进入该阶段时说的台词"; _unlock_text_ed.custom_minimum_size = Vector2(300,0); vbox.add_child(_unlock_text_ed)
	var h4 := HBoxContainer.new(); vbox.add_child(h4)
	h4.add_child(_lab("表情"))
	_unlock_expr_ed = LineEdit.new(); _unlock_expr_ed.placeholder_text = "SmileEyeClosed"; _unlock_expr_ed.custom_minimum_size = Vector2(140,0); h4.add_child(_unlock_expr_ed)
	var add_ud_btn := Button.new(); add_ud_btn.text = "添加解锁台词"; vbox.add_child(add_ud_btn)
	add_ud_btn.pressed.connect(_on_add_unlock_line)

	vbox.add_child(_sep("数据"))
	var save_btn := Button.new(); save_btn.text = "保存 (user://interaction_data.json)"; vbox.add_child(save_btn)
	save_btn.pressed.connect(_on_save)
	var reload_btn := Button.new(); reload_btn.text = "重新加载"; vbox.add_child(reload_btn)
	reload_btn.pressed.connect(_on_reload)
	var import_btn := Button.new(); import_btn.text = "导入文本脚本 (interaction_script.txt)"; vbox.add_child(import_btn)
	import_btn.pressed.connect(_on_import)

	var imp_help := Label.new()
	imp_help.text = "导入文本脚本：把 AI 生成的 interaction_script.txt 放到 data/ 下，点这里即可批量导入（会先自动备份旧数据）。格式见该文件顶部说明。"
	imp_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(imp_help)

	_status = Label.new(); _status.text = "就绪"; _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; vbox.add_child(_status)
	var help := Label.new()
	help.text = "提示：新增身体部位请在 data/regions.json 画矩形（头/胸/手/腿/衣服…），保存后重开本编辑器即出现在下拉。F4 可显示区域调试框。"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(help)

func _lab(t: String) -> Label:
	var l := Label.new(); l.text = t; return l

func _sep(t: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	var lab := Label.new(); lab.text = t; lab.add_theme_font_size_override("font_size", 14)
	box.add_child(lab)
	box.add_child(HSeparator.new())
	return box

# ============================ 刷新 ============================
func refresh() -> void:
	if Dialogue == null:
		return
	var phases: Array = _read_phases()
	_phases_opt.clear()
	for i in range(phases.size()):
		var ph: Dictionary = phases[i]
		var txt = "%d. %s (解锁%d)" % [i + 1, ph.get("name", "?"), int(ph.get("unlock_score", 0))]
		_phases_opt.add_item(txt)
		_phases_opt.set_item_metadata(_phases_opt.get_item_count() - 1, ph.get("id", ""))
	if _phases_opt.item_count > 0:
		_phases_opt.select(mini(Dialogue.get_phase_index(), _phases_opt.item_count - 1))

	_zone_opt.clear()
	for zid in Dialogue.list_zone_ids():
		_zone_opt.add_item(zid)
	_on_phase_selected(_phases_opt.get_selected())
	_update_status("已刷新")

func _read_phases() -> Array:
	var parsed = _read_saved()
	if parsed is Dictionary and parsed.has("phases"):
		return parsed["phases"]
	return []

func _read_saved() -> Variant:
	var path := "user://interaction_data.json"
	var txt := ""
	if FileAccess.file_exists(path):
		txt = FileAccess.get_file_as_string(path)
	elif FileAccess.file_exists("res://data/interaction_data.json"):
		txt = FileAccess.get_file_as_string("res://data/interaction_data.json")
	if txt == "":
		return {}
	return JSON.parse_string(txt)

# ============================ 处理器 ============================
func _on_phase_selected(idx: int) -> void:
	if idx < 0:
		return
	var pid = _phases_opt.get_item_metadata(idx)
	_status.text = "当前编辑阶段: " + str(pid)

func _on_add_phase() -> void:
	var pid = _phase_id_ed.text.strip_edges()
	var nm = _phase_name_ed.text.strip_edges()
	var unlock = int(_phase_unlock_ed.value)
	if pid == "":
		pid = "p%d" % (Dialogue.get_phase_count() + 1)
	if nm == "":
		nm = pid
	Dialogue.add_phase(pid, nm, unlock)
	refresh()
	_update_status("已添加/更新阶段 %s" % pid)

func _on_add_zone() -> void:
	var idx = _phases_opt.get_selected()
	if idx < 0:
		_update_status("请先选择一个阶段"); return
	var pid = _phases_opt.get_item_metadata(idx)
	var zid = _zone_opt.get_item_text(_zone_opt.get_selected())
	if zid == "":
		_update_status("请先在部位下拉选一个（或先用『新建部位』）"); return
	var label = _zone_label_ed.text.strip_edges()
	if label == "":
		label = zid
	Dialogue.add_zone(pid, zid, label, int(_zone_score_ed.value), _zone_random_chk.button_pressed)
	refresh()
	_update_status("已更新部位 %s 得分=%d" % [zid, int(_zone_score_ed.value)])

func _on_new_zone() -> void:
	var idx = _phases_opt.get_selected()
	if idx < 0:
		_update_status("请先选择一个阶段"); return
	var pid = _phases_opt.get_item_metadata(idx)
	var zid = _zone_opt.get_item_text(_zone_opt.get_selected())
	if zid == "":
		_update_status("请先在部位下拉输入/选中新id"); return
	Dialogue.add_zone(pid, zid, zid, 0, false)
	refresh()
	_update_status("已新建部位 %s（请再设标签/得分）" % zid)

func _on_add_line() -> void:
	var idx = _phases_opt.get_selected()
	if idx < 0:
		_update_status("请先选择一个阶段"); return
	var pid = _phases_opt.get_item_metadata(idx)
	var zid = _zone_opt.get_item_text(_zone_opt.get_selected())
	var t = _line_text_ed.text.strip_edges()
	if t == "":
		_update_status("台词文本不能为空"); return
	Dialogue.add_zone_line(pid, zid, t, _line_expr_ed.text.strip_edges(), _line_voice_ed.text.strip_edges())
	_line_text_ed.text = ""
	_update_status("已添加对话行 -> %s" % zid)

func _on_add_unlock_line() -> void:
	var idx = _phases_opt.get_selected()
	if idx < 0:
		_update_status("请先选择一个阶段"); return
	var pid = _phases_opt.get_item_metadata(idx)
	var t = _unlock_text_ed.text.strip_edges()
	if t == "":
		_update_status("解锁台词文本不能为空"); return
	Dialogue.add_unlock_line(pid, t, _unlock_expr_ed.text.strip_edges())
	_unlock_text_ed.text = ""
	_update_status("已添加解锁台词 -> %s" % pid)

func _on_save() -> void:
	Dialogue.save_data()
	_update_status("已保存")

func _on_reload() -> void:
	Dialogue.reload_data()
	refresh()
	_update_status("已重新加载")

func _on_import() -> void:
	var ok := Dialogue.import_text_script()
	if ok:
		refresh()
		_update_status("★ 文本脚本已批量导入（旧数据已自动备份）")
	else:
		_update_status("导入失败：没找到 data/interaction_script.txt 或文件无阶段")

# ============================ 信号 ============================
func _on_score_changed(_total: int) -> void:
	_update_status("")

func _on_phase_changed(_idx: int, _phase: Dictionary) -> void:
	_update_status("★ 解锁阶段: %s" % _phase.get("name", ""))
	refresh()

func _update_status(msg: String) -> void:
	if Dialogue == null:
		return
	_score_label.text = "好感: %d   阶段: %d/%d (%s)" % [
		Dialogue.get_score(), Dialogue.get_phase_index() + 1, Dialogue.get_phase_count(),
		Dialogue.get_current_phase().get("name", "?")]
	_prog_bar.value = Dialogue.get_progress()
	if msg != "" and _status != null:
		_status.text = msg
