#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int32_t status;
    uint32_t window_visible;
    uint32_t presented_frames;
    uint32_t drawable_failures;
    uint32_t requested_cells;
    uint32_t rendered_cells;
    uint32_t readback_samples;
    uint32_t readback_non_clear_pixels;
    uint32_t readback_failures;
} MaruMetalSmokeResult;

typedef struct {
    uint16_t row;
    uint16_t col;
    uint16_t width;
    uint16_t reserved;
    uint32_t codepoint;
    uint32_t slot_id;
} MaruMetalSmokeCell;

typedef struct {
    float x;
    float y;
    float r;
    float g;
    float b;
    float a;
} MaruMetalSmokeVertex;

typedef struct {
    NSUInteger x;
    NSUInteger y;
} MaruMetalSmokeSample;

static const NSUInteger maru_readback_stride = 256;

// VertexIn은 host쪽 MaruMetalSmokeVertex(float 6개, 24바이트, tight-packed)와 같은
// 메모리 레이아웃을 가져야 한다. MSL에서 float4는 16바이트 정렬이라 { float2; float4; }는
// 32바이트가 되어, host 24바이트 배열을 stride 32로 읽게 된다(색/위치 깨짐 + buffer OOB
// read). packed_float2/packed_float4는 4바이트 정렬이라 host struct와 정확히 일치한다.
static NSString *const maru_cell_shader_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VertexIn { packed_float2 position; packed_float4 color; };\n"
     "struct VertexOut { float4 position [[position]]; float4 color; };\n"
     "vertex VertexOut maru_cell_vertex(uint vid [[vertex_id]], const device VertexIn *vertices [[buffer(0)]]) {\n"
     "  VertexOut out;\n"
     "  out.position = float4(float2(vertices[vid].position), 0.0, 1.0);\n"
     "  out.color = float4(vertices[vid].color);\n"
     "  return out;\n"
     "}\n"
     "fragment float4 maru_cell_fragment(VertexOut in [[stage_in]]) {\n"
     "  return in.color;\n"
     "}\n";

static void maru_pump_app_once(void) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.016];
    NSEvent *event = [NSApp
        nextEventMatchingMask:NSEventMaskAny
                    untilDate:until
                       inMode:NSDefaultRunLoopMode
                      dequeue:YES];
    if (event != nil) {
        [NSApp sendEvent:event];
    }
    [NSApp updateWindows];
    [CATransaction flush];
}

