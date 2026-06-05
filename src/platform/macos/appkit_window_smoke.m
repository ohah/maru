#import <Cocoa/Cocoa.h>
#include <stdint.h>

int maru_macos_window_smoke_run(uint32_t duration_ms) {
    @autoreleasepool {
        // 이 bridge는 "제품 UI"가 아니라 첫 window lifecycle smoke다. Zig 쪽에서
        // artifact와 실패 처리를 담당하고, 여기서는 Cocoa가 실제 창을 띄울 수
        // 있는지만 확인한다.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];

        // Metal surface와 terminal grid는 아직 없다. 그래서 내용을 그리기보다
        // 정상적인 native macOS 창을 만들고 짧게 event loop를 돈다는 사실만 검증한다.
        NSRect frame = NSMakeRect(240.0, 240.0, 720.0, 420.0);
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
            return 1;
        }

        [window setTitle:@"Maru window smoke"];
        [window setReleasedWhenClosed:NO];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        NSTimeInterval seconds = ((NSTimeInterval)duration_ms) / 1000.0;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

        // NSApplication run을 호출하면 사용자가 직접 종료해야 하므로 smoke에 맞지 않다.
        // 짧은 수동 event pump만 돌려서 창이 보이는 동안 입력/노출 이벤트를 처리하고
        // 자동으로 종료되게 한다.
        while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
            @autoreleasepool {
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
            }
        }

        [window orderOut:nil];
    }

    return 0;
}
