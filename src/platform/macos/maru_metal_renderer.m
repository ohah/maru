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

// C4b: chrome rich GPU quad 프리미티브 정점. 셰이더 QuadIn(packed_float2×3 + packed_float4×5 +
// float = 27 float, 108바이트 tight-packed)과 같은 레이아웃. quad당 6정점(삼각형 2개)을 host가
// 만들며 사각형 파라미터(local 픽셀 좌표·half size·radii·border·색·gradient)를 각 정점에 복제한다.
typedef struct {
    float position[2];     // NDC
    float local[2];        // 사각형 내 픽셀 좌표(0..w, 0..h)
    float half_size[2];    // (w/2, h/2)
    float corner[4];       // tl, tr, br, bl radii(px)
    float border[4];       // top, right, bottom, left width(px)
    float fill0[4];        // rgba(0..1) — gradient 시작색
    float fill1[4];        // rgba — gradient 끝색
    float border_color[4]; // rgba
    float gradient_kind;   // 0=solid, 1=vertical, 2=horizontal
} MaruRendererQuadVertex;

// 셰이더 QuadIn(maru_metal_shader.h)이 이 정점을 buffer(0)로 raw 재해석하므로 레이아웃이 1:1이어야 한다.
// packed_float2×3(24) + packed_float4×5(80) + float(4) = 108B tight-pack. 한쪽만 필드를 바꾸면 GPU가
// 엉뚱한 offset을 읽어 조용히 깨지므로(컴파일·테스트 무경고) 크기를 정적 단언으로 못박는다(GpuQuad ABI와 동형 가드).
_Static_assert(sizeof(MaruRendererQuadVertex) == 108, "MaruRendererQuadVertex must match MSL QuadIn (108B tight-pack)");

// C4b: shadow 정점. 셰이더 ShadowIn(packed_float2×3 + packed_float4 + float + packed_float4 = 15 float,
// 60B tight-pack)과 1:1. host가 GpuShadow를 blur만큼 확장된 rect로 quad당 6정점 생성한다(fill은 모달-3b-1b).
typedef struct {
    float position[2];     // NDC (확장 rect 모서리)
    float local[2];        // 원본 박스 픽셀 좌표(-blur..w+blur)
    float half_size[2];    // 원본 박스 (w/2, h/2)
    float corner[4];       // tl, tr, br, bl radii(px)
    float blur;            // 흐림 반경(px)
    float color[4];        // rgba(0..1)
} MaruRendererShadowVertex;
_Static_assert(sizeof(MaruRendererShadowVertex) == 60, "MaruRendererShadowVertex must match MSL ShadowIn (60B tight-pack)");

// kitty graphics(K2): 이미지 placement 정점. 셰이더 ImageIn(packed_float2×2 = 16B tight-pack)과 1:1.
// placement당 6정점(삼각형 2개). dest 사각형 NDC + source UV([0,1] crop)만 — 텍스처는 setFragmentTexture로.
typedef struct {
    float position[2]; // NDC
    float uv[2];       // source UV [0,1]
} MaruRendererImageVertex;
_Static_assert(sizeof(MaruRendererImageVertex) == 16, "MaruRendererImageVertex must match MSL ImageIn (16B tight-pack)");

@interface MaruMetalRendererImpl : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> quadPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> shadowPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> imagePipeline;
@property (nonatomic, strong) id<MTLTexture> atlas;
@property (nonatomic) uint32_t atlasWidth;
@property (nonatomic) uint32_t atlasHeight;
// kitty graphics(K2): image_id → MTLTexture 캐시. image_uploads로 (재)생성하고, gpu_images가 image_id로
// 찾아 그린다. 삭제된 이미지 텍스처의 명시적 eviction은 후속(K4) — 참조 안 되면 안 그려질 뿐이다.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id<MTLTexture>> *imageTextures;
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
    // C4b: chrome rich quad 프리미티브 파이프라인(SDF rounded box). 셀과 별개 셰이더/정점 레이아웃이지만
    // 같은 premultiplied-over 블렌딩에 합성한다. 셰이더 컴파일 실패 시 create가 NULL이라 게이트가 잡는다.
    id<MTLLibrary> quad_library = [device newLibraryWithSource:MARU_METAL_QUAD_SHADER_SOURCE
                                                       options:nil
                                                         error:NULL];
    if (quad_library == nil) {
        return NULL;
    }
    MTLRenderPipelineDescriptor *quad_descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    quad_descriptor.vertexFunction = [quad_library newFunctionWithName:@"maru_quad_vertex"];
    quad_descriptor.fragmentFunction = [quad_library newFunctionWithName:@"maru_quad_fragment"];
    quad_descriptor.colorAttachments[0].pixelFormat = pixel_format;
    quad_descriptor.colorAttachments[0].blendingEnabled = YES;
    quad_descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    quad_descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    quad_descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    quad_descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    quad_descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    quad_descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> quad_pipeline =
        [device newRenderPipelineStateWithDescriptor:quad_descriptor error:NULL];
    if (quad_pipeline == nil) {
        return NULL;
    }
    // C4b: chrome 그림자 파이프라인(gaussian-approx blur SDF). quad와 별개, quad·셀보다 아래(먼저) 그린다.
    id<MTLLibrary> shadow_library = [device newLibraryWithSource:MARU_METAL_SHADOW_SHADER_SOURCE
                                                         options:nil
                                                           error:NULL];
    if (shadow_library == nil) {
        return NULL;
    }
    MTLRenderPipelineDescriptor *shadow_descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    shadow_descriptor.vertexFunction = [shadow_library newFunctionWithName:@"maru_shadow_vertex"];
    shadow_descriptor.fragmentFunction = [shadow_library newFunctionWithName:@"maru_shadow_fragment"];
    shadow_descriptor.colorAttachments[0].pixelFormat = pixel_format;
    shadow_descriptor.colorAttachments[0].blendingEnabled = YES;
    shadow_descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    shadow_descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    shadow_descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    shadow_descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    shadow_descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    shadow_descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> shadow_pipeline =
        [device newRenderPipelineStateWithDescriptor:shadow_descriptor error:NULL];
    if (shadow_pipeline == nil) {
        return NULL;
    }
    // kitty graphics(K2): 이미지 textured-quad 파이프라인. 셀/quad/shadow와 별개 셰이더지만 같은
    // premultiplied-over 블렌딩. 셰이더 컴파일 실패 시 create가 NULL이라 게이트가 잡는다.
    id<MTLLibrary> image_library = [device newLibraryWithSource:MARU_METAL_IMAGE_SHADER_SOURCE
                                                        options:nil
                                                          error:NULL];
    if (image_library == nil) {
        return NULL;
    }
    MTLRenderPipelineDescriptor *image_descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    image_descriptor.vertexFunction = [image_library newFunctionWithName:@"maru_image_vertex"];
    image_descriptor.fragmentFunction = [image_library newFunctionWithName:@"maru_image_fragment"];
    image_descriptor.colorAttachments[0].pixelFormat = pixel_format;
    image_descriptor.colorAttachments[0].blendingEnabled = YES;
    image_descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    image_descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    image_descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    image_descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    image_descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    image_descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> image_pipeline =
        [device newRenderPipelineStateWithDescriptor:image_descriptor error:NULL];
    if (image_pipeline == nil) {
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
    impl.quadPipeline = quad_pipeline;
    impl.shadowPipeline = shadow_pipeline;
    impl.imagePipeline = image_pipeline;
    impl.imageTextures = [NSMutableDictionary dictionary];
    // C handle이 ObjC 객체 수명을 소유한다. destroy에서 __bridge_transfer로 해제한다.
    return (__bridge_retained MaruMetalRenderer *)impl;
}

