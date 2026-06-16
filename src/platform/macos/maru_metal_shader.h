#ifndef MARU_PLATFORM_MACOS_METAL_SHADER_H
#define MARU_PLATFORM_MACOS_METAL_SHADER_H

#import <Foundation/Foundation.h>

/* terminal cell quad를 atlas texture로 sampling하는 Metal shader의 단일 출처다. visible
   Metal smoke와 제품 Metal renderer가 같은 GPU 코드를 공유해, 한쪽 셰이더만 바뀌어 sampling
   결과가 갈라지는 일을 막는다. VertexIn은 host쪽 정점(position 2 + uv 2 + color 3 + bg 4 =
   float 11개, 44바이트, tight-packed)과 같은 레이아웃이어야 하므로 packed 타입을 쓴다. bg.a가
   1이면 non-default 배경이라 cell을 그 색으로 채우고 glyph를 위에 blend하고, 0이면 배경 없음
   (glyph coverage만 그려 theme 기본 배경이 비친다). */
static NSString *const MARU_METAL_CELL_SHADER_SOURCE =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VertexIn { packed_float2 position; packed_float2 uv; packed_float3 color; packed_float4 bg; };\n"
     "struct VertexOut { float4 position [[position]]; float2 uv; float3 color; float4 bg; };\n"
     "vertex VertexOut maru_cell_vertex(uint vid [[vertex_id]], const device VertexIn *vertices [[buffer(0)]]) {\n"
     "  VertexOut out;\n"
     "  out.position = float4(float2(vertices[vid].position), 0.0, 1.0);\n"
     "  out.uv = float2(vertices[vid].uv);\n"
     "  out.color = float3(vertices[vid].color);\n"
     "  out.bg = float4(vertices[vid].bg);\n"
     "  return out;\n"
     "}\n"
     "fragment float4 maru_cell_fragment(VertexOut in [[stage_in]], texture2d<float> atlas_texture [[texture(0)]]) {\n"
     "  constexpr sampler atlas_sampler(coord::normalized, address::clamp_to_edge, filter::nearest);\n"
     // UV 규약: u<0 = 배경 전용(atlas 미샘플), u in [0,1] = 일반 글리프(흰색 coverage x 전경색),
     // u in [2,3] = 컬러 글리프(이모지). 컬러는 atlas의 premultiplied RGBA를 그대로 쓰고(전경색
     // 무시), 셀 배경 위에 합성한다. host가 컬러 글리프 UV에 +2.0 sentinel을 더해 보낸다.
     "  if (in.uv.x >= 2.0) {\n"
     "    float4 c = atlas_texture.sample(atlas_sampler, float2(in.uv.x - 2.0, in.uv.y));\n"
     "    float3 rgb = c.rgb + in.bg.rgb * (1.0 - c.a);\n"
     "    float a = max(in.bg.a, c.a);\n"
     "    return float4(rgb, a);\n"
     "  }\n"
     // 일반 글리프: premultiplied 출력. mix(bg.rgb, fg, cov)는 bg.a=0일 때 fg*cov로 환원되고,
     // bg.a=1이면 alpha 1이라 mix 색이 그대로 premultiplied가 된다.
     "  float coverage = (in.uv.x < 0.0) ? 0.0 : atlas_texture.sample(atlas_sampler, in.uv).a;\n"
     "  float3 rgb = mix(in.bg.rgb, in.color, coverage);\n"
     "  float a = max(in.bg.a, coverage);\n"
     "  return float4(rgb, a);\n"
     "}\n";

/* C4b: chrome rich GPU 프리미티브 — 둥근 사각형(per-corner radius + 변별 border + solid/gradient
   fill)을 SDF anti-aliasing으로 그린다. 셀 셰이더와 별개 파이프라인이지만 같은 premultiplied-over
   블렌딩에 합성된다. 색 blend는 linear 색공간에서 한다(sRGB→linear→blend→sRGB) — AA·gradient
   경계가 sRGB 직접 blend보다 정확하다. 정점은 host가 quad당 6개 생성하며 각 정점에 사각형
   파라미터(local 픽셀 좌표·half size·radii·border·색)를 복제해 싣는다(chrome quad 수가 적어
   instanced 없이 충분 — 후속 대량화 시 instanced로 전환). SDF 공식은 표준 rounded-box(iq). */
