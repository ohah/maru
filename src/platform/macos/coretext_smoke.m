#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// 등록된 maru 아이콘 codepoint 집합(생성 — tools/svg_to_coverage.py). maru_is_synthesized_glyph가
// 아이콘 분기에서 이걸 써 **등록 아이콘만** 합성으로 본다(미등록 in-range는 폰트 폴백 — Nerd Fonts v3 MDI 겹침).
#include "icon_codepoints.h"

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
    // 스타일 플래그(비트필드). bit0(MaruDrawCellBoldBit)=bold. Zig NativeDrawCell.style_flags와 동형.
    uint16_t style_flags;
    uint32_t codepoint;
    // grapheme cluster 본체(base 뒤 extra 코드포인트 — 악센트·VS16·NFD 한글 V/T·키캡·ZWJ)를 shape
    // 인자 grapheme_pool에서 가리킨다 — [grapheme_offset, grapheme_offset+grapheme_count). count>0이면
    // base 뒤에 풀의 코드포인트를 모두 붙여 cluster 전체를 셰이핑한다(무손실). 0이면 extra 없음.
    // Zig NativeDrawCell와 20바이트 동형(grapheme_offset u32 + grapheme_count u16 + reserved u16).
    uint32_t grapheme_offset;
    uint16_t grapheme_count;
    uint16_t reserved;
} MaruCoreTextDrawCell;

enum {
    MaruDrawCellBoldBit = 1u << 0,
    MaruDrawCellItalicBit = 1u << 1, // italic(SGR 3) — italic face로 셰이핑(F2-3). bold와 같이 켜지면 bold-italic.
};

