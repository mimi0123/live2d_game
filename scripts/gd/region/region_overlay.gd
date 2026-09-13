extends Node2D
## 区域可视化叠加层：把 regions.json 里的区域矩形画出来，方便微调。
## 由 RegionDetector 创建为 GDCubismUserModel 的子节点，F4 切换显示。

var regions: Dictionary = {}
var colors := [
	Color(1.0, 0.3, 0.3),
	Color(0.3, 1.0, 0.3),
	Color(0.3, 0.6, 1.0),
	Color(1.0, 0.7, 0.2),
	Color(1.0, 0.3, 1.0),
	Color(0.3, 1.0, 1.0),
]

func _draw() -> void:
	var i := 0
	for region_name in regions:
		var rects: Array = regions[region_name].get("rects", [])
		var col: Color = colors[i % colors.size()]
		for r in rects:
			if r.size() >= 4:
				draw_rect(Rect2(r[0], r[1], r[2], r[3]), col, false, 4.0)
		i += 1
