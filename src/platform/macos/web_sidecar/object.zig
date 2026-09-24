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

/// CEF 가 **콜백 인자로** 넘긴 객체는 콜백이 푼다. SDK 헤더는 이 규칙을 적지 않아 실측으로 정했다(W1c): 애니메이션
/// 페이지에서 36 초 동안 그리기 콜백 약 1,920 번마다 browser 인자를 풀어도 죽지 않았다 — 인자가 우리 몫의 참조가 아니었다면
/// 목록이 쥔 참조까지 깎여 몇 번 만에 해제된 객체를 썼을 것이다. 안 풀면 RSS 가 조금씩 더 늘었다(24 초에 +700KB 대 +370KB).
pub const release_callback_args = true;

/// 콜백 인자로 받은 객체를 다 썼을 때 부른다(`release_callback_args` 가 규칙을 든다).
pub fn releaseArg(ptr: anytype) void {
    if (release_callback_args) release(ptr);
}
