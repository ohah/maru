//! OS 통지는 창이나 runtime 포인터를 캡처하지 않는다. 전달 시 현재 main 소유자를 다시 조회한다.
const std = @import("std");
const builtin = @import("builtin");
var queued: std.atomic.Value(bool) = .init(false);
var pumping = false;
extern "c" fn maru_macos_dispatch_main(callback: *const fn (?*anyopaque) callconv(.c) void) void;
pub fn request() void {
    if (queued.swap(true, .acq_rel)) return;
    if (!builtin.is_test and builtin.os.tag == .macos) maru_macos_dispatch_main(deliver);
}
fn deliver(_: ?*anyopaque) callconv(.c) void {
    if (!queued.swap(false, .acq_rel)) return;
    if (pumping) {
        request();
        return;
    }
    pumping = true;
    defer pumping = false;
    @import("dispatch.zig").poll();
}
pub fn deliverForTest() bool {
    if (!builtin.is_test) @compileError("test-only main delivery");
    const pending = queued.load(.acquire);
    deliver(null);
    return pending;
}

pub fn queuedForTest() bool {
    if (!builtin.is_test) @compileError("test-only queue observation");
    return queued.load(.acquire);
}
