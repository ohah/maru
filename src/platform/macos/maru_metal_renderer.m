#import "maru_metal_renderer.h"
#import "maru_metal_shader.h"
#import <QuartzCore/QuartzCore.h>
#include <stdlib.h>
#include <string.h>

// shader의 VertexIn(packed_float2 position + packed_float2 uv + packed_float3 color +
// packed_float4 bg)과 같은 44바이트 tight-packed 레이아웃. 셀당 6정점(삼각형 2개)로 quad를
// 만든다. bg는 (r,g,b,a)이고 a=1이면 cell을 그 색으로 채운다(배경 없으면 a=0).
typedef struct {
    float position[2];
    float uv[2];
    float color[3];
    float bg[4];
} MaruRendererVertex;

@interface MaruMetalRendererImpl : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLTexture> atlas;
@property (nonatomic) uint32_t atlasWidth;
@property (nonatomic) uint32_t atlasHeight;
@end

@implementation MaruMetalRendererImpl
@end

MaruMetalRenderer *maru_metal_renderer_create(id<MTLDevice> device, MTLPixelFormat pixel_format) {
    if (device == nil) {
        return NULL;
    }
    id<MTLLibrary> library = [device newLibraryWithSource:MARU_METAL_CELL_SHADER_SOURCE
                                                  options:nil
                                                    error:NULL];
    if (library == nil) {
        return NULL;
    }
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"maru_cell_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"maru_cell_fragment"];
    descriptor.colorAttachments[0].pixelFormat = pixel_format;
    // premultiplied-alpha over 블렌딩을 켠다. 셰이더는 cell quad를 premultiplied(rgb는 이미 alpha를
    // 곱한 값, alpha=coverage 또는 1)로 낸다. 블렌딩이 꺼져 있으면 default 배경 glyph cell의 여백
    // (coverage 0 -> float4(0,0,0,0))이 clear color 대신 검정으로 덮여, 밝은 theme에선 글자마다
    // 검은 박스가 생긴다. over 블렌딩으로 여백이 clear(=theme 배경)에 합성되게 한다. 배경색 cell은
    // alpha=1이라 그대로 불투명하게 덮는다.
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> pipeline =
        [device newRenderPipelineStateWithDescriptor:descriptor error:NULL];
    if (pipeline == nil) {
        return NULL;
    }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (queue == nil) {
        return NULL;
    }

    MaruMetalRendererImpl *impl = [[MaruMetalRendererImpl alloc] init];
    impl.device = device;
    impl.queue = queue;
    impl.pipeline = pipeline;
    // C handle이 ObjC 객체 수명을 소유한다. destroy에서 __bridge_transfer로 해제한다.
    return (__bridge_retained MaruMetalRenderer *)impl;
}

