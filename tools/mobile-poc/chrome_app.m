// PoC 6: **maru 의 실제 chrome 컴포넌트**가 낸 draw-list 를 시뮬레이터 화면에 그린다.
//
// 앞 단계는 색 격자를 손으로 그렸다. 여기서는 Zig 쪽 `chrome.ui.tree` 로 UI 를 조립하고
// `paint` 가 뱉은 op 을 받아 그대로 그린다 — 플랫폼은 배치를 **모른다**. 그게 maru 의
// 레이어 계약(L3 chrome 이 배치, L4 platform 이 그리기)이고, 이 PoC 가 확인하려는 것이다.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

typedef struct {
    float x, y, w, h;
    float r, g, b, a;
    float radius;
    unsigned int is_text;
} CQuad;

extern unsigned int maru_chrome_build(unsigned int width, unsigned int height);
extern const CQuad *maru_chrome_quads(void);
extern const char *maru_chrome_last_error(void);

// 둥근 모서리를 프래그먼트에서 자른다 — maru 의 rich quad 가 corner_radii 를 쓰므로
// 그 모양이 실제로 나오는지 보려면 필요하다.
static NSString *const kShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float2 local; float2 half_size; float radius; float4 color; };\n"
     "struct Uni { float4 rect_px; float4 color; float4 misc; };  // misc = (radius, vp.x, vp.y, is_text)\n"
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
     "  o.radius = u.misc.x; o.color = u.color;\n"
     "  return o;\n"
     "}\n"
     "fragment float4 f_main(VOut in [[stage_in]]) {\n"
     "  float r = min(in.radius, min(in.half_size.x, in.half_size.y));\n"
     "  float2 q = abs(in.local) - (in.half_size - r);\n"
     "  float d = length(max(q, 0.0)) - r;\n"
     "  if (d > 0.5) discard_fragment();\n"
     "  return in.color;\n"
     "}\n";

typedef struct { float rect_px[4]; float color[4]; float misc[4]; } Uni;  // misc = radius, vp.x, vp.y, is_text

@interface ChromeView : UIView
@end

@implementation ChromeView {
    id<MTLDevice> _dev;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipe;
    CADisplayLink *_link;
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
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    return self;
}

- (void)tick {
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
    CGSize logical = self.bounds.size;
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
        Uni u = {{q->x, q->y, q->x + q->w, q->y + q->h},
                 {q->r, q->g, q->b, q->a},
                 {q->radius, (float)logical.width, (float)logical.height, (float)q->is_text}};
        [e setVertexBytes:&u length:sizeof(u) atIndex:0];
        [e setFragmentBytes:&u length:sizeof(u) atIndex:0];
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
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(14, 54, 360, 40)];
    lb.numberOfLines = 2;
    lb.textColor = UIColor.whiteColor;
    lb.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    lb.text = [NSString stringWithFormat:@"maru chrome on iOS — %u quads %s\nchrome.ui.tree + paint → Metal", n, maru_chrome_last_error()];
    [vc.view addSubview:lb];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
