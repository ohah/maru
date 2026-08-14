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
     "struct VOut { float4 pos [[position]]; float2 local; float2 half_size; float radius; float4 color; float2 uv; float kind; float4 uvb; };\n"
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
     "  // 자기 칸의 UV 경계 — frag 가 여기 안으로 자른다(이웃 칸 잉크가 새는 것을 막는다).\n"
     "  o.uvb = float4(base / float2(u.cell.z, u.cell.w), (base + 1.0) / float2(u.cell.z, u.cell.w));\n"
     "  return o;\n"
     "}\n"
     "fragment float4 f_main(VOut in [[stage_in]],\n"
     "                       texture2d<float> glyphs [[texture(0)]],\n"
     "                       texture2d<float> icons [[texture(1)]],\n"
     "                       texture2d<float> colors [[texture(2)]]) {\n"
     "  float r = min(in.radius, min(in.half_size.x, in.half_size.y));\n"
     "  float2 q = abs(in.local) - (in.half_size - r);\n"
     "  float d = length(max(q, 0.0)) - r;\n"
     "  if (d > 0.5) discard_fragment();\n"
     "  constexpr sampler s(filter::linear);\n"
     "  if (in.kind > 2.5) {\n"                    // 컬러 글리프(이모지) — 아틀라스 색을 그대로
     "    // 커버리지는 전경색을 곱하지만 컬러는 **아틀라스 색이 곧 결과**다. 전경색을 곱하면\n"
     "    // 이모지가 글자색으로 물든다.\n"
     "    float2 ht = 0.5 / float2(colors.get_width(), colors.get_height());\n"
     "    float4 c = colors.sample(s, clamp(in.uv, in.uvb.xy + ht, in.uvb.zw - ht));\n"
     "    if (c.a < 0.04) discard_fragment();\n"
     "    return float4(c.rgb, c.a * in.color.a);\n"
     "  }\n"
     "  if (in.kind > 1.5) {\n"                    // 아이콘 coverage
     "    float2 ht = 0.5 / float2(icons.get_width(), icons.get_height());\n"
     "    float cov = icons.sample(s, clamp(in.uv, in.uvb.xy + ht, in.uvb.zw - ht)).a;\n"
     "    if (cov < 0.04) discard_fragment();\n"
     "    return float4(in.color.rgb, in.color.a * cov);\n"
     "  }\n"
     "  if (in.kind > 0.5) {\n"                    // 글리프 아틀라스
     "    // **자기 칸 안으로 자른다** — 칸 경계에서 이웃의 잉크가 딸려 오면 글자 위에 없는\n"
     "    // 획이 생긴다(위 슬롯이 블록 글자일 때 실제로 그랬다).\n"
     "    float2 ht = 0.5 / float2(glyphs.get_width(), glyphs.get_height());\n"
     "    float cov = glyphs.sample(s, clamp(in.uv, in.uvb.xy + ht, in.uvb.zw - ht)).r;\n"
     "    if (cov < 0.04) discard_fragment();\n"
     "    return float4(in.color.rgb, in.color.a * cov);\n"
     "  }\n"
     "  return in.color;\n"
     "}\n";

typedef struct { float rect_px[4]; float color[4]; float misc[4]; float cell[4]; } Uni;

/// `UITextInput` 은 문서 안의 **위치**와 **범위**를 타입으로 요구한다. 우리 문서는 조합 중
/// 문자열 하나뿐이라 위치는 그냥 정수 오프셋이다.
@interface MaruPos : UITextPosition
@property (nonatomic) NSUInteger off;
+ (instancetype)at:(NSUInteger)o;
@end
@implementation MaruPos
+ (instancetype)at:(NSUInteger)o { MaruPos *p = [MaruPos new]; p.off = o; return p; }
@end

@interface MaruRange : UITextRange
@property (nonatomic) NSUInteger from, to;
+ (instancetype)from:(NSUInteger)f to:(NSUInteger)t;
@end
@implementation MaruRange
+ (instancetype)from:(NSUInteger)f to:(NSUInteger)t {
    MaruRange *r = [MaruRange new]; r.from = MIN(f, t); r.to = MAX(f, t); return r;
}
- (UITextPosition *)start { return [MaruPos at:self.from]; }
- (UITextPosition *)end { return [MaruPos at:self.to]; }
- (BOOL)isEmpty { return self.from == self.to; }
@end

