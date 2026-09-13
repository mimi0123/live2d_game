extends Node
# 无头逻辑测试：编译检查脚本 + 验证阶段/好感引擎
# 作为场景运行: engine\Godot.exe --headless --path . res://test_scene.tscn

func _ready() -> void:
	var failures: Array = []
	var log: Array = []

	for path in [
		"res://scripts/gd/dialogue/dialogue_manager.gd",
		"res://scripts/gd/ui/dialogue_box.gd",
		"res://scripts/gd/ui/interact_editor.gd",
		"res://scripts/gd/anim/touch.gd",
		"res://scripts/gd/anim/hit_area_handler.gd",
		"res://scripts/gd/anim/anim_controller.gd",
		"res://scripts/gd/region/region_detector.gd",
	]:
		var scr = load(path)
		if scr == null:
			failures.append("编译失败: " + path)
			log.append("FAIL 编译: " + path)
		else:
			log.append("OK   编译: " + path)

	var D = get_node_or_null("/root/Dialogue")
	if D == null:
		log.append("ERROR: 无法取得 Dialogue 实例")
		_print_result(false, log, failures)
		get_tree().quit(1)
		return

	if FileAccess.file_exists("user://interaction_data.json"):
		DirAccess.remove_absolute("user://interaction_data.json")
	D.reload_data()
	D.total_score = 0
	D.current_phase_index = 0

	D.interact("头")
	_assert(D.get_score() == 10, "头+10 -> score=%d" % D.get_score(), failures, log)
	D.interact("胸")
	_assert(D.get_score() == 2, "胸-8 -> score=%d" % D.get_score(), failures, log)
	_assert(D.get_phase_index() == 0, "仍在 p1", failures, log)

	for i in range(40):
		D.interact("头")
	_assert(D.get_phase_index() == 3, "应解锁到 p4 -> idx=%d" % D.get_phase_index(), failures, log)
	_assert(D.get_score() > 400, "总分应随阶段加成超过400 -> %d" % D.get_score(), failures, log)
	log.append("最终阶段: %s 总分=%d" % [D.get_current_phase().get("name", "?"), D.get_score()])

	var before = D.get_score()
	D.interact("不存在的部位XYZ")
	_assert(D.get_score() == before, "未知部位不应改变分数", failures, log)

	D.total_score = 0
	D.current_phase_index = 0
	D.add_phase("ptest", "测试阶段", 999999)
	var phases = _read_json("user://interaction_data.json")
	var has_ptest = false
	for p in phases.get("phases", []):
		if p.get("id") == "ptest":
			has_ptest = true
	_assert(has_ptest, "add_phase 应写入 ptest", failures, log)

	D.add_zone("ptest", "测试区", "测试区标签", -5, false)
	D.add_zone_line("ptest", "测试区", "测试台词", "Doubt", "")
	var phases2 = _read_json("user://interaction_data.json")
	var zone_ok = false
	for p in phases2.get("phases", []):
		if p.get("id") == "ptest":
			var z = p.get("zones", {}).get("测试区", {})
			if z.get("score") == -5 and z.get("lines", []).size() == 1:
				zone_ok = true
	_assert(zone_ok, "add_zone/add_zone_line 应生效", failures, log)

	D.total_score = 40
	D.current_phase_index = 0
	var prog = D.get_progress()
	_assert(abs(prog - 0.5) < 0.01, "进度应为0.5 -> %f" % prog, failures, log)

	if FileAccess.file_exists("user://interaction_data.json"):
		DirAccess.remove_absolute("user://interaction_data.json")
	if FileAccess.file_exists("user://_test_interaction_out.json"):
		DirAccess.remove_absolute("user://_test_interaction_out.json")

	_print_result(failures.is_empty(), log, failures)
	get_tree().quit(0 if failures.is_empty() else 1)

func _assert(cond: bool, msg: String, failures: Array, log: Array) -> void:
	if cond:
		log.append("PASS " + msg)
	else:
		failures.append(msg)
		log.append("FAIL " + msg)

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var t = FileAccess.get_file_as_string(path)
	var p = JSON.parse_string(t)
	return p if p is Dictionary else {}

func _print_result(ok: bool, log: Array, failures: Array = []) -> void:
	print("==== 互动引擎无头测试 ====")
	for l in log:
		print(l)
	print("==== 结果: " + ("PASS" if ok else "FAIL"))
	if not ok:
		print("失败项: ", failures)
