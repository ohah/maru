#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
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
    uint32_t atlas_texture_created;
    uint32_t atlas_uploads_requested;
    uint32_t atlas_uploads_uploaded;
    uint32_t atlas_upload_bytes;
    uint32_t atlas_readback_uploads;
    uint32_t atlas_readback_mismatched_bytes;
    uint32_t atlas_readback_failures;
    uint32_t atlas_sampled_cells;
    uint32_t atlas_sample_missing_cells;
    uint32_t screenshot_written;
    uint32_t screenshot_width;
    uint32_t screenshot_height;
    uint32_t screenshot_bytes;
    uint32_t screenshot_failures;
} MaruMetalSmokeResult;

typedef struct {
    int32_t status;
    uint32_t window_visible;
    uint32_t key_down_received;
    uint32_t codepoint;
    uint32_t modifier_shift;
    uint32_t modifier_control;
    uint32_t modifier_option;
    uint32_t modifier_command;
} MaruKeyDownSmokeResult;

typedef struct {
    uint16_t row;
    uint16_t col;
    uint16_t width;
    uint16_t reserved;
    uint32_t codepoint;
    uint32_t slot_id;
    uint32_t atlas_x_px;
    uint32_t atlas_y_px;
    uint32_t atlas_width_px;
    uint32_t atlas_height_px;
    float u0;
    float v0;
    float u1;
    float v1;
} MaruMetalSmokeCell;

typedef struct {
    uint32_t slot_id;
    uint32_t atlas_x_px;
    uint32_t atlas_y_px;
    uint32_t atlas_width_px;
    uint32_t atlas_height_px;
    size_t bytes_offset;
    size_t byte_count;
    size_t bytes_per_row;
    size_t non_clear_pixels;
} MaruMetalRasterUpload;

typedef struct {
    float x;
    float y;
    float u;
    float v;
} MaruMetalSmokeVertex;

typedef struct {
    NSUInteger x;
    NSUInteger y;
    uint8_t expected_b;
    uint8_t expected_g;
    uint8_t expected_r;
    uint8_t expected_a;
} MaruMetalSmokeSample;

typedef struct {
    double rel_x;
    double rel_y;
    uint8_t expected_b;
    uint8_t expected_g;
    uint8_t expected_r;
    uint8_t expected_a;
} MaruMetalSourceSample;

static const NSUInteger maru_readback_stride = 256;

// VertexIn은 host쪽 MaruMetalSmokeVertex(float 4개, 16바이트, tight-packed)와 같은
// 메모리 레이아웃을 가져야 한다. packed_float2 두 개를 쓰면 MSL과 C struct stride가
// 같아져 shader가 UV를 잘못 읽는 숨은 회귀를 피할 수 있다.
static NSString *const maru_cell_shader_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VertexIn { packed_float2 position; packed_float2 uv; };\n"
     "struct VertexOut { float4 position [[position]]; float2 uv; };\n"
     "vertex VertexOut maru_cell_vertex(uint vid [[vertex_id]], const device VertexIn *vertices [[buffer(0)]]) {\n"
     "  VertexOut out;\n"
     "  out.position = float4(float2(vertices[vid].position), 0.0, 1.0);\n"
     "  out.uv = float2(vertices[vid].uv);\n"
     "  return out;\n"
     "}\n"
     "fragment float4 maru_cell_fragment(VertexOut in [[stage_in]], texture2d<float> atlas_texture [[texture(0)]]) {\n"
     "  constexpr sampler atlas_sampler(coord::normalized, address::clamp_to_edge, filter::nearest);\n"
     "  return atlas_texture.sample(atlas_sampler, in.uv);\n"
     "}\n";

@interface MaruKeyCaptureView : NSView {
@public
    MaruKeyDownSmokeResult *_result;
}
- (instancetype)initWithFrame:(NSRect)frame result:(MaruKeyDownSmokeResult *)result;
@end

@implementation MaruKeyCaptureView

- (instancetype)initWithFrame:(NSRect)frame result:(MaruKeyDownSmokeResult *)result {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _result = result;
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    if (_result == NULL) {
        return;
    }

    _result->key_down_received = 1;
    NSEventModifierFlags flags = [event modifierFlags];
    _result->modifier_shift = (flags & NSEventModifierFlagShift) ? 1 : 0;
    _result->modifier_control = (flags & NSEventModifierFlagControl) ? 1 : 0;
    _result->modifier_option = (flags & NSEventModifierFlagOption) ? 1 : 0;
    _result->modifier_command = (flags & NSEventModifierFlagCommand) ? 1 : 0;

    NSString *characters = [event charactersIgnoringModifiers];
    if ([characters length] > 0) {
        // 이번 smoke는 Cmd+B처럼 단일 BMP 문자를 검증한다. IME, dead key, surrogate
        // pair는 제품 key bridge 단계에서 별도 계약으로 다룬다.
        _result->codepoint = (uint32_t)[characters characterAtIndex:0];
    }
}

