extends Node

func _ready() -> void:
	print("=== RhythmGame 测试开始 ===")
	RhythmGame.start("res://data/rhythm_charts/demo.json")
	RhythmGame._song_time = 2.0
	RhythmGame._spawn_notes()
	print("spawn 左活跃=", RhythmGame._active[0].size(), " 右活跃=", RhythmGame._active[1].size())

	RhythmGame._hit(0)
	print("hit@2.0(diff=0) -> score=", RhythmGame._score, " perfect=", RhythmGame._counts.perfect, " combo=", RhythmGame._combo)

	RhythmGame._song_time = 3.1  # 左轨3.0音符, diff=0.1 <= GOOD_WIN(0.13)
	RhythmGame._spawn_notes()
	RhythmGame._hit(0)
	print("hit@3.1(diff=0.1) -> score=", RhythmGame._score, " good=", RhythmGame._counts.good, " combo=", RhythmGame._combo)

	RhythmGame._song_time = 4.18  # 左轨4.0音符, diff=0.18 >GOOD 且 <=MISS(0.20) -> Bad
	RhythmGame._spawn_notes()
	RhythmGame._hit(0)
	print("hit@4.18(diff=0.18) -> bad=", RhythmGame._counts.bad, " combo(应断连=0)=", RhythmGame._combo)

	RhythmGame._song_time = 10.0  # 远离任何未判定音符 -> 空击
	RhythmGame._spawn_notes()
	var before := RhythmGame._score
	RhythmGame._hit(0)
	print("空击 score不变=", RhythmGame._score == before)

	RhythmGame._song_time = 5.5  # 左轨5.0音符 ideal=5.0, 5.5>5.0+0.2 -> Miss
	RhythmGame._check_miss()
	print("miss=", RhythmGame._counts.miss)

	# 验证与 Dialogue 好感计分的对接
	print("Dialogue.total_score(应随音游加分增长)=", Dialogue.get_score())
	RhythmGame.stop()
	print("active=", RhythmGame.active, " layer可见=", RhythmGame._layer.visible)
	print("=== 测试结束 ===")
	get_tree().quit()
