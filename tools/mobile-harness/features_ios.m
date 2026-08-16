// PoC 5(iOS): maru 가 Metal 세부를 파고들어 얻은 **여섯 기능**이 iOS 에서도 되는가.
//
// 이게 이식 난이도를 정하는 진짜 관문이다. 화면이 뜨는 것과, 지금 쓰고 있는
// 렌더 기법이 그대로 되는 것은 다르다. 각 항목은 **픽셀을 읽어** 판정한다.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>

#define W 256
#define H 64

static NSString *const kShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float2 uv; };\n"
     "struct Uni { float4 rect; float4 color; float opacity; };\n"
     "vertex VOut v_main(uint vid [[vertex_id]], constant Uni &u [[buffer(0)]]) {\n"
     "  float2 p[4] = { float2(u.rect.x, u.rect.y), float2(u.rect.z, u.rect.y),\n"
     "                  float2(u.rect.x, u.rect.w), float2(u.rect.z, u.rect.w) };\n"
     "  float2 t[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };\n"
     "  VOut o; o.pos = float4(p[vid], 0, 1); o.uv = t[vid]; return o;\n"
     "}\n"
     // opacity uniform 을 프래그먼트에서 곱한다 — maru 의 커서 blink 페이드와 같은 구조.
     "fragment float4 f_solid(VOut in [[stage_in]], constant Uni &u [[buffer(0)]]) {\n"
     "  return float4(u.color.rgb, 1.0) * u.opacity;\n"
     "}\n"
     "fragment float4 f_tex(VOut in [[stage_in]], constant Uni &u [[buffer(0)]],\n"
     "                      texture2d<float> tex [[texture(0)]]) {\n"
     "  constexpr sampler s(filter::nearest);\n"
     "  return float4(tex.sample(s, in.uv).rgb, 1.0);\n"
     "}\n";

typedef struct { float rect[4]; float color[4]; float opacity; float _pad[3]; } Uni;

static int passed = 0, failed = 0;
static void report(const char *name, int ok, const char *detail) {
    printf("  %-28s %s   %s\n", name, ok ? "PASS" : "FAIL", detail ? detail : "");
    if (ok) passed++; else failed++;
}

