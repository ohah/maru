#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct {
    int32_t status;
    uint32_t primary_font_found;
    uint32_t requested_font_matched;
    uint32_t line_created;
    uint32_t run_count;
    uint32_t glyph_count;
    uint32_t fallback_run_count;
    uint32_t ascii_glyph_present;
    uint32_t cjk_glyph_present;
    uint32_t emoji_glyph_present;
    uint32_t missing_glyph_count;
    uint32_t glyph_record_count;
    uint32_t glyph_record_overflow;
    uint32_t glyph_rasterized;
    uint32_t raster_width;
    uint32_t raster_height;
    uint32_t raster_non_clear_pixels;
    uint32_t raster_failures;
    char primary_font_name[128];
    char first_fallback_font_name[128];
} MaruCoreTextSmokeResult;

typedef struct {
    uint32_t font_id;
    uint32_t glyph_id;
    uint32_t string_index;
    uint32_t category;
    uint32_t fallback;
    char font_name[128];
} MaruCoreTextGlyphRecord;

typedef struct {
    uint16_t row;
    uint16_t col;
    uint16_t width;
    // 스타일 플래그(비트필드). bit0(MaruDrawCellBoldBit)=bold. Zig NativeDrawCell.style_flags와
    // 같은 16바이트 레이아웃 — bold cell은 bold 폰트 face로 셰이핑해 굵은 glyph를 만든다.
    uint16_t style_flags;
    uint32_t codepoint;
    uint32_t combining;
} MaruCoreTextDrawCell;

enum {
    MaruDrawCellBoldBit = 1u << 0,
};

typedef struct {
    uint32_t cell_index;
    uint16_t row;
    uint16_t col;
    uint16_t cell_width;
    uint16_t reserved;
    uint32_t codepoint;
    uint32_t combining;
    uint32_t glyph_id;
    uint32_t drawable;
    uint32_t fallback;
    uint32_t color_glyph_kind;
    char font_name[128];
} MaruCoreTextDrawGlyphRecord;

typedef struct {
    int32_t status;
    uint32_t primary_font_found;
    uint32_t requested_font_matched;
    uint32_t shaped_cell_count;
    uint32_t glyph_record_count;
    uint32_t glyph_record_overflow;
    uint32_t missing_glyph_count;
    uint32_t fallback_run_count;
} MaruCoreTextDrawListShapeResult;

typedef struct {
    int32_t status;
    uint32_t non_clear_pixels;
} MaruCoreTextGlyphRasterResult;

enum {
    MaruGlyphCategoryAscii = 1,
    MaruGlyphCategoryCjk = 2,
    MaruGlyphCategoryEmoji = 3,
    MaruGlyphCategorySpace = 4,
    MaruGlyphCategoryOther = 5,
};

static void maru_clear_result(MaruCoreTextSmokeResult *result) {
    result->status = -1;
    result->primary_font_found = 0;
    result->requested_font_matched = 0;
    result->line_created = 0;
    result->run_count = 0;
    result->glyph_count = 0;
    result->fallback_run_count = 0;
    result->ascii_glyph_present = 0;
    result->cjk_glyph_present = 0;
    result->emoji_glyph_present = 0;
    result->missing_glyph_count = 0;
    result->glyph_record_count = 0;
    result->glyph_record_overflow = 0;
    result->glyph_rasterized = 0;
    result->raster_width = 0;
    result->raster_height = 0;
    result->raster_non_clear_pixels = 0;
    result->raster_failures = 0;
    result->primary_font_name[0] = '\0';
    result->first_fallback_font_name[0] = '\0';
}

static bool maru_copy_cfstring(CFStringRef value, char *buffer, size_t capacity) {
    if (capacity == 0) {
        return false;
    }
    buffer[0] = '\0';
    if (value == NULL) {
        return false;
    }
    if (!CFStringGetCString(value, buffer, capacity, kCFStringEncodingUTF8)) {
        buffer[0] = '\0';
        return false;
    }
    return true;
}

static CFStringRef maru_create_probe_string(void) {
    // 소스 파일 인코딩이나 컴파일러 universal-character-name 처리에 기대지 않으려고
    // probe 문자열을 UTF-8 바이트로 둔다. 내용은 "Maru ", 한글 "한", 공백, 사과
    // emoji다. ASCII/CJK/emoji가 한 줄에서 같이 shape되는지를 확인하기 위한 입력이다.
    static const UInt8 bytes[] = {
        'M', 'a', 'r', 'u', ' ',
        0xED, 0x95, 0x9C,
        ' ',
        0xF0, 0x9F, 0x8D, 0x8E,
    };
    return CFStringCreateWithBytes(
        kCFAllocatorDefault,
        bytes,
        sizeof(bytes),
        kCFStringEncodingUTF8,
        false
    );
}

static CFStringRef maru_create_font_name(const char *font_family, size_t font_family_len) {
    if (font_family == NULL || font_family_len == 0) {
        return NULL;
    }
    return CFStringCreateWithBytes(
        kCFAllocatorDefault,
        (const UInt8 *)font_family,
        (CFIndex)font_family_len,
        kCFStringEncodingUTF8,
        false
    );
}