@interface ChromeView : UIView <UITextInput>
@end

@implementation ChromeView {
    id<MTLDevice> _dev;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipe;
    id<MTLTexture> _glyphTex;
    id<MTLTexture> _iconTex;
    id<MTLTexture> _colorTex;  // 이모지(컬러) 전용 RGBA 아틀라스
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
    /// **조합 중 문자열만 담는 1줄짜리 가짜 문서.** 확정 전에는 여기 있고 코어엔 안 간다 —
    /// 그게 IME 계약이다(자모가 셸로 새면 명령어 일부가 된다).
    NSMutableString *_composing;
    id<UITextInputDelegate> _inputDelegate;
    UITextInputStringTokenizer *_tokenizer;
    float _flingVy;   // 손을 뗀 뒤 남은 관성(프레임당 논리 px)
    float _ptrLastY;  // 직전 move 의 논리 y — 이동량을 내는 기준
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
        unsigned int one = c; // 미리 굽는 집합은 전부 단일 코드포인트(ASCII·박스)다
        maru_mobile_atlas_add(&one, 1, 0, (unsigned int)col, (unsigned int)row, (unsigned int)advance);
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
    // **컬러 전용 아틀라스**(이모지). 글자 아틀라스는 커버리지(R8)라 컬러 비트맵을 넣으면
    // 실루엣이 된다 — 같은 격자 크기로 RGBA 텍스처를 하나 더 세운다(계약 §이모지).
    MTLTextureDescriptor *ctd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:W height:H mipmapped:NO];
    _colorTex = [_dev newTextureWithDescriptor:ctd];
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
/// 논리 좌표 + 이벤트 시각. **판단은 코어가 한다** — 여기서는 좌표계만 되돌린다.
- (void)sendPointer:(unsigned int)phase touches:(NSSet<UITouch *> *)touches {
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    CGPoint p = [touch locationInView:self];
    UIEdgeInsets safe = self.safeAreaInsets;
    float lx = (float)(p.x - safe.left);
    float ly = (float)(p.y - safe.top);
    // 손을 뗀 뒤 흘릴 관성만 우리 몫이다 — Android 와 같은 식(마지막 이동량).
    if (phase == 1) { _flingVy = ly - _ptrLastY; _ptrLastY = ly; }
    if (phase == 0) { _flingVy = 0; _ptrLastY = ly; }
    maru_mobile_pointer(phase, lx, ly, (unsigned long long)(touch.timestamp * 1000.0));
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    CGPoint p = [touch locationInView:self];
    UIEdgeInsets safe = self.safeAreaInsets;
    // 플랫폼이 넘긴 것과 같은 논리 좌표계로 되돌린다 — 안 그러면 셀이 어긋난다.
    float lx = (float)(p.x - safe.left);
    float ly = (float)(p.y - safe.top);
    // **보조 키바가 먼저다.** 키바 위를 눌렀는데 본문 셀 판정으로 가면 키가 안 나간다.
    if (maru_mobile_keybar_tap(lx, ly)) {
        NSLog(@"MARU_KEYBAR pt=(%.0f,%.0f) armed=%u", lx, ly, maru_mobile_armed_mods());
        // 복사를 눌렀으면 코어가 꺼내 놓은 텍스트를 시스템 클립보드에 넣는다 —
        // **꺼내는 것은 코어, 쓰는 것만 플랫폼**이다(§3: 브리지엔 OS 호출이 없다).
        static unsigned char copy_buf[8192];
        unsigned int cn = maru_mobile_take_copy(copy_buf, sizeof copy_buf);
        if (cn > 0) {
            NSString *s = [[NSString alloc] initWithBytes:copy_buf length:cn
                                                 encoding:NSUTF8StringEncoding];
            if (s) {
                UIPasteboard.generalPasteboard.string = s;
                NSLog(@"MARU_COPY len=%u", cn);
            }
        }
        return;
    }
    unsigned int cell = maru_mobile_hit_cell(lx, ly);
    NSLog(@"MARU_TOUCH pt=(%.0f,%.0f) logical=(%.0f,%.0f) cell=(%u,%u)",
          p.x, p.y, lx, ly, cell >> 16, cell & 0xFFFF);
    [self sendPointer:0 touches:touches];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sendPointer:1 touches:touches];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sendPointer:2 touches:touches];
    NSLog(@"MARU_SCROLL fling=%.1f view_offset=%u sel=%u", _flingVy,
          maru_mobile_view_offset(), maru_mobile_has_selection());
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sendPointer:3 touches:touches];
    _flingVy = 0;
    // **취소도 남긴다.** 로그가 없어서 "배경으로 나갈 때 iOS 가 취소를 보내는가" 를 두 번
    // 헛짚었다 — 보내고 있었는데 그 사실이 안 보였다.
    NSLog(@"MARU_SCROLL cancelled view_offset=%u sel=%u", maru_mobile_view_offset(),
          maru_mobile_has_selection());
}

