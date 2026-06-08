#import "maru_metal_renderer.h"
#import "maru_metal_shader.h"
#import <QuartzCore/QuartzCore.h>
#include <stdlib.h>
#include <string.h>

// shader의 VertexIn(packed_float2 position + packed_float2 uv)과 같은 16바이트 tight-packed
// 레이아웃. 셀당 6정점(삼각형 2개)로 quad를 만든다.
typedef struct {
    float position[2];
    float uv[2];
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
        // atlas 범위와 source 범위를 벗어나는 upload는 건너뛴다(손상된 frame 방어).
        if (upload.atlas_width_px == 0 || upload.atlas_height_px == 0 || upload.bytes_per_row == 0) {
            continue;
        }
        if (upload.atlas_x_px >= atlas_width_px || upload.atlas_y_px >= atlas_height_px ||
            upload.atlas_width_px > atlas_width_px - upload.atlas_x_px ||
            upload.atlas_height_px > atlas_height_px - upload.atlas_y_px) {
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

bool maru_metal_renderer_draw(
    MaruMetalRenderer *renderer,
    CAMetalLayer *layer,
    uint16_t cols,
    uint16_t rows,
    const MaruAppHostDevMetalCell *cells,
    size_t cell_count
) {
    if (renderer == NULL || layer == nil || cols == 0 || rows == 0) {
        return false;
    }
    MaruMetalRendererImpl *impl = (__bridge MaruMetalRendererImpl *)renderer;
    if (impl.atlas == nil) {
        return false;
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

    // cell이 없으면 clear만 한 빈 frame을 present한다(encoder는 반드시 endEncoding).
    if (cells == NULL || cell_count == 0) {
        [encoder endEncoding];
        [command_buffer presentDrawable:drawable];
        [command_buffer commit];
        return true;
    }

    const size_t vertices_per_cell = 6;
    const size_t total_vertices = cell_count * vertices_per_cell;
    MaruRendererVertex *vertices = calloc(total_vertices, sizeof(MaruRendererVertex));
    if (vertices == NULL) {
        [encoder endEncoding];
        return false;
    }
    // smoke와 같은 inset grid 매핑(NDC). 실제 font metrics 기반 layout은 Swift view 단계에서
    // 다룬다.
    const float grid_left = -0.92f;
    const float grid_top = 0.86f;
    const float grid_width = 1.84f;
    const float grid_height = 1.72f;
    for (size_t i = 0; i < cell_count; i++) {
        const MaruAppHostDevMetalCell cell = cells[i];
        const float cell_width = (float)(cell.width == 0 ? 1 : cell.width);
        const float left = grid_left + ((float)cell.col / (float)cols) * grid_width;
        const float right = grid_left + (((float)cell.col + cell_width) / (float)cols) * grid_width;
        const float top = grid_top - ((float)cell.row / (float)rows) * grid_height;
        const float bottom = grid_top - (((float)cell.row + 1.0f) / (float)rows) * grid_height;
        MaruRendererVertex quad[6] = {
            {{left, top}, {cell.u0, cell.v0}},
            {{left, bottom}, {cell.u0, cell.v1}},
            {{right, bottom}, {cell.u1, cell.v1}},
            {{left, top}, {cell.u0, cell.v0}},
            {{right, bottom}, {cell.u1, cell.v1}},
            {{right, top}, {cell.u1, cell.v0}},
        };
        memcpy(&vertices[i * vertices_per_cell], quad, sizeof(quad));
    }

    id<MTLBuffer> vertex_buffer = [impl.device
        newBufferWithBytes:vertices
                    length:total_vertices * sizeof(MaruRendererVertex)
                   options:MTLResourceStorageModeShared];
    free(vertices);
    if (vertex_buffer == nil) {
        [encoder endEncoding];
        return false;
    }

    [encoder setRenderPipelineState:impl.pipeline];
    [encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
    [encoder setFragmentTexture:impl.atlas atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:total_vertices];
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
