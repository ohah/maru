// 호스트(macOS)에서 **한글·영어 글리프 아틀라스**를 만든다.
//
// Android NDK 에는 폰트 래스터가 없고 iOS 는 CoreText 가 있지만, 두 플랫폼이 **같은
// 아틀라스**를 쓰면 렌더 결과를 1:1 로 비교할 수 있다. 실제 제품에서는 각 플랫폼이
// 자기 폰트 스택으로 래스터한다(iOS CoreText, Android FreeType/HarfBuzz).
//
// 출력: atlas.gray (단일 채널 raw) + atlas.idx (코드포인트→셀 매핑, 텍스트)
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>

#define CELL_W 24
#define CELL_H 32
#define COLS   16

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: %s <out-dir> <chars-utf8>\n", argv[0]); return 2; }
        const char *outDir = argv[1];
        NSString *chars = [NSString stringWithUTF8String:argv[2]];

        // 유니크 코드포인트만 모은다 — 아틀라스를 작게 유지한다.
        NSMutableArray<NSNumber *> *cps = [NSMutableArray array];
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        [chars enumerateSubstringsInRange:NSMakeRange(0, chars.length)
                                  options:NSStringEnumerationByComposedCharacterSequences
                               usingBlock:^(NSString *sub, NSRange r, NSRange e, BOOL *stop) {
            unichar c = [sub characterAtIndex:0];
            NSNumber *k = @(c);
            if (![seen containsObject:k]) { [seen addObject:k]; [cps addObject:k]; }
        }];

        NSUInteger n = cps.count;
        NSUInteger rows = (n + COLS - 1) / COLS;
        NSUInteger W = COLS * CELL_W, H = rows * CELL_H;
        uint8_t *gray = calloc(W * H, 1);

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
        CGContextRef ctx = CGBitmapContextCreate(gray, W, H, 8, W, cs, kCGImageAlphaNone);
        CGContextSetGrayFillColor(ctx, 0.0, 1.0);
        CGContextFillRect(ctx, CGRectMake(0, 0, W, H));
        CGContextSetGrayFillColor(ctx, 1.0, 1.0);

        // 한글이 있는 등폭 폰트. Menlo 는 한글 글리프가 없어 폴백이 필요하다.
        CTFontRef base = CTFontCreateWithName(CFSTR("Menlo"), 22, NULL);
        CTFontRef korean = CTFontCreateWithName(CFSTR("AppleSDGothicNeo-Regular"), 22, NULL);

        FILE *idx = NULL;
        char idxPath[512];
        snprintf(idxPath, sizeof idxPath, "%s/atlas.idx", outDir);
        idx = fopen(idxPath, "w");
        // 셀 크기 + 글자 수. 각 줄은 `cp col row advance_px` — **advance 가 있어야 자간이 맞는다**
        // (셀 폭을 그대로 쓰면 영문이 24px 칸에 갇혀 자간이 벌어진다. 실측으로 드러났다).
        fprintf(idx, "%lu %lu %d %d %lu\n", (unsigned long)W, (unsigned long)H, CELL_W, CELL_H, (unsigned long)n);

        for (NSUInteger i = 0; i < n; i++) {
            unichar c = (unichar)cps[i].unsignedIntValue;
            NSUInteger col = i % COLS, row = i / COLS;
            // 한글·CJK 는 폴백 폰트로 — 없으면 빈 칸이 나온다(실측하면 바로 드러난다).
            CTFontRef font = (c >= 0xAC00 && c <= 0xD7A3) ? korean : base;
            CGGlyph glyph = 0;
            if (!CTFontGetGlyphsForCharacters(font, &c, &glyph, 1) || glyph == 0) {
                font = korean;
                CTFontGetGlyphsForCharacters(font, &c, &glyph, 1);
            }
            CGPoint pos = CGPointMake(col * CELL_W + 1, H - (row + 1) * CELL_H + 8);
            if (glyph) CTFontDrawGlyphs(font, &glyph, &pos, 1, ctx);
            // 폰트가 알려주는 실제 진행 폭. 이 값으로 다음 글자 위치를 정해야 자간이 자연스럽다.
            CGSize adv = CGSizeZero;
            if (glyph) CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &adv, 1);
            int advance = (int)(adv.width + 0.5);
            if (advance <= 0) advance = CELL_W / 2;
            fprintf(idx, "%u %lu %lu %d\n", (unsigned)c, (unsigned long)col, (unsigned long)row, advance);
        }
        fclose(idx);

        char grayPath[512];
        snprintf(grayPath, sizeof grayPath, "%s/atlas.gray", outDir);
        FILE *g = fopen(grayPath, "wb");
        fwrite(gray, 1, W * H, g);
        fclose(g);
        printf("ATLAS %lux%lu cells=%lu cell=%dx%d\n", (unsigned long)W, (unsigned long)H,
               (unsigned long)n, CELL_W, CELL_H);

        CGContextRelease(ctx); CGColorSpaceRelease(cs);
        CFRelease(base); CFRelease(korean);
        free(gray);
        return 0;
    }
}
