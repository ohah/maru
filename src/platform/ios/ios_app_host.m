// iOS host (L4). UIKit 창·생명주기·터치·키보드 + Metal 백엔드 + CoreText 폰트 래스터.
//
// **플랫폼은 배치를 모른다.** Zig 쪽 `chrome.ui.tree` 로 조립한 UI 를 `paint` 가 quad 로
// 낮춰 주면 여기서는 그리기만 한다 — 그게 maru 의 레이어 계약(L3 chrome 이 배치,
// L4 platform 이 그리기)이다. 계약은 docs/mobile-platform.md 가 단일 출처다.
// 선언은 `platform/mobile/mobile_host_abi.h` 가 단일 출처다 — 여기서 다시 적지 않는다.
#include "../mobile/mobile_host_abi.h"
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreText/CoreText.h>



// 둥근 모서리를 프래그먼트에서 자른다 — maru 의 rich quad 가 corner_radii 를 쓰므로
// 그 모양이 실제로 나오는지 보려면 필요하다.
static NSString *const kShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float2 local; float2 half_size; float radius; float4 color; float2 uv; float kind; };\n"
     "struct Uni { float4 rect_px; float4 color; float4 misc; float4 cell; };\n"
     "// misc = (radius, vp.x, vp.y, kind) · cell = (col, row, atlas_cols, atlas_rows)\n"
     "// quad 마다 draw call 을 내지 않는다 — 목록을 통째로 올리고 instance_id 로 고른다.\n"
     "vertex VOut v_main(uint vid [[vertex_id]], uint iid [[instance_id]],\n"
     "                   constant Uni *quads [[buffer(0)]]) {\n"
     "  constant Uni &u = quads[iid];\n"
     "  float2 p0 = float2(u.rect_px.x, u.rect_px.y);\n"
     "  float2 p1 = float2(u.rect_px.z, u.rect_px.w);\n"
     "  float2 corners[4] = { float2(p0.x,p1.y), float2(p1.x,p1.y), float2(p0.x,p0.y), float2(p1.x,p0.y) };\n"
     "  float2 px = corners[vid];\n"
     "  float2 ndc = float2(px.x / u.misc.y * 2.0 - 1.0, 1.0 - px.y / u.misc.z * 2.0);\n"
     "  VOut o; o.pos = float4(ndc, 0, 1);\n"
     "  float2 half_size = (p1 - p0) * 0.5;\n"
     "  o.half_size = half_size;\n"
     "  o.local = px - (p0 + half_size);\n"
     "  o.radius = u.misc.x; o.color = u.color; o.kind = u.misc.w;\n"
     "  float2 t[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };\n"
     "  float2 base = float2(u.cell.x, u.cell.y);\n"
     "  o.uv = (base + t[vid]) / float2(u.cell.z, u.cell.w);\n"
     "  return o;\n"
     "}\n"
     "fragment float4 f_main(VOut in [[stage_in]],\n"
     "                       texture2d<float> glyphs [[texture(0)]],\n"
     "                       texture2d<float> icons [[texture(1)]]) {\n"
     "  float r = min(in.radius, min(in.half_size.x, in.half_size.y));\n"
     "  float2 q = abs(in.local) - (in.half_size - r);\n"
     "  float d = length(max(q, 0.0)) - r;\n"
     "  if (d > 0.5) discard_fragment();\n"
     "  constexpr sampler s(filter::linear);\n"
     "  if (in.kind > 1.5) {\n"                    // 아이콘 coverage
     "    float cov = icons.sample(s, in.uv).a;\n"
     "    if (cov < 0.04) discard_fragment();\n"
     "    return float4(in.color.rgb, in.color.a * cov);\n"
     "  }\n"
     "  if (in.kind > 0.5) {\n"                    // 글리프 아틀라스
     "    float cov = glyphs.sample(s, in.uv).r;\n"
     "    if (cov < 0.04) discard_fragment();\n"
     "    return float4(in.color.rgb, in.color.a * cov);\n"
     "  }\n"
     "  return in.color;\n"
     "}\n";

typedef struct { float rect_px[4]; float color[4]; float misc[4]; float cell[4]; } Uni;

@interface ChromeView : UIView <UIKeyInput>
@end

