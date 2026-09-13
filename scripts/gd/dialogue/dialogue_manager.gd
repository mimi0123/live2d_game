extends Node
class_name DialogueManager

## 阶段 / 好感度 互动引擎（autoload: Dialogue）
##
## 设计要点（试行版，重点保证可扩展）：
##   - 数据全部来自 interaction_data.json（user:// 优先，回退 res://data/）。
##   - 每个「阶段 phase」有 unlock_score（累计解锁分）与 unlock_dialogue（进入该阶段时播放）。
##   - 每个阶段下按「部位 zone」（= RegionDetector 的区域名，如 头/胸/手/腿/衣服）配置：
##       label 显示名 / score 得分（可为负）/ random 是否随机 / lines 对话行数组。
##   - 点击部位 -> interact(zone_id)：累加总分、按 顺序/随机 取一行播放、检测是否解锁下一阶段。
##   - 好感（总分）可降（score_can_go_negative），但阶段只进不退。
##   - 对外 API 供运行时编辑器（F5）调用，可随时加阶段 / 部位 / 对话行 / 改阈值并保存。
##
## 接入点：RegionDetector 点击区域后调用 Dialogue.say(region, random_order) -> 这里路由到 interact()。

const DATA_PATH := "res://data/interaction_data.json"
const SAVE_PATH := "user://interaction_data.json"
const LEGACY_DIALOGUE_PATH := "res://data/dialogue.json"
const OPACITY_SAVE_PATH := "user://dialogue_opacity.json"
const SPEAKER_SAVE_PATH := "user://speaker_name.txt"
# 纯文本作者脚本的候选路径（按 F6 或点 F5 编辑器按钮时查找）：
#   优先 res://data/interaction_script.txt（随工程分发、可编辑），其次 user://（运行时写入）
const TEXT_SCRIPT_PATHS := ["res://data/interaction_script.txt", "user://interaction_script.txt"]

signal box_opacity_changed(alpha: float)
signal text_opacity_changed(alpha: float)
signal score_changed(total: int)
signal phase_changed(index: int, phase: Dictionary)
signal interact_resolved(zone_id: String, delta: int, total: int)

# ---- 状态 ----
var _phases: Array = []
var _default_speaker: String = "多罗"
var _speaker_override: String = ""
var _score_can_negative: bool = true
var total_score: int = 0
var current_phase_index: int = 0

# ---- 播放 ----
var _box = null
var _controller = null
var _queue: Array = []          # 待播放的对话行（Dictionary）
var _lines: Array = []          # 当前正在播放的对话行组
var _index: int = 0
var _active: bool = false
var _paused: bool = false
var _typing: bool = false
var _full_text: String = ""
var _type_timer: float = 0.0
var _type_speed: float = 0.025
var _line_duration: float = 0.0   # 当前行自动推进延时（音频时长或字数估算）
var _line_elapsed: float = 0.0
var _opacity_box: float = 1.0
var _opacity_text: float = 1.0
var _zone_line_idx: Dictionary = {}   # zone_id -> 下一行下标（顺序模式）

# ---- 顶点锁定（Peak -> After） ----
var _peak_locked: bool = false
var _peak_timer: Timer
var _peak_lock_seconds: float = 6.0

# ---- 编辑器 ----
var _editor = null

func _ready() -> void:
	set_process_unhandled_input(true)
	_load_data()
	_load_speaker_override()
	_load_peak_lock_seconds()
	_peak_timer = Timer.new()
	_peak_timer.one_shot = true
	_peak_timer.timeout.connect(_on_peak_timeout)
	add_child(_peak_timer)
	call_deferred("_setup_ui")
	var op: Dictionary = _load_opacity()
	_opacity_box = op.get("box", 1.0)
	_opacity_text = op.get("text", 1.0)
	box_opacity_changed.emit(_opacity_box)
	text_opacity_changed.emit(_opacity_text)

func _load_data() -> void:
	var txt := ""
	if FileAccess.file_exists(SAVE_PATH):
		txt = FileAccess.get_file_as_string(SAVE_PATH)
	elif FileAccess.file_exists(DATA_PATH):
		txt = FileAccess.get_file_as_string(DATA_PATH)
	if txt != "":
		var parsed = JSON.parse_string(txt)
		if parsed is Dictionary:
			_apply_data(parsed)

