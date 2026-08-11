#version 450
// 둥근 모서리를 SDF 로 자른다 — maru 의 rich quad 가 corner_radii 를 쓰므로
// Metal 쪽(chrome_app.m)과 같은 식을 써서 **두 백엔드가 같은 모양**을 내는지 본다.
layout(push_constant) uniform Push {
    vec4 rect_px;
    vec4 color;
    vec4 misc;      // radius, viewport.x, viewport.y, is_text
} pc;
layout(location = 0) in vec2 vLocal;
layout(location = 1) in vec2 vHalf;
layout(location = 0) out vec4 outColor;
void main() {
    float r = min(pc.misc.x, min(vHalf.x, vHalf.y));
    vec2 q = abs(vLocal) - (vHalf - r);
    float d = length(max(q, 0.0)) - r;
    if (d > 0.5) discard;
    outColor = pc.color;
}