@implementation ChromeView {
    id<MTLDevice> _dev;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipe;
    id<MTLTexture> _glyphTex;
    id<MTLTexture> _iconTex;
    unsigned int _atlasCols, _atlasRows;
    id<MTLBuffer> _quadBuf;   // draw-list 를 통째로 올리는 자리
    NSUInteger _quadCap;
    BOOL _loggedDraw;
    char _lastErr[64];
    // 주기 관측: 표시 클럭 간격을 모아 한 번 기록한다.
    double _paceLast, _paceMs[60];
    int _paceN;
    BOOL _paceDone;
    CTFontRef _atlasFont;
    /// 스타일 비트(0~3)로 바로 찾는다 — SGR 1/3 은 **다른 글리프**라 폰트 파일이 따로 있어야 한다.
    CTFontRef _atlasFaces[4];
    unsigned int _atlasH;
    CADisplayLink *_link;
}

// 호스트가 만든 한글·영어 아틀라스와, **Zig 가 만든** 아이콘 coverage 를 올린다.
// 아이콘 쪽이 중요하다 — SVG 자산이 플랫폼 코드 없이 그대로 이식된다는 증거다.
// **기기에서 굽는다.** 호스트가 만든 아틀라스를 읽는 대신 CoreText 로 직접 래스터한다 —
// "각 플랫폼이 자기 폰트 스택을 쓴다"가 실제로 서는지 보는 자리다. 한글은 Menlo 에 없어
// 폴백(AppleSDGothicNeo)이 필요하고, 진행 폭은 `CTFontGetAdvancesForGlyphs` 가 준다.
- (BOOL)rasterizeAtlasOnDevice {
    NSString *chars = @MARU_ATLAS_PREBAKE;   // 집합은 공용 헤더가 소유한다
    const unsigned int CW = MARU_ATLAS_CELL_W, CH = MARU_ATLAS_CELL_H, COLS = maru_mobile_atlas_cols();
    NSMutableArray<NSNumber *> *cps = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    [chars enumerateSubstringsInRange:NSMakeRange(0, chars.length)
                              options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *sub, NSRange r, NSRange e, BOOL *stop) {
        NSNumber *k = @([sub characterAtIndex:0]);
        if (![seen containsObject:k]) { [seen addObject:k]; [cps addObject:k]; }
    }];
    NSUInteger n = cps.count;
    // 미리 굽는 글자 수가 아니라 **고정 행 수**로 잡는다 — 남는 슬롯이 온디맨드
    // 성장의 상한이 되기 때문이다.
    unsigned int W = COLS * CW, H = maru_mobile_atlas_rows() * CH;
    uint8_t *gray = calloc(W * H, 1);
    if (!gray) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(gray, W, H, 8, W, cs, kCGImageAlphaNone);
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);

    // **번들한 폰트를 쓴다.** maru 는 이미 `assets/fonts/` 에 OFL 폰트를 동봉하고 있고,
    // 그중 Jetendard 는 영문과 한글을 한 파일에 담는다 — 폴백이 아예 필요 없다.
    // 시스템 폰트(Menlo·AppleSDGothicNeo)를 쓰면 플랫폼마다 글자 모양이 갈리는데,
    // 그 차이는 라이선스 때문에 옮길 수도 없는 종류다.
    CTFontRef base = NULL;
    NSString *fontPath = [NSBundle.mainBundle pathForResource:@"Jetendard-Regular" ofType:@"ttf"];
    if (fontPath) {
        CFArrayRef descs = CTFontManagerCreateFontDescriptorsFromURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:fontPath]);
        if (descs && CFArrayGetCount(descs) > 0) {
            base = CTFontCreateWithFontDescriptor(
                (CTFontDescriptorRef)CFArrayGetValueAtIndex(descs, 0), MARU_ATLAS_TEXT_PX, NULL);
        }
        if (descs) CFRelease(descs);
    }
    if (!base) {  // 번들 폰트가 없으면 예전 경로로 — 조용히 다른 글꼴이 되지 않게 로그를 남긴다
        NSLog(@"MARU_CHROME bundled_font_missing fallback=Menlo");
        base = CTFontCreateWithName(CFSTR("Menlo"), MARU_ATLAS_TEXT_PX, NULL);
    }
    CTFontRef korean = CFRetain(base);

    maru_mobile_atlas_geometry(CW, CH);
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = (unichar)cps[i].unsignedIntValue;
        NSUInteger col = i % COLS, row = i / COLS;
        CTFontRef font = (c >= 0xAC00 && c <= 0xD7A3) ? korean : base;
        CGGlyph glyph = 0;
        if (!CTFontGetGlyphsForCharacters(font, &c, &glyph, 1) || glyph == 0) {
            font = korean;
            CTFontGetGlyphsForCharacters(font, &c, &glyph, 1);
        }
        CGPoint pos = CGPointMake(col * CW + 1, H - (row + 1) * CH + 8);
        if (glyph) CTFontDrawGlyphs(font, &glyph, &pos, 1, ctx);
        CGSize adv = CGSizeZero;
        if (glyph) CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &adv, 1);
        int advance = (int)(adv.width + 0.5);
        if (advance <= 0) advance = CW / 2;
        maru_mobile_atlas_add(c, 0, (unsigned int)col, (unsigned int)row, (unsigned int)advance);
    }
    // 온디맨드 성장이 같은 폰트를 계속 쓰므로 여기서 소유권을 넘겨받는다 —
    // 아래 release 뒤에 retain 하면 해제된 객체를 만진다(그렇게 짰다가 앱이 죽었다).
    _atlasFont = (CTFontRef)CFRetain(base);
    // **굵게·기울임 판도 연다.** 가짜 굵게(획을 덧그리기)는 advance 가 달라져 자간이 어긋난다 —
    // Jetendard 는 네 판을 다 동봉하므로 파일로 고른다. 없으면 보통 판으로 되돌린다.
    static NSString *const kFace[4] = {@"Jetendard-Regular", @"Jetendard-Bold",
                                       @"Jetendard-Italic", @"Jetendard-BoldItalic"};
    for (int s = 0; s < 4; s++) {
        CTFontRef f = NULL;
        NSString *path = [NSBundle.mainBundle pathForResource:kFace[s] ofType:@"ttf"];
        if (path) {
            CFArrayRef ds = CTFontManagerCreateFontDescriptorsFromURL(
                (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
            if (ds && CFArrayGetCount(ds) > 0)
                f = CTFontCreateWithFontDescriptor(
                    (CTFontDescriptorRef)CFArrayGetValueAtIndex(ds, 0), MARU_ATLAS_TEXT_PX, NULL);
            if (ds) CFRelease(ds);
        }
        if (!f) { NSLog(@"MARU_CHROME bundled_font_missing style=%d", s); f = (CTFontRef)CFRetain(base); }
        _atlasFaces[s] = f;
    }
    CFRelease(base); CFRelease(korean);
    CGContextRelease(ctx); CGColorSpaceRelease(cs);

    _atlasCols = COLS; _atlasRows = maru_mobile_atlas_rows(); _atlasH = H;
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:W height:H mipmapped:NO];
    _glyphTex = [_dev newTextureWithDescriptor:td];
    [_glyphTex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:gray bytesPerRow:W];
    // 래스터 결과를 남긴다 — 두 플랫폼의 픽셀 차이를 재는 하네스(`atlas_diff.py`)가 읽는다.
    // **요청할 때만 쓴다.** 제품이 매 실행마다 384KB 를 남길 이유가 없다.
    if (NSProcessInfo.processInfo.environment[@"MARU_ATLAS_DUMP"]) {
        NSString *dump = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]
                          stringByAppendingPathComponent:@"atlas_ondevice.gray"];
        [[NSData dataWithBytes:gray length:W * H] writeToFile:dump atomically:YES];
    }
    free(gray);
    NSLog(@"MARU_CHROME atlas_ondevice=%ux%u glyphs=%lu source=CoreText font=%@",
          W, H, (unsigned long)n, fontPath ? @"Jetendard" : @"Menlo");
    return YES;
}