func _apply_data(d: Dictionary) -> void:
	if d.has("default_speaker"):
		_default_speaker = d["default_speaker"]
	if d.has("score_can_go_negative"):
		_score_can_negative = bool(d["score_can_go_negative"])
	if d.has("phases") and d["phases"] is Array and d["phases"].size() > 0:
		_phases = d["phases"]
	current_phase_index = clampi(current_phase_index, 0, _phases.size() - 1)

func _load_peak_lock_seconds() -> void:
	if FileAccess.file_exists("res://data/emotion_config.json"):
		var txt := FileAccess.get_file_as_string("res://data/emotion_config.json")
		var d = JSON.parse_string(txt)
		if d is Dictionary and d.has("peak_lock_seconds"):
			_peak_lock_seconds = float(d["peak_lock_seconds"])


func _setup_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	get_tree().root.add_child(layer)
	var box = preload("res://scripts/gd/ui/dialogue_box.gd").new()
	box.name = "DialogueBox"
	layer.add_child(box)
	box.sync_opacity(_opacity_box, _opacity_text)
	# 互动编辑器（默认隐藏，F5 打开）
	_editor = preload("res://scripts/gd/ui/interact_editor.gd").new()
	_editor.name = "InteractionEditor"
	_editor.visible = false
	layer.add_child(_editor)
	# 开场取名弹窗：玩家可修改角色名字
	var name_input = preload("res://scripts/gd/ui/name_input.gd").new()
	name_input.name = "NameInput"
	layer.add_child(name_input)
	_voice_player = AudioStreamPlayer.new()
	_voice_player.name = "VoicePlayer"
	layer.add_child(_voice_player)

func set_box(b) -> void:
	_box = b

func _get_controller():
	if _controller == null and get_tree().current_scene != null:
		_controller = get_tree().current_scene.get_node_or_null("GDCubismUserModel/Animation")
	return _controller

# =====================================================================
#  对外读取 API
# =====================================================================
func get_score() -> int:
	return total_score

func get_phase_index() -> int:
	return current_phase_index

func get_current_phase() -> Dictionary:
	if current_phase_index < _phases.size():
		return _phases[current_phase_index]
	return {}

func get_phase_count() -> int:
	return _phases.size()

func get_progress() -> float:
	if current_phase_index >= _phases.size() - 1:
		return 1.0
	var cur_unlock: int = _phases[current_phase_index].get("unlock_score", 0)
	var next_unlock: int = _phases[current_phase_index + 1].get("unlock_score", 0)
	var span: int = next_unlock - cur_unlock
	if span <= 0:
		return 1.0
	return clampf(float(total_score - cur_unlock) / float(span), 0.0, 1.0)

## 音游等外部模块直接加分：累加总分并复用阶段解锁逻辑
func add_score(delta: int) -> void:
	total_score += delta
	if not _score_can_negative and total_score < 0:
		total_score = 0
	score_changed.emit(total_score)
	_check_unlock()

# 列出可作为「部位」的候选 id：regions.json 的区域名 + 模型真实命中区（若有）
func list_zone_ids() -> Array:
	var out: Array = []
	if FileAccess.file_exists("res://data/regions.json"):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://data/regions.json"))
		if parsed is Dictionary and parsed.has("regions"):
			for k in parsed["regions"].keys():
				if not out.has(k):
					out.append(k)
	var scene = get_tree().current_scene
	var model = scene.get_node_or_null("GDCubismUserModel") if scene else null
	if model != null and model.has_method("get_hit_areas"):
		var ha = model.get_hit_areas()
		for h in ha:
			var id := ""
			if h is Dictionary:
				id = h.get("Id", h.get("id", ""))
			elif h is String:
				id = h
			if id != "" and not out.has(id):
				out.append(id)
	for p in _phases:
		var z = p.get("zones", {})
		for k in z.keys():
			if not out.has(k):
				out.append(k)
	return out

# =====================================================================
#  对外写入 API（供编辑器调用）
# =====================================================================
func add_phase(id: String, name: String, unlock_score: int) -> void:
	for p in _phases:
		if p.get("id") == id:
			p["unlock_score"] = unlock_score
			if name != "":
				p["name"] = name
			save_data()
			return
	_phases.append({
		"id": id, "name": name, "unlock_score": unlock_score,
		"unlock_dialogue": [], "zones": {}
	})
	save_data()

func set_phase_unlock(id: String, unlock_score: int) -> void:
	for p in _phases:
		if p.get("id") == id:
			p["unlock_score"] = unlock_score
	save_data()

