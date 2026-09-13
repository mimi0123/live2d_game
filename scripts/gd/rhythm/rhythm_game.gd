extends Node

## 音游模块（autoload: RhythmGame）——「光圈」样式
##
## 改造自社区成品 scenent/gd-rhythm（Godot 4，纯 GDScript）的核心思路，但换掉了视觉：
##   - 原版是 4 通道「下落音符 + 位置判定」。
##   - 本模块改为【双轨光圈】：音符是一圈圆环，从大半径向固定目标环收缩，
##     在 ideal_time 时刻恰好与目标环重合；玩家在重合瞬间按键即命中。
##   - 判定用「时间差」（按键时刻 vs 音符理想命中时刻），比位置更稳。
##   - 每种输入都会在对应目标处弹出一个向外扩散的「反馈光圈」（就是点击鼠标那个圈的感觉）。
##   - 双轨输入：左轨 = 鼠标左键 / 空格；右轨 = 鼠标右键 / B。
##   - 独立模式：按 F7 或工具栏「音游」按钮进入/退出（入口见 tool_bar.tscn 的 RhythmButton，
##     等价调用 RhythmGame.toggle()）；进入时通知 RegionDetector 进入节奏模式，
##     屏蔽角色互动输入，退出恢复。
##   - 分数实时喂给现有 Dialogue 好感/计分系统（reuse _check_unlock）。
##   - 结算面板：曲终显示 评级(S/A/B/C/D) + 准确率 + FULL COMBO + 四类判定明细 + 最大连击，
##     按 空格 / F7 / 鼠标点击 关闭。
##   - 判定偏移校准：游戏中按 [ / ] 每步 5ms 微调（范围 ±150ms），自动写入 config.ini 的
##     [rhythm] offset，下次进入自动载入。
##   - 谱面 JSON 支持手写；工具 tools\gen_rhythm_chart.py 可从音频自动生成（Task #29 落地工具）。
##
## 谱面格式（data/rhythm_charts/*.json）：
## {
##   "name": "示例",
##   "audio": "res://audio/xxx.ogg",   // 可选；空则用内部计时
##   "lead_time": 1.6,                  // 光圈提前出现的秒数（出生→命中）
##   "lanes": [ [时间...], [时间...] ]  // 双轨；每元素可为数字(普通) 或 [时间, 时长](长条)
## }

# ===== 配置 =====
const COL_LEFT := Color(0.45, 0.75, 1.0)    # 左轨（蓝）
const COL_RIGHT := Color(1.0, 0.55, 0.82)   # 右轨（粉）
const TARGET_R := 46.0                       # 固定目标环半径
const SPAWN_R := 190.0                       # 光圈出生半径（最大）
const LEAD_TIME := 1.6                        # 出生→命中所需秒数
const PERFECT_WIN := 0.055
const GOOD_WIN := 0.13
const MISS_WIN := 0.20
const SCORE_PERFECT := 2
const SCORE_GOOD := 1
const RIPPLE_LIFE := 0.45                     # 反馈光圈存活秒数
const OFFSET_STEP := 0.005                    # 判定偏移微调步长（秒）
const OFFSET_LIMIT := 0.15                    # 判定偏移可调上限 ±（秒）

# ===== 状态 =====
var active := false
var _lead_time := LEAD_TIME                   # 实际出生提前量，取自谱面 lead_time 字段
var _offset := 0.0                            # 判定偏移校正（秒），正值=按感知时刻延后判定
var _rating := ""                             # 结算评级（S/A/B/C/D）
var _acc := 0.0                               # 结算准确率
var _full_combo := false                      # 是否全连
var _config: Node = null                      # /root/Config（避免直接引用 autoload 标识符）
var _layer: CanvasLayer = null
var _stage: Node2D = null
var _audio: AudioStreamPlayer = null
var _song_time := 0.0
var _running := false
var _chart: Array = [[], []]
var _spawn_idx: Array = [0, 0]
var _active: Array = [[], []]
var _score := 0
var _combo := 0
var _max_combo := 0
var _counts := {"perfect": 0, "good": 0, "bad": 0, "miss": 0}
var _end_time := 0.0
var _finished := false
var _current_chart_name := ""
var _current_audio_path := ""
var _targets: Array = [Vector2.ZERO, Vector2.ZERO]   # 左右目标中心
var _ripples: Array = []                              # 点击反馈光圈