- (void)loadAtlas {
    // 기기에서 굽는다. 실패하면 글리프 없이 뜨는 편이 낫다 — 예전에 두던 "호스트가 만든
    // 아틀라스를 읽는" 폴백은 개발 스크립트가 넣어 준 파일에 기대는 것이라 **실제 앱에는
    // 그 파일이 없다**. 제품 폴백이 아니라 PoC 잔재였다.
    if (![self rasterizeAtlasOnDevice]) NSLog(@"MARU_CHROME atlas_raster_failed");
    [self loadIcons];
}

// 아이콘: Zig 가 coverage 를 만든다(플랫폼 코드 0줄).
- (void)loadIcons {
    unsigned int filled = maru_mobile_icon_build();
    unsigned int slot = maru_mobile_icon_slot_px(), count = maru_mobile_icon_count();
    NSLog(@"MARU_CHROME icons filled=%u/%u slot=%u", filled, count, slot);
    // coverage 는 RGBA8 로 오고 alpha 채널이 값이다(glyph_pixels 계약).
    MTLTextureDescriptor *itd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:slot height:slot * count mipmapped:NO];
    _iconTex = [_dev newTextureWithDescriptor:itd];
    [_iconTex replaceRegion:MTLRegionMake2D(0, 0, slot, slot * count) mipmapLevel:0
                  withBytes:maru_mobile_icon_atlas() bytesPerRow:slot * 4];
}

