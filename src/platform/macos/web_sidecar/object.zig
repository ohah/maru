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