bool maru_metal_renderer_set_atlas(
    MaruMetalRenderer *renderer,
    uint32_t atlas_width_px,
    uint32_t atlas_height_px,
    const MaruAppHostDevMetalRasterUpload *uploads,
    size_t upload_count,
    const uint8_t *raster_pixels,
    size_t raster_pixel_count
) {
    if (renderer == NULL || atlas_width_px == 0 || atlas_height_px == 0) {
        return false;
    }
    MaruMetalRendererImpl *impl = (__bridge MaruMetalRendererImpl *)renderer;

    if (impl.atlas == nil || impl.atlasWidth != atlas_width_px || impl.atlasHeight != atlas_height_px) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:(NSUInteger)atlas_width_px
                                        height:(NSUInteger)atlas_height_px
                                     mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [impl.device newTextureWithDescriptor:descriptor];
        if (texture == nil) {
            return false;
        }
        impl.atlas = texture;
        impl.atlasWidth = atlas_width_px;
        impl.atlasHeight = atlas_height_px;
    }

    if (uploads == NULL || raster_pixels == NULL) {
        return true;
    }
    for (size_t i = 0; i < upload_count; i++) {
        const MaruAppHostDevMetalRasterUpload upload = uploads[i];
        // atlas 범위와 source 범위를 벗어나는 upload는 건너뛴다(손상된 frame 방어). 검증된
        // smoke의 maru_upload_fits_atlas와 같은 invariant를 모두 확인한다 — replaceRegion은
        // bytes_per_row*atlas_height_px 바이트를 읽으므로, byte_count만 봐선 OOB read를 막지
        // 못한다.
        if (upload.atlas_width_px == 0 || upload.atlas_height_px == 0 || upload.bytes_per_row == 0) {
            continue;
        }
        if (upload.atlas_x_px >= atlas_width_px || upload.atlas_y_px >= atlas_height_px ||
            upload.atlas_width_px > atlas_width_px - upload.atlas_x_px ||
            upload.atlas_height_px > atlas_height_px - upload.atlas_y_px) {
            continue;
        }
        // RGBA8 tight row(width*4)와 byte_count == bytes_per_row*height를 강제해, Metal이 읽는
        // 범위가 정확히 byte_count와 일치하게 한다(곱셈 overflow도 막는다).
        if (upload.bytes_per_row != (size_t)upload.atlas_width_px * 4) {
            continue;
        }
        if (upload.bytes_per_row > SIZE_MAX / upload.atlas_height_px) {
            continue;
        }
        if (upload.byte_count != upload.bytes_per_row * (size_t)upload.atlas_height_px) {
            continue;
        }
        if (upload.bytes_offset > raster_pixel_count ||
            upload.byte_count > raster_pixel_count - upload.bytes_offset) {
            continue;
        }
        const uint8_t *source = raster_pixels + upload.bytes_offset;
        [impl.atlas replaceRegion:MTLRegionMake2D(
                                      (NSUInteger)upload.atlas_x_px,
                                      (NSUInteger)upload.atlas_y_px,
                                      (NSUInteger)upload.atlas_width_px,
                                      (NSUInteger)upload.atlas_height_px)
                      mipmapLevel:0
                        withBytes:source
                      bytesPerRow:(NSUInteger)upload.bytes_per_row];
    }
    return true;
}

/* 한 cell을 6 정점 quad로 채운다(out에 6개 기록). 세로 위치/높이(py_top, cell_h)는 caller가 계산해
   넘긴다 — 터미널 셀(py=row×ch), 사이드바 밴드(py=row×slot_h, 높이 slot_h), 사이드바 제목 glyph
   (py=슬롯 안 중앙, 높이 ch)가 같은 함수를 공유한다. 가로는 origin_x + col×cw. reserved 부분 사각형
   (2=underline 하단, 3=bar 좌측)과 색(전경 0x00RRGGBB·배경 0xAARRGGBB) 처리는 동일하다. */