// **입력**: 하드웨어 키보드가 이 뷰로 온다. 받은 문자를 바이트로 코어에 먹인다 —
// 코어는 PTY 에서 온 것과 구분하지 않는다(Android 쪽과 같은 계약).
// **터치**: 탭한 지점을 셀 좌표로 바꿔 코어에 알린다. 데스크톱의 포인터 조회와 같은 계약이고,
// 여기서 확인하려는 것은 "터치가 논리 좌표를 거쳐 셀까지 닿는가"다.
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    CGPoint p = [touch locationInView:self];
    UIEdgeInsets safe = self.safeAreaInsets;
    // 플랫폼이 넘긴 것과 같은 논리 좌표계로 되돌린다 — 안 그러면 셀이 어긋난다.
    float lx = (float)(p.x - safe.left);
    float ly = (float)(p.y - safe.top);
    unsigned int cell = maru_mobile_hit_cell(lx, ly);
    NSLog(@"MARU_TOUCH pt=(%.0f,%.0f) logical=(%.0f,%.0f) cell=(%u,%u)",
          p.x, p.y, lx, ly, cell >> 16, cell & 0xFFFF);
}

- (BOOL)canBecomeFirstResponder { return YES; }
// **소프트 키보드를 막지 않는다.** 한때 빈 `inputView` 를 돌려줘 키보드를 감췄는데,
// 그러면 하드웨어 키보드가 없는 사용자는 **아무것도 입력할 수 없다** — 스크린샷을 깨끗하게
// 하려다 넣은 것이라 제품에는 틀린 동작이었다. Android 도 켜지면 키보드를 올린다.
- (BOOL)hasText { return YES; }
- (void)deleteBackward {
    // **바이트를 손으로 적지 않는다.** backspace 도 코어가 인코딩한다 — 모드에 따라 0x7F 와
    // 0x08 이 갈리고, 수정자가 붙으면 또 달라진다.
    maru_mobile_key(MARU_KEY_BACKSPACE, 0, 0);
}

