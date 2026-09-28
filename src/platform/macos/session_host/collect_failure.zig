//! `collectOutput` 이 **어디서, 무엇 때문에, 어떤 값으로** 접혔는지 — 닫기 직전 한 줄의 기록과 렌더.
//!
//! ## 왜 따로 있나
//!
//! `server.Connection.collectOutputForLocalStreamAtEpoch` 는 스물넷 넘는 실패를 `error.OutOfMemory`
//! 하나로 접는다(오류 집합을 넓히면 호출자 전수가 흔들린다). 그래서 곁다리 기록으로 «어느 자리였는지»
//! 를 남겨 왔다(#3634, `collect_failure_site_boundary`).
//!
//! 2026-09-28 에 그 이름이 `site=delta_seq_mismatch` 까지 데려왔는데 **거기서 멈췄다** — 숫자가
//! 없었다. 이 파일은 frontier 대조 자리의 양쪽 값을 함께 싣는다.
//!
//! 기록과 렌더가 `server.zig`·`connection_turn.zig` 안에 있으면 그 순수 테스트는 **PR 에서 안 도는**
//! session-host 잡에만 들어간다. 적대적 검증(2026-09-29)이 바로 그 틈으로 값을 뒤집는 돌연변이
//! 여럿을 통과시켰다. std 와 `host_log` 만 쓰는 leaf 로 두어 `check-boundaries` 에서 돌게 한다.

const std = @import("std");
const host_log = @import("host_log.zig");

/// frontier 대조가 어긋났을 때 **양쪽 값**.
///
/// - `expected_sequence` — 이 연결이 기대한 sequence(`delta`/`snapshot` 은 commit `+1`, 빈 delta 는
///   commit 그대로).
/// - `committed_generation` — 이 연결이 마지막으로 commit 한 generation. **스냅샷은 세대를 새로
///   정하므로** `is_snapshot` 이면 대조 대상이 아니다 — 그때 `gen` 이 달라도 정상이다.
/// - `actual_*` — producer(`RuntimeManager.deltaOp`/`snapshotOp`)가 낸 값.
pub const FrontierMismatch = struct {
    runtime_id: u128,
    expected_sequence: u64,
    actual_sequence: u64,
    committed_generation: u64,
    actual_generation: u64,
    is_snapshot: bool,
    send_bytes: usize,
};

pub const Record = struct {
    site: []const u8 = "-",
    err: []const u8 = "-",
    frontier: ?FrontierMismatch = null,
};

/// 닫기 직전에 읽는다 — 다음 실패가 덮어쓰기 전이다. 한 번의 `collectOutput` 과 그 뒤의
/// `noteCollectFailure` 는 같은 owner 턴에서 동기로 돈다.
var last_record: Record = .{};

/// `collectOutput` 진입에서 부른다. 헬퍼를 안 거치고 새는 경로가 있어도 **직전 실패의 이름과 숫자**
/// 를 물려주지 않는다 — 거짓 숫자는 없는 것보다 나쁘다.
pub fn reset() void {
    last_record = .{};
}

/// 자리 이름만. 매번 레코드를 **통째로** 갈아 끼운다 — 필드 하나만 바꾸면 직전 frontier 가 남는다.
pub fn fail(site: []const u8) void {
    last_record = .{ .site = site };
}

pub fn failErr(site: []const u8, err_name: []const u8) void {
    last_record = .{ .site = site, .err = err_name };
}

pub fn failFrontier(site: []const u8, mismatch: FrontierMismatch) void {
    last_record = .{ .site = site, .frontier = mismatch };
}

pub fn last() Record {
    return last_record;
}

/// `host_log.line` 은 개행까지 `host_log.max_line_bytes` 에 못 들면 **줄을 통째로 버린다.** 렌더가
/// 이 길이 안에서 끝나야 「숫자가 넘쳐 이름까지 사라지는」 일이 없다.
pub const line_capacity = host_log.max_line_bytes - 1;

const head_overflow = "session host collect failed: site=(too long)";

/// 한 줄로 그린다. **실패하지 않는다** — 숫자가 안 들어가면 이름만, 이름도 안 들어가면 그렇다고 적는다.
///
/// 방향은 «기대 -> 실제» 다. 형제 진단(`budget mismatch … bytes=예약->실제`)과 같아야 두 줄을 나란히
/// 읽는 사람이 헷갈리지 않는다 — 뒤집혀도 컴파일되고, 뒤집힌 줄은 원인을 정반대로 가리킨다.
pub fn render(buf: *[line_capacity]u8, record: Record) []const u8 {
    const head = std.fmt.bufPrint(
        buf,
        "session host collect failed: site={s} err={s}",
        .{ record.site, record.err },
    ) catch return head_overflow;
    const m = record.frontier orelse return head;
    const tail = std.fmt.bufPrint(
        buf[head.len..],
        " runtime={x:0>32} seq={d}->{d} gen={d}->{d} snapshot={d} send={d}",
        .{
            m.runtime_id,
            m.expected_sequence,
            m.actual_sequence,
            m.committed_generation,
            m.actual_generation,
            @intFromBool(m.is_snapshot),
            m.send_bytes,
        },
    ) catch return head;
    return buf[0 .. head.len + tail.len];
}

const sample: FrontierMismatch = .{
    .runtime_id = 0x0935886dc61898048f9fd1e194dee150,
    .expected_sequence = 41,
    .actual_sequence = 42,
    .committed_generation = 7,
    .actual_generation = 8,
    .is_snapshot = false,
    .send_bytes = 512,
};

