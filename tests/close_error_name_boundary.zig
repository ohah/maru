//! 연결을 닫은 자리가 **그 자리를 만든 오류**까지 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-13: 터미널 브라우저를 여는 순간 연결이 죽어 **세션 23 개가 한꺼번에 detach** 됐다.
//! 로그는 이렇게 말했다.
//!
//! ```
//! session host closed client connection: reason=client_closing why=socket_error site=invalidate_purge_tracker
//! ```
//!
//! 자리 이름은 있었다(그건 #3634 가 만들었다). 그런데 **무엇이 그 자리를 만들었는지**가 없었다.
//! `invalidateAndPurgeScreenTracker` 는 `error{ Stale, PartialFrame }` 둘로 실패하는데 호출부의
//! `catch` 가 `|err|` 없이 오류를 버렸다.
//!
//! **고칠 곳이 정반대다.**
//!
//! - `Stale` — 트래커 신원이 어긋났다(슬롯 재사용). 소유 판정을 봐야 한다.
//! - `PartialFrame` — 소켓에 **절반 쓰인 청크**가 있어 지금은 버릴 수 없다. 「지금은 못 버린다」는
//!   뜻이지 「연결을 죽여라」가 아니다 — 그 청크가 빠진 뒤 버리면 된다.
//!
//! 둘 중 어느 것이었는지 끝내 알 수 없어, 그 사고의 수정 방향을 정하지 못했다.
//!
//! ## 이 판정자가 재는 것
//!
//! 「오류를 남긴다」가 아니라 **「오류를 버리는 `catch` 가 없다」**를 잰다. 하나라도 `|err|` 없이
//! 닫으면 그 경로를 밟는 날 다시 이름만 보게 된다.

const std = @import("std");

const turn_path = "src/platform/macos/session_host/connection_turn.zig";
const log_path = "src/platform/macos/session_host/poll_owner.zig";
const max_source_bytes = 16 * 1024 * 1024;

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_source_bytes));
}

test "닫는 자리는 그 자리를 만든 오류까지 남긴다" {
    const a = std.testing.allocator;
    const turn = try read(a, turn_path);
    defer a.free(turn);
    const log = try read(a, log_path);
    defer a.free(log);

    // ① **오류를 버리는 close 가 없어야 한다.** `catch\n ... beginCloseAt(` 은 `|err|` 이 없는 모양이다.
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, turn, scan, "beginCloseAt(")) |at| {
        scan = at + 1;
        // 이 호출 앞 120 바이트 안에 `catch` 가 있으면, 그 `catch` 가 `|err|` 을 잡아야 한다.
        const from = if (at > 120) at - 120 else 0;
        const before = turn[from..at];
        const catch_at = std.mem.lastIndexOf(u8, before, "catch") orelse continue;
        const between = before[catch_at..];
        if (std.mem.indexOf(u8, between, "|err|") == null) {
            std.debug.print(
                "오류를 버리고 닫는 자리가 있다 — 이름만 남고 «무엇»이 사라진다: «{s}»\n",
                .{between},
            );
            return error.CloseDiscardsError;
        }
    }

    // ② 오류를 싣는 경로가 존재한다.
    if (std.mem.indexOf(u8, turn, "fn beginCloseAtErr(") == null) {
        std.debug.print("오류를 함께 남기는 close 경로가 없다\n", .{});
        return error.NoErrorCarryingClose;
    }

    // ③ **자리 이름은 그대로 살아 있다.** 오류를 더하려다 이름을 잃으면 구멍이 자리만 옮긴다.
    try std.testing.expect(std.mem.indexOf(u8, turn, "close_site") != null);
    try std.testing.expect(std.mem.indexOf(u8, turn, "pub fn closeSite(") != null);

    // ④ **로그까지 흐른다.** 기록만 하고 아무도 안 보면 없는 것과 같다.
    if (std.mem.indexOf(u8, log, "err={s}") == null or
        std.mem.indexOf(u8, log, "client.closeError()") == null)
    {
        std.debug.print("오류가 로그로 안 나간다 — 기록만 하고 아무도 안 본다\n", .{});
        return error.ErrorNotLogged;
    }

    // ⑤ **첫 호출이 이긴다는 규율을 지킨다.** `beginClose` 계열은 이미 닫히는 중이면 덮지 않는다 —
    //    덮으면 사유와 자리가 어긋난 채 남는다(그 주석이 이미 그렇게 적고 있다).
    const fn_at = std.mem.indexOf(u8, turn, "fn beginCloseAtErr(") orelse return error.NoErrorCarryingClose;
    const fn_end = std.mem.indexOfPos(u8, turn, fn_at, "\n    }") orelse turn.len;
    if (std.mem.indexOf(u8, turn[fn_at..fn_end], "if (self.isClosing()) return;") == null) {
        std.debug.print("이미 닫히는 중인데 덮어쓴다 — 사유와 자리가 어긋난다\n", .{});
        return error.OverwritesFirstClose;
    }
}