/// 수정자·특수키는 `UIKeyInput` 이 안 준다 — `pressesBegan` 이 `UIKey` 로 준다(iOS 13.4+).
/// 화살표·Home/End·F1~F12·Ctrl 조합이 전부 이 경로다. 문자는 `insertText` 가 계속 맡는다.
- (unsigned int)modsFrom:(UIKeyModifierFlags)f {
    unsigned int m = 0;
    if (f & UIKeyModifierShift) m |= MARU_MOD_SHIFT;
    if (f & UIKeyModifierControl) m |= MARU_MOD_CTRL;
    if (f & UIKeyModifierAlternate) m |= MARU_MOD_ALT;
    if (f & UIKeyModifierCommand) m |= MARU_MOD_CMD;
    return m;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    for (UIPress *press in presses) {
        UIKey *k = press.key;
        if (!k) continue;
        unsigned int mods = [self modsFrom:k.modifierFlags];
        unsigned int id = 0;
        switch (k.keyCode) {
            case UIKeyboardHIDUsageKeyboardUpArrow:    id = MARU_KEY_UP; break;
            case UIKeyboardHIDUsageKeyboardDownArrow:  id = MARU_KEY_DOWN; break;
            case UIKeyboardHIDUsageKeyboardLeftArrow:  id = MARU_KEY_LEFT; break;
            case UIKeyboardHIDUsageKeyboardRightArrow: id = MARU_KEY_RIGHT; break;
            case UIKeyboardHIDUsageKeyboardHome:       id = MARU_KEY_HOME; break;
            case UIKeyboardHIDUsageKeyboardEnd:        id = MARU_KEY_END; break;
            case UIKeyboardHIDUsageKeyboardInsert:     id = MARU_KEY_INSERT; break;
            case UIKeyboardHIDUsageKeyboardDeleteForward: id = MARU_KEY_DELETE; break;
            case UIKeyboardHIDUsageKeyboardPageUp:     id = MARU_KEY_PAGE_UP; break;
            case UIKeyboardHIDUsageKeyboardPageDown:   id = MARU_KEY_PAGE_DOWN; break;
            case UIKeyboardHIDUsageKeyboardEscape:     id = MARU_KEY_ESCAPE; break;
            case UIKeyboardHIDUsageKeyboardTab:        id = MARU_KEY_TAB; break;
            case UIKeyboardHIDUsageKeyboardReturnOrEnter: id = MARU_KEY_ENTER; break;
            case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: id = MARU_KEY_BACKSPACE; break;
            default:
                if (k.keyCode >= UIKeyboardHIDUsageKeyboardF1 &&
                    k.keyCode <= UIKeyboardHIDUsageKeyboardF12) {
                    id = MARU_KEY_F(k.keyCode - UIKeyboardHIDUsageKeyboardF1 + 1);
                } else if (mods & (MARU_MOD_CTRL | MARU_MOD_ALT | MARU_MOD_CMD)) {
                    // 수정자가 붙은 문자는 `insertText` 로 안 온다 — 여기서 코어에 태운다.
                    NSString *s = k.charactersIgnoringModifiers;
                    if (s.length == 0) continue;
                    NSLog(@"MARU_INPUT key=char mods=%u total=%u", mods,
                          maru_mobile_key(MARU_KEY_CHAR, [s characterAtIndex:0], mods));
                    handled = YES;
                    continue;
                } else {
                    continue;  // 평범한 문자는 insertText 가 맡는다
                }
        }
        // Android 의 `MARU_INPUT` 과 같은 판정자다 — 누적 전달 바이트가 늘면 코어에 닿은 것이다.
        NSLog(@"MARU_INPUT key=%u mods=%u total=%u", id, mods, maru_mobile_key(id, 0, mods));
        handled = YES;
    }
    if (!handled) [super pressesBegan:presses withEvent:event];
}
- (void)insertText:(NSString *)text {
    const char *b = text.UTF8String;
    if (!b) return;
    unsigned int total = maru_mobile_input(b, strlen(b));
    NSLog(@"MARU_INPUT text=%@ total=%u", text, total);
}