@end

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

static void maru_run_keydown_smoke(
    uint32_t duration_ms,
    BOOL post_synthetic_event,
    NSString *title,
    MaruKeyDownSmokeResult *result
) {
    result->status = -1;
    result->window_visible = 0;
    result->key_down_received = 0;
    result->codepoint = 0;
    result->modifier_shift = 0;
    result->modifier_control = 0;
    result->modifier_option = 0;
    result->modifier_command = 0;

    @autoreleasepool {
        // 이 helper는 synthetic smoke와 manual smoke가 같은 first-responder/keyDown
        // 경계를 쓰도록 한다. 둘을 분리 구현하면 자동 smoke와 사람이 누르는 smoke가
        // 서로 다른 AppKit setup을 검증하는 오탐이 생긴다.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];

        if ([[NSScreen screens] count] == 0) {
            result->status = 2;
            return;
        }

        NSRect frame = NSMakeRect(180.0, 180.0, 320.0, 120.0);
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        if (window == nil) {
            result->status = 1;
            return;
        }

        MaruKeyCaptureView *view = [[MaruKeyCaptureView alloc] initWithFrame:frame result:result];
        if (view == nil) {
            result->status = 3;
            return;
        }

        [window setTitle:title];
        [window setReleasedWhenClosed:NO];
        [window setContentView:view];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        if (![window makeFirstResponder:view]) {
            result->status = 4;
            [window orderOut:nil];
            return;
        }

        result->window_visible = [window isVisible] ? 1 : 0;
        if (post_synthetic_event) {
            NSEvent *event = [NSEvent
                keyEventWithType:NSEventTypeKeyDown
                        location:NSMakePoint(8.0, 8.0)
                   modifierFlags:NSEventModifierFlagCommand
                       timestamp:0.0
                    windowNumber:[window windowNumber]
                         context:nil
                      characters:@"b"
     charactersIgnoringModifiers:@"b"
                       isARepeat:NO
                         keyCode:11];
            if (event == nil) {
                result->status = 5;
                [window orderOut:nil];
                return;
            }
            [NSApp postEvent:event atStart:NO];
        }

        NSTimeInterval seconds = ((NSTimeInterval)duration_ms) / 1000.0;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
        do {
            @autoreleasepool {
                maru_pump_app_once();
            }
        } while (result->key_down_received == 0 &&
                 [[NSDate date] compare:deadline] == NSOrderedAscending);

        const BOOL visible = [window isVisible];
        result->window_visible = visible ? 1 : 0;
        [window orderOut:nil];

        if (!visible) {
            result->status = 6;
            return;
        }
        if (result->key_down_received == 0 || result->codepoint == 0) {
            result->status = 7;
            return;
        }
        result->status = 0;
    }
}

void maru_macos_keydown_smoke_run(uint32_t duration_ms, MaruKeyDownSmokeResult *result) {
    // 자동 smoke는 물리 키보드가 없는 CI/원격 실행에서도 keyDown delivery 계약을
    // 검증해야 하므로 AppKit event queue에 Cmd+B를 직접 넣는다.
    maru_run_keydown_smoke(
        duration_ms,
        YES,
        @"Maru synthetic keyDown smoke",
        result
    );
}