bool maru_metal_renderer_set_atlas(
    MaruMetalRenderer *renderer,
    uint32_t atlas_width_px,
    uint32_t atlas_height_px,
    const MaruAppHostMetalRasterUpload *uploads,
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
        const MaruAppHostMetalRasterUpload upload = uploads[i];
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
    const MaruAppHostMetalCell cell,
    float origin_x,
    float cw,
    float py_top,
    float cell_h,
    float drawable_w,
    float drawable_h,
    float glyph_scale // 글리프 확대 배율(1.0=무확대). 사이드바 에이전트 심볼만 >1로 키운다.
) {
    const float span = (float)(cell.width == 0 ? 1 : cell.width);
    float px_left = origin_x + (float)cell.col * cw;
    float px_right = px_left + cw * span;
    float px_top = py_top;
    float px_bottom = py_top + cell_h;
    // 커서·테두리·장식선 부분 사각형(reserved). 셀의 한 변 또는 중앙에 가는 띠를 그린다.
    //   강조선(셀 높이/폭 ~15%): 2=underline 커서·pane/divider 하단선, 3=bar 커서·세로 divider 좌측,
    //   4=pane/divider 상단선, 5=pane 우측선, 8=OSC 133 거터 바(셀 왼쪽 바깥). block(0)은 전체 cell.
    //   텍스트 장식선(SGR)은 글자에 붙는 가는 선이라 강조선(15%)의 절반인 ~7.5%로 가늘게 그린다 —
    //   9=밑줄(SGR 4)·링크 hover 하단, 10=윗줄(SGR 53) 상단, 6=취소선(SGR 9) 중앙, 7=2중밑줄(SGR 21) 둘째 선.
    //   베이스: Ghostty는 폰트 메트릭 underline_thickness(=max(1,ceil(face.underlineThickness)))를 쓰지만,
    //   maru는 폰트 메트릭을 .m에 전달하지 않으므로 cell_h 비례 근사를 쓰되 텍스트 장식선은 그 가는 밑줄에
    //   맞춰 절반으로 둔다. 커서·창 테두리·divider는 강조 요소라 15%를 유지한다(텍스트만 가늘게).
    const float text_line = fmaxf(1.0f, cell_h * 0.075f); // 텍스트 장식선(밑줄·윗줄·취소선·2중선) 공통 두께
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
    } else if (cell.reserved == 9) {
        // 텍스트 밑줄(SGR 4)·링크 hover: 셀 하단에 가는 띠(커서 underline=2의 절반 두께).
        px_top = px_bottom - text_line;
    } else if (cell.reserved == 10) {
        // 텍스트 윗줄(SGR 53): 셀 상단에 가는 띠(테두리 상단=4와 분리된 가는 선).
        px_bottom = px_top + text_line;
    } else if (cell.reserved == 6) {
        // strikethrough(SGR 9): 셀 세로 중앙 가는 띠(밑줄은 하단, 이건 중앙).
        const float center = py_top + cell_h * 0.5f;
        px_top = center - text_line * 0.5f;
        px_bottom = center + text_line * 0.5f;
    } else if (cell.reserved == 7) {
        // double underline(SGR 21) 둘째 선: 하단 선(reserved 9) 위로 gap만큼 띄운 가는 띠. 둘이 합쳐 2중선.
        const float gap = fmaxf(1.0f, cell_h * 0.06f); // 두 선 사이 간격
        px_bottom = px_bottom - text_line - gap; // 하단 선 + gap 만큼 위로
        px_top = px_bottom - text_line;          // 둘째 선(첫째선과 같은 두께)
    } else if (cell.reserved == 8) {
        // OSC 133 거터 바: 셀 왼쪽 '바깥'(col 0 글자 시작 전 여백)에 세로 띠를 그린다 — bar(3)는 셀
        // 안 왼쪽이지만 이건 origin 왼쪽으로 빼 col 0 글자와 안 겹친다. 글자에 딱 붙지 않게 gap을 둬
        // 약간 띄운다. window padding 여백이 있으면 그 안에 들어가고, 없으면 사이드바 경계에 붙는다.
        const float thickness = fmaxf(2.0f, cw * 0.15f);
        const float gap = fmaxf(2.0f, cw * 0.12f); // 거터와 col 0 글자 사이 여백
        px_right = px_left - gap;        // 글자 시작에서 gap만큼 왼쪽
        px_left = px_right - thickness;  // 거기서 thickness만큼 바깥
        // window padding이 0이면 px_left(=origin_x-gap-thickness)가 음수(화면 밖)거나 사이드바를 침범할 수 있다.
        // 화면 왼쪽 밖으로 안 나가게 0 하한으로 clamp하고, px_right가 그보다 작아지면 폭 0으로 접는다. 사이드바
        // 폭은 .m이 모르니 0 하한만 둔다 — padding 0이면 거터가 좁아지거나 사이드바 경계에 붙을 수 있으나
        // 글자 침범보다 낫다.
        px_left = fmaxf(px_left, 0.0f);
        px_right = fmaxf(px_right, px_left);
    }
    // 글리프 확대(사이드바 에이전트 심볼): 셀 사각형을 중앙 기준으로 키워 같은 atlas slot을 stretch한다(약간
    // 부드러우나 보조 심볼이라 무방). UV는 그대로라 글리프만 커진다. glyph_scale=1.0이면 무동작(일반 셀·커서).
    if (glyph_scale != 1.0f) {
        const float cx = (px_left + px_right) * 0.5f;
        const float cy = (px_top + px_bottom) * 0.5f;
        px_left = cx + (px_left - cx) * glyph_scale;
        px_right = cx + (px_right - cx) * glyph_scale;
        px_top = cy + (px_top - cy) * glyph_scale;
        px_bottom = cy + (px_bottom - cy) * glyph_scale;
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

/* C4b: 한 GpuQuad를 6정점 quad로 채운다(out에 6개). 픽셀 bounds를 NDC로 투영하고(셀과 같은 좌상단
   원점 방식) local 픽셀 좌표·half size·radii·border·색을 각 정점에 싣는다. 색 0xAARRGGBB를 rgba(0..1)로
   언팩한다(셰이더가 sRGB로 받아 linear blend). 모양/SDF는 셰이더가 — 여기선 순수 산술뿐(렌더 백엔드
   책임, Zig 데이터는 불변). */
static void maru_fill_quad_instance(
    MaruRendererQuadVertex *out,
    const MaruAppHostGpuQuad quad,
    float drawable_w,
    float drawable_h
) {
    const float left = (quad.x / drawable_w) * 2.0f - 1.0f;
    const float right = ((quad.x + quad.w) / drawable_w) * 2.0f - 1.0f;
    const float top = 1.0f - (quad.y / drawable_h) * 2.0f;
    const float bottom = 1.0f - ((quad.y + quad.h) / drawable_h) * 2.0f;
    MaruRendererQuadVertex base;
    base.half_size[0] = quad.w * 0.5f;
    base.half_size[1] = quad.h * 0.5f;
    memcpy(base.corner, quad.corner_radii, sizeof(float) * 4);
    memcpy(base.border, quad.border_widths, sizeof(float) * 4);
    base.fill0[0] = (float)((quad.fill_color0 >> 16) & 0xff) / 255.0f;
    base.fill0[1] = (float)((quad.fill_color0 >> 8) & 0xff) / 255.0f;
    base.fill0[2] = (float)(quad.fill_color0 & 0xff) / 255.0f;
    base.fill0[3] = (float)((quad.fill_color0 >> 24) & 0xff) / 255.0f;
    base.fill1[0] = (float)((quad.fill_color1 >> 16) & 0xff) / 255.0f;
    base.fill1[1] = (float)((quad.fill_color1 >> 8) & 0xff) / 255.0f;
    base.fill1[2] = (float)(quad.fill_color1 & 0xff) / 255.0f;
    base.fill1[3] = (float)((quad.fill_color1 >> 24) & 0xff) / 255.0f;
    base.border_color[0] = (float)((quad.border_color >> 16) & 0xff) / 255.0f;
    base.border_color[1] = (float)((quad.border_color >> 8) & 0xff) / 255.0f;
    base.border_color[2] = (float)(quad.border_color & 0xff) / 255.0f;
    base.border_color[3] = (float)((quad.border_color >> 24) & 0xff) / 255.0f;
    base.gradient_kind = (float)quad.gradient_kind;
    // 모서리 4개의 (NDC pos, local px): tl, tr, br, bl.
    const float cx[4] = {left, right, right, left};
    const float cy[4] = {top, top, bottom, bottom};
    const float lx[4] = {0.0f, quad.w, quad.w, 0.0f};
    const float ly[4] = {0.0f, 0.0f, quad.h, quad.h};
    const int order[6] = {0, 3, 2, 0, 2, 1}; // tl,bl,br + tl,br,tr
    for (int i = 0; i < 6; i++) {
        MaruRendererQuadVertex v = base;
        v.position[0] = cx[order[i]];
        v.position[1] = cy[order[i]];
        v.local[0] = lx[order[i]];
        v.local[1] = ly[order[i]];
        out[i] = v;
    }
}

/* C4b: 한 GpuShadow를 6정점으로 채운다(blur만큼 확장된 rect). local은 원본 박스 기준(-blur..w+blur)이라
   셰이더 SDF d가 원본 모서리에서 0이 되고 blur 영역으로 부드럽게 번진다. 색 0xAARRGGBB 언팩(셰이더 linear/
   premultiplied). 순수 산술 — 모양은 셰이더가. */
static void maru_fill_shadow_instance(
    MaruRendererShadowVertex *out,
    const MaruAppHostGpuShadow sh,
    float drawable_w,
    float drawable_h
) {
    const float blur = sh.blur_radius;
    const float ex0 = sh.x - blur, ey0 = sh.y - blur;
    const float ex1 = sh.x + sh.w + blur, ey1 = sh.y + sh.h + blur;
    const float left = (ex0 / drawable_w) * 2.0f - 1.0f;
    const float right = (ex1 / drawable_w) * 2.0f - 1.0f;
    const float top = 1.0f - (ey0 / drawable_h) * 2.0f;
    const float bottom = 1.0f - (ey1 / drawable_h) * 2.0f;
    MaruRendererShadowVertex base;
    base.half_size[0] = sh.w * 0.5f;
    base.half_size[1] = sh.h * 0.5f;
    memcpy(base.corner, sh.corner_radii, sizeof(float) * 4);
    base.blur = blur;
    base.color[0] = (float)((sh.color >> 16) & 0xff) / 255.0f;
    base.color[1] = (float)((sh.color >> 8) & 0xff) / 255.0f;
    base.color[2] = (float)(sh.color & 0xff) / 255.0f;
    base.color[3] = (float)((sh.color >> 24) & 0xff) / 255.0f;
    // 확장 rect 4모서리의 (NDC, local 원본기준): tl, tr, br, bl.
    const float cx[4] = {left, right, right, left};
    const float cy[4] = {top, top, bottom, bottom};
    const float lx[4] = {-blur, sh.w + blur, sh.w + blur, -blur};
    const float ly[4] = {-blur, -blur, sh.h + blur, sh.h + blur};
    const int order[6] = {0, 3, 2, 0, 2, 1};
    for (int i = 0; i < 6; i++) {
        MaruRendererShadowVertex v = base;
        v.position[0] = cx[order[i]];
        v.position[1] = cy[order[i]];
        v.local[0] = lx[order[i]];
        v.local[1] = ly[order[i]];
        out[i] = v;
    }
}

/* kitty graphics(K2): 한 GpuImage를 6정점 textured quad로 채운다(out에 6개). dest 사각형(origin + dest_x/y,
   크기 dest_w/h)을 셀과 같은 좌상단 원점 방식으로 NDC에 투영하고, source UV(crop)를 싣는다. 순수 산술 —
   샘플/블렌딩은 셰이더. */
static void maru_fill_image_quad(
    MaruRendererImageVertex *out,
    const MaruAppHostGpuImage img,
    float drawable_w,
    float drawable_h
) {
    const float x0 = (float)img.origin_x + img.dest_x;
    const float y0 = (float)img.origin_y + img.dest_y;
    const float x1 = x0 + img.dest_w;
    const float y1 = y0 + img.dest_h;
    const float left = (x0 / drawable_w) * 2.0f - 1.0f;
    const float right = (x1 / drawable_w) * 2.0f - 1.0f;
    const float top = 1.0f - (y0 / drawable_h) * 2.0f;
    const float bottom = 1.0f - (y1 / drawable_h) * 2.0f;
    const float u0 = img.src_u0, v0 = img.src_v0, u1 = img.src_u1, v1 = img.src_v1;
    const MaruRendererImageVertex quad[6] = {
        {{left, top}, {u0, v0}},
        {{left, bottom}, {u0, v1}},
        {{right, bottom}, {u1, v1}},
        {{left, top}, {u0, v0}},
        {{right, bottom}, {u1, v1}},
        {{right, top}, {u1, v0}},
    };
    memcpy(out, quad, sizeof(quad));
}

/* kitty graphics(K2): image_uploads를 image_id별 MTLTexture로 (재)생성해 캐시에 넣는다. RGBA(bpp=4)는
   바로, RGB(bpp=3)는 alpha=255로 확장해 올린다. 손상/범위 밖 디스크립터는 건너뛴다(frame 방어). */
static void maru_upload_image_textures(
    MaruMetalRendererImpl *impl,
    const MaruAppHostGpuImageUpload *uploads,
    size_t upload_count,
    const uint8_t *pixels,
    size_t pixel_count
) {
    if (uploads == NULL || pixels == NULL) {
        return;
    }
    for (size_t i = 0; i < upload_count; i++) {
        const MaruAppHostGpuImageUpload up = uploads[i];
        if (up.width == 0 || up.height == 0 || (up.bpp != 3 && up.bpp != 4)) {
            continue;
        }
        // 픽셀 범위 검증(곱셈 overflow 포함): len == width*height*bpp, 버퍼 안.
        if (up.width > SIZE_MAX / up.height) continue;
        const size_t px = (size_t)up.width * (size_t)up.height;
        if (px > SIZE_MAX / up.bpp) continue;
        const size_t need = px * (size_t)up.bpp;
        if (up.pixels_len != need) continue;
        if (up.pixels_offset > pixel_count || up.pixels_len > pixel_count - up.pixels_offset) continue;
        const uint8_t *src = pixels + up.pixels_offset;

        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:(NSUInteger)up.width
                                        height:(NSUInteger)up.height
                                     mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [impl.device newTextureWithDescriptor:descriptor];
        if (texture == nil) {
            continue;
        }
        const NSUInteger bytes_per_row = (NSUInteger)up.width * 4u; // 텍스처는 항상 RGBA8
        if (up.bpp == 4) {
            [texture replaceRegion:MTLRegionMake2D(0, 0, up.width, up.height)
                       mipmapLevel:0
                         withBytes:src
                       bytesPerRow:bytes_per_row];
        } else {
            // RGB → RGBA 확장(alpha=255). 임시 버퍼에 풀어 한 번에 업로드한다.
            uint8_t *rgba = (uint8_t *)malloc(px * 4u);
            if (rgba == NULL) {
                continue;
            }
            for (size_t p = 0; p < px; p++) {
                rgba[p * 4 + 0] = src[p * 3 + 0];
                rgba[p * 4 + 1] = src[p * 3 + 1];
                rgba[p * 4 + 2] = src[p * 3 + 2];
                rgba[p * 4 + 3] = 0xff;
            }
            [texture replaceRegion:MTLRegionMake2D(0, 0, up.width, up.height)
                       mipmapLevel:0
                         withBytes:rgba
                       bytesPerRow:bytes_per_row];
            free(rgba);
        }
        impl.imageTextures[@(up.image_id)] = texture; // 같은 id는 교체(새 generation)
    }
}

/* kitty graphics(K4c): live image id 집합에 없는 캐시 텍스처를 evict해 GPU 메모리를 회수한다(delete/evict/
   RIS 반영). live_count==0이면 살아있는 이미지 없음 → 전부 evict. ARC가 제거된 텍스처를 해제한다. */
static void maru_evict_image_textures(
    MaruMetalRendererImpl *impl,
    const uint32_t *live_ids,
    size_t live_count
) {
    if (impl.imageTextures.count == 0) return;
    if (live_count > 0 && live_ids == NULL) return; // 방어: count>0인데 포인터 없음 — evict 안 함
    NSMutableSet<NSNumber *> *live = [NSMutableSet setWithCapacity:live_count];
    for (size_t i = 0; i < live_count; i++) {
        [live addObject:@(live_ids[i])];
    }
    NSMutableArray<NSNumber *> *dead = [NSMutableArray array];
    for (NSNumber *key in impl.imageTextures) {
        if (![live containsObject:key]) [dead addObject:key];
    }
    for (NSNumber *key in dead) {
        [impl.imageTextures removeObjectForKey:key];
    }
}

bool maru_metal_renderer_draw(
    MaruMetalRenderer *renderer,
    CAMetalLayer *layer,
    uint16_t cols,
    uint16_t rows,
    uint32_t cell_width_px,
    uint32_t cell_height_px,
    const MaruAppHostMetalCell *cells,
    size_t cell_count,
    uint32_t terminal_origin_x_px,
    uint32_t sidebar_bg,
    const MaruAppHostMetalCell *sidebar_cells,
    size_t sidebar_cell_count,
    uint32_t sidebar_slot_height_px,
    uint32_t sidebar_header_height_px,
    /* C4b: chrome rich GPU quad 프리미티브(둥근 사각형). NULL/0이면 안 그림(tui 테마). 셀 패스 아래
       (배경 레이어)에 별개 파이프라인으로 그린다. */
    const MaruAppHostGpuQuad *gpu_quads,
    size_t gpu_quad_count,
    size_t modal_cells_start,
    /* C4b: chrome 그림자(GpuShadow). NULL/0이면 안 그림. quad·셀보다 아래(맨 처음) 그린다. */
    const MaruAppHostGpuShadow *gpu_shadows,
    size_t gpu_shadow_count,
    /* kitty graphics(K2): 이미지 placement + 텍스처 업로드 채널. */
    const MaruAppHostGpuImage *gpu_images,
    size_t gpu_image_count,
    const MaruAppHostGpuImageUpload *image_uploads,
    size_t image_upload_count,
    const uint8_t *image_pixels,
    size_t image_pixel_count,
    const uint32_t *live_image_ids,
    size_t live_image_id_count,
    uint32_t terminal_bg
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
        // 1) 사이드바 배경 quad(x:0..origin_x, 전체 높이)를 **cells보다 먼저** 그린다 — 사이드바 영역 cells(헤더
        //    glyph 등 origin_x=0)가 배경 '위'에 보이게(painter 순서). UV(-1) sentinel로 배경만(셰이더 u<0 → coverage 0 → bg.rgb).
        //    터미널 cells는 origin_x≥사이드바 폭이라 배경(x<origin_x)과 안 겹친다. quad_index 누적은 [배경][cells]
        //    [사이드바 cells] 순서이지만 사이드바 cells의 시작 인덱스(=배경+cell_count)는 옛 순서와 같다(영향 없음).
        size_t quad_index = 0;
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
        // 2) 터미널 cells — 각 cell이 자기 origin(origin_x + col×cw). 사이드바 헤더 glyph(origin_x=0)는 위 배경 '다음'
        //    순서라 사이드바 영역에 배경 위로 그려진다. 인덱스는 배경(quad_index) 다음부터.
        for (size_t i = 0; i < cell_count; i++) {
            const MaruAppHostMetalCell tc = cells[i];
            // 사이드바 헤더 아이콘 확대/정렬. 헤더 glyph만 origin_x==0이다 — 사이드바가 켜지면(terminal_origin_x_px>0)
            // 터미널 cell은 origin_x=사이드바폭>0이라 origin_x==0은 헤더뿐이고, 사이드바가 꺼지면 헤더 frame 자체가
            // 없어(buildSidebarHeaderFrame가 null) 터미널 '+'를 오확대하지 않는다.
            //   ⚙(view options)·+(새 워크스페이스): 1.7× 확대(에이전트 심볼과 같은 slot-stretch) + 줄0이 창 top에
            //   붙어 위로 쏠리므로 신호등 수직 중앙에 맞춰 아래로 내린다(py_nudge=ch×0.45 — 확대로 위가 잘리는 것도
            //   함께 방지). 🔍(검색)은 검색 텍스트와 같은 크기라 확대하지 않는다(1.0, 텍스트보다 커 보이던 것 정정).
            // 헤더 아이콘은 줄0(row==0)의 ⚙/+만 — 검색 줄(row≥1)에 사용자가 친 '+'(예: 브랜치 `feat/a+b` 검색)는
            // 같은 헤더 frame(origin_x==0)이라 row 조건이 없으면 1.7×로 확대돼 깨져 보인다. row 0으로 한정한다.
            const bool is_header = (terminal_origin_x_px > 0u && tc.origin_x == 0u);
            const bool is_corner_icon = is_header && tc.row == 0u && (tc.codepoint == 0x2699u || tc.codepoint == (uint32_t)'+');
            const float hscale = is_corner_icon ? 1.7f : 1.0f;
            const float py_nudge = is_corner_icon ? ch * 0.45f : 0.0f;
            maru_fill_cell_quad(&vertices[(quad_index + i) * vertices_per_cell], tc, (float)tc.origin_x, cw, (float)tc.origin_y + (float)tc.row * ch + py_nudge, ch, drawable_w, drawable_h, hscale);
        }
        quad_index += cell_count;
        // 3) 사이드바 cells — origin 0, 배경 quad 위에 그린다(painter 순서). 탭 슬롯 높이로 배치하되 셀 종류를
        //    slot_id로 구분한다: 밴드(slot_id==0, sentinel UV)는 row=slot으로 슬롯 전체를 채우고(py=row×slot_h,
        //    높이 slot_h). 카드 glyph(slot_id≠0)는 row에 슬롯+(줄 수,줄 위치)가 인코딩돼 있다
        //    (coretext_frame_builder.sidebarGlyphRow: row=slot*32 + line_count*4 + line_index). line_count줄(각
        //    1×cell)을 슬롯 안 블록으로 세로 중앙 정렬하고 line_index번째 줄에 ch 높이 + 좌측 여백(cw×0.5)으로 그린다.
        const float slot_h = (sidebar_slot_height_px > 0u) ? (float)sidebar_slot_height_px : ch;
        const float sidebar_header_px = (float)sidebar_header_height_px; // 상단 헤더(검색바·아이콘)만큼 셀을 아래로 민다
        const float glyph_pad = cw * 0.5f; // 제목 텍스트 좌측 여백(폰트 크기에 비례)
        for (size_t i = 0; i < sidebar_cells_n; i++) {
            const MaruAppHostMetalCell sc = sidebar_cells[i];
            float py_top, cell_h, sx_origin;
            if (sc.slot_id == 0u) { // 밴드/배경 — row=slot, 슬롯 전체, 여백 없음
                py_top = (float)sc.row * slot_h + sidebar_header_px;
                cell_h = slot_h;
                sx_origin = 0.0f;
            } else { // 카드 glyph — row=slot*32 + line_count*4 + line_index 디코드 후 슬롯 안 블록 중앙 배치
                const uint32_t slot_idx = sc.row / 32u;
                const uint32_t rem = sc.row % 32u;
                const uint32_t line_count = rem / 4u;  // 카드 줄 수(1~4)
                const uint32_t line_index = rem % 4u;  // 그 줄 위치(0=맨 위)
                const float slot_top = (float)slot_idx * slot_h + sidebar_header_px;
                const float block_h = (float)line_count * ch;
                const float block_top = slot_top + (slot_h - block_h) * 0.5f; // line_count줄 블록을 슬롯 세로 중앙
                py_top = block_top + (float)line_index * ch;
                cell_h = ch;
                sx_origin = glyph_pad;
            }
            // 에이전트 심볼(✳ U+2733 / ✻ U+273B)은 가독을 위해 1.7× 키운다(다른 글리프·밴드는 1.0).
            const float gscale = (sc.slot_id != 0u && (sc.codepoint == 0x2733u || sc.codepoint == 0x273Bu)) ? 1.7f : 1.0f;
            maru_fill_cell_quad(&vertices[(quad_index + i) * vertices_per_cell], sc, sx_origin, cw, py_top, cell_h, drawable_w, drawable_h, gscale);
        }
    }

    // C4b: chrome rich quad 정점 버퍼(gpu_quads) — 셀 패스 아래(배경 레이어)에 별개 파이프라인으로 그린다.
    // NULL/0(tui 테마)이면 생성 안 함. modal(팝업) 위 레이어 분리는 C4b-3에서.
    id<MTLBuffer> quad_vertex_buffer = nil;
    size_t quad_vertex_total = 0;
    size_t bottom_quad_n = 0; // C4b-5: layer 2(bottom — 탭 밴드) quad 수. part1(터미널·탭 제목) '앞'에 그려 제목 아래로.
    size_t under_quad_n = 0; // C4b 모달: layer 0(under — 사이드바 밴드) quad 수. draw가 under/over를 가르는 경계.
    const size_t gpu_quad_n = (gpu_quads != NULL) ? gpu_quad_count : 0;
    if (gpu_quad_n > 0) {
        if (gpu_quad_n > SIZE_MAX / 6) {
            return false;
        }
        quad_vertex_total = gpu_quad_n * 6;
        if (quad_vertex_total > SIZE_MAX / sizeof(MaruRendererQuadVertex)) {
            return false;
        }
        quad_vertex_buffer = [impl.device
            newBufferWithLength:quad_vertex_total * sizeof(MaruRendererQuadVertex)
                        options:MTLResourceStorageModeShared];
        if (quad_vertex_buffer == nil) {
            return false;
        }
        MaruRendererQuadVertex *qv = (MaruRendererQuadVertex *)quad_vertex_buffer.contents;
        // C4b: layer로 z를 가른다 — 2(bottom 탭 밴드, part1 앞)·0(under 사이드바, part1 뒤·part2 앞)·1(over 모달, 최상위).
        // 정점 버퍼에 bottom→under→over 순서로 배치해 draw가 세 패스로 그린다(탭 밴드만 layer 2 신설, 사이드바·모달 불변).
        for (size_t i = 0; i < gpu_quad_n; i++) {
            if (gpu_quads[i].layer == 2) bottom_quad_n += 1;
            else if (gpu_quads[i].layer == 0) under_quad_n += 1;
        }
        size_t bi = 0, ui = bottom_quad_n, oi = bottom_quad_n + under_quad_n;
        for (size_t i = 0; i < gpu_quad_n; i++) {
            size_t dst;
            if (gpu_quads[i].layer == 2) dst = bi++;
            else if (gpu_quads[i].layer == 0) dst = ui++;
            else dst = oi++;
            maru_fill_quad_instance(&qv[dst * 6], gpu_quads[i], drawable_w, drawable_h);
        }
    }

    // C4b: shadow 정점 버퍼(gpu_shadows) — quad·셀보다 아래(맨 처음) 그린다. NULL/0이면 생성 안 함.
    id<MTLBuffer> shadow_vertex_buffer = nil;
    size_t shadow_vertex_total = 0;
    const size_t gpu_shadow_n = (gpu_shadows != NULL) ? gpu_shadow_count : 0;
    if (gpu_shadow_n > 0) {
        if (gpu_shadow_n > SIZE_MAX / 6) {
            return false;
        }
        shadow_vertex_total = gpu_shadow_n * 6;
        if (shadow_vertex_total > SIZE_MAX / sizeof(MaruRendererShadowVertex)) {
            return false;
        }
        shadow_vertex_buffer = [impl.device
            newBufferWithLength:shadow_vertex_total * sizeof(MaruRendererShadowVertex)
                        options:MTLResourceStorageModeShared];
        if (shadow_vertex_buffer == nil) {
            return false;
        }
        MaruRendererShadowVertex *sv = (MaruRendererShadowVertex *)shadow_vertex_buffer.contents;
        for (size_t i = 0; i < gpu_shadow_n; i++) {
            maru_fill_shadow_instance(&sv[i * 6], gpu_shadows[i], drawable_w, drawable_h);
        }
    }

    // kitty graphics(K2): generation이 바뀐 이미지 텍스처를 (재)업로드한다(캐시 갱신, drawable 무관).
    maru_upload_image_textures(impl, image_uploads, image_upload_count, image_pixels, image_pixel_count);
    // kitty graphics(K4c): live 집합에 없는 텍스처를 evict(GPU 메모리 회수). 업로드 후 — 이번 frame에 올린
    // 텍스처는 live에 포함되므로 살아남는다.
    maru_evict_image_textures(impl, live_image_ids, live_image_id_count);

    // kitty graphics(K2): 이미지 placement 정점 버퍼. gpu_images는 (pass,z) 정렬돼 오므로 pass>=2 시작
    // 인덱스로 둘로 가른다 — [0,above_start)=텍스트 뒤(셀 패스 전), [above_start,n)=텍스트 앞(셀 패스 후).
    id<MTLBuffer> image_vertex_buffer = nil;
    const size_t gpu_image_n = (gpu_images != NULL) ? gpu_image_count : 0;
    size_t image_above_start = gpu_image_n; // pass>=2 시작(전부 below면 n)
    if (gpu_image_n > 0) {
        if (gpu_image_n > SIZE_MAX / 6) {
            return false;
        }
        const size_t image_vertex_total = gpu_image_n * 6;
        if (image_vertex_total > SIZE_MAX / sizeof(MaruRendererImageVertex)) {
            return false;
        }
        image_vertex_buffer = [impl.device
            newBufferWithLength:image_vertex_total * sizeof(MaruRendererImageVertex)
                        options:MTLResourceStorageModeShared];
        if (image_vertex_buffer == nil) {
            return false;
        }
        MaruRendererImageVertex *iv = (MaruRendererImageVertex *)image_vertex_buffer.contents;
        for (size_t i = 0; i < gpu_image_n; i++) {
            maru_fill_image_quad(&iv[i * 6], gpu_images[i], drawable_w, drawable_h);
            if (image_above_start == gpu_image_n && gpu_images[i].pass >= 2) {
                image_above_start = i;
            }
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
    // 화면 clear color: terminal_bg(0xAARRGGBB — OSC 11 배경 set 또는 theme.background)가 비-0이면 그 색,
    // 0이면 기존 기본(어두운 남색)으로 폴백. 빈 영역/기본 배경(A0) 셀이 비치는 색.
    if (terminal_bg != 0) {
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            (double)((terminal_bg >> 16) & 0xff) / 255.0,
            (double)((terminal_bg >> 8) & 0xff) / 255.0,
            (double)(terminal_bg & 0xff) / 255.0,
            1.0);
    } else {
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.06, 0.08, 0.12, 1.0);
    }

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
    // C4b: 레이어 순서 = [사이드바 배경 strip] → [터미널 cells(헤더 glyph 포함)] → quad(둥근 밴드) → [사이드바
    // cells(제목)]. 배경 strip(불투명 bg quad)을 '맨 앞'에 그려야 (a)사이드바 헤더 glyph(origin_x=0, 터미널 셀 패스)가
    // 그 위에 보이고 (b)rich 밴드 quad가 strip 위에 보인다(strip을 셀 패스 전체 뒤에 두면 밴드를 덮어 안 보였다).
    // 그래서 셀 패스를 [배경 strip(1a)] · [터미널(1b)] · [사이드바 제목(4)] 셋으로 쪼개고, 밴드 quad(under)를
    // 터미널 '뒤'·제목 glyph '앞'에 끼운다. (모달/divider quad의 위 레이어 분리는 후속.)
    const size_t cell_count_v = cell_count * 6;
    const size_t pre_sidebar_vertices = (cell_count + sidebar_bg_quads) * 6;
    // 버퍼 레이아웃은 [사이드바 bg quad][터미널 cells][사이드바 cells]다(채우기 순서). bg quad가 '맨 앞'이므로
    // 터미널 cell i의 정점은 cells_base_v + i*6에서 시작한다(0이 아님). 셀 패스 오프셋은 전부 이 base를 더해야
    // 한다 — 안 그러면 모달 분할(terminal_end/modal_cells_start)이 한 셀씩 밀린다.
    const size_t cells_base_v = sidebar_bg_quads * 6;
    const size_t bottom_vertex_count = bottom_quad_n * 6; // C4b-5: 탭 밴드(part1 앞 패스)
    const size_t under_vertex_count = under_quad_n * 6;
    // C4b 모달: 모달(overlay) 셀이 cells[modal_cells_start..cell_count]에 있으면, over quad(모달 배경)를 모달
    // 텍스트 '앞'에 끼운다 → 터미널(모달 제외) → 배경 → under quad(사이드바 밴드) → 사이드바 → over quad
    // (모달 배경) → 모달 텍스트. 모달 없으면(0) terminal_end=cell_count라 1·6이 합쳐져 기존과 같다.
    const bool has_modal = (modal_cells_start > 0 && modal_cells_start < cell_count);
    const size_t terminal_end_v = (has_modal ? modal_cells_start : cell_count) * 6;
#define MARU_DRAW_CELLS(sv, cv)                                       \
    do {                                                             \
        if ((cv) > 0) {                                              \
            [encoder setRenderPipelineState:impl.pipeline];          \
            [encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0]; \
            [encoder setFragmentTexture:impl.atlas atIndex:0];       \
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:(sv) vertexCount:(cv)]; \
        }                                                            \
    } while (0)