func add_zone(phase_id: String, zone_id: String, label: String, score: int, random: bool) -> void:
	var phase = _find_phase(phase_id)
	if phase == null:
		return
	var zones = phase.get("zones", {})
	if not zones.has(zone_id):
		zones[zone_id] = {"label": label, "score": score, "random": random, "lines": []}
	else:
		zones[zone_id]["label"] = label
		zones[zone_id]["score"] = score
		zones[zone_id]["random"] = random
	phase["zones"] = zones
	save_data()

func set_zone_score(phase_id: String, zone_id: String, score: int) -> void:
	var phase = _find_phase(phase_id)
	if phase == null:
		return
	var zones = phase.get("zones", {})
	if zones.has(zone_id):
		zones[zone_id]["score"] = score
		save_data()

func add_zone_line(phase_id: String, zone_id: String, text: String, expr: String, voice: String) -> void:
	var phase = _find_phase(phase_id)
	if phase == null:
		return
	var zones = phase.get("zones", {})
	if not zones.has(zone_id):
		zones[zone_id] = {"label": zone_id, "score": 0, "random": false, "lines": []}
	zones[zone_id]["lines"].append({"text": text, "expr": expr, "voice": voice})
	phase["zones"] = zones
	save_data()

func add_unlock_line(phase_id: String, text: String, expr: String) -> void:
	var phase = _find_phase(phase_id)
	if phase == null:
		return
	if not phase.has("unlock_dialogue"):
		phase["unlock_dialogue"] = []
	phase["unlock_dialogue"].append({"text": text, "expr": expr, "voice": ""})
	save_data()

func reload_data() -> void:
	_load_data()
	phase_changed.emit(current_phase_index, get_current_phase())

func save_data(_override: String = "") -> void:
	var path := _override if _override != "" else SAVE_PATH
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		var out := {
			"version": "0.3",
			"default_speaker": _default_speaker,
			"score_can_go_negative": _score_can_negative,
			"phases": _phases
		}
		f.store_string(JSON.stringify(out, "\t"))
		f.close()
		print("[Dialogue] 已保存互动数据 -> ", path)
	else:
		push_error("[Dialogue] 无法写入 ", path)

func _find_phase(phase_id: String) -> Dictionary:
	for p in _phases:
		if p.get("id") == phase_id:
			return p
	return {}

# =====================================================================
#  文本脚本导入（纯文本作者格式 <-> interaction_data.json）
# =====================================================================
## 把 Master/AI 生成的纯文本脚本解析成 {default_speaker, score_can_negative, phases}。
## 格式（详见 data/interaction_script.txt.example 顶部说明）：
##   # 开头 = 注释；空行忽略
##   角色名: 多罗            （可选全局）
##   好感可降: 是/否         （可选全局）
##   == <阶段id> | <阶段名> | <解锁分> ==      （阶段头）
##   进入: <解锁台词> | expr=SmileEyeClosed     （进入该阶段时播放，可多行）
##   -- <部位id> | <显示名> | <得分±> [| 随机] --   （部位头）
##   <台词文本> | expr=XX | voice=YY            （该部位的对话行）
func parse_text_format(txt: String) -> Dictionary:
	var result := {
		"default_speaker": "",
		"score_can_negative": true,
		"phases": []
	}
	var lines := txt.split("\n", false)
	var cur_phase: Dictionary = {}
	var cur_zone_id: String = ""
	var in_phase := false
	var in_zone := false

	for raw in lines:
		var line := raw.strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		if line.begins_with("角色名:") or line.begins_with("角色名："):
			result["default_speaker"] = line.substr(line.find(":") + 1).strip_edges()
			continue
		if line.begins_with("好感可降:") or line.begins_with("好感可降："):
			var v := line.substr(line.find(":") + 1).strip_edges()
			result["score_can_negative"] = not (v == "否" or v == "no" or v == "false" or v == "0")
			continue
		if line.begins_with("=="):
			cur_phase = _parse_phase_header(line)
			result["phases"].append(cur_phase)
			in_phase = true
			in_zone = false
			cur_zone_id = ""
			continue
		if line.begins_with("--"):
			if not in_phase:
				continue
			var zh := _parse_zone_header(line)
			cur_zone_id = zh["_id"]
			if not cur_phase.has("zones"):
				cur_phase["zones"] = {}
			cur_phase["zones"][cur_zone_id] = {
				"label": zh["label"], "score": zh["score"],
				"random": zh["random"], "lines": []
			}
			in_zone = true
			continue
		if line.begins_with("进入:") or line.begins_with("进入："):
			if not in_phase:
				continue
			if not cur_phase.has("unlock_dialogue"):
				cur_phase["unlock_dialogue"] = []
			var body := line.substr(line.find(":") + 1).strip_edges()
			var pl := _parse_line_body(body)
			cur_phase["unlock_dialogue"].append({"text": pl["text"], "expr": pl["expr"], "voice": pl["voice"]})
			continue
		# 其余视为当前部位的对话行
		if in_zone and cur_zone_id != "":
			var pl := _parse_line_body(line)
			cur_phase["zones"][cur_zone_id]["lines"].append({"text": pl["text"], "expr": pl["expr"], "voice": pl["voice"]})

	return result

