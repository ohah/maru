#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#import "maru_ppm_writer.h"

typedef struct {
    int32_t status;
    uint32_t window_visible;
    uint32_t metal_device_created;
    uint32_t command_queue_created;
    uint32_t source_rasterized;
    uint32_t texture_created;
    uint32_t texture_uploaded;
    uint32_t pipeline_created;
    uint32_t glyph_text_drawn;
    uint32_t presented_frames;
    uint32_t drawable_failures;
    uint32_t source_width;
    uint32_t source_height;
    uint32_t source_non_clear_pixels;
    uint32_t readback_samples;
    uint32_t readback_non_clear_pixels;
    uint32_t readback_visible_glyph_pixels;
    uint32_t readback_failures;
    uint32_t upload_bytes;
    uint32_t screenshot_written;
    uint32_t screenshot_width;
    uint32_t screenshot_height;
    uint32_t screenshot_bytes;
    uint32_t screenshot_failures;
    uint32_t backing_scale_x100;
} MaruGlyphTextSmokeResult;

// Zig config.ResolvedAppearance에서 넘어온 검증된 색. raw 문자열이 아니라 이미 #RRGGBB가
// Rgb로 parse된 값이라, 이 bridge는 정규화(0..1)만 하고 그대로 그린다. 필드 순서/타입은
// glyph_text_smoke.zig의 NativeGlyphTextAppearance와 정확히 일치해야 한다.
typedef struct {
    uint8_t background_r;
    uint8_t background_g;
    uint8_t background_b;
    uint8_t foreground_r;
    uint8_t foreground_g;
    uint8_t foreground_b;
    uint8_t cursor_r;
    uint8_t cursor_g;
    uint8_t cursor_b;
} MaruGlyphTextAppearance;

typedef struct {
    uint8_t *pixels;
    size_t width;
    size_t height;
    size_t bytes_per_row;
    size_t byte_count;
    uint32_t non_clear_pixels;
} MaruGlyphTextBitmap;

typedef struct {
    float x;
    float y;
    float u;
    float v;
} MaruGlyphTextVertex;

typedef struct {
    NSUInteger x;
    NSUInteger y;
} MaruGlyphTextDrawableSample;

typedef struct {
    size_t x;
    size_t y;
} MaruGlyphTextSourceSample;

static const NSUInteger maru_glyph_text_readback_stride = 256;

// VertexIn은 host쪽 MaruGlyphTextVertex(float 4개, 16바이트)와 같은 메모리
// 레이아웃이어야 한다. packed_float2 두 개를 쓰면 MSL과 C struct stride가 같아져,
// shader가 uv를 잘못 읽는 숨은 회귀를 피할 수 있다.
static NSString *const maru_glyph_text_shader_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VertexIn { packed_float2 position; packed_float2 uv; };\n"
     "struct VertexOut { float4 position [[position]]; float2 uv; };\n"
     "vertex VertexOut maru_glyph_text_vertex(uint vid [[vertex_id]], const device VertexIn *vertices [[buffer(0)]]) {\n"
     "  VertexOut out;\n"
     "  out.position = float4(float2(vertices[vid].position), 0.0, 1.0);\n"
     "  out.uv = float2(vertices[vid].uv);\n"
     "  return out;\n"
     "}\n"
     "fragment float4 maru_glyph_text_fragment(VertexOut in [[stage_in]], texture2d<float> glyph_texture [[texture(0)]]) {\n"
     "  constexpr sampler glyph_sampler(coord::normalized, address::clamp_to_edge, filter::nearest);\n"
     "  return glyph_texture.sample(glyph_sampler, in.uv);\n"
     "}\n";