static id<MTLRenderPipelineState> maru_make_cell_pipeline(
    id<MTLDevice> device,
    MTLPixelFormat pixel_format
) {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:maru_cell_shader_source
                                                  options:nil
                                                    error:&error];
    if (library == nil) {
        return nil;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"maru_cell_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"maru_cell_fragment"];
    descriptor.colorAttachments[0].pixelFormat = pixel_format;

    error = nil;
    return [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
}

static void maru_cell_color(MaruMetalSmokeCell cell, float *r, float *g, float *b) {
    // 이 색은 터미널 theme가 아니다. glyph가 붙기 전에도 셀 위치를 눈으로 확인하기 위한
    // 진단용 색이다. slot_id를 섞어 Zig의 GlyphFrame/atlas slot 데이터가 native bridge까지
    // 넘어왔다는 신호를 만든다. 실제 glyph 색상은 제품 renderer 단계에서 별도로 다룬다.
    const uint32_t codepoint = cell.codepoint;
    const uint32_t slot_id = cell.slot_id == 0 ? 1u : cell.slot_id;
    *r = 0.20f + (float)((codepoint + slot_id) % 3u) * 0.10f;
    *g = 0.56f + (float)((codepoint + slot_id) % 5u) * 0.05f;
    *b = 0.78f;
}

static NSUInteger maru_clamp_pixel(double value, NSUInteger upper_bound) {
    if (upper_bound == 0) {
        return 0;
    }
    if (value <= 0.0) {
        return 0;
    }
    double max_value = (double)(upper_bound - 1);
    if (value >= max_value) {
        return upper_bound - 1;
    }
    return (NSUInteger)value;
}

static MaruMetalSmokeSample *maru_build_cell_samples(
    const MaruMetalSmokeCell *cells,
    size_t cell_count,
    uint16_t cols,
    uint16_t rows,
    NSUInteger texture_width,
    NSUInteger texture_height,
    size_t *sample_count
) {
    *sample_count = 0;
    if (cells == NULL || cell_count == 0 || cols == 0 || rows == 0 ||
        texture_width == 0 || texture_height == 0)
    {
        return NULL;
    }

    // smoke는 전체 화면 readback이 아니라 셀 중심 픽셀만 읽는다. fixture가 커져도
    // GPU 검증 비용이 폭증하지 않게 앞쪽 셀 일부만 샘플링한다.
    const size_t max_samples = 64;
    const size_t count = cell_count < max_samples ? cell_count : max_samples;
    MaruMetalSmokeSample *samples = calloc(count, sizeof(MaruMetalSmokeSample));
    if (samples == NULL) {
        return NULL;
    }

    const double grid_left = -0.92;
    const double grid_top = 0.86;
    const double grid_width = 1.84;
    const double grid_height = 1.72;

    for (size_t i = 0; i < count; i++) {
        const MaruMetalSmokeCell cell = cells[i];
        const double cell_width = (double)(cell.width == 0 ? 1 : cell.width);
        const double left = grid_left + ((double)cell.col / (double)cols) * grid_width;
        const double right = grid_left + (((double)cell.col + cell_width) / (double)cols) * grid_width;
        const double top = grid_top - ((double)cell.row / (double)rows) * grid_height;
        const double bottom = grid_top - (((double)cell.row + 1.0) / (double)rows) * grid_height;
        const double center_x = (left + right) * 0.5;
        const double center_y = (top + bottom) * 0.5;

        samples[i].x = maru_clamp_pixel(((center_x + 1.0) * 0.5) * (double)texture_width, texture_width);
        samples[i].y = maru_clamp_pixel(((1.0 - center_y) * 0.5) * (double)texture_height, texture_height);
    }

    *sample_count = count;
    return samples;
}

static BOOL maru_pixel_is_non_clear(const uint8_t *pixel) {
    // BGRA8Unorm clear color는 MTLClearColorMake(0.06, 0.08, 0.12, 1.0)이다.
    // GPU의 float->unorm 반올림 차이를 감안해 작은 허용 오차를 둔다. placeholder
    // 셀 색은 clear보다 훨씬 밝아서 이 기준을 안정적으로 넘는다.
    const int expected_b = 31;
    const int expected_g = 20;
    const int expected_r = 15;
    const int expected_a = 255;
    const int tolerance = 8;
    return abs((int)pixel[0] - expected_b) > tolerance ||
        abs((int)pixel[1] - expected_g) > tolerance ||
        abs((int)pixel[2] - expected_r) > tolerance ||
        abs((int)pixel[3] - expected_a) > tolerance;
}

static uint32_t maru_count_non_clear_readback_pixels(
    id<MTLBuffer> readback_buffer,
    size_t sample_count
) {
    const uint8_t *bytes = (const uint8_t *)[readback_buffer contents];
    if (bytes == NULL) {
        return 0;
    }

    uint32_t non_clear = 0;
    for (size_t i = 0; i < sample_count; i++) {
        const uint8_t *pixel = bytes + (i * maru_readback_stride);
        if (maru_pixel_is_non_clear(pixel)) {
            non_clear += 1;
        }
    }
    return non_clear;
}

static MaruMetalSmokeVertex *maru_build_cell_vertices(
    const MaruMetalSmokeCell *cells,
    size_t cell_count,
    uint16_t cols,
    uint16_t rows,
    size_t *vertex_count
) {
    *vertex_count = 0;
    if (cells == NULL || cell_count == 0 || cols == 0 || rows == 0) {
        return NULL;
    }

    const size_t vertices_per_cell = 6;
    const size_t total_vertices = cell_count * vertices_per_cell;
    MaruMetalSmokeVertex *vertices = calloc(total_vertices, sizeof(MaruMetalSmokeVertex));
    if (vertices == NULL) {
        return NULL;
    }

    const float grid_left = -0.92f;
    const float grid_top = 0.86f;
    const float grid_width = 1.84f;
    const float grid_height = 1.72f;

    for (size_t i = 0; i < cell_count; i++) {
        const MaruMetalSmokeCell cell = cells[i];
        const float cell_width = (float)(cell.width == 0 ? 1 : cell.width);
        const float left = grid_left + ((float)cell.col / (float)cols) * grid_width;
        const float right = grid_left + (((float)cell.col + cell_width) / (float)cols) * grid_width;
        const float top = grid_top - ((float)cell.row / (float)rows) * grid_height;
        const float bottom = grid_top - (((float)cell.row + 1.0f) / (float)rows) * grid_height;
        float r = 0.0f;
        float g = 0.0f;
        float b = 0.0f;
        maru_cell_color(cell, &r, &g, &b);

        MaruMetalSmokeVertex quad[6] = {
            {left, top, r, g, b, 1.0f},
            {left, bottom, r, g, b, 1.0f},
            {right, bottom, r, g, b, 1.0f},
            {left, top, r, g, b, 1.0f},
            {right, bottom, r, g, b, 1.0f},
            {right, top, r, g, b, 1.0f},
        };
        memcpy(&vertices[i * vertices_per_cell], quad, sizeof(quad));
    }

    *vertex_count = total_vertices;
    return vertices;
}

static BOOL maru_draw_cell_frame(
    CAMetalLayer *layer,
    id<MTLCommandQueue> queue,
    id<MTLRenderPipelineState> cell_pipeline,
    const MaruMetalSmokeCell *cells,
    size_t cell_count,
    uint16_t cols,
    uint16_t rows,
    MaruMetalSmokeResult *result
) {
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (drawable == nil) {
        result->drawable_failures += 1;
        return NO;
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.06, 0.08, 0.12, 1.0);

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    if (command_buffer == nil) {
        result->drawable_failures += 1;
        return NO;
    }

    id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:pass];
    if (encoder == nil) {
        result->drawable_failures += 1;
        return NO;
    }

    size_t vertex_count = 0;
    MaruMetalSmokeVertex *vertices = maru_build_cell_vertices(
        cells,
        cell_count,
        cols,
        rows,
        &vertex_count
    );
    if (vertices == NULL || vertex_count == 0) {
        // 이미 만든 encoder를 endEncoding 없이 버리면 Metal API 위반이다(검증 레이어
        // assert/명령버퍼 손상). 정점 생성 실패 시에도 encoder를 정상 종료한 뒤 빠진다.
        [encoder endEncoding];
        free(vertices);
        result->drawable_failures += 1;
        return NO;
    }

    // setVertexBytes는 4KB 인라인 한도가 있어 셀 수가 늘면(현재 fixture는 9셀이라
    // 안전) 한도를 넘는다. 셀 개수와 무관하도록 프레임마다 transient MTLBuffer로
    // 올린다(ARC가 프레임 끝에서 해제). 재사용 buffer 모델은 제품 renderer 몫이다.
    id<MTLBuffer> vertex_buffer = [layer.device
        newBufferWithBytes:vertices
                    length:vertex_count * sizeof(MaruMetalSmokeVertex)
                   options:MTLResourceStorageModeShared];
    free(vertices);
    if (vertex_buffer == nil) {
        [encoder endEncoding];
        result->drawable_failures += 1;
        return NO;
    }

    size_t sample_count = 0;
    MaruMetalSmokeSample *samples = maru_build_cell_samples(
        cells,
        cell_count,
        cols,
        rows,
        drawable.texture.width,
        drawable.texture.height,
        &sample_count
    );
    if (samples == NULL || sample_count == 0) {
        [encoder endEncoding];
        free(samples);
        result->readback_failures += 1;
        return NO;
    }

    id<MTLBuffer> readback_buffer = [layer.device
        newBufferWithLength:sample_count * maru_readback_stride
                    options:MTLResourceStorageModeShared];
    if (readback_buffer == nil) {
        [encoder endEncoding];
        free(samples);
        result->readback_failures += 1;
        return NO;
    }

    [encoder setRenderPipelineState:cell_pipeline];
    [encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:vertex_count];
    [encoder endEncoding];

    id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
    if (blit == nil) {
        free(samples);
        result->readback_failures += 1;
        return NO;
    }
    for (size_t i = 0; i < sample_count; i++) {
        [blit copyFromTexture:drawable.texture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(samples[i].x, samples[i].y, 0)
                   sourceSize:MTLSizeMake(1, 1, 1)
                     toBuffer:readback_buffer
            destinationOffset:i * maru_readback_stride
       destinationBytesPerRow:maru_readback_stride
     destinationBytesPerImage:maru_readback_stride];
    }
    [blit endEncoding];
    free(samples);

    [command_buffer presentDrawable:drawable];
    [command_buffer commit];
    [command_buffer waitUntilCompleted];
    result->presented_frames += 1;
    // rendered_cells는 "draw에 제출한 셀 수"라는 관측값이다(실제 렌더 검증은 readback이
    // 한다). summary에서 requested_cells와 같은 포화 규칙으로 맞춰 둔다.
    result->rendered_cells = (cell_count > UINT32_MAX) ? UINT32_MAX : (uint32_t)cell_count;
    result->readback_samples = (sample_count > UINT32_MAX) ? UINT32_MAX : (uint32_t)sample_count;
    result->readback_non_clear_pixels = maru_count_non_clear_readback_pixels(
        readback_buffer,
        sample_count
    );
    return YES;
}