#define MARU_DRAW_QUADS(sv, cv)                                       \
    do {                                                             \
        if ((cv) > 0) {                                              \
            [encoder setRenderPipelineState:impl.quadPipeline];      \
            [encoder setVertexBuffer:quad_vertex_buffer offset:0 atIndex:0]; \
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:(sv) vertexCount:(cv)]; \
        }                                                            \
    } while (0)
    // kitty graphics(K2): 이미지를 image_id별 텍스처로 한 장씩 그린다([si,ei) 구간). 텍스처 없는 건 skip
    // (Zig는 업로드했다고 보지만 캐시에 없으면 — 렌더러 재생성 등 — 안 그릴 뿐, crash 없음).
#define MARU_DRAW_IMAGES(si, ei)                                      \
    do {                                                             \
        if (image_vertex_buffer != nil && (ei) > (si)) {             \
            /* pipeline·vertex buffer는 범위당 1회만 바인딩한다 — 이미지마다 바뀌는 건 fragment   \
               texture뿐이라, 매 이미지 재바인딩(pipeline/vertex state 변경은 인코더에서 가장 비싼 \
               연산)을 루프 밖으로 끌어낸다. draw 순서·결과는 불변. */                            \
            [encoder setRenderPipelineState:impl.imagePipeline];     \
            [encoder setVertexBuffer:image_vertex_buffer offset:0 atIndex:0]; \
            for (size_t ii = (si); ii < (ei); ii++) {                \
                id<MTLTexture> tex = impl.imageTextures[@(gpu_images[ii].image_id)]; \
                if (tex == nil) continue;                            \
                [encoder setFragmentTexture:tex atIndex:0];          \
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:(ii * 6) vertexCount:6]; \
            }                                                        \
        }                                                            \
    } while (0)
    if (quad_vertex_buffer != nil) MARU_DRAW_QUADS(0, bottom_vertex_count);   // 0. bottom quad(탭 밴드 — 터미널·제목 앞, 제목 아래로)
    MARU_DRAW_IMAGES(0, image_above_start);                                   // 0.5 kitty 이미지(텍스트 뒤 — 투명 셀로 비침)
    // 1a. 사이드바 배경 strip(bg quad, 버퍼 맨 앞 [0, cells_base_v)) — 터미널 cells '앞'에 그려 사이드바 헤더
    //     glyph(origin_x=0, 셀 패스)·밴드·제목이 배경 '위'에 보이게 한다(painter — 헤더 glyph 가림 회귀 fix).
    if (vertex_buffer != nil) MARU_DRAW_CELLS(0, cells_base_v);
    // 1b. 터미널(모달 제외, 탭 제목 포함) — cells는 bg quad 다음(cells_base_v)부터.
    if (vertex_buffer != nil) MARU_DRAW_CELLS(cells_base_v, terminal_end_v);
    MARU_DRAW_IMAGES(image_above_start, gpu_image_n);                         // 1.5 kitty 이미지(텍스트 앞)
    if (quad_vertex_buffer != nil) MARU_DRAW_QUADS(bottom_vertex_count, under_vertex_count); // 3. under quad(사이드바 밴드)
    if (vertex_buffer != nil) MARU_DRAW_CELLS(pre_sidebar_vertices, total_vertices - pre_sidebar_vertices); // 4. 사이드바 cells(제목)
    // C4b: shadow 패스 — 터미널·사이드바 위, 모달 배경(over quad) 아래. 모달이 떠 보이게(리뷰 #1 — 맨 처음이면
    // 터미널 셀이 halo를 덮어 그림자가 깜빡/사라졌다). 모달 over quad·텍스트가 이 위에 그려진다.
    if (shadow_vertex_buffer != nil) {
        [encoder setRenderPipelineState:impl.shadowPipeline];
        [encoder setVertexBuffer:shadow_vertex_buffer offset:0 atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:shadow_vertex_total];
    }
    if (quad_vertex_buffer != nil) MARU_DRAW_QUADS(bottom_vertex_count + under_vertex_count, quad_vertex_total - bottom_vertex_count - under_vertex_count); // 5. over quad(모달 배경)
    if (vertex_buffer != nil && has_modal) MARU_DRAW_CELLS(cells_base_v + modal_cells_start * 6, cell_count_v - modal_cells_start * 6); // 6. 모달 텍스트(cells_base_v 오프셋)
#undef MARU_DRAW_CELLS
#undef MARU_DRAW_QUADS
#undef MARU_DRAW_IMAGES
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
    impl.quadPipeline = nil;
    impl.shadowPipeline = nil;
    impl.imagePipeline = nil;
    [impl.imageTextures removeAllObjects];
    impl.imageTextures = nil;
    impl.queue = nil;
    impl.device = nil;
}
