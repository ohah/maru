// PoC 4: 시뮬레이터 화면에 실제로 띄운다.
//
// 오프스크린은 "그려진다"를 증명하지만 눈으로 볼 수 없다. UIKit 창에
// CAMetalLayer 를 붙여 maru 가 낼 draw-list 와 같은 종류의 quad 들을 그린다.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

extern unsigned int maru_poc_smoke(void);

static NSString *const kShader = @"#include <metal_stdlib>\n"
                                  "using namespace metal;\n"
                                  "struct VOut { float4 pos [[position]]; float4 color; };\n"
                                  "vertex VOut v_main(uint vid [[vertex_id]],\n"
                                  "                   constant float4 *rect [[buffer(0)]],\n"
                                  "                   constant float4 *col [[buffer(1)]]) {\n"
                                  "  float2 p[4] = { float2(rect->x, rect->y), float2(rect->z, rect->y),\n"
                                  "                  float2(rect->x, rect->w), float2(rect->z, rect->w) };\n"
                                  "  VOut o; o.pos = float4(p[vid], 0, 1); o.color = *col; return o;\n"
                                  "}\n"
                                  "fragment float4 f_main(VOut in [[stage_in]]) { return in.color; }\n";

@interface MaruView : UIView
@end

@implementation MaruView {
    id<MTLDevice> _dev;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipe;
    CADisplayLink *_link;
    int _frame;
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
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v_main"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f_main"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _pipe = [_dev newRenderPipelineStateWithDescriptor:pd error:&err];
    _queue = [_dev newCommandQueue];

    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    return self;
}

- (void)tick {
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    l.drawableSize = CGSizeMake(self.bounds.size.width * UIScreen.mainScreen.scale,
                                self.bounds.size.height * UIScreen.mainScreen.scale);
    id<CAMetalDrawable> d = [l nextDrawable];
    if (!d) return;

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = d.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.07, 0.07, 0.09, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:_pipe];

    // 터미널 셀 격자 — 커서가 깜빡이는 것까지 흉내 내 프레임이 도는 것을 눈으로 보이게 한다.
    const int COLS = 24, ROWS = 10;
    float palette[6][3] = {
        {0.86f, 0.20f, 0.18f}, {0.20f, 0.72f, 0.35f}, {0.90f, 0.68f, 0.18f},
        {0.25f, 0.52f, 0.90f}, {0.70f, 0.35f, 0.85f}, {0.25f, 0.75f, 0.80f},
    };
    for (int r = 0; r < ROWS; r++) {
        for (int c = 0; c < COLS; c++) {
            float x0 = -1.0f + 2.0f * ((float)c / COLS) + 0.003f;
            float x1 = -1.0f + 2.0f * ((float)(c + 1) / COLS) - 0.003f;
            float y1 = 1.0f - 2.0f * ((float)r / ROWS) - 0.006f;
            float y0 = 1.0f - 2.0f * ((float)(r + 1) / ROWS) + 0.006f;
            float rect[4] = {x0, y0, x1, y1};
            float fade = 0.30f + 0.70f * ((float)c / COLS);
            float color[4] = {palette[r % 6][0] * fade, palette[r % 6][1] * fade,
                              palette[r % 6][2] * fade, 1.0f};
            // 마지막 행 끝에 커서 — 30프레임 주기로 깜빡인다
            if (r == ROWS - 1 && c == COLS - 1 && ((_frame / 30) % 2 == 0)) {
                color[0] = color[1] = color[2] = 0.95f;
            }
            [enc setVertexBytes:rect length:sizeof(rect) atIndex:0];
            [enc setVertexBytes:color length:sizeof(color) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
    }
    [enc endEncoding];
    [cb presentDrawable:d];
    [cb commit];
    _frame++;
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    unsigned int rc = maru_poc_smoke();
    NSLog(@"MARU_POC zig_core_rc=%u", rc);

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    MaruView *v = [[MaruView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    vc.view = v;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, 340, 76)];
    label.numberOfLines = 3;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    label.text = [NSString stringWithFormat:@"maru core on iOS — rc=%u\nZig terminal core + Metal\nCADisplayLink 로 매 프레임 갱신", rc];
    [v addSubview:label];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