func _parse_phase_header(line: String) -> Dictionary:
	var inner := line
	if inner.begins_with("=="):
		inner = inner.substr(2)
	if inner.ends_with("=="):
		inner = inner.substr(0, inner.length() - 2)
	inner = inner.strip_edges()
	var tokens: Array = inner.split("|")
	for i in range(tokens.size()):
		tokens[i] = tokens[i].strip_edges()
	var unlock := 0
	if tokens.size() > 0 and _is_int(tokens[tokens.size() - 1]):
		unlock = int(tokens[tokens.size() - 1])
		tokens.remove_at(tokens.size() - 1)
	var pid := ""
	var pname := ""
	if tokens.size() > 0:
		pid = tokens[0]
		if tokens.size() > 1:
			pname = " ".join(tokens.slice(1))
	return {"id": pid, "name": pname, "unlock_score": unlock, "unlock_dialogue": [], "zones": {}}

func _parse_zone_header(line: String) -> Dictionary:
	var inner := line
	if inner.begins_with("--"):
		inner = inner.substr(2)
	if inner.ends_with("--"):
		inner = inner.substr(0, inner.length() - 2)
	inner = inner.strip_edges()
	var tokens: Array = inner.split("|")
	for i in range(tokens.size()):
		tokens[i] = tokens[i].strip_edges()
	var random := false
	var score := 0
	var zid := ""
	var label_parts: Array = []
	for t in tokens:
		if t == "随机":
			random = true
		elif _is_int(t):
			score = int(t)
		elif zid == "":
			zid = t
		else:
			label_parts.append(t)
	var label := " ".join(label_parts) if label_parts.size() > 0 else zid
	return {"_id": zid, "label": label, "score": score, "random": random}

func _parse_line_body(body: String) -> Dictionary:
	var expr := ""
	var voice := ""
	var text := body
	var parts: Array = body.split(" | ")
	text = parts[0]
	for i in range(1, parts.size()):
		var seg: String = parts[i].strip_edges()
		if seg.begins_with("expr="):
			expr = seg.substr(5).strip_edges()
		elif seg.begins_with("voice="):
			voice = seg.substr(6).strip_edges()
		else:
			text += " | " + seg
	return {"text": text, "expr": expr, "voice": voice}

func _is_int(s: String) -> bool:
	s = s.strip_edges()
	if s == "":
		return false
	var i := 0
	if s[0] == "+" or s[0] == "-":
		i = 1
	if i >= s.length():
		return false
	while i < s.length():
		if s[i] < "0" or s[i] > "9":
			return false
		i += 1
	return true

## 读取文本脚本并批量导入：解析 -> 备份旧数据 -> 写入 interaction_data.json -> 重新加载。
## path_hint 为空时按 TEXT_SCRIPT_PATHS 顺序查找。返回是否成功。
func import_text_script(path_hint: String = "") -> bool:
	var path := ""
	if path_hint != "":
		if FileAccess.file_exists(path_hint):
			path = path_hint
	else:
		for p in TEXT_SCRIPT_PATHS:
			if FileAccess.file_exists(p):
				path = p
				break
	if path == "":
		push_error("[Dialogue] 没找到文本脚本（应是 res://data/interaction_script.txt 或 user://interaction_script.txt）")
		return false

	var txt := FileAccess.get_file_as_string(path)
	var data := parse_text_format(txt)
	if data["phases"].size() == 0:
		push_error("[Dialogue] 文本脚本解析后没有任何阶段，导入中止")
		return false

	_backup_save()
	if data["default_speaker"] != "":
		_default_speaker = data["default_speaker"]
	_score_can_negative = bool(data["score_can_negative"])
	_phases = data["phases"]
	current_phase_index = 0
	_zone_line_idx.clear()
	save_data()
	reload_data()
	var nz := 0
	for p in _phases:
		nz += p.get("zones", {}).size()
	print("[Dialogue] 文本脚本导入成功 -> ", path)
	print("[Dialogue] 阶段数=", _phases.size(), " 部位数=", nz, " 角色=", _default_speaker)
	return true