void maru_macos_metal_smoke_run(
    uint32_t duration_ms,
    uint16_t cols,
    uint16_t rows,
    const MaruMetalSmokeCell *cells,
    size_t cell_count,
    MaruMetalSmokeResult *result
) {
    result->status = -1;
    result->window_visible = 0;
    result->presented_frames = 0;
    result->drawable_failures = 0;
    result->requested_cells = (cell_count > UINT32_MAX) ? UINT32_MAX : (uint32_t)cell_count;
    result->rendered_cells = 0;
    result->readback_samples = 0;
    result->readback_non_clear_pixels = 0;
    result->readback_failures = 0;

    @autoreleasepool {
        // 이 bridge는 "Metal glyph renderer 완성"이 아니라 첫 GlyphFrame 소비 smoke다.
        // Zig 쪽이 TerminalCore/RendererState/GlyphFrame/artifact 계약을 소유하고,
        // 여기서는 그 slot-backed 셀 배열을 실제 CAMetalLayer 위에 placeholder quad로
        // present할 수 있는지 확인한다.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];

        if ([[NSScreen screens] count] == 0) {
            result->status = 2;
            return;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            result->status = 3;
            return;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (queue == nil) {
            result->status = 4;
            return;
        }
        if (cells == NULL || cell_count == 0 || cols == 0 || rows == 0) {
            result->status = 7;
            return;
        }

        NSRect frame = NSMakeRect(260.0, 260.0, 720.0, 420.0);
        NSWindowStyleMask style =
            NSWindowStyleMaskTitled |
            NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable |
            NSWindowStyleMaskResizable;

        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:style
                        backing:NSBackingStoreBuffered
                          defer:NO];
        if (window == nil) {
            result->status = 1;
            return;
        }

        NSView *content = [[NSView alloc]
            initWithFrame:NSMakeRect(0.0, 0.0, frame.size.width, frame.size.height)];

        CAMetalLayer *metal_layer = [CAMetalLayer layer];
        metal_layer.device = device;
        metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        // 이 smoke는 drawable의 셀 중심 픽셀을 blit-readback해야 한다. framebufferOnly=YES는
        // render target 전용 최적화라 readback 검증 신호를 만들 수 없으므로 smoke에서만 끈다.
        metal_layer.framebufferOnly = NO;
        metal_layer.contentsScale = window.backingScaleFactor;
        metal_layer.frame = content.bounds;
        metal_layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        metal_layer.drawableSize = CGSizeMake(
            content.bounds.size.width * window.backingScaleFactor,
            content.bounds.size.height * window.backingScaleFactor
        );

        id<MTLRenderPipelineState> cell_pipeline = maru_make_cell_pipeline(
            device,
            metal_layer.pixelFormat
        );
        if (cell_pipeline == nil) {
            result->status = 8;
            return;
        }

        // 레이어 호스팅 뷰는 .layer를 먼저 지정한 뒤 wantsLayer=YES로 둬야 한다.
        // 순서가 반대면 AppKit이 layer-backed로 보고 backing layer를 직접 만들고
        // 교체할 수 있어(스케일 변경/재표시), CAMetalLayer가 합성 트리에서 분리돼
        // present는 되지만 화면에 안 보이는 오탐이 생길 수 있다.
        content.layer = metal_layer;
        content.wantsLayer = YES;
        [window setTitle:@"Maru Metal smoke"];
        [window setReleasedWhenClosed:NO];
        [window setContentView:content];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        NSTimeInterval seconds = ((NSTimeInterval)duration_ms) / 1000.0;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

        // window smoke와 마찬가지로 직접 짧은 event pump를 돌린다. 매 루프마다
        // drawableSize를 최신 backing scale과 view bounds에 맞춰 갱신하고 cell
        // frame을 present/readback해, "창은 뜨지만 셀이 안 그려지는" 오탐을 막는다.
        do {
            @autoreleasepool {
                maru_pump_app_once();
                CGFloat scale = window.backingScaleFactor;
                metal_layer.contentsScale = scale;
                metal_layer.drawableSize = CGSizeMake(
                    content.bounds.size.width * scale,
                    content.bounds.size.height * scale
                );
                (void)maru_draw_cell_frame(
                    metal_layer,
                    queue,
                    cell_pipeline,
                    cells,
                    cell_count,
                    cols,
                    rows,
                    result
                );
            }
        } while ([[NSDate date] compare:deadline] == NSOrderedAscending);

        // Metal drawable present만으로는 "사용자가 볼 수 있는 UI"를 증명하지 못한다.
        // window smoke와 같은 기준으로 실제 NSWindow visibility를 함께 확인해야
        // headless/activation 실패에서 visible_ui=true 오탐을 막을 수 있다.
        BOOL became_visible = [window isVisible];
        result->window_visible = became_visible ? 1 : 0;
        [window orderOut:nil];

        if (!became_visible) {
            result->status = 5;
            return;
        }

        if (result->presented_frames == 0) {
            result->status = 6;
            return;
        }
        // readback이 실제 렌더 검증의 단일 게이트다. 샘플한 셀 중심이 "하나라도"가
        // 아니라 "전부" clear가 아니어야 부분 렌더 회귀(셀 일부만 그려짐)까지 잡는다.
        // readback은 compositing 전 drawable 텍스처를 읽으므로 "GPU가 셀을 렌더했다"를
        // 증명하고, "화면에 안 가려졌다"는 window_visible이 따로 담당한다.
        if (result->readback_samples == 0 ||
            result->readback_non_clear_pixels != result->readback_samples ||
            result->readback_failures > 0)
        {
            result->status = 9;
            return;
        }

        result->status = 0;
    }
}
