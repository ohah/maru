// iOS host (L4). UIKit 창·생명주기·터치·키보드 + Metal 백엔드 + CoreText 폰트 래스터.
//
// **플랫폼은 배치를 모른다.** Zig 쪽 `chrome.ui.tree` 로 조립한 UI 를 `paint` 가 quad 로
// 낮춰 주면 여기서는 그리기만 한다 — 그게 maru 의 레이어 계약(L3 chrome 이 배치,
// L4 platform 이 그리기)이다. 계약은 docs/mobile-platform.md 가 단일 출처다.
// 선언은 `platform/mobile/mobile_host_abi.h` 가 단일 출처다 — 여기서 다시 적지 않는다.
#include "../mobile/mobile_host_abi.h"
#include "../mobile_host/ssh_pump.h"
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreText/CoreText.h>



// 둥근 모서리를 프래그먼트에서 자른다 — maru 의 rich quad 가 corner_radii 를 쓰므로
// 그 모양이 실제로 나오는지 보려면 필요하다.
// 정의는 파일 뒤에 있고 그리는 경로가 먼저 부른다 — 선언이 없으면 implicit declaration 이다
// (Android 에서 같은 순서로 두 번 데였다).
static void drainConfigWrite(void);
static void startSshIfAsked(void);
static void driveControlChannel(void);

/// 컨트롤 채널을 연 시각(ms, 0 이면 안 열었다). **시한을 재는 것은 host 의 일이다** —
/// 코어에는 시계가 없다(계약 §4a: 5초).
static double gControlOpenMs = 0;
/// 「아직 때가 아니다」로 되돌린 첫 시각(ms, 0 이면 되돌린 적 없다). **재시도에도 마감이 있다** —
/// 닫힘이 영영 안 끝나면 화면이 조용히 「받는 중」에 머문다(계약 §4a: 실패하면 그 화면이 말한다).
static double gControlRetryMs = 0;
static void pumpSshOnMainThread(void);

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
/// 배경으로 나갈 때 AppDelegate 가 부른다 — 키바가 잡고 있던 터치를 푼다.
/// 같은 자리에서 밀린 화면(설정)이 잡고 있던 터치를 푼다.
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
    double _paceLast, _paceMs[MARU_FRAME_PACE_SAMPLES];
    int _paceN, _paceWarm;
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
    /// 소프트 키보드가 덮는 높이(논리 px, 뷰 좌표). 레이아웃 가용 높이에서 뺀다.
    CGFloat _keyboardH;
}

/// 키보드 프레임 변화를 받아 `_keyboardH` 를 갱신한다.
///
/// **`WillChangeFrame` 하나만 본다.** show/hide 를 따로 받으면 회전·분할 키보드·높이 변화(예:
/// 예측 입력 줄 토글)에서 상태가 갈린다 — 이 알림은 그 전부를 같은 모양으로 준다.
/// 화면 밖으로 나간 프레임(숨김)은 교집합이 0 이라 자연히 0 이 된다.
- (void)maruKeyboardFrameChanged:(NSNotification *)note {
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inView = [self convertRect:[self.window convertRect:end fromWindow:nil] fromView:nil];
    CGRect overlap = CGRectIntersection(self.bounds, inView);
    CGFloat h = CGRectIsNull(overlap) ? 0 : overlap.size.height;
    if (fabs(h - _keyboardH) < 0.5) return;
    _keyboardH = h;
    NSLog(@"MARU_KEYBOARD height=%.0f", (double)h);
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
                (CTFontDescriptorRef)CFArrayGetValueAtIndex(descs, 0), maru_mobile_atlas_text_px(), NULL);
        }
        if (descs) CFRelease(descs);
    }
    if (!base) {  // 번들 폰트가 없으면 예전 경로로 — 조용히 다른 글꼴이 되지 않게 로그를 남긴다
        NSLog(@"MARU_CHROME bundled_font_missing fallback=Menlo");
        base = CTFontCreateWithName(CFSTR("Menlo"), maru_mobile_atlas_text_px(), NULL);
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
                    (CTFontDescriptorRef)CFArrayGetValueAtIndex(ds, 0), maru_mobile_atlas_text_px(), NULL);
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
/// **`UITouch` 에는 숫자 id 가 없다.** 계약이 요구하는 것은 "`down` 부터 그 손가락의 `up` 까지
/// 같은 불투명 정수" 뿐이고, `UITouch` 객체는 그 동안 같은 인스턴스가 유지되므로 **포인터
/// 주소를 접어** 쓴다. 값의 의미는 코어가 안 가정한다(계약 §3.1).
static unsigned int maruPointerId(UITouch *t) {
    return (unsigned int)(((uintptr_t)t >> 4) & 0x7FFFFFFF);
}

