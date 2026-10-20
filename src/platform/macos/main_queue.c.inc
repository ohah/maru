// Apple Dispatch의 main queue를 쓰는 내부 어댑터다. payload에 창/문서 포인터를 담지 않는다.
#include <dispatch/dispatch.h>
__attribute__((visibility("hidden")))
void maru_macos_dispatch_main(void (*callback)(void *)) {
    dispatch_async_f(dispatch_get_main_queue(), NULL, callback);
}
