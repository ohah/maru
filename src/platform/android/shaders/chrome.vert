#version 450
// chrome draw-list 의 quad 를 **픽셀 좌표**로 받아 NDC 로 옮긴다. maru 의 ChromeDraw 가
// 픽셀을 쓰므로(sub-cell 정밀도) 셰이더도 같은 단위를 받는 것이 자연스럽다.
//
// **quad 마다 draw call 을 내지 않는다.** 목록 전체를 storage buffer 로 한 번 올리고
// 인스턴스 드로우 한 번으로 그린다 — 모바일 타일 기반 GPU 는 draw call 오버헤드에
// 특히 민감하다(docs/mobile-platform.md §1).
struct Quad {
    vec4 rect_px;   // x0,y0,x1,y1
    vec4 color;
    vec4 misc;      // radius, viewport.x, viewport.y, kind
    vec4 cell;      // col, row, atlas_cols, atlas_rows
};
layout(std430, set = 0, binding = 2) readonly buffer Quads { Quad q[]; } quads;

// frag 는 이제 push constant 를 못 읽는다(quad 마다 다르다) — 필요한 값을 varying 으로 넘긴다.
layout(location = 0) out vec2 vLocal;
layout(location = 1) out vec2 vHalf;
layout(location = 2) out vec2 vUV;
layout(location = 3) out vec4 vColor;
layout(location = 4) out float vRadius;
layout(location = 5) out float vKind;
// 자기 칸의 UV 경계. **이웃 칸이 새어 들지 않게** frag 가 여기 안으로 자른다 — 아틀라스는
// 칸 사이에 여백이 없고 블록 글자(█)는 칸을 가득 채워서, 바로 아래 칸을 그릴 때 그 아래
// 모서리가 딸려 온다(화살표 라벨 위에 가로 획으로 나타났다).
layout(location = 6) out vec4 vUVBounds;

void main() {
    Quad d = quads.q[gl_InstanceIndex];
    vec2 p0 = d.rect_px.xy;
    vec2 p1 = d.rect_px.zw;
    vec2 corners[4] = vec2[4](vec2(p0.x, p1.y), vec2(p1.x, p1.y),
                              vec2(p0.x, p0.y), vec2(p1.x, p0.y));
    vec2 px = corners[gl_VertexIndex];
    // Vulkan 은 NDC 의 Y 가 아래로 향한다 — Metal 과 부호가 반대다(실측으로 잡은 차이).
    vec2 ndc = vec2(px.x / d.misc.y * 2.0 - 1.0, px.y / d.misc.z * 2.0 - 1.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    vec2 half_size = (p1 - p0) * 0.5;
    vHalf = half_size;
    vLocal = px - (p0 + half_size);
    vec2 t[4] = vec2[4](vec2(0,1), vec2(1,1), vec2(0,0), vec2(1,0));
    vUV = (d.cell.xy + t[gl_VertexIndex]) / d.cell.zw;
    vUVBounds = vec4(d.cell.xy / d.cell.zw, (d.cell.xy + 1.0) / d.cell.zw);
    vColor = d.color;
    vRadius = d.misc.x;
    vKind = d.misc.w;
}