/// tick 에서 부른다. 남은 관성을 한 프레임 몫만큼 흘리고 감쇠시킨다.
- (void)stepFling {
    if (_flingVy == 0) return;
    maru_mobile_scroll(_flingVy);
    _flingVy *= 0.92f;                       // 실측 없이 고른 값 — 손 테스트로 맞춘다
    if (fabsf(_flingVy) < 0.5f) _flingVy = 0; // 영원히 도는 것을 막는다
}

- (BOOL)canBecomeFirstResponder { return YES; }
// **소프트 키보드를 막지 않는다.** 한때 빈 `inputView` 를 돌려줘 키보드를 감췄는데,
// 그러면 하드웨어 키보드가 없는 사용자는 **아무것도 입력할 수 없다** — 스크린샷을 깨끗하게
// 하려다 넣은 것이라 제품에는 틀린 동작이었다. Android 도 켜지면 키보드를 올린다.
- (BOOL)hasText { return YES; }

// ── UITextInput: 조합 중 문자열만 담는 1줄짜리 문서 ────────────────────────────
// 터미널에는 편집할 문서가 없다. 그런데 `UITextInput` 은 문서를 요구하고, 그 대가로
// **marked text**(조합 중 상태)를 준다 — 그게 있어야 확정 전 자모를 코어에 안 넣을 수 있다.
// 그래서 조합 중 문자열만 담는 가짜 문서를 두고, 확정될 때만 코어로 보낸다.

- (NSMutableString *)doc {
    if (!_composing) _composing = [NSMutableString string];
    return _composing;
}

/// 조합을 코어에 **확정**해 보낸다. 겉치레는 지운다.
- (void)commitComposing {
    if (self.doc.length == 0) return;
    const char *b = self.doc.UTF8String;
    if (b) maru_mobile_input(b, strlen(b));
    [self.doc setString:@""];
    maru_mobile_set_preedit("", 0);
}

- (void)setMarkedText:(NSString *)markedText selectedRange:(NSRange)selectedRange {
    [self.doc setString:markedText ?: @""];
    // **코어에 넣지 않는다.** 화면에만 흐리게 그릴 겉치레라 별도 경로로 보낸다.
    const char *b = self.doc.UTF8String;
    maru_mobile_set_preedit(b ?: "", b ? strlen(b) : 0);
    NSLog(@"MARU_IME marked=%@", self.doc);
}

- (void)unmarkText {
    // 조합이 확정됐다 — 이제 코어로 보낸다.
    if (self.doc.length) NSLog(@"MARU_IME commit=%@", self.doc);
    [self commitComposing];
}

- (UITextRange *)markedTextRange {
    return self.doc.length ? [MaruRange from:0 to:self.doc.length] : nil;
}
- (NSDictionary *)markedTextStyle { return nil; }
- (void)setMarkedTextStyle:(NSDictionary *)s { (void)s; }