void maru_macos_manual_keydown_smoke_run(uint32_t duration_ms, MaruKeyDownSmokeResult *result) {
    // manual smoke는 사용자가 실제로 누른 키를 기다린다. 제품 interactive loop는
    // 아직 아니지만, 물리 키보드 -> AppKit keyDown -> Zig payload 경계를 확인할 수 있다.
    maru_run_keydown_smoke(
        duration_ms,
        NO,
        @"Maru manual keyDown smoke - press Cmd+B",
        result
    );
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

static BOOL maru_rgba_source_pixel_has_ink(const uint8_t *pixel) {
    // atlas source buffer의 clear 값은 0이다. 실제 glyph rasterizer가 붙으면 중심 픽셀이
    // 비어 있을 수 있으므로, 특정 위치를 가정하지 않고 source tile 안의 잉크 픽셀을 고른다.
    return pixel[0] != 0 || pixel[1] != 0 || pixel[2] != 0 || pixel[3] != 0;
}

static BOOL maru_upload_source_range_is_valid(
    MaruMetalRasterUpload upload,
    size_t raster_pixel_count
) {
    if (upload.atlas_width_px == 0 || upload.atlas_height_px == 0) {
        return NO;
    }
    if (upload.bytes_per_row != (size_t)upload.atlas_width_px * 4) {
        return NO;
    }
    if (upload.bytes_per_row > SIZE_MAX / (size_t)upload.atlas_height_px) {
        return NO;
    }
    if (upload.byte_count != upload.bytes_per_row * (size_t)upload.atlas_height_px) {
        return NO;
    }
    if (upload.bytes_offset > raster_pixel_count ||
        upload.byte_count > raster_pixel_count - upload.bytes_offset)
    {
        return NO;
    }
    return YES;
}

static BOOL maru_find_source_ink_sample(
    MaruMetalRasterUpload upload,
    const uint8_t *raster_pixels,
    size_t raster_pixel_count,
    MaruMetalSourceSample *sample
) {
    if (raster_pixels == NULL || sample == NULL ||
        !maru_upload_source_range_is_valid(upload, raster_pixel_count))
    {
        return NO;
    }

    BOOL found = NO;
    size_t best_x = 0;
    size_t best_y = 0;
    double best_score = 0.0;
    const size_t width = (size_t)upload.atlas_width_px;
    const size_t height = (size_t)upload.atlas_height_px;
    const double center_x = ((double)width - 1.0) * 0.5;
    const double center_y = ((double)height - 1.0) * 0.5;

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            const size_t offset = upload.bytes_offset + y * upload.bytes_per_row + x * 4;
            if (offset + 3 >= raster_pixel_count) {
                continue;
            }
            const uint8_t *pixel = raster_pixels + offset;
            if (!maru_rgba_source_pixel_has_ink(pixel)) {
                continue;
            }

            // edge texel보다 중심에 가까운 잉크 texel을 고르면, 실제 glyph가 얇거나
            // punctuation처럼 작은 경우에도 quad 경계 rasterization 오차를 덜 탄다.
            const double dx = (double)x - center_x;
            const double dy = (double)y - center_y;
            const double score = dx * dx + dy * dy;
            if (!found || score < best_score) {
                found = YES;
                best_x = x;
                best_y = y;
                best_score = score;
            }
        }
    }
    if (!found) {
        return NO;
    }

    const size_t offset = upload.bytes_offset + best_y * upload.bytes_per_row + best_x * 4;
    sample->rel_x = ((double)best_x + 0.5) / (double)width;
    sample->rel_y = ((double)best_y + 0.5) / (double)height;
    sample->expected_b = raster_pixels[offset + 2];
    sample->expected_g = raster_pixels[offset + 1];
    sample->expected_r = raster_pixels[offset + 0];
    sample->expected_a = raster_pixels[offset + 3];
    return YES;
}

static MaruMetalSmokeSample *maru_build_cell_samples(
    const MaruMetalSmokeCell *cells,
    size_t cell_count,
    uint16_t cols,
    uint16_t rows,
    NSUInteger texture_width,
    NSUInteger texture_height,
    const MaruMetalRasterUpload *uploads,
    size_t upload_count,
    const uint8_t *raster_pixels,
    size_t raster_pixel_count,
    size_t *sample_count,
    size_t *missing_count
) {
    *sample_count = 0;
    *missing_count = 0;
    if (cells == NULL || cell_count == 0 || cols == 0 || rows == 0 ||
        texture_width == 0 || texture_height == 0)
    {
        return NULL;
    }
    if (upload_count > 0 &&
        (uploads == NULL || raster_pixels == NULL || raster_pixel_count == 0))
    {
        return NULL;
    }

    // smoke는 전체 화면 readback이 아니라 대표 잉크 픽셀만 읽는다. fixture가 커져도
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

    size_t written = 0;
    for (size_t i = 0; i < count; i++) {
        const MaruMetalSmokeCell cell = cells[i];
        const double cell_width = (double)(cell.width == 0 ? 1 : cell.width);
        const double left = grid_left + ((double)cell.col / (double)cols) * grid_width;
        const double right = grid_left + (((double)cell.col + cell_width) / (double)cols) * grid_width;
        const double top = grid_top - ((double)cell.row / (double)rows) * grid_height;
        const double bottom = grid_top - (((double)cell.row + 1.0) / (double)rows) * grid_height;

        MaruMetalSourceSample source_sample = {0};
        BOOL found_source_sample = NO;
        // upload가 0개인 frame은 all-skip 또는 warm atlas 같은 renderer 상태일 수 있다.
        // 이 경우는 Metal readback 인프라 실패가 아니라 visible cell에 대응하는 source
        // sample이 없다는 도메인 신호이므로 missing_count로 따로 회계한다.
        for (size_t upload_index = 0; upload_index < upload_count; upload_index++) {
            const MaruMetalRasterUpload upload = uploads[upload_index];
            if (upload.slot_id != cell.slot_id) {
                continue;
            }
            if (maru_find_source_ink_sample(
                    upload,
                    raster_pixels,
                    raster_pixel_count,
                    &source_sample))
            {
                found_source_sample = YES;
                break;
            }
        }
        if (!found_source_sample) {
            *missing_count += 1;
            continue;
        }

        const double sample_x = left + (right - left) * source_sample.rel_x;
        const double sample_y = top + (bottom - top) * source_sample.rel_y;
        samples[written].x = maru_clamp_pixel(((sample_x + 1.0) * 0.5) * (double)texture_width, texture_width);
        samples[written].y = maru_clamp_pixel(((1.0 - sample_y) * 0.5) * (double)texture_height, texture_height);
        samples[written].expected_b = source_sample.expected_b;
        samples[written].expected_g = source_sample.expected_g;
        samples[written].expected_r = source_sample.expected_r;
        samples[written].expected_a = source_sample.expected_a;
        written += 1;
    }

    *sample_count = written;
    return samples;
}

