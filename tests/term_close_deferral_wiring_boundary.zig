//! 재접속 job 이 붙든 runtime 의 Term 을 사용자가 닫을 때 backend 닫기를 **미루는** 배선을 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 재접속 job 은 host 의 runtime 행을 붙든 채 여러 프레임에 걸쳐 전이한다. 그 사이 ⌘W 로 탭을 닫으면
//! `destroyTerm` 이 같은 호출 안에서 `closeAndDetach` → `remove` 까지 갔다 — 얼림 구간에는 runtime `deinit` 의
//! `tryDeinit` 이 `.busy` 라 `teardown invariant violated` 로, 커밋 뒤에는 job 의 다음 전이가 사라진 행을 찾다
//! `fatalIntegrity(.proof_loss)` 로 앱이 끝났다. backend 가 「아직」을 돌려줘도 사용자 닫기는 Term 을 트리에서 이미
//! 뺀 뒤라 다시 부를 자리가 없어 `@panic` 이었다.
//!
//! 판정(`term_close_deferral.zig`)은 순수 테스트가 잰다. 판정을 부르는 자리는 backend·AppSession 을 써서 PR 에서
//! 못 돌리므로 — **닫기를 보내기 전에** 판정이 있는지, 미룬 Term 을 tick·창 닫기·teardown 이 마저 닫는지를 여기서
//! 글자로 잰다.

const std = @import("std");

const term_path = "src/platform/macos/app_session/term.zig";
const workspace_path = "src/platform/macos/app_session/workspace.zig";
const app_session_path = "src/platform/macos/app_session.zig";
const backend_path = "src/platform/macos/session_host/remote_term_backend.zig";

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024 * 1024));
}

/// 주석을 지우고 공백 연속을 한 칸으로 줄인다 — 줄바꿈·들여쓰기는 의도가 아니므로 잠그지 않는다.
fn normalize(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_ws = false;
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        for (code) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                in_ws = true;
                continue;
            }
            if (in_ws and out.items.len != 0) try out.append(allocator, ' ');
            in_ws = false;
            try out.append(allocator, ch);
        }
        in_ws = true;
    }
    return out.toOwnedSlice(allocator);
}

fn countAll(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |f| : (at = f + needle.len) n += 1;
    return n;
}

fn expectOnce(haystack: []const u8, needle: []const u8, what: []const u8) !usize {
    const n = countAll(haystack, needle);
    if (n != 1) {
        std.debug.print("{s}: «{s}» 가 {d} 번 — 한 번이어야 한다\n", .{ what, needle, n });
        return error.WiringChanged;
    }
    return std.mem.indexOf(u8, haystack, needle).?;
}

fn expectBefore(haystack: []const u8, first: usize, needle: []const u8, what: []const u8) !void {
    const at = std.mem.indexOf(u8, haystack, needle) orelse {
        std.debug.print("{s}: «{s}» 가 없다\n", .{ what, needle });
        return error.WiringChanged;
    };
    if (first >= at) {
        std.debug.print("{s}: 판정이 «{s}» 보다 뒤에 있다 — 닫기를 보낸 뒤에는 이미 늦다\n", .{ what, needle });
        return error.WiringChanged;
    }
}

/// `header` 로 시작하는 함수의 본문 — 첫 `{` 뒤부터 짝이 맞는 `}` 앞까지. 주석은 이미 지워졌다.
fn bodyAfter(src: []const u8, header: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, header) orelse {
        std.debug.print("«{s}» 가 없다\n", .{header});
        return error.FunctionMissing;
    };
    const open = std.mem.indexOfScalarPos(u8, src, at + header.len, '{') orelse return error.FunctionMissing;
    var depth: usize = 0;
    var i = open;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return std.mem.trim(u8, src[open + 1 .. i], " ");
            },
            else => {},
        }
    }
    return error.FunctionMissing;
}

const defer_gate_first =
    "if (close_deferral.admit(reconnectHoldsTermRuntime(term)) == .defer_teardown) { deferTermTeardown(self, term); return; }";
const defer_gate_retry =
    "if (close_deferral.admit(reconnectHoldsTermRuntime(term)) == .defer_teardown) return false;";