static void maru_clear_result(MaruGlyphTextSmokeResult *result) {
    result->status = -1;
    result->window_visible = 0;
    result->metal_device_created = 0;
    result->command_queue_created = 0;
    result->source_rasterized = 0;
    result->texture_created = 0;
    result->texture_uploaded = 0;
    result->pipeline_created = 0;
    result->glyph_text_drawn = 0;
    result->presented_frames = 0;
    result->drawable_failures = 0;
    result->source_width = 0;
    result->source_height = 0;
    result->source_non_clear_pixels = 0;
    result->readback_samples = 0;
    result->readback_non_clear_pixels = 0;
    result->readback_visible_glyph_pixels = 0;
    result->readback_failures = 0;
    result->upload_bytes = 0;
    result->screenshot_written = 0;
    result->screenshot_width = 0;
    result->screenshot_height = 0;
    result->screenshot_bytes = 0;
    result->screenshot_failures = 0;
    result->backing_scale_x100 = 0;
}

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

static CFStringRef maru_create_probe_string(void) {
    static const UInt8 bytes[] = { 'M', 'a', 'r', 'u' };
    return CFStringCreateWithBytes(
        kCFAllocatorDefault,
        bytes,
        sizeof(bytes),
        kCFStringEncodingUTF8,
        false
    );
}

static CTFontRef maru_create_primary_font(void) {
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, 24.0, NULL);
    if (font != NULL) {
        return font;
    }
    return CTFontCreateWithName(CFSTR("Menlo-Regular"), 24.0, NULL);
}

static void maru_free_bitmap(MaruGlyphTextBitmap *bitmap) {
    if (bitmap->pixels != NULL) {
        free(bitmap->pixels);
    }
    bitmap->pixels = NULL;
    bitmap->width = 0;
    bitmap->height = 0;
    bitmap->bytes_per_row = 0;
    bitmap->byte_count = 0;
    bitmap->non_clear_pixels = 0;
}

static uint32_t maru_count_non_clear_rgba_pixels(const uint8_t *pixels, size_t byte_count) {
    uint32_t non_clear = 0;
    for (size_t offset = 0; offset + 3 < byte_count; offset += 4) {
        if (pixels[offset + 3] != 0) {
            non_clear += 1;
        }
    }
    return non_clear;
}

