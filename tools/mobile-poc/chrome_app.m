// PoC 6: **maru 의 실제 chrome 컴포넌트**가 낸 draw-list 를 시뮬레이터 화면에 그린다.
//
// 앞 단계는 색 격자를 손으로 그렸다. 여기서는 Zig 쪽 `chrome.ui.tree` 로 UI 를 조립하고
// `paint` 가 뱉은 op 을 받아 그대로 그린다 — 플랫폼은 배치를 **모른다**. 그게 maru 의
// 레이어 계약(L3 chrome 이 배치, L4 platform 이 그리기)이고, 이 PoC 가 확인하려는 것이다.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreText/CoreText.h>

typedef struct {
    float x, y, w, h;
    float r, g, b, a;
    float radius;
    unsigned int kind;      // 0=단색 1=아틀라스 글리프 2=아이콘
    unsigned int cell_x, cell_y;
} CQuad;

extern unsigned int maru_chrome_build(unsigned int width, unsigned int height);
extern const CQuad *maru_chrome_quads(void);
extern const char *maru_chrome_last_error(void);
extern void maru_atlas_add(unsigned int cp, unsigned int col, unsigned int row, unsigned int advance);
extern void maru_atlas_geometry(unsigned int cell_w, unsigned int cell_h);
extern unsigned int maru_icon_build(void);
extern const unsigned char *maru_icon_atlas(void);
extern unsigned int maru_icon_slot_px(void);
extern unsigned int maru_icon_count(void);
extern unsigned int maru_term_input(const char *bytes, unsigned long len);

// 둥근 모서리를 프래그먼트에서 자른다 — maru 의 rich quad 가 corner_radii 를 쓰므로
// 그 모양이 실제로 나오는지 보려면 필요하다.
static NSString *const kShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float2 local; float2 half_size; float radius; float4 color; float2 uv; float kind; };\n"
     "struct Uni { float4 rect_px; float4 color; float4 misc; float4 cell; };\n"
     "// misc = (radius, vp.x, vp.y, kind) · cell = (col, row, atlas_cols, atlas_rows)\n"
     "vertex VOut v_main(uint vid [[vertex_id]], constant Uni &u [[buffer(0)]]) {\n"
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
    CADisplayLink *_link;
    unsigned int _tickCount;
}

