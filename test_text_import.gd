extends Node
# 无头测试：纯文本作者脚本 解析器 / 导入器 正确性
# 运行: engine\Godot.exe --headless --path . res://test_text_scene.tscn

func _ready() -> void:
	var failures: Array = []
	var log: Array = []

	for path in [
		"res://scripts/gd/dialogue/dialogue_manager.gd",
		"res://scripts/gd/ui/interact_editor.gd",
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

	# 1) 读取范例文本并解析
	var ex_path := "res://data/interaction_script.txt.example"
	if not FileAccess.file_exists(ex_path):
		failures.append("范例文件缺失: " + ex_path)
		_print_result(false, log, failures)
		get_tree().quit(1)
		return
	var ex_txt := FileAccess.get_file_as_string(ex_path)
	var parsed = D.parse_text_format(ex_txt)
	_assert(parsed["phases"].size() == 4, "应解析出4个阶段 -> %d" % parsed["phases"].size(), failures, log)
	_assert(parsed["default_speaker"] == "多罗", "角色名应=多罗 -> %s" % parsed["default_speaker"], failures, log)
	_assert(parsed["score_can_negative"] == true, "好感可降=true", failures, log)

	# 2) 与原始 JSON 逐项结构比对（验证 round-trip 保真）
	var ref = _read_json("res://data/interaction_data.json")
	var ref_phases = ref.get("phases", [])
	_assert(parsed["phases"].size() == ref_phases.size(), "阶段数一致", failures, log)
	for i in range(ref_phases.size()):
		var rp = ref_phases[i]
		var pp = parsed["phases"][i]
		_assert(pp.get("id") == rp.get("id"), "阶段%d id 一致(%s)" % [i, rp.get("id")], failures, log)
		_assert(pp.get("name") == rp.get("name"), "阶段%d 名一致(%s)" % [i, rp.get("name")], failures, log)
		_assert(int(pp.get("unlock_score")) == int(rp.get("unlock_score")), "阶段%d 解锁分一致" % i, failures, log)
		# 解锁台词
		var rud = rp.get("unlock_dialogue", [])
		var pud = pp.get("unlock_dialogue", [])
		_assert(rud.size() == pud.size(), "阶段%d 解锁台词数一致" % i, failures, log)
		for j in range(rud.size()):
			_assert(pud[j].get("text") == rud[j].get("text"), "阶段%d 解锁台词%d 文本一致" % [i, j], failures, log)
			_assert(pud[j].get("expr") == rud[j].get("expr"), "阶段%d 解锁台词%d 表情一致" % [i, j], failures, log)
		# 部位
		var rz = rp.get("zones", {})
		var pz = pp.get("zones", {})
		_assert(rz.keys().size() == pz.keys().size(), "阶段%d 部位数一致" % i, failures, log)
		for zid in rz.keys():
			_assert(pz.has(zid), "阶段%d 含部位 %s" % [i, zid], failures, log)
			if not pz.has(zid):
				continue
			_assert(int(pz[zid].get("score")) == int(rz[zid].get("score")), "阶段%d 部位%s 得分一致" % [i, zid], failures, log)
			_assert(pz[zid].get("label") == rz[zid].get("label"), "阶段%d 部位%s 标签一致" % [i, zid], failures, log)
			var rl = rz[zid].get("lines", [])
			var pl = pz[zid].get("lines", [])
			_assert(rl.size() == pl.size(), "阶段%d 部位%s 台词数一致" % [i, zid], failures, log)
			for k in range(rl.size()):
				_assert(pl[k].get("text") == rl[k].get("text"), "阶段%d 部位%s 台词%d 文本一致" % [i, zid, k], failures, log)
				_assert(pl[k].get("expr") == rl[k].get("expr"), "阶段%d 部位%s 台词%d 表情一致" % [i, zid, k], failures, log)

	# 3) 真实导入：把范例复制到 user://interaction_script.txt 再 import
	if FileAccess.file_exists("user://interaction_script.txt"):
		DirAccess.remove_absolute("user://interaction_script.txt")
	var ex2 = FileAccess.get_file_as_string(ex_path)
	var wf = FileAccess.open("user://interaction_script.txt", FileAccess.WRITE)
	wf.store_string(ex2)
	wf.close()
	var ok = D.import_text_script()
	_assert(ok, "import_text_script 应成功", failures, log)
	_assert(D.get_phase_count() == 4, "导入后阶段数=4 -> %d" % D.get_phase_count(), failures, log)
	# 导入后交互逻辑仍正常
	D.total_score = 0
	D.current_phase_index = 0
	D.interact("头")
	_assert(D.get_score() == 10, "导入后 头 仍+10 -> %d" % D.get_score(), failures, log)
	var saved = _read_json("user://interaction_data.json")
	_assert(saved.get("phases", []).size() == 4, "导入后已落盘到 user://interaction_data.json", failures, log)

	# 4) 边界：空文本 / 无阶段
	var empty = D.parse_text_format("# 只有注释\n\n")
	_assert(empty["phases"].size() == 0, "纯注释应解析为0阶段", failures, log)
	# 负分 / 随机 解析
	var frag = D.parse_text_format("== px | 测试 | 7 ==\n-- 尾 | 尾巴 | -3 | 随机 --\n摇尾巴 | expr=SmileEyeClosed\n")
	_assert(frag["phases"].size() == 1, "片段应有1阶段", failures, log)
	var fz = frag["phases"][0]["zones"].get("尾", {})
	_assert(int(fz.get("score")) == -3, "片段 尾 得分=-3", failures, log)
	_assert(fz.get("random") == true, "片段 尾 random=true", failures, log)

	# 清理
	if FileAccess.file_exists("user://interaction_script.txt"):
		DirAccess.remove_absolute("user://interaction_script.txt")
	if FileAccess.file_exists("user://interaction_data.json"):
		DirAccess.remove_absolute("user://interaction_data.json")

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
	print("==== 文本脚本导入 无头测试 ====")
	for l in log:
		print(l)
	print("==== 结果: " + ("PASS" if ok else "FAIL"))
	if not ok:
		print("失败项: ", failures)
