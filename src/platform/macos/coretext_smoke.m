#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stddef.h>

typedef struct {
    int32_t status;
    uint32_t primary_font_found;
    uint32_t line_created;
    uint32_t run_count;
    uint32_t glyph_count;
    uint32_t fallback_run_count;
    uint32_t ascii_glyph_present;
    uint32_t cjk_glyph_present;
    uint32_t emoji_glyph_present;
    uint32_t missing_glyph_count;
    char primary_font_name[128];
    char first_fallback_font_name[128];
} MaruCoreTextSmokeResult;

static void maru_clear_result(MaruCoreTextSmokeResult *result) {
    result->status = -1;
    result->primary_font_found = 0;
    result->line_created = 0;
    result->run_count = 0;
    result->glyph_count = 0;
    result->fallback_run_count = 0;
    result->ascii_glyph_present = 0;
    result->cjk_glyph_present = 0;
    result->emoji_glyph_present = 0;
    result->missing_glyph_count = 0;
    result->primary_font_name[0] = '\0';
    result->first_fallback_font_name[0] = '\0';
}

static void maru_copy_cfstring(CFStringRef value, char *buffer, size_t capacity) {
    if (capacity == 0) {
        return;
    }
    buffer[0] = '\0';
    if (value == NULL) {
        return;
    }
    if (!CFStringGetCString(value, buffer, capacity, kCFStringEncodingUTF8)) {
        buffer[0] = '\0';
    }
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

static CTFontRef maru_create_primary_font(void) {
    // UserFixedPitch는 macOS 사용자가 기대하는 기본 고정폭 계열에 가장 가깝다.
    // 만약 OS 정책상 nil이 오면 Menlo로 한 번 더 fallback해서 smoke가 "폰트 없음"이
    // 아니라 "CoreText 자체 접근 실패"에 가까운 상황에서만 실패하게 한다.
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, 14.0, NULL);
    if (font != NULL) {
        return font;
    }
    return CTFontCreateWithName(CFSTR("Menlo-Regular"), 14.0, NULL);
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

static void maru_record_probe_glyph(
    MaruCoreTextSmokeResult *result,
    CGGlyph glyph,
    CFIndex string_index
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

    if (string_index >= 0 && string_index <= 3) {
        result->ascii_glyph_present = 1;
    } else if (string_index == 5) {
        result->cjk_glyph_present = 1;
    } else if (string_index >= 7 && string_index <= 8) {
        result->emoji_glyph_present = 1;
    }
}

void maru_macos_coretext_smoke_run(MaruCoreTextSmokeResult *result) {
    @autoreleasepool {
        if (result == NULL) {
            return;
        }
        maru_clear_result(result);

        CTFontRef primary_font = maru_create_primary_font();
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
            CFIndex glyph_count = CTRunGetGlyphCount(run);
            result->glyph_count += maru_u32_from_cfindex(glyph_count);

            // smoke probe는 작지만, stack buffer 상한을 둬서 나중에 probe가 실수로 커져도
            // native bridge가 과도한 동적 할당을 하지 않게 한다. 상한 초과는 smoke 실패다.
            if (glyph_count > 64) {
                result->status = 7;
                continue;
            }

            CGGlyph glyphs[64];
            CFIndex string_indices[64];
            CTRunGetGlyphs(run, CFRangeMake(0, glyph_count), glyphs);
            CTRunGetStringIndices(run, CFRangeMake(0, glyph_count), string_indices);
            for (CFIndex glyph_index = 0; glyph_index < glyph_count; glyph_index++) {
                maru_record_probe_glyph(result, glyphs[glyph_index], string_indices[glyph_index]);
            }

            CFDictionaryRef run_attributes = CTRunGetAttributes(run);
            CTFontRef run_font = run_attributes == NULL
                ? NULL
                : (CTFontRef)CFDictionaryGetValue(run_attributes, kCTFontAttributeName);
            if (run_font == NULL || primary_name == NULL) {
                continue;
            }

            CFStringRef run_name = CTFontCopyPostScriptName(run_font);
            if (run_name == NULL) {
                continue;
            }

            if (CFStringCompare(run_name, primary_name, 0) != kCFCompareEqualTo) {
                result->fallback_run_count += 1;
                if (result->first_fallback_font_name[0] == '\0') {
                    maru_copy_cfstring(
                        run_name,
                        result->first_fallback_font_name,
                        sizeof(result->first_fallback_font_name)
                    );
                }
            }
            CFRelease(run_name);
        }

        if (result->status != 7) {
            result->status = result->glyph_count > 0 &&
                    result->ascii_glyph_present != 0 &&
                    result->cjk_glyph_present != 0 &&
                    result->emoji_glyph_present != 0 &&
                    result->missing_glyph_count == 0
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
