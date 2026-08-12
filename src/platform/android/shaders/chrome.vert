#version 450
// chrome draw-list 의 quad 를 **픽셀 좌표**로 받아 NDC 로 옮긴다. maru 의 ChromeDraw 가
// 픽셀을 쓰므로(sub-cell 정밀도) 셰이더도 같은 단위를 받는 것이 자연스럽다.
layout(push_constant) uniform Push {
    vec4 rect_px;   // x0,y0,x1,y1
    vec4 color;
    vec4 misc;      // radius, viewport.x, viewport.y, kind
    vec4 cell;      // col, row, atlas_cols, atlas_rows
} pc;
layout(location = 0) out vec2 vLocal;
layout(location = 1) out vec2 vHalf;
layout(location = 2) out vec2 vUV;
void main() {
    vec2 p0 = pc.rect_px.xy;
    vec2 p1 = pc.rect_px.zw;
    vec2 corners[4] = vec2[4](vec2(p0.x, p1.y), vec2(p1.x, p1.y),
                              vec2(p0.x, p0.y), vec2(p1.x, p0.y));
    vec2 px = corners[gl_VertexIndex];
    // Vulkan 은 NDC 의 Y 가 아래로 향한다 — Metal 과 부호가 반대다(실측으로 잡은 차이).
    vec2 ndc = vec2(px.x / pc.misc.y * 2.0 - 1.0, px.y / pc.misc.z * 2.0 - 1.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    vec2 half_size = (p1 - p0) * 0.5;
    vHalf = half_size;
    vLocal = px - (p0 + half_size);
    vec2 t[4] = vec2[4](vec2(0,1), vec2(1,1), vec2(0,0), vec2(1,0));
    vUV = (pc.cell.xy + t[gl_VertexIndex]) / pc.cell.zw;
}
