//! 재접속 job 이 붙든 runtime 의 Term 을 닫을 때 backend 닫기를 **미루는** 배선을 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 재접속 job 은 host 의 runtime 행을 붙든 채 여러 프레임에 걸쳐 전이한다. 그 사이 ⌘W 로 탭을 닫으면
//! `destroyTerm` 이 같은 호출 안에서 `closeAndDetach` → `remove` 까지 갔다 — 얼림 구간에는 runtime `deinit` 의
//! `tryDeinit` 이 `.busy` 라 `teardown invariant violated` 로, 커밋 뒤에는 job 의 다음 전이가 사라진 행을 찾다
//! `fatalIntegrity(.proof_loss)` 로 앱이 끝났다. 창의 마지막 탭(⌘W → `latchSessionClose` → Session teardown)은
//! `destroyTerm` 을 거치지 않고 teardown pass 1·2 가 같은 일을 했다.
//!
//! 판정(`term_close_deferral.zig`)은 순수 테스트가 잰다. 판정을 부르는 자리는 backend·AppSession 을 써서 PR 에서 못
//! 돌리므로 여기서 **자리와 순서**를 잰다 — 판정이 닫기·제거 호출보다 앞에 있는가, 붙든 갈래가 backend 에 맡기는가,
//! 맡긴 닫기를 tick 과 teardown 이 다시 묻는가. 문장 전체를 글자로 잠그지 않는다(표현을 바꿔도 의도가 같으면 통과).

const std = @import("std");

const term_path = "src/platform/macos/app_session/term.zig";
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

fn find(haystack: []const u8, needle: []const u8, what: []const u8) !usize {
    return std.mem.indexOf(u8, haystack, needle) orelse {
        std.debug.print("{s}: «{s}» 가 없다\n", .{ what, needle });
        return error.WiringChanged;
    };
}

fn findOnce(haystack: []const u8, needle: []const u8, what: []const u8) !usize {
    const n = countAll(haystack, needle);
    if (n != 1) {
        std.debug.print("{s}: «{s}» 가 {d} 번 — 한 번이어야 한다\n", .{ what, needle, n });
        return error.WiringChanged;
    }
    return std.mem.indexOf(u8, haystack, needle).?;
}

fn expectOrder(first: usize, second: usize, what: []const u8, msg: []const u8) !void {
    if (first >= second) {
        std.debug.print("{s}: {s}\n", .{ what, msg });
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

/// `at` 에서 시작하는 `if (…)` 의 조건 괄호 안 — 괄호 짝으로 끊는다.
fn ifCondition(src: []const u8, at: usize) ![]const u8 {
    const open = std.mem.indexOfScalarPos(u8, src, at, '(') orelse return error.WiringChanged;
    var depth: usize = 0;
    var i = open;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return src[open + 1 .. i];
            },
            else => {},
        }
    }
    return error.WiringChanged;
}

