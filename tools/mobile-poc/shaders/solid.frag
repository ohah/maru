#version 450
// opacity 를 곱한다 — maru 의 커서 blink 페이드와 같은 구조(uniform 하나로 프레임마다 바뀐다).
layout(push_constant) uniform Push { vec4 rect; vec4 color; float opacity; } pc;
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
void main() { outColor = vec4(pc.color.rgb, 1.0) * pc.opacity; }