/// **손가락 전부를 보낸다.** 비소유자의 기준이 낡으면 그 손가락이 이어받는 순간 옛 자리에서
/// 델타가 나와 화면이 점프한다(T1 이 없앤 병) — 소유권 판정은 코어가 한다.
- (void)sendPointer:(unsigned int)phase touches:(NSSet<UITouch *> *)touches {
    UIEdgeInsets safe = self.safeAreaInsets;
    for (UITouch *touch in touches) {
        CGPoint p = [touch locationInView:self];
        float lx = (float)(p.x - safe.left);
        float ly = (float)(p.y - safe.top);
        unsigned int pid = maruPointerId(touch);
        double t_ms = touch.timestamp * 1000.0;
        // **관성은 코어가 든다.** 전에는 여기서 속도를 쟀는데, 그러려면 "이 제스처가 본문
        // 것인가" 를 알아야 하고 그 지식은 R2 로 사라졌다 — 남은 채로 두니 키바를 비스듬히
        // 튕겨도 본문이 흘렀다. 목적지를 아는 쪽이 재는 것이 맞다(§3.1).
        maru_mobile_pointer(phase, pid, lx, ly, (unsigned long long)t_ms);
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // **어디로 갈지는 코어가 정한다**(계약 §3.1) — 뷰는 좌표와 id 만 나른다. 목적지도, 그
    // 제스처의 나머지 손가락을 같은 곳으로 보내는 것도 코어가 든다.
    UITouch *first = touches.anyObject; // 로그용 — 이 이벤트의 아무 손가락이면 된다
    if (first) {
        CGPoint p = [first locationInView:self];
        UIEdgeInsets safe = self.safeAreaInsets;
        float lx = (float)(p.x - safe.left);
        float ly = (float)(p.y - safe.top);
        unsigned int cell = maru_mobile_hit_cell(lx, ly);
        NSLog(@"MARU_TOUCH pt=(%.0f,%.0f) logical=(%.0f,%.0f) cell=(%u,%u)",
              p.x, p.y, lx, ly, cell >> 16, cell & 0xFFFF);
    }
    [self sendPointer:0 touches:touches];
}

/// **어디로 갈지는 코어가 정한다**(계약 §3.1) — 뷰는 좌표와 손가락 id 만 나른다. 전에는
/// `routeChrome:`·`routeKeybar:` 로 여기서 골랐고 그 답을 `_chromeActive`·`_keybarActive` 로
/// 들었는데, **같은 사실을 두 층이 들다** 보니 정리도 두 곳에서 해야 했다("브리지와 뷰 양쪽을
/// 푼다" 는 주석이 그 값이었다). 그 상태를 지웠다.
- (void)finishGesture {
    // **복사는 늘 시도한다.** 목적지를 뷰가 더는 모르므로 "키바가 끝났을 때만" 이라고 못 적는다 —
    // `take_copy` 는 꺼낼 것이 없으면 0 을 돌려주므로 그냥 묻는다.
    // **이름을 그대로 둔다** — 판정자와 검증 기록이 `MARU_KEYBAR` 를 본다. 다만 이제 이 줄은
    // "키바 제스처가 끝났다" 가 아니라 **어떤 제스처든 끝났고 그때 눌러 둔 수정자가 이랬다** 는
    // 뜻이다(목적지를 host 가 더는 모른다).
    NSLog(@"MARU_KEYBAR armed=%u", maru_mobile_armed_mods());
    static unsigned char copy_buf[8192];
    unsigned int cn = maru_mobile_take_copy(copy_buf, sizeof copy_buf);
    if (cn > 0) {
        // **바이트를 그대로 넣는다 — 변환을 안 거친다.** `initWithBytes:NSUTF8StringEncoding` 은
        // 잘못된 UTF-8 에 nil 을 돌려주고, 그 nil 을 검사하는 가지를 두면 실패가 조용히 지나간다.
        NSData *d = [NSData dataWithBytes:copy_buf length:cn];
        [UIPasteboard.generalPasteboard setData:d forPasteboardType:@"public.utf8-plain-text"];
        NSLog(@"MARU_COPY len=%u", cn);
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sendPointer:1 touches:touches];
}

/// 이 이벤트 뒤에도 **닿아 있는 손가락이 남아 있나.** 제스처의 끝은 마지막 손가락이 떼질
/// 때다 — 손가락마다 끝내면 둘째가 떼는 순간 첫 손가락이 잡고 있던 것이 풀린다.
- (BOOL)anyTouchRemains:(UIEvent *)event {
    for (UITouch *t in event.allTouches) {
        // **우리 뷰의 손가락만 센다.** `allTouches` 는 이벤트에 딸린 전부라 다른 뷰의 터치가
        // 섞일 수 있고, 그러면 "마지막 손가락" 이 영영 거짓이 되어 **그 표면이 잡힌 채 굳는다**
        // (관성도 새 터치도 안 먹는다). 같은 이유로 이어받기도 우리 것만 본다.
        if (t.view != self) continue;
        if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) return YES;
    }
    return NO;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    BOOL last = ![self anyTouchRemains:event];
    [self sendPointer:2 touches:touches];
    if (last) [self finishGesture];
    NSLog(@"MARU_SCROLL view_offset=%u sel=%u", maru_mobile_view_offset(),
          maru_mobile_has_selection());
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // **취소는 손가락을 안 가린다**(계약 §3.1) — 코어가 전부 놓는다.
    maru_mobile_pointer(3, 0, 0, 0, 0);
    NSLog(@"MARU_SCROLL cancelled view_offset=%u sel=%u", maru_mobile_view_offset(),
          maru_mobile_has_selection());
}

