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
     // 배경 전용 cell은 sentinel UV(u<0)라 atlas를 sampling하지 않고 coverage 0(배경만)으로 본다.
     // 그 외엔 glyph atlas의 흰색 coverage를 샘플링한다. premultiplied 출력: mix(bg.rgb, fg, cov)는
     // bg.a=0일 때 fg*cov(=기존 float4(fg*coverage, coverage))로 정확히 환원되고, bg.a=1이면
     // alpha 1이라 mix 색이 그대로 premultiplied가 된다.
     "  float coverage = (in.uv.x < 0.0) ? 0.0 : atlas_texture.sample(atlas_sampler, in.uv).a;\n"
     "  float3 rgb = mix(in.bg.rgb, in.color, coverage);\n"
     "  float a = max(in.bg.a, coverage);\n"
     "  return float4(rgb, a);\n"
     "}\n";

#endif
