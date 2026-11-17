// Source: Copyright (c) 2026 Steve Castellotti
// License: MIT License
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, shadows_disabled;

uniform vec3 sky_base : source_color = vec3(0.01, 0.0, 0.1);
uniform vec3 sky_strand : source_color = vec3(0.35, 0.3, 0.9);
uniform vec3 sky_arc : source_color = vec3(1.0, 0.7, 0.15);
uniform vec3 sky_formula : source_color = vec3(1.0, 0.4, 0.55);
uniform vec3 sky_wash : source_color = vec3(0.72, 0.66, 1.0);
uniform vec3 board : source_color = vec3(0.0, 0.03, 0.02);
uniform float strength = 1.0;
uniform sampler2D atlas : filter_nearest, repeat_disable;

varying vec3 dir;

void vertex() {
    dir = VERTEX;
}

float hash11(float x) {
    return fract(sin(x * 127.1) * 43758.5453);
}
float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}
float hash31(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}
float vnoise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x), mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x), f.y);
    float b = mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x), mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x), f.y);
    return mix(a, b, f.z);
}

// One glyph of the atlas, a little blurred (four taps), 0 outside its box.
float glyph_at(float index, vec2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return 0.0;
    }
    vec2 origin = vec2(mod(index, 8.0), floor(index / 8.0)) * vec2(8.0, 10.0);
    vec2 px = origin + uv * vec2(8.0, 10.0);
    float s = 0.0;
    s += textureLod(atlas, (px + vec2(-0.5, -0.5)) / vec2(64.0, 80.0), 0.0).r;
    s += textureLod(atlas, (px + vec2(0.5, -0.5)) / vec2(64.0, 80.0), 0.0).r;
    s += textureLod(atlas, (px + vec2(-0.5, 0.5)) / vec2(64.0, 80.0), 0.0).r;
    s += textureLod(atlas, (px + vec2(0.5, 0.5)) / vec2(64.0, 80.0), 0.0).r;
    return s * 0.25;
}

void fragment() {
    vec3 d = normalize(dir);
    float t = TIME * 0.02;
    float az = atan(d.z, d.x);
    float el = asin(clamp(d.y, -1.0, 1.0));

    // 1. The base, darkening toward the zenith.
    vec3 col = sky_base * (1.0 - 0.5 * max(d.y, 0.0));

    // 2. Filaments: warped value noise taken as ridges, and a finer layer at half strength.
    vec3 q = d * 2.5 + vec3(t, 0.0, -t);
    float warp = vnoise(q * 1.7 + vec3(3.0, 1.0, 5.0));
    float n1 = 0.65 * vnoise(q + warp * 1.5) + 0.35 * vnoise(q * 2.3 - warp);
    float ridge1 = pow(1.0 - abs(2.0 * n1 - 1.0), 6.0);
    vec3 q2 = d * 6.0 + vec3(-t, t, 0.0);
    float n2 = vnoise(q2 + vnoise(q2 * 0.7) * 2.0);
    float ridge2 = pow(1.0 - abs(2.0 * n2 - 1.0), 6.0);
    col += sky_strand * (ridge1 * 0.2 + ridge2 * 0.09);

    // 3. Gold arcs: in one cell in three, a partial ring that turns slowly.
    vec2 ang = vec2(az, el);
    vec2 acell = floor(ang / 0.12);
    if (hash21(acell) < 0.34) {
        vec2 local = fract(ang / 0.12) - 0.5;
        float r = length(local);
        float start = hash21(acell + 11.0) * 6.2831853 + TIME * 0.05 * (hash21(acell + 5.0) - 0.5) * 2.0;
        float a = mod(atan(local.y, local.x) - start, 6.2831853);
        float on = step(a, 2.0943951);
        float ring = 1.0 - smoothstep(0.015, 0.03, abs(r - 0.35));
        col += sky_arc * ring * on * 0.5;
    }

    // 4. Formula glyphs: in one larger cell in four, a short row of glyphs, soft and dim.
    vec2 fcell = floor(ang / 0.35);
    if (hash21(fcell + 31.0) < 0.25) {
        vec2 local = fract(ang / 0.35);
        float count = 4.0 + floor(hash21(fcell + 2.0) * 4.0);
        float x0 = 0.5 - count / 14.0;
        float slot = floor((local.x - x0) * 7.0);
        if (slot >= 0.0 && slot < count) {
            float h = hash21(fcell + vec2(slot, 17.0));
            float idx = 1.0 + floor(h * 36.0);
            if (h > 0.7) {
                float pick = floor((h - 0.7) / 0.3 * 7.0);
                idx = pick < 1.0 ? 38.0 : (pick < 2.0 ? 42.0 : (pick < 3.0 ? 49.0 : (pick < 4.0 ? 50.0 : (pick < 5.0 ? 40.0 : (pick < 6.0 ? 51.0 : 52.0)))));
            }
            vec2 guv = vec2(fract((local.x - x0) * 7.0), 1.0 - (local.y - 0.4) / 0.2);
            col += sky_formula * glyph_at(idx, guv) * 0.35;
        }
    }

    // 5. Pale diagonal streaks.
    float streak = vnoise(vec3((az * 1.3 + el * 1.3) * 3.0, (az - el) * 0.35, t * 2.0));
    col += sky_wash * smoothstep(0.62, 0.9, streak) * 0.10;

    // 6. Below the horizon, the board.
    col = mix(col, board, smoothstep(0.0, -0.1, d.y));
    ALBEDO = col * strength;
}