/// 좌측 가장자리에서 밀면 화면 한 장을 뺀다. **끝났을 때 한 번만** 민다 — 진행 중에 밀면
/// 손가락을 되돌려도 이미 넘어가 있다.
- (void)maruEdgeBack:(UIScreenEdgePanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    unsigned int popped = maru_mobile_pop_screen();
    NSLog(@"MARU_NAV edge_back popped=%u", popped);
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
/// `keyboardType` 은 **터미널에서는 안 건드린다** — ASCII 배열을 요구하면 한글 입력이 불편해진다.
/// 다만 **설정의 숫자 칸**에서는 숫자 패드를 요구한다(`maru_mobile_input_kind() == 1`): 그 자리는
/// 숫자만 받고, 숫자 패드에는 조합이 없어 IME 위험도 없다. 종류가 바뀌면 `reloadInputViews` 로
/// **이미 떠 있는 키보드를 갈아 끼워야** 한다 — 안 그러면 다음에 열 때나 반영된다.
- (UIKeyboardType)keyboardType {
    return maru_mobile_input_kind() == 1 ? UIKeyboardTypeNumberPad : UIKeyboardTypeDefault;
}
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
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(maruKeyboardFrameChanged:)
                                               name:UIKeyboardWillChangeFrameNotification
                                             object:nil];
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

    // **뒤로가기는 좌측 가장자리 스와이프다**([UX §3](../../../docs/mobile-ux.md) — Android 는
    // 하드웨어 뒤로가기, iOS 는 이것). 이 앱에는 화면이 셋이 됐는데(세션 목록 → 터미널 →
    // 설정) iOS 에는 그 스택을 되감을 수단이 아예 없었다 — **설정에 영영 못 들어가는** 상태로
    // 나갈 뻔했다.
    //
    // **`UIScreenEdgePanGestureRecognizer` 를 쓴다.** 터치를 직접 판정하지 않는 이유는 그
    // 자리가 본문 선택·스크롤과 겹치기 때문이다 — 가장자리 인식기는 OS 가 그 구분을 이미
    // 갖고 있고, 우리 `touchesBegan` 은 인식되는 순간 취소(cancel)를 받아 **선택이 남지 않는다**.
    //
    // **이 경로는 스크립트로 검증이 안 된다.** `idb ui swipe` 의 합성 터치는 `touchesBegan`
    // 에는 닿는데(로그로 확인) **제스처 인식기에는 안 닿는다** — 가장자리 조건을 뺀 평범한
    // `UIPanGestureRecognizer` 를 임시로 붙여도 한 번도 안 불렸다. 그래서 이 자리는 사람이
    // 시뮬레이터에서 밀어 보는 것이 유일한 판정이다([검증 행렬](../../../docs/verification-matrix.md)
    // 의 "iOS 여러 줄 선택 드래그" 와 같은 부류다).
    // **멀티터치를 켠다**(T3). 기본값이 `NO` 라 이 뷰는 손가락 하나만 받고 있었다 — 둘째
    // 손가락은 `touchesBegan:` 조차 안 왔다. 켜는 순간 `touches` 에 여럿이 들어오므로
    // **`anyObject` 를 쓰는 자리를 한 곳도 남기면 안 된다**(그 순간 진짜로 임의 선택이 된다).
    self.multipleTouchEnabled = YES;

    UIScreenEdgePanGestureRecognizer *edge =
        [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(maruEdgeBack:)];
    edge.edges = UIRectEdgeLeft;
    [self addGestureRecognizer:edge];
    // **붙었다는 사실을 로그로 남긴다.** 이 경로는 스크립트로 못 밟는다(아래 주석) — 그러면
    // "안 붙어서 안 되는 것" 과 "붙었는데 손짓이 안 온 것" 을 나중에 못 가른다.
    NSLog(@"MARU_NAV edge_recognizer_attached n=%lu", (unsigned long)self.gestureRecognizers.count);
    _queue = [_dev newCommandQueue];
    [self loadAtlas];

    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    // **30Hz(comfort).** 터미널은 매 vsync 마다 새로 그릴 것이 없고, 모바일은 배터리·발열이
    // 사용자에게 보인다. Android 도 같은 값이다. **데스크톱은 60 이라 다르다**(`render.frame-rate`
    // 기본값 — hover/scroll 지연을 우선하고 전력 여유가 있다). 실측으로 이 경로가 33.33ms 를
    // 낸다는 것을 확인했다(`present-ios`).
    //
    // **여기가 값을 정하는 유일한 자리다** — OS 에 범위를 선언하면 기기 주사율과 무관하게
    // 지켜진다(Android 는 vsync 콜백에서 경과 시간으로 직접 재야 한다). 60 을 넘기려면
    // `Info.plist` 에 `CADisableMinimumFrameDuration` 이 필요하다 — 지금은 없고, 없으면
    // ProMotion 기기에서도 60 에서 잘린다. config(M10)로 열 때 함께 본다.
    if (@available(iOS 15.0, *)) {
        _link.preferredFrameRateRange =
            CAFrameRateRangeMake(MARU_FRAME_TARGET_HZ, MARU_FRAME_TARGET_HZ, MARU_FRAME_TARGET_HZ);
    } else {
        _link.preferredFramesPerSecond = MARU_FRAME_TARGET_HZ;
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
    // **첫 프레임들은 버린다.** 아틀라스를 굽고 스왑체인이 서는 동안의 간격은 정상 주기가
    // 아니다. Android 만 이걸 하고 여기엔 없어서, 같은 이름의 로그가 **다른 것을 재고
    // 있었다** — 표본 수와 함께 헤더가 소유한다.
    if (_paceWarm < MARU_FRAME_PACE_WARMUP) {
        _paceWarm++;
        _paceLast = now;
        return;
    }
    if (_paceLast > 0 && now > _paceLast && _paceN < MARU_FRAME_PACE_SAMPLES)
        _paceMs[_paceN++] = (now - _paceLast) * 1000.0;
    _paceLast = now;
    if (_paceN < MARU_FRAME_PACE_SAMPLES) return;
    for (int i = 1; i < MARU_FRAME_PACE_SAMPLES; i++) {
        double k = _paceMs[i]; int j = i - 1;
        while (j >= 0 && _paceMs[j] > k) { _paceMs[j + 1] = _paceMs[j]; j--; }
        _paceMs[j + 1] = k;
    }
    _paceDone = YES;
    double med = _paceMs[MARU_FRAME_PACE_SAMPLES / 2];
    NSLog(@"MARU_PACE median_ms=%.2f n=%d target=%.2f verdict=%s", med, MARU_FRAME_PACE_SAMPLES,
          MARU_FRAME_TARGET_MS,
          (med >= MARU_FRAME_PACE_MIN_MS && med <= MARU_FRAME_PACE_MAX_MS) ? "PASS" : "FAIL");
}