// **아틀라스를 키운다.** Zig 가 모은 미등록 코드포인트를 그 슬롯에만 구워 올린다 —
// 텍스처 전체를 다시 만들지 않고 `replaceRegion` 으로 그 칸만 바꾼다(여섯 기능 4번과 같은 경로).
- (void)growAtlas {
    unsigned int n = maru_mobile_missing_count();
    if (n == 0 || !_atlasFont || !_glyphTex) return;
    // **뒤에서부터 훑는다.** `maru_mobile_atlas_add` 가 미스 목록에서 그 항목을 지우면서
    // **마지막 항목을 그 자리로** 당겨 오므로, 앞으로 진행하면 당겨진 것을 건너뛴다(실측).
    // 뒤에서부터 가면 지워지는 자리가 항상 훑은 뒤쪽이라 앞쪽이 흔들리지 않는다 —
    // 목록 크기를 host 가 따로 알 필요도 없어진다(그 상수를 양쪽에 두면 또 어긋난다).
    const unsigned int CW = MARU_ATLAS_CELL_W, CH = MARU_ATLAS_CELL_H;
    uint8_t *cell = calloc(CW * CH, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    unsigned int added = 0;
    for (int i = (int)n - 1; i >= 0; i--) {
        unsigned int cp = maru_mobile_missing_cp((unsigned int)i);
        unsigned int style = maru_mobile_missing_style((unsigned int)i);
        if (cp == 0 || cp > 0xFFFF) continue;
        CTFontRef face = _atlasFaces[style & 3] ?: _atlasFont;
        unsigned int slot = maru_mobile_next_slot(_atlasCols);
        // 등록부가 꽉 차면 sentinel 이 온다. 옛 코드는 같은 자리를 계속 받아 **매 프레임
        // 다시 굽고** 있었다 — 화면에는 안 나오면서 CPU·GPU 만 먹는다.
        if (slot == 0xFFFFFFFF) break;  // 축출 정책은 아직 없다(계약 §4)
        unsigned int col = slot >> 16, row = slot & 0xFFFF;
        memset(cell, 0, CW * CH);
        // **합성이 먼저다**(renderer 계약). 박스·블록·브라유는 폰트로 구우면 셀에 안 맞아
        // 끊긴다 — 합성은 셀을 가장자리까지 채운다. 0 이면 합성 대상이 아니라 폰트로 간다.
        if (maru_mobile_synthesize(cp, cell, CW) != 0) {
            [_glyphTex replaceRegion:MTLRegionMake2D(col * CW, row * CH, CW, CH) mipmapLevel:0
                           withBytes:cell bytesPerRow:CW];
            maru_mobile_atlas_add(cp, style, col, row, CW / 2);
            added++;
            continue;
        }
        CGContextRef ctx = CGBitmapContextCreate(cell, CW, CH, 8, CW, cs, kCGImageAlphaNone);
        CGContextSetGrayFillColor(ctx, 1.0, 1.0);
        unichar c = (unichar)cp;
        CGGlyph glyph = 0;
        CTFontGetGlyphsForCharacters(face, &c, &glyph, 1);
        if (glyph) {
            CGPoint pos = CGPointMake(1, 8);   // 셀 하나짜리 컨텍스트라 원점이 곧 셀 원점이다
            CTFontDrawGlyphs(face, &glyph, &pos, 1, ctx);
        }
        CGContextRelease(ctx);
        CGSize adv = CGSizeZero;
        if (glyph) CTFontGetAdvancesForGlyphs(face, kCTFontOrientationHorizontal, &glyph, &adv, 1);
        unsigned int advance = (unsigned int)(adv.width + 0.5);
        if (advance == 0) advance = CW / 2;
        [_glyphTex replaceRegion:MTLRegionMake2D(col * CW, row * CH, CW, CH) mipmapLevel:0
                       withBytes:cell bytesPerRow:CW];
        maru_mobile_atlas_add(cp, style, col, row, advance);
        added++;
    }
    CGColorSpaceRelease(cs);
    free(cell);
    maru_mobile_missing_clear();
    if (added) NSLog(@"MARU_ATLAS grew=%u", added);
}

/// 배경/복귀에서 렌더를 멈추고 잇는다. `CADisplayLink.paused` 는 콜백만 멈출 뿐 링크를
/// 버리지 않으므로 복귀가 싸다.
- (void)setRenderingPaused:(BOOL)paused {
    _link.paused = paused;
}

+ (Class)layerClass { return [CAMetalLayer class]; }

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (!self) return nil;
    _dev = MTLCreateSystemDefaultDevice();
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    l.device = _dev;
    l.pixelFormat = MTLPixelFormatBGRA8Unorm;
    NSError *err = nil;
    id<MTLLibrary> lib = [_dev newLibraryWithSource:kShader options:nil error:&err];
    if (!lib) { NSLog(@"MARU_CHROME shader_fail=%@", err); return self; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v_main"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f_main"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    _pipe = [_dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!_pipe) NSLog(@"MARU_CHROME pipeline_fail=%@", err);
    _queue = [_dev newCommandQueue];
    [self loadAtlas];
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    // **30Hz(comfort).** 터미널은 매 vsync 마다 새로 그릴 것이 없고, 모바일은 배터리·발열이
    // 사용자에게 보인다. Android 도 같은 값이고, 데스크톱 maru 의 present 정책과 같다.
    // 실측으로 이 경로가 33.33ms 를 낸다는 것을 확인했다(`present-ios`).
    if (@available(iOS 15.0, *)) {
        _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 30, 30);
    } else {
        _link.preferredFramesPerSecond = 30;
    }
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    return self;
}