func _backup_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var src := FileAccess.get_file_as_string(SAVE_PATH)
	var ts := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var bak := SAVE_PATH + "." + ts + ".bak"
	var f := FileAccess.open(bak, FileAccess.WRITE)
	if f != null:
		f.store_string(src)
		f.close()
		print("[Dialogue] 已备份旧数据 -> ", bak)

# =====================================================================
#  互动入口
# =====================================================================
## 区域点击的入口：RegionDetector 调用 Dialogue.say(region, random_order)
func say(key: String, random_order: bool = false) -> void:
	interact(key, random_order)

## 核心：点击某个部位 -> 计分 + 播放该阶段台词 + 检测解锁
func interact(zone_id: String, random_order: bool = false) -> void:
	if _peak_locked:
		return
	var phase: Dictionary = get_current_phase()
	var delta: int = 0
	var line := {}

	if phase.has("zones") and phase["zones"].has(zone_id):
		var zone: Dictionary = phase["zones"][zone_id]
		delta = int(zone.get("score", 0))
		total_score += delta
		if not _score_can_negative and total_score < 0:
			total_score = 0
		line = _pick_line(zone, zone_id, random_order)
		_check_unlock()
	else:
		var later := _find_zone_in_later_phase(zone_id)
		if later != "":
			line = {"name": _default_speaker, "text": "（" + later + " 现在还不能碰哦，先让好感再涨一点吧）", "expr": "Sullen", "voice": ""}
		else:
			line = _legacy_line(zone_id, random_order)

	score_changed.emit(total_score)
	interact_resolved.emit(zone_id, delta, total_score)
	# 动画强度反馈：把当前 zone 的 anim_level / reject 交给情感系统选 1~4 档动画
	var emo = get_node_or_null("/root/Emotion")
	if emo != null and emo.has_method("on_interact_anim"):
		var zdata: Dictionary = phase.get("zones", {}).get(zone_id, {})
		var al: Array = zdata.get("anim_level", [1, 1])
		var rej: bool = bool(zdata.get("reject", false))
		emo.on_interact_anim(zone_id, al, delta, rej)
	if line.size() > 0:
		# 复制一份再注入上下文（阶段/部位/当前情绪），供语音按 (phase,zone,emotion) 自动解析，避免污染原始数据
		var play_line: Dictionary = line.duplicate()
		play_line["_zone"] = zone_id
		play_line["_phase"] = _phases[current_phase_index].get("id", "")
		if emo != null and emo.has_method("get_current"):
			play_line["_emotion"] = emo.get_current()
		_enqueue(play_line)

func _pick_line(zone: Dictionary, zone_id: String, random_order: bool) -> Dictionary:
	var lines: Array = zone.get("lines", [])
	if lines.size() == 0:
		return {}
	if random_order or bool(zone.get("random", false)):
		return lines[randi() % lines.size()]
	var idx: int = _zone_line_idx.get(zone_id, 0)
	var line: Dictionary = lines[idx]
	_zone_line_idx[zone_id] = (idx + 1) % lines.size()
	return line

func _find_zone_in_later_phase(zone_id: String) -> String:
	for i in range(current_phase_index + 1, _phases.size()):
		var z = _phases[i].get("zones", {})
		if z.has(zone_id):
			return _phases[i].get("name", _phases[i].get("id", ""))
	return ""

func _check_unlock() -> void:
	while current_phase_index + 1 < _phases.size():
		var next: Dictionary = _phases[current_phase_index + 1]
		var need: int = int(next.get("unlock_score", 0))
		if total_score >= need:
			current_phase_index += 1
			var ph: Dictionary = _phases[current_phase_index]
			var ud: Array = ph.get("unlock_dialogue", [])
			for l in ud:
				_enqueue(l)
			phase_changed.emit(current_phase_index, ph)
			if _is_peak(ph):
				_start_peak_lock()
				break   # Peak 为暂态：锁定输入，结束后由计时器进入 After，不再自动连跳
		else:
			break