- (void)tick {
    [self recordPace];
    // **원격과 주고받는 것은 그리기와 무관하다.** 아래 `nextDrawable` 이 nil 이면 이 함수는
    // 곧바로 돌아가는데(창이 바뀌는 순간 등) 그 자리에 두면 **친 글자가 그동안 안 나간다** —
    // 그리기가 잠깐 막힌 것과 입력이 막히는 것은 사용자에게 전혀 다른 일이다.
    pumpSshOnMainThread();
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
    // **소프트 키보드도 같은 종류의 inset 이다.** 안 빼면 키보드가 화면 절반을 덮는데 레이아웃은
    // 그대로라, 하단에 있는 것이 통째로 가려진다 — **보조 키바가 그렇게 사라졌다**(화면으로
    // 확인). 그 키바의 존재 이유가 "소프트 키보드에 Ctrl·Esc·Tab·화살표가 없다" 인데, 정작
    // 키보드가 뜨면 못 쓰게 되는 상태였다. 키보드 높이를 빼면 column 레이아웃이라 키바가
    // 자동으로 키보드 **위**로 올라온다.
    //
    // safe area 하단과 겹치는 만큼은 두 번 빼지 않는다 — 키보드는 홈 인디케이터 영역을 덮는다.
    CGFloat kb = _keyboardH > safe.bottom ? _keyboardH - safe.bottom : 0;
    CGSize logical = CGSizeMake(self.bounds.size.width - safe.left - safe.right,
                                self.bounds.size.height - safe.top - safe.bottom - kb);
    unsigned int n = maru_mobile_build((unsigned int)logical.width, (unsigned int)logical.height,
                                       (unsigned long long)(CACurrentMediaTime() * 1000.0));
    // **저장 요청은 프레임마다 본다**(Android 와 같은 자리). 값이 바뀐 그 프레임에만 실제
    // 쓰기가 난다 — 가져가면 요청이 사라진다.
    drainConfigWrite();
    driveControlChannel(); // 목록 화면이 원하면 컨트롤 채널을 열고 요청을 나른다
    // **키보드를 다시 올린다.** 우리는 시작부터 first responder 라 그 상태로는 iOS 가 키보드를
    // 다시 안 띄운다 — 사용자가 한 번 내리면(⌘K·스와이프) 숫자 칸을 눌러도 안 올라온다.
    // resign 후 become 이 그 자리다.
    if (maru_mobile_take_keyboard_raise()) {
        [self resignFirstResponder];
        [self becomeFirstResponder];
        NSLog(@"MARU_INPUT keyboard_raised");
    }
    // **내리는 쪽도 같은 자리에 둔다.** first responder 를 놓으면 키보드가 내려간다 — 다시
    // 필요해지면 위 `keyboard_raise` 가 잡는다(Android `hideKeyboard` 와 대칭).
    if (maru_mobile_take_keyboard_hide()) {
        [self resignFirstResponder];
        NSLog(@"MARU_INPUT keyboard_hidden");
    }
    // **끊어 달라는 요청을 실행한다.** 펌프만 세운다 — 화면은 상태가 바뀌는 것을 보고
    // 저절로 따라가므로 여기서 화면을 밀지 않는다(Android `disconnectIfAsked` 와 같은 자리).
    if (maru_mobile_take_disconnect() && maru_ssh_pump_is_running()) {
        NSLog(@"MARU_SSH disconnect_requested");
        maru_ssh_pump_stop();
    }
    // 입력 종류가 바뀌면 키보드를 갈아 끼운다(Android `restartInput` 과 같은 자리).
    static unsigned int last_kind = 0xFFFFFFFF;
    unsigned int kind = maru_mobile_input_kind();
    if (kind != last_kind) {
        last_kind = kind;
        [self reloadInputViews];
        NSLog(@"MARU_INPUT kind=%u keyboard_reloaded", kind);
    }
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

@interface AppDelegate : UIResponder <UIApplicationDelegate> {
    /// 배경 유예 시간을 얻은 자리. **끝나면 반드시 돌려줘야 한다** — 안 돌려주면 OS 가 앱을
    /// 종료한다.
    UIBackgroundTaskIdentifier _sshBackgroundTask;
}
@property (strong, nonatomic) UIWindow *window;
@end

// 정의는 아래에 있고 `applicationWillEnterForeground` 가 먼저 부른다 — Android 에서 같은 순서로
// 한 번 데였다(정의를 함수 안에 두어 implicit declaration 이 났다). 전방 선언으로 못박는다.
static void loadConfigFile(void);

@implementation AppDelegate

- (instancetype)init {
    self = [super init];
    if (self) _sshBackgroundTask = UIBackgroundTaskInvalid;
    return self;
}

/// 유예 시간을 돌려준다. **두 번 불려도 안전해야 한다** — 만료 핸들러와 복귀 경로가 둘 다 부른다.
- (void)endSshBackgroundTask {
    if (_sshBackgroundTask == UIBackgroundTaskInvalid) return;
    [UIApplication.sharedApplication endBackgroundTask:_sshBackgroundTask];
    _sshBackgroundTask = UIBackgroundTaskInvalid;
}
// **생명주기**: 백그라운드에서는 그리지 않는다. iOS 는 창을 없애지 않아 Android 처럼
// 스왑체인을 부술 필요는 없지만, CADisplayLink 를 멈추지 않으면 복귀 시 밀린 프레임이
// 몰린다. 재개 후 다시 도는지가 판정 기준이다.
- (void)applicationDidEnterBackground:(UIApplication *)app {
    // **누르고 있던 손가락을 정리한다.** iOS 는 배경으로 나갈 때 `touchesCancelled` 를
    // 보내지 않는다(로그로 확인했다) — 안 정리하면 브리지가 "누르고 있다" 를 들고 있다가
    // 돌아온 프레임에서 옛 자리를 길게 누른 것으로 판정할 수 있다.
    maru_mobile_pointer(3, 0, 0, 0, 0);
    // 키바가 잡고 있던 것도 함께 푼다 — 안 풀면 복귀 후 첫 터치가 통째로 키바로 간다.
    // 브리지와 뷰 **양쪽**을 푼다: 브리지만 풀면 뷰가 계속 키바로 라우팅하고, 뷰만 풀면
    // 브리지의 `kb_active` 가 남는다.
    // **밀린 화면(설정)이 잡고 있던 것도 같은 이유로 푼다.** 키바만 풀고 여기를 빠뜨렸더니,
    // 톱니를 누른 채 홈으로 나갔다 오면 `_chromeActive` 가 남아 **복귀 후 첫 손짓이 통째로
    // 삼켜졌다**(iOS 는 배경 전환에 touchesCancelled 를 안 보낸다 — 위 주석).
    // **본문 관성도 거둔다.** 이건 브리지가 아니라 우리가 든 값이라 위 취소로 안 지워진다.
    // 감쇠가 시간 기준이 된 뒤로는 남겨 두면 복귀 프레임의 dt 가 "배경에 있던 시간"이 되어
    // (상한 100ms 로 잘려도) 화면이 한 번에 튄다.
    // **배경에서는 그리지 않는다.** 로그만 남기고 CADisplayLink 를 계속 돌리면 백그라운드
    // GPU 작업이 되어 앱이 종료될 수 있다(Apple 이 명시적으로 금지한다). Android 는
    // 창이 죽을 때 Vulkan 을 부수는데 iOS 만 아무것도 안 하고 있었다.
    [(ChromeView *)self.window.rootViewController.view setRenderingPaused:YES];
    // 포커스도 코어에 알린다(DEC 1004 — vim 의 FocusGained/Lost). 모바일은 배경↔복귀가
    // 데스크톱보다 훨씬 잦은데 아무 신호도 안 보내고 있었다.
    maru_mobile_report_focus(0);

    // **iOS 에는 안드로이드의 포그라운드 서비스 같은 것이 없다.** 배경에서 소켓을 계속 들
    // 방법이 없어서(앱이 곧 정지된다) 여기서 할 수 있는 것은 **유예 시간**을 얻는 것뿐이다.
    // 그 시간이 끝나면 **정직하게 끊는다** — 그냥 두면 앱이 정지되며 소켓이 조용히 죽고,
    // 돌아왔을 때 화면은 붙어 있는 것처럼 보인다(그 상태가 사용자를 가장 헷갈리게 한다).
    if (maru_ssh_pump_is_running() && _sshBackgroundTask == UIBackgroundTaskInvalid) {
        __weak typeof(self) weakSelf = self;
        _sshBackgroundTask = [app beginBackgroundTaskWithName:@"maru-ssh" expirationHandler:^{
            NSLog(@"MARU_SSH background_expired — 세션을 끊는다");
            maru_ssh_pump_stop();
            [weakSelf endSshBackgroundTask];
        }];
        NSLog(@"MARU_SSH background_grace task=%lu", (unsigned long)_sshBackgroundTask);
    }
    NSLog(@"MARU_LIFECYCLE background");
}
- (void)applicationWillEnterForeground:(UIApplication *)app {
    // **복귀할 때 다시 읽는다.** Android 는 창이 부서졌다 서면서 이미 그렇게 하고 있었다 —
    // 한쪽만 다시 읽으면 "파일을 고치고 돌아왔을 때" 의 동작이 플랫폼마다 갈린다.
    loadConfigFile();
    [(ChromeView *)self.window.rootViewController.view setRenderingPaused:NO];
    maru_mobile_report_focus(1);
    [self endSshBackgroundTask]; // 돌아왔으니 유예 시간은 돌려준다
    // 다시 읽은 config 에서 브리지가 "원격 세션이 없으면" 요청을 세운다 — 그 요청을 실행한다.
    startSshIfAsked();
    NSLog(@"MARU_LIFECYCLE foreground");
}
/// config 파일을 읽어 브리지에 넘긴다. **자리는 `Library/Application Support/maru/config`**
/// (docs/mobile-config.md §2). 파일을 여는 것은 host 다 — 브리지엔 OS 호출이 없다.
///
/// **그 디렉터리는 새 컨테이너에 없다.** iOS 는 `Library` 밑에 `Caches` 와 `Preferences` 만 두고
/// 시작한다(시뮬레이터 컨테이너로 확인) — `create:YES` 로 만든다. `Caches` 에 두지 않는 이유는
/// OS 가 저장 공간이 모자라면 지우기 때문이다(설정이 말없이 초기화된다).
///
/// **못 만든 것도 실패로 알린다.** 지금은 읽기뿐이라 티가 안 나지만, 저장(M10c)이 붙으면 그때
/// 통째로 실패한다 — 계약이 "쓰기가 실패하면 조용하지 않다" 를 요구한다.
/// 브리지가 세운 저장 요청을 파일에 쓴다(Android 와 같은 규율 — 가져가면 요청이 사라진다).
/// **임시 파일에 쓰고 바꿔치기한다.** 덮어쓰다 죽으면 config 가 반만 남는다.
static void drainConfigWrite(void) {
    static unsigned char buf[MARU_CONFIG_MAX_BYTES];
    unsigned long n = maru_mobile_take_config_write(buf, sizeof buf);
    if (n == 0) return;
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                          inDomain:NSUserDomainMask
                                                 appropriateForURL:nil
                                                            create:YES
                                                             error:nil];
    if (!support) { NSLog(@"MARU_CONFIG write_support_failed"); return; }
    NSURL *dir = [support URLByAppendingPathComponent:@"maru" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *file = [dir URLByAppendingPathComponent:@"config" isDirectory:NO];
    NSData *data = [NSData dataWithBytes:buf length:n];
    NSError *err = nil;
    // atomically:YES = 임시 파일에 쓰고 바꿔치기한다.
    if (![data writeToURL:file options:NSDataWritingAtomic error:&err]) {
        NSLog(@"MARU_CONFIG write_failed path=%@ err=%@", file.path, err.localizedDescription);
        return;
    }
    NSLog(@"MARU_CONFIG wrote bytes=%lu path=%@", n, file.path);
}

// ── SSH 세션(S9-3c) ─────────────────────────────────────────────────────────
//
// **소켓 루프는 여기 없다.** 두 host 가 함께 쓰는 `ssh_pump.c` 가 든다 — 이 파일은 접속 정보를
// 읽어 넘기고, 원격 출력을 화면에 넣는다.
//
// **자물쇠 대신 main 큐를 쓴다.** iOS 의 브리지 호출은 전부 main 에서 돈다는 것이 이 host 의
// 모델이고(계약 §3), 펌프 스레드가 끼어들면 그 모델이 깨진다. 그래서 펌프가 주는 것은
// **main 으로 던지고**(`dispatch_async`), 가져오는 것은 **프레임 tick 이 main 에서** 한다 —
// `dispatch_sync` 로 당기면 `stop` 이 그 스레드를 기다리는 순간 교착한다(main 이 join 을 하고,
// 펌프는 main 을 기다린다).

// **컨트롤 채널의 ndjson**(S10d-3). 화면 훅과 **다른 자리**로 온다 — 합치면 파서가 사람 화면을
// 읽게 된다(계약 §4a). 화면 훅과 같은 이유로 **복사한다**: 이 포인터는 코어 안을 가리키고
// 블록이 나중에 실행되므로 그때는 이미 다른 내용이다.
static void sshControl(void *ctx, const unsigned char *bytes, unsigned long len) {
    (void)ctx;
    NSData *copy = [NSData dataWithBytes:bytes length:len];
    dispatch_async(dispatch_get_main_queue(), ^{
        maru_mobile_control_feed(copy.bytes, copy.length);
    });
}

static void sshScreen(void *ctx, const unsigned char *bytes, unsigned long len) {
    (void)ctx;
    // **복사한다.** 이 포인터는 코어 안을 가리키고 다음 걸음이면 사라진다 — 블록이 나중에
    // 실행되므로 그때는 이미 다른 내용이다.
    NSData *copy = [NSData dataWithBytes:bytes length:len];
    dispatch_async(dispatch_get_main_queue(), ^{
        maru_mobile_term_write(copy.bytes, copy.length);
    });
}

static void sshState(void *ctx, unsigned int state) {
    (void)ctx;
    // **한 번만 읽어 그대로 나른다.** 예전에는 여기(펌프 스레드에서 즉시)와 아래 main 블록(나중에
    // 실행)에서 각각 읽었다 — 그 사이에 값이 바뀌면 **로그와 화면이 서로 다른 이름을 본다**.
    // Android 는 같은 스레드·같은 시점이라 그 창이 없었다: 두 host 가 한 벌이어야 하는 자리다.
    // 문자열은 복사해 든다(헤더 규약: 다음 호출이 그 자리를 덮는다).
    const char *err = maru_ssh_pump_error();
    NSString *errCopy = err ? @(err) : @"";
    NSLog(@"MARU_SSH state=%u error=%s", state, errCopy.UTF8String);
    dispatch_async(dispatch_get_main_queue(), ^{
        // **입력 목적지를 세션과 함께 옮긴다.** 안 옮기면 친 글자가 화면에 한 번 찍히고 원격에는
        // 영영 안 간다(안드로이드에서 실측한 것과 같은 자리다).
        maru_mobile_set_input_sink(state == MARU_SSH_STATE_CLOSED ? 0 : 1);
        // 상태와 실패 이름을 화면에 알린다(Android 와 같은 자리).
        const char *serr = errCopy.UTF8String;
        maru_mobile_set_ssh_status(state, (const unsigned char *)serr, strlen(serr));
        // **비밀번호를 물어야 하면 화면을 연다**(그 자리에서 펌프가 기다린다). 벗어나면 끈다.
        maru_mobile_set_password_prompt(state == MARU_SSH_STATE_PASSWORD_NEEDED ? 1 : 0);
        // **처음 보는 서버면 지문을 묻는다**(Android 와 같은 자리). 지문이 이미 있으면 펌프가
        // 그 자리에서 판정하고 이 상태를 스쳐 지나간다.
        if (state == MARU_SSH_STATE_HOST_KEY_DECISION) {
            const char *fp = maru_ssh_pump_host_key_fingerprint();
            if (fp && fp[0]) maru_mobile_set_host_key_prompt((const unsigned char *)fp, strlen(fp));
        } else {
            maru_mobile_set_host_key_prompt((const unsigned char *)"", 0);
        }
    });
}

/// 프레임마다 main 에서 돈다: 친 것을 원격으로, 코어가 만든 답도 원격으로, 격자가 바뀌면 알린다.
static void pumpSshOnMainThread(void) {
    if (!maru_ssh_pump_is_running()) return;
    // **사용자가 친 비밀번호를 넘긴다**(Android 와 같은 자리). 넘긴 뒤 사본을 지운다(계약 §3.4).
    {
        unsigned char pw[256];
        unsigned long n = maru_mobile_take_password(pw, sizeof pw);
        if (n > 0) {
            maru_ssh_pump_password((const char *)pw, (unsigned int)n);
            memset(pw, 0, sizeof pw);
            NSLog(@"MARU_SSH password_supplied bytes=%lu", n);
        }
    }
    // 지문 승인·거절도 같은 자리에서 나른다.
    {
        unsigned int d = maru_mobile_take_host_key_decision();
        if (d != 0) {
            maru_ssh_pump_accept_host_key(d == 1);
            NSLog(@"MARU_SSH host_key_%s", d == 1 ? "accepted" : "rejected");
        }
    }
    if (maru_ssh_pump_state() == MARU_SSH_STATE_READY) {
        // **`ready` 일 때만 가져간다** — 가져가면 브리지에서 사라지는데 그때 못 보내면 그
        // 글자가 통째로 없어진다(그전에는 브리지에 남아 type-ahead 가 된다).
        static unsigned char input_buf[4096];
        unsigned long got = maru_mobile_take_input(input_buf, sizeof input_buf);
        if (got > 0) {
            unsigned long sent = maru_ssh_pump_write(input_buf, got);
            if (sent != got) NSLog(@"MARU_SSH input_partial sent=%lu of=%lu", sent, got);
        }
        static unsigned char response_buf[256];
        unsigned long resp = maru_mobile_take_response(response_buf, sizeof response_buf);
        if (resp > 0) maru_ssh_pump_write(response_buf, resp);
    }
    // 격자가 바뀌면 원격에 알린다 — 키보드가 오르내리면 행 수가 바뀐다.
    static unsigned int last_cols, last_rows;
    unsigned int cols = maru_mobile_term_cols();
    unsigned int rows = maru_mobile_term_rows();
    if (cols && rows && (cols != last_cols || rows != last_rows)) {
        if (last_cols) {
            maru_ssh_pump_resize(cols, rows);
            NSLog(@"MARU_SSH resize cols=%u rows=%u", cols, rows);
        }
        last_cols = cols;
        last_rows = rows;
    }
}

/// **이 기기의 공개키 한 줄을 브리지에 알린다**(화면이 보여 주고 복사한다 — S9c-4).
///
/// iOS 는 키를 **앱 전용 파일**로 든다(Keychain 은 실기기 검증까지 보류 — 계획 S9c-2). 그
/// 파일에서 한 줄을 만들어 두면 사용자가 **붙기 전에** 서버 `authorized_keys` 에 넣을 수 있다.
/// 파일이 없으면 아무것도 안 알린다 — 화면이 "아직 키가 없다" 고 말한다.
static void publishPublicKey(void) {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                          inDomain:NSUserDomainMask
                                                 appropriateForURL:nil
                                                            create:YES
                                                             error:nil];
    if (!support) return;
    NSURL *keyFile = [[support URLByAppendingPathComponent:@"maru" isDirectory:YES]
        URLByAppendingPathComponent:@"id_ed25519" isDirectory:NO];
    static unsigned char pem[16 * 1024];
    FILE *kf = fopen(keyFile.fileSystemRepresentation, "rb");
    if (!kf) {
        NSLog(@"MARU_SSH public_key_absent path=%@", keyFile.path);
        return;
    }
    size_t pem_len = fread(pem, 1, sizeof pem, kf);
    fclose(kf);
    static unsigned char secret[MARU_SSH_SECRET_KEY_BYTES];
    int loaded = maru_mobile_ssh_load_key(pem, (unsigned int)pem_len,
                                          (const unsigned char *)"", 0, secret);
    memset(pem, 0, sizeof pem); // 읽은 원문을 안 남긴다
    if (loaded != MARU_SSH_OK) {
        NSLog(@"MARU_SSH public_key_load_failed=%s", maru_mobile_ssh_last_load_error());
        return;
    }
    unsigned char line[256];
    int rc = maru_mobile_ssh_public_key_line(secret, line, sizeof line);
    memset(secret, 0, sizeof secret); // 개인키 사본은 바로 지운다
    if (rc != MARU_SSH_OK) {
        NSLog(@"MARU_SSH public_key_failed=%s", maru_mobile_ssh_last_load_error());
        return;
    }
    maru_mobile_set_public_key(line, strlen((const char *)line));
    NSLog(@"MARU_SSH public_key_ready");
}