signal score_added(delta: int, total: int)


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 300
	_layer.visible = false
	add_child(_layer)   # 加到自身（autoload 节点），避开 root 初始化时的 busy 状态
	_stage = Node2D.new()
	_stage.name = "RhythmStage"
	_layer.add_child(_stage)
	_stage.draw.connect(_on_stage_draw)
	_audio = AudioStreamPlayer.new()
	_audio.name = "RhythmAudio"
	_layer.add_child(_audio)
	# 载入上次校准的判定偏移
	_config = get_node_or_null("/root/Config")
	if _config != null:
		_offset = clampf(float(_config.get_value("rhythm", "offset", 0.0)), -OFFSET_LIMIT, OFFSET_LIMIT)


# =====================================================================
#  对外：进入 / 退出
# =====================================================================
func start(chart_path: String = "") -> void:
	if active:
		return
	var path := chart_path
	if path == "":
		# 默认优先用「带音乐」的示范谱面；若不存在则回退到无声 demo
		path = "res://data/rhythm_charts/demo_beat.json"
		if not FileAccess.file_exists(path):
			path = "res://data/rhythm_charts/demo.json"
	_load_chart(path)
	if _chart[0].size() == 0 and _chart[1].size() == 0:
		push_error("[RhythmGame] 谱面为空，未开始")
		return
	_reset_state()
	_compute_targets()
	active = true
	_running = true
	_finished = false
	_layer.visible = true
	if RegionDetector != null:
		RegionDetector.set_rhythm_mode(true)
	if _audio != null and _current_audio_path != "":
		var stream = load(_current_audio_path)
		if stream is AudioStream:
			_audio.stream = stream
			_audio.play()
	print("[RhythmGame] 开始：谱面=", _current_chart_name,
		" 音符 左=", _chart[0].size(), " 右=", _chart[1].size())


func stop() -> void:
	_running = false
	active = false
	_finished = false
	_layer.visible = false
	if RegionDetector != null:
		RegionDetector.set_rhythm_mode(false)
	if _audio != null and _audio.playing:
		_audio.stop()
	for lane in _active:
		for n in lane:
			if is_instance_valid(n):
				n.queue_free()
	_active = [[], []]


## 供 UI 按钮调用：进 / 出音游（与 F7 等效）
func toggle() -> void:
	if active:
		stop()
	else:
		start()


