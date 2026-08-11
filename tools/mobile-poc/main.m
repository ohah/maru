// PoC 2b + 3: Zig 코어를 iOS 시뮬레이터에서 실행하고, Metal 오프스크린에 그린다.
//
// Zig 가 iOS 용 libSystem 링크를 못 해서(실측) Zig 는 .a 까지만 만들고
// 링크는 clang 이 한다 — 실제 앱에서도 이 구조가 된다.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UTCoreTypes.h>
#include <stdio.h>

extern unsigned int maru_poc_smoke(void);

// 셀 배경 quad 하나를 그리는 최소 셰이더. maru 의 실제 파이프라인은 훨씬 크지만,
// 여기서 보려는 것은 "iOS Metal 이 살아 있고 픽셀이 나오는가" 하나다.
static NSString *const kShader = @"#include <metal_stdlib>\n"
                                  "using namespace metal;\n"
                                  "struct VOut { float4 pos [[position]]; float4 color; };\n"
                                  "vertex VOut v_main(uint vid [[vertex_id]],\n"
                                  "                   constant float4 *rect [[buffer(0)]],\n"
                                  "                   constant float4 *col [[buffer(1)]]) {\n"
                                  "  float2 p[4] = { float2(rect->x, rect->y), float2(rect->z, rect->y),\n"
                                  "                  float2(rect->x, rect->w), float2(rect->z, rect->w) };\n"
                                  "  VOut o; o.pos = float4(p[vid], 0, 1); o.color = *col; return o;\n"
                                  "}\n"
                                  "fragment float4 f_main(VOut in [[stage_in]]) { return in.color; }\n";

int main(void) {
    @autoreleasepool {
        // ── 2b: Zig 코어가 실제로 도는가
        unsigned int rc = maru_poc_smoke();
        printf("ZIG_CORE rc=%u\n", rc);
        if (rc != 0) return 1;

        // ── 3: Metal 오프스크린 렌더
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("METAL no_device\n"); return 2; }
        printf("METAL device=%s\n", dev.name.UTF8String);

        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kShader options:nil error:&err];
        if (!lib) { printf("METAL shader_fail=%s\n", err.description.UTF8String); return 3; }

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"v_main"];
        pd.fragmentFunction = [lib newFunctionWithName:@"f_main"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> pipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pipe) { printf("METAL pipeline_fail=%s\n", err.description.UTF8String); return 4; }

        const NSUInteger W = 480, H = 240;
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipe];
        // 터미널 셀 격자를 흉내 낸 quad 들을 그린다 — maru 의 draw-list 가 내는 모양과 같은 종류다.
        // 실제 파이프라인은 글리프 아틀라스를 샘플링하지만, 여기서 보려는 것은
        // "셀 단위 quad 를 원하는 자리에 원하는 색으로 낼 수 있는가"다.
        const int COLS = 20, ROWS = 6;
        for (int r = 0; r < ROWS; r++) {
            for (int c = 0; c < COLS; c++) {
                float x0 = -1.0f + 2.0f * ((float)c / COLS) + 0.004f;
                float x1 = -1.0f + 2.0f * ((float)(c + 1) / COLS) - 0.004f;
                float y1 = 1.0f - 2.0f * ((float)r / ROWS) - 0.01f;
                float y0 = 1.0f - 2.0f * ((float)(r + 1) / ROWS) + 0.01f;
                float rect[4] = {x0, y0, x1, y1};
                // 행마다 다른 ANSI 계열 색 — SGR 색 투영을 흉내
                float palette[6][4] = {
                    {0.86f, 0.20f, 0.18f, 1}, {0.20f, 0.72f, 0.35f, 1},
                    {0.90f, 0.68f, 0.18f, 1}, {0.25f, 0.52f, 0.90f, 1},
                    {0.70f, 0.35f, 0.85f, 1}, {0.25f, 0.75f, 0.80f, 1},
                };
                float color[4];
                float fade = 0.35f + 0.65f * ((float)c / COLS);
                for (int i = 0; i < 3; i++) color[i] = palette[r][i] * fade;
                color[3] = 1.0f;
                [enc setVertexBytes:rect length:sizeof(rect) atIndex:0];
                [enc setVertexBytes:color length:sizeof(color) atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            }
        }
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        // 픽셀을 읽어 실제로 그려졌는지 판정하고 PNG 로 남긴다 — "안 죽었다"로는 부족하다.
        uint8_t *px = calloc(W * H, 4);
        [tex getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        size_t center = ((H / 2) * W + (W / 2)) * 4;
        int lit = 0;
        for (size_t i = 0; i < W * H; i++) {
            if (px[i * 4] > 20 || px[i * 4 + 1] > 20 || px[i * 4 + 2] > 20) lit++;
        }
        printf("PIXEL center=B%d,G%d,R%d  lit=%d/%lu (%.1f%%)\n",
               px[center], px[center + 1], px[center + 2], lit,
               (unsigned long)(W * H), 100.0 * lit / (W * H));

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, W, H, 8, W * 4, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        const char *outPath = getenv("POC_PNG");
        if (!outPath) outPath = "/tmp/maru-ios-poc.png";
        CFStringRef pathStr = CFStringCreateWithCString(NULL, outPath, kCFStringEncodingUTF8);
        CFURLRef url = CFURLCreateWithFileSystemPath(NULL, pathStr, kCFURLPOSIXPathStyle, false);
        CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, (CFStringRef)UTTypePNG.identifier, 1, NULL);
        int saved = 0;
        if (dest) {
            CGImageDestinationAddImage(dest, img, NULL);
            saved = CGImageDestinationFinalize(dest);
            CFRelease(dest);
        }
        printf("PNG %s path=%s\n", saved ? "SAVED" : "FAIL", outPath);
        CFRelease(url); CFRelease(pathStr);
        CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);

        int ok = lit > (int)(W * H / 4);
        printf("POC3 %s\n", ok ? "PASS" : "FAIL");
        free(px);
        return ok ? 0 : 5;
    }
}
