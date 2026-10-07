//! 재접속 job 이 **재시도 없이 끝나는 모든 갈래**가 그 자리에서 한 줄을 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-10-04 23:43 — 잠자기 뒤 read_timeout poison 으로 재접속 job 이 하나 생겼고(`reconnect turn idle:
//! admissions=0 jobs=1`), 그 뒤 50분 동안 재접속 관련 줄이 **0** 이었다. 세션은 앱 재시작으로만 돌아왔다.
//! `deadline_exceeded`·`host_gone` 으로 끝나는 갈래는 입장 결속만 풀고 조용히 사라졌고, `retry_later` 로 다시 넣는
//! 갈래도 아무것도 남기지 않아 「첫 시도가 왜 실패했나」를 가릴 수 없었다.
//!
//! 2026-10-07 같은 사고가 다시 났고, 이 기록이 원인을 「첫 시도가 5 초 안에 연결을 못 마쳤는데 `deadline_exceeded` 가
//! 종결이라 다시 안 걸었다」로 판정했다. 그 뒤로 `deadline_exceeded` 는 새 데드라인·대기로 다시 넣는다
//! (`reconnect_retry_policy.zig`) — 이 판정자는 그 배선도 함께 잰다.
//!
//! 서식·판정(`reconnect_failure_log.zig`)은 순수 테스트가 잰다. 정산 갈래는 backend·워커 스레드를 써서 PR 에서
//! 못 돌린다 — 그래서 각 갈래가 그 기록을 **제자리에서, 조건 없이** 부르는지를 여기서 글자로 잰다.

const std = @import("std");

const coordinator_path = "src/platform/macos/session_host/reconnect_product_coordinator.zig";
const issuer_path = "src/platform/macos/session_host/reconnect_worker_issuer.zig";

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

fn expectCount(haystack: []const u8, needle: []const u8, want: usize, what: []const u8) !void {
    const n = countAll(haystack, needle);
    if (n != want) {
        std.debug.print("{s}: «{s}» 가 {d} 번 — {d} 번이어야 한다\n", .{ what, needle, n, want });
        return error.WiringChanged;
    }
}

fn expectOnce(haystack: []const u8, needle: []const u8, what: []const u8) !usize {
    try expectCount(haystack, needle, 1, what);
    return std.mem.indexOf(u8, haystack, needle).?;
}

/// `fn <name>(` 부터 다음 `fn ` 앞까지. 주석은 이미 지워졌다.
fn fnBody(src: []const u8, comptime name: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, "fn " ++ name ++ "(") orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + 3, " fn ") orelse src.len;
    return src[at..end];
}

