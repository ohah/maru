//! 어떤 프로세스가 가진 창의 수(W1c). 창 없는 브라우저만 쓰는 sidecar 는 창이 **0 개**여야 한다 — 같은 프로필로 다시
//! 실행되거나 페이지가 `window.open` 을 부르면 Chromium 의 기본 동작이 네이티브 창이라(실측) 이것으로 잡는다.

extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) ?*anyopaque;
extern "c" fn CFArrayGetCount(array: *anyopaque) isize;
extern "c" fn CFArrayGetValueAtIndex(array: *anyopaque, index: isize) ?*anyopaque;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *const anyopaque) ?*anyopaque;
extern "c" fn CFNumberGetValue(number: *anyopaque, kind: isize, out: *anyopaque) u8;
extern "c" fn CFRelease(object: *anyopaque) void;
extern "c" const kCGWindowOwnerPID: *const anyopaque;

const kCGWindowListOptionAll: u32 = 0;
const kCFNumberSInt32Type: isize = 3;

pub fn ownedBy(pid: c_int) usize {
    const list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, 0) orelse return 0;
    defer CFRelease(list);
    var owned: usize = 0;
    var i: isize = 0;
    while (i < CFArrayGetCount(list)) : (i += 1) {
        const info = CFArrayGetValueAtIndex(list, i) orelse continue;
        const number = CFDictionaryGetValue(info, kCGWindowOwnerPID) orelse continue;
        var owner: i32 = 0;
        if (CFNumberGetValue(number, kCFNumberSInt32Type, &owner) != 0 and owner == pid) owned += 1;
    }
    return owned;
}