/// **요청한 주기가 실제로 나오는지 확인한다.** `preferredFrameRateRange` 는 힌트라 기기·상태에
/// 따라 무시될 수 있는데, Android 는 실측 로그가 있고 iOS 만 없어 30Hz 가 조용히 깨져도 몰랐다.
/// `CADisplayLink.timestamp` 는 직전 vsync 시각이라 벽시계보다 정확하다.
- (void)recordPace {
    if (_paceDone) return;
    double now = _link.timestamp;
    if (_paceLast > 0 && now > _paceLast && _paceN < 60) _paceMs[_paceN++] = (now - _paceLast) * 1000.0;
    _paceLast = now;
    if (_paceN < 60) return;
    for (int i = 1; i < 60; i++) {
        double k = _paceMs[i]; int j = i - 1;
        while (j >= 0 && _paceMs[j] > k) { _paceMs[j + 1] = _paceMs[j]; j--; }
        _paceMs[j + 1] = k;
    }
    _paceDone = YES;
    double med = _paceMs[30];
    NSLog(@"MARU_PACE median_ms=%.2f n=60 target=33.33 verdict=%s",
          med, (med >= 25.0 && med <= 42.0) ? "PASS" : "FAIL");
}

- (void)tick {
    [self recordPace];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    CGFloat scale = UIScreen.mainScreen.scale;
    CGSize px = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
    l.drawableSize = px;
    id<CAMetalDrawable> d = [l nextDrawable];
    if (!d) return;

    // **여기가 핵심**: 레이아웃을 Zig chrome 이 한다. 플랫폼은 크기만 주고 op 을 받는다.
    //
    // 크기는 **논리 픽셀**로 준다. drawableSize 는 backing(3x)이라 그대로 넘기면 34pt 탭이
    // 34px 가 되어 화면이 텅 빈 것처럼 보인다 — 데스크톱에서 backing scale 을 따로 다루는
    // 것과 같은 이유다. NDC 변환도 같은 논리 좌표계를 쓰면 Metal 이 알아서 확대한다.
    // **safe area 를 지킨다.** 창 전체에 그리면 상태바·다이내믹 아일랜드 밑으로 UI 가 들어간다
    // (처음에 그렇게 나왔다). 데스크톱에서 타이틀바 inset 을 다루는 것과 같은 종류의 일이고,
    // 실제 이식에서는 이 inset 을 L1 DTO 로 chrome 에 전달해야 한다.
    UIEdgeInsets safe = self.safeAreaInsets;
    CGSize logical = CGSizeMake(self.bounds.size.width - safe.left - safe.right,
                                self.bounds.size.height - safe.top - safe.bottom);
    unsigned int n = maru_mobile_build((unsigned int)logical.width, (unsigned int)logical.height);
    // **오류는 바뀔 때 알린다.** 시작 때 한 번만 읽으면 그 뒤에 생긴 실패(quad 넘침·코어
    // write·아틀라스 만원)는 기록만 되고 아무도 안 본다 — 계약 §5 가 약속한 것이 안 지켜진다.
    const char *err = maru_mobile_last_error();
    if (err[0]) {
        if (strcmp(err, _lastErr) != 0) {
            strncpy(_lastErr, err, sizeof _lastErr - 1);
            NSLog(@"MARU_CHROME error=%s", err);
        }
        maru_mobile_clear_error();  // 읽은 쪽이 비운다 — 다음 실패가 가려지지 않게
    }
    // build 가 못 그린 글자를 모아 뒀다 — 그것만 구워 넣고 **다음 프레임에 보이게** 한다.
    [self growAtlas];
    const MaruQuad *quads = maru_mobile_quads();

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = d.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.06, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:_pipe];
    // **draw call 한 번.** `setVertexBytes:` 는 4KB 한계라 148 quad(9.5KB)도 못 싣는다 —
    // 버퍼를 잡고 채운 뒤 인스턴스로 그린다(Vulkan storage buffer 와 같은 모양).
    // 프래그먼트는 이미 varying 으로 받으므로 `setFragmentBytes:` 는 필요 없다.
    // **크기는 코어가 답한다.** host 마다 상한을 적어 두면 어긋난다(Android 는 4096 에서
    // 조용히 잘랐다). 코어 버퍼는 격자가 커질 때만 자라므로 여기 재할당도 그때뿐이다.
    NSUInteger want = maru_mobile_max_quads();
    if (_quadCap < want) {
        _quadCap = want;
        _quadBuf = [_dev newBufferWithLength:_quadCap * sizeof(Uni)
                                     options:MTLResourceStorageModeShared];
    }
    Uni *dst = (Uni *)_quadBuf.contents;
    for (unsigned int i = 0; i < n; i++) {
        const MaruQuad *q = &quads[i];
        // kind=3 은 슬롯의 **왼쪽 절반**이다 — 슬롯 하나가 양폭 상자라 단폭 글자는 절반만 쓴다.
        // 셰이더는 `(cell.xy + t)/cell.zw` 뿐이라, 열과 나누는 수를 함께 2배로 주면 그대로
        // 왼쪽 절반이 나온다. 셰이더에는 kind=1 로 넘긴다.
        int half = (q->kind == 3);
        float cols = (q->kind == 2) ? 1.0f : (float)_atlasCols * (half ? 2.0f : 1.0f);
        float rows = (q->kind == 2) ? (float)maru_mobile_icon_count() : (float)_atlasRows;
        float cx = (float)q->cell_x * (half ? 2.0f : 1.0f);
        float kind = half ? 1.0f : (float)q->kind;
        Uni u = {{q->x + (float)safe.left, q->y + (float)safe.top,
                  q->x + q->w + (float)safe.left, q->y + q->h + (float)safe.top},
                 {q->r, q->g, q->b, q->a},
                 {q->radius, (float)self.bounds.size.width, (float)self.bounds.size.height, kind},
                 {cx, (float)q->cell_y, cols, rows}};
        dst[i] = u;
    }
    if (n > 0) {
        [e setVertexBuffer:_quadBuf offset:0 atIndex:0];
        if (_glyphTex) [e setFragmentTexture:_glyphTex atIndex:0];
        if (_iconTex) [e setFragmentTexture:_iconTex atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4
                instanceCount:n];
        if (!_loggedDraw) { _loggedDraw = YES; NSLog(@"MARU_DRAW calls=1 instances=%u", n); }
    }
    [e endEncoding];
    [cb presentDrawable:d];
    [cb commit];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
