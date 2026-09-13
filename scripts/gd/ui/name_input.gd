extends Control
## 开场取名弹窗：玩家可以修改角色名字（autoload Dialogue 的 get/set_speaker_name）

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -180.0
	panel.offset_right = 180.0
	panel.offset_top = -90.0
	panel.offset_bottom = 90.0
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "给她起个名字吧"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "不改的话直接点确定"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate.a = 0.6
	vbox.add_child(hint)

	var line_edit := LineEdit.new()
	line_edit.placeholder_text = "输入角色名字"
	line_edit.text = Dialogue.get_speaker_name()
	vbox.add_child(line_edit)

	var btn := Button.new()
	btn.text = "确定"
	btn.pressed.connect(func():
		var n := line_edit.text.strip_edges()
		if n != "":
			Dialogue.set_speaker_name(n)
		queue_free())
	vbox.add_child(btn)

	line_edit.grab_focus()
	line_edit.text_submitted.connect(func(_t): btn.pressed.emit())