static bool maru_cfstring_equals_requested(CFStringRef actual, CFStringRef requested) {
    if (actual == NULL || requested == NULL) {
        return false;
    }
    return CFStringCompare(actual, requested, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
}

static bool maru_font_matches_requested(CTFontRef font, CFStringRef requested_name) {
    if (font == NULL || requested_name == NULL) {
        return false;
    }

    bool matched = false;

    CFStringRef family_name = CTFontCopyFamilyName(font);
    if (maru_cfstring_equals_requested(family_name, requested_name)) {
        matched = true;
    }
    if (family_name != NULL) {
        CFRelease(family_name);
    }

    if (matched) {
        return true;
    }

    CFStringRef postscript_name = CTFontCopyPostScriptName(font);
    if (maru_cfstring_equals_requested(postscript_name, requested_name)) {
        matched = true;
    }
    if (postscript_name != NULL) {
        CFRelease(postscript_name);
    }

    if (matched) {
        return true;
    }

    CFStringRef full_name = CTFontCopyFullName(font);
    if (maru_cfstring_equals_requested(full_name, requested_name)) {
        matched = true;
    }
    if (full_name != NULL) {
        CFRelease(full_name);
    }

    return matched;
}

static bool maru_font_postscript_name_matches(CTFontRef font, CFStringRef expected_name) {
    if (font == NULL || expected_name == NULL) {
        return false;
    }

    bool matched = false;
    CFStringRef actual_name = CTFontCopyPostScriptName(font);
    if (actual_name != NULL) {
        matched = CFStringCompare(actual_name, expected_name, 0) == kCFCompareEqualTo;
        CFRelease(actual_name);
    }
    return matched;
}

static CTFontRef maru_create_primary_font(
    const char *font_family,
    size_t font_family_len,
    double font_size,
    uint32_t *requested_font_matched
) {
    // Zig의 ResolvedAppearance가 빈 family와 잘못된 크기를 먼저 거른다. 이 native smoke는
    // 그 resolved 요청을 CoreText 경계까지 전달하는지 보는 단계다. CoreText는 요청 font가
    // 없어도 Helvetica 같은 대체 font를 돌려줄 수 있으므로 실제 이름/family까지 맞는지
    // 확인한다. 맞지 않으면 그 대체 font를 primary로 쓰지 않고 macOS system monospace로
    // 명시적으로 물러난다.
    CFStringRef requested_name = maru_create_font_name(font_family, font_family_len);
    if (requested_name != NULL) {
        CTFontRef requested_font = CTFontCreateWithName(requested_name, (CGFloat)font_size, NULL);
        if (requested_font != NULL) {
            if (maru_font_matches_requested(requested_font, requested_name)) {
                if (requested_font_matched != NULL) {
                    *requested_font_matched = 1;
                }
                CFRelease(requested_name);
                return requested_font;
            }
            CFRelease(requested_font);
        }
        CFRelease(requested_name);
    }

    CTFontRef system_font = CTFontCreateUIFontForLanguage(
        kCTFontUIFontUserFixedPitch,
        (CGFloat)font_size,
        NULL
    );
    if (system_font != NULL) {
        return system_font;
    }
    return CTFontCreateWithName(CFSTR("Menlo-Regular"), (CGFloat)font_size, NULL);
}

typedef struct {
    int32_t status;
    uint32_t cell_width_px;
    uint32_t cell_height_px;
    uint32_t ascent_px;
    uint32_t descent_px;
} MaruCoreTextCellMetrics;

// 모노스페이스 cell 메트릭(advance 폭 × line-height)을 device 픽셀로 돌려준다. font_size_px는
// 이미 device_scale이 곱해진(예: 14pt × 2 = 28) device 크기다. dev session이 atlas slot 크기와
// 화면 cell 크기를 모두 이 값으로 맞춰, glyph가 정확한 모노스페이스 격자로 그려진다.
void maru_macos_coretext_font_cell_metrics(
    const char *requested_font_family,
    size_t requested_font_family_len,
    double font_size_px,
    MaruCoreTextCellMetrics *result
) {
    @autoreleasepool {
        if (result == NULL) {
            return;
        }
        result->status = -1;
        result->cell_width_px = 0;
        result->cell_height_px = 0;
        result->ascent_px = 0;
        result->descent_px = 0;

        uint32_t matched = 0;
        CTFontRef font = maru_create_primary_font(
            requested_font_family,
            requested_font_family_len,
            font_size_px,
            &matched
        );
        if (font == NULL) {
            result->status = 1;
            return;
        }

        const CGFloat ascent = CTFontGetAscent(font);
        const CGFloat descent = CTFontGetDescent(font);
        const CGFloat leading = CTFontGetLeading(font);

        // 모노스페이스 폰트는 모든 glyph advance가 같다. 대표 glyph('M')의 advance를 cell 폭으로
        // 쓴다. glyph 조회/advance가 실패하면 0.6em 근사로 물러난다.
        UniChar character = (UniChar)'M';
        CGGlyph glyph = 0;
        CGFloat advance = 0.0;
        if (CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) && glyph != 0) {
            advance = CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, NULL, 1);
        }
        if (!(advance > 0.0)) {
            advance = font_size_px * 0.6;
        }

        CGFloat line_height = ascent + descent + leading;
        if (!(line_height > 0.0)) {
            line_height = font_size_px * 1.2;
        }

        result->cell_width_px = (uint32_t)lround((double)advance);
        result->cell_height_px = (uint32_t)lround((double)line_height);
        result->ascent_px = (uint32_t)lround((double)ascent);
        result->descent_px = (uint32_t)lround((double)descent);
        result->status = 0;
        CFRelease(font);
    }
}

static uint32_t maru_u32_from_cfindex(CFIndex value) {
    if (value <= 0) {
        return 0;
    }
    if (value > UINT32_MAX) {
        return UINT32_MAX;
    }
    return (uint32_t)value;
}

static uint32_t maru_category_for_string_index(CFIndex string_index) {
    if (string_index >= 0 && string_index <= 3) {
        return MaruGlyphCategoryAscii;
    }
    if (string_index == 5) {
        return MaruGlyphCategoryCjk;
    }
    if (string_index >= 7 && string_index <= 8) {
        return MaruGlyphCategoryEmoji;
    }
    if (string_index == 4 || string_index == 6) {
        return MaruGlyphCategorySpace;
    }
    return MaruGlyphCategoryOther;
}

static uint32_t maru_category_for_codepoint(uint32_t codepoint) {
    if (codepoint == 0 || codepoint == ' ') {
        return MaruGlyphCategorySpace;
    }
    if (codepoint < 0x80) {
        return MaruGlyphCategoryAscii;
    }
    if ((codepoint >= 0x3000 && codepoint <= 0x9FFF) ||
        (codepoint >= 0xAC00 && codepoint <= 0xD7AF))
    {
        return MaruGlyphCategoryCjk;
    }
    if (codepoint >= 0x1F300 && codepoint <= 0x1FAFF) {
        return MaruGlyphCategoryEmoji;
    }
    return MaruGlyphCategoryOther;
}