// **생명주기**: 백그라운드에서는 그리지 않는다. iOS 는 창을 없애지 않아 Android 처럼
// 스왑체인을 부술 필요는 없지만, CADisplayLink 를 멈추지 않으면 복귀 시 밀린 프레임이
// 몰린다. 재개 후 다시 도는지가 판정 기준이다.
- (void)applicationDidEnterBackground:(UIApplication *)app {
    // **배경에서는 그리지 않는다.** 로그만 남기고 CADisplayLink 를 계속 돌리면 백그라운드
    // GPU 작업이 되어 앱이 종료될 수 있다(Apple 이 명시적으로 금지한다). Android 는
    // 창이 죽을 때 Vulkan 을 부수는데 iOS 만 아무것도 안 하고 있었다.
    [(ChromeView *)self.window.rootViewController.view setRenderingPaused:YES];
    NSLog(@"MARU_LIFECYCLE background");
}
- (void)applicationWillEnterForeground:(UIApplication *)app {
    [(ChromeView *)self.window.rootViewController.view setRenderingPaused:NO];
    NSLog(@"MARU_LIFECYCLE foreground");
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    // 시작 때 가짜 크기로 한 번 빌드해 로그를 찍던 것을 지웠다 — 실제 뷰가 서기 전이라
    // 그 결과는 아무도 안 쓰고, 아틀라스가 서기 전에 miss 목록만 채웠다.
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    vc.view = [[ChromeView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    // 화면에는 chrome 이 그린 것만 남긴다 — 디버그 배너는 UI 를 덮고 자기 숫자도 낡는다.
    // 판정에 필요한 값(quad 수·에러)은 위에서 로그로 이미 나간다.
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    // first responder 가 아니면 하드웨어 키가 앱까지 오지 않는다.
    BOOL fr = [vc.view becomeFirstResponder];
    NSLog(@"MARU_INPUT first_responder=%d", fr);
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