- (void)insertText:(NSString *)text {
    // 조합이 있던 자리면 그것을 대체하는 확정이다.
    [self.doc setString:@""];
    maru_mobile_set_preedit("", 0);
    const char *b = text.UTF8String;
    if (!b) return;
    NSLog(@"MARU_INPUT text=%@ total=%u", text, maru_mobile_input(b, strlen(b)));
}
/// **IME 가 입력을 고쳐 쓰지 못하게 한다.** `UITextInput` 은 `UITextInputTraits` 를 함께 갖고,
/// 아무것도 선언하지 않으면 iOS 기본값이 붙는다 — 자동 대문자·자동 수정·**스마트 문장부호**.
/// 그래서 `"` 가 `“ ”` 로, `--` 가 `- –` 로 바뀌어 들어갔다(시뮬레이터 실측). 셸에서 따옴표도
/// `--` 플래그도 못 치는 상태였다. Android 는 이미 `TYPE_TEXT_FLAG_NO_SUGGESTIONS` 로 같은
/// 것을 끄고 있었고, 이쪽만 비어 있었다.
///
/// `keyboardType` 은 **안 건드린다** — ASCII 배열을 요구하면 한글 입력이 불편해진다.
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextSpellCheckingType)spellCheckingType { return UITextSpellCheckingTypeNo; }
- (UITextSmartQuotesType)smartQuotesType { return UITextSmartQuotesTypeNo; }
- (UITextSmartDashesType)smartDashesType { return UITextSmartDashesTypeNo; }
- (UITextSmartInsertDeleteType)smartInsertDeleteType { return UITextSmartInsertDeleteTypeNo; }

- (void)deleteBackward {
    if (self.doc.length) {  // 조합 중이면 조합에서 지운다 — 코어는 안 건드린다
        [self.doc deleteCharactersInRange:NSMakeRange(self.doc.length - 1, 1)];
        const char *b = self.doc.UTF8String;
        maru_mobile_set_preedit(b ?: "", b ? strlen(b) : 0);
        return;
    }
    // **바이트를 손으로 적지 않는다.** 모드에 따라 0x7F 와 0x08 이 갈린다.
    maru_mobile_key(MARU_KEY_BACKSPACE, 0, 0);
}

// ── 문서 조회/편집 ──────────────────────────────────────────────────────────
- (NSString *)textInRange:(UITextRange *)range {
    MaruRange *r = (MaruRange *)range;
    if (r.to > self.doc.length) return @"";
    return [self.doc substringWithRange:NSMakeRange(r.from, r.to - r.from)];
}
- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    (void)range;
    [self insertText:text];
}
- (UITextRange *)selectedTextRange { return [MaruRange from:self.doc.length to:self.doc.length]; }
- (void)setSelectedTextRange:(UITextRange *)r { (void)r; }
- (UITextPosition *)beginningOfDocument {
    // UIKit 이 `UITextInput` 세션을 열면 여기부터 부른다 — 한 번만 남겨 "프로토콜이 실제로
    // 쓰이는지" 를 판정한다(선언만 하고 안 쓰이는 경우와 가른다).
    static BOOL logged;
    if (!logged) { logged = YES; NSLog(@"MARU_IME protocol=UITextInput"); }
    return [MaruPos at:0];
}
- (UITextPosition *)endOfDocument { return [MaruPos at:self.doc.length]; }

// ── 위치 계산 ───────────────────────────────────────────────────────────────
- (UITextRange *)textRangeFromPosition:(UITextPosition *)f toPosition:(UITextPosition *)t {
    return [MaruRange from:((MaruPos *)f).off to:((MaruPos *)t).off];
}
- (UITextPosition *)positionFromPosition:(UITextPosition *)p offset:(NSInteger)o {
    NSInteger n = (NSInteger)((MaruPos *)p).off + o;
    if (n < 0 || n > (NSInteger)self.doc.length) return nil;
    return [MaruPos at:(NSUInteger)n];
}
- (UITextPosition *)positionFromPosition:(UITextPosition *)p
                             inDirection:(UITextLayoutDirection)d offset:(NSInteger)o {
    NSInteger sign = (d == UITextLayoutDirectionLeft || d == UITextLayoutDirectionUp) ? -1 : 1;
    return [self positionFromPosition:p offset:sign * o];
}
- (NSComparisonResult)comparePosition:(UITextPosition *)a toPosition:(UITextPosition *)b {
    NSUInteger x = ((MaruPos *)a).off, y = ((MaruPos *)b).off;
    return x < y ? NSOrderedAscending : (x > y ? NSOrderedDescending : NSOrderedSame);
}
- (NSInteger)offsetFromPosition:(UITextPosition *)a toPosition:(UITextPosition *)b {
    return (NSInteger)((MaruPos *)b).off - (NSInteger)((MaruPos *)a).off;
}
- (UITextPosition *)positionWithinRange:(UITextRange *)r
                    farthestInDirection:(UITextLayoutDirection)d {
    MaruRange *m = (MaruRange *)r;
    return [MaruPos at:(d == UITextLayoutDirectionLeft || d == UITextLayoutDirectionUp) ? m.from : m.to];
}
- (UITextRange *)characterRangeByExtendingPosition:(UITextPosition *)p
                                       inDirection:(UITextLayoutDirection)d {
    NSUInteger o = ((MaruPos *)p).off;
    if (d == UITextLayoutDirectionLeft || d == UITextLayoutDirectionUp)
        return [MaruRange from:0 to:o];
    return [MaruRange from:o to:self.doc.length];
}
- (UITextWritingDirection)baseWritingDirectionForPosition:(UITextPosition *)p
                                              inDirection:(UITextStorageDirection)d {
    (void)p; (void)d;
    return UITextWritingDirectionLeftToRight;
}
- (void)setBaseWritingDirection:(UITextWritingDirection)w forRange:(UITextRange *)r {
    (void)w; (void)r;
}