/* Zig renderer가 코드포인트로 직접 합성하는 글리프(폰트 글리프 불요)인지. **renderer/block_glyph.zig·
   box_glyph.zig의 집합과 동기 유지**(거기 추가하면 여기도). CoreText가 글리프를 못 줘도(glyph==0) 이
   코드포인트는 record를 남겨야 rasterizer 합성에 도달한다(안 그러면 셰이퍼가 드롭 → 보더가 안 보임). */
static bool maru_is_synthesized_glyph(uint32_t cp) {
    // block_glyph: solid block(eighth/half/full/quadrant), shade ░▒▓(2591~2593)는 제외.
    if ((cp >= 0x2580 && cp <= 0x2590) || (cp >= 0x2594 && cp <= 0x259F)) {
        return true;
    }
    // box_glyph: light single(─│┌┐└┘├┤┬┴┼·둥근 ╭╮╰╯) + heavy(━┃┏┓┗┛┣┫┳┻╋) + dashed(┄┅┆┇┈┉┊┋╌╍╎╏)
    // + double(═║╔╗╚╝╠╣╦╩╬). 혼합 굵기(┍┎…)·single↔double 혼합(╒╓…)은 box_glyph가 아직 안 덮어 폴백.
    switch (cp) {
        // light single
        case 0x2500: case 0x2502: case 0x250C: case 0x2510:
        case 0x2514: case 0x2518: case 0x251C: case 0x2524:
        case 0x252C: case 0x2534: case 0x253C:
        case 0x256D: case 0x256E: case 0x256F: case 0x2570:
        // heavy
        case 0x2501: case 0x2503: case 0x250F: case 0x2513:
        case 0x2517: case 0x251B: case 0x2523: case 0x252B:
        case 0x2533: case 0x253B: case 0x254B:
        // dashed
        case 0x2504: case 0x2505: case 0x2506: case 0x2507:
        case 0x2508: case 0x2509: case 0x250A: case 0x250B:
        case 0x254C: case 0x254D: case 0x254E: case 0x254F:
        // double
        case 0x2550: case 0x2551: case 0x2554: case 0x2557:
        case 0x255A: case 0x255D: case 0x2560: case 0x2563:
        case 0x2566: case 0x2569: case 0x256C:
            return true;
        default:
            return false;
    }
}

static bool maru_append_utf16_scalar(uint32_t codepoint, UniChar *buffer, CFIndex *len, CFIndex capacity) {
    if (buffer == NULL || len == NULL) {
        return false;
    }
    if (codepoint > 0x10FFFF || (codepoint >= 0xD800 && codepoint <= 0xDFFF)) {
        return false;
    }
    if (codepoint <= 0xFFFF) {
        if (*len >= capacity) {
            return false;
        }
        buffer[*len] = (UniChar)codepoint;
        *len += 1;
        return true;
    }

    if (*len + 1 >= capacity) {
        return false;
    }
    uint32_t value = codepoint - 0x10000;
    buffer[*len] = (UniChar)(0xD800 + (value >> 10));
    *len += 1;
    buffer[*len] = (UniChar)(0xDC00 + (value & 0x3FF));
    *len += 1;
    return true;
}

static CFStringRef maru_create_string_for_draw_cell(MaruCoreTextDrawCell cell) {
    UniChar units[4];
    CFIndex len = 0;
    if (!maru_append_utf16_scalar(cell.codepoint, units, &len, 4)) {
        return NULL;
    }
    if (cell.combining != 0 && !maru_append_utf16_scalar(cell.combining, units, &len, 4)) {
        return NULL;
    }
    return CFStringCreateWithCharacters(kCFAllocatorDefault, units, len);
}

static bool maru_validate_raster_request(
    const uint8_t *pixels,
    size_t width,
    size_t height,
    size_t bytes_per_row,
    size_t pixel_capacity,
    size_t *byte_count
) {
    if (pixels == NULL || byte_count == NULL) {
        return false;
    }
    if (width == 0 || height == 0 || bytes_per_row == 0) {
        return false;
    }
    if (width > SIZE_MAX / 4) {
        return false;
    }

    const size_t tight_row = width * 4;
    if (bytes_per_row < tight_row) {
        return false;
    }
    if (height > SIZE_MAX / bytes_per_row) {
        return false;
    }

    const size_t needed = height * bytes_per_row;
    if (needed > pixel_capacity) {
        return false;
    }

    *byte_count = needed;
    return true;
}

static uint32_t maru_count_non_clear_rgba_pixels(
    const uint8_t *pixels,
    size_t width,
    size_t height,
    size_t bytes_per_row
) {
    uint32_t count = 0;
    for (size_t y = 0; y < height; y++) {
        const uint8_t *row = pixels + y * bytes_per_row;
        for (size_t x = 0; x < width; x++) {
            const uint8_t alpha = row[x * 4 + 3];
            if (alpha != 0 && count < UINT32_MAX) {
                count += 1;
            }
        }
    }
    return count;
}

static void maru_append_glyph_record(
    MaruCoreTextSmokeResult *result,
    MaruCoreTextGlyphRecord *records,
    size_t record_capacity,
    uint32_t font_id,
    CFStringRef font_name,
    CGGlyph glyph,
    CFIndex string_index,
    uint32_t fallback
) {
    if (records == NULL || result->glyph_record_count >= record_capacity) {
        result->glyph_record_overflow = 1;
        return;
    }

    const uint32_t category = maru_category_for_string_index(string_index);
    const bool drawable = glyph != 0 && category != MaruGlyphCategorySpace;

    MaruCoreTextGlyphRecord *record = &records[result->glyph_record_count];
    record->font_id = font_id;
    record->glyph_id = (uint32_t)glyph;
    record->string_index = maru_u32_from_cfindex(string_index);
    record->category = category;
    record->fallback = fallback;
    if (!maru_copy_cfstring(font_name, record->font_name, sizeof(record->font_name)) && drawable) {
        // Drawable glyph의 PostScript name이 없으면 Zig registry가 어떤 face의 glyph인지
        // 알 수 없다. 공백처럼 rasterizer까지 가지 않는 record는 best-effort 진단으로
        // 남기지만, 실제 glyph는 wrong-glyph를 만들기 전에 incomplete shape로 닫는다.
        result->glyph_record_overflow = 1;
        record->font_name[0] = '\0';
        return;
    }
    result->glyph_record_count += 1;
}

