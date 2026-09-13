extends Node
class_name EmotionManager

## 情感系统（autoload: Emotion）
##
## 在 DialogueManager 的「好感阶段」之上，维护一个会随时间衰减的「心情 / 情绪」状态。
##   - 4 个主情绪，与 4 个阶段一一对应：CALM(平静/p1) HAPPY(开心/p2) SHY(害羞/p3) ANGRY(生气/p4)
##   - 每种情绪映射到 AnimationController 支持的模型表情（见 _expr_map / 配置）
##   - 触发来源：
##       * 互动事件 Dialogue.interact_resolved(zone, delta, total) -> 按部位 + 正负分注入情绪；扣分到阈值 -> 直接 ANGRY
##       * 阶段变化 Dialogue.phase_changed(index, phase)           -> 进入新阶段注入对应情绪
##       * 空闲：_decay_timer 每秒衰减，强度跌破阈值后回落到基线 CALM
##   - 驱动：
##       * 对话进行中不打断台词表情（Dialogue.is_active() 时跳过）
##       * 对话结束后由 Dialogue._end() 调 restore_mood() 把表情回落到当前心情
##       * 空闲时心情表情自然呈现
##       * 主导情绪变化 -> _trigger_animation() 按 emotion_animations 切换动画
##       * 台词语音：行内 voice 为空时，按 (阶段,部位,情绪) 由 voice_template 自动找文件
##   - 全部阈值 / 映射在 res://data/emotion_config.json，可改不动代码。

signal emotion_changed(id: String, expr: String, intensity: float)

const CONFIG_PATH := "res://data/emotion_config.json"

# 内置默认（配置缺失或某字段缺失时回退）
var _baseline := "CALM"
var _decay_per_second := 0.15
var _threshold := 0.05
var _expr_map := {
	"CALM": "Idle",
	"HAPPY": "SmileEyeClosed",
	"SHY": "Silence",
	"ANGRY": "DockPopAngry",
}
# 部位触发（瞬时心情）：zone_id -> {emotion, pos, neg}
var _zone_triggers := {}
# 阶段触发（进入某情感阶段时的基线心情）：phase_id -> {emotion, intensity}
var _stage_triggers := {}
# 当前情感阶段 id（来自 Dialogue.phase_changed）
var _current_stage := "p1"
# 情绪 -> 动画（动作）名，由 set_motion 播放；默认全 Idle（不切换），Master 填真实动作名即点亮
var _anim_map := {}
# 部位 id -> 动画键名（用于拼动作名，避免中文进 AnimationTree）
var _anim_zone_key := {}
# 动作名模板：{zone}=动画键名, {intensity}=强度档位(1~4)
var _motion_template := "{zone}_L{intensity}"
# 互动能量：每次互动 +energy_per_interact，随时间衰减；用于在同一阶段强度档位内升档
var _energy := 0.0
var _energy_per_interact := 0.34
var _energy_decay_per_sec := 0.1
# 语音文件命名模板：{phase}=阶段id, {zone}=部位id, {emotion}=情绪id；文件存在才播
var _voice_template := ""
# 互动扣分到此值及以下 -> 直接触发生气（覆盖部位映射）
var _angry_threshold := -8.0
var _angry_amount := 0.6

var _intensity := {}      # id -> float 强度（0~1）
var _current := "CALM"    # 当前主导情绪
var _decay_timer: Timer


func _ready() -> void:
	_load_config()
	_decay_timer = Timer.new()
	_decay_timer.wait_time = 1.0
	_decay_timer.one_shot = false
	_decay_timer.timeout.connect(_on_decay_tick)
	add_child(_decay_timer)
	_decay_timer.start()

	var dlg = get_node_or_null("/root/Dialogue")
	if dlg != null:
		if dlg.has_signal("interact_resolved"):
			dlg.interact_resolved.connect(_on_interact_resolved)
		if dlg.has_signal("phase_changed"):
			dlg.phase_changed.connect(_on_phase_changed)

	# 初始化基线表情
	apply_current(true)
	print("[Emotion] 情感系统已加载，基线=", _baseline, " 衰减=", _decay_per_second, "/s")


