#import "maru_metal_renderer.h"
#import "maru_metal_shader.h"
#import "maru_ppm_writer.h"
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

/* 스크린샷 하니스(MARU_SCREENSHOT). 평소엔 비어 있고(NULL) lean 런타임에 비용이 없다 —
   env가 설정됐을 때만 draw가 오프스크린 캡처 경로로 분기한다. getenv를 매 frame 부르지 않게
   한 번만 캐시한다(draw는 Swift main-thread timer에서만 불리지만 dispatch_once로 못박는다).
   반환값 NULL이면 평소(present) 경로, 비-NULL이면 그 경로로 PPM 한 장 쓰고 프로세스를 끝낸다. */
static const char *maru_screenshot_path(void) {
    static const char *path = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *env = getenv("MARU_SCREENSHOT");
        if (env != NULL && env[0] != '\0') {
            path = env;
        }
    });
    return path;
}

/* Chrome Lab처럼 한 frame capture 뒤 Zig 쪽에서 artifact를 검사해야 하는 test executable만
   `maru-test-only-v1`을 넣어 종료를 억제한다. 일반 MARU_SCREENSHOT은 기존처럼 capture 직후
   종료하고, 값이 다르면 fail-closed로 일반 동작을 유지한다. 이 조회는 screenshot mode 안에서만
   일어나므로 평소 renderer hot path에는 새 getenv가 없다. */
static bool maru_screenshot_keeps_process(void) {
    const char *value = getenv("MARU_SCREENSHOT_KEEP_PROCESS");
    return value != NULL && strcmp(value, "maru-test-only-v1") == 0;
}

/* MARU_SCREENSHOT_DELAY_MS: 캡처를 "내용이 있는 첫 frame"에서 N ms 늦춘다(그동안은 평소 present).
   기본(미설정/0)은 기존과 동일한 즉시 캡처. 첫 frame은 탭바/커서만으로도 '내용'이 되므로, PTY
   출력(셸 스크립트의 색 테스트 등)이 화면에 도달한 뒤를 찍으려면 이 지연이 필요하다 — 렌더 검증
   하니스 전용이며 env 미설정 일반 실행엔 비용·분기가 없다(스크린샷 모드 안에서만 읽는다). */
static bool maru_screenshot_delay_elapsed(void) {
    static double delay_ms = -1.0;
    static double first_content_frame_at = 0.0;
    if (delay_ms < 0.0) {
        const char *env = getenv("MARU_SCREENSHOT_DELAY_MS");
        delay_ms = (env != NULL) ? strtod(env, NULL) : 0.0;
        if (delay_ms < 0.0) delay_ms = 0.0;
    }
    if (delay_ms == 0.0) return true;
    const double now_ms = CACurrentMediaTime() * 1000.0;
    if (first_content_frame_at == 0.0) first_content_frame_at = now_ms;
    return (now_ms - first_content_frame_at) >= delay_ms;
}

/* Metal copyFromTexture:toBuffer:의 destinationBytesPerRow는 GPU에 따라 256 정렬을 요구하므로
   (smoke의 readback stride와 같은 값) width*4를 256의 배수로 올림한다. PPM writer는 이 stride를
   행 간격으로 받아 width 픽셀만 쓰므로 패딩 바이트는 무시된다. */
static size_t maru_align_up_256(size_t value) {
    const size_t alignment = 256;
    if (value > SIZE_MAX - (alignment - 1)) {
        return 0; // overflow
    }
    return (value + (alignment - 1)) & ~(alignment - 1);
}

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
    float gradient_kind;   // 0=solid, 1=vertical, 2=horizontal, 3=위 삼각형(말풍선 caret — fill0 단색+edge AA)
    float clip[4];         // 좌상단 원점 backing-pixel 뷰포트 (x, y, w, h). w==0이면 클리핑 없음
} MaruRendererQuadVertex;

// 셰이더 QuadIn(maru_metal_shader.h)이 이 정점을 buffer(0)로 raw 재해석하므로 레이아웃이 1:1이어야 한다.
// packed_float2×3(24) + packed_float4×6(96) + float(4) = 124B tight-pack. 한쪽만 필드를 바꾸면 GPU가
// 엉뚱한 offset을 읽어 조용히 깨지므로(컴파일·테스트 무경고) 크기를 정적 단언으로 못박는다(GpuQuad ABI와 동형 가드).
_Static_assert(sizeof(MaruRendererQuadVertex) == 124, "MaruRendererQuadVertex must match MSL QuadIn (124B tight-pack)");

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
// Phase 4b-2 오버레이 present 상태: 직전 present에서 오버레이 레이어에 실제로 그린 게 content(모달·그림자)였는가.
// present 결정에 쓴다 — content→빈 전이 프레임엔 clear를 present해 닫힌 모달 잔상을 지우고(그 뒤엔 빈→빈이라 skip),
// 빈→빈이면 오버레이 present를 통째로 건너뛴다(모달 없는 평상시 매 프레임 이중 present 방지). 기본 false(초기
// 오버레이=미present=투명). per-surface impl이라 창마다 자기 오버레이 상태를 정확히 추적한다.
@property (nonatomic) bool overlayHadContent;
// AS4-c host fixture만 다음 completed frame의 최종 합성 결과를 복사한다. 일반 screenshot env와
// 별개인 one-shot request라 여러 상태를 한 process에서 capture해도 다음 user frame에 남지 않는다.
@property (nonatomic, copy) NSString *testCapturePath;
@end

@implementation MaruMetalRendererImpl
@end

/* one-shot test capture seam을 열어 주는 fixture env 허용 목록. 값은 정확히 "1"이어야 하고(fail-closed),
   여기 없는 실행에서는 seam 자체가 없다 — 제품·일반 스크린샷 경로는 이 함수를 통과하지 못한다. */
static bool maru_test_capture_env_allows(void) {
    static const char *const gates[] = {
        "MARU_AGENT_SESSION_ARCHIVE_SMOKE", /* AS4-c 아카이브 상태 캡처 */
        "MARU_TAB_DRAG_SMOKE",              /* CIM4b 탭 드래그 — 끄는 도중 프레임 */
    };
    for (size_t i = 0; i < sizeof(gates) / sizeof(gates[0]); i += 1) {
        const char *value = getenv(gates[i]);
        if (value != NULL && strcmp(value, "1") == 0) {
            return true;
        }
    }
    return false;
}

