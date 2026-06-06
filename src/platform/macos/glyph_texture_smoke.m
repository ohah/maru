#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int32_t status;
    uint32_t metal_device_created;
    uint32_t command_queue_created;
    uint32_t source_rasterized;
    uint32_t texture_created;
    uint32_t texture_uploaded;
    uint32_t texture_readback;
    uint32_t source_width;
    uint32_t source_height;
    uint32_t source_non_clear_pixels;
    uint32_t texture_non_clear_pixels;
    uint32_t texture_mismatched_pixels;
    uint32_t upload_bytes;
    uint32_t readback_failures;
} MaruGlyphTextureSmokeResult;

typedef struct {
    uint8_t *pixels;
    size_t width;
    size_t height;
    size_t bytes_per_row;
    size_t byte_count;
    uint32_t non_clear_pixels;
} MaruGlyphTextureBitmap;

static void maru_clear_result(MaruGlyphTextureSmokeResult *result) {
    result->status = -1;
    result->metal_device_created = 0;
    result->command_queue_created = 0;
    result->source_rasterized = 0;
    result->texture_created = 0;
    result->texture_uploaded = 0;
    result->texture_readback = 0;
    result->source_width = 0;
    result->source_height = 0;
    result->source_non_clear_pixels = 0;
    result->texture_non_clear_pixels = 0;
    result->texture_mismatched_pixels = 0;
    result->upload_bytes = 0;
    result->readback_failures = 0;
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

static void maru_free_bitmap(MaruGlyphTextureBitmap *bitmap) {
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

static uint32_t maru_count_mismatched_bytes(
    const uint8_t *left,
    const uint8_t *right,
    size_t byte_count
) {
    uint32_t mismatches = 0;
    for (size_t index = 0; index < byte_count; index++) {
        if (left[index] != right[index]) {
            mismatches += 1;
        }
    }
    return mismatches;
}

static int maru_make_coretext_bitmap(
    MaruGlyphTextureSmokeResult *result,
    MaruGlyphTextureBitmap *bitmap
) {
    // 이 bitmap은 제품 atlas가 아니다. CoreText가 만든 실제 glyph pixels를 Metal
    // texture upload smoke의 입력으로 쓰기 위한 작은 fixture다. 제품 renderer가
    // 들어오면 atlas packing/eviction은 별도 모듈에서 소유한다.
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

    const void *keys[] = { kCTFontAttributeName };
    const void *values[] = { font };
    CFDictionaryRef attributes = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (attributes == NULL) {
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
        CFRelease(probe);
        CFRelease(font);
        return 2;
    }

    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    if (line == NULL) {
        CFRelease(attributed);
        CFRelease(attributes);
        CFRelease(probe);
        CFRelease(font);
        return 2;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == NULL) {
        CFRelease(line);
        CFRelease(attributed);
        CFRelease(attributes);
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
        CFRelease(probe);
        CFRelease(font);
        return 2;
    }

    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextSetShouldAntialias(context, true);
    CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
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
    CFRelease(probe);
    CFRelease(font);

    return bitmap->non_clear_pixels > 0 ? 0 : 2;
}

static int maru_upload_and_readback_texture(
    MaruGlyphTextureSmokeResult *result,
    const MaruGlyphTextureBitmap *bitmap
) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
        return 3;
    }
    result->metal_device_created = 1;

    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (queue == nil) {
        return 4;
    }
    result->command_queue_created = 1;

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:bitmap->width
                                    height:bitmap->height
                                 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;

    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (texture == nil) {
        return 5;
    }
    result->texture_created = 1;

    [texture replaceRegion:MTLRegionMake2D(0, 0, bitmap->width, bitmap->height)
               mipmapLevel:0
                 withBytes:bitmap->pixels
               bytesPerRow:bitmap->bytes_per_row];
    result->texture_uploaded = 1;
    // upload_bytes는 "실제로 texture에 올린 byte 수"를 뜻해야 한다. 그래서 source bitmap을
    // 만들 때가 아니라 replaceRegion이 끝난 직후에 기록한다. device가 없어 upload가
    // 일어나지 않은 run에서는 0으로 남아, summary만 보고 "GPU에 올린 게 없다"를 구분할 수 있다.
    result->upload_bytes = (bitmap->byte_count > UINT32_MAX) ? UINT32_MAX : (uint32_t)bitmap->byte_count;

    id<MTLBuffer> readback_buffer = [device
        newBufferWithLength:bitmap->byte_count
                    options:MTLResourceStorageModeShared];
    if (readback_buffer == nil) {
        result->readback_failures += 1;
        return 6;
    }

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    if (command_buffer == nil) {
        result->readback_failures += 1;
        return 6;
    }

    id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
    if (blit == nil) {
        result->readback_failures += 1;
        return 6;
    }

    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(bitmap->width, bitmap->height, 1)
                 toBuffer:readback_buffer
        destinationOffset:0
   destinationBytesPerRow:bitmap->bytes_per_row
 destinationBytesPerImage:bitmap->byte_count];
    [blit endEncoding];

    [command_buffer commit];
    [command_buffer waitUntilCompleted];

    const uint8_t *readback = (const uint8_t *)[readback_buffer contents];
    if (readback == NULL) {
        result->readback_failures += 1;
        return 6;
    }

    result->texture_readback = 1;
    result->texture_non_clear_pixels = maru_count_non_clear_rgba_pixels(readback, bitmap->byte_count);
    result->texture_mismatched_pixels = maru_count_mismatched_bytes(
        bitmap->pixels,
        readback,
        bitmap->byte_count
    );

    return result->texture_non_clear_pixels == result->source_non_clear_pixels &&
            result->texture_mismatched_pixels == 0
        ? 0
        : 7;
}

// result->status는 어느 단계에서 멈췄는지 summary(native_status/native_status_label)로
// 분리하기 위한 값이다. 새 값을 추가하면 glyph_texture_smoke.zig의 nativeStatusLabel도
// 같이 갱신해야 artifact와 native bridge가 같은 말을 한다:
//   0  = 성공(raster + upload + readback + byte 일치)
//   2  = CoreText/CoreGraphics CPU bitmap raster 실패(폰트/컨텍스트 생성 또는 0-ink)
//   3  = Metal device 생성 실패(headless/GPU 없음)
//   4  = command queue 생성 실패
//   5  = texture 생성 실패(예: storage mode 미지원)
//   6  = readback 인프라 실패(buffer/command buffer/blit encoder/contents가 nil)
//   7  = readback 픽셀이 source bitmap과 불일치
//  -1  = 아직 실행되지 않음
void maru_macos_glyph_texture_smoke_run(MaruGlyphTextureSmokeResult *result) {
    @autoreleasepool {
        if (result == NULL) {
            return;
        }
        maru_clear_result(result);

        MaruGlyphTextureBitmap bitmap = {0};
        int status = maru_make_coretext_bitmap(result, &bitmap);
        if (status == 0) {
            status = maru_upload_and_readback_texture(result, &bitmap);
        }

        result->status = status;
        maru_free_bitmap(&bitmap);
    }
}
