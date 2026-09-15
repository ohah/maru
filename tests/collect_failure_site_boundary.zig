//! `collectOutput` 이 **어느 자리에서** 접혔는지 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-13 실측 — 터미널 브라우저를 **세션 호스트에서** 띄우면 화면이 안 뜨고 GUI 연결이 끊겼다.
//! 인프로세스에서는 (프레임 드랍은 있어도) 잘 뜬다. 즉 브라우저도 터미널 코어도 아니고, 화면이
//! 직렬화되어 예산을 거쳐 전달되는 **호스트 경로**가 범인이다.
//!
//! 자리 이름(#3634)이 여기까지 데려왔다.
//!
//! ```
//! closed client connection: why=resource_exhausted site=tick_collect_oom
//! ```
//!
//! **그런데 그 안에서 스물넷이 다시 `OutOfMemory` 하나로 접힌다.** 그중 진짜 할당 실패는 일부이고
//! 나머지는 원격 runtime ops 가 낸 서로 다른 오류를 `else =>` 로 뭉갠 것이다 — 그래서
//! `resource_exhausted` 가 「메모리가 모자랐다」는 뜻이 **아닐 수 있다.**
//!
//! 오늘 같은 모양을 세 번 풀었다: attach 자리 여덟(#3577) → 오류 이름 다섯(#3603) → 닫힘 자리
//! 29·18 곳(#3634). 매번 이름을 붙이자 **한 번의 재현으로 끝났다.**

const std = @import("std");

const server_path = "src/platform/macos/session_host/server.zig";
const turn_path = "src/platform/macos/session_host/connection_turn.zig";
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

fn countAll(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |f| : (at = f + needle.len) n += 1;
    return n;
}