func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		_build_default_config()
		return
	var txt := FileAccess.get_file_as_string(CONFIG_PATH)
	var d = JSON.parse_string(txt)
	if d is Dictionary:
		if d.has("baseline"):
			_baseline = d["baseline"]
		if d.has("decay_per_second"):
			_decay_per_second = float(d["decay_per_second"])
		if d.has("intensity_threshold"):
			_threshold = float(d["intensity_threshold"])
		if d.has("emotions") and d["emotions"] is Dictionary:
			for k in d["emotions"].keys():
				var e = d["emotions"][k]
				if e is Dictionary and e.has("expr"):
					_expr_map[k] = e["expr"]
		if d.has("zone_triggers") and d["zone_triggers"] is Dictionary:
			_zone_triggers = d["zone_triggers"]
		if d.has("stage_triggers") and d["stage_triggers"] is Dictionary:
			_stage_triggers = d["stage_triggers"]
		if d.has("emotion_animations") and d["emotion_animations"] is Dictionary:
			_anim_map = d["emotion_animations"]
		if d.has("anim_zone_key") and d["anim_zone_key"] is Dictionary:
			_anim_zone_key = d["anim_zone_key"]
		if d.has("motion_template"):
			_motion_template = String(d["motion_template"])
		if d.has("energy_per_interact"):
			_energy_per_interact = float(d["energy_per_interact"])
		if d.has("energy_decay_per_sec"):
			_energy_decay_per_sec = float(d["energy_decay_per_sec"])
		if d.has("voice_template"):
			_voice_template = String(d["voice_template"])
		if d.has("angry_threshold"):
			_angry_threshold = float(d["angry_threshold"])
		if d.has("angry_amount"):
			_angry_amount = float(d["angry_amount"])
	_current = _baseline


func _build_default_config() -> void:
	var cfg := {
		"baseline": "CALM",
		"decay_per_second": 0.15,
		"intensity_threshold": 0.05,
		"emotions": {
			"CALM":  {"expr": "Idle",           "desc": "平静（基线，默认表情）"},
			"HAPPY": {"expr": "SmileEyeClosed", "desc": "开心（闭眼笑）"},
			"SHY":   {"expr": "Silence",        "desc": "害羞 / 被摸到敏感部位时的扭捏沉默"},
			"ANGRY": {"expr": "DockPopAngry",   "desc": "生气 / 炸毛"}
		},
		"zone_triggers": {
			"头":   {"emotion": "HAPPY", "pos": 0.5,  "neg": 0.3},
			"手":   {"emotion": "HAPPY", "pos": 0.4,  "neg": 0.2},
			"胸":   {"emotion": "SHY",   "pos": 0.4,  "neg": 0.6},
			"腿":   {"emotion": "SHY",   "pos": 0.3,  "neg": 0.6},
			"衣服": {"emotion": "SHY",   "pos": 0.25, "neg": 0.5}
		},
		"stage_triggers": {
			"p1": {"emotion": "CALM",  "intensity": 0.3},
			"p2": {"emotion": "CALM",  "intensity": 0.3},
			"p3": {"emotion": "SHY",   "intensity": 0.5},
			"p4": {"emotion": "HAPPY", "intensity": 0.5},
			"p5": {"emotion": "HAPPY", "intensity": 0.7},
			"p6": {"emotion": "SHY",   "intensity": 0.5}
		},
		"emotion_animations": {
			"CALM":  "Idle",
			"HAPPY": "Idle",
			"SHY":   "Idle",
			"ANGRY": "Idle"
		},
		"anim_zone_key": {
			"头": "Head", "胸": "Chest", "手": "Hand", "腿": "Leg", "衣服": "Clothes"
		},
		"motion_template": "{zone}_L{intensity}",
		"energy_per_interact": 0.34,
		"energy_decay_per_sec": 0.1,
		"voice_template": "res://audio/voice/{phase}_{zone}_{emotion}.wav",
		"angry_threshold": -8,
		"angry_amount": 0.6,
		"peak_lock_seconds": 6
	}
	var f = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cfg, "\t"))
		f.close()
		print("[Emotion] 已写出默认配置 -> ", CONFIG_PATH)


# =====================================================================
#  对外 API
# =====================================================================

## 直接注入情绪（外部模块如音游也可用），amount 叠加到强度并钳制 0~1
func add_emotion(id: String, amount: float) -> void:
	if id == "" or not _expr_map.has(id):
		return
	_intensity[id] = clampf(_intensity.get(id, 0.0) + amount, 0.0, 1.0)
	_recompute_dominant()
	apply_current(false)


## 把心情直接设成某情绪（清空其它），intensity 默认满
func set_emotion(id: String, intensity: float = 1.0) -> void:
	if id == "" or not _expr_map.has(id):
		return
	_intensity.clear()
	_intensity[id] = clampf(intensity, 0.0, 1.0)
	_recompute_dominant()
	apply_current(false)


func get_current() -> String:
	return _current


func get_intensity(id: String = "") -> float:
	if id == "":
		id = _current
	return _intensity.get(id, 0.0)


func expr_for(id: String) -> String:
	return _expr_map.get(id, "Idle")


## 对话结束后由 Dialogue._end() 调用：把表情回落到当前心情
func restore_mood() -> void:
	apply_current(true)