static void maru_append_draw_glyph_record(
    MaruCoreTextDrawListShapeResult *result,
    MaruCoreTextDrawGlyphRecord *records,
    size_t record_capacity,
    size_t cell_index,
    MaruCoreTextDrawCell cell,
    CFStringRef font_name,
    CGGlyph glyph,
    uint32_t fallback
) {
    if (records == NULL || result->glyph_record_count >= record_capacity || cell_index > UINT32_MAX) {
        result->glyph_record_overflow = 1;
        return;
    }

    const uint32_t category = maru_category_for_codepoint(cell.codepoint);
    // 합성 대상(box-drawing·block)은 폰트가 글리프를 못 줘도(glyph==0) Zig rasterizer가 코드포인트로 직접
    // 그린다 → record를 남겨야 한다(여기서 드롭하면 보더가 안 보임). glyph_id=0이어도 rasterizer는 코드포인트
    // 분기라 무시한다.
    const bool synth = (glyph == 0) && maru_is_synthesized_glyph(cell.codepoint);
    const bool drawable = (glyph != 0 || synth) &&
        category != MaruGlyphCategorySpace &&
        cell.width != 0;
    if (glyph == 0 && !synth) {
        result->missing_glyph_count += 1;
        return;
    }

    MaruCoreTextDrawGlyphRecord *record = &records[result->glyph_record_count];
    record->cell_index = (uint32_t)cell_index;
    record->row = cell.row;
    record->col = cell.col;
    record->cell_width = cell.width;
    record->reserved = 0;
    record->codepoint = cell.codepoint;
    record->combining = cell.combining;
    record->glyph_id = (uint32_t)glyph;
    record->drawable = drawable ? 1 : 0;
    record->fallback = fallback;
    record->color_glyph_kind = category == MaruGlyphCategoryEmoji ? 1 : 0;
    if (!maru_copy_cfstring(font_name, record->font_name, sizeof(record->font_name))) {
        record->font_name[0] = '\0';
        // 합성(synth) 글리프는 font_name이 불요하다(rasterizer가 코드포인트로 그림) → 복사 실패로 드롭하지
        // 않는다. 일반 drawable 글리프만 폰트명이 없으면 overflow로 드롭(렌더가 폰트를 못 찾으니).
        if (drawable && !synth) {
            result->glyph_record_overflow = 1;
            return;
        }
    }
    result->glyph_record_count += 1;
}

static void maru_record_probe_glyph(
    MaruCoreTextSmokeResult *result,
    MaruCoreTextGlyphRecord *records,
    size_t record_capacity,
    uint32_t font_id,
    CFStringRef font_name,
    CGGlyph glyph,
    CFIndex string_index,
    uint32_t fallback
) {
    // CTRunGetGlyphCount는 .notdef도 glyph로 센다. 그래서 glyph id 0을 따로 세고,
    // probe 문자열의 UTF-16 index별로 실제 glyph가 붙었는지 확인한다.
    //
    // probe: "Maru 한 🍎"
    // UTF-16 index:
    //   0..3 = ASCII "Maru"
    //   5    = CJK "한"
    //   7..8 = emoji surrogate pair "🍎"
    if (glyph == 0) {
        result->missing_glyph_count += 1;
        return;
    }

    maru_append_glyph_record(result, records, record_capacity, font_id, font_name, glyph, string_index, fallback);

    if (string_index >= 0 && string_index <= 3) {
        result->ascii_glyph_present = 1;
    } else if (string_index == 5) {
        result->cjk_glyph_present = 1;
    } else if (string_index >= 7 && string_index <= 8) {
        result->emoji_glyph_present = 1;
    }
}

static void maru_rasterize_line_into_cpu_bitmap(MaruCoreTextSmokeResult *result, CTLineRef line) {
    // 이 smoke는 아직 Metal texture upload를 검증하지 않는다. 대신 CoreText가 만든
    // glyph run을 CPU bitmap에 한 번 그려서 "glyph id가 있다"와 "실제 픽셀이
    // 나온다"를 분리한다. 그래야 다음 Metal text draw 단계에서 실패 원인을
    // font stack, rasterizer, GPU upload 중 어디에서 봐야 하는지 좁힐 수 있다.
    const size_t width = 512;
    const size_t height = 128;
    const size_t bytes_per_pixel = 4;
    const size_t bytes_per_row = width * bytes_per_pixel;
    const size_t byte_count = bytes_per_row * height;

    result->raster_width = (uint32_t)width;
    result->raster_height = (uint32_t)height;

    uint8_t *pixels = (uint8_t *)calloc(byte_count, 1);
    if (pixels == NULL) {
        result->raster_failures += 1;
        return;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == NULL) {
        free(pixels);
        result->raster_failures += 1;
        return;
    }

    CGContextRef context = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        bytes_per_row,
        color_space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    if (context == NULL) {
        CGColorSpaceRelease(color_space);
        free(pixels);
        result->raster_failures += 1;
        return;
    }

    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextSetShouldAntialias(context, true);
    CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
    CGContextSetTextPosition(context, 16.0, 64.0);
    CTLineDraw(line, context);

    uint32_t non_clear_pixels = 0;
    for (size_t offset = 0; offset + 3 < byte_count; offset += bytes_per_pixel) {
        const uint8_t alpha = pixels[offset + 3];
        if (alpha != 0) {
            non_clear_pixels += 1;
        }
    }

    result->raster_non_clear_pixels = non_clear_pixels;
    result->glyph_rasterized = non_clear_pixels > 0 ? 1 : 0;

    CGContextRelease(context);
    CGColorSpaceRelease(color_space);
    free(pixels);
}