static void maru_fill_cell_quad(
    MaruRendererVertex *out,
    const MaruAppHostDevMetalCell cell,
    float origin_x,
    float cw,
    float py_top,
    float cell_h,
    float drawable_w,
    float drawable_h
) {
    const float span = (float)(cell.width == 0 ? 1 : cell.width);
    float px_left = origin_x + (float)cell.col * cw;
    float px_right = px_left + cw * span;
    float px_top = py_top;
    float px_bottom = py_top + cell_h;
    // 커서 모양(DECSCUSR): reserved 2=underline(하단 ~15%), 3=bar(좌측 ~15%, 최소 2px). block(0)은 전체 cell.
    // 4=상단선, 5=우측선(active pane 테두리용 — 2/3의 반대 변). 모두 cell의 한 변 ~2px 띠로 그린다.
    if (cell.reserved == 2) {
        const float thickness = fmaxf(2.0f, cell_h * 0.15f);
        px_top = px_bottom - thickness;
    } else if (cell.reserved == 3) {
        const float thickness = fmaxf(2.0f, cw * 0.15f);
        px_right = px_left + thickness;
    } else if (cell.reserved == 4) {
        const float thickness = fmaxf(2.0f, cell_h * 0.15f);
        px_bottom = px_top + thickness;
    } else if (cell.reserved == 5) {
        const float thickness = fmaxf(2.0f, cw * 0.15f);
        px_left = px_right - thickness;
    }
    const float left = (px_left / drawable_w) * 2.0f - 1.0f;
    const float right = (px_right / drawable_w) * 2.0f - 1.0f;
    const float top = 1.0f - (px_top / drawable_h) * 2.0f;
    const float bottom = 1.0f - (px_bottom / drawable_h) * 2.0f;
    const float fr = (float)((cell.foreground >> 16) & 0xff) / 255.0f;
    const float fg = (float)((cell.foreground >> 8) & 0xff) / 255.0f;
    const float fb = (float)(cell.foreground & 0xff) / 255.0f;
    const float ba = (float)((cell.background >> 24) & 0xff) / 255.0f;
    const float br = (float)((cell.background >> 16) & 0xff) / 255.0f;
    const float bg = (float)((cell.background >> 8) & 0xff) / 255.0f;
    const float bb = (float)(cell.background & 0xff) / 255.0f;
    const MaruRendererVertex quad[6] = {
        {{left, top}, {cell.u0, cell.v0}, {fr, fg, fb}, {br, bg, bb, ba}},
        {{left, bottom}, {cell.u0, cell.v1}, {fr, fg, fb}, {br, bg, bb, ba}},
        {{right, bottom}, {cell.u1, cell.v1}, {fr, fg, fb}, {br, bg, bb, ba}},
        {{left, top}, {cell.u0, cell.v0}, {fr, fg, fb}, {br, bg, bb, ba}},
        {{right, bottom}, {cell.u1, cell.v1}, {fr, fg, fb}, {br, bg, bb, ba}},
        {{right, top}, {cell.u1, cell.v0}, {fr, fg, fb}, {br, bg, bb, ba}},
    };
    memcpy(out, quad, sizeof(quad));
}