# =====================================================================
#  谱面加载
# =====================================================================
func _load_chart(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_error("[RhythmGame] 谱面不存在: " + path)
		return
	var txt := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(txt)
	if data is Dictionary and data.has("lanes"):
		_chart = [[], []]
		var lanes: Array = data["lanes"]
		for li in range(mini(lanes.size(), 2)):
			for n in lanes[li]:
				if n is Array and n.size() >= 1:
					_chart[li].append({"time": float(n[0]), "dur": float(n[1]) if n.size() > 1 else 0.0})
				else:
					_chart[li].append({"time": float(n), "dur": 0.0})
		_chart[0].sort_custom(func(a, b): return a["time"] < b["time"])
		_chart[1].sort_custom(func(a, b): return a["time"] < b["time"])
		_current_chart_name = data.get("name", path.get_file())
		_current_audio_path = data.get("audio", "")
		_end_time = 0.0
		for lane in _chart:
			for n in lane:
				_end_time = maxf(_end_time, n["time"] + n["dur"])
		_end_time += 1.5
		print("[RhythmGame] 载入谱面 ", _current_chart_name, " 结束时刻=", _end_time)
	else:
		push_error("[RhythmGame] 谱面格式错误: " + path)


func _reset_state() -> void:
	_song_time = 0.0
	_spawn_idx = [0, 0]
	_score = 0
	_combo = 0
	_max_combo = 0
	_counts = {"perfect": 0, "good": 0, "bad": 0, "miss": 0}
	_ripples = []
	for lane in _active:
		for n in lane:
			if is_instance_valid(n):
				n.queue_free()
	_active = [[], []]


func _compute_targets() -> void:
	var sz: Vector2 = get_viewport().size
	var cx: float = sz.x / 2.0
	var cy: float = sz.y / 2.0
	if sz.x < 10.0 or sz.y < 10.0:
		cx = 427.0; cy = 320.0
	_targets = [Vector2(cx - 175.0, cy), Vector2(cx + 175.0, cy)]


# =====================================================================
#  主循环
# =====================================================================
func _process(delta: float) -> void:
	if _finished:
		_stage.queue_redraw()   # 结算界面需持续重绘
		return
	if not _running:
		return
	_song_time += delta
	_spawn_notes()
	_update_notes()
	_check_miss()
	_stage.queue_redraw()
	if _song_time >= _end_time and not _finished:
		_finish()


func _spawn_notes() -> void:
	for lane in [0, 1]:
		while _spawn_idx[lane] < _chart[lane].size():
			var nd: Dictionary = _chart[lane][_spawn_idx[lane]]
			if nd["time"] - _lead_time <= _song_time:
				_spawn_note(lane, nd)
				_spawn_idx[lane] += 1
			else:
				break


func _spawn_note(lane: int, nd: Dictionary) -> void:
	var note = preload("res://scripts/gd/rhythm/note.tscn").instantiate()
	note.lane = lane
	note.ideal_time = nd["time"]
	note.duration = nd["dur"]
	note.is_long = nd["dur"] > 0.0
	note.lead_time = _lead_time
	note.target_r = TARGET_R
	note.spawn_r = SPAWN_R
	note.cur_time = _song_time
	note.position = _targets[lane]
	_stage.add_child(note)
	_active[lane].append(note)


func _update_notes() -> void:
	for lane in [0, 1]:
		var keep := []
		for n in _active[lane]:
			if not is_instance_valid(n):
				continue
			n.cur_time = _song_time
			if n.judged and _song_time - n.judge_time > 0.3:
				n.queue_free()
				continue
			keep.append(n)
		_active[lane] = keep


func _check_miss() -> void:
	for lane in [0, 1]:
		for n in _active[lane]:
			if not is_instance_valid(n) or n.judged:
				continue
			if _song_time > n.ideal_time + MISS_WIN:
				n.judged = true
				n.result_text = "Miss"
				n.judge_time = _song_time
				_counts.miss += 1
				_combo = 0


# =====================================================================
#  判定（按键）
# =====================================================================
func _hit(lane: int) -> void:
	if not _running:
		return
	var best = null
	var best_diff := INF
	var now := _song_time - _offset
	for n in _active[lane]:
		if not is_instance_valid(n) or n.judged:
			continue
		var d := absf(now - n.ideal_time)
		if d < best_diff:
			best_diff = d
			best = n
	if best == null or best_diff > MISS_WIN:
		return  # 空击，忽略
	var res := ""
	var delta := 0
	if best_diff <= PERFECT_WIN:
		res = "Perfect"; delta = SCORE_PERFECT; _counts.perfect += 1
	elif best_diff <= GOOD_WIN:
		res = "Good"; delta = SCORE_GOOD; _counts.good += 1
	else:
		res = "Bad"; delta = 0; _counts.bad += 1
	best.judged = true
	best.result_text = res
	best.judge_time = _song_time
	if res == "Bad":
		_combo = 0
	else:
		_combo += 1
		if _combo > _max_combo:
			_max_combo = _combo
	_score += delta
	if Dialogue != null:
		Dialogue.add_score(delta)
	score_added.emit(delta, _score)


func _add_ripple(lane: int) -> void:
	if _targets[lane] == Vector2.ZERO:
		_compute_targets()
	_ripples.append({"pos": _targets[lane], "t0": _song_time,
		"col": COL_LEFT if lane == 0 else COL_RIGHT})


# =====================================================================
#  输入：F7 进入/退出；左/右键 + 空格/B 打拍
# =====================================================================
func _unhandled_input(event: InputEvent) -> void:
	if not active:
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
			start()
		return
	# 结算界面：任意确认键 / 鼠标点击关闭
	if _finished:
		var confirm := false
		if event is InputEventKey and event.pressed and not event.echo:
			confirm = event.keycode in [KEY_F7, KEY_SPACE, KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE]
		elif event is InputEventMouseButton and event.pressed:
			confirm = true
		if confirm:
			stop()
			get_viewport().set_input_as_handled()
		return
	# 音游模式中
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
		stop()
		get_viewport().set_input_as_handled()
		return
	# 判定偏移微调：[ 提前 / ] 延后（每步 5ms，写回 config.ini）
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_BRACKETLEFT:
			_set_offset(_offset - OFFSET_STEP)
			get_viewport().set_input_as_handled()
			return
		elif event.keycode == KEY_BRACKETRIGHT:
			_set_offset(_offset + OFFSET_STEP)
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_add_ripple(0); _hit(0); get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_add_ripple(1); _hit(1); get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_add_ripple(0); _hit(0); get_viewport().set_input_as_handled()
		elif event.keycode == KEY_B:
			_add_ripple(1); _hit(1); get_viewport().set_input_as_handled()


# =====================================================================
#  结算
# =====================================================================
func _finish() -> void:
	_finished = true
	_running = false
	if _audio != null and _audio.playing:
		_audio.stop()
	_compute_result()
	print("[RhythmGame] 完成 评级=", _rating,
		" 准确率=", snappedf(_acc * 100.0, 0.1), "% 音游分=", _score,
		" Perfect=", _counts.perfect, " Good=", _counts.good,
		" Bad=", _counts.bad, " Miss=", _counts.miss,
		" 最大连击=", _max_combo, " 全连=", _full_combo)
	_stage.queue_redraw()
	# 结算界面常驻，等玩家按键 / 点击关闭（见 _unhandled_input）


## 计算准确率与评级（供结算面板与外部读取）
func _compute_result() -> void:
	var total: int = _counts.perfect + _counts.good + _counts.bad + _counts.miss
	_full_combo = total > 0 and _counts.bad == 0 and _counts.miss == 0
	if total <= 0:
		_acc = 0.0
		_rating = "D"
		return
	_acc = float(_counts.perfect * SCORE_PERFECT + _counts.good * SCORE_GOOD) \
		/ float(total * SCORE_PERFECT)
	if _full_combo and _acc >= 0.95:
		_rating = "S"
	elif _acc >= 0.90:
		_rating = "A"
	elif _acc >= 0.80:
		_rating = "B"
	elif _acc >= 0.65:
		_rating = "C"
	else:
		_rating = "D"


## 运行时判定偏移微调（由 _unhandled_input 的 [ / ] 调用），并持久化到 config.ini
func _set_offset(v: float) -> void:
	_offset = clampf(v, -OFFSET_LIMIT, OFFSET_LIMIT)
	if _config != null:
		_config.set_value("rhythm", "offset", _offset)
		_config.save_config()
	print("[RhythmGame] 判定偏移 = ", snappedf(_offset * 1000.0, 1.0), " ms")


# =====================================================================
#  HUD / 光圈 绘制
# =====================================================================
func _on_stage_draw() -> void:
	if _targets[0] == Vector2.ZERO and _targets[1] == Vector2.ZERO:
		_compute_targets()
	# 半透明背景遮罩
	var sz: Vector2 = get_viewport().size
	_stage.draw_rect(Rect2(0.0, 0.0, sz.x, sz.y), Color(0.05, 0.07, 0.12, 0.55))

	# 固定目标环（每个轨道一个）
	_stage.draw_arc(_targets[0], TARGET_R, 0, TAU, 48, COL_LEFT, 5)
	_stage.draw_arc(_targets[1], TARGET_R, 0, TAU, 48, COL_RIGHT, 5)
	_stage.draw_circle(_targets[0], 5, COL_LEFT)
	_stage.draw_circle(_targets[1], 5, COL_RIGHT)

	# 点击/按键的反馈光圈（向外扩散并淡出）
	for rp in _ripples:
		var age: float = _song_time - float(rp.t0)
		if age < 0.0:
			age = 0.0
		var rr: float = TARGET_R + age * 240.0
		var a: float = clampf(1.0 - age / 0.4, 0.0, 1.0)
		var pos: Vector2 = rp.pos
		var col: Color = rp.col
		_stage.draw_arc(pos, rr, 0, TAU, 36, Color(col.r, col.g, col.b, a), 4)
	_ripples = _ripples.filter(func(rp): return (_song_time - rp.t0) < RIPPLE_LIFE)

	# 文字 HUD
	var f = ThemeDB.get_default_theme().get_default_font()
	if f == null:
		return
	var s := "SCORE " + str(_score) + "    COMBO " + str(_combo)
	_stage.draw_string(f, Vector2(20, 34), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color.WHITE)
	_stage.draw_string(f, Vector2(20, 64),
		"左轨: 鼠标左键 / 空格      右轨: 鼠标右键 / B      F7 退出      [ ] 调判定偏移",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.8, 0.85, 0.95))
	_stage.draw_string(f, Vector2(20, 88),
		"谱面: %s     偏移: %+.0f ms" % [_current_chart_name, _offset * 1000.0],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.62, 0.70, 0.82))
	if _finished:
		_draw_result(f)