test "collectOutput 이 접히면 어느 자리였는지와 원래 오류를 남긴다" {
    const a = std.testing.allocator;
    const server_raw = try read(a, server_path);
    defer a.free(server_raw);
    const server = try stripComments(a, server_raw);
    defer a.free(server);
    const turn_raw = try read(a, turn_path);
    defer a.free(turn_raw);
    const turn = try stripComments(a, turn_raw);
    defer a.free(turn);

    const fn_at = std.mem.indexOf(u8, server, "pub fn collectOutputForLocalStreamAtEpoch(") orelse
        return error.CollectMissing;
    const fn_end = std.mem.indexOfPos(u8, server, fn_at, "\n    pub fn ") orelse server.len;
    const body = server[fn_at..fn_end];

    // ① **이름 없는 접힘이 남지 않는다.** 하나만 익명이어도 그 자리는 다시 스물넷과 뭉친다 —
    //    그리고 하필 그 하나가 범인일 때 진단이 통째로 무의미해진다.
    const bare = countAll(body, "error.OutOfMemory;");
    if (bare != 0) {
        std.debug.print("이름 없는 접힘이 {d} 곳 남았다\n", .{bare});
        return error.AnonymousCollapseRemains;
    }

    // ② **접히는 자리마다 헬퍼를 거친다.** 자리 수는 구현이 바뀌면 달라지므로 값이 아니라
    //    「전부 거친다」를 잰다.
    const via = countAll(body, "collectFail(") + countAll(body, "collectFailErr(");
    if (via < 20) {
        std.debug.print("헬퍼를 거치는 자리가 {d} 곳뿐이다 — 스물넷이 접히던 자리다\n", .{via});
        return error.TooFewLabelled;
    }

    // ③ **이름이 조건과 어긋나지 않는다.** 첫 판은 「이름이 붙었는가」만 봤고, 그래서 크기 상한을
    //    지키는 자리에 `snapshot_frame`(인코딩 실패처럼 읽힌다) 같은 **거짓 이름**이 붙어도 통과했다.
    //    거짓 이름은 없는 것보다 나쁘다 — 다음 조사를 통째로 엉뚱한 데로 보낸다.
    //
    //    값이 아니라 **짝**을 고정한다: 크기 상한(`max_viewport_snapshot`)을 지키는 자리는
    //    `oversize` 로, frontier/sequence 를 지키는 자리는 `mismatch` 로 끝난다.
    {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, body, at, "protocol.max_viewport_snapshot")) |guard| : (at = guard + 1) {
            const tail = body[guard..@min(guard + 260, body.len)];
            const call = std.mem.indexOf(u8, tail, "collectFail(\"") orelse continue;
            const name_start = call + "collectFail(\"".len;
            const name_end = std.mem.indexOfPos(u8, tail, name_start, "\"") orelse continue;
            const name = tail[name_start..name_end];
            if (std.mem.indexOf(u8, name, "oversize") == null) {
                std.debug.print("크기 상한을 지키는 자리에 «{s}» — 이름이 조건과 어긋난다\n", .{name});
                return error.LabelContradictsGuard;
            }
        }
    }
    // 크기와 시퀀스가 **한 이름에 뭉치지 않는다.** 둘은 고칠 곳이 정반대다.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"snapshot_oversize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"snapshot_seq_mismatch\"") != null);

    // ④ **원래 오류가 있는 자리는 그것을 싣는다.** 이름만 남기고 오류를 버리면 「ops 가 무엇을
    //    냈는가」가 사라져, 진짜 할당 실패와 원격 오류가 다시 같아 보인다.
    const err_fn_at = std.mem.indexOf(u8, server, "fn collectFailErr(") orelse
        return error.ErrAccessorMissing;
    const err_fn_end = std.mem.indexOfPos(u8, server, err_fn_at, "\n}\n") orelse server.len;
    try std.testing.expect(
        std.mem.indexOf(u8, server[err_fn_at..err_fn_end], "@errorName(err)") != null,
    );

    // ⑤ **헬퍼를 안 거치고 새는 길이 없다.** `try` 로 빠져나가면 `collect_fail_site` 는 «직전
    //    실패의 이름» 을 그대로 들고 있어 로그가 거짓말을 한다 — 적대적 검증에서 `appendChunks`
    //    (큰 이미지가 실제로 지나가는 경로)가 정확히 그랬다.
    {
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, t, "try ") or std.mem.indexOf(u8, t, " try self.") != null) {
                std.debug.print("헬퍼를 안 거치는 길이 남았다: {s}\n", .{t});
                return error.UnnamedLeakPath;
            }
        }
    }

    // ⑥ **진입에서 이름을 지운다.** 그래도 새는 길이 생기면 «-» 로 나가야 한다 — 모르는 것을
    //    모른다고 말하는 편이, 직전 이름을 물려주는 것보다 언제나 낫다.
    const reset_at = std.mem.indexOf(u8, body, "collect_fail_site = \"-\";") orelse
        return error.EntryResetMissing;
    const first_fail = std.mem.indexOf(u8, body, "collectFail") orelse return error.NoFailSites;
    try std.testing.expect(reset_at < first_fail);

    // ⑦ **오류 집합을 넓히지 않는다.** 넓히면 호출자 전수가 흔들린다 — 지금 필요한 것은
    //    「무엇이 접혔는지」뿐이고, 그것은 곁다리 기록으로 충분하다.
    try std.testing.expect(
        std.mem.indexOf(u8, server[err_fn_at..err_fn_end], "error{OutOfMemory}") != null,
    );

    // ⑧ **닫기 «전» 에 남긴다.** 뒤에 두면 닫힘 경로가 먼저 돌아 그 줄이 영영 안 나간다
    //    (#3634 가 같은 이유로 이름을 사유보다 먼저 저장한다).
    const note_at = std.mem.indexOf(u8, turn, "noteCollectFailure();") orelse
        return error.NoticeMissing;
    const close_at = std.mem.indexOfPos(u8, turn, note_at, "beginCloseAt(\"tick_collect_oom\"") orelse
        return error.CloseSiteMissing;
    try std.testing.expect(note_at < close_at);

    // ⑨ 한 줄에 **자리와 오류가 함께** 나온다.
    const log_at = std.mem.indexOf(u8, turn, "fn noteCollectFailure(") orelse
        return error.NoticeFnMissing;
    const log_end = std.mem.indexOfPos(u8, turn, log_at, "\n}\n") orelse turn.len;
    const log = turn[log_at..log_end];
    try std.testing.expect(std.mem.indexOf(u8, log, "site={s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "err={s}") != null);
}

// `tick` 안의 `partial_timeout` 이 **익명으로 닫지 않는다.**
//
// ## 무엇이 있었나
//
// 2026-09-15 실측 — host 로그 88 개에 `why=partial_timeout` 이 **126 번** 있었다. 전부 `site=-` 라
// 넷 중 무엇인지 알 수 없었고, `why_ra` 로도 못 갈랐다: 최적화가 네 자리를 뭉개 줄번호가 `defer`
// (745) 와 `producer_sweep_cursor %` (775) 를 가리켰다. 그래서 그 126 은 **사고인지 정상 회수인지조차**
// 말하지 못했다 — 넷 중 `unattached_idle` 하나는 구독 0 인 연결을 거두는 **정상**이다.
//
// 순수 판정자는 네 갈래를 직접 몰아넣어 이름을 확인한다. 그런데 **다섯째 자리가 익명으로 새로
// 생기는 것**은 못 본다 — 그것은 이 축에서 센다. 이름 없는 자리가 하나만 남아도 그날의 로그는
// 다시 「126 번, 무엇인지 모름」이 된다.
test "tick 의 partial_timeout 은 자리 이름 없이 닫지 않는다" {
    const a = std.testing.allocator;
    const turn_raw = try read(a, turn_path);
    defer a.free(turn_raw);
    const turn = try stripComments(a, turn_raw);
    defer a.free(turn);

    const fn_at = std.mem.indexOf(u8, turn, "pub fn tick(self: *Client, now_ns: u64) void {") orelse
        return error.TickMissing;
    const fn_end = std.mem.indexOfPos(u8, turn, fn_at, "\n    pub fn ") orelse turn.len;
    const body = turn[fn_at..fn_end];

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, ".partial_timeout") == null) continue;
        // ① **익명으로 닫는 길이 없다.** `beginClose`/`failPendingUpgrade` 는 이름을 안 싣는다.
        const call_at = std.mem.indexOf(u8, line, "At(\"") orelse {
            std.debug.print("이름 없이 닫는 자리가 남았다: {s}\n", .{std.mem.trim(u8, line, " \t")});
            return error.AnonymousPartialTimeout;
        };
        const name_start = call_at + "At(\"".len;
        const name_end = std.mem.indexOfPos(u8, line, name_start, "\"") orelse
            return error.MalformedSite;
        try names.append(a, line[name_start..name_end]);
    }

    // ② **자리가 넷 이상 남아 있다.** 하나로 합치면 그 로그는 다시 못 읽는 숫자가 된다.
    if (names.items.len < 4) {
        std.debug.print("이름 붙은 자리가 {d} 곳뿐이다 — 넷이 갈리던 자리다\n", .{names.items.len});
        return error.TooFewPartialTimeoutSites;
    }

    // ③ **이름이 서로 다르다.** 같은 이름 둘은 안 붙인 것과 같다.
    for (names.items, 0..) |lhs, i| {
        for (names.items[i + 1 ..]) |rhs| {
            if (std.mem.eql(u8, lhs, rhs)) {
                std.debug.print("같은 이름이 두 자리에 있다: «{s}»\n", .{lhs});
                return error.DuplicateSiteName;
            }
        }
    }

    // ④ **정상 회수가 제 이름을 갖는다.** 넷 중 이것만 사고가 아니다 — 이 이름이 사라지면
    //    「사고가 126 번」으로 읽히는 그 오독이 그대로 돌아온다.
    {
        var found = false;
        for (names.items) |name| {
            if (std.mem.indexOf(u8, name, "unattached_idle") != null) found = true;
        }
        if (!found) return error.IdleReclaimUnnamed;
    }

    // ⑤ **읽기 정체와 쓰기 정체가 한 이름에 뭉치지 않는다.** write 정체는 client 가 안 빼간다
    //    (배압)이고 read 정체는 client 가 안 보낸다 — 의심할 쪽이 정반대다.
    {
        var read_seen = false;
        var write_seen = false;
        for (names.items) |name| {
            if (std.mem.indexOf(u8, name, "partial_read") != null) read_seen = true;
            if (std.mem.indexOf(u8, name, "partial_write") != null) write_seen = true;
        }
        if (!read_seen or !write_seen) return error.StallDirectionsMerged;
    }
}