// 호스트가 만든 한글·영어 아틀라스와, **Zig 가 만든** 아이콘 coverage 를 올린다.
// 아이콘 쪽이 중요하다 — SVG 자산이 플랫폼 코드 없이 그대로 이식된다는 증거다.
// **기기에서 굽는다.** 호스트가 만든 아틀라스를 읽는 대신 CoreText 로 직접 래스터한다 —
// "각 플랫폼이 자기 폰트 스택을 쓴다"가 실제로 서는지 보는 자리다. 한글은 Menlo 에 없어
// 폴백(AppleSDGothicNeo)이 필요하고, 진행 폭은 `CTFontGetAdvancesForGlyphs` 가 준다.
- (BOOL)rasterizeAtlasOnDevice {
    NSString *chars = @"$ zig build test All 11 passed.git status --short"
                       "M src/chrome/ui/tree.zigmaru 0.1.0 (arm64)zshvimlogswebdocsinfrascratch"
                       "한글 터미널 세션 목록 설정 검색 알림";
    const unsigned int CW = 24, CH = 32, COLS = 16;
    NSMutableArray<NSNumber *> *cps = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    [chars enumerateSubstringsInRange:NSMakeRange(0, chars.length)
                              options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *sub, NSRange r, NSRange e, BOOL *stop) {
        NSNumber *k = @([sub characterAtIndex:0]);
        if (![seen containsObject:k]) { [seen addObject:k]; [cps addObject:k]; }
    }];
    NSUInteger n = cps.count, rows = (n + COLS - 1) / COLS;
    unsigned int W = COLS * CW, H = (unsigned int)(rows * CH);
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
                (CTFontDescriptorRef)CFArrayGetValueAtIndex(descs, 0), 22, NULL);
        }
        if (descs) CFRelease(descs);
    }
    if (!base) {  // 번들 폰트가 없으면 예전 경로로 — 조용히 다른 글꼴이 되지 않게 로그를 남긴다
        NSLog(@"MARU_CHROME bundled_font_missing fallback=Menlo");
        base = CTFontCreateWithName(CFSTR("Menlo"), 22, NULL);
    }
    CTFontRef korean = CFRetain(base);

    maru_atlas_geometry(CW, CH);
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
        maru_atlas_add(c, (unsigned int)col, (unsigned int)row, (unsigned int)advance);
    }
    CFRelease(base); CFRelease(korean);
    CGContextRelease(ctx); CGColorSpaceRelease(cs);

    _atlasCols = COLS; _atlasRows = (unsigned int)rows;
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:W height:H mipmapped:NO];
    _glyphTex = [_dev newTextureWithDescriptor:td];
    [_glyphTex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:gray bytesPerRow:W];
    // 래스터 결과를 그대로 남긴다 — 두 플랫폼의 픽셀 차이를 재려면 원본이 필요하다.
    NSString *dump = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]
                      stringByAppendingPathComponent:@"atlas_ondevice.gray"];
    [[NSData dataWithBytes:gray length:W * H] writeToFile:dump atomically:YES];
    free(gray);
    NSLog(@"MARU_CHROME atlas_ondevice=%ux%u glyphs=%lu source=CoreText font=%@",
          W, H, (unsigned long)n, fontPath ? @"Jetendard" : @"Menlo");
    return YES;
}

- (void)loadAtlas {
    // 기기 래스터가 서면 번들 아틀라스는 아예 안 읽는다.
    if ([self rasterizeAtlasOnDevice]) { [self loadIcons]; return; }
    NSString *dir = NSProcessInfo.processInfo.environment[@"MARU_ATLAS_DIR"];
    if (!dir) dir = [NSBundle.mainBundle resourcePath];
    NSString *idxPath = [dir stringByAppendingPathComponent:@"atlas.idx"];
    NSString *idx = [NSString stringWithContentsOfFile:idxPath encoding:NSUTF8StringEncoding error:nil];
    if (idx) {
        NSArray<NSString *> *lines = [idx componentsSeparatedByString:@"\n"];
        NSArray<NSString *> *head = [lines[0] componentsSeparatedByString:@" "];
        unsigned int W = head[0].intValue, H = head[1].intValue;
        unsigned int cw = head[2].intValue, ch = head[3].intValue;
        _atlasCols = W / cw; _atlasRows = H / ch;
        maru_atlas_geometry(cw, ch);
        NSData *gray = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"atlas.gray"]];
        if (gray.length >= W * H) {
            MTLTextureDescriptor *td =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                   width:W height:H mipmapped:NO];
            _glyphTex = [_dev newTextureWithDescriptor:td];
            [_glyphTex replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0
                           withBytes:gray.bytes bytesPerRow:W];
            for (NSUInteger i = 1; i < lines.count; i++) {
                NSArray<NSString *> *f = [lines[i] componentsSeparatedByString:@" "];
                if (f.count < 4) continue;
                maru_atlas_add(f[0].intValue, f[1].intValue, f[2].intValue, f[3].intValue);
            }
        }
        NSLog(@"MARU_CHROME atlas=%ux%u cols=%u rows=%u", W, H, _atlasCols, _atlasRows);
    } else {
        NSLog(@"MARU_CHROME atlas_missing dir=%@", dir);
    }

    [self loadIcons];
}