## 结算面板：评级 + 明细 + 关闭提示
func _draw_result(f) -> void:
	var sz: Vector2 = get_viewport().size
	var w := 440.0
	var h := 320.0
	var x := (sz.x - w) / 2.0
	var y := (sz.y - h) / 2.0
	_stage.draw_rect(Rect2(x, y, w, h), Color(0.06, 0.09, 0.15, 0.94))
	_stage.draw_rect(Rect2(x, y, w, h), Color(0.45, 0.75, 1.0, 0.85), false, 2.0)
	_stage.draw_string(f, Vector2(x + 22, y + 38),
		"音游结算 · " + _current_chart_name,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color(0.78, 0.84, 0.94))
	_stage.draw_string(f, Vector2(x + 22, y + 116), _rating,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 60, Color(1.0, 0.85, 0.35))
	_stage.draw_string(f, Vector2(x + 116, y + 96),
		"准确率  %.1f%%" % (_acc * 100.0),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)
	if _full_combo:
		_stage.draw_string(f, Vector2(x + 116, y + 122), "FULL COMBO",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1.0, 0.55, 0.82))
	var lines := [
		"Perfect   %d" % _counts.perfect,
		"Good      %d" % _counts.good,
		"Bad       %d" % _counts.bad,
		"Miss      %d" % _counts.miss,
		"最大连击   %d" % _max_combo,
		"音游得分   %d" % _score,
	]
	var yy := y + 156.0
	for ln in lines:
		_stage.draw_string(f, Vector2(x + 26, yy), ln,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.90, 0.93, 0.98))
		yy += 23.0
	_stage.draw_string(f, Vector2(x + 26, y + h - 14),
		"按 空格 / F7 / 鼠标点击  关闭",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.62, 0.70, 0.85))