test "재접속 닫기 미룸: destroyTerm·closeTermAt 은 job 이 붙든 runtime 에 닫기를 보내기 전에 backend 에 맡긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, term_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    const destroy = try bodyAfter(src, "fn destroyTermWithAbandonBackend(");
    const admit_at = try findOnce(destroy, "close_deferral.admit(reconnectHoldsTermRuntime(term))", "destroyTerm");
    const handoff_at = try findOnce(destroy, "handOffRuntimeCloseToBackend(term)", "destroyTerm");
    try expectOrder(admit_at, handoff_at, "destroyTerm", "맡기는 자리가 판정보다 앞에 있다");
    // 판정과 맡김은 닫기·제거 호출보다 앞이다 — 닫기를 보낸 뒤에는 이미 늦다.
    try expectOrder(handoff_at, try find(destroy, "closeAndDetach(term.rt.handle)", "destroyTerm"), "destroyTerm", "닫기를 판정보다 먼저 보낸다");
    try expectOrder(handoff_at, try find(destroy, ".remove(term.rt.handle)", "destroyTerm"), "destroyTerm", "제거를 판정보다 먼저 한다");
    // 예전 두 panic 은 첫 시도 판정의 위반 갈래에만 남는다.
    try expectOrder(
        try findOnce(destroy, "close_deferral.afterClose(.first,", "destroyTerm"),
        try findOnce(destroy, "term destruction bypassed a pending close operation", "destroyTerm"),
        "destroyTerm",
        "닫기 panic 이 첫 시도 판정 앞에 있다",
    );
    try expectOrder(
        try findOnce(destroy, "close_deferral.afterRemove(.first,", "destroyTerm"),
        try findOnce(destroy, "term destruction lost its terminal runtime", "destroyTerm"),
        "destroyTerm",
        "제거 panic 이 첫 시도 판정 앞에 있다",
    );

    // closeTermAt(에이전트 행 ✕·exit reap): 붙든 runtime 이면 닫기를 보내지 않고 destroyTerm 으로 간다(✕ 가 무시되지 않게).
    const close_at = try bodyAfter(src, "pub fn closeTermAt(");
    const close_call = try find(close_at, "closeAndDetach(target.rt.handle)", "closeTermAt");
    const if_at = std.mem.lastIndexOf(u8, close_at[0..close_call], "if (") orelse return error.WiringChanged;
    const outer_if = std.mem.lastIndexOf(u8, close_at[0..if_at], "if (") orelse return error.WiringChanged;
    const cond = try ifCondition(close_at, outer_if);
    if (std.mem.indexOf(u8, cond, "!reconnectHoldsTermRuntime(target)") == null) {
        std.debug.print("closeTermAt: 닫기 조건에 재접속 붙듦 판정이 없다 — «{s}»\n", .{cond});
        return error.WiringChanged;
    }

    const holds = try bodyAfter(src, "pub fn reconnectHoldsTermRuntime(");
    _ = try findOnce(holds, "reconnectJobHoldsRuntime(term.rt.handle)", "reconnectHoldsTermRuntime");
    const handoff = try bodyAfter(src, "pub fn handOffRuntimeCloseToBackend(");
    _ = try findOnce(handoff, "closeRuntimeAfterReconnect(term.rt.handle)", "handOffRuntimeCloseToBackend");
}

test "재접속 닫기 미룸: Session teardown 은 붙든 runtime 을 닫지도 빼지도 않고 backend 에 맡긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, app_session_path);
    defer a.free(raw);
    const app = try normalize(a, raw);
    defer a.free(app);

    const deinit = try bodyAfter(app, "pub fn deinit(self: *AppSession) void");
    // 첫머리: 맡긴 닫기를 다른 무엇(앱 quit 의 routing tombstone 포함)보다 먼저 다시 묻는다.
    const advance_at = try findOnce(deinit, "term_ops.advanceReconnectDeferredCloses()", "AppSession.deinit");
    try expectOrder(advance_at, try find(deinit, "beginAppQuitShutdown(", "AppSession.deinit"), "AppSession.deinit", "맡긴 닫기를 앱 quit 시작 뒤에 묻는다");

    // pass 1: 붙든 runtime 은 닫기를 보내지 않는다 — 판정이 닫기 호출과 panic 보다 앞이다.
    const pass1_panic = try findOnce(deinit, "process teardown reached an active terminal close operation", "AppSession.deinit");
    const pass1_close = std.mem.lastIndexOf(u8, deinit[0..pass1_panic], "closeAndDetach(term.rt.handle)") orelse
        return error.WiringChanged;
    const pass1_skip = std.mem.lastIndexOf(u8, deinit[0..pass1_close], "if (term_ops.reconnectHoldsTermRuntime(term)) continue;") orelse {
        std.debug.print("AppSession.deinit pass 1: 붙든 runtime 을 건너뛰지 않고 닫는다\n", .{});
        return error.WiringChanged;
    };
    const pass1_loop = std.mem.lastIndexOf(u8, deinit[0..pass1_close], "for (pane.terms.items) |term|") orelse
        return error.WiringChanged;
    try expectOrder(pass1_loop, pass1_skip, "AppSession.deinit pass 1", "건너뛰기가 같은 순회 안에 없다");

    // pass 2: 붙든 runtime 은 빼지 않고 backend 에 맡긴다 — 그 갈래가 remove 갈래 앞이다.
    const pass2_panic = try findOnce(deinit, "approved window teardown lost its terminal runtime", "AppSession.deinit");
    const pass2_remove = std.mem.lastIndexOf(u8, deinit[0..pass2_panic], ".remove(term.rt.handle)") orelse
        return error.WiringChanged;
    const pass2_handoff = std.mem.lastIndexOf(u8, deinit[0..pass2_remove], "term_ops.handOffRuntimeCloseToBackend(term)") orelse {
        std.debug.print("AppSession.deinit pass 2: 붙든 runtime 을 맡기지 않고 뺀다\n", .{});
        return error.WiringChanged;
    };
    const pass2_cond = std.mem.lastIndexOf(u8, deinit[0..pass2_handoff], "term_ops.reconnectHoldsTermRuntime(term)") orelse
        return error.WiringChanged;
    try expectOrder(pass1_panic, pass2_cond, "AppSession.deinit pass 2", "맡김 판정이 pass 2 가 아닌 자리에 있다");
}

