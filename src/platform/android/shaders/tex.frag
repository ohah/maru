#version 450
// 글리프 아틀라스 샘플링 — 부분 업데이트가 반영되는지 보려고 쓴다.
layout(push_constant) uniform Push { vec4 rect; vec4 color; float opacity; } pc;
layout(set = 0, binding = 0) uniform sampler2D atlas;
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
void main() { outColor = vec4(texture(atlas, vUV).rgb, 1.0); }
