extends Node
## GDScript 替身：顶替原工程的 C# 版 WindowManager。
## GetSystemMetrics 取主显示器尺寸（原 C# 走 Win32 API，78=屏宽、79=屏高）。
## IsOtherAppFullscreen 需要枚举系统窗口，标准版无法实现，恒定返回 false
## 是安全降级——原工程本身也把该功能注释掉了（标注为 BUG）。

const SM_CXSCREEN := 78
const SM_CYSCREEN := 79

func GetSystemMetrics(index: int) -> int:
	var screen := DisplayServer.window_get_current_screen()
	var size := DisplayServer.screen_get_size(screen)
	if index == SM_CYSCREEN:
		return int(size.y)
	return int(size.x)

func IsOtherAppFullscreen() -> bool:
	return false