bool maru_metal_renderer_request_test_capture(
    MaruMetalRenderer *renderer,
    const char *ppm_path
) {
    if (renderer == NULL || ppm_path == NULL || ppm_path[0] == '\0') {
        return false;
    }
    // This is deliberately unavailable to ordinary screenshot/product launches. The host also
    // verifies an isolated fixture root, but keeping the renderer seam independently test-gated
    // prevents another caller from accidentally changing MARU_SCREENSHOT's one-frame exit contract.
    // 허용 목록은 이 seam을 실제로 쓰는 AppKit E2E들이다 — CIM4b 탭 드래그 스모크는 **끄는 도중의**
    // 프레임을 찍어야 해서 첫-프레임-후-종료인 MARU_SCREENSHOT으로는 얻을 수 없다.
    if (!maru_test_capture_env_allows()) {
        return false;
    }
    MaruMetalRendererImpl *impl = (__bridge MaruMetalRendererImpl *)renderer;
    if (impl.testCapturePath != nil) {
        return false;
    }
    NSString *path = [NSString stringWithUTF8String:ppm_path];
    if (path == nil || path.length == 0) {
        return false;
    }
    impl.testCapturePath = path;
    return true;
}

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
    float glyph_scale_x, // 글리프 가로 확대 배율(1.0=무확대). 도크 토글은 producer atlas extent에서 파생.
    float glyph_scale_y, // 글리프 세로 확대 배율. x와 분리해 정수 px로 굳힌 atlas 크기를 그대로 소비한다.
    uint32_t divider_thickness_px // pane divider(reserved 30 세로·31 가로)의 device px 두께(config split.divider-thickness → app_session). seam 중앙정렬·셀 clamp. 0=안 보임.
) {
    const float span = (float)(cell.width == 0 ? 1 : cell.width);
    float px_left = origin_x + (float)cell.col * cw;
    float px_right = px_left + cw * span;
    float px_top = py_top;
    float px_bottom = py_top + cell_h;
    // 커서·장식선 부분 사각형(reserved). 셀의 한 변 또는 중앙에 가는 띠를 그린다.
    //   강조선(셀 높이/폭 ~15%): 2=underline 커서·hollow 하단, 3=bar 커서·hollow 좌측,
    //   4=hollow 상단, 5=hollow 우측, 8=OSC 133 거터 바(셀 왼쪽 바깥). block(0)은 전체 cell.
    //   pane divider(config 두께 divider_thickness_px, seam 중앙정렬·셀 clamp): 30=세로선·31=가로선. 커서 강조선(2~5, 15%)과
    //   분리해 divider만 config로 두께 조절(split.divider-thickness). FocusOwner border는 이 cell 경로가 아닌 GPU quad다.
    //   텍스트 장식선(SGR)은 글자에 붙는 가는 선이라 강조선(15%)의 절반인 ~7.5%로 가늘게 그린다 —
    //   9=밑줄(SGR 4)·링크 hover 하단, 10=윗줄(SGR 53) 상단, 6=취소선(SGR 9) 중앙, 7=2중밑줄(SGR 21) 둘째 선.
    //   베이스: Ghostty는 폰트 메트릭 underline_thickness(=max(1,ceil(face.underlineThickness)))를 쓰지만,
    //   maru는 폰트 메트릭을 .m에 전달하지 않으므로 cell_h 비례 근사를 쓰되 텍스트 장식선은 그 가는 밑줄에
    //   맞춰 절반으로 둔다. 커서·divider는 강조 요소라 15%를 유지한다(텍스트만 가늘게).
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
    } else if (cell.reserved == 30) {
        // pane divider 세로선: 셀 origin이 경계(seam=px_left)라, 그 seam에 config 두께를 **중앙 정렬**하고 셀폭으로
        // clamp한다(두꺼운 값이 인접 pane 내용 위로 번지지 않게 — 최대 1셀, 좌/우 pane에 반씩). 커서 강조선 15%와 분리.
        const float t = fminf((float)divider_thickness_px, cw);
        const float seam = px_left;
        px_left = seam - t * 0.5f;
        px_right = seam + t * 0.5f;
    } else if (cell.reserved == 31) {
        // pane divider 가로선: 셀 origin이 경계(seam=px_top)라, 그 seam에 config 두께를 중앙 정렬하고 셀 높이로 clamp.
        const float t = fminf((float)divider_thickness_px, cell_h);
        const float seam = px_top;
        px_top = seam - t * 0.5f;
        px_bottom = seam + t * 0.5f;
    }
    // 글리프 확대: 셀 quad를 중앙 기준으로 키운다. 헤더 줄0 아이콘(1.7×)은 slot도 목표 px(raster_*_px)라 큰
    // 텍스처를 큰 quad에 1:1로 그려 선명; 사이드바 에이전트 심볼(1.1×)은 slot이 셀 크기라 stretch한다(약간
    // 부드러우나 보조 심볼이라 무방). UV는 그대로라 글리프만 커진다. glyph_scale=1.0이면 무동작(일반 셀·커서).
    if (glyph_scale_x != 1.0f || glyph_scale_y != 1.0f) {
        const float cx = (px_left + px_right) * 0.5f;
        const float cy = (px_top + px_bottom) * 0.5f;
        px_left = cx + (px_left - cx) * glyph_scale_x;
        px_right = cx + (px_right - cx) * glyph_scale_x;
        px_top = cy + (px_top - cy) * glyph_scale_y;
        px_bottom = cy + (px_bottom - cy) * glyph_scale_y;
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
    // UV는 metal_frame.zig가 굽고(glyph_quads.uvRectForPx 단일 출처), 멀티 페인 grow 정합을 위해 replace가
    // 최종 atlas 크기로 renormalizeGlyphCellUvs로 다시 정규화해 넘긴다 — 렌더러는 그대로 쓴다(수치 계산은 Zig).
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

/* A(자간 분리): 폰트 글리프를 **자연폭**(atlas slot 폭, device px)으로 px_left에서 **좌측정렬** 그린다. 셀 배경은
   별도 bg quad(셀폭)가 그리므로, 이 글리프 quad는 **투명 bg(0,0,0,0)**로 그 위에 over-blend된다 — 셰이더가
   premultiplied(rgb=mix(bg,fg,cov), a=max(bg.a,cov))라 bg.a=0이면 (fg*cov, cov)로 환원돼 아래 bg quad에 정확히
   합성된다. 그래서 자간이 셀 advance를 좁혀도(음수=이웃과 겹침)·넓혀도(양수=우측 여백) 글리프가 찌그러지지 않고
   자연 비율로 그려진다. reserved 장식·확대(glyph_scale) 없는 일반 텍스트 글리프 전용(호출처가 게이트). */
static void maru_fill_glyph_quad(
    MaruRendererVertex *out,
    const MaruAppHostMetalCell cell,
    float px_left,
    float glyph_w,
    float py_top,
    float cell_h,
    float drawable_w,
    float drawable_h
) {
    const float px_right = px_left + glyph_w;
    const float px_bottom = py_top + cell_h;
    const float left = (px_left / drawable_w) * 2.0f - 1.0f;
    const float right = (px_right / drawable_w) * 2.0f - 1.0f;
    const float top = 1.0f - (py_top / drawable_h) * 2.0f;
    const float bottom = 1.0f - (px_bottom / drawable_h) * 2.0f;
    const float fr = (float)((cell.foreground >> 16) & 0xff) / 255.0f;
    const float fg = (float)((cell.foreground >> 8) & 0xff) / 255.0f;
    const float fb = (float)(cell.foreground & 0xff) / 255.0f;
    const MaruRendererVertex quad[6] = {
        {{left, top}, {cell.u0, cell.v0}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
        {{left, bottom}, {cell.u0, cell.v1}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
        {{right, bottom}, {cell.u1, cell.v1}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
        {{left, top}, {cell.u0, cell.v0}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
        {{right, bottom}, {cell.u1, cell.v1}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
        {{right, top}, {cell.u1, cell.v0}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
    };
    memcpy(out, quad, sizeof(quad));
}

/* B1 rich Chrome text uses the same atlas/premultiplied glyph pipeline as terminal text, but its
   final rect comes from the component text artifact instead of a cell row/column. Keeping this a
   distinct DTO prevents a future Button from smuggling sub-cell y through NativeMetalCell. */
static void maru_fill_rich_glyph_quad(
    MaruRendererVertex *out,
    const MaruAppHostGpuGlyph glyph,
    float drawable_w,
    float drawable_h
) {
    const float left = (glyph.x / drawable_w) * 2.0f - 1.0f;
    const float right = ((glyph.x + glyph.w) / drawable_w) * 2.0f - 1.0f;
    const float top = 1.0f - (glyph.y / drawable_h) * 2.0f;
    const float bottom = 1.0f - ((glyph.y + glyph.h) / drawable_h) * 2.0f;
    const float fr = (float)((glyph.foreground >> 16) & 0xff) / 255.0f;
    const float fg = (float)((glyph.foreground >> 8) & 0xff) / 255.0f;
    const float fb = (float)(glyph.foreground & 0xff) / 255.0f;
    const MaruRendererVertex quad[6] = {
        {{left, top}, {glyph.u0, glyph.v0}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
        {{left, bottom}, {glyph.u0, glyph.v1}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
        {{right, bottom}, {glyph.u1, glyph.v1}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
        {{left, top}, {glyph.u0, glyph.v0}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
        {{right, bottom}, {glyph.u1, glyph.v1}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
        {{right, top}, {glyph.u1, glyph.v0}, {fr, fg, fb}, {0.0f, 0.0f, 0.0f, 0.0f}},
    };
    memcpy(out, quad, sizeof(quad));
}

static void maru_draw_rich_glyphs(
    id<MTLRenderCommandEncoder> encoder,
    MaruMetalRendererImpl *impl,
    const MaruAppHostGpuGlyph *glyphs,
    size_t glyph_count,
    CGSize drawable_size
) {
    if (glyphs == NULL || glyph_count == 0 || drawable_size.width <= 0.0 || drawable_size.height <= 0.0) return;
    if (glyph_count > SIZE_MAX / 6 || glyph_count * 6 > SIZE_MAX / sizeof(MaruRendererVertex)) return;
    id<MTLBuffer> buffer = [impl.device newBufferWithLength:glyph_count * 6 * sizeof(MaruRendererVertex)
                                                     options:MTLResourceStorageModeShared];
    if (buffer == nil) return;
    MaruRendererVertex *vertices = (MaruRendererVertex *)buffer.contents;
    size_t count = 0;
    for (size_t i = 0; i < glyph_count; i++) {
        if (glyphs[i].layer != 0u || glyphs[i].w <= 0.0f || glyphs[i].h <= 0.0f) continue;
        maru_fill_rich_glyph_quad(&vertices[count * 6], glyphs[i], (float)drawable_size.width, (float)drawable_size.height);
        count += 1;
    }
    if (count == 0) return;
    const float opacity = 1.0f;
    [encoder setRenderPipelineState:impl.pipeline];
    [encoder setVertexBuffer:buffer offset:0 atIndex:0];
    [encoder setFragmentBytes:&opacity length:sizeof(float) atIndex:1];
    [encoder setFragmentTexture:impl.atlas atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:count * 6];
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
    // 클리핑은 rect를 미리 자르지 않는다 — shader가 원본 모양(corner radius·변별 border)을 그린 뒤 이
    // 사각형 밖 fragment만 버린다. CPU가 rect를 먼저 자르면 잘린 변에 없어야 할 곡률과 stroke가 생긴다.
    base.clip[0] = quad.clip_x;
    base.clip[1] = quad.clip_y;
    base.clip[2] = quad.clip_w;
    base.clip[3] = quad.clip_h;
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

/* Phase 4b(b1): 한 draw pass의 인코딩 시퀀스를 두 논리 레이어(터미널 / 모달 오버레이)로 분할한다.
   지금은 두 함수가 **같은 encoder·같은 drawable**에 back-to-back으로 그려 출력이 byte-identical이다
   (1레이어 무회귀 — docs/web-panel.md §2 (a) 렌더러 분할의 함수 경계만 먼저 고정). b2에서 각 함수에
   자기 CAMetalLayer의 drawable/encoder를 주면 실제 2레이어가 된다(그때 present 원자성·컨테이너 재편).
   이 컨텍스트는 그 분할 경계에 필요한 상태(encoder·버퍼·오프셋·모달/커서 파라미터)를 한 번에 나른다.
   ARC 소유 객체는 __unsafe_unretained로 담는다 — 이 struct는 stack-local이고 담긴 객체(encoder·버퍼·
   impl)는 모두 maru_metal_renderer_draw 지역이 draw 호출 동안 강참조로 살려 두므로 안전하다. */
typedef struct {
    __unsafe_unretained id<MTLRenderCommandEncoder> encoder;
    __unsafe_unretained MaruMetalRendererImpl *impl;
    __unsafe_unretained id<MTLBuffer> vertex_buffer;
    __unsafe_unretained id<MTLBuffer> quad_vertex_buffer;
    __unsafe_unretained id<MTLBuffer> shadow_vertex_buffer;
    __unsafe_unretained id<MTLBuffer> image_vertex_buffer;
    const MaruAppHostGpuImage *gpu_images;
    CGSize drawable_size;
    // gpu_quads 레이어 세그먼트 정점 수: bottom(탭 밴드)·under(사이드바 밴드)·header(배지) + 전체.
    size_t bottom_vertex_count;
    size_t under_vertex_count;
    size_t header_vertex_count;
    size_t quad_vertex_total;
    size_t shadow_vertex_total;
    // kitty 이미지: 텍스트-앞(pass>=2) 시작 인덱스와 전체 개수.
    size_t image_above_start;
    size_t gpu_image_n;
    // 셀 정점 오프셋(자간 자연폭이라 셀당 2 quad = ×12): 사이드바 bg quad 뒤 터미널 셀 base·사이드바 셀 시작·전체.
    size_t cells_base_v;
    size_t pre_sidebar_vertices;
    size_t total_vertices;
    // 본문 터미널(모달·커서 suffix 제외) 끝 정점.
    size_t terminal_end_v;
    // 커서 blink 페이드 suffix(셀): 시작·개수·불투명도·게이트.
    size_t cursor_start;
    size_t cursor_cells;
    float cursor_opacity;
    bool draw_cursor;
    // v146 본문 분할: 커서 구간을 뺀 앞/뒤 두 구간(셀 단위). 커서가 그 레이어에 없으면 b_len=0이라 한 번만 그린다.
    size_t term_b_start;
    size_t term_b_len;
    size_t modal_a_len;
    size_t modal_b_start;
    size_t modal_b_len;
    bool cursor_in_terminal;
    bool cursor_in_modal;
    bool has_modal;
    // 모달 오버레이: 셀 시작 인덱스와 클리핑 px(w==0=없음).
    size_t modal_cells_start;
    uint32_t modal_clip_x_px;
    uint32_t modal_clip_y_px;
    uint32_t modal_clip_w_px;
    uint32_t modal_clip_h_px;
    // 사이드바 스크롤 scissor 판정용.
    size_t sidebar_cells_n;
    uint32_t sidebar_scroll_offset_px;
    uint32_t sidebar_header_height_px;
} MaruDrawPass;

// 셀/quad/이미지 draw 매크로(컨텍스트 c 기준). 커서 페이드 pass만 op<1이라 셀 fragment opacity를 넘긴다.
#define MARU_DRAW_CELLS(sv, cv, op)                                        \
    do {                                                                   \
        if ((cv) > 0) {                                                    \
            float _op = (op);                                              \
            [c->encoder setRenderPipelineState:c->impl.pipeline];          \
            [c->encoder setVertexBuffer:c->vertex_buffer offset:0 atIndex:0]; \
            [c->encoder setFragmentBytes:&_op length:sizeof(float) atIndex:1]; \
            [c->encoder setFragmentTexture:c->impl.atlas atIndex:0];       \
            [c->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:(sv) vertexCount:(cv)]; \
        }                                                                  \
    } while (0)
#define MARU_DRAW_QUADS(sv, cv)                                            \
    do {                                                                   \
        if ((cv) > 0) {                                                    \
            [c->encoder setRenderPipelineState:c->impl.quadPipeline];      \
            [c->encoder setVertexBuffer:c->quad_vertex_buffer offset:0 atIndex:0]; \
            [c->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:(sv) vertexCount:(cv)]; \
        }                                                                  \
    } while (0)
#define MARU_DRAW_IMAGES(si, ei)                                           \
    do {                                                                   \
        if (c->image_vertex_buffer != nil && (ei) > (si)) {               \
            /* pipeline·vertex buffer는 범위당 1회만 바인딩하고 이미지마다 fragment texture만 바꾼다. */ \
            [c->encoder setRenderPipelineState:c->impl.imagePipeline];    \
            [c->encoder setVertexBuffer:c->image_vertex_buffer offset:0 atIndex:0]; \
            for (size_t ii = (si); ii < (ei); ii++) {                     \
                id<MTLTexture> tex = c->impl.imageTextures[@(c->gpu_images[ii].image_id)]; \
                if (tex == nil) continue;                                 \
                [c->encoder setFragmentTexture:tex atIndex:0];            \
                [c->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:(ii * 6) vertexCount:6]; \
            }                                                             \
        }                                                                 \
    } while (0)

/* 터미널 레이어 pass(맨 아래): 탭 밴드 quad → kitty(텍스트 뒤) → 사이드바 bg strip → 헤더 배지 quad →
   터미널 본문 셀 → 터미널 커서 페이드(모달 없을 때) → kitty(텍스트 앞) → 사이드바 밴드 quad → 사이드바 셀.
   b2에서 이 함수가 터미널 CAMetalLayer의 drawable/encoder를 받는다. */
static void maru_draw_terminal_layer(const MaruDrawPass *c) {
    if (c->quad_vertex_buffer != nil) MARU_DRAW_QUADS(0, c->bottom_vertex_count); // 0. bottom quad(탭 밴드 — 터미널·제목 앞, 제목 아래로)
    MARU_DRAW_IMAGES(0, c->image_above_start);                                    // 0.5 kitty 이미지(텍스트 뒤 — 투명 셀로 비침)
    // 1a. 사이드바 배경 strip(bg quad, 버퍼 맨 앞 [0, cells_base_v)) — 터미널 cells '앞'에 그려 사이드바 헤더
    //     glyph(origin_x=0, 셀 패스)·밴드·제목이 배경 '위'에 보이게 한다(painter — 헤더 glyph 가림 회귀 fix).
    if (c->vertex_buffer != nil) MARU_DRAW_CELLS(0, c->cells_base_v, 1.0f);
    // 1a+. 헤더 quad(layer 4, 알림 종 배지 빨강 원) — 사이드바 bg strip '뒤' / 터미널·헤더 글리프 '앞'에 끼운다(흰 숫자
    //      글리프가 원 위에 보이게). 버퍼 구간 [bottom+under, +header). 배지 없으면 0이라 no-op(기존 경로 불변).
    if (c->quad_vertex_buffer != nil) MARU_DRAW_QUADS(c->bottom_vertex_count + c->under_vertex_count, c->header_vertex_count);
    // 1b. 터미널(모달 제외, 탭 제목 포함) — cells는 bg quad 다음(cells_base_v)부터. opacity 1.0. 커서가 이 레이어에
    //     있으면 그 구간을 빼고 앞[0,커서)·뒤(커서,끝) 두 번 그린다(v146 — 커서는 아래 페이드 pass가 따로 그린다).
    if (c->vertex_buffer != nil) MARU_DRAW_CELLS(c->cells_base_v, c->terminal_end_v, 1.0f);
    if (c->vertex_buffer != nil && c->term_b_len > 0)
        MARU_DRAW_CELLS(c->cells_base_v + c->term_b_start * 12, c->term_b_len * 12, 1.0f);
    // 1b+. 터미널 커서 페이드 pass(커서가 터미널 레이어에 있을 때). 본문 '뒤'·kitty 텍스트-앞 이미지 '앞'에 그려 기존
    //      커서 레이어를 보존한다. cursor_fade_milli<1이면 반투명으로 아래 본문 셀에 합성돼 blink가 페이드.
    if (c->vertex_buffer != nil && c->draw_cursor && c->cursor_in_terminal)
        MARU_DRAW_CELLS(c->cells_base_v + c->cursor_start * 12, c->cursor_cells * 12, c->cursor_opacity);
    MARU_DRAW_IMAGES(c->image_above_start, c->gpu_image_n);                        // 1.5 kitty 이미지(텍스트 앞)
    if (c->quad_vertex_buffer != nil) MARU_DRAW_QUADS(c->bottom_vertex_count, c->under_vertex_count); // 3. under quad(사이드바 밴드)
    // 4. 사이드바 cells(밴드·제목). 스크롤됐으면(offset>0) 헤더 위로 샌 카드를 자르도록 헤더 영역 [0, header_h)를
    //    scissor 밖으로 둬 [header_h, drawable_h]만 그린다. **MTLScissorRect는 좌상단 원점**(Apple 문서 — framebuffer
    //    픽셀 좌표, y가 아래로 증가). 정점 셰이더가 py_top(좌상단 px)→NDC로 매핑해 framebuffer가 표준 방향이라, 상단
    //    헤더를 자르려면 y=header_h부터 남긴다. 헤더 glyph는 터미널 셀 패스(위)라 이 scissor에 안 걸려 고정된다. 바로
    //    뒤 패스(그림자·모달)를 위해 full drawable로 복원한다. offset==0이면 기존 동작(scissor 없음).
    const bool sidebar_scroll_clip = (c->sidebar_cells_n > 0 && c->sidebar_scroll_offset_px > 0u &&
                                      (float)c->sidebar_header_height_px < (float)c->drawable_size.height);
    if (sidebar_scroll_clip) {
        const NSUInteger dw = (NSUInteger)c->drawable_size.width;
        const NSUInteger dh = (NSUInteger)c->drawable_size.height;
        const NSUInteger header_h = (NSUInteger)c->sidebar_header_height_px; // 좌상단 원점 → 상단 header_h를 잘라내고 [header_h, dh] 유지
        [c->encoder setScissorRect:(MTLScissorRect){ .x = 0, .y = header_h, .width = dw, .height = dh - header_h }];
    }
    if (c->vertex_buffer != nil) MARU_DRAW_CELLS(c->pre_sidebar_vertices, c->total_vertices - c->pre_sidebar_vertices, 1.0f); // 사이드바 cells(제목)
    if (sidebar_scroll_clip) {
        const NSUInteger dw = (NSUInteger)c->drawable_size.width;
        const NSUInteger dh = (NSUInteger)c->drawable_size.height;
        [c->encoder setScissorRect:(MTLScissorRect){ .x = 0, .y = 0, .width = dw, .height = dh }]; // full 복원(다음 패스용)
    }
}

/* 모달 오버레이 레이어 pass(맨 위): 그림자 → over quad(모달 배경) → 모달 텍스트 셀(clip scissor) →
   오버레이 caret 페이드(모달 열림일 때). b2에서 이 함수가 투명 오버레이 CAMetalLayer의 drawable/encoder를
   받아 터미널 레이어(+미래 WKWebView) 위에 합성된다. 모달이 없으면(has_modal=false, over/modal 세그먼트 0)
   그림자·caret pass만 게이트로 걸러져 사실상 no-op이다. */
static void maru_draw_overlay_layer(const MaruDrawPass *c) {
    // C4b: shadow 패스 — 터미널·사이드바 위, 모달 배경(over quad) 아래. 모달이 떠 보이게(맨 처음이면 터미널
    // 셀이 halo를 덮어 그림자가 깜빡/사라졌다). 모달 over quad·텍스트가 이 위에 그려진다.
    if (c->shadow_vertex_buffer != nil) {
        [c->encoder setRenderPipelineState:c->impl.shadowPipeline];
        [c->encoder setVertexBuffer:c->shadow_vertex_buffer offset:0 atIndex:0];
        [c->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:c->shadow_vertex_total];
    }
    if (c->quad_vertex_buffer != nil) MARU_DRAW_QUADS(c->bottom_vertex_count + c->under_vertex_count + c->header_vertex_count, c->quad_vertex_total - c->bottom_vertex_count - c->under_vertex_count - c->header_vertex_count); // 5. over quad(모달 배경)
    // 6. 모달 텍스트(cells_base_v 오프셋) — clip 영역이 있으면 모달 셀만 scissor로 자른다(부분 카드 픽셀 스크롤
    //    인프라). w==0이면 클리핑 없음(기존 동작). 모달 셀이 이 encoder의 마지막 본문 draw다.
    //    ⚠️ 알려진 이슈: 아래 y-flip(cy = dh - (y+h))은 MTLScissorRect를 **좌하단 원점**으로 가정하지만, Metal의
    //    실제 규약은 **좌상단 원점**이다(위 사이드바 scissor 참고). 이 modal_clip 경로는 아직 어떤 컴포넌트도
    //    draw.Op.clip을 emit하지 않는 미사용 인프라(metal_frame.zig "적용 후속")라 이 버그가 런타임에 드러나지
    //    않았다. 부분 픽셀 스크롤을 실제 컴포넌트에 연결할 때 좌상단 원점으로 정정(cy = modal_clip_y_px)하고 함께
    //    검증할 것 — 지금 고치면 검증 경로가 없어 보류한다(4b 분할은 이 경로 동작을 그대로 이관).
    if (c->vertex_buffer != nil && c->has_modal) {
        if (c->modal_clip_w_px > 0) {
            const NSUInteger dw = (NSUInteger)c->drawable_size.width;
            const NSUInteger dh = (NSUInteger)c->drawable_size.height;
            const NSUInteger cx = ((NSUInteger)c->modal_clip_x_px < dw) ? (NSUInteger)c->modal_clip_x_px : 0;
            const NSUInteger cw2 = ((NSUInteger)c->modal_clip_x_px + (NSUInteger)c->modal_clip_w_px <= dw) ? (NSUInteger)c->modal_clip_w_px : (dw - cx);
            const NSUInteger top = (NSUInteger)c->modal_clip_y_px + (NSUInteger)c->modal_clip_h_px;
            const NSUInteger cy = (top <= dh) ? (dh - top) : 0;
            const NSUInteger ch2 = (cy + (NSUInteger)c->modal_clip_h_px <= dh) ? (NSUInteger)c->modal_clip_h_px : (dh - cy);
            [c->encoder setScissorRect:(MTLScissorRect){ .x = cx, .y = cy, .width = cw2, .height = ch2 }];
        }
        // 모달 본문. 모달이 caret을 내면(find·palette) 그 구간을 빼고 앞/뒤로 나눠 그리고, 안 내면(notice·드래그
        // 고스트·drop 하이라이트·포커스 테두리) 오버레이 영역 전체를 한 번에 그린다 — 그 경우 커서는 터미널 레이어에
        // 남아 위 1b+가 페이드한다(v146: 옛 코드는 여기서 커서를 통째로 잃어 blink가 죽었다).
        MARU_DRAW_CELLS(c->cells_base_v + c->modal_cells_start * 12, c->modal_a_len * 12, 1.0f); // 셀당 2 quad — ×12
        if (c->modal_b_len > 0) MARU_DRAW_CELLS(c->cells_base_v + c->modal_b_start * 12, c->modal_b_len * 12, 1.0f);
    }
    // 6+. 오버레이 caret 페이드 pass(모달 열림 — 커서=모달 뒤 suffix). 모달 텍스트 '위'(마지막 draw)에 opacity로 그린다.
    //     modal_clip scissor가 위에서 걸렸으면 그대로 이어져 caret도 같은 영역에 클립된다(모달 셀의 일부라 의도된 동작).
    if (c->vertex_buffer != nil && c->draw_cursor && c->cursor_in_modal)
        MARU_DRAW_CELLS(c->cells_base_v + c->cursor_start * 12, c->cursor_cells * 12, c->cursor_opacity);
}
#undef MARU_DRAW_CELLS
#undef MARU_DRAW_QUADS
#undef MARU_DRAW_IMAGES

bool maru_metal_renderer_draw(
    MaruMetalRenderer *renderer,
    CAMetalLayer *terminal_layer,
    CAMetalLayer *overlay_layer,
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
    /* C4b 모달 클리핑(px, 좌상단, w==0=없음). 모달 셀 draw에 setScissorRect로 적용(Metal 좌하단 원점 y 변환). */
    uint32_t modal_clip_x_px,
    uint32_t modal_clip_y_px,
    uint32_t modal_clip_w_px,
    uint32_t modal_clip_h_px,
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
    uint32_t terminal_bg,
    uint32_t titlebar_strip_px,
    uint32_t window_opacity_milli,
    uint32_t sidebar_scroll_offset_px,
    /* pane divider(reserved 30 세로·31 가로)의 device px 두께(config split.divider-thickness → app_session가 pt×scale). seam 중앙정렬·셀 clamp. 0=안 그림. */
    uint32_t divider_thickness_px,
    /* 커서 blink 페이드: 커서 overlay가 차지하는 cells suffix 길이(cells[cell_count-cursor_cells..])와 그 불투명도×1000.
       본문 셀 draw에서 이 suffix를 제외하고, cursor_fade_milli>0이면 별도 pass로 opacity=cursor_fade_milli/1000에 그린다. */
    size_t cursor_cells,
    uint32_t cursor_fade_milli,
    uint32_t overlay_cells_present,
    /* 커서 구간 시작(ABI v146) — 근거는 헤더 주석 단일 출처. */
    size_t cursor_start_in,
    const MaruAppHostGpuGlyph *gpu_glyphs,
    size_t gpu_glyph_count
) {
    if (renderer == NULL || terminal_layer == nil || cols == 0 || rows == 0) {
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
    // NDC에 투영하므로, 창을 키우면 글자가 늘어나는 게 아니라 더 많은 cell이 보인다. 터미널 레이어가
    // authoritative — 오버레이 레이어는 아래에서 이 크기에 맞춘다(두 레이어 NDC 투영 lockstep).
    const CGSize drawable_size = terminal_layer.drawableSize;
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
    // quad 순서: [사이드바 배경 quad][터미널 cells(셀당 2 quad: 배경+전경, 인접)][사이드바 cells(1 quad)]. A(자간
    // 자연폭)로 터미널 셀이 배경+전경 2 quad라 vertex가 셀당 ×2 — 인접 배치라 cell 순서·painter·모달/scissor는 불변,
    // 아래 오프셋만 터미널은 ×12(=2×6)로 잡는다. 사이드바 cells는 1 quad(투명 카드 글리프만 자연폭).
    const size_t quad_count = 2 * cell_count + sidebar_bg_quads + sidebar_cells_n;
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
        //    A(자간 분리)는 셀당 1 quad 유지 — 투명 bg 일반 글자만 그 quad를 자연폭 글리프로 그려 레이아웃 불변.
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
            // 사이드바 헤더 아이콘 확대/정렬. 헤더 frame은 origin(0,0)에 박힌다(setCellsPaneOrigin 0,0)라 origin_x==0 &&
            // origin_y==0이 헤더 cell이다. 터미널/pane은 상단 타이틀바 띠로 origin_y≥띠>0(메인 창)이라 안 걸리고, 펼침이면
            // 터미널 origin_x>0이라 더 확실하다. 그래서 펼침·접힘(터미널 origin_x=0이어도 origin_y>0) 모두 헤더만 잡는다.
            //   헤더 아이콘(◧·⚙·+·🔔·🔍)은 모두 PUA SVG 합성 아이콘(renderer/icon_glyph.zig, Plane 15 PUA 0xF0000~).
            //   줄0 아이콘(◧⚙+🔔)은 셀×1.7 목표 px로 atlas에 직접 래스터(app_session collectShaped가 raster_*_px 주입)돼
            //   1.7× quad에 1:1로 들어가 선명하다 — 셀 크기로 굽고 GPU에서 확대하던 옛 slot-stretch(anti-alias 번짐)는 폐기.
            //   줄0이 창 top에 붙어 위로 쏠리므로 신호등 수직 중앙에 맞춰 py_nudge=ch×0.30만큼 내린다. 🔍(검색)은 검색
            //   텍스트와 같은 크기라 확대 안 함. row 0으로 한정해 검색 줄(row≥1)의 아이콘을 오확대하지 않는다.
            const bool is_header = (tc.origin_x == 0u && tc.origin_y == 0u);
            // 파일 도크 토글은 자유 배치 pane frame이라 왼쪽 헤더처럼 origin=(0,0)이 아니다. Zig의
            // explicit PaneFrame role이 NativeMetalCell.reserved=32로 lower되므로 codepoint·좌표를 보고
            // 역할을 재추론하지 않는다. 일반 pane이 같은 PUA를 출력해도 확대되지 않는다.
            const MaruMetalCellGlyphPolicy glyph_policy = maru_metal_cell_glyph_policy(
                tc.reserved, tc.atlas_width_px, tc.atlas_height_px, cell_width_px, cell_height_px);
            const bool is_dock_toggle = glyph_policy.is_dock_toggle != 0u;
            const bool is_corner_icon = tc.row == 0u &&
                ((is_header && (tc.codepoint == 0xF0002u || tc.codepoint == 0xF0003u || tc.codepoint == 0xF0006u)) ||
                 is_dock_toggle); // gear·plus·sidebar(PUA icon_glyph), including the freely placed dock toggle
            // 알림 종(🔔)도 PUA 단색 합성 아이콘(0xF0005)이라 코너 아이콘(◧⚙+)과 같은 1.7×로 통일한다. 예전엔 컬러
            // 이모지(width=2, fallback)라 1.7×면 과대해 1.0×로 두고 maru_center_ink_vertically로 보이는 ink를 슬롯 중앙에
            // 맞췄으나(폰트/DPI마다 틀어지는 근사), 단색 합성은 fillCoverage가 슬롯 중앙에 직접 그려 그 보정이 불필요하다.
            const bool is_bell_icon = is_header && tc.row == 0u && tc.codepoint == 0xF0005u; // bell(PUA icon_glyph) — 단색 합성이라 코너 아이콘과 같은 1.7×로 통일
            // 접힘(terminal_origin_x_px==0, 사이드바 폭 0)이면 헤더 줄0 글리프(◧ 펼치기 토글 + 알림 종 🔔 + 배지)가
            // 신호등 옆에 단독으로 떠 신호등과 수직 정렬돼야 한다 — 셋을 모두 타이틀바 띠 [0, titlebar_strip_px] 안에 세로
            // 중앙 배치한다(띠는 max(cell_h, 30pt)라 0.3ch nudge로는 위로 쏠렸다). 예전엔 ◧만 정렬했으나 접힘에도 알림 종을
            // 유지하면서 종/배지도 같은 정렬이 필요해 헤더 줄0 전체로 일반화(사용자 피드백). 펼침 헤더(◧/⚙/+/종)는
            // origin_x>0이라 신호등과 안 겹쳐 아래 py_nudge 경로(무영향).
            const bool is_collapsed_header = is_header && tc.row == 0u && terminal_origin_x_px == 0u;
            const float glyph_scale_x = is_dock_toggle ? glyph_policy.scale_x : ((is_corner_icon || is_bell_icon) ? 1.7f : 1.0f);
            const float glyph_scale_y = is_dock_toggle ? glyph_policy.scale_y : ((is_corner_icon || is_bell_icon) ? 1.7f : 1.0f);
            float py_top;
            if (is_collapsed_header && titlebar_strip_px > 0u) {
                const float strip = (float)titlebar_strip_px;
                py_top = (strip > ch) ? (strip - ch) * 0.5f : 0.0f; // 띠 안 세로 중앙(신호등 정렬)
            } else {
                // 헤더 줄0 아이콘(◧⚙+🔔)은 창 top에 붙어 위로 쏠리므로 같은 0.30ch만큼 아래로 내려 신호등/타이틀바
                // 수직 중앙에 맞춘다. PUA 합성이라 모두 슬롯 중앙에 그려져 글리프별 보정 없이 같은 nudge로 정렬된다.
                const float py_nudge = ((is_corner_icon || is_bell_icon) && !is_dock_toggle) ? ch * 0.30f : 0.0f;
                py_top = (float)tc.origin_y + (float)tc.row * ch + py_nudge;
            }
            // PUA 합성 아이콘은 fillCoverage가 슬롯(EAW width 폭) 중앙에 그리므로, 이모지 시절 종(width 2)의 슬롯 중심이
            // 셀 경계에 떨어져 1칸 아이콘과 반칸 어긋나 px_nudge(-0.5칸)로 보정하던 것이 불필요하다 — 합성 아이콘 중심이
            // 곧 슬롯 중심이라 어느 width·col이든 정합한다(검색이 width 2여도 보정 0).
            // A(자간 자연폭): 셀당 **2 quad**(인접: 배경 quad + 전경 quad)로 그린다. 같은 cell 인덱스에 인접 배치하므로
            // **cell 순서가 보존**돼(장식 셀=글리프 셀보다 뒤=위, 커서 셀의 불투명 배경이 원래 글자를 덮음) 모달/scissor/
            // 이미지 z·페인터 순서가 불변이다 — draw-pass 구조는 그대로 두고 셀당 vertex만 ×2(오프셋 ×12). **모든 글리프
            // (불투명 bg 포함)를 자연폭**으로 그려, 선택영역·SGR48 색배경·블록 커서 밑 글자의 자간 왜곡/breathing이 사라진다
            // (배경은 별도 배경 quad가 셀폭으로 그림). box-drawing은 glyph_id==0로 slot=셀폭이라 자연폭=셀폭으로 타일링 보존.
            MaruRendererVertex *bg_p = &vertices[(quad_index + i * 2) * vertices_per_cell];
            MaruRendererVertex *fg_p = &vertices[(quad_index + i * 2 + 1) * vertices_per_cell];
            if (tc.reserved != 0u && !is_dock_toggle) {
                // reserved 부분-사각형 셀(커서 bar/underline·hollow 변·SGR 장식선·OSC 거터·pane divider/테두리): 색을
                // background에 담은 sentinel(uv<0) 셀이라 글리프가 없다. A(자간 자연폭)의 2-quad 분리는 **글리프 셀 전용** —
                // 여기서 배경 quad가 reserved를 무시하면(옛 bgc.reserved=0) strip이 셀 전체로 번져 divider·커서 바·밑줄이
                // 셀폭 블록으로 굵어진다(c351a19 회귀). 그래서 reserved 셀은 셀당 **1 quad**로 그 reserved strip만 bg_p에
                // 그리고 fg_p는 비운다 — painter 순서·오프셋(셀당 ×2)은 불변. reserved!=0 셀은 hscale==1(확대는 아이콘=reserved 0뿐).
                maru_fill_cell_quad(bg_p, tc, (float)tc.origin_x, cw, py_top, ch, drawable_w, drawable_h, 1.0f, 1.0f, divider_thickness_px);
                memset(fg_p, 0, sizeof(MaruRendererVertex) * vertices_per_cell);
            } else {
                // 배경 quad: 셀 전체 배경색, UV=-1(글리프 안 샘플 → 셰이더가 배경만). 투명 bg면 no-op.
                // semantic role은 여기서 이미 소비했다. generic quad helper는 reserved=2..31 부분
                // 사각형만 이해하므로 dock-toggle glyph는 normal full-cell 입력으로 정규화한다.
                MaruAppHostMetalCell bgc = tc;
                if (is_dock_toggle) bgc.reserved = 0u;
                bgc.u0 = -1.0f;
                bgc.u1 = -1.0f;
                maru_fill_cell_quad(bg_p, bgc, (float)tc.origin_x, cw, py_top, ch, drawable_w, drawable_h, 1.0f, 1.0f, divider_thickness_px);
                // 전경 quad(투명 bg — 배경은 위 배경 quad가 담당).
                if (tc.u0 >= 0.0f && glyph_scale_x == 1.0f && glyph_scale_y == 1.0f) {
                    // 일반 텍스트 글리프 → 자연폭(atlas_width_px, 좌측정렬). 셀 좌단 = panel origin + col×cw.
                    const uint32_t span_u = (tc.width == 0u) ? 1u : tc.width;
                    const float gw = (tc.atlas_width_px > 0u) ? (float)tc.atlas_width_px : cw * (float)span_u;
                    maru_fill_glyph_quad(fg_p, tc, (float)tc.origin_x + (float)tc.col * cw, gw, py_top, ch, drawable_w, drawable_h);
                } else if (tc.u0 < 0.0f) {
                    memset(fg_p, 0, sizeof(MaruRendererVertex) * vertices_per_cell); // 빈 셀 — 전경 없음(배경 quad만)
                } else if (is_bell_icon) {
                    // 종(🔔)은 width 2 stretch를 피해 1칸 quad(코너 아이콘 동형)·origin +0.5cw로 2칸 중앙. 전경만(투명 bg).
                    MaruAppHostMetalCell bell = tc;
                    bell.width = 1;
                    bell.background = 0u;
                    maru_fill_cell_quad(fg_p, bell, (float)tc.origin_x + cw * 0.5f, cw, py_top, ch, drawable_w, drawable_h, glyph_scale_x, glyph_scale_y, divider_thickness_px);
                } else {
                    // 헤더 아이콘(◧⚙+ hscale=1.7 glyph): 그 글리프를 전경으로(투명 bg).
                    MaruAppHostMetalCell fgc = tc;
                    if (is_dock_toggle) fgc.reserved = 0u;
                    fgc.background = 0u;
                    maru_fill_cell_quad(fg_p, fgc, (float)tc.origin_x, cw, py_top, ch, drawable_w, drawable_h, glyph_scale_x, glyph_scale_y, divider_thickness_px);
                }
            }
        }
        quad_index += 2 * cell_count;
        // 3) 사이드바 cells — origin 0, 배경 quad 위에 그린다(painter 순서). 탭 슬롯 높이로 배치하되 셀 종류를
        //    slot_id로 구분한다: 밴드(slot_id==0, sentinel UV)는 row=slot(=표시 row 인덱스)으로 슬롯 전체를 채운다
        //    (py=row×slot_h, 높이 slot_h). 카드 glyph(slot_id≠0)는 **세로 위치를 Zig가 origin_y에 실어 준다**
        //    (app_session.applySidebarGlyphPyTop: rowTop 기반 content-상대 py = Σ앞선 row 높이 + 블록중앙 + 줄오프셋).
        //    옛 균일 인코딩(row=slot*32… → slot×slot_h + 블록중앙)은 그룹 헤더가 slot보다 낮아 카드가 위로 어긋나
        //    폐기했다(SG3b-2-ii, code-review #1·#5·#6). 여기선 origin_y에 헤더 시프트·스크롤만 더한다. 좌측 여백 cw×0.5.
        const float slot_h = (sidebar_slot_height_px > 0u) ? (float)sidebar_slot_height_px : ch;
        // 상단 헤더(검색바·아이콘)만큼 셀을 아래로 밀고, 사이드바 세로 스크롤만큼 위로 당긴다(카드가 헤더 아래 뷰포트를
        // 넘으면 스크롤). 헤더 glyph는 터미널 셀 패스(origin 0,0)라 여기 안 걸려 고정된다. scroll>0이면 아래 scissor가
        // 헤더 위로 샌 카드를 자른다(밴드/glyph 둘 다 이 패스라 함께 클립).
        const float sidebar_header_px = (float)sidebar_header_height_px;
        const float sidebar_scroll = (float)sidebar_scroll_offset_px;
        const float glyph_pad = cw * 0.5f; // 제목 텍스트 좌측 여백(폰트 크기에 비례)
        for (size_t i = 0; i < sidebar_cells_n; i++) {
            const MaruAppHostMetalCell sc = sidebar_cells[i];
            float py_top, cell_h, sx_origin;
            if (sc.slot_id == 0u) { // 밴드/배경 — 세로 위치(origin_y)·높이(atlas_height_px)를 Zig가 실어 준다(가변 높이 #7·#8)
                // 옛 균일 기하(row*slot_h·높이 slot_h)를 폐기: 그룹 헤더(header_row_h<slot_h)가 앞서면 밴드가 slot_h
                // 격자로 어긋났다(code-review #7). 이제 lowerSidebar가 chrome content-상대 rowTop을 origin_y로, 실제 row
                // 높이를 atlas_height_px로 실어 준다(glyph 옵션2와 동형). 여기선 헤더 시프트·스크롤만 더한다 — 밴드/glyph
                // 단일 스크롤 소스. past-end(리스트 아래 새 워크스페이스 드롭 행)도 origin_y=contentHeight로 정상 방출(#8).
                py_top = (float)sc.origin_y + sidebar_header_px - sidebar_scroll;
                cell_h = (sc.atlas_height_px > 0u) ? (float)sc.atlas_height_px : slot_h;
                sx_origin = 0.0f;
            } else { // 카드 glyph — 세로 위치(블록중앙 포함 content-상대 py)는 Zig가 origin_y에 실어 준다(가변 높이, SG3b-2-ii)
                // 옛 균일 기하(slot_idx*slot_h + 블록중앙)를 폐기: 그룹 헤더(header_row_h<slot_h)가 앞서면 카드가 헤더
                // 높이만큼 위로 어긋났다(code-review #1·#5·#6). 이제 applySidebarGlyphPyTop이 rowTop 기반 py를 origin_y에
                // 넣고(헤더·스크롤 제외 content 상대), 여기선 헤더 시프트·세로 스크롤만 더한다 — 밴드와 같은 단일 스크롤 소스.
                py_top = (float)sc.origin_y + sidebar_header_px - sidebar_scroll;
                cell_h = ch;
                sx_origin = glyph_pad;
            }
            // 에이전트 심볼(✶→sparkle 0xF0007 / ◆→diamond 0xF0008, PUA SVG 합성 아이콘)은 width=2(2칸 slot)로 또렷이
            // 그려지므로 stretch는 보조만(1.1×). **gutter col 0 아이콘만** 확대한다 — col 가드가 없으면 워크스페이스
            // 이름/경로 텍스트에 같은 글리프가 들어가도 그 텍스트 셀(slot_id≠0·동일 codepoint)까지 1.1×로 안 늘어난다
            // (app_session.zig 색칠 루프의 col 0 가드와 짝). 색은 agent 브랜드색(claude 코랄·codex 청록)을 foreground로.
            const float gscale = (sc.slot_id != 0u && sc.col == 0u && (sc.codepoint == 0xF0007u || sc.codepoint == 0xF0008u)) ? 1.1f : 1.0f;
            // A(자간 분리): 사이드바 카드 글리프(slot_id≠0)도 투명 bg·확대 없는 일반 글자면 자연폭으로 — 터미널과 동일
            // 이유(자간 squish 제거). 밴드(slot_id==0, sentinel UV)·에이전트 심볼(gscale 1.1)·불투명 bg는 combined 유지.
            MaruRendererVertex *sp = &vertices[(quad_index + i) * vertices_per_cell];
            const bool sc_natural = (sc.slot_id != 0u && sc.u0 >= 0.0f && gscale == 1.0f && ((sc.background >> 24) & 0xffu) == 0u);
            if (sc_natural) {
                const uint32_t sspan = (sc.width == 0u) ? 1u : sc.width;
                const float sgw = (sc.atlas_width_px > 0u) ? (float)sc.atlas_width_px : cw * (float)sspan;
                maru_fill_glyph_quad(sp, sc, sx_origin + (float)sc.col * cw, sgw, py_top, cell_h, drawable_w, drawable_h);
            } else {
                maru_fill_cell_quad(sp, sc, sx_origin, cw, py_top, cell_h, drawable_w, drawable_h, gscale, gscale, divider_thickness_px);
            }
        }
    }

    // C4b: chrome rich quad 정점 버퍼(gpu_quads) — 셀 패스 아래(배경 레이어)에 별개 파이프라인으로 그린다.
    // NULL/0(tui 테마)이면 생성 안 함. modal(팝업) 위 레이어 분리는 C4b-3에서.
    id<MTLBuffer> quad_vertex_buffer = nil;
    size_t quad_vertex_total = 0;
    size_t bottom_quad_n = 0; // C4b-5: layer 2(bottom — 탭 밴드) quad 수. part1(터미널·탭 제목) '앞'에 그려 제목 아래로.
    size_t under_quad_n = 0; // C4b 모달: layer 0(under — 사이드바 밴드) quad 수. draw가 under/over를 가르는 경계.
    size_t header_quad_n = 0; // layer 4(header — 사이드바 bg strip 뒤·헤더 글리프 앞) quad 수. 알림 종 배지(빨강 원) 등.
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
        // C4b: layer로 z를 가른다 — 2(bottom 탭 밴드, part1 앞)·0(under 사이드바, part1 뒤·part2 앞)·4(header — 사이드바
        // bg strip 뒤·헤더 글리프 앞)·1(over 모달, 최상위). 정점 버퍼에 bottom→under→header→over 순서로 배치해 draw가
        // 네 패스로 그린다. layer 4는 헤더 글리프(터미널 셀 패스) '뒤'에 quad를 끼울 유일한 패스다 — 알림 종 배지(빨강
        // 원) 위에 흰 숫자 글리프가 보이게 한다(0/1/3은 셀 패스 '뒤'가 안 돼 글리프를 덮는다 — 헤더 호버 quad 한계와 동형).
        for (size_t i = 0; i < gpu_quad_n; i++) {
            if (gpu_quads[i].layer == 2) bottom_quad_n += 1;
            else if (gpu_quads[i].layer == 0) under_quad_n += 1;
            else if (gpu_quads[i].layer == 4) header_quad_n += 1;
        }
        size_t bi = 0, ui = bottom_quad_n, hi = bottom_quad_n + under_quad_n, oi = bottom_quad_n + under_quad_n + header_quad_n;
        for (size_t i = 0; i < gpu_quad_n; i++) {
            size_t dst;
            if (gpu_quads[i].layer == 2) dst = bi++;
            else if (gpu_quads[i].layer == 0) dst = ui++;
            else if (gpu_quads[i].layer == 4) dst = hi++;
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

    // 스크린샷 하니스: MARU_SCREENSHOT가 설정되면 drawable(framebufferOnly=true라 읽을 수 없다) 대신
    // 같은 크기·픽셀포맷의 오프스크린 텍스처에 두 pass(터미널 Clear → 오버레이 Load)를 합성해 그린다 —
    // 두 물리 레이어가 CoreAnimation으로 합성되는 최종 픽셀을 한 장으로 캡처(무회귀 실측). 평소(NULL)엔 이
    // 분기가 없는 것과 같다. atlas==nil·cols/rows==0 같은 이른 return은 위에서 걸러지므로 캡처는 "내용이 있는
    // 첫 frame"에서만 일어난다 — MARU_SCREENSHOT_DELAY_MS가 있으면 그 시점부터 N ms 지난 frame에서 찍는다.
    const char *screenshot_path = maru_screenshot_path();
    const bool normal_screenshot_mode = (screenshot_path != NULL) && maru_screenshot_delay_elapsed();
    const bool test_capture_mode = impl.testCapturePath != nil;
    // Keep the NSString strongly held by `impl` for the whole draw. The request is cleared only
    // after the synchronous readback has reached the PPM writer below.
    const char *capture_path = test_capture_mode ? impl.testCapturePath.fileSystemRepresentation : screenshot_path;
    const bool screenshot_mode = normal_screenshot_mode || test_capture_mode;

    // C4b: 레이어 순서 = [사이드바 배경 strip] → [터미널 cells(헤더 glyph 포함)] → quad(둥근 밴드) → [사이드바
    // cells(제목)]. 배경 strip(불투명 bg quad)을 '맨 앞'에 그려야 (a)사이드바 헤더 glyph(origin_x=0, 터미널 셀 패스)가
    // 그 위에 보이고 (b)rich 밴드 quad가 strip 위에 보인다(strip을 셀 패스 전체 뒤에 두면 밴드를 덮어 안 보였다).
    // 그래서 셀 패스를 [배경 strip(1a)] · [터미널(1b)] · [사이드바 제목(4)] 셋으로 쪼개고, 밴드 quad(under)를
    // 터미널 '뒤'·제목 glyph '앞'에 끼운다.
    // A(자간 자연폭): 터미널 셀은 배경+전경 2 quad = 셀당 12 vertex라, 셀 인덱스→vertex는 ×12다. 인접 배치라
    // 한 셀의 두 quad가 연속이므로, 연속 vertex 구간 draw가 [배경,전경]을 cell 순서대로 함께 그린다(패스 분할 불요).
    // 사이드바 cells 시작 = 사이드바 bg quad(6) + 터미널 cells(cc×12). 사이드바는 1 quad/셀이라 그 뒤 sc×6.
    const size_t pre_sidebar_vertices = sidebar_bg_quads * 6 + cell_count * 12;
    // 버퍼 레이아웃은 [사이드바 bg quad][터미널 cells(셀당 2 quad)][사이드바 cells]다(채우기 순서). bg quad가 '맨 앞'
    // 이므로 터미널 cell i의 정점은 cells_base_v + i*12에서 시작한다(0이 아님). 셀 패스 오프셋은 전부 이 base를 더해야
    // 한다 — 안 그러면 모달 분할(terminal_end/modal_cells_start)이 어긋난다.
    const size_t cells_base_v = sidebar_bg_quads * 6;
    const size_t bottom_vertex_count = bottom_quad_n * 6; // C4b-5: 탭 밴드(part1 앞 패스)
    const size_t under_vertex_count = under_quad_n * 6;
    const size_t header_vertex_count = header_quad_n * 6; // 헤더 quad(알림 배지) — bg strip 뒤·헤더 글리프 앞 패스
    // C4b 모달: 오버레이 셀(모달 텍스트 **또는** 탭/pane 드래그 고스트·drop 하이라이트 — web-panel.md §5)이
    // cells[modal_cells_start..cell_count]에 있으면 이 셀들을 오버레이 레이어(WKWebView 위)에 그리고, over quad(모달
    // 배경)를 그 '앞'에 끼운다. index 0도 유효하며 explicit overlay_cells_present가 존재 여부를 구분한다. 이름은
    // modal이지만 실제 게이트는 "오버레이 영역 존재"라 드래그 시각물도 이 경로로 최상위에 뜬다.
    const bool has_modal = (overlay_cells_present != 0 && modal_cells_start <= cell_count);
    // 커서 blink 페이드(v146): 커서 구간은 [cursor_start, cursor_start+cursor_cells)이고 **버퍼 어디에나 올 수 있다**.
    // v95는 "항상 buffer suffix"를 가정했는데, caret 없는 오버레이 셀(포커스 테두리·drop 하이라이트·드래그 고스트)이
    // 커서 뒤에 붙으면 그 가정이 깨진다 — 그때 옛 Zig가 cursor_cells=0으로 접어 커서가 본문과 함께 불투명하게 그려졌고
    // blink가 죽었다. 이제 시작을 명시로 받아 본문을 커서 앞/뒤 두 구간으로 나눠 그린다(fade_milli==0이면 커서 pass 생략).
    const float cursor_opacity = (float)cursor_fade_milli / 1000.0f;
    const bool cursor_valid = (cursor_cells > 0 && cursor_start_in <= cell_count && cursor_start_in + cursor_cells <= cell_count);
    const size_t cursor_start = cursor_valid ? cursor_start_in : cell_count;
    const size_t cursor_end = cursor_valid ? (cursor_start_in + cursor_cells) : cell_count;
    const bool draw_cursor = (cursor_valid && cursor_fade_milli > 0);
    // 터미널 레이어 본문은 모달 시작(모달 있음) 또는 버퍼 끝에서 끝난다. 커서가 그 안에 있으면 두 구간으로 쪼갠다.
    const size_t terminal_end = has_modal ? modal_cells_start : cell_count;
    const bool cursor_in_terminal = cursor_valid && cursor_end <= terminal_end;
    const size_t term_a_len = cursor_in_terminal ? cursor_start : terminal_end;                       // [0, 커서)
    const size_t term_b_start = cursor_in_terminal ? cursor_end : 0;                                  // (커서, 터미널 끝)
    const size_t term_b_len = (cursor_in_terminal && cursor_end < terminal_end) ? (terminal_end - cursor_end) : 0;
    // 모달(오버레이) 레이어 본문도 같은 규칙. 커서가 오버레이 영역에 있으면(모달 caret) 그쪽을 쪼갠다.
    const bool cursor_in_modal = cursor_valid && has_modal && cursor_start >= modal_cells_start;
    const size_t modal_total = (cell_count > modal_cells_start) ? (cell_count - modal_cells_start) : 0;
    const size_t modal_a_len = cursor_in_modal ? (cursor_start - modal_cells_start) : modal_total;    // [모달 시작, 커서)
    const size_t modal_b_start = cursor_in_modal ? cursor_end : 0;                                    // (커서, 버퍼 끝)
    const size_t modal_b_len = (cursor_in_modal && cursor_end < cell_count) ? (cell_count - cursor_end) : 0;
    const size_t terminal_end_v = term_a_len * 12; // 셀당 2 quad(자간 자연폭) — ×12

    // 터미널 레이어 clear color: terminal_bg(0xAARRGGBB — OSC 11 배경 set 또는 theme.background)가 비-0이면 그 색,
    // 0이면 기존 기본(어두운 남색)으로 폴백. 빈 영역/기본 배경(A0) 셀이 비치는 색. window.opacity(배경 투명도)는
    // clear color의 **alpha에만** 곱한다 — default 배경만 투명, 명시적 배경색 셀(bg.a=1)은 셀 quad로 그려져 무영향
    // (iTerm2/Ghostty background-opacity 모델). BGRA8Unorm straight-alpha clear라 rgb는 그대로. milli/1000.
    const double opacity = (double)window_opacity_milli / 1000.0;
    MTLClearColor terminal_clear;
    if (terminal_bg != 0) {
        terminal_clear = MTLClearColorMake(
            (double)((terminal_bg >> 16) & 0xff) / 255.0,
            (double)((terminal_bg >> 8) & 0xff) / 255.0,
            (double)(terminal_bg & 0xff) / 255.0,
            opacity);
    } else {
        terminal_clear = MTLClearColorMake(0.06, 0.08, 0.12, opacity);
    }
    // 오버레이 레이어 clear: 완전 투명(0,0,0,0). 모달이 없는 영역은 아래 터미널(+미래 WKWebView)이 비친다
    // (오버레이 CAMetalLayer는 isOpaque=false). 모달 셀·그림자·over quad·caret만 그 위에 premultiplied-over로 합성.
    const MTLClearColor overlay_clear = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);

    // Phase 4b(b2): 두 논리 레이어 함수(터미널/오버레이)에 각자 CAMetalLayer의 drawable/encoder를 준다. 공통 오프셋·
    // 모달/커서 파라미터는 한 컨텍스트에 모아 두 pass가 나눠 쓰고, encoder만 pass별로 교체한다. drawable_size는
    // 터미널 레이어가 authoritative(위에서 계산)이며, 오버레이 draw도 같은 크기로 NDC 투영해 모달 좌표가 정합한다.
    MaruDrawPass pass_ctx = {
        .encoder = nil, // pass별로 아래에서 설정
        .impl = impl,
        .vertex_buffer = vertex_buffer,
        .quad_vertex_buffer = quad_vertex_buffer,
        .shadow_vertex_buffer = shadow_vertex_buffer,
        .image_vertex_buffer = image_vertex_buffer,
        .gpu_images = gpu_images,
        .drawable_size = drawable_size,
        .bottom_vertex_count = bottom_vertex_count,
        .under_vertex_count = under_vertex_count,
        .header_vertex_count = header_vertex_count,
        .quad_vertex_total = quad_vertex_total,
        .shadow_vertex_total = shadow_vertex_total,
        .image_above_start = image_above_start,
        .gpu_image_n = gpu_image_n,
        .cells_base_v = cells_base_v,
        .pre_sidebar_vertices = pre_sidebar_vertices,
        .total_vertices = total_vertices,
        .terminal_end_v = terminal_end_v,
        .cursor_start = cursor_start,
        .cursor_cells = cursor_cells,
        .cursor_opacity = cursor_opacity,
        .draw_cursor = draw_cursor,
        .term_b_start = term_b_start,
        .term_b_len = term_b_len,
        .modal_a_len = modal_a_len,
        .modal_b_start = modal_b_start,
        .modal_b_len = modal_b_len,
        .cursor_in_terminal = cursor_in_terminal,
        .cursor_in_modal = cursor_in_modal,
        .has_modal = has_modal,
        .modal_cells_start = modal_cells_start,
        .modal_clip_x_px = modal_clip_x_px,
        .modal_clip_y_px = modal_clip_y_px,
        .modal_clip_w_px = modal_clip_w_px,
        .modal_clip_h_px = modal_clip_h_px,
        .sidebar_cells_n = sidebar_cells_n,
        .sidebar_scroll_offset_px = sidebar_scroll_offset_px,
        .sidebar_header_height_px = sidebar_header_height_px,
    };

    if (screenshot_mode) {
        // 2레이어 합성을 한 오프스크린 텍스처에 캡처: 터미널 pass(Clear=terminal_clear) → 오버레이 pass(Load,
        // over-blend)로 CoreAnimation 합성과 같은 최종 픽셀을 만든다(b1 단일 pass와 시각 동일 — 무회귀 실측 근거).
        // Private 스토리지 렌더 타깃 + blit 소스(Intel/Apple Silicon 모두 안전). loadAction=Load는 같은 command
        // buffer 안에서 pass1 결과를 유지하므로 오버레이가 그 위에 정확히 합성된다.
        MTLTextureDescriptor *offscreen_desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:terminal_layer.pixelFormat
                                         width:(NSUInteger)drawable_size.width
                                        height:(NSUInteger)drawable_size.height
                                     mipmapped:NO];
        offscreen_desc.storageMode = MTLStorageModePrivate;
        offscreen_desc.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target_texture = [impl.device newTextureWithDescriptor:offscreen_desc];
        if (target_texture == nil) {
            fprintf(stderr, "MARU_SCREENSHOT: offscreen texture 생성 실패\n");
            exit(1);
        }
        id<MTLCommandBuffer> command_buffer = [impl.queue commandBuffer];
        if (command_buffer == nil) {
            fprintf(stderr, "MARU_SCREENSHOT: command buffer 생성 실패\n");
            exit(1);
        }
        // pass 1: 터미널(Clear)
        MTLRenderPassDescriptor *tpass = [MTLRenderPassDescriptor renderPassDescriptor];
        tpass.colorAttachments[0].texture = target_texture;
        tpass.colorAttachments[0].loadAction = MTLLoadActionClear;
        tpass.colorAttachments[0].storeAction = MTLStoreActionStore;
        tpass.colorAttachments[0].clearColor = terminal_clear;
        id<MTLRenderCommandEncoder> tenc = [command_buffer renderCommandEncoderWithDescriptor:tpass];
        if (tenc == nil) {
            fprintf(stderr, "MARU_SCREENSHOT: 터미널 pass 인코더 생성 실패\n");
            exit(1);
        }
        pass_ctx.encoder = tenc;
        maru_draw_terminal_layer(&pass_ctx);
        maru_draw_rich_glyphs(tenc, impl, gpu_glyphs, gpu_glyph_count, drawable_size);
        [tenc endEncoding];
        // pass 2: 오버레이(Load — 터미널 결과 위에 합성)
        MTLRenderPassDescriptor *opass = [MTLRenderPassDescriptor renderPassDescriptor];
        opass.colorAttachments[0].texture = target_texture;
        opass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        opass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> oenc = [command_buffer renderCommandEncoderWithDescriptor:opass];
        if (oenc == nil) {
            fprintf(stderr, "MARU_SCREENSHOT: 오버레이 pass 인코더 생성 실패\n");
            exit(1);
        }
        pass_ctx.encoder = oenc;
        maru_draw_overlay_layer(&pass_ctx);
        [oenc endEncoding];

        // 오프스크린 텍스처(Private)를 Shared 버퍼로 blit해 CPU에서 읽고 PPM으로 쓴 뒤 프로세스를 끝낸다
        // ("한 frame 캡처 후 종료" — 하니스 계약). 캡처 실패는 retry 없이 즉시 exit(1)로 닫는다.
        const size_t shot_w = (size_t)target_texture.width;
        const size_t shot_h = (size_t)target_texture.height;
        const size_t bytes_per_row = maru_align_up_256(shot_w * 4);
        if (shot_w == 0 || shot_h == 0 || bytes_per_row == 0 ||
            shot_h > SIZE_MAX / bytes_per_row) {
            fprintf(stderr, "MARU_SCREENSHOT: 비정상 텍스처 크기 %zux%zu\n", shot_w, shot_h);
            exit(1);
        }
        const size_t byte_count = bytes_per_row * shot_h;
        id<MTLBuffer> readback = [impl.device newBufferWithLength:byte_count
                                                         options:MTLResourceStorageModeShared];
        if (readback == nil) {
            fprintf(stderr, "MARU_SCREENSHOT: readback 버퍼 생성 실패 (%zu bytes)\n", byte_count);
            exit(1);
        }
        id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
        if (blit == nil) {
            fprintf(stderr, "MARU_SCREENSHOT: blit encoder 생성 실패\n");
            exit(1);
        }
        [blit copyFromTexture:target_texture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(shot_w, shot_h, 1)
                     toBuffer:readback
            destinationOffset:0
       destinationBytesPerRow:bytes_per_row
     destinationBytesPerImage:byte_count];
        [blit endEncoding];
        [command_buffer commit];
        [command_buffer waitUntilCompleted];

        const uint8_t *pixels = (const uint8_t *)readback.contents;
        const BOOL wrote = maru_write_ppm_from_bgra8_buffer(
            capture_path, pixels, shot_w, shot_h, bytes_per_row);
        if (!wrote) {
            fprintf(stderr, "MARU_SCREENSHOT: PPM 쓰기 실패 → %s\n", capture_path);
            exit(1);
        }
        fprintf(stderr, "MARU_SCREENSHOT: %zux%zu PPM 캡처 → %s\n", shot_w, shot_h, capture_path);
        if (test_capture_mode) {
            // The sink has copied this exact completed renderer output. Clear before returning so
            // an idle/cursor redraw cannot overwrite it or keep readback enabled in product mode.
            impl.testCapturePath = nil;
            return true;
        }
        if (maru_screenshot_keeps_process()) {
            // Chrome Lab bridge는 같은 process에서 PPM→PNG·JSON 검증을 끝내야 한다. 이 opt-in은
            // fixture executable만 설정하며, 일반 제품 screenshot의 one-frame-and-exit 계약은 그대로다.
            return true;
        }
        exit(0);
    }

    // 평소(present) 경로: 두 물리 레이어의 drawable을 잡아 각자 그리고, **한 command buffer에 둘 다 present +
    // 단일 commit**한다 → 모달 열림/닫힘 전이 프레임이 원자적으로 표시된다(터미널 caret 제거 + 오버레이 모달·caret이
    // 서로 다른 vsync로 갈라지지 않아 tearing/‌caret 0·2개가 없다). vertex 버퍼는 위에서 이미 다 만들었으므로,
    // drawable 획득 실패가 이미 만든 자원을 낭비할 뿐 잡은 drawable을 새게(starve) 하지 않는다.
    //
    // command buffer를 **drawable 획득 전에** 잡는다: 큐 고갈로 command buffer가 nil이면 아직 drawable을 안 잡았으니
    // 새는 drawable이 없다. 그 뒤 인코더 생성이 실패해도(사실상 없음) 이미 잡은 drawable은 present+commit으로 pool에
    // 되돌려 고갈을 막는다(단순 return이면 미커밋 drawable이 pool을 굶긴다).
    id<MTLCommandBuffer> command_buffer = [impl.queue commandBuffer];
    if (command_buffer == nil) {
        return false; // drawable 미획득 — 누수 없음, 다음 frame 재시도
    }
    id<CAMetalDrawable> terminal_drawable = [terminal_layer nextDrawable];
    if (terminal_drawable == nil) {
        return false; // command buffer는 미커밋 폐기(누수 없음), 다음 frame 재시도
    }

    // 오버레이 present 결정(모달 잔상·이중 present 홀리스틱): 오버레이는 **그릴 내용이 있거나(모달·그림자) 직전
    // present가 content였는데 이번엔 비었을 때(clear 전이)**만 present한다. 빈→빈이면 이미 clear(또는 미present=투명)라
    // 건너뛴다 → 모달 없는 평상시 매 frame 오버레이 이중 present(GPU·컴포지터 낭비)를 없앤다. content→빈 전이 프레임엔
    // clear를 present해 **닫힌 모달의 잔상**을 지운다(그 뒤엔 빈→빈이라 다시 skip). CAMetalLayer는 마지막 present
    // 콘텐츠를 유지하므로, skip 상태에서도 오버레이는 마지막에 present한 (투명) clear 그대로 남는다.
    const bool overlay_has_content = (has_modal || shadow_vertex_total > 0);
    const bool overlay_needs_present = overlay_has_content || impl.overlayHadContent;
    id<CAMetalDrawable> overlay_drawable = nil;
    if (overlay_layer != nil && overlay_needs_present) {
        // 오버레이 drawableSize를 터미널과 lockstep으로 맞춘다(둘이 다르면 모달 NDC 투영이 어긋난다). draw는 main
        // thread(Swift frame timer)에서만 불리므로 CAMetalLayer 속성 접근이 안전하다.
        if (!CGSizeEqualToSize(overlay_layer.drawableSize, drawable_size)) {
            overlay_layer.drawableSize = drawable_size;
        }
        overlay_drawable = [overlay_layer nextDrawable]; // nil이면(드물게 pool starvation) 아래 drop 처리.
    }
    // present가 필요한데(내용 있음 또는 clear 전이) drawable을 못 잡았으면 이 frame은 드롭이다: return false로 신호해
    // 다음 tick이 재시도하게 한다. **정적 모달**(종료/닫기 확인 등 검색 caret이 없어 metal_dirty가 churn 안 하는 모달)은
    // 한 번 드롭되면 재그리기 트리거가 없어 영구 미표시가 되고, **닫힘 clear** 드롭은 모달 잔상이 남는다 — 둘 다
    // drawMetalFrame이 metalNeedsRedraw로 재시도해야 한다(caret은 has_modal 분기로 어느 레이어든 1개라 유실 없음).
    const bool overlay_content_dropped = (overlay_needs_present && overlay_drawable == nil);

    // pass 1: 터미널 레이어(Clear=terminal_clear). vertex_buffer가 nil이면(cell 없음) clear만 한 빈 frame이다.
    MTLRenderPassDescriptor *tpass = [MTLRenderPassDescriptor renderPassDescriptor];
    tpass.colorAttachments[0].texture = terminal_drawable.texture;
    tpass.colorAttachments[0].loadAction = MTLLoadActionClear;
    tpass.colorAttachments[0].storeAction = MTLStoreActionStore;
    tpass.colorAttachments[0].clearColor = terminal_clear;
    id<MTLRenderCommandEncoder> tenc = [command_buffer renderCommandEncoderWithDescriptor:tpass];
    if (tenc == nil) {
        // 인코더 실패(사실상 없음)라도 이미 잡은 drawable(들)은 present+commit으로 pool에 되돌린다(누수 0). 미인코딩
        // drawable은 1 frame stale이 보일 수 있으나 return false로 다음 frame이 재그린다(pool 고갈보다 낫다).
        [command_buffer presentDrawable:terminal_drawable];
        if (overlay_drawable != nil) {
            [command_buffer presentDrawable:overlay_drawable];
        }
        [command_buffer commit];
        return false;
    }
    pass_ctx.encoder = tenc;
    maru_draw_terminal_layer(&pass_ctx); // 맨 아래: 터미널 셀·사이드바·chrome·kitty·(모달 없을 때)터미널 커서
    maru_draw_rich_glyphs(tenc, impl, gpu_glyphs, gpu_glyph_count, drawable_size);
    [tenc endEncoding];

    // pass 2: 오버레이 레이어(Clear=투명). 모달만 그리고 나머지는 투명이라 아래 터미널이 비친다. present 대상이
    // 아니면(overlay_drawable==nil — 빈→빈 skip 또는 drop) 이 pass를 건너뛴다.
    if (overlay_drawable != nil) {
        MTLRenderPassDescriptor *opass = [MTLRenderPassDescriptor renderPassDescriptor];
        opass.colorAttachments[0].texture = overlay_drawable.texture;
        opass.colorAttachments[0].loadAction = MTLLoadActionClear;
        opass.colorAttachments[0].storeAction = MTLStoreActionStore;
        opass.colorAttachments[0].clearColor = overlay_clear;
        id<MTLRenderCommandEncoder> oenc = [command_buffer renderCommandEncoderWithDescriptor:opass];
        if (oenc == nil) {
            // 오버레이 인코더 실패: 터미널은 이미 인코딩됐다. 두 drawable을 present+commit해 pool에 되돌린다(누수 0).
            [command_buffer presentDrawable:terminal_drawable];
            [command_buffer presentDrawable:overlay_drawable];
            [command_buffer commit];
            return false;
        }
        pass_ctx.encoder = oenc;
        maru_draw_overlay_layer(&pass_ctx); // 맨 위: 그림자·모달 배경·모달 텍스트·(모달 열림)오버레이 caret
        [oenc endEncoding];
    }

    // 두 drawable을 같은 command buffer에 present → 단일 commit으로 원자 표시(전이 tearing 방지, caret 항상 1개).
    [command_buffer presentDrawable:terminal_drawable];
    if (overlay_drawable != nil) {
        [command_buffer presentDrawable:overlay_drawable];
        // 이번에 오버레이 레이어에 실제 present한 내용이 content였는지 기록(다음 frame의 present 결정용). clear 전이를
        // present한 경우 overlay_has_content=false라 다음부터 빈→빈 skip으로 넘어간다. drop(present 안 함)이면 갱신하지
        // 않아, 재시도 프레임이 여전히 present 필요로 판단한다.
        impl.overlayHadContent = overlay_has_content;
    }
    [command_buffer commit];
    return !overlay_content_dropped; // 내용/clear 전이가 drawable 부족으로 드롭됐으면 재시도(위 주석).
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
