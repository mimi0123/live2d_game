extends Control

var box: Panel
var name_label: Label
var text_label: Label
var indicator_label: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	box = Panel.new()
	box.name = "Box"
	box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	box.offset_top = -190.0
	box.offset_left = 16.0
	box.offset_right = -16.0
	box.offset_bottom = -16.0
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.visible = false
	add_child(box)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 14.0
	vbox.offset_top = 12.0
	vbox.offset_right = -14.0
	vbox.offset_bottom = -12.0
	box.add_child(vbox)

	name_label = Label.new()
	name_label.text = "名字"
	vbox.add_child(name_label)

	text_label = Label.new()
	text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(text_label)

	indicator_label = Label.new()
	indicator_label.text = "▼  点击继续"
	indicator_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vbox.add_child(indicator_label)

	box.gui_input.connect(_on_box_clicked)
	Dialogue.set_box(self)

	# 透明度现在由右上角悬浮设置区控制，这里只负责应用（self_modulate 独立控制）
	sync_opacity(Dialogue.get_box_opacity(), Dialogue.get_text_opacity())

func _on_box_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			Dialogue.advance()

func set_speaker(n: String) -> void:
	name_label.text = n

func set_text(t: String) -> void:
	text_label.text = t

func sync_opacity(box_a: float, text_a: float) -> void:
	# self_modulate 只作用于自身：面板透明度与文字透明度互相独立
	box.self_modulate.a = box_a
	name_label.self_modulate.a = text_a
	text_label.self_modulate.a = text_a
	indicator_label.self_modulate.a = text_a

func show_box() -> void:
	box.visible = true

func hide_box() -> void:
	box.visible = false