static NSString *const MARU_METAL_QUAD_SHADER_SOURCE =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct QuadIn { packed_float2 position; packed_float2 local; packed_float2 half_size; packed_float4 corner; packed_float4 border; packed_float4 fill0; packed_float4 fill1; packed_float4 border_color; float gradient_kind; };\n"
     "struct QuadOut { float4 position [[position]]; float2 local; float2 half_size; float4 corner; float4 border; float4 fill0; float4 fill1; float4 border_color; float gradient_kind; };\n"
     "static inline float3 srgb_to_linear(float3 c) { return select(c/12.92, pow((c+0.055)/1.055, 3.0), c > 0.04045); }\n"
     "static inline float3 linear_to_srgb(float3 c) { return select(c*12.92, 1.055*pow(c, 1.0/2.4)-0.055, c > 0.0031308); }\n"
     "vertex QuadOut maru_quad_vertex(uint vid [[vertex_id]], const device QuadIn *v [[buffer(0)]]) {\n"
     "  QuadOut o;\n"
     "  o.position = float4(float2(v[vid].position), 0.0, 1.0);\n"
     "  o.local = float2(v[vid].local);\n"
     "  o.half_size = float2(v[vid].half_size);\n"
     "  o.corner = float4(v[vid].corner);\n"
     "  o.border = float4(v[vid].border);\n"
     "  o.fill0 = float4(v[vid].fill0);\n"
     "  o.fill1 = float4(v[vid].fill1);\n"
     "  o.border_color = float4(v[vid].border_color);\n"
     "  o.gradient_kind = v[vid].gradient_kind;\n"
     "  return o;\n"
     "}\n"
     "fragment float4 maru_quad_fragment(QuadOut in [[stage_in]]) {\n"
     // 중심 원점 좌표. 모서리별 radius 선택: p.x<0=좌, p.y<0=상 → tl/tr/br/bl = corner.x/y/z/w.
     "  float2 p = in.local - in.half_size;\n"
     "  float r = (p.x < 0.0) ? ((p.y < 0.0) ? in.corner.x : in.corner.w) : ((p.y < 0.0) ? in.corner.y : in.corner.z);\n"
     // signed distance to rounded box(표준): q = |p| - half + r, d = min(max(q.x,q.y),0) + length(max(q,0)) - r.
     "  float2 q = abs(p) - in.half_size + r;\n"
     "  float d = min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - r;\n"
     "  float aa = max(fwidth(d), 1e-4);\n"
     "  float cov = 1.0 - smoothstep(-aa, aa, d);\n"
     "  if (cov <= 0.0) { discard_fragment(); }\n"
     // 변별 border: 안쪽 깊이(-d)에서 가장 가까운 변의 폭으로 경계를 잡는다(토대 근사 — 모서리
     // 변별 정밀화는 C4b 후속). top/right/bottom/left = border.x/y/z/w.
     "  float bw = max((p.y < 0.0) ? in.border.x : in.border.z, (p.x < 0.0) ? in.border.w : in.border.y);\n"
     "  float dist_in = -d;\n"
     "  float border_mix = (bw > 0.0) ? (1.0 - smoothstep(bw - aa, bw + aa, dist_in)) : 0.0;\n"
     // fill gradient: 1=수직(local.y/h), 2=수평(local.x/w), 0=solid.
     "  float t = (in.gradient_kind > 1.5) ? (in.local.x / (in.half_size.x * 2.0)) : (in.local.y / (in.half_size.y * 2.0));\n"
     "  float4 fill = (in.gradient_kind < 0.5) ? in.fill0 : mix(in.fill0, in.fill1, clamp(t, 0.0, 1.0));\n"
     // linear에서 fill↔border 섞고 coverage 적용, premultiplied 출력(셀과 같은 over 블렌딩).
     "  float3 rgb_lin = mix(srgb_to_linear(fill.rgb), srgb_to_linear(in.border_color.rgb), border_mix);\n"
     "  float a = mix(fill.a, in.border_color.a, border_mix) * cov;\n"
     "  float3 rgb = linear_to_srgb(rgb_lin) * a;\n"
     "  return float4(rgb, a);\n"
     "}\n";

