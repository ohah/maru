//! 업그레이드 스캔(`host_connect.tryUpgradeExistingHost`)이 **결과를 보고** 다음 후보로 넘어갈지 가르는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-30 — 설치할 때마다 session host 가 하나씩 늘어 넷이 됐다. 스캔은 「prepare 를 한 번 보낸 뒤에는 결과와
//! 무관하게 끝낸다」였고, 9/27 빌드 host 는 매니페스트 ctime 결함으로 교체가 매번 `resumed/handoff_failed` 로
//! 끝나는데 readdir 순서상 늘 첫 후보였다. 그래서 9/28·9/29 빌드 host 는 **한 번도 시도받지 못했다.**
//!
//! 판정 자체(`upgrade_scan_policy.zig`)는 순수 테스트가 잰다. 그런데 스캔 루프는 readdir·소켓을 써서 PR 에서 못
//! 돌린다 — 그래서 루프가 그 판정을 **제자리에서** 부르는지를 여기서 글자로 잰다: 상한이 prepare 앞에 있고, 모든
//! 종료 갈래가 정산을 거치며, 루프 안에 판정을 우회하는 조기 반환이 없고, 넘긴 첫 실패가 알림으로 나간다.

const std = @import("std");

const connect_path = "src/platform/macos/session_host/host_connect.zig";

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

/// `fn <name>(` 부터 다음 최상위 `fn ` 앞까지. 주석은 이미 지워졌다.
fn fnBody(src: []const u8, comptime name: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, "fn " ++ name ++ "(") orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + 3, " fn ") orelse src.len;
    return src[at..end];
}