/// **붙어 달라는 요청을 실행한다.** 어느 서버인지는 브리지가 말한다(config 가 단일 출처 —
/// `ssh.server.<n>.*`, docs/mobile-config.md §4.3). 예전에는 이 함수가 `ssh.conf` 를 직접
/// 파싱했는데, 그러면 같은 사실이 두 자리에 살아 화면이 고른 것과 갈린다.
///
/// **키는 config 에 없다.** 앱 전용 파일(`Application Support/maru/id_ed25519`)을 읽는다 —
/// 경로가 고정이라 설정에 적을 것이 없다(iOS Keychain 은 실기기 검증까지 보류: 계획 S9c-2).
/// 컨트롤 축을 프레임마다 굴린다(S10d-3). Android 의 같은 이름 함수와 **한 벌**이다 — 두 벌이면
/// 한쪽만 고쳐지고 그 차이는 "한 기기에서만 목록이 안 뜬다" 로 나타난다.
static void driveControlChannel(void) {
    if (!maru_ssh_pump_is_running()) return;

    // **셸이 뜬 뒤에만 연다.** 예전 가드는 `is_running` 뿐이었는데 그것은 `pthread_create` 직후
    // 참이라 READY 와 무관하다 — 목록 화면이 nav 스택의 뿌리라 접속 중에 거기 있으면 요청이 곧바로
    // 서고, 그때 열기가 `not_running`/`NotReady` 로 지고 **요청은 take-once 라 사라졌다**. 그러면
    // 셸이 떠도 목록은 영영 "받는 중" 이었다(Android 기기에서 실측 — 같은 코드라 여기도 같다).
    // **열 수 있을 때만 집는다.** 이 요청은 take-once 가 아니다(계약 §4a) — 채널이 아직 안
    // 닫혔는데 가져가면 그 뜻이 사라져 축이 영영 안 선다. 닫힘이 확인된 다음 tick 에 연다.
    const unsigned int control_ch = maru_ssh_pump_control_state();
    // **닫기가 열기보다 «먼저» 다.** 순서가 뒤집혀 있으면, `wantControl` 이 닫기와 열기를 함께
    // 세운 tick 에 채널이 마침 CLOSED 인 경우 **열고 나서 그 자리에서 닫는다** — 그 뒤로는 열고
    // 닫기를 무한히 되풀이하며 아무 세션도 안 뜬다(실기 2026-09-04 계측: `ch` 가 opening↔closed
    // 로 진동했다). 빠르게 여닫는 조작이 정확히 그 창을 만든다. §4a 가 「한 번에 하나」이므로
    // 닫는 것이 먼저다.
    if (maru_mobile_take_control_close()) {
        // **닫기 결과를 읽는다.** 실패를 안 보면 원격 명령이 고아로 남아 그 뒤 모든 열기가
        // 막히는데 화면에도 로그에도 아무 말이 없다(실기 2026-09-04 — 그렇게 4분을 헤맸다).
        const int close_rc = maru_ssh_pump_close_control();
        if (close_rc != 0)
            NSLog(@"MARU_CONTROL close failed rc=%d: %s", close_rc, maru_ssh_pump_control_error());
        gControlOpenMs = 0;
    }

    if (maru_ssh_pump_state() == MARU_SSH_STATE_READY &&
        (control_ch == MARU_SSH_CONTROL_NONE || control_ch == MARU_SSH_CONTROL_CLOSED) &&
        maru_mobile_take_control_open()) {
        // **명령은 코어가 만든다** — 그 서버 설정의 `maru-path` 를 쓰고, 셸이 쪼개지 못하게
        // 인용까지 해서 준다(계약 §4a). host 가 문자열을 조립하면 두 플랫폼이 갈린다.
        char cmd[512];
        unsigned long cmd_len = maru_mobile_control_command((unsigned char *)cmd, sizeof cmd);
        // **「아직 때가 아니다」와 「졌다」를 가른다.** 이전 채널이 닫히는 중이면 코어가
        // `MARU_SSH_ERR_NOT_READY` 를 내는데(그 자리 주석이 "조금 뒤에 다시 부르면 된다"),
        // 그것을 딱딱한 실패로 접으면 「열자」는 뜻이 사라져 그 화면이 **영영 「받는 중」** 이
        // 된다(실측 2026-09-03: 세션 화면 재진입).
        const int open_rc = cmd_len == 0
                                ? -1
                                : maru_ssh_pump_open_control(cmd, (unsigned int)cmd_len);
        if (open_rc == MARU_SSH_ERR_NOT_READY) {
            const double now_ms = CACurrentMediaTime() * 1000.0;
            if (gControlRetryMs == 0) gControlRetryMs = now_ms;
            if (now_ms - gControlRetryMs > 5000) {
                NSLog(@"MARU_CONTROL open gave up: %s", maru_ssh_pump_control_error());
                gControlRetryMs = 0;
                maru_mobile_control_open_failed();
            } else {
                maru_mobile_control_open_retry();
            }
        } else if (open_rc != 0) {
            gControlRetryMs = 0;
            // **컨트롤 축의 이름을 찍는다**(Android 와 같은 자리) — 터미널 슬롯을 찍으면 한 번
            // 박힌 이름이 그 뒤 모든 실패를 덮는다.
            NSLog(@"MARU_CONTROL open failed: %s", maru_ssh_pump_control_error());
            // **실패는 그 화면이 말한다**(계약 §4a).
            maru_mobile_control_open_failed();
        } else {
            gControlRetryMs = 0;
            gControlOpenMs = CACurrentMediaTime() * 1000.0;
        }
    }

    // **명령이 그냥 끝났으면 시한을 기다리지 않는다.** 답할 것이 이미 죽었고, 종료 코드는
    // 사용자가 고칠 자리를 가른다(계약 §4a: 127 이면 그 기계에 `maru` 가 없다).
    //
    // **세션이 살아 있을 때만 그렇게 읽는다.** 연결이 죽으면 채널도 함께 죽는데, 그것은 명령이
    // 실패한 것이 아니라 **명령이 서 있던 바닥이 사라진 것**이다. 안 가르면 끊을 때마다 그
    // 잔해가 "그 기계에 maru 가 없다" 로 화면에 떴다(Android 실측 — 서버에는 있었다).
    unsigned int control_exit = 0;
    if (gControlOpenMs != 0 && maru_ssh_pump_state() == MARU_SSH_STATE_READY &&
        maru_ssh_pump_control_exit_status(&control_exit) == 0) {
        maru_mobile_control_note_exit(control_exit);
        gControlOpenMs = 0;
    }

    if (gControlOpenMs != 0 && maru_mobile_control_state() == MARU_MOBILE_CONTROL_WAITING &&
        CACurrentMediaTime() * 1000.0 - gControlOpenMs > 5000) {
        maru_mobile_control_timeout();
        gControlOpenMs = 0;
    }

    unsigned char req[512];
    unsigned long n = maru_mobile_take_control_request(req, sizeof req);
    if (n > 0) maru_ssh_pump_write_control(req, n);
}