void maru_macos_coretext_shape_draw_list(
    const char *requested_font_family,
    size_t requested_font_family_len,
    double requested_font_size,
    const MaruCoreTextDrawCell *cells,
    size_t cell_count,
    MaruCoreTextDrawListShapeResult *result,
    MaruCoreTextDrawGlyphRecord *glyph_records,
    size_t glyph_record_capacity
) {
    @autoreleasepool {
        if (result == NULL) {
            return;
        }
        result->status = -1;
        result->primary_font_found = 0;
        result->requested_font_matched = 0;
        result->shaped_cell_count = 0;
        result->glyph_record_count = 0;
        result->glyph_record_overflow = 0;
        result->missing_glyph_count = 0;
        result->fallback_run_count = 0;

        if (cells == NULL && cell_count != 0) {
            result->status = 1;
            return;
        }

        CTFontRef primary_font = maru_create_primary_font(
            requested_font_family,
            requested_font_family_len,
            requested_font_size,
            &result->requested_font_matched
        );
        if (primary_font == NULL) {
            result->status = 2;
            return;
        }
        result->primary_font_found = 1;

        CFStringRef primary_name = CTFontCopyPostScriptName(primary_font);
        const void *keys[] = { kCTFontAttributeName };
        const void *values[] = { primary_font };
        CFDictionaryRef attributes = CFDictionaryCreate(
            kCFAllocatorDefault,
            keys,
            values,
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
        if (attributes == NULL) {
            if (primary_name != NULL) {
                CFRelease(primary_name);
            }
            CFRelease(primary_font);
            result->status = 3;
            return;
        }

        // bold cell용 폰트 변형. 처음 만나는 bold cell에서 한 번만(lazy) 만든다 — bold cell이 하나도
        // 없는 프레임(흔한 경우: 일반 터미널 출력·탭 제목)은 CoreText 변형 호출을 아예 안 한다.
        // CTFontCreateCopyWithSymbolicTraits는 family에 bold variant가 없으면 NULL을 돌려주며, 그 경우
        // bold cell도 primary(regular)로 폴백한다(없는 굵기를 합성하지 않음). 있으면 bold PostScript
        // name(예: "Menlo-Bold")이 record로 흘러 rasterizer가 그 이름으로 굵은 glyph를 그린다.
        CTFontRef bold_font = NULL;
        CFStringRef bold_name = NULL;
        CFDictionaryRef bold_attributes = NULL;
        bool bold_attempted = false; // bold variant가 없는 폰트면 매 bold cell마다 재시도하지 않게

        for (size_t cell_index = 0; cell_index < cell_count; cell_index++) {
            const MaruCoreTextDrawCell cell = cells[cell_index];
            // 이 cell의 굵기를 정한다. 첫 bold cell에서 bold variant를 만들고(이후 재사용), 없으면(NULL) regular 폴백.
            const bool want_bold = (cell.style_flags & MaruDrawCellBoldBit) != 0;
            if (want_bold && !bold_attempted) {
                bold_attempted = true;
                bold_font = CTFontCreateCopyWithSymbolicTraits(
                    primary_font, 0.0, NULL, kCTFontTraitBold, kCTFontTraitBold);
                if (bold_font != NULL) {
                    bold_name = CTFontCopyPostScriptName(bold_font);
                    const void *bold_values[] = { bold_font };
                    bold_attributes = CFDictionaryCreate(
                        kCFAllocatorDefault,
                        keys,
                        bold_values,
                        1,
                        &kCFTypeDictionaryKeyCallBacks,
                        &kCFTypeDictionaryValueCallBacks
                    );
                }
            }
            const bool use_bold = want_bold && bold_attributes != NULL;
            CFDictionaryRef cell_attributes = use_bold ? bold_attributes : attributes;
            // run의 폰트가 이 cell이 의도한 face와 다르면(진짜 fallback) 표시한다. bold cell은
            // bold_name과 비교해야 bold variant를 fallback으로 오탐하지 않는다.
            CFStringRef expected_name = use_bold ? bold_name : primary_name;
            const uint32_t category = maru_category_for_codepoint(cell.codepoint);
            if (category == MaruGlyphCategorySpace || cell.width == 0) {
                continue;
            }

            // 이 cell이 실제 glyph record를 하나라도 만들었는지 보려고 처리 전 record 수를
            // 기억한다. 모든 glyph가 .notdef(glyph 0)면 record가 안 늘므로 shaped로 세지 않는다.
            const uint32_t records_before_cell = result->glyph_record_count;

            CFStringRef string = maru_create_string_for_draw_cell(cell);
            if (string == NULL) {
                result->missing_glyph_count += 1;
                continue;
            }

            CFAttributedStringRef attributed = CFAttributedStringCreate(
                kCFAllocatorDefault,
                string,
                cell_attributes
            );
            if (attributed == NULL) {
                CFRelease(string);
                result->status = 4;
                break;
            }

            CTLineRef line = CTLineCreateWithAttributedString(attributed);
            if (line == NULL) {
                CFRelease(attributed);
                CFRelease(string);
                result->status = 5;
                break;
            }

            CFArrayRef runs = CTLineGetGlyphRuns(line);
            CFIndex run_count = runs == NULL ? 0 : CFArrayGetCount(runs);
            for (CFIndex run_index = 0; run_index < run_count; run_index++) {
                CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, run_index);
                if (run == NULL) {
                    continue;
                }

                uint32_t run_fallback = 0;
                CFStringRef run_name = NULL;
                CFDictionaryRef run_attributes = CTRunGetAttributes(run);
                CTFontRef run_font = run_attributes == NULL
                    ? NULL
                    : (CTFontRef)CFDictionaryGetValue(run_attributes, kCTFontAttributeName);
                if (run_font != NULL) {
                    run_name = CTFontCopyPostScriptName(run_font);
                    if (run_name != NULL &&
                        expected_name != NULL &&
                        CFStringCompare(run_name, expected_name, 0) != kCFCompareEqualTo)
                    {
                        run_fallback = 1;
                        result->fallback_run_count += 1;
                    }
                }
                CFStringRef record_font_name = run_name != NULL ? run_name : expected_name;

                CFIndex glyph_count = CTRunGetGlyphCount(run);
                if (glyph_count > 16) {
                    result->glyph_record_overflow = 1;
                    result->status = 7;
                    if (run_name != NULL) {
                        CFRelease(run_name);
                    }
                    break;
                }

                CGGlyph glyphs[16];
                CTRunGetGlyphs(run, CFRangeMake(0, glyph_count), glyphs);
                for (CFIndex glyph_index = 0; glyph_index < glyph_count; glyph_index++) {
                    maru_append_draw_glyph_record(
                        result,
                        glyph_records,
                        glyph_record_capacity,
                        cell_index,
                        cell,
                        record_font_name,
                        glyphs[glyph_index],
                        run_fallback
                    );
                    if (result->glyph_record_overflow != 0) {
                        result->status = 7;
                        break;
                    }
                }

                if (run_name != NULL) {
                    CFRelease(run_name);
                }
                if (result->status == 7) {
                    break;
                }
            }

            // glyph record를 하나라도 만든 cell만 shaped로 센다. CTLine/run은 만들어졌지만
            // 모든 glyph가 .notdef라 record가 0개인 cell은 "shape됨"이 아니라 missing이다.
            if (result->status == -1 && result->glyph_record_count > records_before_cell) {
                result->shaped_cell_count += 1;
            }

            CFRelease(line);
            CFRelease(attributed);
            CFRelease(string);

            if (result->status == 4 || result->status == 5 || result->status == 7) {
                break;
            }
        }

        if (result->status == -1) {
            result->status = result->glyph_record_overflow == 0 &&
                    result->missing_glyph_count == 0
                ? 0
                : 6;
        }

        CFRelease(attributes);
        if (bold_attributes != NULL) {
            CFRelease(bold_attributes);
        }
        if (bold_name != NULL) {
            CFRelease(bold_name);
        }
        if (bold_font != NULL) {
            CFRelease(bold_font);
        }
        if (primary_name != NULL) {
            CFRelease(primary_name);
        }
        CFRelease(primary_font);
    }
}

