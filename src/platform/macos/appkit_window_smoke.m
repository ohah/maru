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

        // window server에 연결된 display가 없으면(headless/CI, GUI 세션 없는 ssh)
        // 실제로 보이는 창을 띄울 수 없다. nil 창만 실패로 보던 검사로는 이 경우를
        // 놓쳐 visible_ui=true 오탐이 난다. 별도 코드로 돌려 Zig summary가 구분한다.
        if ([[NSScreen screens] count] == 0) {
            return 2;
        }

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
        // 자동으로 종료되게 한다. 아주 짧은 duration에서도 창이 한 frame은 노출되도록
        // do/while로 최소 한 번은 pump한다(그냥 while이면 deadline이 이미 지나 body가
        // 한 번도 안 돌고 창이 뜨자마자 사라질 수 있다).
        do {
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
        } while ([[NSDate date] compare:deadline] == NSOrderedAscending);

        // makeKeyAndOrderFront만으로는 "창이 실제로 화면에 올라왔다"를 보장하지 못한다.
        // window server 접근이 막혔거나(automation/세션 제약) 다른 앱이 activation을
        // 거부하면 alloc은 성공해도 창은 끝내 안 보일 수 있다. 그 경우 status 0을
        // 돌려주면 screens==0 가드(return 2)가 막으려던 것과 같은 visible_ui=true
        // 오탐이 난다. orderOut 전에 isVisible로 확인해 별도 코드(3)로 구분한다.
        BOOL became_visible = [window isVisible];
        [window orderOut:nil];

        if (!became_visible) {
            return 3;
        }
    }

    return 0;
}