static void startSshIfAsked(void) {
    if (maru_ssh_pump_is_running()) return;
    unsigned int req = maru_mobile_take_server_connect();
    if (!req) return;
    unsigned int idx = req - 1;

    unsigned char host[256], user[MARU_SSH_MAX_USER], fp[128];
    unsigned long host_len = maru_mobile_server_field(idx, MARU_SERVER_HOST, host, sizeof host - 1);
    unsigned long user_len = maru_mobile_server_field(idx, MARU_SERVER_USER, user, sizeof user - 1);
    unsigned long fp_len = maru_mobile_server_field(idx, MARU_SERVER_FINGERPRINT, fp, sizeof fp - 1);
    unsigned int port = maru_mobile_server_port(idx);
    // **비어 있으면 안 붙는다.** 브리지가 온전한 줄만 요청하지만 버퍼가 모자라도 0 이 오므로
    // (자르지 않는 계약) 여기서도 본다 — 반쪽 주소로 붙으면 실패가 오타처럼 보인다.
    // **지문은 빼고 본다** — 처음 붙는 서버는 없는 것이 정상이고 그때는 화면이 묻는다(Android 와 같다).
    if (!host_len || !user_len || !port) {
        NSLog(@"MARU_SSH connect_incomplete index=%u", idx);
        return;
    }
    host[host_len] = 0;
    user[user_len] = 0;
    fp[fp_len] = 0;

    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                          inDomain:NSUserDomainMask
                                                 appropriateForURL:nil
                                                            create:YES
                                                             error:nil];
    if (!support) return;
    NSURL *keyFile = [[support URLByAppendingPathComponent:@"maru" isDirectory:YES]
        URLByAppendingPathComponent:@"id_ed25519" isDirectory:NO];

    // **키는 우리가 읽고 ABI 가 푼다.** 파일 바이트는 이 함수 밖으로 안 나간다.
    //
    // **`NSData` 로 읽지 않는다.** 그 바이트는 우리가 못 지우고(autorelease 라 언제 풀릴지도
    // 모른다) 힙에 개인키가 그대로 남는다 — Android 쪽은 자기 버퍼를 쓰고 지운다. 같은 규율이다.
    // **키가 없어도 붙는다.** 비밀번호만 여는 서버에는 키가 필요 없는데, 예전에는 여기서
    // 돌아서서 그 서버에도 못 붙었다(사용자 지적). 키가 없으면 `NULL` 을 넘기고 코어가
    // `none` 으로 방법 목록만 묻는다(SSH 계약 §3.4).
    static unsigned char secret[MARU_SSH_SECRET_KEY_BYTES];
    int have_key = 0;
    {
        static unsigned char pem[16 * 1024];
        FILE *kf = fopen(keyFile.fileSystemRepresentation, "rb");
        if (kf) {
            size_t pem_len = fread(pem, 1, sizeof pem, kf);
            fclose(kf);
            if (pem_len > 0) {
                int loaded = maru_mobile_ssh_load_key(pem, (unsigned int)pem_len,
                                                      (const unsigned char *)"", 0, secret);
                memset(pem, 0, sizeof pem); // 읽은 원문을 안 남긴다
                if (loaded == MARU_SSH_OK) have_key = 1;
                else NSLog(@"MARU_SSH key_failed=%s", maru_mobile_ssh_last_load_error());
            } else {
                NSLog(@"MARU_SSH key_empty path=%@", keyFile.path);
            }
        } else {
            NSLog(@"MARU_SSH key_absent path=%@ — 비밀번호만 여는 서버라면 그래도 붙는다", keyFile.path);
        }
    }

    // 문자열은 펌프가 복사해 간다.
    MaruSshPumpConfig cfg;
    memset(&cfg, 0, sizeof cfg);
    cfg.host = (const char *)host;
    cfg.port = (unsigned short)port;
    cfg.user = (const char *)user;
    cfg.secret = have_key ? secret : NULL;
    unsigned int cols = maru_mobile_term_cols(), rows = maru_mobile_term_rows();
    cfg.cols = cols ? cols : 80;
    cfg.rows = rows ? rows : 24;
    cfg.expect_fingerprint = (const char *)fp;

    MaruSshPumpHooks hooks;
    memset(&hooks, 0, sizeof hooks);
    hooks.screen = sshScreen;
    hooks.state_changed = sshState;
    // **훅이 없으면 채널을 못 연다**(펌프가 거절한다) — 받을 사람이 없으면 코어가 배압으로
    // 멈추고 터미널까지 함께 멎기 때문이다.
    hooks.control = sshControl;
    // **새 연결이면 컨트롤 축도 처음부터**(계약 §4a). 안 그러면 끊겼다 다시 붙었을 때 **죽은
    // 세션 목록이 그대로 남아** 살아 있는 것처럼 보인다 — 코어에는 그 판정에 쓸 연결 개념이
    // 없으므로(시계도 소켓도 없다) 이 자리에서 알려야 한다.
    maru_mobile_control_reset();
    gControlOpenMs = 0;
    int rc = maru_ssh_pump_start(&cfg, &hooks);
    memset(secret, 0, sizeof secret);
    NSLog(@"MARU_SSH start host=%s port=%u user=%s rc=%d", host, cfg.port, user, rc);
}

