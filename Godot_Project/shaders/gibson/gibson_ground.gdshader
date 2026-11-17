// Source: Copyright (c) 2026 Steve Castellotti
// License: MIT License
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

uniform vec3 board : source_color = vec3(0.0, 0.03, 0.02);
uniform vec3 trace_a : source_color = vec3(0.4, 0.35, 1.0);
uniform vec3 trace_b : source_color = vec3(1.0, 0.7, 0.45);
uniform vec3 camera_local = vec3(0.0, 10.0, 0.0);
uniform float fade_start = 120.0;
uniform float fade_end = 220.0;

varying vec2 p;

void vertex() {
    p = VERTEX.xz;
}

float hash21(vec2 q) {
    return fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453);
}

// Coverage of a line of width w at distance d, anti-aliased, dimmed when narrower than a pixel.
// px: the size of a pixel in the plane's units, taken by the caller outside any branch.
float line(float d, float w, float px) {
    float half_w = 0.5 * max(w, px);
    return (1.0 - smoothstep(half_w - 0.5 * px, half_w + 0.5 * px, abs(d))) * min(1.0, w / px);
}

void fragment() {
    // Derivatives are taken here, before any branch.
    float px_x = max(fwidth(p.x), 0.0001);
    float px_z = max(fwidth(p.y), 0.0001);
    float px_c = max(px_x, px_z);
    float sx = mod(p.x, 16.0) - 8.0;        // signed distance to the street line running along z
    float sz = mod(p.y, 16.0) - 8.0;        // ... and along x
    vec3 col = vec3(0.0);

    // Streets: five traces around each centre line, each carrying a pulse.
    for (int i = 0; i < 5; i++) {
        float off = -1.6 + 0.8 * float(i);
        vec3 tint = (i % 2 == 0) ? trace_a : trace_b;
        float lane_x = hash21(vec2(float(i), floor(p.x / 16.0)));
        float lane_z = hash21(vec2(float(i) + 7.0, floor(p.y / 16.0)));
        float pulse_x = 0.6 + 0.4 * smoothstep(0.9, 1.0, fract(p.y * 0.03 - TIME * 0.25 + lane_x));
        float pulse_z = 0.6 + 0.4 * smoothstep(0.9, 1.0, fract(p.x * 0.03 - TIME * 0.25 + lane_z));
        col += tint * line(sx - off, 0.05, px_x) * pulse_x;
        col += tint * line(sz - off, 0.05, px_z) * pulse_z;
    }

    // Inside blocks: finer, dimmer decoration, one choice per 1-unit cell.
    if (abs(sx) > 2.0 && abs(sz) > 2.0) {
        vec2 c = floor(p);
        vec2 f = fract(p) - 0.5;
        float h = hash21(c);
        vec3 tint = hash21(c + 3.1) < 0.5 ? trace_a : trace_b;
        float w = 0.04;
        float m = 0.0;
        if (h >= 0.4) {
            float kind = (h - 0.4) / 0.6;
            if (kind < 0.25) {
                m = line(f.y, w, px_c) * step(abs(f.x), 0.5);                         // a horizontal segment
            } else if (kind < 0.5) {
                m = line(f.x, w, px_c) * step(abs(f.y), 0.5);                         // a vertical segment
            } else if (kind < 0.75) {
                m = max(line(f.y, w, px_c) * step(f.x, 0.0) * step(-0.5, f.x),        // a corner
                        line(f.x, w, px_c) * step(f.y, 0.0) * step(-0.5, f.y));
            } else {
                vec2 a = abs(f) - vec2(0.3);                                    // a pad: a small outline
                float ring = max(a.x, a.y);
                m = line(ring, w, px_c) * step(max(abs(f.x), abs(f.y)), 0.34);
            }
        }
        col += tint * m * 0.35;
    }

    float dist = distance(vec3(p.x, 0.0, p.y), camera_local);
    float fade = smoothstep(fade_start, fade_end, dist);
    ALBEDO = mix(board + col, board, fade);
}