// 컬러 이모지 codepoint인지(축소-맞춤을 이모지에만 적용하기 위함 — 텍스트는 baseline 정렬 유지).
// 글리프가 컬러 이모지인지 — 그린 폰트가 컬러 글리프 테이블(sbix/COLR)을 가졌는지로 판정한다.
// codepoint 휴리스틱(단색 텍스트 기호를 잘못 포함, ❤+VS16의 base U+2764를 놓침)보다 정확하다:
// 셰이퍼가 이미 이모지/텍스트 폰트를 골라줬으므로, 그 폰트가 컬러면 이 글리프는 컬러 이모지다.
// 이모지에만 scale-맞춤(.cover)을 적용해 단색 텍스트(한글/CJK 포함)의 baseline 정렬을 지킨다.
static bool maru_font_is_color(CTFontRef font) {
    if (font == NULL) {
        return false;
    }
    // 'sbix'(Apple Color Emoji) 또는 'COLR'(컬러 벡터 폰트) 테이블이 있으면 컬러 폰트.
    const CTFontTableTag sbix = ('s' << 24) | ('b' << 16) | ('i' << 8) | 'x';
    const CTFontTableTag colr = ('C' << 24) | ('O' << 16) | ('L' << 8) | 'R';
    CFDataRef t = CTFontCopyTable(font, sbix, kCTFontTableOptionNoOptions);
    if (t != NULL) {
        CFRelease(t);
        return true;
    }
    t = CTFontCopyTable(font, colr, kCTFontTableOptionNoOptions);
    if (t != NULL) {
        CFRelease(t);
        return true;
    }
    return false;
}

