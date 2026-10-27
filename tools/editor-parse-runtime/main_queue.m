// 제품과 같은 어댑터를 링크한다. 테스트 전용 dispatch 대체 구현을 만들지 않는다.
#include "../../src/platform/macos/main_queue.c.inc"
#include <CoreFoundation/CoreFoundation.h>
void maru_parse_run_main_turn(void) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
}