test "재접속 job 이 재시도 없이 끝나거나 다시 들어가는 모든 갈래가 그 자리에서 한 줄을 남긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, coordinator_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    // ① 논리 정산: 다시 넣는 갈래(retry_later·deadline_exceeded)는 **새 데드라인**을 싣고 대기를 건 뒤, 그 갈래
    //    안에서 다시 넣기 줄을 남긴다. 나머지(host_gone·cancelled)는 결속을 푼 **뒤 조건 없이** 끝 줄을 남긴다.
    //    2026-10-07: deadline_exceeded 가 종결이었고 다시 넣어도 처음 5 초 데드라인을 끌고 가, 잠자기 뒤 GUI 가
    //    앱 재시작까지 안 붙었다. 「deadline_exceeded 를 다시 빼기」·「데드라인 갱신 빼기」·「대기 빼기」가 여기서 잡힌다.
    const settle = try fnBody(src, "settleLogicalCompletion");
    // 시간 초과는 끝없이(timeout), retry_later 는 연속 상한까지(other) — 값은 `reconnect_retry_policy.zig` 가 잰다.
    const kinds = try expectOnce(
        settle,
        "const retry_kind: ?retry_policy.Failure = switch (outcome) { .deadline_exceeded => .timeout, .retry_later => .other, else => null, };",
        "deadline_exceeded 는 시간 초과로, retry_later 는 그 밖의 실패로 다시 넣는 갈래에 들어간다",
    );
    const retry_open = try expectOnce(
        settle,
        "if (retries) |retry_number| { try self.consumeLogicalCompletion();",
        "정책이 허락한 실패만 다시 넣는다",
    );
    if (kinds > retry_open) return error.WiringChanged;
    const fresh = try expectOnce(
        settle,
        "next.absolute_deadline_ns = retry.absolute_deadline_ns;",
        "다시 넣는 job 은 새 데드라인을 싣는다",
    );
    const deferred = try expectOnce(
        settle,
        "try self.jobs.deferQueued(key, next, retry.not_before_ns); self.noteRequeued(next, @tagName(outcome), retry.backoff_ns); return outcome; }",
        "다시 넣은 뒤 대기를 걸고 그 자리에서 다시 넣기 줄을 남긴다",
    );
    if (!(retry_open < fresh and fresh < deferred)) return error.WiringChanged;
    _ = try expectOnce(
        settle,
        "self.retry_streak.reset(snapshot.host_id); try backend.settleBoundReconnectSnapshot(completion.snapshot, budget); try self.consumeLogicalCompletion(); self.noteEnded(snapshot, @tagName(outcome)); return outcome; }",
        "재시도 없는 정산이 횟수를 비우고 결속을 푼 뒤 조건 없이 끝 줄을 남긴다",
    );
    try expectCount(settle, "self.noteEnded(", 1, "끝 줄은 정산 갈래 하나에만");
    try expectCount(settle, "self.noteRequeued(", 1, "다시 넣기 줄은 다시 넣는 갈래 하나에만");
    // 영구 실패는 host_gone 하나다 — 다시 넣는 조건에 끼면 사라진 host 를 30 초마다 영원히 두드린다.
    try expectCount(settle, ".host_gone", 0, "host_gone 은 다시 넣는 조건에 없다");

    // ①' 대기는 dispatch 가 지킨다 — 대기 없는 claim 이 남으면 다시 넣은 job 이 매 frame 나간다.
    const dispatch = try fnBody(src, "dispatchOne");
    _ = try expectOnce(dispatch, "self.jobs.claimReady(&self.job_receipt, self.nowNs())", "dispatch 가 대기를 지킨다");
    try expectCount(src, "self.jobs.claim(", 0, "대기를 무시하는 claim 은 coordinator 에 없다");

    // ② 연결 뒤 CR5 가 retained_terminal 로 끝나면 실패 줄, completed 면 칸만 비운다.
    const progress = try fnBody(src, "progressConnectedOne");
    _ = try expectOnce(
        progress,
        "if (terminal == .completed) _ = self.streaks.end(snapshot.host_id, snapshot.connection_generation, self.nowNs()) else self.noteEnded(snapshot, \"retained_terminal\");",
        "retained_terminal 이 실패 줄을 남긴다",
    );

    // ③ 물리 결과를 받는 순간 그 시도 기록을 잡는다 — connected 분기로 빠지기 **전**이어야 채택 실패 사유도 잇는다.
    const poll = try fnBody(src, "pollCompletion");
    const captured = try expectOnce(poll, "self.last_attempt = completion.attempt();", "물리 결과의 시도 기록을 잡는다");
    const connected = try expectOnce(poll, "if (outcome == .connected) return .connected_ready;", "connected 분기");
    if (captured > connected) return error.WiringChanged;

    // ④ 채택 실패는 다시 넣기 줄에 사유를 싣는다.
    const adopt = try fnBody(src, "settleConnectedCompletion");
    _ = try expectOnce(adopt, ".busy => .adopt_busy, .invalid_authority => .adopt_invalid_authority, else => .adopt_failed,", "채택 실패 사유");

    // ⑤ 새 job 입장에서 시도 횟수·경과의 기준을 잡는다.
    const admit = try fnBody(src, "admitOne");
    _ = try expectOnce(
        admit,
        ".started => { try admissions.consumeScheduled(projection); self.streaks.begin(snapshot.host_id, snapshot.connection_generation, self.nowNs()); return .admitted; },",
        "새 job 입장이 시도 기준을 잡는다",
    );

    // ⑥ 줄을 실제로 내는 곳: 끝 줄·다시 넣기 줄은 leaf 서식으로, (0,0) 전이는 drained 로.
    _ = try expectOnce(try fnBody(src, "noteEnded"), "logLine(.warn, failure_log.writeEnded,", "끝 줄 서식");
    const requeued = try fnBody(src, "noteRequeued");
    _ = try expectOnce(requeued, "const suppressed = self.requeue_rate.admit(now) orelse return;", "다시 넣기 줄 간격 상한");
    _ = try expectOnce(requeued, "logLine(.info, failure_log.writeRequeued,", "다시 넣기 줄 서식");
    const idle = try fnBody(src, "noteIdleTurn");
    _ = try expectOnce(idle, "switch (Last.tracker.note(admission_count, active_jobs)) {", "idle 전이 판정");
    _ = try expectOnce(idle, ".drained => logLine(.info, failure_log.writeDrained, .{ prev_admissions, prev_jobs }),", "(0,0) 전이 줄");
}

test "워커는 시도 결과마다 사유와 시작 시점 잔여 데드라인을 Completion 에 싣는다" {
    const a = std.testing.allocator;
    const raw = try read(a, issuer_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    const body = try fnBody(src, "executeIntoWith");
    // 연결 **전에** 잔여 데드라인을 잰다 — stale_deadline 가설의 증거다.
    const measured = try expectOnce(body, "const started: Note = .{ .deadline_remaining_ms = failure_log.deadlineRemainingMs(", "시작 시점 잔여 데드라인");
    const past = try expectOnce(
        body,
        "catch return finish(out, order, .deadline_exceeded, null, started.with(.deadline_past_before_connect, null));",
        "연결 전 데드라인 지남",
    );
    const connect = try expectOnce(body, "var connected = connector.connect(", "연결 시도");
    if (!(measured < past and past < connect)) return error.WiringChanged;
    _ = try expectOnce(body, ".failed => |reason| return finish( out, order, classifyFailure(reason), null, started.with(.connect_failed, reason), ),", "연결 실패 사유");
    _ = try expectOnce(body, "return finish(out, order, .retry_later, null, started.with(.candidate_rejected, null));", "후보 거절");

    // 기록은 봉인에 들어간다 — 정산 갈래가 읽는 사유가 워커가 남긴 그대로다.
    const seal = try fnBody(src, "completionSeal");
    _ = try expectOnce(seal, "hasher.update(std.mem.asBytes(&detail_raw));", "사유 봉인");
    _ = try expectOnce(seal, "hasher.update(std.mem.asBytes(&completion.deadline_remaining_ms));", "잔여 데드라인 봉인");
}
