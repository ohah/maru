//! 호스트 어댑터 확보 실패가 **어디서·왜** 였는지 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 워크스페이스 복원이 매번 이렇게 죽었다(2026-09-13 실측).
//!
//! ```
//! workspace apply failed: window_index=0 err=PersistentRuntimeUnavailable attach_site=- attach_raw=- attach_outcome=-
//! ```
//!
//! `attach_site=-` 는 **attach 를 시도조차 못 했다**는 뜻이다 — 그 앞의 `ensureRestoreHostAdapter` 가
//! 이미 포기했다. 그런데 그 함수는 `.unavailable` 을 **아홉 곳**에서 돌려주고 전부 익명이었다.
//! 풀 문제인지·프로토콜인지·연결 실패인지 **물어볼 수가 없었다.**
//!
//! 특히 연결 실패 갈래는 이랬다.
//!
//! ```zig
//! .failed => |reason| {
//!     if (reason != .host_gone) return .unavailable;   // reason 을 «버린다»
//! ```
//!
//! 죽은 host 가 왜 `host_gone` 으로 안 갈렸는지가 그래서 안 보였다. 오늘 같은 병을 여섯 번 고쳤는데
//! (`collect_fail_site`·close `site=`·`digest site`·`attach_site`) 여기만 남아 있었다.
//!
//! ## 이 판정자가 재는 것
//!
//! 「이름이 있다」가 아니라 **「모든 포기 자리가 이름을 남긴다」**를 잰다. 하나라도 익명으로 남으면
//! 그 경로를 밟는 날 다시 `-` 만 보게 된다.

const std = @import("std");

const session_path = "src/platform/macos/app_session.zig";
const abi_path = "src/platform/macos/app_host_abi.zig";
const max_source_bytes = 16 * 1024 * 1024;

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_source_bytes));
}

test "호스트 어댑터 확보 실패는 모든 자리가 이름을 남긴다" {
    const a = std.testing.allocator;
    const src = try read(a, session_path);
    defer a.free(src);
    const abi = try read(a, abi_path);
    defer a.free(abi);

    const decl = "fn ensureRestoreHostAdapterAtBase(";
    const at = std.mem.indexOf(u8, src, decl) orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + decl.len, "\n    pub fn ") orelse src.len;
    const body = src[at..end];

    // ① **익명 포기가 하나도 없어야 한다.** `return .unavailable;` 은 이름을 안 남긴다.
    if (std.mem.indexOf(u8, body, "return .unavailable;") != null) {
        std.debug.print("이름 없이 포기하는 자리가 남아 있다 — 그 경로를 밟으면 다시 `-` 만 보인다\n", .{});
        return error.AnonymousUnavailable;
    }

    // ② 이름을 남기는 경로가 실제로 쓰인다(전부 헬퍼 경유).
    var helper_uses: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, body, scan, "restoreHostUnavailable(")) |found| {
        helper_uses += 1;
        scan = found + 1;
    }
    if (helper_uses < 5) {
        std.debug.print("이름 붙은 포기가 {d} 곳뿐이다 — 아홉 곳이 있었다\n", .{helper_uses});
        return error.TooFewNamedSites;
    }

    // ③ **연결 실패의 원래 reason 을 버리지 않는다.** 죽은 host 가 왜 `host_gone` 이 아니었는지가
    //    거기 있다. `@tagName(reason)` 이 기록돼야 한다.
    const failed_at = std.mem.indexOf(u8, body, "if (reason != .host_gone)") orelse
        return error.ConnectFailedArmMissing;
    const arm_end = std.mem.indexOfPos(u8, body, failed_at, "\n") orelse body.len;
    if (std.mem.indexOf(u8, body[failed_at..arm_end], "@tagName(reason)") == null) {
        std.debug.print("연결 실패가 원래 reason 을 버린다 — host_gone 오분류를 영영 못 본다\n", .{});
        return error.ConnectReasonDiscarded;
    }

    // ④ **진입 때 초기화한다.** 안 지우면 지난 실패의 이름이 이번 것으로 읽힌다(오늘 그 실수를 했다).
    const reset_at = std.mem.indexOf(u8, body, "noteRestoreHost(\"-\", \"-\")") orelse {
        std.debug.print("진입 시 원장을 안 지운다 — 직전 실패의 이름이 찍힌다\n", .{});
        return error.LedgerNotReset;
    };
    const first_named = std.mem.indexOf(u8, body, "restoreHostUnavailable(") orelse return error.TooFewNamedSites;
    try std.testing.expect(reset_at < first_named);

    // ⑤ **로그까지 흐른다.** 기록만 하고 아무도 안 보면 없는 것과 같다.
    if (std.mem.indexOf(u8, abi, "host_site={s}") == null or
        std.mem.indexOf(u8, abi, "AppSession.restore_host_site") == null)
    {
        std.debug.print("이름이 로그로 안 나간다 — 기록만 하고 아무도 안 본다\n", .{});
        return error.SiteNotLogged;
    }
}
