#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>

typedef struct {
    int32_t status;
    uint32_t presented_frames;
    uint32_t drawable_failures;
} MaruMetalSmokeResult;

static void maru_pump_app_once(void) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.016];
    NSEvent *event = [NSApp
        nextEventMatchingMask:NSEventMaskAny
                    untilDate:until
                       inMode:NSDefaultRunLoopMode
                      dequeue:YES];
    if (event != nil) {
        [NSApp sendEvent:event];
    }
    [NSApp updateWindows];
    [CATransaction flush];
}

static BOOL maru_draw_clear_frame(
    CAMetalLayer *layer,
    id<MTLCommandQueue> queue,
    MaruMetalSmokeResult *result
) {
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (drawable == nil) {
        result->drawable_failures += 1;
        return NO;
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.06, 0.08, 0.12, 1.0);

    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    if (command_buffer == nil) {
        result->drawable_failures += 1;
        return NO;
    }

    id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:pass];
    if (encoder == nil) {
        result->drawable_failures += 1;
        return NO;
    }

    [encoder endEncoding];
    [command_buffer presentDrawable:drawable];
    [command_buffer commit];
    [command_buffer waitUntilCompleted];
    result->presented_frames += 1;
    return YES;
}

void maru_macos_metal_smoke_run(uint32_t duration_ms, MaruMetalSmokeResult *result) {
    result->status = -1;
    result->presented_frames = 0;
    result->drawable_failures = 0;

    @autoreleasepool {
        // 이 bridge는 "Metal renderer 완성"이 아니라 첫 GPU surface smoke다. Zig 쪽이
        // artifact와 실패 처리를 소유하고, 여기서는 CAMetalLayer에 clear frame을
        // 실제로 present할 수 있는지만 확인한다.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];

        if ([[NSScreen screens] count] == 0) {
            result->status = 2;
            return;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            result->status = 3;
            return;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (queue == nil) {
            result->status = 4;
            return;
        }

        NSRect frame = NSMakeRect(260.0, 260.0, 720.0, 420.0);
        NSWindowStyleMask style =
            NSWindowStyleMaskTitled |
            NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable |
            NSWindowStyleMaskResizable;

        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:style
                        backing:NSBackingStoreBuffered
                          defer:NO];
        if (window == nil) {
            result->status = 1;
            return;
        }

        NSView *content = [[NSView alloc]
            initWithFrame:NSMakeRect(0.0, 0.0, frame.size.width, frame.size.height)];
        content.wantsLayer = YES;

        CAMetalLayer *metal_layer = [CAMetalLayer layer];
        metal_layer.device = device;
        metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metal_layer.framebufferOnly = YES;
        metal_layer.contentsScale = window.backingScaleFactor;
        metal_layer.frame = content.bounds;
        metal_layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        metal_layer.drawableSize = CGSizeMake(
            content.bounds.size.width * window.backingScaleFactor,
            content.bounds.size.height * window.backingScaleFactor
        );

        content.layer = metal_layer;
        [window setTitle:@"Maru Metal smoke"];
        [window setReleasedWhenClosed:NO];
        [window setContentView:content];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        NSTimeInterval seconds = ((NSTimeInterval)duration_ms) / 1000.0;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

        // window smoke와 마찬가지로 직접 짧은 event pump를 돌린다. 매 루프마다
        // drawableSize를 최신 backing scale과 view bounds에 맞춰 갱신하고 clear
        // frame을 present해, "창은 뜨지만 Metal drawable은 못 얻는" 오탐을 막는다.
        do {
            @autoreleasepool {
                maru_pump_app_once();
                CGFloat scale = window.backingScaleFactor;
                metal_layer.contentsScale = scale;
                metal_layer.drawableSize = CGSizeMake(
                    content.bounds.size.width * scale,
                    content.bounds.size.height * scale
                );
                (void)maru_draw_clear_frame(metal_layer, queue, result);
            }
        } while ([[NSDate date] compare:deadline] == NSOrderedAscending);

        // Metal drawable present만으로는 "사용자가 볼 수 있는 UI"를 증명하지 못한다.
        // window smoke와 같은 기준으로 실제 NSWindow visibility를 함께 확인해야
        // headless/activation 실패에서 visible_ui=true 오탐을 막을 수 있다.
        BOOL became_visible = [window isVisible];
        [window orderOut:nil];

        if (!became_visible) {
            result->status = 5;
            return;
        }

        result->status = result->presented_frames > 0 ? 0 : 6;
    }
}