// ── 기하: **IME 후보창이 이 값을 보고 따라온다** ────────────────────────────
// 커서 자리는 배치를 아는 쪽(코어)이 답한다 — 여기서 셀 크기를 다시 계산하면 어긋난다.
- (CGRect)caretRectForPosition:(UITextPosition *)p {
    (void)p;
    unsigned long long r = maru_mobile_caret_rect();
    if (r == 0) return CGRectZero;
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat x = (CGFloat)((r >> 48) & 0xFFFF) + safe.left;
    CGFloat y = (CGFloat)((r >> 32) & 0xFFFF) + safe.top;
    return CGRectMake(x, y, (CGFloat)((r >> 16) & 0xFFFF), (CGFloat)(r & 0xFFFF));
}
- (CGRect)firstRectForRange:(UITextRange *)range {
    (void)range;
    return [self caretRectForPosition:nil];
}
- (NSArray<UITextSelectionRect *> *)selectionRectsForRange:(UITextRange *)range {
    (void)range;
    return @[];
}
- (UITextPosition *)closestPositionToPoint:(CGPoint)pt { (void)pt; return [self endOfDocument]; }
- (UITextPosition *)closestPositionToPoint:(CGPoint)pt withinRange:(UITextRange *)r {
    (void)pt; return ((MaruRange *)r).end;
}
- (UITextRange *)characterRangeAtPoint:(CGPoint)pt { (void)pt; return nil; }

- (id<UITextInputTokenizer>)tokenizer {
    if (!_tokenizer) _tokenizer = [[UITextInputStringTokenizer alloc] initWithTextInput:self];
    return _tokenizer;
}
- (id<UITextInputDelegate>)inputDelegate { return _inputDelegate; }
- (void)setInputDelegate:(id<UITextInputDelegate>)d { _inputDelegate = d; }

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
// **아틀라스를 키운다.** Zig 가 모은 미등록 코드포인트를 그 슬롯에만 구워 올린다 —
// 텍스처 전체를 다시 만들지 않고 `replaceRegion` 으로 그 칸만 바꾼다(여섯 기능 4번과 같은 경로).
/// 이모지 한 글자를 **컬러 아틀라스**에 굽는다.
///
/// 세 가지가 함께 필요하다(계약 §이모지): ① BMP 밖 글자는 UTF-16 **서러게이트 쌍**이라야
/// CoreText 가 한 글자로 본다 — `(unichar)cp` 로 자르면 엉뚱한 글자가 되거나(0x1F600→0xF600)
/// 아예 없다. ② 번들 폰트에 이모지가 없으므로 `CTFontCreateForString` 으로 시스템이 고르게
/// 한다. ③ 컬러 비트맵이라 RGBA 컨텍스트에 그린다(커버리지 R8 에 그리면 실루엣).
/// 코드포인트 **열**을 `NSString` 으로 편다(BMP 밖은 서러게이트 쌍).
///
/// 열째로 넘겨야 CoreText 가 결합한다 — `❤`+VS16 을 따로 그리면 하트와 보이지 않는 선택자가
/// 각각 그려질 뿐 컬러 하트가 안 된다.
static NSString *MaruClusterString(const unsigned int *cps, unsigned int n) {
    unichar units[MARU_MAX_CLUSTER * 2];
    NSUInteger k = 0;
    for (unsigned int i = 0; i < n && k + 2 <= sizeof units / sizeof units[0]; i++) {
        unsigned int cp = cps[i];
        if (cp > 0x10FFFF) continue;
        if (cp > 0xFFFF) {
            unsigned int v = cp - 0x10000;
            units[k++] = (unichar)(0xD800 + (v >> 10));
            units[k++] = (unichar)(0xDC00 + (v & 0x3FF));
        } else {
            units[k++] = (unichar)cp;
        }
    }
    if (k == 0) return nil;
    return [NSString stringWithCharacters:units length:k];
}

