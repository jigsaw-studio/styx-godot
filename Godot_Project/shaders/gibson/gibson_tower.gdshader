// Source: Copyright (c) 2026 Steve Castellotti
// License: MIT License
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec3 size = vec3(2.0, 10.0, 2.0);        // side, height, side, in city units
uniform vec3 glass : source_color = vec3(0.1, 0.8, 0.5);
uniform vec3 text_color : source_color = vec3(0.6, 1.0, 0.8);
uniform vec3 cap_color : source_color = vec3(1.0, 0.2, 0.2);
uniform float cap_fraction = 0.0;
uniform float brightness = 1.0;
uniform bool selected = false;                   // drawn in the highlight colour, edges at full strength
uniform vec3 highlight : source_color = vec3(0.5, 0.4, 1.0);
uniform bool stripes = false;                    // film schemes: refused
uniform bool cap_stripes = false;                // film schemes: a partly refused cap
uniform bool dashes = false;                     // film schemes: outside the tunnel
uniform bool windows = false;                    // Night
uniform sampler2D atlas : filter_nearest, repeat_disable;
uniform sampler2D page : filter_nearest, repeat_enable;
uniform float page_rows = 1.0;

varying vec3 lp;   // position on the unit box, -0.5 .. 0.5
varying vec3 ln;   // the face's normal in the box's own space

void vertex() {
    lp = VERTEX;
    ln = NORMAL;
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
    bool flat_face = abs(ln.y) > 0.5;

    // u runs left to right as seen from outside.
    float u = ln.z > 0.5 ? lp.x + 0.5 : (ln.z < -0.5 ? 0.5 - lp.x : (ln.x > 0.5 ? 0.5 - lp.z : lp.z + 0.5));
    float d = (0.5 - lp.y) * size.y;                    // down from the top
    float cell_h = size.x / 24.0 * 1.5;
    vec2 cell = vec2(u * 24.0, d / cell_h);
    // Derivatives of the continuous coordinate, before any floor or branch.
    vec2 dx = dFdx(cell);
    vec2 dy = dFdy(cell);
    float rows_px = 1.0 / max(fwidth(cell.y), 0.0001);
    float detail = clamp((rows_px - 4.0) / 4.0, 0.0, 1.0);

    // Edges: distance to the nearest border of the face, in city units.
    float to_side = min(u, 1.0 - u) * size.x;
    float to_cap = min(d, size.y - d);
    float to_top_edge = flat_face ? min(min(lp.x + 0.5, 0.5 - lp.x), min(lp.z + 0.5, 0.5 - lp.z)) * size.x : 1.0e3;
    float side_w = max(0.05, 1.5 * fwidth(to_side));
    float cap_w = max(0.05, 1.5 * fwidth(to_cap));
    float flat_w = max(0.05, 1.5 * fwidth(to_top_edge));
    float edge_v = 1.0 - smoothstep(0.0, side_w, to_side);
    float edge_h = 1.0 - smoothstep(0.0, cap_w, to_cap);
    if (dashes) {
        edge_v *= step(mod(d, 0.8), 0.4);
        edge_h *= step(mod(u * size.x, 0.8), 0.4);
    }
    float edge = max(edge_v, edge_h);
    if (flat_face) {
        edge = 1.0 - smoothstep(0.0, flat_w, to_top_edge);
        if (dashes) {
            edge *= step(mod(lp.x * size.x + lp.z * size.x, 0.8), 0.4);
        }
    }

    bool in_cap = cap_fraction > 0.0 && (flat_face ? lp.y > 0.0 : d < cap_fraction * size.y);
    vec3 glass_here = selected ? highlight : (in_cap ? cap_color : glass);
    vec3 text_here = selected ? highlight : (in_cap ? cap_color : text_color);

    float stripe = 0.25 * step(fract((u * size.x + d) / 0.6), 0.5);
    float fill = 0.10;
    float coverage = 0.0;
    if (flat_face) {
        fill = 0.22;
    } else {
        // The glyph this cell holds, and the page's row (the page repeats down the tower).
        vec2 whole = floor(cell);
        vec2 page_uv = (vec2(whole.x, mod(whole.y, page_rows)) + 0.5) / vec2(24.0, page_rows);
        float gi = floor(texture(page, page_uv).r * 255.0 + 0.5);

        // Near: the glyph from the atlas, sampled at texel centres with the cell's own gradients.
        vec2 f = fract(cell) * vec2(8.0, 10.0);
        vec2 texel = floor(f) + 0.5;
        vec2 atlas_px = vec2(mod(gi, 8.0), floor(gi / 8.0)) * vec2(8.0, 10.0) + texel;
        vec2 grad_scale = vec2(8.0, 10.0) / vec2(64.0, 80.0);
        float glyph = textureGrad(atlas, atlas_px / vec2(64.0, 80.0), dx * grad_scale, dy * grad_scale).r;
        glyph *= step(0.5, gi);

        // Far: a bar across the middle 60 % of the row wherever the glyph is not a space,
        // or, in Night, a lit strip chosen by a hash of the cell.
        float row_y = fract(cell.y);
        float band = smoothstep(0.2, 0.25, row_y) * (1.0 - smoothstep(0.75, 0.8, row_y));
        float far_cov = step(0.5, gi) * band * 0.5;
        if (windows) {
            far_cov = step(hash21(whole), 0.7) * step(0.5, gi) * band * 0.8;
        }
        coverage = mix(far_cov, glyph, detail);
        if (stripes) {
            coverage *= 0.3;
            fill += stripe;
        }
        if (in_cap && cap_stripes) {
            fill += stripe;
        }
    }
    if (flat_face && in_cap && cap_stripes) {
        fill += 0.25 * step(fract((lp.x + lp.z) * size.x / 0.6), 0.5);
    }

    float level = selected ? 1.0 : brightness;
    ALBEDO = (glass_here * (fill + edge * (selected ? 1.5 : 1.0)) + text_here * coverage) * level;
}
