//! 앱 메인 소유 파싱 runtime. 종료 전에 전역 소유자를 먼저 내리므로 늦은 OS 전달도 안전하다.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const syntax = @import("syntax");
pub const runtime = @import("runtime.zig");
pub const worker = @import("worker.zig");
pub const wake = @import("wake.zig");
pub const registry = maru.session.editor.document_registry;
pub const request = maru.session.editor.syntax.request;
var active: ?runtime.Runtime = null;
fn allocator() std.mem.Allocator {
    return if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;
}
/// 내부 연결 API다. 일반 편집기의 기존 점진 파싱 경로는 아직 이 API로 전환하지 않는다.
pub fn submit(source: registry.Lease, grammar: request.Grammar, language: syntax.Language) !request.Request {
    if (!builtin.is_test and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    if (active == null) active = try runtime.Runtime.init(allocator(), .{ .notify = wake.request });
    return active.?.submit(source, grammar, language) catch |err| {
        if (active.?.entries.items.len == 0) shutdown();
        return err;
    };
}
pub fn ready(identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) ?*const worker.Completion {
    if (active) |*owner| return owner.ready(identity, grammar, language);
    return null;
}
/// 알림·재시도는 호출자의 정책이다. 현재 요청의 게시·완료 사실만 조회한다.
pub fn observe(identity: registry.DocumentIdentity, grammar: request.Grammar, language: syntax.Language) runtime.Observation {
    if (active) |*owner| return owner.observe(identity, grammar, language);
    return .none;
}
pub fn poll() void {
    if (active) |*owner| {
        owner.poll();
        // 문서가 모두 회수됐다면 native 작업도 없다. 닫기에서 실행 중 worker를 동기 대기하지 않는다.
        if (owner.entries.items.len == 0) shutdown();
    }
}
pub fn viewsChanged() void {
    if (active) |*owner| {
        owner.sweep();
        if (owner.entries.items.len == 0) shutdown();
    }
}
pub fn shutdown() void {
    var owner = active orelse return;
    active = null;
    owner.deinit();
}
pub fn lastPollThread() ?std.Thread.Id {
    return if (active) |owner| owner.last_poll_thread else null;
}