test "업그레이드 스캔은 공정 순서로 후보를 돌고, 결과를 판정에 넘기며, 상한은 prepare 앞에 있고, 넘긴 첫 실패가 알림으로 나간다" {
    const a = std.testing.allocator;
    const raw = try read(a, connect_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    const body = try fnBody(src, "tryUpgradeExistingHost");

    // ① 후보를 먼저 모으고 **공정 순서**로 정렬한 뒤 돈다. readdir 순서 그대로 돌면 교체 하나에서 멈추는 스캔이
    //    매 설치 같은 host 만 바꿔 수렴하지 않는다.
    const collect_at = try expectOnce(body, "candidates[candidate_count] = .{ .host_id = host_id, .published_ns = manifestPublishedNs(session_dir, host_id) };", "후보 수집");
    const order_at = try expectOnce(body, "upgrade_scan_policy.orderByPublication(candidates[0..candidate_count]);", "공정 정렬");
    const scan_at = try expectOnce(body, "var scan: UpgradeScan = .{ .started_ms = monotonicMsForMeasure() };", "스캔 상태");
    const loop_at = try expectOnce(body, "for (candidates[0..candidate_count], 0..) |candidate, candidate_index| { const host_id = candidate.host_id;", "정렬된 후보 순회");
    try std.testing.expect(collect_at < order_at and order_at < scan_at and scan_at < loop_at);
    // 시작 시각은 **한 번만** 잡는다 — 후보마다 다시 잡으면 경과 상한이 무력해진다.
    try expectCount(body, "started_ms", 1, "시작 시각 대입");
    try expectCount(body, "scan = ", 0, "스캔 상태 재대입");

    // ② 상한은 **연결·prepare 전에** 보고, 넘으면 그 사실을 한 줄 남긴 뒤 끝낸다.
    const gate_at = try expectOnce(body, "if (!scan.mayPrepareNow(monotonicMsForMeasure())) { if (!builtin.is_test) std.log.info(\"session host upgrade scan bound reached: tried={d} skipped={d} next_host={x:0>32}\", .{ scan.sent, candidate_count - candidate_index, host_id, }); break; }", "상한과 그 로그");
    const connect_at = try expectOnce(body, "connectExistingHost(allocator, base_cache_dir, host_id)", "후보 연결");
    const note_at = try expectOnce(body, "scan.notePrepared();", "prepare 셈");
    const prepare_at = try expectOnce(body, "client.prepareUpgrade(", "prepare");
    try std.testing.expect(loop_at < gate_at and gate_at < connect_at and connect_at < note_at and note_at < prepare_at);

    // ③ 모든 종료 갈래가 **자기 결과로** 정산한다. 갈래가 결과를 바꿔 넘기면(예: 재연결 실패를 거절로) 교체 중인
    //    host 를 두고 다음 host 를 흔든다. 재연결은 **보낸 그 attempt** 로 묻는다.
    try expectCount(body, "settleUpgrade(&scan, ", 5, "정산 갈래 수");
    _ = try expectOnce(body, "settleUpgrade(&scan, .prepare_transport_error, reconnected)", "transport 오류");
    _ = try expectOnce(body, "settleUpgrade(&scan, resolutionAfterReconnect(reconnected), reconnected)", "accepted 뒤 재연결");
    _ = try expectOnce(body, "settleUpgrade(&scan, .{ .completed = .committed }, reconnected)", "committed 재연결");
    _ = try expectOnce(body, "settleUpgrade(&scan, .{ .completed = report.status }, .{ .failed = notice })", "끝난 attempt");
    _ = try expectOnce(body, "settleUpgrade(&scan, rejectedResolution(code), .{ .failed = notice })", "typed 거절");
    try expectCount(body, "reconnectUpgradedHost(", 3, "재연결 호출");
    try expectCount(body, "reconnectUpgradedHost(allocator, base_cache_dir, host_id, target_build_id, attempt_id);", 3, "재연결 attempt 인자");
    try expectCount(body, ".attempt_id = attempt_id,", 1, "prepare attempt 인자");
    // 실패는 갈래마다 로그로 남는다(재연결 갈래는 `reconnectUpgradedHost` 가 남긴다).
    try expectCount(body, "logUpgradeNotice(notice);", 3, "실패 로그"); // completed·rejected + 루프 뒤 legacy

    // ④ 루프 안에는 판정을 우회해 스캔을 끝내는 조기 반환이 없다 — 예전 규칙(결과와 무관하게 끝냄)의 모양이다.
    //    capability 없는 host 는 알림 칸을 넘긴 실패에 내줘도 로그에는 남는다.
    const legacy_log_at = try expectOnce(body, "if (legacy_notice) |notice| logUpgradeNotice(notice);", "legacy 로그");
    const skipped_at = try expectOnce(body, "if (scan.skipped) |notice| return .{ .fallback = notice };", "넘긴 첫 실패 알림");
    const legacy_at = try expectOnce(body, "if (legacy_notice) |notice| return .{ .fallback = notice };", "legacy 알림");
    try std.testing.expect(loop_at < legacy_log_at and legacy_log_at < skipped_at and skipped_at < legacy_at);
    const loop_body = body[loop_at..legacy_log_at];
    try expectCount(loop_body, "return .{ .fallback", 0, "루프 안 조기 폴백");
    try expectCount(loop_body, "return switch (reconnectUpgradedHost", 0, "루프 안 재연결 조기 반환");

    // ⑤ 정산: 성공은 그 연결, 멈춤은 그 실패, 다음 후보면 null(첫 실패는 scan 이 기억).
    const settle = try fnBody(src, "settleUpgrade");
    _ = try expectOnce(settle, ".connected => |client| .{ .connected = client },", "정산 성공");
    _ = try expectOnce(settle, ".failed => |notice| switch (scan.settle(resolution, notice)) { .stop => .{ .fallback = notice }, .next_candidate => null, },", "정산 판정");

    // ⑥ accepted 뒤 재연결: host 가 보고한 status 만 쓰고, 상태를 못 확정하면 unresolved(멈춤).
    const resolve = try fnBody(src, "resolutionAfterReconnect");
    _ = try expectOnce(resolve, ".connected => .upgraded,", "재연결 성공");
    _ = try expectOnce(resolve, ".report => |report| .{ .reconnected_old_image = report.status },", "보고된 status");
    _ = try expectOnce(resolve, ".reconnect, .local => .unresolved,", "확정 못 함");

    // ⑦ typed 거절: `attempt_conflict`(다른 attempt 진행 중)만 멈춤 갈래로, 코드는 이름에 남긴다.
    const rejected = try fnBody(src, "rejectedResolution");
    _ = try expectOnce(rejected, ".upgrade_busy => .rejected_busy,", "busy");
    _ = try expectOnce(rejected, ".attempt_conflict => .rejected_conflict,", "conflict");
    _ = try expectOnce(rejected, "else => .rejected_other,", "그 밖");
}
