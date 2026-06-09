#ifndef MARU_PLATFORM_MACOS_METAL_SHADER_H
#define MARU_PLATFORM_MACOS_METAL_SHADER_H

#import <Foundation/Foundation.h>

/* terminal cell quad를 atlas texture로 sampling하는 Metal shader의 단일 출처다. visible
   Metal smoke와 제품 Metal renderer가 같은 GPU 코드를 공유해, 한쪽 셰이더만 바뀌어 sampling
   결과가 갈라지는 일을 막는다. VertexIn은 host쪽 정점(float 4개, 16바이트, tight-packed)과
   같은 레이아웃이어야 하므로 packed_float2 두 개를 쓴다. */
static NSString *const MARU_METAL_CELL_SHADER_SOURCE =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VertexIn { packed_float2 position; packed_float2 uv; packed_float3 color; };\n"
     "struct VertexOut { float4 position [[position]]; float2 uv; float3 color; };\n"
     "vertex VertexOut maru_cell_vertex(uint vid [[vertex_id]], const device VertexIn *vertices [[buffer(0)]]) {\n"
     "  VertexOut out;\n"
     "  out.position = float4(float2(vertices[vid].position), 0.0, 1.0);\n"
     "  out.uv = float2(vertices[vid].uv);\n"
     "  out.color = float3(vertices[vid].color);\n"
     "  return out;\n"
     "}\n"
     "fragment float4 maru_cell_fragment(VertexOut in [[stage_in]], texture2d<float> atlas_texture [[texture(0)]]) {\n"
     "  constexpr sampler atlas_sampler(coord::normalized, address::clamp_to_edge, filter::nearest);\n"
     // glyph atlas는 흰색 coverage(premultiplied alpha)다. 전경색을 coverage에 곱해 칠한다.
     "  float4 texel = atlas_texture.sample(atlas_sampler, in.uv);\n"
     "  return float4(in.color * texel.a, texel.a);\n"
     "}\n";

#endif
