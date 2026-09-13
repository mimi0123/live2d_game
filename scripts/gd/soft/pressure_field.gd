## 压力场（SoftTouch 模块）—— 决定「离触点多远，受力多少」
##
## 这是整套软体手感的核心：输入只有一个距离，输出 0~1 的影响系数。
##   中心 = 1.0   近中心 = 0.8   中距离 = 0.4   边缘≈0.05   外面 = 0
##
## 与旧的「矩形区域整体变形」的根本区别：
##   旧做法  → 在不在矩形内（布尔），在就整体平移
##   本做法  → 连续衰减（float），每个顶点各算各的
## 所以不会出现截图里那种方块状一起动的现象。
##
## 本文件不引用任何 Live2D / UI 系统，纯数学。

class_name PressureField
extends RefCounted

## 最基础的幂衰减：t = 1 - d/r，返回 t^power
##
## power 越大，影响越集中在触点附近：
##   power = 2 → 平缓（像按海绵，大范围动）
##   power = 4 → 明显局部（默认，像按皮肤）
##   power = 8 → 非常尖锐（像针尖，几乎只有中心动）
static func falloff(distance: float, radius: float, power: float = 4.0) -> float:
	if radius <= 0.0:
		return 0.0
	if distance >= radius:
		return 0.0
	if distance <= 0.0:
		return 1.0
	var t: float = 1.0 - distance / radius
	return pow(t, maxf(power, 0.01))


## 平滑版：先幂衰减，再过一次 smoothstep，边缘收得更自然（无一级导数突跳）
## 若发现「变形边缘有一圈硬线」，把 falloff 换成它即可。
static func smooth_falloff(distance: float, radius: float, power: float = 4.0) -> float:
	var f: float = falloff(distance, radius, power)
	return f * f * (3.0 - 2.0 * f)


## 椭圆版：px / py 传两个半径，可做「横向比纵向更宽」的影响场（贴皮肤走向）
static func falloff_ellipse(offset: Vector2, radius_x: float, radius_y: float, power: float = 4.0) -> float:
	if radius_x <= 0.0 or radius_y <= 0.0:
		return 0.0
	var nx: float = offset.x / radius_x
	var ny: float = offset.y / radius_y
	var d: float = sqrt(nx * nx + ny * ny)
	if d >= 1.0:
		return 0.0
	var t: float = 1.0 - d
	return pow(t, maxf(power, 0.01))


## 平滑阶梯 0→1（smoothstep），用于让边缘无一级导数突跳
static func smoothstep01(x: float) -> float:
	var t: float = clampf(x, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## 「平顶 + 平滑肩」按压 profile（STEP 2 用的就是它）
##
## 与 falloff 的区别（这是「凹陷能不能真的凹下去」的关键）：
##   falloff(d,r,3.5) 在 d=0.25r 处只剩 0.30，力被摊薄在很大一片，中心反而不够强；
##   本函数在 d <= flat_top*r 的整片区域内恒为 1.0（中心整片等强），
##   之后用 (1-u)^power 衰减，再过 smoothstep 收尾，到 d=r 处严格为 0。
##
## 参数：
##   flat_top 平顶半径占 r 的比例（0.15~0.35 比较像皮肤）
##   power    肩部衰减指数，越小过渡越宽
static func soft_press_profile(distance: float, radius: float,
		flat_top: float = 0.18, power: float = 1.8) -> float:
	if radius <= 0.0:
		return 0.0
	if distance >= radius:
		return 0.0
	if distance <= 0.0:
		return 1.0
	var ft: float = clampf(flat_top, 0.0, 0.95)
	var t: float = distance / radius
	if t <= ft:
		return 1.0
	var u: float = (t - ft) / (1.0 - ft)          # 0（平顶边缘）→ 1（影响半径边缘）
	var f: float = pow(1.0 - u, maxf(power, 0.01))
	return f * f * (3.0 - 2.0 * f)                 # smoothstep 收尾，r 处为 0


## 高斯衰减（更「软」的选择，中心平顶、尾巴长）
## sigma 约等于影响半径的一半时手感接近真实皮肤。
static func gaussian(distance: float, sigma: float) -> float:
	if sigma <= 0.0:
		return 0.0
	var s: float = distance / sigma
	return exp(-0.5 * s * s)