# =====================================================================
#  内部
# =====================================================================

func _on_interact_resolved(zone_id: String, delta: int, _total: int) -> void:
	# 扣分到阈值及以下 -> 直接触发生气（覆盖部位映射）
	if float(delta) <= _angry_threshold:
		add_emotion("ANGRY", _angry_amount)
		return
	var t = _zone_triggers.get(zone_id, {})
	if t is Dictionary and t.has("emotion"):
		var amt: float = float(t.get("pos", 0.3)) if delta >= 0 else float(t.get("neg", 0.2))
		add_emotion(String(t["emotion"]), amt)


func _on_phase_changed(_index: int, phase: Dictionary) -> void:
	var pid: String = phase.get("id", "")
	_current_stage = pid
	var t = _stage_triggers.get(pid, {})
	if t is Dictionary and t.has("emotion"):
		_intensity.clear()
		set_emotion(String(t["emotion"]), float(t.get("intensity", 0.5)))


func _on_decay_tick() -> void:
	for e in _intensity.keys():
		var v: float = _intensity[e] - _decay_per_second
		if v <= 0.0:
			_intensity[e] = 0.0
		else:
			_intensity[e] = v
	# 互动能量随时间自然回落（用于动画强度升档）
	_energy = maxf(0.0, _energy - _energy_decay_per_sec)
	_recompute_dominant()
	if not _is_dialogue_active():
		apply_current(false)


func _recompute_dominant() -> void:
	var best := _baseline
	var best_v := 0.0
	for e in _intensity.keys():
		var v: float = _intensity[e]
		if v > _threshold and v > best_v:
			best_v = v
			best = e
	if best != _current:
		_current = best
		_trigger_animation(_current)


func apply_current(force: bool = false) -> void:
	if not force and _is_dialogue_active():
		return
	var expr: String = expr_for(_current)
	var c = _get_controller()
	if c != null and c.has_method("set_expression"):
		c.set_expression(expr)
	emotion_changed.emit(_current, expr, get_intensity())


func _is_dialogue_active() -> bool:
	var dlg = get_node_or_null("/root/Dialogue")
	if dlg != null and dlg.has_method("is_active"):
		return dlg.is_active()
	return false


func _get_controller():
	var scene = get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("GDCubismUserModel/Animation")


## 主导情绪变化时，按配置触发对应动画（动作）
func _trigger_animation(emotion_id: String) -> void:
	var name: String = _anim_map.get(emotion_id, "Idle")
	var c = _get_controller()
	if c != null and c.has_method("set_motion"):
		c.set_motion(name)


## 按 (阶段, 部位, 情绪) 解析语音文件路径；文件存在才返回，否则返回空（不播）
func resolve_voice(phase_id: String, zone_id: String, emotion_id: String) -> String:
	if _voice_template == "":
		return ""
	var p: String = _voice_template.replace("{phase}", phase_id).replace("{zone}", zone_id).replace("{emotion}", emotion_id)
	if FileAccess.file_exists(p):
		return p
	return ""


## 互动时由 DialogueManager 调用：按「当前阶段允许的动画强度档位 + 互动能量」选 1~4 档动画并播放。
## anim_level: [min,max]（来自 interaction_data 各 zone 的 anim_level）；reject: 是否强制强度1（早期拒绝区）
func on_interact_anim(zone_id: String, anim_level: Array, delta: int, reject: bool) -> void:
	var lo: int = 1
	var hi: int = 1
	if anim_level.size() > 0:
		lo = int(anim_level[0])
	if anim_level.size() > 1:
		hi = int(anim_level[1])
	if reject:
		lo = 1
		hi = 1
	# 能量累积：同一阶段内连续互动会升档（如 Active 2->3）
	_energy = minf(_energy + _energy_per_interact, 1.0)
	var t: float = _energy
	var intensity: int = int(round(lerp(float(lo), float(hi), t)))
	intensity = clampi(intensity, lo, hi)
	var key: String = _anim_zone_key.get(zone_id, zone_id)
	var name: String = _motion_template.replace("{zone}", key).replace("{intensity}", str(intensity))
	var c = _get_controller()
	if c != null and c.has_method("set_motion"):
		# 分层动画并非全部已接入 AnimationTree：从高档往下找第一个真实存在的，找不到就不切动作
		var picked := ""
		for lv in range(intensity, lo - 1, -1):
			var cand: String = _motion_template.replace("{zone}", key).replace("{intensity}", str(lv))
			if not c.has_method("has_motion") or bool(c.has_motion(cand)):
				picked = cand
				break
		if picked != "":
			c.set_motion(picked)
	emotion_changed.emit(_current, expr_for(_current), get_intensity())