void maru_macos_coretext_smoke_rasterize_glyph(
    const char *requested_font_family,
    size_t requested_font_family_len,
    double requested_font_size,
    const char *font_postscript_name,
    size_t font_postscript_name_len,
    uint32_t codepoint,
    uint32_t glyph_id,
    size_t width_px,
    size_t height_px,
    size_t bytes_per_row,
    uint8_t *pixels,
    size_t pixel_capacity,
    MaruCoreTextGlyphRasterResult *result
) {
    @autoreleasepool {
        if (result == NULL) {
            return;
        }
        result->status = -1;
        result->non_clear_pixels = 0;

        size_t byte_count = 0;
        if (!maru_validate_raster_request(
            pixels,
            width_px,
            height_px,
            bytes_per_row,
            pixel_capacity,
            &byte_count
        )) {
            result->status = 1;
            return;
        }
        if (glyph_id == 0 || glyph_id > UINT16_MAX) {
            result->status = 2;
            return;
        }

        // Zig의 GlyphRasterFrame builder가 buffer를 pre-clear하는 계약이지만, 이 native
        // smoke bridge는 C ABI 경계에 있으므로 한 번 더 0으로 닫는다. 실패/부분 draw가
        // 이전 upload byte를 재사용하는 상황을 만들지 않는 것이 디버깅에 더 유리하다.
        memset(pixels, 0, byte_count);

        (void)requested_font_family;
        (void)requested_font_family_len;
        (void)codepoint;

        CFStringRef draw_font_name = maru_create_font_name(
            font_postscript_name,
            font_postscript_name_len
        );
        if (draw_font_name == NULL) {
            result->status = 3;
            return;
        }

        // glyph_id는 shaping 때 선택된 font face 안에서만 유효하다. 그래서 smoke
        // rasterizer도 codepoint로 fallback을 다시 찾지 않고, Zig registry가 넘긴
        // 같은 PostScript name으로 CTFont를 만든 뒤 그 glyph id를 그린다.
        CTFontRef draw_font = CTFontCreateWithName(
            draw_font_name,
            (CGFloat)requested_font_size,
            NULL
        );
        if (draw_font == NULL) {
            CFRelease(draw_font_name);
            result->status = 4;
            return;
        }
        if (!maru_font_postscript_name_matches(draw_font, draw_font_name)) {
            CFRelease(draw_font);
            CFRelease(draw_font_name);
            result->status = 8;
            return;
        }

        CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
        if (color_space == NULL) {
            CFRelease(draw_font);
            CFRelease(draw_font_name);
            result->status = 5;
            return;
        }

        CGContextRef context = CGBitmapContextCreate(
            pixels,
            width_px,
            height_px,
            8,
            bytes_per_row,
            color_space,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
        );
        if (context == NULL) {
            CGColorSpaceRelease(color_space);
            CFRelease(draw_font);
            CFRelease(draw_font_name);
            result->status = 6;
            return;
        }

        // CTFontDrawGlyphs는 이 CGBitmapContext에서 이미 Metal upload가 기대하는
        // top-to-bottom memory order로 glyph를 그린다. CTLineDraw용 y-flip 관용구를
        // 여기에도 적용하면 raster source 자체가 뒤집히고, Metal은 그 뒤집힌 bitmap을
        // 정확히 샘플링해 smoke가 green이 된다. 즉 readback만으로는 못 잡는 시각적
        // 회귀라서 single-glyph rasterizer에서는 CTM을 뒤집지 않는다.
        CGContextSetTextMatrix(context, CGAffineTransformIdentity);
        CGContextSetShouldAntialias(context, true);
        CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);

        CGGlyph glyph = (CGGlyph)glyph_id;
        CGRect bounds = CTFontGetBoundingRectsForGlyphs(
            draw_font,
            kCTFontOrientationDefault,
            &glyph,
            NULL,
            1
        );
        // 수직은 모든 glyph를 공통 baseline에 앉혀 정렬한다(이전엔 ink bounds 기준 가운데
        // 정렬이라 글자마다 baseline이 달라 'm'은 위로 'a'는 아래로 흔들렸다). CTFontDrawGlyphs는
        // position.y를 baseline으로 쓰므로(이 context는 y-up), baseline = descent + 위아래
        // 여백/2로 두면 셀 안에서 일관된 줄에 글자가 앉는다. 수평은 정사각 slot 안에서 가운데로
        // 둔다(advance 폭 기반 cell은 다음 단계). line height가 slot보다 크면 위/아래 약간 잘림.
        const CGFloat ascent = CTFontGetAscent(draw_font);
        const CGFloat descent = CTFontGetDescent(draw_font);
        const CGFloat line_height = ascent + descent;
        const CGFloat avail_w = (CGFloat)width_px;
        const CGFloat avail_h = (CGFloat)height_px;

        // 축소-맞춤은 이모지(컬러 글리프)에만 적용한다 — Ghostty도 constraint(.cover)를 이모지에만
        // 건다(SharedGrid.zig: `if (p == .emoji)`). 일반 텍스트(한글/CJK 포함)는 ink가 셀보다 커도
        // 축소+가운데정렬하면 baseline이 흔들려 윗/아랫줄과 어긋나 보인다(이게 회귀의 원인이었다).
        // 텍스트는 공통-baseline 정렬을 그대로 써 줄이 일관되게 맞고, 큰 글자는 셀 메트릭으로 맞춘다.
        // 좁은 셀(EAW 1칸)의 이모지는 ink가 슬롯을 넘으므로 종횡비 유지 축소로 안 잘리게 한다.
        const bool is_emoji = maru_font_is_color(draw_font);
        if (is_emoji && bounds.size.width > 0.0 && bounds.size.height > 0.0) {
            // 이모지는 슬롯을 꽉 채우도록 종횡비 유지하며 키우거나 줄인다(Ghostty의 .cover와 같은
            // 의도 — 풀사이즈). 두 축 비율 중 작은 쪽으로 스케일하면 슬롯 안에 정확히 들어맞고
            // 넘치지 않는다(width 2 슬롯이면 2칸을 가득, width 1이면 셀 폭에 맞춰 온전히). cap 없이
            // 작은 글리프도 키워 텍스트 줄 높이만큼 또렷하게 보이게 한다.
            CGFloat scale = fmin(avail_w / bounds.size.width, avail_h / bounds.size.height);
            if (!isfinite((double)scale) || scale <= 0.0) {
                scale = 1.0;
            }
            CGContextSaveGState(context);
            // 슬롯 중심으로 옮긴 뒤 축소하고, glyph의 ink box 중심을 원점(=슬롯 중심)에 맞춰 그린다.
            CGContextTranslateCTM(context, avail_w / 2.0, avail_h / 2.0);
            CGContextScaleCTM(context, scale, scale);
            const CGFloat ink_center_x = bounds.origin.x + bounds.size.width / 2.0;
            const CGFloat ink_center_y = bounds.origin.y + bounds.size.height / 2.0;
            CGPoint position = CGPointMake(-ink_center_x, -ink_center_y);
            CTFontDrawGlyphs(draw_font, &glyph, &position, 1, context);
            CGContextRestoreGState(context);
        } else {
            // 기존 경로: 수평 가운데 + 공통 baseline(descent + 위아래 여백/2).
            CGFloat x = -bounds.origin.x + floor((avail_w - bounds.size.width) / 2.0);
            CGFloat y = descent;
            if (line_height > 0.0 && line_height <= avail_h) {
                y = descent + floor((avail_h - line_height) / 2.0);
            }
            if (!isfinite((double)x)) {
                x = 0.0;
            }
            if (!isfinite((double)y)) {
                y = avail_h * 0.2;
            }
            if (x < 0.0) {
                x = 0.0;
            }
            if (y < 0.0) {
                y = 0.0;
            }
            CGPoint position = CGPointMake(x, y);
            CTFontDrawGlyphs(draw_font, &glyph, &position, 1, context);
        }

        const uint32_t non_clear = maru_count_non_clear_rgba_pixels(
            pixels,
            width_px,
            height_px,
            bytes_per_row
        );
        result->non_clear_pixels = non_clear;
        // status 7은 "glyph를 그렸으나 non-clear pixel이 없다"는 zero-ink 신호다. 이건 실패가
        // 아니라 renderer가 zero_ink_uploads로 회계하는 정상 결과이므로, Zig 경계
        // (coretext_raster.zig)가 status 7을 RasterizerFailed가 아닌 non_clear=0 성공으로 닫는다.
        result->status = non_clear > 0 ? 0 : 7;

        CGContextRelease(context);
        CGColorSpaceRelease(color_space);
        CFRelease(draw_font);
        CFRelease(draw_font_name);
    }
}