test "재접속 닫기 미룸: destroyTerm 은 job 이 붙든 runtime 에 닫기를 보내기 전에 미룬다" {
    const a = std.testing.allocator;
    const raw = try read(a, term_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    const destroy = try bodyAfter(src, "fn destroyTermWithAbandonBackend(");
    const gate_at = try expectOnce(destroy, defer_gate_first, "destroyTermWithAbandonBackend");
    try expectBefore(destroy, gate_at, "closeAndDetach(term.rt.handle)", "destroyTermWithAbandonBackend");
    try expectBefore(destroy, gate_at, ".remove(term.rt.handle)", "destroyTermWithAbandonBackend");
    // 미루지 않은 첫 시도의 「아직」만 예전 불변식 위반이다 — 조건까지 판정 하나를 지난다.
    _ = try expectOnce(
        destroy,
        "close_deferral.afterClose(.first, self.backendFor(term).closeAndDetach(term.rt.handle) == .complete) == .invariant_violation) @panic(\"term destruction bypassed a pending close operation\");",
        "destroyTermWithAbandonBackend",
    );
    _ = try expectOnce(
        destroy,
        "close_deferral.afterRemove(.first, self.backendFor(term).remove(term.rt.handle) == .removed) == .invariant_violation) @panic(\"term destruction lost its terminal runtime\");",
        "destroyTermWithAbandonBackend",
    );
    // 미룬 Term 을 푸는 꼬리는 하나다 — 미룬 갈래는 그 앞에서 돌아간다.
    _ = try expectOnce(destroy, "freeTermOwned(self, term);", "destroyTermWithAbandonBackend");

    const holds = try bodyAfter(src, "fn reconnectHoldsTermRuntime(");
    _ = try expectOnce(holds, "return rb.reconnectJobHoldsRuntime(term.rt.handle);", "reconnectHoldsTermRuntime");
}

test "재접속 닫기 미룸: 미룬 Term 은 job 이 놓은 뒤에만 닫고, 목록에서 먼저 빼고 푼다" {
    const a = std.testing.allocator;
    const raw = try read(a, term_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    const retry = try bodyAfter(src, "fn retryDeferredTermClose(");
    const gate_at = try expectOnce(retry, defer_gate_retry, "retryDeferredTermClose");
    try expectBefore(retry, gate_at, "closeAndDetach(term.rt.handle)", "retryDeferredTermClose");
    try expectBefore(retry, gate_at, ".remove(term.rt.handle)", "retryDeferredTermClose");
    _ = try expectOnce(
        retry,
        "close_deferral.afterClose(.retry, self.backendFor(term).closeAndDetach(term.rt.handle) == .complete) == .defer_teardown) return false;",
        "retryDeferredTermClose",
    );
    _ = try expectOnce(
        retry,
        "close_deferral.afterRemove(.retry, self.backendFor(term).remove(term.rt.handle) == .removed) != .finish) return false;",
        "retryDeferredTermClose",
    );

    const advance = try bodyAfter(src, "pub fn advanceDeferredTermCloses(");
    _ = try expectOnce(advance, "if (!retryDeferredTermClose(self, term)) {", "advanceDeferredTermCloses");
    const take_at = try expectOnce(advance, "self.deferred_term_closes.orderedRemove(index);", "advanceDeferredTermCloses");
    // 해제는 한 자리뿐이고 목록에서 뺀 Term 에만 한다 — 목록에 남은 채 풀면 다음 순회가 해제된 Term 을 읽는다.
    const free_at = try expectOnce(advance, "freeTermOwned(", "advanceDeferredTermCloses");
    try expectBefore(advance, take_at, "freeTermOwned(self, done);", "advanceDeferredTermCloses");
    if (free_at < take_at) {
        std.debug.print("advanceDeferredTermCloses: 목록에서 빼기 전에 푼다\n", .{});
        return error.WiringChanged;
    }

    const drain = try bodyAfter(src, "pub fn drainDeferredTermClosesForTeardown(");
    const first_at = try expectOnce(drain, "advanceDeferredTermCloses(self);", "drainDeferredTermClosesForTeardown");
    const drain_take_at = try expectOnce(drain, "self.deferred_term_closes.orderedRemove(0);", "drainDeferredTermClosesForTeardown");
    try expectBefore(drain, first_at, "self.deferred_term_closes.orderedRemove(0);", "drainDeferredTermClosesForTeardown");
    const drain_free_at = try expectOnce(drain, "freeTermOwned(", "drainDeferredTermClosesForTeardown");
    if (drain_free_at < drain_take_at) {
        std.debug.print("drainDeferredTermClosesForTeardown: 목록에서 빼기 전에 푼다\n", .{});
        return error.WiringChanged;
    }
    if (std.mem.indexOf(u8, drain, "@panic(") != null) {
        std.debug.print("drainDeferredTermClosesForTeardown: teardown 이 남은 미룬 닫기로 abort 한다\n", .{});
        return error.WiringChanged;
    }
}

test "재접속 닫기 미룸: tick·창 닫기·Session teardown 이 미룬 목록을 마저 닫는다" {
    const a = std.testing.allocator;

    const app_raw = try read(a, app_session_path);
    defer a.free(app_raw);
    const app = try normalize(a, app_raw);
    defer a.free(app);
    // tick: 창 닫기보다 먼저 — 창 닫기는 이 목록이 빌 때까지 기다린다.
    _ = try expectOnce(
        app,
        "term_ops.advanceDeferredTermCloses(self); workspace_ops.advancePendingWindowClose(self);",
        "AppSession tick",
    );
    // teardown: 다른 무엇을 풀기 전에, abort 없이.
    const deinit = try bodyAfter(app, "pub fn deinit(self: *AppSession) void");
    if (!std.mem.startsWith(u8, deinit, "term_ops.drainDeferredTermClosesForTeardown(self); self.deferred_term_closes.deinit(self.allocator);")) {
        std.debug.print("AppSession.deinit: 첫 문장이 미룬 닫기 정리가 아니다\n", .{});
        return error.WiringChanged;
    }

    const ws_raw = try read(a, workspace_path);
    defer a.free(ws_raw);
    const ws = try normalize(a, ws_raw);
    defer a.free(ws);
    const close = try bodyAfter(ws, "fn advanceWindowClose(");
    if (!std.mem.startsWith(u8, close, "term_ops.advanceDeferredTermCloses(self); if (self.deferred_term_closes.items.len != 0) return .event_pending;")) {
        std.debug.print("advanceWindowClose: 미룬 닫기가 남았는데 창을 닫을 수 있다\n", .{});
        return error.WiringChanged;
    }
}

test "재접속 닫기 미룸: backend 는 job 이 붙든 행을 닫지도 빼지도 않는다" {
    const a = std.testing.allocator;
    const raw = try read(a, backend_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    const guard = "if (self.reconnectJobHoldsRuntime(handle)) return .event_pending;";
    const headers = [_][]const u8{
        "fn remove(ctx: *anyopaque, handle: RuntimeHandle) maru.app.term_runtime_backend.RemoveProgress",
        "fn requestRuntimeClose(",
        "pub fn windowCloseReadiness(self: *const RemoteTermBackend, handle: RuntimeHandle)",
    };
    for (headers) |header| {
        const body = try bodyAfter(src, header);
        // remove 는 첫 줄이 ctx 캐스트다 — 그 다음 문장이어야 한다.
        const rest = if (std.mem.startsWith(u8, body, "const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));"))
            std.mem.trimStart(u8, body["const self: *RemoteTermBackend = @ptrCast(@alignCast(ctx));".len..], " ")
        else
            body;
        if (!std.mem.startsWith(u8, rest, guard)) {
            std.debug.print("«{s}»: 첫 문장이 재접속 붙듦 관문이 아니다\n", .{header});
            return error.WiringChanged;
        }
    }

    const holds = try bodyAfter(src, "pub fn reconnectJobHoldsRuntime(");
    _ = try expectOnce(holds, "return term_close_deferral.holdsRuntime(phase, in_rows);", "reconnectJobHoldsRuntime");
    // 실패로 끝나 보관 중인 job 은 붙든 것이 아니다 — 여기서 갈리면 ⌘W 가 영영 안 닫힌다.
    _ = try expectOnce(
        holds,
        "else if (job.state_raw == @intFromEnum(HostReconnectJobState.host_failure_complete)) .retained_terminal",
        "reconnectJobHoldsRuntime",
    );
}
