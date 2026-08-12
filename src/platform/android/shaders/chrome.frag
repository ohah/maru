#version 450
// 둥근 모서리를 SDF 로 자르고, kind 에 따라 글리프·아이콘 아틀라스를 샘플링한다 —
// Metal 쪽(ios_app_host.m)과 같은 식을 써서 **두 백엔드가 같은 그림**을 내는지 본다.
//
// 인스턴스 드로우로 바뀌면서 quad 별 값(색·radius·kind)은 push constant 가 아니라
// vertex 가 넘긴 varying 으로 온다 — 한 번의 draw call 안에서 quad 마다 달라야 한다.
layout(set = 0, binding = 0) uniform sampler2D glyphs;   // 한글·영어 아틀라스(R8)
layout(set = 0, binding = 1) uniform sampler2D icons;    // Zig 가 만든 아이콘 coverage(RGBA8, alpha)
layout(location = 0) in vec2 vLocal;
layout(location = 1) in vec2 vHalf;
layout(location = 2) in vec2 vUV;
layout(location = 3) in vec4 vColor;
layout(location = 4) in float vRadius;
layout(location = 5) in float vKind;
layout(location = 0) out vec4 outColor;
void main() {
    float r = min(vRadius, min(vHalf.x, vHalf.y));
    vec2 q = abs(vLocal) - (vHalf - r);
    float d = length(max(q, 0.0)) - r;
    if (d > 0.5) discard;

    if (vKind > 1.5) {                           // 아이콘 — alpha 가 coverage 다
        float cov = texture(icons, vUV).a;
        if (cov < 0.04) discard;
        outColor = vec4(vColor.rgb, vColor.a * cov);
        return;
    }
    if (vKind > 0.5) {                           // 글리프
        float cov = texture(glyphs, vUV).r;
        if (cov < 0.04) discard;
        outColor = vec4(vColor.rgb, vColor.a * cov);
        return;
    }
    outColor = vColor;
}