static int maru_make_coretext_bitmap(
    MaruGlyphTextSmokeResult *result,
    const MaruGlyphTextAppearance *appearance,
    MaruGlyphTextBitmap *bitmap
) {
    // 이 bitmap은 제품 glyph atlas가 아니라 shader sampling smoke의 입력 fixture다.
    // 제품 renderer가 들어오면 atlas packing, eviction, scale별 slot 관리는 Zig
    // renderer 모듈이 소유하고, 이 bridge는 low-level 회귀 smoke로만 남는다.
    const size_t width = 128;
    const size_t height = 64;
    const size_t bytes_per_pixel = 4;
    const size_t bytes_per_row = width * bytes_per_pixel;
    const size_t byte_count = bytes_per_row * height;

    bitmap->pixels = (uint8_t *)calloc(byte_count, 1);
    if (bitmap->pixels == NULL) {
        return 2;
    }
    bitmap->width = width;
    bitmap->height = height;
    bitmap->bytes_per_row = bytes_per_row;
    bitmap->byte_count = byte_count;

    CTFontRef font = maru_create_primary_font();
    if (font == NULL) {
        return 2;
    }

    CFStringRef probe = maru_create_probe_string();
    if (probe == NULL) {
        CFRelease(font);
        return 2;
    }

    const CGFloat fg_r = (CGFloat)appearance->foreground_r / 255.0;
    const CGFloat fg_g = (CGFloat)appearance->foreground_g / 255.0;
    const CGFloat fg_b = (CGFloat)appearance->foreground_b / 255.0;
    CGColorRef foreground_color = CGColorCreateGenericRGB(fg_r, fg_g, fg_b, 1.0);
    if (foreground_color == NULL) {
        CFRelease(probe);
        CFRelease(font);
        return 2;
    }

    const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
    const void *values[] = { font, foreground_color };
    CFDictionaryRef attributes = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (attributes == NULL) {
        CGColorRelease(foreground_color);
        CFRelease(probe);
        CFRelease(font);
        return 2;
    }

    CFAttributedStringRef attributed = CFAttributedStringCreate(
        kCFAllocatorDefault,
        probe,
        attributes
    );
    if (attributed == NULL) {
        CFRelease(attributes);
        CGColorRelease(foreground_color);
        CFRelease(probe);
        CFRelease(font);
        return 2;
    }

    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    if (line == NULL) {
        CFRelease(attributed);
        CFRelease(attributes);
        CGColorRelease(foreground_color);
        CFRelease(probe);
        CFRelease(font);
        return 2;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == NULL) {
        CFRelease(line);
        CFRelease(attributed);
        CFRelease(attributes);
        CGColorRelease(foreground_color);
        CFRelease(probe);
        CFRelease(font);
        return 2;
    }

    CGContextRef context = CGBitmapContextCreate(
        bitmap->pixels,
        width,
        height,
        8,
        bytes_per_row,
        color_space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    if (context == NULL) {
        CGColorSpaceRelease(color_space);
        CFRelease(line);
        CFRelease(attributed);
        CFRelease(attributes);
        CGColorRelease(foreground_color);
        CFRelease(probe);
        CFRelease(font);
        return 2;
    }

    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextSetShouldAntialias(context, true);
    // attributed string의 kCTForegroundColorAttributeName이 실제 색을 정하지만, context
    // fill color도 같은 resolved foreground로 맞춰 둔다(둘이 어긋나 헷갈리지 않게).
    CGContextSetRGBFillColor(context, fg_r, fg_g, fg_b, 1.0);
    CGContextSetTextPosition(context, 8.0, 36.0);
    CTLineDraw(line, context);

    bitmap->non_clear_pixels = maru_count_non_clear_rgba_pixels(bitmap->pixels, bitmap->byte_count);
    result->source_width = (uint32_t)width;
    result->source_height = (uint32_t)height;
    result->source_non_clear_pixels = bitmap->non_clear_pixels;
    result->source_rasterized = bitmap->non_clear_pixels > 0 ? 1 : 0;

    CGContextRelease(context);
    CGColorSpaceRelease(color_space);
    CFRelease(line);
    CFRelease(attributed);
    CFRelease(attributes);
    CGColorRelease(foreground_color);
    CFRelease(probe);
    CFRelease(font);

    return bitmap->non_clear_pixels > 0 ? 0 : 2;
}

static id<MTLTexture> maru_make_glyph_texture(
    id<MTLDevice> device,
    const MaruGlyphTextBitmap *bitmap,
    MaruGlyphTextSmokeResult *result
) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:bitmap->width
                                    height:bitmap->height
                                 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;

    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture == nil) {
        return nil;
    }
    result->texture_created = 1;

    [texture replaceRegion:MTLRegionMake2D(0, 0, bitmap->width, bitmap->height)
               mipmapLevel:0
                 withBytes:bitmap->pixels
               bytesPerRow:bitmap->bytes_per_row];
    result->texture_uploaded = 1;
    result->upload_bytes = (bitmap->byte_count > UINT32_MAX) ? UINT32_MAX : (uint32_t)bitmap->byte_count;
    return texture;
}

