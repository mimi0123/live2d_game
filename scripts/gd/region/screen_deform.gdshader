shader_type canvas_item;
// 屏幕空间形变（区域限定 + 轨迹）：
//  - 按住并在部件上移动 -> 沿鼠标路径形成【连续】凹陷（左键=暗色，右键=亮色），按住期间保持满强度
//  - 松开 -> 由 fade_time 缓慢渐隐
//  - 轨迹为"连续管状"：除每个点的圆外，相邻点之间的线段也连成凹槽，不再是离散的点

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

const int MAXP = 48;
uniform vec2 p_c[MAXP];       // 轨迹点（归一化屏幕坐标）
uniform float p_a[MAXP];      // 轨迹点强度（正=向内凹陷）
uniform float p_dir[MAXP];    // +1 亮色(右键)，-1 暗色(左键)
uniform float p_radius = 0.10;
uniform float p_shade = 0.55;  // 变色强度（透明度）
uniform vec3 p_dark_color = vec3(0.05, 0.05, 0.08);   // 左键暗色
uniform vec3 p_bright_color = vec3(1.0, 1.0, 1.0);    // 右键亮色
uniform vec4 p_mask = vec4(0.0, 0.0, 1.0, 1.0);
uniform float p_mask_limit = 0.0;
uniform sampler2D p_map;
uniform float p_use_map = 0.0;
uniform float p_active = 0.0;   // 1.0=有轨迹在绘制；0.0=空闲直接跳过，省开销

float in_mask(vec2 uv, vec4 m) {
    return step(m.x, uv.x) * step(uv.x, m.z) * step(m.y, uv.y) * step(uv.y, m.w);
}

vec2 map_disp(vec2 uv, vec2 center, float radius, float amt, float fall) {
    vec2 muv = clamp((uv - center) / (radius * 2.0) + 0.5, 0.0, 1.0);
    vec2 md = texture(p_map, muv).rg - 0.5;
    return md * amt * 2.0 * fall;
}

// 在 center 处叠加一个圆形凹陷（端点/单点用）
void add_dent(vec2 uv, vec2 center, float radius, float amt, float dir_sign, inout vec2 suv, inout float dark, inout float bright) {
    if (amt < 1e-4) { return; }
    vec2 d = uv - center;
    float dist = length(d);
    if (dist > radius) { return; }
    float fall = smoothstep(1.0, 0.0, dist / radius);
    vec2 dir = (dist > 1e-4) ? (d / dist) : vec2(0.0);
    vec2 disp = (p_use_map > 0.5) ? map_disp(uv, center, radius, amt, fall) : (-dir * amt * fall);
    suv -= disp;
    float zone = smoothstep(0.0, 0.7, fall);
    if (dir_sign > 0.5) { bright += p_shade * zone; }
    else { dark += p_shade * zone; }
}

void fragment() {
    vec2 uv = SCREEN_UV;
    vec2 suv = uv;
    float dark = 0.0;
    float bright = 0.0;
    float maskok = (p_mask_limit > 0.5) ? in_mask(uv, p_mask) : 1.0;
    if (maskok >= 0.5 && p_active >= 0.5) {
        for (int i = 0; i < MAXP; i++) {
            if (abs(p_a[i]) < 1e-4) { continue; }
            // 点圆（端点 / 单点）
            add_dent(uv, p_c[i], p_radius, p_a[i], p_dir[i], suv, dark, bright);
            // 与下一点的连线：连续管状凹槽
            int j = i + 1;
            if (j < MAXP && abs(p_a[j]) >= 1e-4) {
                vec2 a = p_c[i];
                vec2 b = p_c[j];
                vec2 pa = uv - a;
                vec2 ba = b - a;
                float baba = dot(ba, ba);
                if (baba > 1e-6) {
                    float h = clamp(dot(pa, ba) / baba, 0.0, 1.0);
                    vec2 proj = a + ba * h;
                    add_dent(uv, proj, p_radius, (p_a[i] + p_a[j]) * 0.5, p_dir[i], suv, dark, bright);
                }
            }
        }
        suv = clamp(suv, vec2(0.001), vec2(0.999));
        vec4 col = texture(screen_texture, suv);
        float dk = clamp(dark, 0.0, 1.0);
        float br = clamp(bright, 0.0, 1.0);
        col.rgb *= mix(vec3(1.0), p_dark_color, dk);
        col.rgb = mix(col.rgb, p_bright_color, br);
        COLOR = col;
    } else {
        COLOR = texture(screen_texture, uv);
    }
}
