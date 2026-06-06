#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int32_t status;
    uint32_t presented_frames;
    uint32_t drawable_failures;
    uint32_t requested_cells;
    uint32_t rendered_cells;
} MaruMetalSmokeResult;

typedef struct {
    uint16_t row;
    uint16_t col;
    uint16_t width;
    uint16_t reserved;
    uint32_t codepoint;
} MaruMetalSmokeCell;

typedef struct {
    float x;
    float y;
    float r;
    float g;
    float b;
    float a;
} MaruMetalSmokeVertex;

static NSString *const maru_cell_shader_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VertexIn { float2 position; float4 color; };\n"
     "struct VertexOut { float4 position [[position]]; float4 color; };\n"
     "vertex VertexOut maru_cell_vertex(uint vid [[vertex_id]], const device VertexIn *vertices [[buffer(0)]]) {\n"
     "  VertexOut out;\n"
     "  out.position = float4(vertices[vid].position, 0.0, 1.0);\n"
     "  out.color = vertices[vid].color;\n"
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

static void maru_cell_color(uint32_t codepoint, float *r, float *g, float *b) {
    // 이 색은 터미널 theme가 아니다. glyph가 붙기 전에도 셀 위치를 눈으로 확인하기 위한
    // 진단용 색이다. codepoint를 조금 섞어 행렬이 단색 덩어리처럼 보이지 않게 한다.
    *r = 0.20f + (float)(codepoint % 3u) * 0.10f;
    *g = 0.56f + (float)(codepoint % 5u) * 0.05f;
    *b = 0.78f;
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
        maru_cell_color(cell.codepoint, &r, &g, &b);

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
        free(vertices);
        result->drawable_failures += 1;
        return NO;
    }

    [encoder setRenderPipelineState:cell_pipeline];
    [encoder setVertexBytes:vertices
                     length:vertex_count * sizeof(MaruMetalSmokeVertex)
                    atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:vertex_count];
    [encoder endEncoding];
    [command_buffer presentDrawable:drawable];
    [command_buffer commit];
    [command_buffer waitUntilCompleted];
    free(vertices);
    result->presented_frames += 1;
    result->rendered_cells = (uint32_t)cell_count;
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
    result->presented_frames = 0;
    result->drawable_failures = 0;
    result->requested_cells = (cell_count > UINT32_MAX) ? UINT32_MAX : (uint32_t)cell_count;
    result->rendered_cells = 0;

    @autoreleasepool {
        // 이 bridge는 "Metal glyph renderer 완성"이 아니라 첫 DrawList 소비 smoke다.
        // Zig 쪽이 TerminalCore/DrawList/artifact 계약을 소유하고, 여기서는 그 셀
        // 배열을 실제 CAMetalLayer 위에 placeholder quad로 present할 수 있는지 확인한다.
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
        content.wantsLayer = YES;

        CAMetalLayer *metal_layer = [CAMetalLayer layer];
        metal_layer.device = device;
        metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metal_layer.framebufferOnly = YES;
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

        content.layer = metal_layer;
        [window setTitle:@"Maru Metal smoke"];
        [window setReleasedWhenClosed:NO];
        [window setContentView:content];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        NSTimeInterval seconds = ((NSTimeInterval)duration_ms) / 1000.0;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

        // window smoke와 마찬가지로 직접 짧은 event pump를 돌린다. 매 루프마다
        // drawableSize를 최신 backing scale과 view bounds에 맞춰 갱신하고 clear
        // frame을 present해, "창은 뜨지만 Metal drawable은 못 얻는" 오탐을 막는다.
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
        [window orderOut:nil];

        if (!became_visible) {
            result->status = 5;
            return;
        }

        result->status = (result->presented_frames > 0 && result->rendered_cells == result->requested_cells)
            ? 0
            : 6;
    }
}