static BOOL maru_pixel_is_non_clear(const uint8_t *pixel) {
    // BGRA8Unorm clear color는 MTLClearColorMake(0.06, 0.08, 0.12, 1.0)이다.
    // GPU의 float->unorm 반올림 차이를 감안해 작은 허용 오차를 둔다. 실제 atlas
    // sampling 여부는 이 함수가 아니라 expected atlas texel 비교가 판단한다.
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

static BOOL maru_pixel_matches_expected_atlas_sample(
    const uint8_t *pixel,
    MaruMetalSmokeSample sample
) {
    const int tolerance = 2;
    return abs((int)pixel[0] - (int)sample.expected_b) <= tolerance &&
        abs((int)pixel[1] - (int)sample.expected_g) <= tolerance &&
        abs((int)pixel[2] - (int)sample.expected_r) <= tolerance &&
        abs((int)pixel[3] - (int)sample.expected_a) <= tolerance;
}

static void maru_count_cell_readback_pixels(
    id<MTLBuffer> readback_buffer,
    const MaruMetalSmokeSample *samples,
    size_t sample_count,
    uint32_t *non_clear_out,
    uint32_t *atlas_sampled_out
) {
    uint32_t non_clear = 0;
    uint32_t atlas_sampled = 0;
    const uint8_t *bytes = (const uint8_t *)[readback_buffer contents];
    if (bytes != NULL && samples != NULL) {
        for (size_t i = 0; i < sample_count; i++) {
            const uint8_t *pixel = bytes + (i * maru_readback_stride);
            if (maru_pixel_is_non_clear(pixel)) {
                non_clear += 1;
            }
            if (maru_pixel_matches_expected_atlas_sample(pixel, samples[i])) {
                atlas_sampled += 1;
            }
        }
    }

    *non_clear_out = non_clear;
    *atlas_sampled_out = atlas_sampled;
}

static uint32_t maru_saturating_add_u32(uint32_t left, size_t right) {
    if (right > UINT32_MAX - left) {
        return UINT32_MAX;
    }
    return left + (uint32_t)right;
}

static size_t maru_align_up_size(size_t value, size_t alignment) {
    if (alignment == 0) {
        return value;
    }
    const size_t remainder = value % alignment;
    if (remainder == 0) {
        return value;
    }
    return value + (alignment - remainder);
}

static char *maru_copy_path(const char *path, size_t path_len) {
    if (path == NULL || path_len == 0) {
        return NULL;
    }
    char *copy = (char *)malloc(path_len + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, path, path_len);
    copy[path_len] = '\0';
    return copy;
}

static BOOL maru_write_ppm_from_bgra8_buffer(
    const char *path,
    const uint8_t *bgra_pixels,
    size_t width,
    size_t height,
    size_t bytes_per_row
) {
    if (path == NULL || bgra_pixels == NULL || width == 0 || height == 0) {
        return NO;
    }

    FILE *file = fopen(path, "wb");
    if (file == NULL) {
        return NO;
    }

    // 제품 Metal smoke는 대표 픽셀 readback으로 gate를 닫지만, 그 숫자만으로는 glyph
    // bitmap 자체가 뒤집힌 회귀를 사람이 확인할 수 없다. PPM(P6)은 외부 이미지
    // 라이브러리 없이 전체 drawable을 남기는 가장 단순한 artifact 포맷이다.
    if (fprintf(file, "P6\n%zu %zu\n255\n", width, height) < 0) {
        fclose(file);
        return NO;
    }

    BOOL ok = YES;
    for (size_t y = 0; y < height && ok; y++) {
        const uint8_t *row = bgra_pixels + y * bytes_per_row;
        for (size_t x = 0; x < width; x++) {
            const uint8_t *pixel = row + x * 4;
            const uint8_t rgb[3] = { pixel[2], pixel[1], pixel[0] };
            if (fwrite(rgb, sizeof(rgb), 1, file) != 1) {
                ok = NO;
                break;
            }
        }
    }

    if (fclose(file) != 0) {
        ok = NO;
    }
    return ok;
}

static uint32_t maru_count_mismatched_bytes(
    const uint8_t *left,
    const uint8_t *right,
    size_t byte_count
) {
    uint32_t mismatches = 0;
    for (size_t index = 0; index < byte_count; index++) {
        if (left[index] != right[index]) {
            mismatches = maru_saturating_add_u32(mismatches, 1);
        }
    }
    return mismatches;
}

static BOOL maru_upload_fits_atlas(
    MaruMetalRasterUpload upload,
    uint32_t atlas_width_px,
    uint32_t atlas_height_px,
    size_t raster_pixel_count
) {
    if (upload.slot_id == 0 ||
        upload.atlas_width_px == 0 ||
        upload.atlas_height_px == 0 ||
        upload.bytes_per_row == 0 ||
        upload.byte_count == 0)
    {
        return NO;
    }
    if (atlas_width_px == 0 || atlas_height_px == 0) {
        return NO;
    }
    if (upload.atlas_x_px >= atlas_width_px ||
        upload.atlas_y_px >= atlas_height_px ||
        upload.atlas_width_px > atlas_width_px - upload.atlas_x_px ||
        upload.atlas_height_px > atlas_height_px - upload.atlas_y_px)
    {
        return NO;
    }

    const size_t height = (size_t)upload.atlas_height_px;
    if (upload.bytes_per_row > SIZE_MAX / height) {
        return NO;
    }
    const size_t expected_bytes = upload.bytes_per_row * height;
    if (upload.byte_count != expected_bytes) {
        return NO;
    }
    // readback 비교는 source가 width*4로 tight하게 packing됐다고 보고 row 단위로 한다.
    // bytes_per_row가 slot width와 어긋나면 그 가정이 깨지므로 여기서 막는다(RGBA8 = 4 byte).
    if (upload.bytes_per_row != (size_t)upload.atlas_width_px * 4) {
        return NO;
    }
    if (upload.bytes_offset > raster_pixel_count ||
        upload.byte_count > raster_pixel_count - upload.bytes_offset)
    {
        return NO;
    }
    return YES;
}

static id<MTLTexture> maru_make_product_atlas_texture(
    id<MTLDevice> device,
    uint32_t atlas_width_px,
    uint32_t atlas_height_px,
    MaruMetalSmokeResult *result
) {
    if (device == nil || atlas_width_px == 0 || atlas_height_px == 0) {
        result->atlas_readback_failures += 1;
        return nil;
    }

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:(NSUInteger)atlas_width_px
                                    height:(NSUInteger)atlas_height_px
                                 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;

    id<MTLTexture> atlas_texture = [device newTextureWithDescriptor:descriptor];
    if (atlas_texture == nil) {
        result->atlas_readback_failures += 1;
        return nil;
    }
    result->atlas_texture_created = 1;
    return atlas_texture;
}

static BOOL maru_upload_and_readback_product_atlas(
    id<MTLDevice> device,
    id<MTLCommandQueue> queue,
    id<MTLTexture> atlas_texture,
    uint32_t atlas_width_px,
    uint32_t atlas_height_px,
    const MaruMetalRasterUpload *uploads,
    size_t upload_count,
    const uint8_t *raster_pixels,
    size_t raster_pixel_count,
    MaruMetalSmokeResult *result
) {
    // 제품 GlyphRasterFrame이 만든 RGBA bytes가 native Metal texture 경계까지 손실 없이
    // 건너가는지 먼저 검증한다. draw 단계는 이 texture를 다시 shader sampling하므로,
    // upload/readback과 sampling을 같은 summary에서 분리해 원인을 좁힐 수 있다.
    result->atlas_uploads_requested =
        (upload_count > UINT32_MAX) ? UINT32_MAX : (uint32_t)upload_count;
    if (device == nil || queue == nil || atlas_texture == nil ||
        atlas_width_px == 0 || atlas_height_px == 0)
    {
        result->atlas_readback_failures += 1;
        return NO;
    }
    if (upload_count == 0) {
        // upload 후보가 전혀 없는 것은 byte upload/readback 인프라 실패가 아니다.
        // draw 단계에서 visible cell의 atlas sample source 누락으로 기록해야 원인이
        // readback path가 아니라 raster/slot 준비 단계라는 점이 보인다.
        return YES;
    }
    if (uploads == NULL || raster_pixels == NULL || raster_pixel_count == 0) {
        result->atlas_readback_failures += 1;
        return NO;
    }

    for (size_t index = 0; index < upload_count; index++) {
        const MaruMetalRasterUpload upload = uploads[index];
        if (!maru_upload_fits_atlas(upload, atlas_width_px, atlas_height_px, raster_pixel_count)) {
            result->atlas_readback_failures += 1;
            return NO;
        }

        const uint8_t *source = raster_pixels + upload.bytes_offset;
        [atlas_texture replaceRegion:MTLRegionMake2D(
                                      (NSUInteger)upload.atlas_x_px,
                                      (NSUInteger)upload.atlas_y_px,
                                      (NSUInteger)upload.atlas_width_px,
                                      (NSUInteger)upload.atlas_height_px)
                          mipmapLevel:0
                            withBytes:source
                          bytesPerRow:upload.bytes_per_row];
        result->atlas_uploads_uploaded = maru_saturating_add_u32(result->atlas_uploads_uploaded, 1);
        result->atlas_upload_bytes = maru_saturating_add_u32(result->atlas_upload_bytes, upload.byte_count);
    }

    for (size_t index = 0; index < upload_count; index++) {
        const MaruMetalRasterUpload upload = uploads[index];
        const uint8_t *source = raster_pixels + upload.bytes_offset;
        // Metal texture->buffer blit은 destinationBytesPerRow가 정렬(여기선 256)된 값이어야
        // 하는 GPU가 있다(이 파일의 cell readback이 maru_readback_stride=256을 쓰는 이유,
        // docs/font-strategy.md도 같은 제약을 적는다). 그래서 source의 tight stride 대신
        // 정렬된 row stride로 readback buffer를 잡고, 비교는 각 row의 실제 byte만 한다.
        const size_t aligned_bytes_per_row =
            maru_align_up_size(upload.bytes_per_row, maru_readback_stride);
        const size_t readback_height = (size_t)upload.atlas_height_px;
        const size_t readback_length = aligned_bytes_per_row * readback_height;
        id<MTLBuffer> readback_buffer = [device
            newBufferWithLength:readback_length
                        options:MTLResourceStorageModeShared];
        if (readback_buffer == nil) {
            result->atlas_readback_failures += 1;
            return NO;
        }

        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
        if (command_buffer == nil) {
            result->atlas_readback_failures += 1;
            return NO;
        }

        id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
        if (blit == nil) {
            result->atlas_readback_failures += 1;
            return NO;
        }

        [blit copyFromTexture:atlas_texture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(
                                  (NSUInteger)upload.atlas_x_px,
                                  (NSUInteger)upload.atlas_y_px,
                                  0)
                   sourceSize:MTLSizeMake(
                                  (NSUInteger)upload.atlas_width_px,
                                  (NSUInteger)upload.atlas_height_px,
                                  1)
                     toBuffer:readback_buffer
            destinationOffset:0
       destinationBytesPerRow:aligned_bytes_per_row
     destinationBytesPerImage:readback_length];
        [blit endEncoding];
        [command_buffer commit];
        [command_buffer waitUntilCompleted];

        const uint8_t *readback = (const uint8_t *)[readback_buffer contents];
        if (readback == NULL) {
            result->atlas_readback_failures += 1;
            return NO;
        }
        result->atlas_readback_uploads = maru_saturating_add_u32(result->atlas_readback_uploads, 1);
        // source는 tight(bytes_per_row)하고 readback은 정렬 stride라, 각 row의 padding을 빼고
        // 실제 픽셀 byte(bytes_per_row)만 비교한다.
        for (size_t row = 0; row < readback_height; row++) {
            result->atlas_readback_mismatched_bytes = maru_saturating_add_u32(
                result->atlas_readback_mismatched_bytes,
                maru_count_mismatched_bytes(
                    source + row * upload.bytes_per_row,
                    readback + row * aligned_bytes_per_row,
                    upload.bytes_per_row));
        }
    }

    return result->atlas_uploads_uploaded == result->atlas_uploads_requested &&
        result->atlas_readback_uploads == result->atlas_uploads_uploaded &&
        result->atlas_readback_mismatched_bytes == 0 &&
        result->atlas_readback_failures == 0;
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
        MaruMetalSmokeVertex quad[6] = {
            {left, top, cell.u0, cell.v0},
            {left, bottom, cell.u0, cell.v1},
            {right, bottom, cell.u1, cell.v1},
            {left, top, cell.u0, cell.v0},
            {right, bottom, cell.u1, cell.v1},
            {right, top, cell.u1, cell.v0},
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
    id<MTLTexture> atlas_texture,
    const MaruMetalSmokeCell *cells,
    size_t cell_count,
    uint16_t cols,
    uint16_t rows,
    const MaruMetalRasterUpload *uploads,
    size_t upload_count,
    const uint8_t *raster_pixels,
    size_t raster_pixel_count,
    const char *screenshot_path,
    MaruMetalSmokeResult *result
) {
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (drawable == nil) {
        result->drawable_failures += 1;
        return NO;
    }
    if (atlas_texture == nil) {
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
    size_t missing_count = 0;
    MaruMetalSmokeSample *samples = maru_build_cell_samples(
        cells,
        cell_count,
        cols,
        rows,
        drawable.texture.width,
        drawable.texture.height,
        uploads,
        upload_count,
        raster_pixels,
        raster_pixel_count,
        &sample_count,
        &missing_count
    );
    result->atlas_sample_missing_cells =
        (missing_count > UINT32_MAX) ? UINT32_MAX : (uint32_t)missing_count;
    if (samples == NULL) {
        [encoder endEncoding];
        result->readback_failures += 1;
        return NO;
    }

    id<MTLBuffer> readback_buffer = nil;
    if (sample_count > 0) {
        readback_buffer = [layer.device
            newBufferWithLength:sample_count * maru_readback_stride
                        options:MTLResourceStorageModeShared];
        if (readback_buffer == nil) {
            [encoder endEncoding];
            free(samples);
            result->readback_failures += 1;
            return NO;
        }
    }

    const BOOL should_write_screenshot =
        screenshot_path != NULL &&
        result->screenshot_written == 0 &&
        result->screenshot_failures == 0;
    id<MTLBuffer> screenshot_buffer = nil;
    size_t screenshot_bytes_per_row = 0;
    size_t screenshot_byte_count = 0;
    if (should_write_screenshot) {
        const size_t raw_bytes_per_row = (size_t)drawable.texture.width * 4;
        screenshot_bytes_per_row = maru_align_up_size(raw_bytes_per_row, maru_readback_stride);
        if (screenshot_bytes_per_row == 0 ||
            drawable.texture.height > SIZE_MAX / screenshot_bytes_per_row)
        {
            result->screenshot_failures += 1;
        } else {
            screenshot_byte_count = screenshot_bytes_per_row * (size_t)drawable.texture.height;
            screenshot_buffer = [layer.device
                newBufferWithLength:screenshot_byte_count
                            options:MTLResourceStorageModeShared];
            if (screenshot_buffer == nil) {
                result->screenshot_failures += 1;
            }
        }
    }

    [encoder setRenderPipelineState:cell_pipeline];
    [encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
    [encoder setFragmentTexture:atlas_texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:vertex_count];
    [encoder endEncoding];

    if (sample_count > 0) {
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
        if (screenshot_buffer != nil) {
            [blit copyFromTexture:drawable.texture
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(drawable.texture.width, drawable.texture.height, 1)
                         toBuffer:screenshot_buffer
                destinationOffset:0
           destinationBytesPerRow:screenshot_bytes_per_row
         destinationBytesPerImage:screenshot_byte_count];
        }
        [blit endEncoding];
    }

    [command_buffer presentDrawable:drawable];
    [command_buffer commit];
    [command_buffer waitUntilCompleted];
    result->presented_frames += 1;
    // rendered_cells는 "draw에 제출한 셀 수"라는 관측값이다(실제 렌더 검증은 readback이
    // 한다). summary에서 requested_cells와 같은 포화 규칙으로 맞춰 둔다.
    result->rendered_cells = (cell_count > UINT32_MAX) ? UINT32_MAX : (uint32_t)cell_count;
    result->readback_samples = (sample_count > UINT32_MAX) ? UINT32_MAX : (uint32_t)sample_count;
    if (sample_count > 0) {
        maru_count_cell_readback_pixels(
            readback_buffer,
            samples,
            sample_count,
            &result->readback_non_clear_pixels,
            &result->atlas_sampled_cells
        );
    }
    if (screenshot_buffer != nil &&
        sample_count > 0 &&
        result->atlas_sampled_cells == result->readback_samples)
    {
        const uint8_t *screenshot_bytes = (const uint8_t *)[screenshot_buffer contents];
        const BOOL wrote = maru_write_ppm_from_bgra8_buffer(
            screenshot_path,
            screenshot_bytes,
            (size_t)drawable.texture.width,
            (size_t)drawable.texture.height,
            screenshot_bytes_per_row
        );
        if (wrote) {
            result->screenshot_written = 1;
            result->screenshot_width = (drawable.texture.width > UINT32_MAX)
                ? UINT32_MAX
                : (uint32_t)drawable.texture.width;
            result->screenshot_height = (drawable.texture.height > UINT32_MAX)
                ? UINT32_MAX
                : (uint32_t)drawable.texture.height;
            const size_t rgb_payload_bytes = (size_t)drawable.texture.width *
                (size_t)drawable.texture.height *
                3;
            result->screenshot_bytes = (rgb_payload_bytes > UINT32_MAX)
                ? UINT32_MAX
                : (uint32_t)rgb_payload_bytes;
        } else {
            result->screenshot_failures += 1;
        }
    }
    free(samples);
    return YES;
}

void maru_macos_metal_smoke_run(
    uint32_t duration_ms,
    uint16_t cols,
    uint16_t rows,
    const MaruMetalSmokeCell *cells,
    size_t cell_count,
    uint32_t atlas_width_px,
    uint32_t atlas_height_px,
    const MaruMetalRasterUpload *raster_uploads,
    size_t raster_upload_count,
    const uint8_t *raster_pixels,
    size_t raster_pixel_count,
    const char *screenshot_path,
    size_t screenshot_path_len,
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
    result->atlas_texture_created = 0;
    result->atlas_uploads_requested = 0;
    result->atlas_uploads_uploaded = 0;
    result->atlas_upload_bytes = 0;
    result->atlas_readback_uploads = 0;
    result->atlas_readback_mismatched_bytes = 0;
    result->atlas_readback_failures = 0;
    result->atlas_sampled_cells = 0;
    result->atlas_sample_missing_cells = 0;
    result->screenshot_written = 0;
    result->screenshot_width = 0;
    result->screenshot_height = 0;
    result->screenshot_bytes = 0;
    result->screenshot_failures = 0;

    @autoreleasepool {
        // 이 bridge는 "Metal glyph renderer 완성"이 아니라 첫 RenderFrame/GlyphQuadFrame/
        // GlyphRasterFrame 소비 smoke다.
        // Zig 쪽이 TerminalCore/RendererState/RenderFrame/artifact 계약을 소유하고,
        // 여기서는 그 slot-backed 셀 배열을 실제 CAMetalLayer 위에서 제품 atlas texture
        // sampling quad로 present하고, raster bytes를 Metal atlas texture에 업로드/readback한다.
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

        id<MTLTexture> atlas_texture = maru_make_product_atlas_texture(
            device,
            atlas_width_px,
            atlas_height_px,
            result
        );
        if (atlas_texture == nil) {
            result->status = 10;
            return;
        }

        if (!maru_upload_and_readback_product_atlas(
                device,
                queue,
                atlas_texture,
                atlas_width_px,
                atlas_height_px,
                raster_uploads,
                raster_upload_count,
                raster_pixels,
                raster_pixel_count,
                result))
        {
            result->status = 10;
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
        // 이 smoke는 drawable의 source ink 위치를 blit-readback해야 한다. framebufferOnly=YES는
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

        char *screenshot_path_copy = maru_copy_path(screenshot_path, screenshot_path_len);
        if (screenshot_path_copy == NULL) {
            result->screenshot_failures += 1;
        }

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
                    atlas_texture,
                    cells,
                    cell_count,
                    cols,
                    rows,
                    raster_uploads,
                    raster_upload_count,
                    raster_pixels,
                    raster_pixel_count,
                    screenshot_path_copy,
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
        free(screenshot_path_copy);

        if (!became_visible) {
            result->status = 5;
            return;
        }

        if (result->presented_frames == 0) {
            result->status = 6;
            return;
        }
        if (result->atlas_sample_missing_cells > 0) {
            result->status = 11;
            return;
        }
        // readback이 실제 렌더 검증의 게이트다. shader가 제품 atlas texel을 drawable에
        // 샘플링했는지는 아래 atlas_sampled_cells == readback_samples 비교가 판정하므로
        // (near-clear glyph도 통과), 여기서는 readback 자체가 성공했는지만 본다. non-clear
        // 픽셀 수는 summary 진단값으로만 남기고 pass/fail 게이트로 쓰지 않는다(Zig
        // deriveSmokeStatus와 같은 규칙). readback은 compositing 전 drawable 텍스처를
        // 읽으므로 "GPU가 셀을 렌더했다"를 증명하고, "화면에 안 가려졌다"는 window_visible이
        // 따로 담당한다.
        if (result->readback_samples == 0 ||
            result->readback_failures > 0)
        {
            result->status = 9;
            return;
        }
        if (result->atlas_sampled_cells != result->readback_samples) {
            result->status = 11;
            return;
        }
        if (result->screenshot_written == 0 || result->screenshot_failures > 0) {
            result->status = 12;
            return;
        }
        // atlas upload/readback 검증은 위 maru_upload_and_readback_product_atlas가 NO를
        // 돌려주면 이미 status=10으로 early-return했다. 그래서 여기서 다시 게이트하지 않고,
        // 제품 gate(product_atlas_uploaded)는 Zig deriveSmokeStatus 한 곳에서만 판정한다.
        result->status = 0;
    }
}