test "frontier 불일치 줄은 양쪽 값을 «기대 -> 실제» 방향으로 싣는다" {
    // 값마다 **서로 다른 수**를 쓴다 — 같은 수면 두 인자를 바꿔 넣어도 같은 줄이 나온다.
    var buf: [line_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(
        "session host collect failed: site=delta_seq_mismatch err=- " ++
            "runtime=0935886dc61898048f9fd1e194dee150 seq=41->42 gen=7->8 snapshot=0 send=512",
        render(&buf, .{ .site = "delta_seq_mismatch", .frontier = sample }),
    );
    var snap = sample;
    snap.is_snapshot = true;
    try std.testing.expect(std.mem.endsWith(u8, render(&buf, .{ .site = "x", .frontier = snap }), " snapshot=1 send=512"));
    // `runtime=` 은 `maru runtime list` 와 같은 32 자리 — 앞자리 0 을 버리면 grep 이 안 맞는다.
    var small = sample;
    small.runtime_id = 0xab;
    try std.testing.expect(std.mem.indexOf(
        u8,
        render(&buf, .{ .site = "x", .frontier = small }),
        " runtime=000000000000000000000000000000ab ",
    ) != null);
}

test "frontier 가 없는 자리는 예전 줄 그대로다" {
    var buf: [line_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(
        "session host collect failed: site=delta err=ProjectionTooLarge",
        render(&buf, .{ .site = "delta", .err = "ProjectionTooLarge" }),
    );
}

test "가장 긴 값도 host_log 한 줄에 들고, 넘치면 숫자를 버려도 이름은 남긴다" {
    var buf: [line_capacity]u8 = undefined;
    // 실제 자리 중 가장 긴 이름 + 모든 값이 최대.
    const widest = render(&buf, .{ .site = "delta_frontier_mismatch", .frontier = .{
        .runtime_id = std.math.maxInt(u128),
        .expected_sequence = std.math.maxInt(u64),
        .actual_sequence = std.math.maxInt(u64),
        .committed_generation = std.math.maxInt(u64),
        .actual_generation = std.math.maxInt(u64),
        .is_snapshot = true,
        .send_bytes = std.math.maxInt(usize),
    } });
    // 숫자로 끝난다 = 이름만 남기는 갈래로 떨어지지 않았다.
    try std.testing.expect(std.mem.endsWith(u8, widest, " snapshot=1 send=18446744073709551615"));
    try std.testing.expect(widest.len + 1 <= host_log.max_line_bytes);

    // **상한 자체를 잰다.** 가장 긴 실제 줄(235 B)만 재면 상한을 256 이나 300 으로 올려도 초록이다
    // (적대적 검증 2회차 L09·L10). 렌더가 딱 `line_capacity` 를 채우는 줄을 만들어, 그것이
    // `host_log` 가 **실제로 쓰는 모양**(`formatLine`)을 통과하는지 본다. 1 B 더 길면 숫자를 버린다.
    const prefix = "session host collect failed: site=";
    const tail = " err=- runtime=0935886dc61898048f9fd1e194dee150 seq=41->42 gen=7->8 snapshot=0 send=512";
    const exact_site = "s" ** (line_capacity - prefix.len - tail.len);
    const exact = render(&buf, .{ .site = exact_site, .frontier = sample });
    try std.testing.expectEqualStrings(prefix ++ exact_site ++ tail, exact);
    var log_buf: [host_log.max_line_bytes]u8 = undefined;
    try std.testing.expect(host_log.formatLine(&log_buf, "{s}", .{exact}) != null);
    const over = render(&buf, .{ .site = exact_site ++ "s", .frontier = sample });
    try std.testing.expectEqualStrings(prefix ++ exact_site ++ "s err=-", over);

    // 숫자가 안 들어갈 만큼 이름이 길면 **이름만** — 줄 전체를 잃지 않는다.
    const long_site = "s" ** 200;
    const clipped = render(&buf, .{ .site = long_site, .frontier = sample });
    try std.testing.expectEqualStrings("session host collect failed: site=" ++ long_site ++ " err=-", clipped);
    // 이름조차 안 들어가면 그렇다고 말한다.
    try std.testing.expectEqualStrings(head_overflow, render(&buf, .{ .site = "s" ** 300 }));
}

test "기록은 매번 통째로 갈아 끼워 남의 이름·숫자를 물려주지 않는다" {
    defer reset();
    failFrontier("delta_seq_mismatch", sample);
    try std.testing.expectEqualStrings("delta_seq_mismatch", last().site);
    try std.testing.expectEqualStrings("-", last().err);
    try std.testing.expectEqual(sample, last().frontier.?);

    // 이름만 남기는 실패가 뒤따르면 직전 숫자가 **사라진다**.
    fail("delta");
    try std.testing.expectEqualStrings("delta", last().site);
    try std.testing.expect(last().frontier == null);

    failFrontier("snapshot_seq_mismatch", sample);
    failErr("delta_chunks", "OutOfMemory");
    try std.testing.expectEqualStrings("delta_chunks", last().site);
    try std.testing.expectEqualStrings("OutOfMemory", last().err);
    try std.testing.expect(last().frontier == null);

    // 오류 이름이 남은 뒤 frontier 실패가 와도 그 이름을 물려받지 않는다.
    failFrontier("delta_frontier_mismatch", sample);
    try std.testing.expectEqualStrings("-", last().err);

    reset();
    try std.testing.expectEqualStrings("-", last().site);
    try std.testing.expectEqualStrings("-", last().err);
    try std.testing.expect(last().frontier == null);
}