- (BOOL)bakeColorGlyph:(const unsigned int *)cps count:(unsigned int)ncp style:(unsigned int)style {
    if (!_colorTex) return NO;
    const unsigned int CW = MARU_ATLAS_CELL_W, CH = MARU_ATLAS_CELL_H;
    unsigned int slot = maru_mobile_next_color_slot(_atlasCols);
    if (slot == 0xFFFFFFFF) return NO;   // 버릴 자리도 없다(전부 이번 프레임 것)
    unsigned int col = slot >> 16, row = slot & 0xFFFF;

    NSString *str = MaruClusterString(cps, ncp);
    if (!str) return NO;
    const NSUInteger unit_n = str.length;

    // ② 이 글자를 실제로 가진 폰트를 시스템이 고르게 한다(번들 폰트엔 이모지가 없다).
    CTFontRef base = _atlasFaces[style & 3] ?: _atlasFont;
    CTFontRef face = CTFontCreateForString(base, (__bridge CFStringRef)str,
                                           CFRangeMake(0, (CFIndex)unit_n));
    if (!face) return NO;

    // ③ RGBA 로 굽는다 — 컬러 비트맵을 커버리지에 넣으면 색이 사라진다.
    uint8_t *rgba = calloc(CW * CH * 4, 1);
    if (!rgba) { CFRelease(face); return NO; }
    CGColorSpaceRef rgb_cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba, CW, CH, 8, CW * 4, rgb_cs,
                                             kCGImageAlphaPremultipliedLast);
    BOOL ok = NO;
    if (ctx) {
        CTLineRef line = CTLineCreateWithAttributedString(
            (__bridge CFAttributedStringRef)[[NSAttributedString alloc]
                initWithString:str
                    attributes:@{(__bridge NSString *)kCTFontAttributeName: (__bridge id)face}]);
        if (line) {
            CGContextSetTextPosition(ctx, 1, 6);
            CTLineDraw(line, ctx);   // 컬러 글리프(sbix/COLR)는 CTLineDraw 가 색까지 그린다
            CFRelease(line);
            ok = YES;
        }
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(rgb_cs);
    if (ok) {
        [_colorTex replaceRegion:MTLRegionMake2D(col * CW, row * CH, CW, CH) mipmapLevel:0
                       withBytes:rgba bytesPerRow:CW * 4];
        maru_mobile_color_atlas_add(cps, ncp, style, col, row, CW);  // 이모지는 2셀 = 슬롯 전체
    }
    free(rgba);
    CFRelease(face);
    return ok;
}

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
        // **열을 통째로 읽는다.** base 만 읽으면 `❤` 와 `❤️` 가 같아 보여 VS16 결합이 단색이 된다.
        unsigned int cps[MARU_MAX_CLUSTER];
        unsigned int ncp = maru_mobile_missing_len((unsigned int)i);
        if (ncp > MARU_MAX_CLUSTER) ncp = MARU_MAX_CLUSTER;
        for (unsigned int j = 0; j < ncp; j++) cps[j] = maru_mobile_missing_cp_at((unsigned int)i, j);
        unsigned int style = maru_mobile_missing_style((unsigned int)i);
        if (ncp == 0 || cps[0] == 0 || cps[0] > 0x10FFFF) continue;
        // **컬러 글리프는 다른 아틀라스로 간다.** 커버리지(R8)에 컬러를 구우면 실루엣이 된다.
        if (maru_mobile_missing_is_color((unsigned int)i)) {
            if ([self bakeColorGlyph:cps count:ncp style:style]) added++;
            continue;
        }
        CTFontRef face = _atlasFaces[style & 3] ?: _atlasFont;
        unsigned int slot = maru_mobile_next_slot(_atlasCols);
        // 꽉 차면 브리지가 **가장 안 쓰인 자리를 재사용하라고** 내준다(축출). 여기서 빈 자리와
        // 재사용 자리를 가릴 필요가 없다 — 아래 `memset` + 슬롯 전체 `replaceRegion` 이 옛 글리프를
        // 완전히 덮으므로 잔상이 안 남는다. sentinel 은 **이번 프레임에 그려진 것만 남아 버릴 것이
        // 없다**는 뜻이라(한 화면이 512종을 넘겼다) 이번 프레임은 포기한다.
        if (slot == 0xFFFFFFFF) break;
        unsigned int col = slot >> 16, row = slot & 0xFFFF;
        memset(cell, 0, CW * CH);
        // **합성이 먼저다**(renderer 계약). 박스·블록·브라유는 폰트로 구우면 셀에 안 맞아
        // 끊긴다 — 합성은 셀을 가장자리까지 채운다. 0 이면 합성 대상이 아니라 폰트로 간다.
        // 합성 대상(박스·블록·브라유)은 전부 단일 코드포인트라 base 만 넘긴다.
        if (maru_mobile_synthesize(cps[0], cell, CW) != 0) {
            [_glyphTex replaceRegion:MTLRegionMake2D(col * CW, row * CH, CW, CH) mipmapLevel:0
                           withBytes:cell bytesPerRow:CW];
            maru_mobile_atlas_add(cps, ncp, style, col, row, CW / 2);
            added++;
            continue;
        }
        // **CTLine 으로 그린다**(글리프 1:1 이 아니라). 예전에는 `CTFontGetGlyphsForCharacters` +
        // `CTFontDrawGlyphs` 로 **코드포인트 하나당 글리프 하나**를 그려서 클러스터가 결합되지
        // 않았다 — `❤`+VS16 이 하트와 보이지 않는 선택자로 갈렸다. CTLine 은 결합·리거처·**폰트
        // 폴백**을 다 처리한다(번들 폰트에 없는 기호를 시스템 폰트로 잇던 수동 폴백도 여기에
        // 흡수된다 — 두 벌로 두면 한쪽만 고쳐져 조용히 어긋난다).
        NSString *str = MaruClusterString(cps, ncp);
        if (!str) continue;
        CGContextRef ctx = CGBitmapContextCreate(cell, CW, CH, 8, CW, cs, kCGImageAlphaNone);
        if (!ctx) continue;
        // **색을 문자열에 실어야 한다.** `CTLineDraw` 는 컨텍스트 fill color 가 아니라 run 의
        // 전경색 속성을 보고, 없으면 **검정**을 쓴다 — 커버리지(회색조 0) 아틀라스에서 검정은
        // 곧 빈칸이라, 온디맨드로 굽는 글자가 통째로 사라졌다(화면으로 잡았다). 앞서 쓰던
        // `CTFontDrawGlyphs` 는 컨텍스트 색을 따라가서 이 함정이 없었다.
        CGColorRef ink = CGColorCreateGenericGray(1.0, 1.0);
        CTLineRef line = CTLineCreateWithAttributedString(
            (__bridge CFAttributedStringRef)[[NSAttributedString alloc]
                initWithString:str
                    attributes:@{
                        (__bridge NSString *)kCTFontAttributeName: (__bridge id)face,
                        (__bridge NSString *)kCTForegroundColorAttributeName: (__bridge id)ink,
                    }]);
        CGColorRelease(ink);
        double width = 0;
        if (line) {
            CGContextSetTextPosition(ctx, 1, 8);   // 셀 하나짜리 컨텍스트라 원점이 곧 셀 원점이다
            CTLineDraw(line, ctx);
            width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
            CFRelease(line);
        }
        CGContextRelease(ctx);
        unsigned int advance = (unsigned int)(width + 0.5);
        if (advance == 0) advance = CW / 2;
        [_glyphTex replaceRegion:MTLRegionMake2D(col * CW, row * CH, CW, CH) mipmapLevel:0
                       withBytes:cell bytesPerRow:CW];
        maru_mobile_atlas_add(cps, ncp, style, col, row, advance);
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
    // **실패했으면 렌더 루프를 걸지 않는다.** 위 셰이더 실패는 `return` 하는데 여기만 로그를
    // 남기고 계속 갔다 — 그러면 tick 이 nil 파이프라인을 `setRenderPipelineState:` 에 넘긴다.
    // Android 는 `g.ready` 를 안 세워 draw 가 통째로 no-op 이 된다. 같은 모양으로 맞춘다:
    // 검은 화면 + 로그 한 줄이지, 죽는 것이 아니다.
    if (!_pipe) { NSLog(@"MARU_CHROME pipeline_fail=%@", err); return self; }
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
    // **제스처 인식기를 안 쓴다.** 인식되는 순간 UIKit 이 touchesMoved 를 끊어(cancel) 길게
    // 눌러 끄는 선택이 죽는다 — 원시 터치를 그대로 코어에 넘기고 뜻은 코어가 정한다(§3.1).
    // 관성만 우리가 계산한다(Android 와 같은 식).
    // **길게 누름 지연은 OS 가 정한다.** 코어에 박으면 플랫폼 차이를 지운다 — 실측으로 iOS 는
    // 500ms, Android 는 400ms 였다(같은 값이 아니다). UIKit 의 기본값을 그대로 넘긴다.
    //
    // 한계: 접근성 "터치 조절 → 유지 시간" 은 공개 API 로 못 읽는다. UIKit 은 자기 인식기에
    // 그것을 내부에서 적용하므로, 그 설정까지 따르려면 우리가 판단하는 대신 `UILongPress-
    // GestureRecognizer` 를 쓰는 쪽으로 가야 한다(§3.1 의 "판단은 코어" 와 갈리는 자리다).
    UILongPressGestureRecognizer *lp = [UILongPressGestureRecognizer new];
    maru_mobile_set_long_press_ms((unsigned int)(lp.minimumPressDuration * 1000.0));
    NSLog(@"MARU_INPUT long_press_ms=%u (sent %.0f)", maru_mobile_long_press_ms(),
          lp.minimumPressDuration * 1000.0);
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
    [self stepFling];   // 손을 뗀 뒤 남은 관성을 프레임마다 흘린다
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
    unsigned int n = maru_mobile_build((unsigned int)logical.width, (unsigned int)logical.height,
                                       (unsigned long long)(CACurrentMediaTime() * 1000.0));
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
        // kind 4·5 는 **컬러 아틀라스**(다른 텍스처)다. 5 는 그 왼쪽 절반이라 3 과 같은 배수
        // 규칙을 쓰고, 셰이더에는 3(=컬러)으로 넘긴다 — 텍스처만 다르고 좌표 규칙은 같다.
        int half = (q->kind == 3 || q->kind == 5);
        int color = (q->kind == 4 || q->kind == 5);
        float cols = (q->kind == 2) ? 1.0f : (float)_atlasCols * (half ? 2.0f : 1.0f);
        float rows = (q->kind == 2) ? (float)maru_mobile_icon_count() : (float)_atlasRows;
        float cx = (float)q->cell_x * (half ? 2.0f : 1.0f);
        float kind = color ? 3.0f : (half ? 1.0f : (float)q->kind);
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
        if (_colorTex) [e setFragmentTexture:_colorTex atIndex:2];
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
    // **누르고 있던 손가락을 정리한다.** iOS 는 배경으로 나갈 때 `touchesCancelled` 를
    // 보내지 않는다(로그로 확인했다) — 안 정리하면 브리지가 "누르고 있다" 를 들고 있다가
    // 돌아온 프레임에서 옛 자리를 길게 누른 것으로 판정할 수 있다.
    maru_mobile_pointer(3, 0, 0, 0);
    // **배경에서는 그리지 않는다.** 로그만 남기고 CADisplayLink 를 계속 돌리면 백그라운드
    // GPU 작업이 되어 앱이 종료될 수 있다(Apple 이 명시적으로 금지한다). Android 는
    // 창이 죽을 때 Vulkan 을 부수는데 iOS 만 아무것도 안 하고 있었다.
    [(ChromeView *)self.window.rootViewController.view setRenderingPaused:YES];
    // 포커스도 코어에 알린다(DEC 1004 — vim 의 FocusGained/Lost). 모바일은 배경↔복귀가
    // 데스크톱보다 훨씬 잦은데 아무 신호도 안 보내고 있었다.
    maru_mobile_report_focus(0);
    NSLog(@"MARU_LIFECYCLE background");
}
- (void)applicationWillEnterForeground:(UIApplication *)app {
    [(ChromeView *)self.window.rootViewController.view setRenderingPaused:NO];
    maru_mobile_report_focus(1);
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
