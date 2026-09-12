//! 연결을 **어느 줄이 닫았는지** 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-13, 터미널 브라우저를 띄우면 GUI 연결이 끊겨 세션 목록이 하나만 찼다. host 가 남긴 것은
//! 이 두 줄뿐이다.
//!
//! ```
//! closed client connection: ... why=peer_requested  why_ra=0x1049e05b4 pending_out=12
//! closed client connection: ... why=resource_exhausted why_ra=0x1049d1dbc
//! ```
//!
//! 사유로는 못 좁힌다 — `socket_error` 는 호출부가 **29 곳**, `resource_exhausted` 는 **18 곳**이다.
//! 그래서 주소를 역어셈블로 풀었는데, 그 자리의 명령이 넘기는 사유 값(`w1=1`, `socket_error`)이
//! 로그의 사유(`resource_exhausted`)와 **어긋났다.** 어디가 틀렸는지 못 가린 채 그 길이 막혔다.
//!
//! 같은 벽을 오늘 한 번 넘은 적이 있다. `attach not admitted` 가 여덟 자리를 한 사유로 뭉치던 것을
//! 자리 이름(#3577)과 오류 이름(#3603)으로 끝냈고, 한 번의 재현으로
//! `site=screen_batch_enqueue err=ScreenInvalidated` 가 나와 #3610 수정으로 이어졌다.
//!
//! **주소는 사람이 풀어야 하고 풀이가 틀릴 수 있다. 이름은 틀릴 수 없다.**

const std = @import("std");

const turn_path = "src/platform/macos/session_host/connection_turn.zig";
const owner_path = "src/platform/macos/session_host/poll_owner.zig";
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

test "닫힘은 사유와 함께 어느 줄이었는지 남긴다" {
    const a = std.testing.allocator;
    const turn_raw = try read(a, turn_path);
    defer a.free(turn_raw);
    const turn = try stripComments(a, turn_raw);
    defer a.free(turn);
    const owner_raw = try read(a, owner_path);
    defer a.free(owner_raw);
    const owner = try stripComments(a, owner_raw);
    defer a.free(owner);

    // ① 이름을 **먼저** 두고 닫는다. `beginClose` 는 첫 호출이 이기므로, 이름을 뒤에 두면 사유는
    //    첫 호출 것이고 이름은 나중 것이 되어 **짝이 어긋난다** — 그게 오늘 주소 풀이가 막힌 것과
    //    똑같은 종류의 거짓이다.
    const at_fn = std.mem.indexOf(u8, turn, "fn beginCloseAt(") orelse return error.NamedCloseMissing;
    const at_end = std.mem.indexOfPos(u8, turn, at_fn, "\n    }\n") orelse turn.len;
    const body = turn[at_fn..at_end];
    const guard = std.mem.indexOf(u8, body, "if (self.isClosing()) return;") orelse
        return error.FirstCallWinsGuardMissing;
    const name_at = std.mem.indexOf(u8, body, "self.close_site = site;") orelse
        return error.SiteNotStored;
    const state_at = std.mem.indexOf(u8, body, "self.state =") orelse return error.StateNotSet;
    try std.testing.expect(guard < name_at);
    try std.testing.expect(name_at < state_at);

    // ② **막혔던 두 경로에 빠짐없이 붙는다.** 하나라도 익명이면 다음 재현에서 또 「이 자리인가
    //    저 자리인가」로 돌아간다. 값이 아니라 **자리마다 서로 다른 이름**임을 고정한다.
    const sites = [_][]const u8{
        "\"invalidate_slot_lookup\"",
        "\"invalidate_purge_tracker\"",
        "\"invalidate_notice_build\"",
        "\"invalidate_notice_adopt\"",
        "\"tick_begin_dispatch\"",
        "\"tick_collect_oom\"",
        "\"tick_connection_self_closed\"",
    };
    for (sites) |site| {
        const n = countAll(turn, site);
        if (n != 1) {
            std.debug.print("자리 «{s}» 가 {d} 번 — 정확히 1 번이어야 갈린다\n", .{ site, n });
            return error.SiteNotUnique;
        }
    }

    // ③ `invalidateSubscriptionOutput` 안에 **이름 없는 닫기가 남지 않는다.** 넷 중 하나만 익명이어도
    //    그 경로는 다시 사유 둘로 뭉친다(2026-09-13 에 실제로 그랬다).
    const inv_at = std.mem.indexOf(u8, turn, "fn invalidateSubscriptionOutput(") orelse
        return error.InvalidateMissing;
    const inv_end = std.mem.indexOfPos(u8, turn, inv_at, "\n    }\n") orelse turn.len;
    const inv = turn[inv_at..inv_end];
    if (countAll(inv, "self.beginClose(") != 0) {
        std.debug.print("invalidateSubscriptionOutput 에 이름 없는 닫기가 남았다\n", .{});
        return error.AnonymousCloseInInvalidate;
    }
    try std.testing.expect(countAll(inv, "self.beginCloseAt(") == 4);

    // ④ **로그가 그 이름을 싣는다.** 저장만 하고 안 찍으면 사람에게는 없는 것과 같다.
    try std.testing.expect(std.mem.indexOf(u8, owner, "site={s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner, "client.closeSite()") != null);

    // ⑤ 사유·주소를 **대체하지 않고 더한다.** 이름이 틀릴 때 주소가 마지막 근거로 남아야 한다.
    try std.testing.expect(std.mem.indexOf(u8, owner, "why={s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner, "why_ra=0x{x}") != null);
}