static void loadConfigFile(void) {
    NSError *err = nil;
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                          inDomain:NSUserDomainMask
                                                 appropriateForURL:nil
                                                            create:YES
                                                             error:&err];
    if (!support) {
        NSLog(@"MARU_CONFIG support_dir_failed err=%@", err.localizedDescription);
        return;
    }
    NSURL *dir = [support URLByAppendingPathComponent:@"maru" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:&err]) {
        NSLog(@"MARU_CONFIG mkdir_failed path=%@ err=%@", dir.path, err.localizedDescription);
        return;
    }
    NSURL *file = [dir URLByAppendingPathComponent:@"config" isDirectory:NO];
    NSData *data = [NSData dataWithContentsOfURL:file options:0 error:&err];
    if (!data) {
        // 없는 것이 정상 상태다 — 설정을 한 번도 안 건드린 기기가 그렇다(계약 §7).
        NSLog(@"MARU_CONFIG absent path=%@", file.path);
        return;
    }
    // **상한을 넘으면 안 읽는다**(헤더가 단일 출처). 자른 앞부분을 쓰면 반만 적용된 설정이 된다.
    if (data.length > MARU_CONFIG_MAX_BYTES) {
        NSLog(@"MARU_CONFIG too_large bytes=%lu limit=%u path=%@",
              (unsigned long)data.length, MARU_CONFIG_MAX_BYTES, file.path);
        return;
    }
    maru_mobile_load_config((const unsigned char *)data.bytes, (unsigned long)data.length);
    NSLog(@"MARU_CONFIG loaded bytes=%lu path=%@", (unsigned long)data.length, file.path);
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    // 시작 때 가짜 크기로 한 번 빌드해 로그를 찍던 것을 지웠다 — 실제 뷰가 서기 전이라
    // 그 결과는 아무도 안 쓰고, 아틀라스가 서기 전에 miss 목록만 채웠다.
    loadConfigFile(); // 뷰가 서기 전에 — 첫 프레임부터 그 색으로 그린다
    publishPublicKey(); // 접속 **전에** 보여 줘야 서버에 붙일 수 있다
    startSshIfAsked();
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