func _is_peak(phase: Dictionary) -> bool:
	var id: String = phase.get("id", "")
	var name: String = String(phase.get("name", ""))
	return id == "p5" or "Peak" in name


func _start_peak_lock() -> void:
	_peak_locked = true
	if _peak_timer != null:
		_peak_timer.wait_time = _peak_lock_seconds
		_peak_timer.start()


func _on_peak_timeout() -> void:
	_peak_locked = false
	# 顶点结束后进入 After（余韵）
	var after_idx: int = -1
	for i in range(_phases.size()):
		var p: Dictionary = _phases[i]
		if p.get("id") == "p6" or "After" in String(p.get("name", "")):
			after_idx = i
			break
	if after_idx >= 0 and current_phase_index < after_idx:
		current_phase_index = after_idx
		var ph: Dictionary = _phases[current_phase_index]
		for l in ph.get("unlock_dialogue", []):
			_enqueue(l)
		phase_changed.emit(current_phase_index, ph)

func _legacy_line(zone_id: String, random_order: bool) -> Dictionary:
	if not FileAccess.file_exists(LEGACY_DIALOGUE_PATH):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(LEGACY_DIALOGUE_PATH))
	if parsed is Dictionary:
		var entry = parsed.get(zone_id, parsed.get("default", []))
		var arr: Array = []
		if entry is Array:
			arr = entry
		elif entry is Dictionary:
			arr = [entry]
		if arr.size() > 0:
			if random_order:
				return arr[randi() % arr.size()]
			# 顺序模式：每次点一下，循环到下一条（衣服1 -> 衣服2 -> 衣服3 -> 衣服1 ...）
			var idx: int = _zone_line_idx.get(zone_id, 0)
			var line: Dictionary = arr[idx]
			_zone_line_idx[zone_id] = (idx + 1) % arr.size()
			return line
	return {}

# =====================================================================
#  播放（队列）
# =====================================================================
# ---- 播放（队列） ----
var _voice_player: AudioStreamPlayer = null

func _enqueue(line: Dictionary) -> void:
	_queue.append(line)
	_pump()

func _pump() -> void:
	if _paused or _active or _typing:
		return
	if _queue.size() == 0:
		return
	_lines = [_queue.pop_front()]
	_index = 0
	_active = true
	if _box != null:
		_box.show_box()
	_show_current()

func _show_current() -> void:
	if _index >= _lines.size():
		_end()
		return
	var line: Dictionary = _lines[_index]
	var name: String = _speaker_override if _speaker_override != "" else line.get("name", _default_speaker)
	var text: String = line.get("text", "")
	var expr: String = line.get("expr", "")
	var voice: String = line.get("voice", "")
	# 行内未指定语音时，按 (阶段, 部位, 情绪) 自动找文件（文件存在才播）
	if voice == "" and line.has("_zone"):
		var emo = get_node_or_null("/root/Emotion")
		if emo != null and emo.has_method("resolve_voice"):
			voice = emo.resolve_voice(str(line.get("_phase", "")), str(line.get("_zone", "")), str(line.get("_emotion", "")))
	if _box != null:
		_box.set_speaker(name)
		_start_typewriter(text)
		_play_voice(voice)
	if expr != "":
		var c = _get_controller()
		if c != null and c.has_method("set_expression"):
			c.set_expression(expr)

## 每句持续时间：有音频则跟音频长度，否则按字数估算（中文约 5 字/秒）
func _estimate_duration(text: String, path: String) -> float:
	if path != "":
		var stream = load(path)
		if stream is AudioStream:
			return stream.get_length()
	return maxf(1.2, float(text.length()) / 5.0)

func _play_voice(path: String) -> void:
	if _voice_player == null or path == "":
		return
	var stream = load(path)
	if stream is AudioStream:
		_voice_player.stop()
		_voice_player.stream = stream
		_voice_player.play()

func _start_typewriter(text: String) -> void:
	_full_text = text
	_typing = true
	_type_timer = 0.0
	if _box != null:
		_box.set_text("")

func _process(delta: float) -> void:
	if _paused:
		return
	if _typing and _box != null:
		_type_timer += delta
		var n: int = int(_type_timer / _type_speed)
		if n >= _full_text.length():
			n = _full_text.length()
			_typing = false
		_box.set_text(_full_text.substr(0, n))
		_pump()