test "재접속 닫기 미룸: 창이 0 개여도 도는 재접속 tick 이 맡긴 닫기를 다시 묻고, drain 은 「아직」인 종료를 들고 다시 finish 한다" {
    const a = std.testing.allocator;
    const raw = try read(a, app_session_path);
    defer a.free(raw);
    const app = try normalize(a, raw);
    defer a.free(app);

    // 앱 전역 재접속 tick(Swift tickAppSession 이 창 유무 guard **앞**에서 매 frame 부른다): backend 가 있으면 coordinator
    // 준비 여부와 무관하게 묻는다 — 판정이 coordinator 준비 검사보다 앞이다.
    const tick = try bodyAfter(app, "pub fn tickReconnectProductCoordinator()");
    const backend_at = try find(tick, "const backend =", "tickReconnectProductCoordinator");
    const advance_at = try findOnce(tick, "backend.advanceReconnectDeferredCloses()", "tickReconnectProductCoordinator");
    const ready_at = try find(tick, "app_reconnect_product_coordinator.ready", "tickReconnectProductCoordinator");
    try expectOrder(backend_at, advance_at, "tickReconnectProductCoordinator", "backend 를 얻기 전에 묻는다");
    try expectOrder(advance_at, ready_at, "tickReconnectProductCoordinator", "coordinator 가 준비되지 않으면 맡긴 닫기가 멈춘다");
    // 창 tick 은 묻지 않는다(창이 0 개면 멈춘다) — AppSession 쪽 호출은 Session teardown 한 곳뿐이다.
    _ = try findOnce(app, "term_ops.advanceReconnectDeferredCloses()", "AppSession");

    // 끝 보고는 한 번뿐이다 — 「아직」이면 Term 에 들고, 다음 tick 의 판정이 그것을 다시 쓴다.
    const reap = try findOnce(app, "finishAfterTermination(term.rt.handle) == .event_pending", "AppSession reap");
    const retry_source = try findOnce(app, "ds.ended orelse term.rt.pending_termination", "AppSession reap");
    try expectOrder(retry_source, reap, "AppSession reap", "들고 있던 종료를 finish 뒤에 읽는다");
    const keep_at = try find(app[reap..], "term.rt.pending_termination = ended;", "AppSession reap");
    const continue_at = try find(app[reap..], "continue;", "AppSession reap");
    try expectOrder(keep_at, continue_at, "AppSession reap", "「아직」인 종료를 들지 않고 건너뛴다");
}