static id<MTLRenderPipelineState> maru_make_glyph_text_pipeline(
    id<MTLDevice> device,
    MTLPixelFormat pixel_format
) {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:maru_glyph_text_shader_source
                                                  options:nil
                                                    error:&error];
    if (library == nil) {
        return nil;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"maru_glyph_text_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"maru_glyph_text_fragment"];
    descriptor.colorAttachments[0].pixelFormat = pixel_format;
    // glyph texture는 CoreGraphics가 kCGImageAlphaPremultipliedLast로 만든 premultiplied
    // 데이터이고 fragment shader가 그 값을 그대로 반환한다. premultiplied source의 올바른
    // "over" 합성은 source 계수가 One이다. SourceAlpha를 쓰면 alpha가 한 번 더 곱해져
    // 반투명 glyph edge가 실제보다 어둡게(클리어 색에 가깝게) 합성된다.
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

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

static size_t maru_align_up_size(size_t value, size_t alignment) {
    if (alignment == 0) {
        return value;
    }
    const size_t remainder = value % alignment;
    if (remainder == 0) {
        return value;
    }
    const size_t increment = alignment - remainder;
    if (value > SIZE_MAX - increment) {
        return 0;
    }
    return value + increment;
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

static MaruGlyphTextSourceSample *maru_build_source_samples(
    const MaruGlyphTextBitmap *bitmap,
    size_t *sample_count
) {
    *sample_count = 0;
    if (bitmap->pixels == NULL || bitmap->width == 0 || bitmap->height == 0) {
        return NULL;
    }

    const size_t max_samples = 64;
    MaruGlyphTextSourceSample *samples = calloc(max_samples, sizeof(MaruGlyphTextSourceSample));
    if (samples == NULL) {
        return NULL;
    }

    // glyph edge의 낮은 alpha 픽셀은 blending 후 clear 색과 구분이 약할 수 있다.
    // 먼저 alpha가 높은 ink 픽셀을 고르고, 그런 픽셀이 전혀 없을 때만 모든 ink로
    // fallback한다. smoke가 안티앨리어싱 경계가 아니라 실제 glyph body를 보게 하기 위함이다.
    const uint8_t thresholds[] = { 160, 1 };
    const size_t threshold_count = sizeof(thresholds) / sizeof(thresholds[0]);
    for (size_t pass = 0; pass < threshold_count; pass++) {
        const uint8_t threshold = thresholds[pass];
        size_t count = 0;
        for (size_t y = 0; y < bitmap->height && count < max_samples; y++) {
            for (size_t x = 0; x < bitmap->width && count < max_samples; x++) {
                const size_t offset = y * bitmap->bytes_per_row + x * 4;
                const uint8_t alpha = bitmap->pixels[offset + 3];
                if (alpha >= threshold) {
                    samples[count].x = x;
                    samples[count].y = y;
                    count += 1;
                }
            }
        }
        if (count > 0) {
            *sample_count = count;
            return samples;
        }
    }

    free(samples);
    return NULL;
}

static MaruGlyphTextDrawableSample *maru_build_drawable_samples(
    const MaruGlyphTextSourceSample *source_samples,
    size_t source_sample_count,
    const MaruGlyphTextBitmap *bitmap,
    NSUInteger drawable_width,
    NSUInteger drawable_height,
    size_t *sample_count
) {
    *sample_count = 0;
    if (source_samples == NULL || source_sample_count == 0 ||
        bitmap->width == 0 || bitmap->height == 0 ||
        drawable_width == 0 || drawable_height == 0)
    {
        return NULL;
    }

    MaruGlyphTextDrawableSample *samples = calloc(
        source_sample_count,
        sizeof(MaruGlyphTextDrawableSample)
    );
    if (samples == NULL) {
        return NULL;
    }

    const double quad_left = -0.68;
    const double quad_right = 0.68;
    const double quad_top = 0.34;
    const double quad_bottom = -0.34;
    const double quad_width = quad_right - quad_left;
    const double quad_height = quad_top - quad_bottom;

    for (size_t i = 0; i < source_sample_count; i++) {
        const double u = ((double)source_samples[i].x + 0.5) / (double)bitmap->width;
        const double v = ((double)source_samples[i].y + 0.5) / (double)bitmap->height;
        const double ndc_x = quad_left + u * quad_width;
        const double ndc_y = quad_top - v * quad_height;

        samples[i].x = maru_clamp_pixel(((ndc_x + 1.0) * 0.5) * (double)drawable_width, drawable_width);
        samples[i].y = maru_clamp_pixel(((1.0 - ndc_y) * 0.5) * (double)drawable_height, drawable_height);
    }

    *sample_count = source_sample_count;
    return samples;
}

static MaruGlyphTextVertex *maru_build_glyph_text_vertices(size_t *vertex_count) {
    *vertex_count = 6;
    MaruGlyphTextVertex *vertices = calloc(*vertex_count, sizeof(MaruGlyphTextVertex));
    if (vertices == NULL) {
        *vertex_count = 0;
        return NULL;
    }

    const float left = -0.68f;
    const float right = 0.68f;
    const float top = 0.34f;
    const float bottom = -0.34f;
    MaruGlyphTextVertex quad[6] = {
        {left, top, 0.0f, 0.0f},
        {left, bottom, 0.0f, 1.0f},
        {right, bottom, 1.0f, 1.0f},
        {left, top, 0.0f, 0.0f},
        {right, bottom, 1.0f, 1.0f},
        {right, top, 1.0f, 0.0f},
    };
    memcpy(vertices, quad, sizeof(quad));
    return vertices;
}

static BOOL maru_pixel_is_non_clear(const uint8_t *pixel, const MaruGlyphTextAppearance *appearance) {
    // drawable은 BGRA8Unorm이라 메모리 순서가 B,G,R,A다. clear 색은 더 이상 하드코딩이
    // 아니라 resolved theme.background이므로, 그 background와 충분히 다른 픽셀만 non-clear로
    // 본다. 허용 오차는 GPU float->unorm 반올림 차이를 흡수하기 위한 값이다.
    const int expected_b = appearance->background_b;
    const int expected_g = appearance->background_g;
    const int expected_r = appearance->background_r;
    const int expected_a = 255;
    const int tolerance = 8;
    return abs((int)pixel[0] - expected_b) > tolerance ||
        abs((int)pixel[1] - expected_g) > tolerance ||
        abs((int)pixel[2] - expected_r) > tolerance ||
        abs((int)pixel[3] - expected_a) > tolerance;
}

static BOOL maru_pixel_is_visible_glyph(const uint8_t *pixel, const MaruGlyphTextAppearance *appearance) {
    // non-clear만 보면 "배경과 비슷한 밝기의 glyph"도 성공으로 보인다. 이 smoke는 사람이
    // 볼 수 있는 glyph를 검증해야 하므로, resolved background와 luma가 충분히 대비되는지도
    // 별도로 센다. theme는 밝은 배경/어두운 글자(light theme)일 수도 있으므로 "더 밝다"가
    // 아니라 "절댓값 대비가 충분히 크다"로 본다. 그래야 background를 어떤 색으로 바꿔도
    // gate가 유효하다. (R*299+G*587+B*114)/1000 luma를 background와 같은 가중치로 비교한다.
    const int luma =
        ((int)pixel[2] * 299 + (int)pixel[1] * 587 + (int)pixel[0] * 114) / 1000;
    const int background_luma =
        ((int)appearance->background_r * 299 +
         (int)appearance->background_g * 587 +
         (int)appearance->background_b * 114) / 1000;
    return abs(luma - background_luma) > 40;
}

// non-clear 카운트와 visible-glyph 카운트는 같은 readback buffer를 같은 stride로
// 도는 동일 루프라, 예측자만 다른 두 함수를 하나로 합쳐 한 번만 스캔한다. bytes가
// NULL이면(드물게 GPU buffer mapping 실패) 둘 다 0으로 남겨 기존 동작을 유지한다.
static void maru_count_readback_pixels(
    id<MTLBuffer> readback_buffer,
    size_t sample_count,
    const MaruGlyphTextAppearance *appearance,
    uint32_t *non_clear_out,
    uint32_t *visible_glyph_out
) {
    uint32_t non_clear = 0;
    uint32_t visible = 0;
    const uint8_t *bytes = (const uint8_t *)[readback_buffer contents];
    if (bytes != NULL) {
        for (size_t i = 0; i < sample_count; i++) {
            const uint8_t *pixel = bytes + (i * maru_glyph_text_readback_stride);
            if (maru_pixel_is_non_clear(pixel, appearance)) {
                non_clear += 1;
            }
            if (maru_pixel_is_visible_glyph(pixel, appearance)) {
                visible += 1;
            }
        }
    }
    *non_clear_out = non_clear;
    *visible_glyph_out = visible;
}

static BOOL maru_draw_glyph_text_frame(
    CAMetalLayer *layer,
    id<MTLCommandQueue> queue,
    id<MTLRenderPipelineState> pipeline,
    id<MTLTexture> glyph_texture,
    const MaruGlyphTextBitmap *bitmap,
    const MaruGlyphTextAppearance *appearance,
    const char *screenshot_path,
    MaruGlyphTextSmokeResult *result
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
    // clear 색을 resolved theme.background로 칠한다. readback 예측자도 같은 background를
    // 참조하므로, 사용자가 배경색을 바꿔도 glyph ink 검증 gate는 그대로 유효하다.
    pass.colorAttachments[0].clearColor = MTLClearColorMake(
        (double)appearance->background_r / 255.0,
        (double)appearance->background_g / 255.0,
        (double)appearance->background_b / 255.0,
        1.0
    );

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
    MaruGlyphTextVertex *vertices = maru_build_glyph_text_vertices(&vertex_count);
    if (vertices == NULL || vertex_count == 0) {
        [encoder endEncoding];
        free(vertices);
        result->drawable_failures += 1;
        return NO;
    }

    id<MTLBuffer> vertex_buffer = [layer.device
        newBufferWithBytes:vertices
                    length:vertex_count * sizeof(MaruGlyphTextVertex)
                   options:MTLResourceStorageModeShared];
    free(vertices);
    if (vertex_buffer == nil) {
        [encoder endEncoding];
        result->drawable_failures += 1;
        return NO;
    }

    size_t source_sample_count = 0;
    MaruGlyphTextSourceSample *source_samples = maru_build_source_samples(
        bitmap,
        &source_sample_count
    );
    if (source_samples == NULL || source_sample_count == 0) {
        [encoder endEncoding];
        free(source_samples);
        result->readback_failures += 1;
        return NO;
    }

    size_t drawable_sample_count = 0;
    MaruGlyphTextDrawableSample *drawable_samples = maru_build_drawable_samples(
        source_samples,
        source_sample_count,
        bitmap,
        drawable.texture.width,
        drawable.texture.height,
        &drawable_sample_count
    );
    free(source_samples);
    if (drawable_samples == NULL || drawable_sample_count == 0) {
        [encoder endEncoding];
        free(drawable_samples);
        result->readback_failures += 1;
        return NO;
    }

    id<MTLBuffer> readback_buffer = [layer.device
        newBufferWithLength:drawable_sample_count * maru_glyph_text_readback_stride
                    options:MTLResourceStorageModeShared];
    if (readback_buffer == nil) {
        [encoder endEncoding];
        free(drawable_samples);
        result->readback_failures += 1;
        return NO;
    }

    const BOOL should_write_screenshot =
        screenshot_path != NULL &&
        result->screenshot_written == 0;
    id<MTLBuffer> screenshot_buffer = nil;
    size_t screenshot_bytes_per_row = 0;
    size_t screenshot_byte_count = 0;
    if (should_write_screenshot) {
        const size_t raw_bytes_per_row = (size_t)drawable.texture.width * 4;
        screenshot_bytes_per_row = maru_align_up_size(raw_bytes_per_row, 256);
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

    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
    [encoder setFragmentTexture:glyph_texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:vertex_count];
    [encoder endEncoding];

    id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
    if (blit == nil) {
        free(drawable_samples);
        result->readback_failures += 1;
        return NO;
    }
    for (size_t i = 0; i < drawable_sample_count; i++) {
        [blit copyFromTexture:drawable.texture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(drawable_samples[i].x, drawable_samples[i].y, 0)
                   sourceSize:MTLSizeMake(1, 1, 1)
                     toBuffer:readback_buffer
            destinationOffset:i * maru_glyph_text_readback_stride
       destinationBytesPerRow:maru_glyph_text_readback_stride
     destinationBytesPerImage:maru_glyph_text_readback_stride];
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
    free(drawable_samples);

    [command_buffer presentDrawable:drawable];
    [command_buffer commit];
    [command_buffer waitUntilCompleted];

    result->presented_frames += 1;
    result->readback_samples = (drawable_sample_count > UINT32_MAX)
        ? UINT32_MAX
        : (uint32_t)drawable_sample_count;
    maru_count_readback_pixels(
        readback_buffer,
        drawable_sample_count,
        appearance,
        &result->readback_non_clear_pixels,
        &result->readback_visible_glyph_pixels
    );
    result->glyph_text_drawn =
        result->readback_samples > 0 &&
        result->readback_non_clear_pixels == result->readback_samples &&
        result->readback_visible_glyph_pixels == result->readback_samples
        ? 1
        : 0;
    if (screenshot_buffer != nil && result->glyph_text_drawn != 0) {
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
    return result->glyph_text_drawn != 0;
}

// result->status는 어느 단계에서 멈췄는지 summary(native_status/native_status_label)로
// 분리하기 위한 값이다. 새 값을 추가하면 glyph_text_smoke.zig의 nativeStatusLabel도
// 같이 갱신해야 artifact와 native bridge가 같은 말을 한다:
//   0  = 성공(visible window + texture upload + shader sampling + readback)
//   1  = window/AppKit lifecycle 실패
//   2  = CoreText/CoreGraphics CPU bitmap raster 실패
//   3  = Metal device 생성 실패(headless/GPU 없음)
//   4  = command queue 생성 실패
//   5  = texture 생성 또는 upload 실패
//   6  = render pipeline 생성 실패
//   7  = drawable/frame 생성 실패
//   8  = readback 인프라 실패(buffer/blit/contents)
//   9  = readback 픽셀이 clear이거나 일부만 glyph로 보임
//   10 = screenshot artifact 쓰기 실패
//  -1  = 아직 실행되지 않음
void maru_macos_glyph_text_smoke_run(
    uint32_t duration_ms,
    const MaruGlyphTextAppearance *appearance,
    const char *screenshot_path,
    size_t screenshot_path_len,
    MaruGlyphTextSmokeResult *result
) {
    if (result == NULL) {
        return;
    }
    maru_clear_result(result);

    // appearance가 NULL이면(방어적) 기존 기본 색(dark background + 흰 glyph)으로 진행한다.
    // 15/20/31은 옛 clear color(0.06,0.08,0.12)*255 근사값이라 기본 동작이 유지된다.
    const MaruGlyphTextAppearance default_appearance = {
        .background_r = 15,
        .background_g = 20,
        .background_b = 31,
        .foreground_r = 255,
        .foreground_g = 255,
        .foreground_b = 255,
        .cursor_r = 255,
        .cursor_g = 255,
        .cursor_b = 255,
    };
    const MaruGlyphTextAppearance *appr =
        (appearance != NULL) ? appearance : &default_appearance;

    @autoreleasepool {
        MaruGlyphTextBitmap bitmap = {0};
        int status = maru_make_coretext_bitmap(result, appr, &bitmap);
        if (status != 0) {
            result->status = status;
            maru_free_bitmap(&bitmap);
            return;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];

        if ([[NSScreen screens] count] == 0) {
            result->status = 1;
            maru_free_bitmap(&bitmap);
            return;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            result->status = 3;
            maru_free_bitmap(&bitmap);
            return;
        }
        result->metal_device_created = 1;

        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (queue == nil) {
            result->status = 4;
            maru_free_bitmap(&bitmap);
            return;
        }
        result->command_queue_created = 1;

        id<MTLTexture> glyph_texture = maru_make_glyph_texture(device, &bitmap, result);
        if (glyph_texture == nil) {
            result->status = 5;
            maru_free_bitmap(&bitmap);
            return;
        }

        NSRect frame = NSMakeRect(300.0, 300.0, 720.0, 420.0);
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
            maru_free_bitmap(&bitmap);
            return;
        }

        NSView *content = [[NSView alloc]
            initWithFrame:NSMakeRect(0.0, 0.0, frame.size.width, frame.size.height)];

        CAMetalLayer *metal_layer = [CAMetalLayer layer];
        metal_layer.device = device;
        metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        // drawable의 glyph ink 위치를 blit-readback해야 하므로 render target 전용
        // 최적화인 framebufferOnly를 이 smoke에서는 끈다.
        metal_layer.framebufferOnly = NO;
        metal_layer.contentsScale = window.backingScaleFactor;
        // 제품 frame probe(Zig)가 같은 backing scale로 glyph atlas key를 준비하도록 실제
        // 창이 쓴 scale을 x100 정수로 남긴다. pipeline/draw가 뒤에서 실패해도 이 값은 남는다.
        // AppKit은 backingScaleFactor를 보통 1.0~3.0으로 보장하지만, 손상된/비표준 디스플레이
        // 값(음수·NaN·과도한 값)이 float -> uint32 캐스트 UB(C11 6.3.1.4)로 이어지지 않게
        // sane 범위로 먼저 막는다. Zig deviceScaleFromNative가 다시 [1,8]로 clamp하지만,
        // 캐스트 자체를 정의된 상태로 두는 것이 Zig 쪽 방어 clamp와 대칭이다.
        double backing_scale = window.backingScaleFactor;
        if (!(backing_scale > 0.0)) backing_scale = 1.0; // 음수/NaN 방어(NaN은 모든 비교가 false)
        if (backing_scale > 80.0) backing_scale = 80.0; // 실제 디스플레이 scale보다 충분히 큰 상한
        result->backing_scale_x100 = (uint32_t)(backing_scale * 100.0 + 0.5);
        metal_layer.frame = content.bounds;
        metal_layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        metal_layer.drawableSize = CGSizeMake(
            content.bounds.size.width * window.backingScaleFactor,
            content.bounds.size.height * window.backingScaleFactor
        );

        id<MTLRenderPipelineState> pipeline = maru_make_glyph_text_pipeline(
            device,
            metal_layer.pixelFormat
        );
        if (pipeline == nil) {
            result->status = 6;
            maru_free_bitmap(&bitmap);
            return;
        }
        result->pipeline_created = 1;

        char *screenshot_path_copy = maru_copy_path(screenshot_path, screenshot_path_len);
        if (screenshot_path_copy == NULL) {
            result->screenshot_failures += 1;
        }

        content.layer = metal_layer;
        content.wantsLayer = YES;
        [window setTitle:@"Maru glyph text smoke"];
        [window setReleasedWhenClosed:NO];
        [window setContentView:content];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        NSTimeInterval seconds = ((NSTimeInterval)duration_ms) / 1000.0;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

        do {
            @autoreleasepool {
                maru_pump_app_once();
                CGFloat scale = window.backingScaleFactor;
                metal_layer.contentsScale = scale;
                metal_layer.drawableSize = CGSizeMake(
                    content.bounds.size.width * scale,
                    content.bounds.size.height * scale
                );
                (void)maru_draw_glyph_text_frame(
                    metal_layer,
                    queue,
                    pipeline,
                    glyph_texture,
                    &bitmap,
                    appr,
                    screenshot_path_copy,
                    result
                );
            }
        } while ([[NSDate date] compare:deadline] == NSOrderedAscending);

        BOOL became_visible = [window isVisible];
        result->window_visible = became_visible ? 1 : 0;
        [window orderOut:nil];
        free(screenshot_path_copy);
        maru_free_bitmap(&bitmap);

        if (!became_visible) {
            result->status = 1;
            return;
        }
        if (result->presented_frames == 0) {
            result->status = 7;
            return;
        }
        if (result->readback_failures > 0) {
            result->status = 8;
            return;
        }
        if (result->readback_samples == 0 ||
            result->readback_non_clear_pixels != result->readback_samples ||
            result->glyph_text_drawn == 0)
        {
            result->status = 9;
            return;
        }
        if (result->screenshot_written == 0 || result->screenshot_failures > 0) {
            result->status = 10;
            return;
        }

        result->status = 0;
    }
}