static void readback(id<MTLTexture> tex, uint8_t *px) {
    [tex getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
}
static uint8_t *at(uint8_t *px, int x, int y) { return px + ((size_t)y * W + x) * 4; }

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no_device\n"); return 1; }
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kShader options:nil error:&err];
        if (!lib) { printf("shader_fail=%s\n", err.description.UTF8String); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];

        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> target = [dev newTextureWithDescriptor:td];
        uint8_t *px = calloc(W * H, 4);

        // 파이프라인 셋: solid / premultiplied blend / straight blend / 텍스처
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v_main"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f_solid"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> pSolid = [dev newRenderPipelineStateWithDescriptor:pd error:&err];

        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;            // premultiplied
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        id<MTLRenderPipelineState> pPremul = [dev newRenderPipelineStateWithDescriptor:pd error:&err];

        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;    // straight
        id<MTLRenderPipelineState> pStraight = [dev newRenderPipelineStateWithDescriptor:pd error:&err];

        pd.colorAttachments[0].blendingEnabled = NO;
        pd.fragmentFunction = [lib newFunctionWithName:@"f_tex"];
        id<MTLRenderPipelineState> pTex = [dev newRenderPipelineStateWithDescriptor:pd error:&err];

        printf("iOS Metal — 여섯 기능\n");

        // ── 1. per-cell clip: draw 사이에 scissor 를 바꿀 수 있는가 (ABI v169)
        {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pSolid];
            // 화면 전체를 덮는 quad 를 두 번 그리되 scissor 로 각각 다른 절반만 남긴다.
            Uni u = {{-1, -1, 1, 1}, {1, 0, 0, 1}, 1.0f, {0}};
            [e setScissorRect:(MTLScissorRect){0, 0, W / 2, H}];
            [e setVertexBytes:&u length:sizeof(u) atIndex:0];
            [e setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            u.color[0] = 0; u.color[2] = 1;                       // 파랑
            [e setScissorRect:(MTLScissorRect){W / 2, 0, W / 2, H}];
            [e setVertexBytes:&u length:sizeof(u) atIndex:0];
            [e setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
            readback(target, px);
            uint8_t *l = at(px, W / 4, H / 2), *r = at(px, 3 * W / 4, H / 2);
            char d[96]; snprintf(d, sizeof d, "left R=%d B=%d · right R=%d B=%d", l[2], l[0], r[2], r[0]);
            report("1. per-cell clip", l[2] > 200 && l[0] < 50 && r[0] > 200 && r[2] < 50, d);
        }

        // ── 2. blink opacity uniform: draw 마다 uniform 을 바꿀 수 있는가
        {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pSolid];
            for (int i = 0; i < 4; i++) {
                float x0 = -1.0f + 0.5f * i, x1 = x0 + 0.5f;
                Uni u = {{x0, -1, x1, 1}, {1, 1, 1, 1}, 0.25f * (i + 1), {0}};
                [e setVertexBytes:&u length:sizeof(u) atIndex:0];
                [e setFragmentBytes:&u length:sizeof(u) atIndex:0];
                [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            }
            [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
            readback(target, px);
            int v[4];
            for (int i = 0; i < 4; i++) v[i] = at(px, W / 8 + i * W / 4, H / 2)[1];
            char d[96]; snprintf(d, sizeof d, "G=%d,%d,%d,%d (단조 증가여야)", v[0], v[1], v[2], v[3]);
            report("2. blink opacity uniform", v[0] < v[1] && v[1] < v[2] && v[2] < v[3], d);
        }

        // ── 3. per-draw blend 모드: 같은 인코더 안에서 파이프라인을 바꿀 수 있는가
        {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            // 같은 색·같은 alpha 를 두 blend 모드로 그려 결과가 달라야 한다.
            Uni u = {{-1, -1, 0, 1}, {1, 1, 1, 1}, 0.5f, {0}};
            [e setRenderPipelineState:pPremul];
            [e setVertexBytes:&u length:sizeof(u) atIndex:0];
            [e setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            u.rect[0] = 0; u.rect[2] = 1;
            [e setRenderPipelineState:pStraight];
            [e setVertexBytes:&u length:sizeof(u) atIndex:0];
            [e setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
            readback(target, px);
            int pre = at(px, W / 4, H / 2)[1], str = at(px, 3 * W / 4, H / 2)[1];
            char d[96]; snprintf(d, sizeof d, "premul G=%d vs straight G=%d (달라야)", pre, str);
            report("3. per-draw blend", pre != str, d);
        }

        // ── 4. 아틀라스 부분 업데이트: 텍스처 일부만 갱신되는가
        {
            MTLTextureDescriptor *ad =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                   width:16 height:16 mipmapped:NO];
            ad.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> atlas = [dev newTextureWithDescriptor:ad];
            uint8_t base[16 * 16 * 4];
            memset(base, 0, sizeof base);
            for (int i = 0; i < 16 * 16; i++) base[i * 4 + 1] = 255;      // 전체 녹색
            [atlas replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0
                       withBytes:base bytesPerRow:16 * 4];
            // 왼쪽 위 4×4 만 빨강으로 부분 갱신 — maru 가 글리프를 아틀라스에 넣는 방식
            uint8_t patch[4 * 4 * 4];
            memset(patch, 0, sizeof patch);
            for (int i = 0; i < 16; i++) patch[i * 4 + 2] = 255;
            [atlas replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0
                       withBytes:patch bytesPerRow:4 * 4];

            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pTex];
            Uni u = {{-1, -1, 1, 1}, {1, 1, 1, 1}, 1.0f, {0}};
            [e setVertexBytes:&u length:sizeof(u) atIndex:0];
            [e setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [e setFragmentTexture:atlas atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
            readback(target, px);
            uint8_t *tl = at(px, W / 16, H / 16);          // 패치 영역
            uint8_t *br = at(px, W * 3 / 4, H * 3 / 4);    // 원래 영역
            char d[96]; snprintf(d, sizeof d, "patch R=%d · base G=%d", tl[2], br[1]);
            report("4. 아틀라스 부분 업데이트", tl[2] > 200 && br[1] > 200, d);
        }

        // ── 5. 자연폭 quad: quad 마다 다른 크기·UV
        {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = target;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pSolid];
            // 폭이 제각각인 quad 를 이어 붙인다(letter-spacing 자연폭과 같은 요구)
            float widths[4] = {0.2f, 0.5f, 0.3f, 0.8f};
            float x = -1.0f;
            for (int i = 0; i < 4; i++) {
                Uni u = {{x, -1, x + widths[i], 1}, {1, 1, 1, 1}, 1.0f, {0}};
                [e setVertexBytes:&u length:sizeof(u) atIndex:0];
                [e setFragmentBytes:&u length:sizeof(u) atIndex:0];
                [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                x += widths[i] + 0.1f;   // 사이를 띄워 경계가 보이게
            }
            [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
            readback(target, px);
            // **폭이 실제로 서로 다른지**를 잰다. 전환 횟수로 판정하면 마지막 quad 가
            // 화면 끝까지 이어질 때 오답이 난다(처음 그렇게 짰다가 오탐을 봤다).
            int runlen[8] = {0}, nrun = 0, prev = 0, cur = 0;
            for (int xx = 0; xx < W && nrun < 8; xx++) {
                int lit = at(px, xx, H / 2)[1] > 128;
                if (lit != prev) { if (prev && cur) runlen[nrun++] = cur; cur = 0; prev = lit; }
                if (lit) cur++;
            }
            if (prev && cur && nrun < 8) runlen[nrun++] = cur;
            int distinct = 0;
            for (int i = 0; i < nrun; i++) {
                int dup = 0;
                for (int j = 0; j < i; j++) if (runlen[j] == runlen[i]) dup = 1;
                if (!dup) distinct++;
            }
            char d[96]; snprintf(d, sizeof d, "흰 구간 폭 %d,%d,%d,%d px · 서로 다른 값 %d개",
                                 runlen[0], runlen[1], runlen[2], runlen[3], distinct);
            report("5. 자연폭 quad", nrun >= 4 && distinct >= 3, d);
        }

        // ── 6. present 페이싱: 오프스크린에서는 판정 불가
        report("6. present 페이싱", 0, "오프스크린 범위 밖 — CAMetalLayer 필요");

        printf("\n결과: %d PASS / %d FAIL\n", passed, failed);
        free(px);
        return failed > 1 ? 1 : 0;   // 6번은 예정된 미확인
    }
}
