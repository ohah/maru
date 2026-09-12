//! 재동기화 sweep 이 **무엇에 막혔는지** 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-13 실측 — ssh 가 끊긴 뒤 터미널에 입력이 안 먹었는데, **pane 을 하나 만들자 나머지가
//! 전부 복구됐다.** 데이터가 사라진 게 아니라 `beginProducerSweep` 이 멈춰 있다가 `localStreams`
//! 가 바뀌며 다시 돌았다는 뜻이다.
//!
//! 그런데 그 sweep 의 후보 선택은 **여섯 갈래가 전부 조용히 빠진다** — 트래커 없음, 상태 조회 실패,
//! 무효화 아님, 재동기화 미요청, 시도 불가, 백오프. 하나도 안 남으므로 「고를 것이 없었다」와
//! 「있었는데 다 막혔다」가 로그에서 **똑같아 보인다.**
//!
//! 오늘 이 저장소에서 같은 모양을 세 번 풀었다(`attach not admitted` 여덟 자리 → #3577·#3603 →
//! #3610, 닫힘 자리 29·18 곳 → #3634). 셋 다 **이름을 붙이자 한 번의 재현으로 끝났다.**

const std = @import("std");

const source_path = "src/platform/macos/session_host/connection_turn.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const keep = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, keep);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "막힌 sweep 은 여섯 갈래를 따로 세어 남긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    const sweep_at = std.mem.indexOf(u8, src, "pub fn beginProducerSweep(") orelse
        return error.SweepMissing;
    const sweep_end = std.mem.indexOfPos(u8, src, sweep_at, "\n    pub fn takeArmedUpgrade(") orelse src.len;
    const sweep = src[sweep_at..sweep_end];

    // ① **여섯이 저마다 다른 이름으로 세어진다.** 총합 하나로 접으면 고칠 곳이 정반대인 것들이
    //    다시 뭉친다 — 백오프는 기다리면 풀리고, 미요청은 클라이언트가 안 물은 것이고, 시도 불가는
    //    예산 문제다.
    //    **«센다»를 이름의 등장이 아니라 «증가»로 잰다.** 선언하고 로그에만 싣고 정작 한 번도
    //    안 올리면, 그 갈래는 영원히 0 으로 나가 「그 이유가 아니다」로 읽힌다 — 없는 것보다 나쁘다
    //    (적대적 검증에서 두 갈래를 한 카운터로 합치는 돌연변이가 이 단언을 그냥 통과했다).
    for ([_][]const u8{
        "blocked_no_tracker",
        "blocked_state_stale",
        "blocked_not_pending",
        "blocked_cannot_attempt",
        "blocked_backoff",
        "invalidated_seen",
    }) |name| {
        var buf: [64]u8 = undefined;
        const bump = std.fmt.bufPrint(&buf, "{s} += 1", .{name}) catch return error.NameTooLong;
        var seen: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, sweep, at, bump)) |f| : (at = f + bump.len) seen += 1;
        if (seen != 1) {
            std.debug.print("갈래 «{s}» 의 증가가 {d} 번 — 정확히 1 번이어야 갈린다\n", .{ name, seen });
            return error.BranchNotCounted;
        }
    }

    // ② **막혔을 때만 낸다.** sweep 은 틱마다 도므로 늘 찍으면 로그를 통째로 먹는다(#3605 가 없앤 것).
    //    조건은 「아무도 못 뽑혔고 무효화된 것이 있었다」 — 그 둘이 함께 걸려야 한다.
    const call_at = std.mem.indexOf(u8, sweep, "noteResyncSweepBlocked(") orelse
        return error.BlockNoticeMissing;
    const guard_from = if (call_at > 200) call_at - 200 else 0;
    const guard = sweep[guard_from..call_at];
    try std.testing.expect(std.mem.indexOf(u8, guard, "!chose") != null);
    try std.testing.expect(std.mem.indexOf(u8, guard, "invalidated_seen != 0") != null);

    // ③ **고른 경우는 그대로 고른다.** 계측이 선택 동작을 바꾸면 진단이 증상을 만든다.
    try std.testing.expect(std.mem.indexOf(u8, sweep, "self.producer_sweep_cursor = index;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sweep, "chose = true;") != null);

    // ④ **같은 분포가 이어지면 반복하지 않는다.** 멈춘 상태는 틱마다 같은 값을 내므로 그대로 두면
    //    초당 수십 줄이 된다 — 오늘 로그의 92 % 가 내 진단이었던 일을 되풀이하지 않는다.
    const fn_at = std.mem.indexOf(u8, src, "fn noteResyncSweepBlocked(") orelse
        return error.NoticeFnMissing;
    const fn_end = std.mem.indexOfPos(u8, src, fn_at, "\n}\n") orelse src.len;
    const body = src[fn_at..fn_end];
    try std.testing.expect(std.mem.indexOf(u8, body, "std.meta.eql(prev, now)") != null);

    // ⑤ 한 줄에 **여섯이 함께** 나온다. 축이 흩어지면 어느 순간의 분포인지 사람이 다시 맞춰야 한다.
    for ([_][]const u8{ "no_tracker={d}", "state_stale={d}", "not_pending={d}", "cannot_attempt={d}", "backoff={d}", "invalidated={d}" }) |axis| {
        if (std.mem.indexOf(u8, body, axis) == null) {
            std.debug.print("축 «{s}» 이 로그에 없다\n", .{axis});
            return error.AxisMissingFromLine;
        }
    }
}
