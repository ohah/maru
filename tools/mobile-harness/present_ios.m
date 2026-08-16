// PoC 8(iOS): **present 페이싱을 측정한다.**
//
// 여섯 기능 중 마지막 항목이다. 오프스크린으로는 볼 수 없어 미확인으로 남아 있었다 —
// 스왑체인(여기서는 CAMetalLayer)이 있어야 "언제 화면에 나갔는가"가 존재한다.
//
// **판정은 요청이 아니라 실측으로 한다.** 30Hz 를 요청했다는 사실은 근거가 못 된다.
// `CADisplayLink.timestamp` 는 **표시 클럭**(직전 vsync 시각)이므로 그 간격의 중앙값을
// 재서 요청한 주기와 맞는지 본다. 벽시계가 아니다.
//
// **iOS 의 페이싱 수단은 macOS 와 다르다.** `presentAfterMinimumDuration:`·`presentedTime`·
// `addPresentedHandler:` 는 iOS SDK 에 아예 없다(실측: iPhoneSimulator26.2.sdk 의
// MTLDrawable 에는 `present`/`presentAtTime:` 둘뿐). iOS 에서 주기를 정하는 것은
// `CADisplayLink` 의 프레임 레이트 범위이고, Metal 쪽 수단은 `presentDrawable:atTime:`
// 와 `CAMetalLayer.maximumDrawableCount`(큐 깊이)다.
//
// maru 는 30Hz present(comfort)를 쓴다 — 그 페이싱이 iOS 에서 서는지가 실질 질문이다.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

// **이 값들은 제품과 따로다 — 일부러 그렇다.** 제품 host 는 `mobile_host_abi.h` 의
// `MARU_FRAME_*` 를 쓰지만, 여기는 "iOS 가 30Hz 를 낼 수 있는가" 를 재는 **능력 프로브**라
// 제품 정책을 가져오면 정책이 바뀔 때 질문 자체가 바뀐다. 아래 창(25~42ms)도 제품의 ±25/30%
// 와 다른 근거로 유도했다 — 한 vsync(16.7ms)의 절반이다.
//
// **대신 자동으로 안 따라온다**: 제품 주기가 30 이 아니게 되면 여기 30 은 그대로 남아
// README 의 측정표가 제품과 다른 것을 재게 된다. 그때 이 파일도 함께 손봐야 한다.
#define WARMUP 20
#define SAMPLES 60

typedef enum { PHASE_WARMUP, PHASE_FREE, PHASE_30HZ, PHASE_DONE } Phase;

@interface PacingView : UIView
@end

@implementation PacingView {
    CAMetalLayer *_layer;
    id<MTLDevice> _dev;
    id<MTLCommandQueue> _q;
    CADisplayLink *_link;
    Phase _phase;
    int _count;
    double _last;
    double _free[SAMPLES];
    double _hz30[SAMPLES];
    int _nfree, _n30;
}

+ (Class)layerClass { return CAMetalLayer.class; }

- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _dev = MTLCreateSystemDefaultDevice();
    _q = [_dev newCommandQueue];
    _layer = (CAMetalLayer *)self.layer;
    _layer.device = _dev;
    _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _layer.framebufferOnly = YES;
    // 큐 깊이도 페이싱 수단이다 — 2 면 CPU 가 GPU 보다 한 프레임 이상 앞서지 못한다.
    _layer.maximumDrawableCount = 3;
    _phase = PHASE_WARMUP;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return self;
}

static double medianOf(double *v, int n) {
    for (int i = 1; i < n; i++) {
        double k = v[i]; int j = i - 1;
        while (j >= 0 && v[j] > k) { v[j + 1] = v[j]; j--; }
        v[j + 1] = k;
    }
    return n ? v[n / 2] : 0;
}

- (void)requestThirtyHz {
    if (@available(iOS 15.0, *)) {
        _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 30, 30);
    } else {
        _link.preferredFramesPerSecond = 30;
    }
}

- (void)report {
    double free_ms = medianOf(_free, _nfree) * 1000.0;
    double hz30_ms = medianOf(_hz30, _n30) * 1000.0;
    NSLog(@"MARU_PACE drawable_count=%lu", (unsigned long)_layer.maximumDrawableCount);
    NSLog(@"MARU_PACE free_median_ms=%.2f n=%d", free_ms, _nfree);
    NSLog(@"MARU_PACE throttled_median_ms=%.2f n=%d target=33.33", hz30_ms, _n30);
    // 30Hz 요청이 실제 표시 간격으로 나타나야 PASS 다. 허용 범위는 한 vsync(16.7ms)의 절반.
    BOOL paced = (hz30_ms >= 25.0 && hz30_ms <= 42.0);
    BOOL slower = (hz30_ms > free_ms * 1.4);
    NSLog(@"MARU_PACE verdict=%s paced=%d slower_than_free=%d",
          (paced && slower) ? "PASS" : "FAIL", paced, slower);
}

- (void)tick:(CADisplayLink *)link {
    if (_phase == PHASE_DONE) return;

    // 표시 클럭. 벽시계(CACurrentMediaTime)가 아니라 직전 vsync 시각이다.
    double now = link.timestamp;
    if (_last > 0 && now > _last) {
        double dt = now - _last;
        if (_phase == PHASE_FREE && _nfree < SAMPLES) _free[_nfree++] = dt;
        if (_phase == PHASE_30HZ && _n30 < SAMPLES) _hz30[_n30++] = dt;
    }
    _last = now;

    id<CAMetalDrawable> d = [_layer nextDrawable];
    if (d) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        // 위상이 눈에 보이게 색을 굴린다 — 화면이 실제로 갱신되는지 사람도 확인할 수 있다.
        double t = _count / 60.0;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1 + 0.3 * fabs(sin(t)), 0.12, 0.16, 1);
        id<MTLCommandBuffer> cb = [_q commandBuffer];
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        [cb presentDrawable:d];
        [cb commit];
    }
    _count++;

    if (_phase == PHASE_WARMUP && _count >= WARMUP) { _phase = PHASE_FREE; _last = 0; }
    else if (_phase == PHASE_FREE && _nfree >= SAMPLES) {
        _phase = PHASE_30HZ; _last = 0;
        [self requestThirtyHz];
    } else if (_phase == PHASE_30HZ && _n30 >= SAMPLES) {
        _phase = PHASE_DONE;
        [_link invalidate];
        [self report];
    }
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    vc.view = [[PacingView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    NSLog(@"MARU_PACE start screen_max_fps=%ld", (long)UIScreen.mainScreen.maximumFramesPerSecond);
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
