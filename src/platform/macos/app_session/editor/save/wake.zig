//! 저장 actor의 메인 큐 통지. 문서/창을 빌리지 않고 도착 시 현재 소유자를 다시 찾는다.
const std = @import("std");
const builtin = @import("builtin");
const host = @import("../../../app_session.zig");
var queued = std.atomic.Value(bool).init(false);
var pumping = false; // 메인 스레드만 접근한다.
extern "c" fn maru_macos_dispatch_main(callback: *const fn (?*anyopaque) callconv(.c) void) void;

/// 게시자가 worker여도 안전하다. callback은 절대로 게시자를 동기 대기하지 않는다.
pub fn request() void {
    if (queued.swap(true, .acq_rel)) return;
    if (!builtin.is_test and builtin.os.tag == .macos) maru_macos_dispatch_main(deliver);
}
fn deliver(_: ?*anyopaque) callconv(.c) void {
    // 먼저 내린다. 처리 도중 생긴 완료/후속 요청은 다음 turn을 예약할 수 있어야 한다.
    if (!queued.swap(false, .acq_rel)) return;
    if (pumping) {
        request();
        return;
    }
    pumping = true;
    defer pumping = false;
    @import("dispatch.zig").poll();
    @import("as.zig").poll();
    // 닫기 후에는 borrowed 창 배열을 버리고 다시 조회한다.
    var i: usize = 0;
    while (i < host.editorSaveWindows().len) {
        const session = host.editorSaveWindows()[i];
        @import("close.zig").poll(session);
        if (i < host.editorSaveWindows().len and host.editorSaveWindows()[i] == session) i += 1;
    }
}
/// headless 검증도 제품과 같은 drain을 쓰되 OS run loop나 frame tick은 돌리지 않는다.
pub fn deliverForTest() bool {
    if (!builtin.is_test) @compileError("test-only save wake delivery");
    const pending = queued.load(.acquire);
    deliver(null);
    return pending;
}

/// 메인 입력/포맷 종료 훅은 저장이 있을 때만 통지를 만든다.
pub fn resumePending() void {
    var pending = @import("dispatch.zig").requestCount() != 0 or @import("as.zig").pending() != 0;
    for (host.editorSaveWindows()) |session| if (session.editor_save_close) |state| {
        if (state.receipt != null) pending = true;
    };
    if (pending) request();
}
