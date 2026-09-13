extends Control

func _on_window_middle_click() -> void:
	visible = !visible


func _on_window_docking(enable: bool, direction: int) -> void:
	if enable:
		visible = false
	else:
		# 解除停靠时必须把 GUI 恢复可见，否则窗口滑出屏幕后永远回不来
		visible = true
