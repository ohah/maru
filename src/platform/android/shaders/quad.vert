#version 450
// maru 의 draw-list 와 같은 구조: quad 를 push constant 의 rect 로 낸다.
//
// **Vulkan 은 NDC 의 Y 가 아래로 향한다**(Metal 은 위로). 그래서 같은 rect·같은 UV 를
// 주면 텍스처가 상하로 뒤집힌다 — 실측으로 잡았다(아틀라스 패치가 화면 반대편에
// 나왔다). 여기서 UV 의 v 를 뒤집어 Metal 쪽과 같은 그림이 나오게 맞춘다.
layout(push_constant) uniform Push {
    vec4 rect;      // x0,y0,x1,y1 (NDC)
    vec4 color;
    float opacity;
} pc;
layout(location = 0) out vec2 vUV;
void main() {
    vec2 p[4] = vec2[4](vec2(pc.rect.x, pc.rect.y), vec2(pc.rect.z, pc.rect.y),
                        vec2(pc.rect.x, pc.rect.w), vec2(pc.rect.z, pc.rect.w));
    vec2 t[4] = vec2[4](vec2(0,0), vec2(1,0), vec2(0,1), vec2(1,1));
    gl_Position = vec4(p[gl_VertexIndex], 0.0, 1.0);
    vUV = t[gl_VertexIndex];
}
