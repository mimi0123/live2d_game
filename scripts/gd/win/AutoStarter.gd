extends Node
## GDScript 替身：顶替原工程的 C# 版 AutoStarter。
## 开机自启需要读写 Windows 注册表，标准版 Godot 无 .NET，这里做安全空实现：
## 一律报告「未开启」，开关操作只打印提示，不影响游戏本体运行。
## 若日后确实需要此功能，再安装 Godot .NET 版并换回 C# 版本即可。

func IsAutoStartEnabled(_app_name: String) -> bool:
	return false

func EnableAutoStart(_app_name: String) -> void:
	print("[AutoStarter] 开机自启需要 Godot .NET 版，当前为标准版，已跳过。")

func DisableAutoStart(_app_name: String) -> void:
	print("[AutoStarter] 开机自启需要 Godot .NET 版，当前为标准版，已跳过。")
