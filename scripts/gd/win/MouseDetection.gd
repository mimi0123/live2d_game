extends Node
## GDScript 替身：顶替原工程的 C# 版 MouseDetection。
## 判定鼠标是否悬停在本窗口上方，并在「从外部进入窗口」的那一刻发出
## MouseEntered 信号（原工程用它统计抚摸次数，摸多了角色会换表情）。

signal MouseEntered

var mouse_hovered: bool = false

func _process(_delta: float) -> void:
	var win_pos := DisplayServer.window_get_position()
	var win_size := DisplayServer.window_get_size()
	var rect := Rect2(win_pos, win_size)
	var inside: bool = rect.has_point(DisplayServer.mouse_get_position())
	if inside and not mouse_hovered:
		MouseEntered.emit()
	mouse_hovered = inside