typedef struct {
    uint32_t cell_index;
    uint16_t row;
    uint16_t col;
    uint16_t cell_width;
    uint16_t reserved;
    uint32_t codepoint;
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

typedef struct {
    int32_t status;
    uint32_t primary_font_found;
    uint32_t glyph_record_count;
    uint32_t glyph_record_overflow;
} MaruChromeTextShapeResult;

typedef struct {
    uint32_t glyph_id;
    uint32_t codepoint;
    uint32_t fallback;
    uint32_t color_glyph_kind;
    float x_px;
    float advance_px;
    char font_name[128];
} MaruChromeTextGlyphRecord;

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

static bool maru_is_system_ui_postscript_name(const char *name, size_t len) {
    // CoreText intentionally rejects private .SFNS/.AppleSDGothic postscript names when
    // reopened by name (and substitutes Times). Those names are nevertheless legitimate
    // identities returned from CTLine. Recreate them through the public system-font API.
    if (name == NULL || len == 0) return false;
    return (len >= 5 && memcmp(name, ".SFNS", 5) == 0) ||
        (len >= 14 && memcmp(name, ".AppleSDGothic", 14) == 0);
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

// Chrome Lab은 Maru.app bundle 밖에서 실행되므로 Info.plist의 ATSApplicationFontsPath를 받지
// 않는다. 이 test-only seam은 bundle에 들어갈 원본 TTF 하나를 process scope에 등록한 뒤,
// 실제 CoreText family lookup까지 확인한다. 앱 제품 경로는 이 함수를 호출하지 않는다.
int32_t maru_macos_coretext_lab_register_font(
    const char *font_path,
    size_t font_path_len,
    const char *requested_font_family,
    size_t requested_font_family_len,
    char *postscript_name_out,
    size_t postscript_name_out_len
) {
    @autoreleasepool {
        if (font_path == NULL || font_path_len == 0 || requested_font_family == NULL || requested_font_family_len == 0 || postscript_name_out == NULL || postscript_name_out_len < 2) {
            return 1;
        }
        postscript_name_out[0] = '\0';
        CFStringRef path = maru_create_font_name(font_path, font_path_len);
        CFStringRef family = maru_create_font_name(requested_font_family, requested_font_family_len);
        if (path == NULL || family == NULL) {
            if (path != NULL) CFRelease(path);
            if (family != NULL) CFRelease(family);
            return 2;
        }
        CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path, kCFURLPOSIXPathStyle, false);
        CFRelease(path);
        if (url == NULL) {
            CFRelease(family);
            return 3;
        }
        CFErrorRef error = NULL;
        const bool registered = CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, &error);
        if (error != NULL) CFRelease(error);
        CFRelease(url);
        if (!registered) {
            CFRelease(family);
            return 4;
        }
        CTFontRef font = CTFontCreateWithName(family, 14.0, NULL);
        const bool matched = maru_font_matches_requested(font, family);
        CFStringRef actual_name = matched ? CTFontCopyPostScriptName(font) : NULL;
        const bool copied_name = actual_name != NULL && maru_copy_cfstring(actual_name, postscript_name_out, postscript_name_out_len);
        if (actual_name != NULL) CFRelease(actual_name);
        if (font != NULL) CFRelease(font);
        CFRelease(family);
        return matched && copied_name && postscript_name_out[0] != '\0' ? 0 : 5;
    }
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

// base 폰트에 사용자 폴백 폰트(쉼표 구분 CSV)를 cascade list로 박은 새 CTFont를 돌려준다(F1-2 font.fallback). 사용자
// 폴백을 **앞에** 두고 CoreText 기본 cascade(CTFontCopyDefaultCascadeListForLanguages)를 **뒤에** 이어, 주 폰트에 없는
// 글리프(한글·이모지 등)를 사용자 폰트 우선으로 그린다. cascade list 요소는 CTFontDescriptor다(Apple 규약). 빈/실패면
// NULL을 돌려 호출자가 base를 그대로 쓰게 한다(폴백은 best-effort — 잘못된 폰트명은 CoreText가 그 항목을 무시). 새
// 폰트는 호출자 소유(CFRelease). 베이스: Ghostty도 cascade list를 명시해 사용자 폰트를 우선한다(동작 비교만).
static CTFontRef maru_apply_cascade_list(
    CTFontRef base,
    const char *fallback_families,
    size_t fallback_families_len,
    double font_size
) {
    if (base == NULL || fallback_families == NULL || fallback_families_len == 0) {
        return NULL;
    }
    CFMutableArrayRef cascade = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (cascade == NULL) {
        return NULL;
    }
    char *dup = strndup(fallback_families, fallback_families_len);
    if (dup != NULL) {
        char *saveptr = NULL;
        for (char *tok = strtok_r(dup, ",", &saveptr); tok != NULL; tok = strtok_r(NULL, ",", &saveptr)) {
            // 항목 앞뒤 공백 trim(내부 공백은 폰트명이라 보존).
            char *start = tok;
            while (*start == ' ' || *start == '\t') start++;
            char *end = start + strlen(start);
            while (end > start && (end[-1] == ' ' || end[-1] == '\t')) end--;
            if (end == start) continue;
            CFStringRef name = CFStringCreateWithBytes(
                kCFAllocatorDefault, (const UInt8 *)start, (CFIndex)(end - start), kCFStringEncodingUTF8, false);
            if (name == NULL) continue;
            const void *dkeys[] = { (const void *)kCTFontFamilyNameAttribute };
            const void *dvals[] = { name };
            CFDictionaryRef dattrs = CFDictionaryCreate(
                kCFAllocatorDefault, dkeys, dvals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            if (dattrs != NULL) {
                CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(dattrs);
                if (d != NULL) {
                    CFArrayAppendValue(cascade, d);
                    CFRelease(d);
                }
                CFRelease(dattrs);
            }
            CFRelease(name);
        }
        free(dup);
    }
    // 사용자 폴백 뒤에 CoreText 기본 cascade를 이어 시스템 폴백(한글/이모지 기본 폰트 등)도 유지한다.
    CFArrayRef default_cascade = CTFontCopyDefaultCascadeListForLanguages(base, NULL);
    if (default_cascade != NULL) {
        CFArrayAppendArray(cascade, default_cascade, CFRangeMake(0, CFArrayGetCount(default_cascade)));
        CFRelease(default_cascade);
    }
    CTFontRef result = NULL;
    const void *keys[] = { (const void *)kCTFontCascadeListAttribute };
    const void *vals[] = { cascade };
    CFDictionaryRef attrs = CFDictionaryCreate(
        kCFAllocatorDefault, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (attrs != NULL) {
        CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attrs);
        if (desc != NULL) {
            result = CTFontCreateCopyWithAttributes(base, (CGFloat)font_size, NULL, desc);
            CFRelease(desc);
        }
        CFRelease(attrs);
    }
    CFRelease(cascade);
    return result;
}

typedef struct {
    int32_t status;
    uint32_t cell_width_px;
    uint32_t cell_height_px;
    uint32_t ascent_px;
    uint32_t descent_px;
} MaruCoreTextCellMetrics;

// 모노스페이스 cell 메트릭(advance 폭 × line-height)을 device 픽셀로 돌려준다. font_size_px는
// 이미 device_scale이 곱해진(예: 14pt × 2 = 28) device 크기다. app session이 atlas slot 크기와
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
    // block_glyph: **U+2580~259F 전체**(eighth/half/full·shade ░▒▓ 균일 alpha·quadrant). renderer/block_glyph.zig와 동기.
    if (cp >= 0x2580 && cp <= 0x259F) {
        return true;
    }
    // box_glyph: **U+2500~257F 전체** 합성(직선·모서리·T·사거리·dashed·둥근·이중선·single↔double 혼합·대각선·
    // 반선 — light·heavy·혼합 전부). **renderer/box_glyph.zig specFor가 이 범위를 빠짐없이 덮음**(동기 유지).
    if (cp >= 0x2500 && cp <= 0x257F) {
        return true;
    }
    // powerline_glyph: Powerline separator(U+E0B0~E0BF — 삼각형·반원·thin) + Powerline-extra 사다리꼴(E0D2·E0D4).
    // renderer/powerline_glyph.zig와 동기.
    if ((cp >= 0xE0B0 && cp <= 0xE0BF) || cp == 0xE0D2 || cp == 0xE0D4) {
        return true;
    }
    // braille_glyph: Braille 점 패턴(U+2800~28FF — 2열×4행 8점 비트마스크). renderer/braille_glyph.zig와 동기.
    if (cp >= 0x2800 && cp <= 0x28FF) {
        return true;
    }
    // legacy_mosaic_glyph: Legacy Computing 블록 모자이크 — sextant(U+1FB00~1FB3B 2×3)·octant(U+1CD00~1CDE5
    // 2×4). renderer/legacy_mosaic_glyph.zig와 동기.
    if ((cp >= 0x1FB00 && cp <= 0x1FB3B) || (cp >= 0x1CD00 && cp <= 0x1CDE5)) {
        return true;
    }
    // legacy_wedge_glyph: edge wedge 삼각형(U+1FB68~1FB6F)·bowtie(U+1FB9A~1FB9B). renderer/legacy_wedge_glyph.zig와 동기.
    if ((cp >= 0x1FB68 && cp <= 0x1FB6F) || (cp >= 0x1FB9A && cp <= 0x1FB9B)) {
        return true;
    }
    // legacy_smooth_glyph: smooth mosaic(U+1FB3C~1FB67 — 대각 폴리곤 44개). renderer/legacy_smooth_glyph.zig와 동기.
    if (cp >= 0x1FB3C && cp <= 0x1FB67) {
        return true;
    }
    // legacy_wedge_glyph corner 삼각형: ◢◣◤◥(U+25E2~25E5, solid)·🮜🮝🮞🮟(U+1FB9C~1FB9F, 50% 음영). 동기.
    if ((cp >= 0x25E2 && cp <= 0x25E5) || (cp >= 0x1FB9C && cp <= 0x1FB9F)) {
        return true;
    }
    // legacy_diagonal_glyph: 대각선 stroke/hatch — hatch(U+1FB98/99)·코너 다이아몬드(U+1FBA0~1FBAE)·cell
    // 대각(U+1FBD0~1FBDF). renderer/legacy_diagonal_glyph.zig와 동기.
    if ((cp >= 0x1FB98 && cp <= 0x1FB99) || (cp >= 0x1FBA0 && cp <= 0x1FBAE) || (cp >= 0x1FBD0 && cp <= 0x1FBDF)) {
        return true;
    }
    // icon_glyph: maru chrome 아이콘(빌드타임 SVG→coverage 합성) — Plane-15 PUA. **등록된 codepoint만** 합성으로
    // 본다(maru_is_registered_icon_cp, 생성 헤더). 미등록 in-range는 폰트로 폴백한다 — Nerd Fonts v3가 Material
    // Design Icons를 이 범위(U+F0001~)로 옮겨 겹치므로, 미등록 cp를 가로채면 그 글리프가 blank가 됐다. renderer/
    // icon_glyph.zig의 isRegisteredIcon과 **동일 집합**이어야 한다(같은 ICONS 소스 생성 → 항상 일치). 어긋나면 blank.
    return maru_is_registered_icon_cp(cp);
}

/* 폰트가 셀보다 넓게 그려 cover-fit(종횡비 축소)할 wide-render-symbol인지 — **src/width.zig의
   isWideRenderSymbol과 동기**(Enclosed Alphanumerics U+2460~24FF: ①②③ 등). 래스터 cover-fit 게이트의
   단일 출처는 width.zig이고 여기는 주석-동기 미러다(이 .m은 풀 코어 비링크 smoke 하니스 공유라 zig 직접
   호출 불가 — maru_is_synthesized_glyph·maru_category_for_codepoint와 동일 이유). 일반 텍스트는 ink가
   advance를 미세하게 넘어도 이 집합 밖이라 자연 메트릭+baseline으로 둔다(docs/glyph-role-render-model.md). */
static bool maru_is_wide_render_symbol(uint32_t cp) {
    return cp >= 0x2460 && cp <= 0x24FF;
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

static CFStringRef maru_create_string_for_draw_cell(
    MaruCoreTextDrawCell cell,
    const uint32_t *grapheme_pool,
    size_t grapheme_pool_len
) {
    // base + cluster 본체(grapheme_pool)를 그대로 CoreText에 넘긴다 — 악센트·VS16·NFD 한글 V/T·키캡
    // (base+VS16+U+20E3)이 store에 온전히 담겨 있어, 단일 combining 슬롯 시절의 VS16 재주입 같은 보정이
    // 필요 없다(원본 시퀀스 그대로 셰이핑). 키캡은 풀에 VS16이 들어 있어 CoreText가 컬러 키캡을 고른다.
    UniChar base_units[2];
    CFIndex base_len = 0;
    if (!maru_append_utf16_scalar(cell.codepoint, base_units, &base_len, 2)) {
        return NULL;
    }
    // extra 없음(또는 범위 밖) — base 한 글자. 대부분의 셀이라 빠른 경로(할당 1회)로 둔다.
    if (cell.grapheme_count == 0 ||
        (size_t)cell.grapheme_offset + (size_t)cell.grapheme_count > grapheme_pool_len) {
        return CFStringCreateWithCharacters(kCFAllocatorDefault, base_units, base_len);
    }
    // cluster — 가변 길이라 CFMutableString으로 base 뒤에 풀 전체를 무손실 append.
    CFMutableStringRef str = CFStringCreateMutable(kCFAllocatorDefault, 0);
    if (str == NULL) {
        return NULL;
    }
    CFStringAppendCharacters(str, base_units, base_len);
    for (uint16_t i = 0; i < cell.grapheme_count; i++) {
        UniChar scalar[2];
        CFIndex n = 0;
        if (maru_append_utf16_scalar(grapheme_pool[cell.grapheme_offset + i], scalar, &n, 2)) {
            CFStringAppendCharacters(str, scalar, n);
        }
    }
    return str;
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

// 글리프를 슬롯에 그린 뒤, 실제로 보이는(alpha>0) 픽셀의 세로 범위를 측정해 슬롯 세로 중앙으로 옮긴다.
// 왜: 컬러 이모지(sbix/COLR — 예: 알림 종 🔔)는 CTFontGetBoundingRectsForGlyphs가 돌려주는 design bbox와,
// 실제 색이 칠해진 보이는 artwork의 중심이 다르다(폰트가 bbox 안에 비대칭 여백을 두고 그림을 얹기 때문).
// cover-fit 분기는 그 design bbox 중심을 슬롯 중앙에 맞추므로, 보이는 종이 위로 떠 보였고 — 그래서 렌더러가
// 종에만 별도 py_nudge(0.40ch)를 단색 아이콘(0.30ch)과 손으로 맞춰야 했다(폰트/DPI마다 다시 틀어지는 근사).
// 여기서 보이는 ink를 직접 측정해 슬롯 중앙에 앉히면 그 보정이 폰트-독립적으로 사라진다(렌더러는 모든 헤더
// 아이콘에 같은 nudge만 준다). 단색 윤곽 글리프(◧/⚙ 등)는 design bbox가 곧 ink라 이동량이 0에 가깝다 —
// 즉 이 정렬은 cover-fit/center 분기 전체에 안전하게 적용된다(일반 텍스트 baseline 분기는 호출하지 않는다).
static void maru_center_ink_vertically(
    uint8_t *pixels,
    size_t width,
    size_t height,
    size_t bytes_per_row
) {
    // 보이는 ink가 걸친 첫(top)·마지막(bottom) 메모리 행을 찾는다. 메모리 행 공간에서 대칭으로 중앙을 맞추므로
    // CTFontDrawGlyphs의 y-up 좌표계와 메모리의 top-to-bottom 순서가 어떻든(중앙 정렬은 방향에 무관) 정확하다.
    size_t ink_top = height; // sentinel: ink 없음(top>bottom)
    size_t ink_bottom = 0;
    for (size_t y = 0; y < height; y++) {
        const uint8_t *row = pixels + y * bytes_per_row;
        bool row_has_ink = false;
        for (size_t x = 0; x < width; x++) {
            if (row[x * 4 + 3] != 0) {
                row_has_ink = true;
                break;
            }
        }
        if (row_has_ink) {
            if (y < ink_top) {
                ink_top = y;
            }
            ink_bottom = y;
        }
    }
    if (ink_top > ink_bottom) {
        return; // zero-ink — 옮길 것이 없다(status 7 경로).
    }
    // 슬롯 중앙에 ink box 중앙을 맞추는 정수-행 이동량. long으로 계산해 size_t 언더플로를 피한다(ink_height가
    // 슬롯 높이를 넘는 비정상 입력에서도 음수가 안전하게 표현된다 — cover-fit이 보장하지만 방어적으로).
    const size_t ink_height = ink_bottom - ink_top + 1;
    const long target_top = ((long)height - (long)ink_height) / 2; // 위/아래 여백 균등
    const long shift = target_top - (long)ink_top;
    if (shift == 0) {
        return; // 이미 중앙(단색 글리프 대부분).
    }
    // 행 단위 이동. 중앙으로만 옮기므로 슬롯 안 ink는 경계를 넘지 않는다. 경계 밖에서 온 행은 0으로 비운다.
    // 폭은 width*4만 다룬다 — bytes_per_row의 padding 바이트는 시작 시 memset(0)으로 이미 비어 있다.
    const size_t row_bytes = width * 4;
    if (shift > 0) {
        // 아래로 이동: 겹침 방지로 아래 행부터 채운다(dst 행 y ← src 행 y-shift).
        for (size_t y = height; y-- > 0;) {
            uint8_t *dst = pixels + y * bytes_per_row;
            if ((long)y - shift >= 0) {
                const uint8_t *src = pixels + (size_t)((long)y - shift) * bytes_per_row;
                memmove(dst, src, row_bytes);
            } else {
                memset(dst, 0, row_bytes);
            }
        }
    } else {
        // 위로 이동: 위 행부터 채운다(dst 행 y ← src 행 y+up).
        const size_t up = (size_t)(-shift);
        for (size_t y = 0; y < height; y++) {
            uint8_t *dst = pixels + y * bytes_per_row;
            if (y + up < height) {
                const uint8_t *src = pixels + (y + up) * bytes_per_row;
                memmove(dst, src, row_bytes);
            } else {
                memset(dst, 0, row_bytes);
            }
        }
    }
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

// 전방선언 — 정의는 아래(rasterizer와 공유). 셰이핑 단계에서 color_glyph_kind를 run 폰트 색으로 정하는 데 쓴다.
static bool maru_font_is_color(CTFontRef font);

static void maru_append_draw_glyph_record(
    MaruCoreTextDrawListShapeResult *result,
    MaruCoreTextDrawGlyphRecord *records,
    size_t record_capacity,
    size_t cell_index,
    MaruCoreTextDrawCell cell,
    CFStringRef font_name,
    CGGlyph glyph,
    uint32_t fallback,
    bool is_color_font
) {
    if (records == NULL || result->glyph_record_count >= record_capacity || cell_index > UINT32_MAX) {
        result->glyph_record_overflow = 1;
        return;
    }

    const uint32_t category = maru_category_for_codepoint(cell.codepoint);
    // 합성 대상(box-drawing·block·Powerline)은 폰트 글리프 유무와 무관하게 Zig rasterizer가 코드포인트로
    // 직접 그린다 → 폰트가 글리프를 주더라도(glyph!=0) 그 글리프는 절대 쓰이지 않는다. 따라서 synth 판정은
    // glyph 유무가 아니라 코드포인트만으로 한다. 폰트가 글리프를 주는 경우(glyph!=0)에도 synth로 봐야:
    //   (1) 아래에서 glyph_id를 0으로 정규화 → cache_key가 codepoint로 키잉되어 primary/fallback이 한 슬롯에
    //       모인다(옛 `glyph==0 &&` 조건은 폰트 보유 시 일반 경로로 새서 폰트 glyph_id로 키잉 → 같은 합성
    //       비트맵을 두 슬롯에 중복 업로드, 드물게 다른 글자와 glyph_id가 겹치면 aliasing).
    //   (2) font_name 복사 실패 시에도 드롭하지 않는다(합성은 폰트명 불요).
    const bool synth = maru_is_synthesized_glyph(cell.codepoint);
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
    // synth는 codepoint로 합성하므로 폰트 glyph_id는 무의미하다. 0으로 정규화해 downstream(cache_key)이
    // codepoint로 키잉하게 한다(glyph_id!=0이면 폰트 glyph_id로 키잉되어 중복/aliasing). 비-synth는 그대로.
    record->glyph_id = synth ? 0 : (uint32_t)glyph;
    record->drawable = drawable ? 1 : 0;
    record->fallback = fallback;
    // 색 판정은 **실제 셰이핑된 run 폰트가 컬러 글리프 테이블(sbix/COLR)을 가졌는지**로 한다 — base
    // 코드포인트 category(0x1F300~1FAFF만 Emoji)로 판정하면 키캡(base ASCII '2')·VS16 표현(❤️ base
    // U+2764)·기본표현 이모지(✅ 등 BMP)가 mono로 잘못 판정돼 컬러 글리프가 회색 틴트로 그려진다(HG3b에서
    // colorUv가 isColorGlyph→color_glyph_kind로 옮겨오며 생긴 회귀). run 폰트 기반은 rasterizer(maru_font_is_color)와
    // 동일 신호라 UV sentinel과 atlas 색이 항상 일치한다. synth(glyph_id=0)는 rasterizer가 mono로 그리는데,
    // box-drawing 등은 텍스트(mono) 폰트로 셰이핑돼 is_color_font=false라 자연히 mono.
    record->color_glyph_kind = is_color_font ? 1 : 0;
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

// (want_bold, want_italic) 조합용 styled CTFont를 만든다(F2-3). bold/italic family가 지정+존재하면 그 패밀리에서
// (+cascade+traits), 아니면 primary_font에서 symbolic trait 파생(이미 박힌 cascade list 상속). 조합에 맞는 face가
// 없으면(SymbolicTraits NULL) NULL을 돌려 호출자가 primary(regular)로 폴백한다 — 없는 스타일을 합성하지 않는다.
// 호출자 소유(CFRelease). bold-italic은 bold base(family-bold 또는 primary)에 italic trait을 더하는 우선순위다.
static CTFontRef maru_create_styled_font(
    CTFontRef primary_font,
    double size,
    const char *fallback_families,
    size_t fallback_families_len,
    const char *bold_family,
    size_t bold_family_len,
    const char *italic_family,
    size_t italic_family_len,
    bool want_bold,
    bool want_italic
) {
    CTFontSymbolicTraits traits =
        (CTFontSymbolicTraits)((want_bold ? kCTFontTraitBold : 0) | (want_italic ? kCTFontTraitItalic : 0));
    if (traits == 0) {
        return NULL; // regular = primary(호출자가 그대로 씀)
    }
    // 베이스 패밀리: bold면 family-bold 우선, 아니면 italic면 family-italic. 지정+존재할 때만.
    const char *base_family = NULL;
    size_t base_family_len = 0;
    if (want_bold && bold_family != NULL && bold_family_len > 0) {
        base_family = bold_family;
        base_family_len = bold_family_len;
    } else if (want_italic && italic_family != NULL && italic_family_len > 0) {
        base_family = italic_family;
        base_family_len = italic_family_len;
    }
    if (base_family != NULL) {
        uint32_t matched = 0;
        CTFontRef fam = maru_create_primary_font(base_family, base_family_len, size, &matched);
        if (matched && fam != NULL) {
            // 그 패밀리 안에서 굵게/기울임(variant 없으면 NULL → 그대로 regular weight of that family).
            CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(fam, 0.0, NULL, traits, traits);
            if (styled != NULL) {
                CFRelease(fam);
                fam = styled;
            }
            // 새로 만든 폰트라 cascade(fallback)를 재적용한다(primary 파생과 달리 상속 안 되므로 — bold/italic 한글·이모지 폴백).
            if (fallback_families != NULL && fallback_families_len > 0) {
                CTFontRef with_cascade = maru_apply_cascade_list(fam, fallback_families, fallback_families_len, size);
                if (with_cascade != NULL) {
                    CFRelease(fam);
                    fam = with_cascade;
                }
            }
            return fam;
        }
        if (fam != NULL) {
            CFRelease(fam); // 패밀리 못 찾음(matched=0) → 아래 primary 파생으로 폴백
        }
    }
    // 지정 패밀리 없음/못 찾음 → primary_font에서 trait 파생(이미 박힌 cascade 상속).
    return CTFontCreateCopyWithSymbolicTraits(primary_font, 0.0, NULL, traits, traits);
}

void maru_macos_coretext_shape_draw_list(
    const char *requested_font_family,
    size_t requested_font_family_len,
    double requested_font_size,
    const char *fallback_families,
    size_t fallback_families_len,
    const char *bold_family, // F2-3: bold 글자용 폰트 패밀리(len 0=주 family bold variant)
    size_t bold_family_len,
    const char *italic_family, // F2-3: italic 글자용 폰트 패밀리(len 0=주 family italic variant)
    size_t italic_family_len,
    const MaruCoreTextDrawCell *cells,
    size_t cell_count,
    // grapheme cluster 본체 풀(base 제외한 extra 코드포인트). cell.grapheme_offset/count가 가리킨다.
    const uint32_t *grapheme_pool,
    size_t grapheme_pool_len,
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

        // 사용자 폴백 폰트(font.fallback)가 있으면 주 폰트에 cascade list로 박는다 — 이후 모든 CTLine(attributes의
        // kCTFontAttributeName이 이 폰트)이 주 폰트에 없는 글리프를 사용자 폴백→시스템 폴백 순으로 그린다(매 cell 변경 불요).
        // 비용: cascade 폰트를 **shape 호출(출력/dirty 프레임)마다** 재구성한다 — 같은 family+fallback+size면 결과가
        // 동일하므로 후속에서 (primary_font 생성과 함께) family+fallback+size 키로 캐시할 여지가 있다(code-review max F1-2 #1).
        if (fallback_families != NULL && fallback_families_len > 0) {
            CTFontRef with_cascade = maru_apply_cascade_list(
                primary_font, fallback_families, fallback_families_len, requested_font_size);
            if (with_cascade != NULL) {
                CFRelease(primary_font);
                primary_font = with_cascade;
            }
        }

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

        // 스타일 face 캐시(F2-3): index = (bold?1:0)|(italic?2:0). 0=regular(primary), 1=bold, 2=italic, 3=bold-italic.
        // 각 조합을 처음 만나는 cell에서 lazy 생성(없는 조합은 매번 재시도 안 하게 attempted). regular(0)은 위에서 이미
        // primary_font/primary_name/attributes로 준비됨. 생성 실패(없는 face)면 그 cell은 regular(0)로 폴백한다.
        CTFontRef styled_fonts[4] = { primary_font, NULL, NULL, NULL };
        CFStringRef styled_names[4] = { primary_name, NULL, NULL, NULL };
        CFDictionaryRef styled_attrs[4] = { attributes, NULL, NULL, NULL };
        bool styled_attempted[4] = { true, false, false, false };

        for (size_t cell_index = 0; cell_index < cell_count; cell_index++) {
            const MaruCoreTextDrawCell cell = cells[cell_index];
            // 이 cell의 스타일(bold/italic)을 정해 해당 face를 lazy 생성·재사용한다. 없으면(NULL) regular 폴백.
            const bool want_bold = (cell.style_flags & MaruDrawCellBoldBit) != 0;
            const bool want_italic = (cell.style_flags & MaruDrawCellItalicBit) != 0;
            const int style_index = (want_bold ? 1 : 0) | (want_italic ? 2 : 0);
            if (style_index != 0 && !styled_attempted[style_index]) {
                styled_attempted[style_index] = true;
                CTFontRef styled = maru_create_styled_font(
                    primary_font, requested_font_size,
                    fallback_families, fallback_families_len,
                    bold_family, bold_family_len,
                    italic_family, italic_family_len,
                    want_bold, want_italic);
                if (styled != NULL) {
                    styled_fonts[style_index] = styled;
                    styled_names[style_index] = CTFontCopyPostScriptName(styled);
                    const void *styled_values[] = { styled };
                    styled_attrs[style_index] = CFDictionaryCreate(
                        kCFAllocatorDefault, keys, styled_values, 1,
                        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                }
            }
            // styled face가 만들어졌으면 그걸로, 실패했으면(없는 face) regular(0)로 폴백.
            const int use_index = (styled_attrs[style_index] != NULL) ? style_index : 0;
            CFDictionaryRef cell_attributes = styled_attrs[use_index];
            // run의 폰트가 이 cell이 의도한 face와 다르면(진짜 fallback) 표시한다. styled cell은 그 face name과 비교해야
            // bold/italic variant를 fallback으로 오탐하지 않는다.
            CFStringRef expected_name = styled_names[use_index];
            const uint32_t category = maru_category_for_codepoint(cell.codepoint);
            if (category == MaruGlyphCategorySpace || cell.width == 0) {
                continue;
            }

            // 이 cell이 실제 glyph record를 하나라도 만들었는지 보려고 처리 전 record 수를
            // 기억한다. 모든 glyph가 .notdef(glyph 0)면 record가 안 늘므로 shaped로 세지 않는다.
            const uint32_t records_before_cell = result->glyph_record_count;

            CFStringRef string = maru_create_string_for_draw_cell(cell, grapheme_pool, grapheme_pool_len);
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
                // 이 run을 그릴 실제 폰트의 컬러 여부(sbix/COLR) — color_glyph_kind의 단일 출처(아래).
                const bool run_is_color = run_font != NULL ? maru_font_is_color(run_font) : false;
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
                        run_fallback,
                        run_is_color
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
        // styled face 캐시(1~3) 정리 — index 0(regular)은 primary_font/primary_name/attributes라 아래에서 따로 푼다(F2-3).
        for (int si = 1; si < 4; si++) {
            if (styled_attrs[si] != NULL) CFRelease(styled_attrs[si]);
            if (styled_names[si] != NULL) CFRelease(styled_names[si]);
            if (styled_fonts[si] != NULL) CFRelease(styled_fonts[si]);
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

// Chrome text의 role은 아홉 종뿐이고 그 (point size, weight) 조합은 프레임마다 그대로 반복된다.
// 그런데 run마다 UI 폰트를 새로 만들면 그 생성 비용이 셰이핑 자체를 압도한다 — 55 run 한 프레임에서
// role이 전부 같으면 3.0ms, run마다 다르면 9.4ms였다(같은 문자열, ReleaseFast). 같은 폰트가 9종을
// 여섯 바퀴 반복하는데도 안 싸지므로 CoreText의 내부 캐시에 기댈 수 없다. 터미널 draw list 경로가
// `styled_fonts[]`로 style별 face를 재사용하는 것과 같은 규율을 chrome 경로에도 준다.
//
// Chrome text 셰이핑은 main actor 전용이므로 lock을 두지 않는다 — 다른 스레드에서 부르면 이 전제가 깨진다.
//
// 용량은 role 수(9)의 배수로 잡고 **가득 차면 라운드로빈으로 축출한다**. 상한만 두고 축출을 안 하면
// `Cmd`+`+`/`-` 두 번이면 캐시가 차 버린다 — dock scale이 폰트 크기를 따라가므로 크기마다 role 9개가
// 새 항목이기 때문이다. 그 뒤에는 매 run이 폰트를 다시 만드는 옛 경로로 조용히 되돌아가고, 그 상태가
// 영구히 남는다(측정상 프레임 비용 1.4ms → 6.3ms). 어느 순간 살아 있는 조합은 한 scale의 9개뿐이라
// 라운드로빈으로 충분하다.
#define MARU_CHROME_FONT_CACHE_CAPACITY 36

typedef struct {
    double size;
    uint32_t weight;
    CTFontRef font;
    CFStringRef postscript_name;
} MaruChromeFontCacheEntry;

static MaruChromeFontCacheEntry maru_chrome_font_cache[MARU_CHROME_FONT_CACHE_CAPACITY];
static size_t maru_chrome_font_cache_count = 0;
static size_t maru_chrome_font_cache_cursor = 0;

/// (size, weight)에 해당하는 system UI face와 그 PostScript 이름을 돌려준다. 반환값은 **항상 캐시 소유**라
/// 호출자가 release하지 않는다. 가득 차면 가장 오래된 항목을 축출한다 — 상한만 두고 축출을 안 하면
/// 폰트 zoom 몇 번에 캐시가 막힌다.
static CTFontRef maru_chrome_font_for(double size, uint32_t weight, CFStringRef *out_name) {
    for (size_t i = 0; i < maru_chrome_font_cache_count; i++) {
        if (maru_chrome_font_cache[i].size == size && maru_chrome_font_cache[i].weight == weight) {
            *out_name = maru_chrome_font_cache[i].postscript_name;
            return maru_chrome_font_cache[i].font;
        }
    }
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, (CGFloat)size, NULL);
    if (font == NULL) { *out_name = NULL; return NULL; }
    // Role weights are closed in Zig.  CoreText's symbolic bold gives the system UI
    // emphasized face without exposing an arbitrary family string at the Chrome boundary.
    if (weight != 0) {
        CTFontRef emphasized = CTFontCreateCopyWithSymbolicTraits(font, 0.0, NULL, kCTFontBoldTrait, kCTFontBoldTrait);
        if (emphasized != NULL) { CFRelease(font); font = emphasized; }
    }
    CFStringRef name = CTFontCopyPostScriptName(font);
    if (maru_chrome_font_cache_count < MARU_CHROME_FONT_CACHE_CAPACITY) {
        maru_chrome_font_cache_count += 1;
    } else {
        // 축출 대상은 이번 호출이 끝난 뒤에도 아무도 안 든다 — 반환한 face는 호출자가 같은 호출 안에서만
        // 쓰고 보관하지 않는다.
        CFRelease(maru_chrome_font_cache[maru_chrome_font_cache_cursor].font);
        if (maru_chrome_font_cache[maru_chrome_font_cache_cursor].postscript_name) {
            CFRelease(maru_chrome_font_cache[maru_chrome_font_cache_cursor].postscript_name);
        }
    }
    maru_chrome_font_cache[maru_chrome_font_cache_cursor] = (MaruChromeFontCacheEntry){
        .size = size, .weight = weight, .font = font, .postscript_name = name,
    };
    maru_chrome_font_cache_cursor = (maru_chrome_font_cache_cursor + 1) % MARU_CHROME_FONT_CACHE_CAPACITY;
    *out_name = name;
    return font;
}

// Chrome text is deliberately shaped as a complete proportional UI line, rather than one
// terminal cell at a time.  Only portable scalar records escape this bridge; CTLine/CTRun and
// font handles are released before returning to Zig.
void maru_macos_coretext_shape_chrome_text(
    const uint8_t *utf8,
    size_t utf8_len,
    double font_size_px,
    uint32_t weight,
    double max_width_px,
    MaruChromeTextShapeResult *result,
    MaruChromeTextGlyphRecord *glyph_records,
    size_t glyph_record_capacity
) {
    @autoreleasepool {
        if (result == NULL) return;
        result->status = -1;
        result->primary_font_found = 0;
        result->glyph_record_count = 0;
        result->glyph_record_overflow = 0;
        if (utf8 == NULL || utf8_len == 0 || glyph_records == NULL || glyph_record_capacity == 0 ||
            !isfinite(font_size_px) || font_size_px <= 0 || !isfinite(max_width_px) || max_width_px <= 0) {
            result->status = 1;
            return;
        }
        CFStringRef string = CFStringCreateWithBytes(kCFAllocatorDefault, utf8, (CFIndex)utf8_len, kCFStringEncodingUTF8, false);
        if (string == NULL) { result->status = 2; return; }
        CFStringRef primary_name = NULL;
        CTFontRef primary = maru_chrome_font_for(font_size_px, weight, &primary_name);
        if (primary == NULL) { CFRelease(string); result->status = 3; return; }
        result->primary_font_found = 1;
        const void *keys[] = { kCTFontAttributeName };
        const void *values[] = { primary };
        CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFAttributedStringRef attributed = attributes == NULL ? NULL :
            CFAttributedStringCreate(kCFAllocatorDefault, string, attributes);
        CTLineRef line = attributed == NULL ? NULL : CTLineCreateWithAttributedString(attributed);
        if (line == NULL) {
            if (attributed) CFRelease(attributed);
            if (attributes) CFRelease(attributes);
            CFRelease(string); result->status = 4; return;
        }
        CTLineRef draw_line = line;
        CGFloat ascent = 0, descent = 0, leading = 0;
        const double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        if (width > max_width_px) {
            CFStringRef ellipsis_string = CFSTR("…");
            CFAttributedStringRef ellipsis = CFAttributedStringCreate(kCFAllocatorDefault, ellipsis_string, attributes);
            CTLineRef token = ellipsis == NULL ? NULL : CTLineCreateWithAttributedString(ellipsis);
            CTLineRef truncated = token == NULL ? NULL : CTLineCreateTruncatedLine(line, (CGFloat)max_width_px, kCTLineTruncationEnd, token);
            if (truncated != NULL) draw_line = truncated;
            if (token) CFRelease(token);
            if (ellipsis) CFRelease(ellipsis);
        }
        CFArrayRef runs = CTLineGetGlyphRuns(draw_line);
        const CFIndex run_count = runs == NULL ? 0 : CFArrayGetCount(runs);
        size_t out = 0;
        for (CFIndex run_index = 0; run_index < run_count; run_index++) {
            CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, run_index);
            const CFIndex glyph_count = CTRunGetGlyphCount(run);
            CFDictionaryRef run_attrs = CTRunGetAttributes(run);
            CTFontRef run_font = run_attrs == NULL ? NULL : (CTFontRef)CFDictionaryGetValue(run_attrs, kCTFontAttributeName);
            CFStringRef run_name = run_font == NULL ? NULL : CTFontCopyPostScriptName(run_font);
            const bool fallback = run_name != NULL && primary_name != NULL && !CFEqual(run_name, primary_name);
            for (CFIndex i = 0; i < glyph_count; i++) {
                if (out == glyph_record_capacity) { result->glyph_record_overflow = 1; break; }
                CGGlyph glyph = 0; CGPoint position = CGPointZero; CGSize advance = CGSizeZero; CFIndex string_index = 0;
                CTRunGetGlyphs(run, CFRangeMake(i, 1), &glyph);
                CTRunGetPositions(run, CFRangeMake(i, 1), &position);
                CTRunGetAdvances(run, CFRangeMake(i, 1), &advance);
                CTRunGetStringIndices(run, CFRangeMake(i, 1), &string_index);
                UniChar ch = (string_index >= 0 && string_index < CFStringGetLength(string)) ? CFStringGetCharacterAtIndex(string, string_index) : 0x2026;
                glyph_records[out].glyph_id = (uint32_t)glyph;
                glyph_records[out].codepoint = (uint32_t)ch;
                glyph_records[out].fallback = fallback ? 1u : 0u;
                glyph_records[out].color_glyph_kind = run_font != NULL && maru_font_is_color(run_font) ? 1u : 0u;
                glyph_records[out].x_px = (float)position.x;
                glyph_records[out].advance_px = (float)advance.width;
                glyph_records[out].font_name[0] = '\0';
                (void)maru_copy_cfstring(run_name, glyph_records[out].font_name, sizeof(glyph_records[out].font_name));
                out++;
            }
            if (run_name) CFRelease(run_name);
            if (result->glyph_record_overflow) break;
        }
        result->glyph_record_count = (uint32_t)out;
        if (draw_line != line) CFRelease(draw_line);
        CFRelease(line); CFRelease(attributed); CFRelease(attributes); CFRelease(string);
        result->status = result->glyph_record_overflow ? 5 : 0;
    }
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

        CFStringRef draw_font_name = NULL;
        CTFontRef draw_font = NULL;
        if (maru_is_system_ui_postscript_name(font_postscript_name, font_postscript_name_len)) {
            CTFontRef system_font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, (CGFloat)requested_font_size, NULL);
            if (system_font != NULL) {
                UniChar character = (UniChar)(codepoint <= UINT16_MAX ? codepoint : 0xFFFDu);
                CFStringRef probe = CFStringCreateWithCharacters(kCFAllocatorDefault, &character, 1);
                draw_font = probe == NULL ? NULL : CTFontCreateForString(system_font, probe, CFRangeMake(0, 1));
                if (probe) CFRelease(probe);
                if (draw_font == NULL) draw_font = CFRetain(system_font);
                CFRelease(system_font);
            }
        } else {
            draw_font_name = maru_create_font_name(font_postscript_name, font_postscript_name_len);
            if (draw_font_name != NULL) draw_font = CTFontCreateWithName(draw_font_name, (CGFloat)requested_font_size, NULL);
        }
        if (draw_font == NULL) {
            if (draw_font_name) CFRelease(draw_font_name);
            result->status = 4;
            return;
        }
        if (draw_font_name != NULL && !maru_font_postscript_name_matches(draw_font, draw_font_name)) {
            CFRelease(draw_font);
            CFRelease(draw_font_name);
            result->status = 8;
            return;
        }

        CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
        if (color_space == NULL) {
            CFRelease(draw_font);
            if (draw_font_name) CFRelease(draw_font_name);
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
            if (draw_font_name) CFRelease(draw_font_name);
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

        // 축소-맞춤(cover-fit: 종횡비 유지 축소)은 **역할(role)** 로 게이트한다 — 런타임 ink 측정을
        // **모든** 글리프에 적용하지 않는다(docs/glyph-role-render-model.md). 대상은 (1) 이모지(컬러
        // 글리프) (2) 헤더 아이콘 심볼(◧⚙) (3) **wide-render-symbol**(width.isWideRenderSymbol —
        // Enclosed Alphanumerics ①②③ U+2460대, 폰트가 셀보다 넓게 그리는 EAW Ambiguous 기호)이다.
        // overflow 분기는 (3)이 1칸에 욱여넣어져 오른쪽이 잘리던 것을 종횡비 축소로 온전히 그린다(폭은
        // UAX#11대로 width 1, 렌더만 셀에 맞춤 — Ghostty constraintWidth와 동일, renderer/cell.zig).
        //
        // **일반 텍스트(한글/CJK 포함)는 역할에 안 들어 cover-fit 대상이 아니다** — ink가 advance를
        // 미세하게 넘어도(예: Hack 'w'는 ink폭==advance라 slot=round(advance) 내림 시 ~0.5px 초과)
        // 자연 메트릭+공통 baseline으로 둔다. 이전의 bare `ink>slot`은 폭 레이어가 narrow라 한 텍스트
        // 'w'까지 ink-center해 descender 없는 'w'가 위로 떴다(Hack에서만; JBM 'w'는 ink<advance라
        // 여유 있어 안 걸림). 텍스트=.none, 기호만 fit인 Ghostty와 동일 모델 — wide-render-symbol 밖의
        // 비합성 기호가 폰트에서 셀보다 넓으면 fit 대신 자연/우측 클립(xterm.js/Alacritty와 동일, maru
        // 폭 정책과 일관). box/block/powerline/braille/legacy·chrome 아이콘은 합성(glyph_id==0)이라 이
        // 경로에 안 와 영향 없다. 특정 기호가 fit이 필요하면 width.isWideRenderSymbol에 한 곳만 추가.
        const bool is_emoji = maru_font_is_color(draw_font);
        const bool is_wide_render_symbol = maru_is_wide_render_symbol(codepoint);
        const bool overflows_slot = is_wide_render_symbol && (bounds.size.width > avail_w);
        // 헤더 아이콘 심볼(◧ U+25E7·⚙ U+2699)은 글리프마다 baseline 대비 ink 위치가 달라, 공통-baseline
        // 정렬이면 같은 줄에 그려도 서로 세로로 어긋나 보인다(사용자 피드백 "3개 아이콘 수평이 안 맞음").
        // 심볼은 ink-center가 자연스럽고(baseline 흔들림 우려는 글자에만 해당 — 심볼은 텍스트 줄과 안 섞임)
        // 셀 중앙에 일관되게 앉아 서로 정렬된다. '+'(ASCII)는 math-axis라 이미 중앙 근처라 제외(텍스트 공유).
        const bool center_symbol = (codepoint == 0x25E7u || codepoint == 0x2699u);
        if ((is_emoji || overflows_slot || center_symbol) && bounds.size.width > 0.0 && bounds.size.height > 0.0) {
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
            // design bbox 기준으로 중앙에 그렸지만, 컬러 이모지는 보이는 artwork 중심이 design bbox 중심과
            // 다르다(위 함수 주석 참고). 그려진 실제 픽셀을 측정해 슬롯 세로 중앙으로 재배치한다 — 렌더러가
            // 종에만 주던 손튜닝 nudge(0.40 vs 0.30)를 폰트-독립으로 없애는 근본 정렬. CGBitmapContext는 이미
            // pixels에 동기 렌더를 끝냈으므로(추가 draw 없음) 버퍼를 직접 옮겨도 안전하다.
            maru_center_ink_vertically(pixels, width_px, height_px, bytes_per_row);
        } else {
            // 수평은 글리프 **advance 폭** 기준 가운데(ink 폭이 아니라) + 공통 baseline. 이전엔 ink
            // bounds 가운데정렬이라, ink 폭이 글자마다 달라 글자가 셀 안에서 좌우로 흔들렸다 — 특히
            // 숫자(JetBrains Mono tabular)는 ink가 셀 폭에 거의 꽉 차 좌측 획이 셀 왼쪽 끝에 바짝 붙어,
            // 왼쪽에 글자가 있으면(`(1`·`0:2`) 0px 간격으로 겹쳐 보였다(공백 옆이면 안 보임). advance
            // 기준으로 두면 글리프가 폰트가 의도한 셀 내 위치(left side bearing 반영)에 앉아 셀 경계를
            // 침범하지 않는다. CTFontGetBoundingRects(ink)와 달리 advance는 폰트의 진짜 칸 폭이다.
            CGSize glyph_advance = CGSizeZero;
            CTFontGetAdvancesForGlyphs(draw_font, kCTFontOrientationHorizontal, &glyph, &glyph_advance, 1);
            CGFloat x = floor((avail_w - glyph_advance.width) / 2.0);
            CGFloat y = descent;
            if (line_height > 0.0 && line_height <= avail_h) {
                y = descent + floor((avail_h - line_height) / 2.0);
            }
            // baseline을 정수 디바이스 픽셀로 스냅한다(루트커즈 개선). descent(분수)·leading·line-height 배수·
            // 세로 중앙정렬이 겹치면 baseline이 분수 픽셀에 떨어지는데, 그러면 v·w처럼 바닥이 1px 두께 뾰족한
            // 글자의 점이 폰트 크기·행간에 따라 픽셀 격자에 다르게 걸쳐 안티앨리어싱이 흔들렸다(줌마다 떠 보임).
            // x는 floor라 이미 정수였고 y만 분수였다 — y를 round해 글자 바닥이 픽셀 줄에 딱 맞게 한다(또렷·크기 간
            // 일관). 슬롯은 정수 px 셀에 배치되므로(grid 정수 px) 정수 baseline이면 화면 픽셀에도 정렬된다.
            // 중앙정렬 의도는 유지(최대 0.5px 보정). is_emoji/overflow cover-fit 분기는 ink-center라 별개.
            y = round(y);
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
        if (draw_font_name) CFRelease(draw_font_name);
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
