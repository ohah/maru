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
const server_path = "src/platform/macos/session_host/server.zig";
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
    //
    //    **이름을 «저장하는» 함수를 찾아서 잰다.** 함수 이름을 잠그면 위임 구조로 바뀔 때 의도가
    //    지켜지는데도 빨개진다 — 실제로 그랬다(2026-09-14: `beginCloseAt` 이 오류까지 싣는
    //    `beginCloseAtErr` 로 위임하자 가드가 그쪽으로 옮겨갔다). 의도는 「이름을 저장하는 곳이
    //    첫-호출 가드 뒤에 있고 상태 변경보다 앞」이다.
    const store = "self.close_site = site;";
    const store_at = std.mem.indexOf(u8, turn, store) orelse return error.SiteNotStored;
    const at_fn = std.mem.lastIndexOf(u8, turn[0..store_at], "noinline fn ") orelse
        return error.NamedCloseMissing;
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
    //    **변형을 포함해 센다.** `beginCloseAt(` 만 세면 오류까지 싣는 `beginCloseAtErr(` 로 바꿀 때
    //    의도가 지켜지는데도 0 으로 세어 빨개진다(2026-09-14 에 실제로 그랬다). 의도는 「넷 다
    //    이름을 남긴다」이지 특정 함수 이름이 아니다.
    try std.testing.expect(countAll(inv, "self.beginCloseAt") == 4);

    // ④ **로그가 그 이름을 싣는다.** 저장만 하고 안 찍으면 사람에게는 없는 것과 같다.
    try std.testing.expect(std.mem.indexOf(u8, owner, "site={s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner, "client.closeSite()") != null);

    // ⑤ 사유·주소를 **대체하지 않고 더한다.** 이름이 틀릴 때 주소가 마지막 근거로 남아야 한다.
    try std.testing.expect(std.mem.indexOf(u8, owner, "why={s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner, "why_ra=0x{x}") != null);
}

test "server close 사유는 peer 요청으로 거짓 변환되지 않는다" {
    const a = std.testing.allocator;
    const turn_raw = try read(a, turn_path);
    defer a.free(turn_raw);
    const turn = try stripComments(a, turn_raw);
    defer a.free(turn);
    const server_raw = try read(a, server_path);
    defer a.free(server_raw);
    const server = try stripComments(a, server_raw);
    defer a.free(server);

    // 원래 막으려던 거짓: host 상태기가 스스로 내린 닫기를 「peer 가 끊었다」로 바꿔 적는 것.
    try std.testing.expect(std.mem.indexOf(u8, turn, ".close => self.beginClose(.peer_requested)") == null);
    try std.testing.expect(std.mem.indexOf(u8, server, "pub const CloseReason = enum") != null);

    // **철자가 아니라 의도로 잰다.** 앞 판은 `.close => |reason|` 과 `close: CloseReason` 을 글자로
    // 잠갔는데, 그 둘은 「사유가 건너간다」의 한 가지 표기일 뿐이다. 2026-09-14 에 payload 를
    // 사유 하나에서 `{reason, site, err}` 로 넓히자 **의도가 더 지켜지는데도** 이 게이트가
    // 빨개졌다. 재는 것은 「dispatch 가 payload 를 풀어 그 사유를 그대로 옮긴다」이다.
    const prong = std.mem.indexOf(u8, turn, ".close => |") orelse return error.ClosePayloadNotBound;
    const bind_at = prong + ".close => |".len;
    const bind_end = std.mem.indexOfScalarPos(u8, turn, bind_at, '|') orelse
        return error.ClosePayloadNotBound;
    const bind = turn[bind_at..bind_end];
    const tail = turn[bind_end..@min(turn.len, bind_end + 512)];

    // ① 옮기는 쪽이 사유를 **새로 짓지 않는다** — 바인딩한 payload 의 사유를 switch 한다.
    const subject = try std.fmt.allocPrint(a, "switch ({s}.reason)", .{bind});
    defer a.free(subject);
    if (std.mem.indexOf(u8, tail, subject) == null) {
        std.debug.print("dispatch 가 «{s}.reason» 을 옮기지 않는다\n", .{bind});
        return error.CloseReasonNotForwarded;
    }

    // ② **자리 이름과 원인 오류도 같이 옮긴다.** 사유만 옮기면 `site=-` 로 돌아간다 —
    //    2026-09-14 의 실패가 정확히 그것이었다(자리 이름은 `server.zig` 에서 지어졌는데
    //    이 줄이 사유만 들고 와 `beginClose` 를 불렀다).
    const forward = try std.fmt.allocPrint(a, "{s}.site, {s}.err", .{ bind, bind });
    defer a.free(forward);
    if (std.mem.indexOf(u8, tail, forward) == null) return error.CloseSiteNotForwarded;
}

test "server 의 모든 닫기는 서로 다른 이름을 달고 나간다" {
    const a = std.testing.allocator;
    const server_raw = try read(a, server_path);
    defer a.free(server_raw);
    const server = try stripComments(a, server_raw);
    defer a.free(server);

    // ① **이름에 기본값을 주지 않는다.** 이것이 닫힌 세계를 여는 유일한 구멍이다 — `site` 에
    //    `= "-"` 가 붙는 순간 새로 생기는 닫기가 컴파일러에 걸리지 않고 조용히 익명으로 돌아간다.
    //    컴파일러가 못 잡는 종류라 게이트가 대신 잡는다.
    const decl = std.mem.indexOf(u8, server, "pub const Close = struct") orelse
        return error.CloseStructMissing;
    const decl_end = std.mem.indexOfPos(u8, server, decl, "\n};\n") orelse server.len;
    const decl_body = server[decl..decl_end];
    //    **필드 줄에서 잰다.** 그냥 `"site: []const u8,"` 을 찾으면 `at(site: []const u8, reason: ...)`
    //    의 파라미터 목록이 대신 잡혀 기본값이 붙어도 초록이 된다 — 이 판정자를 돌연변이로
    //    검증하다 실제로 그랬다(2026-09-14). 필드는 들여쓰기 네 칸으로 «혼자» 선언된 줄이다.
    var field_line: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, decl_body, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "    site:")) continue;
        field_line = line;
        break;
    }
    const field = field_line orelse return error.SiteFieldMissing;
    if (std.mem.indexOfScalar(u8, field, '=') != null) {
        std.debug.print("Close.site 에 기본값이 붙었다 — 다음 닫기가 조용히 익명이 된다: «{s}»\n", .{field});
        return error.SiteFieldMustHaveNoDefault;
    }

    // ② **자리마다 이름이 다르다.** 둘이 같은 이름을 쓰면 그 둘은 로그에서 다시 한 값으로
    //    뭉치고, 사유 하나로 뭉치던 것과 똑같은 벽이 이름 층에 다시 생긴다.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, server, at, ".close = .at")) |f| {
        const open = std.mem.indexOfScalarPos(u8, server, f, '"') orelse return error.SiteNotLiteral;
        const close = std.mem.indexOfScalarPos(u8, server, open + 1, '"') orelse
            return error.SiteNotLiteral;
        try names.append(a, server[open + 1 .. close]);
        at = close;
    }
    if (names.items.len == 0) return error.NoNamedCloses;
    for (names.items, 0..) |name, i| {
        if (name.len == 0) return error.EmptySiteName;
        for (names.items[i + 1 ..]) |other| {
            if (std.mem.eql(u8, name, other)) {
                std.debug.print("자리 이름 «{s}» 이 두 자리에 쓰였다\n", .{name});
                return error.SiteNameNotUnique;
            }
        }
    }
}