bool maru_metal_renderer_draw(
    MaruMetalRenderer *renderer,
    CAMetalLayer *layer,
    uint16_t cols,
    uint16_t rows,
    uint32_t cell_width_px,
    uint32_t cell_height_px,
    const MaruAppHostDevMetalCell *cells,
    size_t cell_count,
    uint32_t terminal_origin_x_px,
    uint32_t sidebar_bg,
    const MaruAppHostDevMetalCell *sidebar_cells,
    size_t sidebar_cell_count,
    uint32_t sidebar_slot_height_px
) {
    if (renderer == NULL || layer == nil || cols == 0 || rows == 0) {
        return false;
    }
    if (cell_width_px == 0 || cell_height_px == 0) {
        return false;
    }
    MaruMetalRendererImpl *impl = (__bridge MaruMetalRendererImpl *)renderer;
    if (impl.atlas == nil) {
        return false;
    }
    // drawable의 backing 픽셀 크기. fixed-cell layout은 cell을 고정 픽셀 크기로 깔고 이 크기로
    // NDC에 투영하므로, 창을 키우면 글자가 늘어나는 게 아니라 더 많은 cell이 보인다.
    const CGSize drawable_size = layer.drawableSize;
    if (drawable_size.width < 1.0 || drawable_size.height < 1.0) {
        return false;
    }
    const float drawable_w = (float)drawable_size.width;
    const float drawable_h = (float)drawable_size.height;

    // 세로 사이드바: terminal_origin_x_px>0이고 sidebar_bg가 불투명(alpha!=0)이면 왼쪽 strip(x:0..origin_x)에
    // 배경 quad 1개를 추가로 그린다. 터미널 셀은 origin_x만큼 오른쪽으로 offset된다("surface→rect" — split도
    // 같은 origin 방식을 확장). 사이드바 quad는 cells 뒤(인덱스 cell_count)에 붙인다.
    const float origin_x = (float)terminal_origin_x_px;
    const bool draw_sidebar = (terminal_origin_x_px > 0u) && (((sidebar_bg >> 24) & 0xffu) != 0u);

    // vertex buffer를 drawable 획득 전에 만든다. 그래야 calloc/buffer 생성 실패가 이미 잡은
    // drawable을 present/commit 없이 새게 만들지 않는다(drawable pool starvation 방지).
    id<MTLBuffer> vertex_buffer = nil;
    size_t total_vertices = 0;
    // 사이드바 셀(탭 엔트리)은 사이드바가 켜졌을 때만(origin_x>0) 그린다 — 폭이 없으면 둘 데가 없다.
    const size_t sidebar_bg_quads = draw_sidebar ? 1u : 0u;
    const size_t sidebar_cells_n =
        (terminal_origin_x_px > 0u && sidebar_cells != NULL) ? sidebar_cell_count : 0u;
    // quad 순서: [터미널 cells][사이드바 배경 quad][사이드바 cells]. 사이드바 cells가 배경 quad
    // 뒤라 그 위에 블렌딩된다(밴드/제목이 사이드바 배경 위에 보인다).
    const size_t quad_count = cell_count + sidebar_bg_quads + sidebar_cells_n;
    if (quad_count > 0) {
        const size_t vertices_per_cell = 6;
        // total_vertices와 byte length 곱셈 overflow를 막는다(손상된 cell_count 방어).
        if (quad_count > SIZE_MAX / vertices_per_cell) {
            return false;
        }
        total_vertices = quad_count * vertices_per_cell;
        if (total_vertices > SIZE_MAX / sizeof(MaruRendererVertex)) {
            return false;
        }
        // 정점을 별도 calloc 버퍼에 만든 뒤 복사(newBufferWithBytes)하지 않고, shared MTLBuffer를
        // 바로 잡아 그 contents에 직접 채운다. calloc + 복사 한 번을 없앤다(draw는 dirty-gate
        // 덕에 변경 frame에서만 일어난다). 매 draw 새 버퍼라 GPU가 이전 frame을 읽는 중 덮어쓰는
        // 경합은 없다(true reuse는 triple-buffering이 필요한 후속 작업).
        vertex_buffer = [impl.device
            newBufferWithLength:total_vertices * sizeof(MaruRendererVertex)
                        options:MTLResourceStorageModeShared];
        if (vertex_buffer == nil) {
            return false;
        }
        MaruRendererVertex *vertices = (MaruRendererVertex *)vertex_buffer.contents;
        // fixed-cell pixel layout: 각 cell을 고정 픽셀 사각형(col×cw, row×ch)에 두고 drawable
        // 픽셀 크기로 NDC에 투영한다(좌상단 원점, Y는 아래로 증가 → NDC Y는 위로). grid를 창에
        // 맞춰 늘이지 않으므로 glyph가 왜곡되지 않는다.
        const float cw = (float)cell_width_px;
        const float ch = (float)cell_height_px;
        // 1) 터미널 cells — 각 cell이 자기 panel의 origin을 들고 있다(origin_x + col×cw, origin_y + row×ch).
        //    단일 panel이면 전부 (사이드바 폭, 0)이라 기존과 같다. split은 panel별로 다른 origin을 준다.
        for (size_t i = 0; i < cell_count; i++) {
            const MaruAppHostDevMetalCell tc = cells[i];
            maru_fill_cell_quad(&vertices[i * vertices_per_cell], tc, (float)tc.origin_x, cw, (float)tc.origin_y + (float)tc.row * ch, ch, drawable_w, drawable_h);
        }
        size_t quad_index = cell_count;
        // 2) 사이드바 배경 quad(x:0..origin_x, 전체 높이) — UV(-1) sentinel로 배경만 칠한다(셰이더가
        //    u<0이면 coverage 0 → bg.rgb만).
        if (draw_sidebar) {
            const float sl = -1.0f;                                  // x=0 → NDC 좌
            const float sr = (origin_x / drawable_w) * 2.0f - 1.0f;  // x=origin_x → NDC
            const float st = 1.0f;                                   // y=0 → NDC 상
            const float sb = -1.0f;                                  // y=drawable_h → NDC 하
            const float sba = (float)((sidebar_bg >> 24) & 0xff) / 255.0f;
            const float sbr = (float)((sidebar_bg >> 16) & 0xff) / 255.0f;
            const float sbg = (float)((sidebar_bg >> 8) & 0xff) / 255.0f;
            const float sbb = (float)(sidebar_bg & 0xff) / 255.0f;
            const MaruRendererVertex squad[6] = {
                {{sl, st}, {-1.0f, -1.0f}, {0.0f, 0.0f, 0.0f}, {sbr, sbg, sbb, sba}},
                {{sl, sb}, {-1.0f, -1.0f}, {0.0f, 0.0f, 0.0f}, {sbr, sbg, sbb, sba}},
                {{sr, sb}, {-1.0f, -1.0f}, {0.0f, 0.0f, 0.0f}, {sbr, sbg, sbb, sba}},
                {{sl, st}, {-1.0f, -1.0f}, {0.0f, 0.0f, 0.0f}, {sbr, sbg, sbb, sba}},
                {{sr, sb}, {-1.0f, -1.0f}, {0.0f, 0.0f, 0.0f}, {sbr, sbg, sbb, sba}},
                {{sr, st}, {-1.0f, -1.0f}, {0.0f, 0.0f, 0.0f}, {sbr, sbg, sbb, sba}},
            };
            memcpy(&vertices[quad_index * vertices_per_cell], squad, sizeof(squad));
            quad_index += 1;
        }
        // 3) 사이드바 cells — origin 0, 배경 quad 위에 그린다(painter 순서). 탭 슬롯 높이(≈2.5×)로
        //    배치하되 셀 종류를 slot_id로 구분한다: 밴드(slot_id==0, sentinel UV)는 슬롯 전체를 채우고
        //    (py=row×slot_h, 높이 slot_h), 제목 glyph(slot_id≠0)는 슬롯 안 세로 중앙에 ch 높이로
        //    그린다(py=row×slot_h + (slot_h−ch)/2). 제목 glyph는 약간의 좌측 여백(cw×0.5)을 둔다.
        const float slot_h = (sidebar_slot_height_px > 0u) ? (float)sidebar_slot_height_px : ch;
        const float glyph_pad = cw * 0.5f; // 제목 텍스트 좌측 여백(폰트 크기에 비례)
        for (size_t i = 0; i < sidebar_cells_n; i++) {
            const MaruAppHostDevMetalCell sc = sidebar_cells[i];
            const float slot_top = (float)sc.row * slot_h;
            float py_top, cell_h, sx_origin;
            if (sc.slot_id == 0u) { // 밴드/배경 — 슬롯 전체, 여백 없음
                py_top = slot_top;
                cell_h = slot_h;
                sx_origin = 0.0f;
            } else { // 제목 glyph — 슬롯 안 세로 중앙, ch 높이, 좌측 여백
                py_top = slot_top + (slot_h - ch) * 0.5f;
                cell_h = ch;
                sx_origin = glyph_pad;
            }
            maru_fill_cell_quad(&vertices[(quad_index + i) * vertices_per_cell], sc, sx_origin, cw, py_top, cell_h, drawable_w, drawable_h);
        }
    }

    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (drawable == nil) {
        return false;
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.06, 0.08, 0.12, 1.0);

    id<MTLCommandBuffer> command_buffer = [impl.queue commandBuffer];
    if (command_buffer == nil) {
        return false;
    }
    id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:pass];
    if (encoder == nil) {
        return false;
    }

    // vertex_buffer가 nil이면(cell 없음) clear만 한 빈 frame이다. 어떤 경우든 encoder는 반드시
    // endEncoding하고 present/commit한다.
    if (vertex_buffer != nil) {
        [encoder setRenderPipelineState:impl.pipeline];
        [encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [encoder setFragmentTexture:impl.atlas atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:total_vertices];
    }
    [encoder endEncoding];

    [command_buffer presentDrawable:drawable];
    [command_buffer commit];
    return true;
}

void maru_metal_renderer_destroy(MaruMetalRenderer *renderer) {
    if (renderer == NULL) {
        return;
    }
    // __bridge_transfer로 ARC 소유권을 회수해 해제한다. 단발성: caller는 destroy 뒤 handle을
    // 비워야 한다.
    MaruMetalRendererImpl *impl = (__bridge_transfer MaruMetalRendererImpl *)renderer;
    impl.atlas = nil;
    impl.pipeline = nil;
    impl.queue = nil;
    impl.device = nil;
}