func advance() -> void:
	if not _active or _paused:
		return
	# 一键推进：完成打字并跳到下一句（或结束）
	_typing = false
	_index += 1
	if _index >= _lines.size():
		if _queue.size() > 0:
			_lines = [_queue.pop_front()]
			_index = 0
			_show_current()
		else:
			_end()
	else:
		_show_current()

func _end() -> void:
	_active = false
	_index = 0
	_lines = []
	_typing = false
	if _box != null:
		_box.hide_box()
	var c = _get_controller()
	if c != null and c.has_method("set_expression"):
		# 对话结束：让情感系统把表情回落到当前心情（无 Emotion 时退回 Idle）
		var emo = get_node_or_null("/root/Emotion")
		if emo != null and emo.has_method("restore_mood"):
			emo.restore_mood()
		else:
			c.set_expression("Idle")

func is_active() -> bool:
	return _active

func toggle_pause() -> bool:
	_paused = not _paused
	return _paused

func is_paused() -> bool:
	return _paused

# ---- 透明度（文字 / 对话框 分开控制） ----
func set_box_opacity(a: float) -> void:
	_opacity_box = clampf(a, 0.2, 1.0)
	if _box != null:
		_box.sync_opacity(_opacity_box, _opacity_text)
	_save_opacity()
	box_opacity_changed.emit(_opacity_box)

func set_text_opacity(a: float) -> void:
	_opacity_text = clampf(a, 0.2, 1.0)
	if _box != null:
		_box.sync_opacity(_opacity_box, _opacity_text)
	_save_opacity()
	text_opacity_changed.emit(_opacity_text)

func get_box_opacity() -> float:
	return _opacity_box

func get_text_opacity() -> float:
	return _opacity_text

func _load_opacity() -> Dictionary:
	var out := {"box": 1.0, "text": 1.0}
	if FileAccess.file_exists(OPACITY_SAVE_PATH):
		var t := FileAccess.get_file_as_string(OPACITY_SAVE_PATH)
		var v = JSON.parse_string(t)
		if v is Dictionary:
			out["box"] = clampf(float(v.get("box", 1.0)), 0.2, 1.0)
			out["text"] = clampf(float(v.get("text", 1.0)), 0.2, 1.0)
		elif typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			# 旧版单值文件：两个都沿用该值
			var a := clampf(float(v), 0.2, 1.0)
			out = {"box": a, "text": a}
	return out

func _save_opacity() -> void:
	var f = FileAccess.open(OPACITY_SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"box": _opacity_box, "text": _opacity_text}))
		f.close()

# ---- 角色名字（开场弹窗修改） ----
func get_speaker_name() -> String:
	return _speaker_override if _speaker_override != "" else _default_speaker

func set_speaker_name(n: String) -> void:
	n = n.strip_edges()
	if n != "":
		_speaker_override = n
		var f = FileAccess.open(SPEAKER_SAVE_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(n)
			f.close()
		print("[Dialogue] 角色名字已设置为: ", n)

func _load_speaker_override() -> void:
	if FileAccess.file_exists(SPEAKER_SAVE_PATH):
		var n := FileAccess.get_file_as_string(SPEAKER_SAVE_PATH).strip_edges()
		if n != "":
			_speaker_override = n

# =====================================================================
#  输入：F5 打开互动编辑器 / 数字键调试
# =====================================================================
func _unhandled_input(event: InputEvent) -> void:
	# Peak 顶点锁定期：屏蔽一切交互与调试输入，直到 _on_peak_timeout 跳到 After
	if _peak_locked:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			# 空格改为“在键盘焦点处点击角色”，由 RegionDetector 处理（见 region_detector.gd）
			KEY_ENTER, KEY_J:
				advance()
			KEY_F5:
				if _editor != null:
					_editor.visible = not _editor.visible
					if _editor.visible and _editor.has_method("refresh"):
						_editor.refresh()
			KEY_F6:
				# 批量导入纯文本脚本（data/interaction_script.txt）
				var ok := import_text_script()
				if not ok:
					print("[Dialogue] F6 导入失败：请确认 res://data/interaction_script.txt 存在且含 == 阶段 == 头")
			KEY_1:
				interact("头")
			KEY_2:
				interact("胸")
			KEY_3:
				interact("手")
			KEY_4:
				interact("腿")
			KEY_5:
				interact("衣服")