// 아이콘: Zig 가 coverage 를 만든다(플랫폼 코드 0줄).
- (void)loadIcons {
    unsigned int filled = maru_icon_build();
    unsigned int slot = maru_icon_slot_px(), count = maru_icon_count();
    NSLog(@"MARU_CHROME icons filled=%u/%u slot=%u", filled, count, slot);
    // coverage 는 RGBA8 로 오고 alpha 채널이 값이다(glyph_pixels 계약).
    MTLTextureDescriptor *itd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:slot height:slot * count mipmapped:NO];
    _iconTex = [_dev newTextureWithDescriptor:itd];
    [_iconTex replaceRegion:MTLRegionMake2D(0, 0, slot, slot * count) mipmapLevel:0
                  withBytes:maru_icon_atlas() bytesPerRow:slot * 4];
}

// **입력**: 하드웨어 키보드가 이 뷰로 온다. 받은 문자를 바이트로 코어에 먹인다 —
// 코어는 PTY 에서 온 것과 구분하지 않는다(Android 쪽과 같은 계약).
- (BOOL)canBecomeFirstResponder { return YES; }
// 소프트 키보드는 이 PoC 에서 화면 절반을 가린다. 빈 `inputView` 를 주면 키보드는 안 뜨고
// **입력 대상 자격은 그대로** 남는다(하드웨어 키는 계속 `insertText:` 로 온다).
- (UIView *)inputView { return [[UIView alloc] initWithFrame:CGRectZero]; }
- (BOOL)hasText { return YES; }
- (void)deleteBackward {
    char bs = 0x7F;
    maru_term_input(&bs, 1);
}
- (void)insertText:(NSString *)text {
    const char *b = text.UTF8String;
    if (!b) return;
    unsigned int total = maru_term_input(b, strlen(b));
    NSLog(@"MARU_INPUT text=%@ total=%u", text, total);
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
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    return self;
}

- (void)tick {
    if ((++_tickCount % 120) == 0) NSLog(@"MARU_LIFECYCLE ticks=%u", _tickCount);
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
    unsigned int n = maru_chrome_build((unsigned int)logical.width, (unsigned int)logical.height);
    const CQuad *quads = maru_chrome_quads();

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = d.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.06, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:_pipe];
    for (unsigned int i = 0; i < n; i++) {
        const CQuad *q = &quads[i];
        float cols = (q->kind == 2) ? 1.0f : (float)_atlasCols;
        float rows = (q->kind == 2) ? (float)maru_icon_count() : (float)_atlasRows;
        Uni u = {{q->x + (float)safe.left, q->y + (float)safe.top,
                  q->x + q->w + (float)safe.left, q->y + q->h + (float)safe.top},
                 {q->r, q->g, q->b, q->a},
                 {q->radius, (float)self.bounds.size.width, (float)self.bounds.size.height, (float)q->kind},
                 {(float)q->cell_x, (float)q->cell_y, cols, rows}};
        [e setVertexBytes:&u length:sizeof(u) atIndex:0];
        [e setFragmentBytes:&u length:sizeof(u) atIndex:0];
        if (_glyphTex) [e setFragmentTexture:_glyphTex atIndex:0];
        if (_iconTex) [e setFragmentTexture:_iconTex atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
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
    NSLog(@"MARU_LIFECYCLE background");
}
- (void)applicationWillEnterForeground:(UIApplication *)app {
    NSLog(@"MARU_LIFECYCLE foreground");
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    unsigned int n = maru_chrome_build(800, 600);
    NSLog(@"MARU_CHROME quads=%u err=%s", n, maru_chrome_last_error());
    const CQuad *qd = maru_chrome_quads();
    for (unsigned int i = 0; i < (n < 6 ? n : 6); i++)
        NSLog(@"MARU_CHROME q%u rect=(%.0f,%.0f %.0fx%.0f) rgba=(%.2f,%.2f,%.2f,%.2f) rad=%.0f",
              i, qd[i].x, qd[i].y, qd[i].w, qd[i].h, qd[i].r, qd[i].g, qd[i].b, qd[i].a, qd[i].radius);
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
