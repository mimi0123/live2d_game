extends Node
## GDScript 替身：顶替原工程的 C# 版 MouseTracker。
## 原工程用 C# 获取「屏幕全局坐标」的鼠标位置（桌宠窗口跟随需要屏显坐标，
## 而非窗口内坐标）。当前 Godot 为标准版（无 .NET），无法编译 C#，
## 故用 DisplayServer 内建 API 等价实现，接口名保持原样，调用方无需改动。

## 返回整数向量：调用方 mouse_follow.gd 会拿它和窗口位置（Vector2i）相减，
## Godot 4.7 不允许 Vector2i 与 Vector2 直接运算，故统一用 Vector2i。
func GetMousePositionGlobal() -> Vector2i:
	return DisplayServer.mouse_get_position()

func GetMousePosition() -> Vector2i:
	return DisplayServer.mouse_get_position()