void maru_macos_coretext_smoke_run(
    const char *requested_font_family,
    size_t requested_font_family_len,
    double requested_font_size,
    MaruCoreTextSmokeResult *result,
    MaruCoreTextGlyphRecord *glyph_records,
    size_t glyph_record_capacity
) {
    @autoreleasepool {
        if (result == NULL) {
            return;
        }
        maru_clear_result(result);

        CTFontRef primary_font = maru_create_primary_font(
            requested_font_family,
            requested_font_family_len,
            requested_font_size,
            &result->requested_font_matched
        );
        if (primary_font == NULL) {
            result->status = 1;
            return;
        }
        result->primary_font_found = 1;

        CFStringRef primary_name = CTFontCopyPostScriptName(primary_font);
        maru_copy_cfstring(primary_name, result->primary_font_name, sizeof(result->primary_font_name));

        CFStringRef probe = maru_create_probe_string();
        if (probe == NULL) {
            if (primary_name != NULL) {
                CFRelease(primary_name);
            }
            CFRelease(primary_font);
            result->status = 2;
            return;
        }

        const void *keys[] = { kCTFontAttributeName };
        const void *values[] = { primary_font };
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
            if (primary_name != NULL) {
                CFRelease(primary_name);
            }
            CFRelease(primary_font);
            result->status = 3;
            return;
        }

        CFAttributedStringRef attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            probe,
            attributes
        );
        if (attributed == NULL) {
            CFRelease(attributes);
            CFRelease(probe);
            if (primary_name != NULL) {
                CFRelease(primary_name);
            }
            CFRelease(primary_font);
            result->status = 4;
            return;
        }

        CTLineRef line = CTLineCreateWithAttributedString(attributed);
        if (line == NULL) {
            CFRelease(attributed);
            CFRelease(attributes);
            CFRelease(probe);
            if (primary_name != NULL) {
                CFRelease(primary_name);
            }
            CFRelease(primary_font);
            result->status = 5;
            return;
        }
        result->line_created = 1;

        CFArrayRef runs = CTLineGetGlyphRuns(line);
        CFIndex run_count = runs == NULL ? 0 : CFArrayGetCount(runs);
        result->run_count = maru_u32_from_cfindex(run_count);

        for (CFIndex i = 0; i < run_count; i++) {
            CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
            if (run == NULL) {
                continue;
            }

            uint32_t run_font_id = 1;
            uint32_t run_fallback = 0;
            CFStringRef run_name = NULL;
            CFDictionaryRef run_attributes = CTRunGetAttributes(run);
            CTFontRef run_font = run_attributes == NULL
                ? NULL
                : (CTFontRef)CFDictionaryGetValue(run_attributes, kCTFontAttributeName);
            if (run_font != NULL) {
                run_name = CTFontCopyPostScriptName(run_font);
                if (run_name != NULL) {
                    if (primary_name != NULL &&
                        CFStringCompare(run_name, primary_name, 0) != kCFCompareEqualTo)
                    {
                        result->fallback_run_count += 1;
                        run_fallback = 1;
                        run_font_id = 1 + result->fallback_run_count;
                        if (result->first_fallback_font_name[0] == '\0') {
                            maru_copy_cfstring(
                                run_name,
                                result->first_fallback_font_name,
                                sizeof(result->first_fallback_font_name)
                            );
                        }
                    }
                }
            }
            CFStringRef record_font_name = run_name != NULL ? run_name : primary_name;

            CFIndex glyph_count = CTRunGetGlyphCount(run);
            result->glyph_count += maru_u32_from_cfindex(glyph_count);

            // smoke probe는 작지만, stack buffer 상한을 둬서 나중에 probe가 실수로 커져도
            // native bridge가 과도한 동적 할당을 하지 않게 한다. 상한 초과는 smoke 실패다.
            if (glyph_count > 64) {
                result->status = 7;
                if (run_name != NULL) {
                    CFRelease(run_name);
                }
                continue;
            }

            CGGlyph glyphs[64];
            CFIndex string_indices[64];
            CTRunGetGlyphs(run, CFRangeMake(0, glyph_count), glyphs);
            CTRunGetStringIndices(run, CFRangeMake(0, glyph_count), string_indices);
            for (CFIndex glyph_index = 0; glyph_index < glyph_count; glyph_index++) {
                maru_record_probe_glyph(
                    result,
                    glyph_records,
                    glyph_record_capacity,
                    run_font_id,
                    record_font_name,
                    glyphs[glyph_index],
                    string_indices[glyph_index],
                    run_fallback
                );
            }

            if (run_name != NULL) {
                CFRelease(run_name);
            }
        }

        if (result->status != 7) {
            maru_rasterize_line_into_cpu_bitmap(result, line);
        }

        if (result->status != 7) {
            result->status = result->glyph_count > 0 &&
                    result->ascii_glyph_present != 0 &&
                    result->cjk_glyph_present != 0 &&
                    result->emoji_glyph_present != 0 &&
                    result->missing_glyph_count == 0 &&
                    result->glyph_record_count > 0 &&
                    result->glyph_record_overflow == 0 &&
                    result->glyph_rasterized != 0 &&
                    result->raster_failures == 0
                ? 0
                : 6;
        }

        CFRelease(line);
        CFRelease(attributed);
        CFRelease(attributes);
        CFRelease(probe);
        if (primary_name != NULL) {
            CFRelease(primary_name);
        }
        CFRelease(primary_font);
    }
}
