extends Node
class_name AnimationController

@export var anim_tree: AnimationTree

# 表情切换去重 + 节流，避免频繁请求把原生 Cubism 表情系统打崩
var _last_expr: String = ""
var _pending_expr: String = ""
var _expr_timer: Timer

# MotonTransition 里实际存在的动作名集合（分层互动动画可能尚未全部做完，请求前需校验）
var _motion_inputs := {}
var _motion_warned := {}

func _ready() -> void:
	_ensure_timer()
	idle()

# EmotionManager 是 autoload，可能在场景内本节点 _ready 之前就调用 set_expression，
# 所以计时器做成惰性创建：不在树里时同步 flush 一次，避免空引用。
func _ensure_timer() -> void:
	if _expr_timer != null:
		return
	_expr_timer = Timer.new()
	# 必须 >= Expression Transition 的 xfade_time(0.15)，保证上一次过渡播完再切下一段
	_expr_timer.wait_time = 0.2
	_expr_timer.one_shot = true
	_expr_timer.timeout.connect(_flush_expr)
	if is_inside_tree():
		add_child(_expr_timer)

func idle():
	if anim_tree == null:
		return
	anim_tree["parameters/MotonTransition/transition_request"] = "Idle"

func run():
	if anim_tree == null:
		return
	anim_tree["parameters/MotonTransition/transition_request"] = "Run"

## 切换到指定动作（情绪动画由 EmotionManager 调用）。动作名必须是 AnimationTree 里存在的状态。
## AnimationTree 对不存在的 input 会刷 "No such input" 错误，所以先查表；没有则忽略。
func set_motion(name: String):
	if name == "" or anim_tree == null:
		return
	if _motion_inputs.is_empty():
		_refresh_motion_inputs()
	if _motion_inputs.has(name):
		anim_tree["parameters/MotonTransition/transition_request"] = name
	elif not _motion_warned.has(name):
		_motion_warned[name] = true
		push_warning("[AnimCtrl] 动作 '%s' 尚未接入 AnimationTree，已降级跳过" % name)

func has_motion(name: String) -> bool:
	if name == "":
		return false
	if anim_tree == null:
		return false
	if _motion_inputs.is_empty():
		_refresh_motion_inputs()
	return _motion_inputs.has(name)

## 收集 MotonTransition 上所有已定义的 input 名（parameters/MotonTransition/input_N/name）
func _refresh_motion_inputs() -> void:
	_motion_inputs.clear()
	if anim_tree == null:
		return
	# 首选：直接从 AnimationNodeTransition 节点读取（最可靠）
	var root := anim_tree.tree_root
	if root != null and root.has_method("get_node"):
		var trans = root.get_node(&"MotonTransition")
		if trans != null and trans.has_method("get_input_count"):
			for i in range(trans.get_input_count()):
				_motion_inputs[String(trans.get_input_name(i))] = true
	if not _motion_inputs.is_empty():
		return
	# 兜底：从 AnimationTree 暴露的 parameters 属性里扫
	var prefix := "parameters/MotonTransition/input_"
	for p in anim_tree.get_property_list():
		var pname := String(p["name"])
		if pname.begins_with(prefix) and pname.ends_with("/name"):
			var v := String(anim_tree.get(pname))
			if v != "":
				_motion_inputs[v] = true

func eye_blink():
	if anim_tree == null:
		return
	anim_tree["parameters/Expression/EyeBlinkOneShot/request"] = AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE

func set_expression(name: String):
	if name == "":
		return
	# 去重：与上次已应用的表情相同、且没有排队请求，直接跳过
	if name == _last_expr and _pending_expr == "":
		return
	_pending_expr = name
	_ensure_timer()
	# 节流：计时器在跑说明上一次切换还没完成，先排队，等它结束再刷
	if _expr_timer != null and not _expr_timer.is_stopped():
		return
	_flush_expr()

func _flush_expr() -> void:
	if _pending_expr == "":
		return
	var name = _pending_expr
	_pending_expr = ""
	if name == _last_expr:
		return
	if anim_tree != null:
		anim_tree["parameters/Expression/Transition/transition_request"] = name
	_last_expr = name
	# 重启节流窗口，期间的重复请求会排队到 timeout 再刷
	if _expr_timer != null and _expr_timer.is_inside_tree():
		_expr_timer.start()

func target_point(target: Vector2):
	if anim_tree == null:
		return
	anim_tree["parameters/HeadControl/blend_position"] = target
