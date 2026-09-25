//! CEF C 구조체를 만드는 도구(W1b). CEF 는 구조체 첫 필드의 크기로 버전을 가르므로 0 으로 채운 뒤 크기를 넣는다.

const std = @import("std");
const c = @import("cef.zig").c;

pub fn zeroed(comptime T: type) T {
    var value = std.mem.zeroes(T);
    if (@hasField(T, "base")) {
        value.base.size = @sizeOf(T);
    } else if (@hasField(T, "size")) {
        value.size = @sizeOf(T);
    }
    return value;
}

/// **프로세스 수명 동안 사는 정적 객체 전용** 참조 카운트 — 세지도 풀지도 않는다. CEF 가 몇 번 잡고 놓든 객체는
/// 전역으로 남는다. 요청마다 만드는 동적 객체에는 쓰지 않는다(그런 객체는 실제로 세고 풀어야 한다).
pub fn staticRefCounted(base: *c.cef_base_ref_counted_t) void {
    base.add_ref = &noop_add_ref;
    base.release = &noop_release;
    base.has_one_ref = &noop_has_one_ref;
    base.has_at_least_one_ref = &noop_has_at_least_one_ref;
}

fn noop_add_ref(_: [*c]c.cef_base_ref_counted_t) callconv(.c) void {}

fn noop_release(_: [*c]c.cef_base_ref_counted_t) callconv(.c) c_int {
    return 0;
}

fn noop_has_one_ref(_: [*c]c.cef_base_ref_counted_t) callconv(.c) c_int {
    return 0;
}

fn noop_has_at_least_one_ref(_: [*c]c.cef_base_ref_counted_t) callconv(.c) c_int {
    return 1;
}

/// CEF 가 돌려준 참조(getter 반환값·목록이 쥔 browser)를 푼다.
pub fn release(ptr: anytype) void {
    if (ptr == null) return;
    _ = ptr.*.base.release.?(&ptr.*.base);
}

/// CEF 가 **콜백 인자로** 넘긴 객체는 콜백이 푼다. C API 헤더는 이 규칙을 적지 않지만 SDK 의 C++ 래퍼가 근거다 —
/// `libcef_dll/ctocpp/ctocpp_ref_counted.h` 의 `Wrap` 은 C 구조체로 받은 인자를 감싼 뒤 「넘기기 전에 저쪽이 더한
/// 참조」를 푼다(`UnderlyingRelease`). 즉 넘겨받은 쪽이 참조 하나를 가진다. 실측도 같다(W1c): 애니메이션 페이지에서
/// 36 초 동안 그리기 콜백 약 1,920 번마다 browser 인자를 풀어도 죽지 않았고, 안 풀면 RSS 가 조금씩 더 늘었다.
/// 거꾸로 **우리가 CEF 함수에 인자로 넘긴** CEF 객체(첫 인자 `self` 는 빼고)는 참조 하나가 CEF 로 옮겨 간다 — C++ 쪽
/// ctocpp `Unwrap` 이 더하고 받는 쪽 cpptoc `Unwrap` 이 푼다. 그래서 넘긴 뒤 우리가 또 풀면 하나 더 깎인다.
pub const release_callback_args = true;

/// 콜백 인자로 받은 객체를 다 썼을 때 부른다(`release_callback_args` 가 규칙을 든다).
pub fn releaseArg(ptr: anytype) void {
    if (release_callback_args) release(ptr);
}
