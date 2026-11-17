// Source: Copyright (c) 2026 Steve Castellotti
// License: MIT License
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec3 size = vec3(2.0, 10.0, 2.0);        // side, height, side, in city units
uniform vec3 glass : source_color = vec3(0.1, 0.8, 0.5);
uniform float brightness = 1.0;

void fragment() {
    ALBEDO = glass * 0.35 * brightness;
}
