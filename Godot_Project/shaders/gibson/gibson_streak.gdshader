// Source: Copyright (c) 2026 Steve Castellotti
// License: MIT License
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// A car: a bright head with a tail that fades out, on a plane lying flat. The head is
// at the end where UV.y is 0 (the plane's -Z end, the way the car faces). The colour
// arrives as the instance colour of a MultiMesh.
void fragment() {
    float along = 1.0 - UV.y;                       // 1 at the head, 0 at the tail
    float tail = pow(along, 3.0);
    float head = smoothstep(0.94, 1.0, along);
    float across = 1.0 - smoothstep(0.0, 0.5, abs(UV.x - 0.5));
    float shape = (tail * 0.8 + head * 0.6) * across;
    ALBEDO = COLOR.rgb * shape;
}