test "재접속 닫기 미룸: backend 는 붙든 행을 닫지도 빼지도 않고, 맡은 닫기는 job 이 놓은 뒤 이어서 닫는다" {
    const a = std.testing.allocator;
    const raw = try read(a, backend_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    // 세 입구 모두 맵·authority 를 만지기 전에 붙듦을 묻는다.
    const headers = [_][]const u8{
        "fn remove(ctx: *anyopaque, handle: RuntimeHandle) maru.app.term_runtime_backend.RemoveProgress",
        "fn requestRuntimeClose(",
        "pub fn windowCloseReadiness(self: *const RemoteTermBackend, handle: RuntimeHandle)",
    };
    for (headers) |header| {
        const body = try bodyAfter(src, header);
        const guard = try find(body, "self.reconnectJobHoldsRuntime(handle)) return .event_pending", header);
        try expectOrder(guard, try find(body, "self.runtimes.get(handle)", header), header, "맵을 읽은 뒤에 붙듦을 묻는다");
        try expectOrder(guard, try find(body, "close_operation_owner.active", header), header, "close 소유권을 본 뒤에 붙듦을 묻는다");
    }

    const holds = try bodyAfter(src, "pub fn reconnectJobHoldsRuntime(");
    _ = try findOnce(holds, "term_close_deferral.holdsRuntime(", "reconnectJobHoldsRuntime");
    // 실패로 끝나 보관 중인 job 은 retained-terminal 로 접힌다 — 붙든 것으로 치면 ⌘W 가 영영 안 닫힌다.
    try expectOrder(
        try findOnce(holds, "HostReconnectJobState.host_failure_complete", "reconnectJobHoldsRuntime"),
        try findOnce(holds, ".retained_terminal", "reconnectJobHoldsRuntime"),
        "reconnectJobHoldsRuntime",
        "host_failure_complete 가 retained_terminal 로 접히지 않는다",
    );

    // 맡은 닫기: 앱 quit 의 shutdown 이 시작되면 멈춘다(quit 이 그 runtime 의 ordinal 을 소유한다). 그다음 붙듦을 먼저 묻고,
    // 닫기 → 제거가 끝난 handle 만 뺀다.
    const advance = try bodyAfter(src, "pub fn advanceReconnectDeferredCloses(");
    const quit_at = try findOnce(advance, "term_close_deferral.queueMayAdvance(self.app_quit_shutdown_deadline_ns != 0)", "advanceReconnectDeferredCloses");
    const admit_at = try findOnce(advance, "term_close_deferral.admit(self.reconnectJobHoldsRuntime(handle))", "advanceReconnectDeferredCloses");
    try expectOrder(quit_at, try find(advance, "while (", "advanceReconnectDeferredCloses"), "advanceReconnectDeferredCloses", "앱 quit 판정이 목록 순회 안에 있다");
    const close_at = try findOnce(advance, "self.requestRuntimeClose(handle,", "advanceReconnectDeferredCloses");
    const remove_at = try findOnce(advance, "remove(self, handle)", "advanceReconnectDeferredCloses");
    try expectOrder(admit_at, close_at, "advanceReconnectDeferredCloses", "job 이 붙든 채 닫는다");
    try expectOrder(close_at, remove_at, "advanceReconnectDeferredCloses", "닫기 전에 뺀다");
    const done_at = std.mem.lastIndexOf(u8, advance, "self.reconnect_deferred_closes.orderedRemove(index)") orelse
        return error.WiringChanged;
    try expectOrder(remove_at, done_at, "advanceReconnectDeferredCloses", "제거가 끝나기 전에 목록에서 뺀다");
    _ = try findOnce(advance, "term_close_deferral.afterRemove(.retry,", "advanceReconnectDeferredCloses");
}