/* C4b: chrome 그림자 — 둥근 사각형 아래 gaussian-approx blur drop shadow. quad와 별개 파이프라인,
   quad·셀보다 먼저(아래) 그린다. SDF rounded box 거리 d로 부드러운 감쇠(d<0 안=color.a, d>blur 바깥=0).
   정점은 host가 blur만큼 확장된 rect로 만들고(그림자가 박스 밖으로 번지게) local/half_size는 원본 박스
   기준이라 d가 원본 모서리에서 0이 된다. premultiplied 출력(셀·quad와 같은 over 블렌딩). */
static NSString *const MARU_METAL_SHADOW_SHADER_SOURCE =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct ShadowIn { packed_float2 position; packed_float2 local; packed_float2 half_size; packed_float4 corner; float blur; packed_float4 color; };\n"
     "struct ShadowOut { float4 position [[position]]; float2 local; float2 half_size; float4 corner; float blur; float4 color; };\n"
     "vertex ShadowOut maru_shadow_vertex(uint vid [[vertex_id]], const device ShadowIn *v [[buffer(0)]]) {\n"
     "  ShadowOut o;\n"
     "  o.position = float4(float2(v[vid].position), 0.0, 1.0);\n"
     "  o.local = float2(v[vid].local);\n"
     "  o.half_size = float2(v[vid].half_size);\n"
     "  o.corner = float4(v[vid].corner);\n"
     "  o.blur = v[vid].blur;\n"
     "  o.color = float4(v[vid].color);\n"
     "  return o;\n"
     "}\n"
     "fragment float4 maru_shadow_fragment(ShadowOut in [[stage_in]]) {\n"
     "  float2 p = in.local - in.half_size;\n"
     "  float r = (p.x < 0.0) ? ((p.y < 0.0) ? in.corner.x : in.corner.w) : ((p.y < 0.0) ? in.corner.y : in.corner.z);\n"
     "  float2 q = abs(p) - in.half_size + r;\n"
     "  float d = min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - r;\n"
     "  float blur = max(in.blur, 0.5);\n"
     "  float a = (1.0 - smoothstep(0.0, blur, d)) * in.color.a;\n"
     "  if (a <= 0.0) { discard_fragment(); }\n"
     "  return float4(in.color.rgb * a, a);\n"
     "}\n";

/* kitty graphics(K2): 이미지 placement를 textured quad로 그린다. 셀/quad/shadow와 별개 파이프라인이지만
   같은 premultiplied-over 블렌딩에 합성한다. 정점은 host가 placement당 6개 생성하며 dest 사각형 NDC와
   source UV([0,1] crop)를 싣는다. fragment는 image_id별 텍스처를 샘플해 premultiply(rgb*=a)한다 —
   투명 PNG·반투명 이미지가 셀(투명 배경)·텍스트와 자연스럽게 합성된다. ImageIn은 host MaruRendererImageVertex
   (position 2 + uv 2 = 16바이트 tight-pack)과 1:1. 샘플러는 linear(스케일 부드럽게)·clamp_to_edge. */
static NSString *const MARU_METAL_IMAGE_SHADER_SOURCE =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct ImageIn { packed_float2 position; packed_float2 uv; };\n"
     "struct ImageOut { float4 position [[position]]; float2 uv; };\n"
     "vertex ImageOut maru_image_vertex(uint vid [[vertex_id]], const device ImageIn *v [[buffer(0)]]) {\n"
     "  ImageOut o;\n"
     "  o.position = float4(float2(v[vid].position), 0.0, 1.0);\n"
     "  o.uv = float2(v[vid].uv);\n"
     "  return o;\n"
     "}\n"
     "fragment float4 maru_image_fragment(ImageOut in [[stage_in]], texture2d<float> img [[texture(0)]]) {\n"
     "  constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);\n"
     "  float4 c = img.sample(s, in.uv);\n"
     "  return float4(c.rgb * c.a, c.a);\n" // premultiplied over(셀·quad와 같은 블렌딩)
     "}\n";

#endif
