//! `ssh-integration.md` §9.4 의 「원격 cwd 소비처」 표가 **코드와 같은 상태를 말하는가**.
//!
//! ## 왜 문서를 판정자가 무는가
//!
//! 그 표는 **두 번 낡았다.** 「창 제목이 `currentCwd` 를 쓴다」는 옛 배선이었고, 코드는 2026-08-12 에
//! 그 사실을 주석으로 정정했는데 표는 따라오지 않았다. 그래서 2026-09-01 에 그 행을 읽고 「host 접두를
//! 붙이는 후속이 남았다」고 판단한 사람이 있었다 — **소비자가 0 인 자리의 후속**이었다.
//!
//! 표가 낡으면 **다음 사람에게 없는 일을 시킨다.** 그 낭비는 조용하고, 되풀이된다.
//!
//! ## 무엇을 세는가
//!
//! 표의 각 행이 주장하는 **코드 사실**을 소스에서 되짚는다. 문장을 대조하는 것이 아니라 **그 문장이
//! 참인지**를 본다 — 문구를 다듬어도 안 깨지고, 배선이 바뀌면 깨진다.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

test "§9.4 표는 원격 cwd 소비처의 지금 배선을 말한다" {
    const allocator = std.testing.allocator;
    const doc = try read(allocator, "docs/ssh-integration.md", 512 * 1024);
    defer allocator.free(doc);
    const app = try read(allocator, "src/platform/macos/app_session.zig", 8 * 1024 * 1024);
    defer allocator.free(app);
    const workspace = try read(allocator, "src/platform/macos/app_session/workspace.zig", 2 * 1024 * 1024);
    defer allocator.free(workspace);

    // ── 표가 있는가(제목이 바뀌면 이 판정자가 딴 데를 보게 된다) ─────────────────────────────
    try std.testing.expect(std.mem.indexOf(u8, doc, "| 소비처 | 원격 cwd일 때 |") != null);

    // ── ⑴ 창 제목은 **cwd 를 안 쓴다.** `windowTitle()` 이 OSC 0/2 관측에서 만든다 ────────────
    //
    // 표가 「`currentCwd` → Swift」라고 적고 있던 자리다. 코드가 그 사실을 먼저 정정했다.
    const wt = std.mem.indexOf(u8, workspace, "pub fn windowTitle") orelse return error.WindowTitleMissing;
    const wt_end = std.mem.indexOfPos(u8, workspace, wt, "\n}\n") orelse workspace.len;
    const wt_body = workspace[wt..wt_end];
    try std.testing.expect(std.mem.indexOf(u8, wt_body, "observation.window_title") != null);
    try std.testing.expect(std.mem.indexOf(u8, wt_body, "currentCwd") == null); // 다시 엮이면 표도 고쳐야 한다
    try std.testing.expect(std.mem.indexOf(u8, doc, "| 창 제목 | **cwd 를 안 쓴다.**") != null);

    // ── ⑵ `maru_macos_app_session_cwd` 는 **제품 소비자가 0** 이다 ─────────────────────────────
    //
    // 헤더 선언과 Zig export 는 있고 Swift 호출자가 없다. 생기면 표의 그 행부터 고쳐야 한다.
    const abi = try read(allocator, "src/platform/macos/app_host_abi.zig", 4 * 1024 * 1024);
    defer allocator.free(abi);
    try std.testing.expect(std.mem.indexOf(u8, abi, "pub export fn maru_macos_app_session_cwd") != null);
    const swift = try read(allocator, "src/platform/macos/MaruAppHost.swift", 8 * 1024 * 1024);
    defer allocator.free(swift);
    try std.testing.expect(std.mem.indexOf(u8, swift, "maru_macos_app_session_cwd(") == null);

    // ── ⑶ 표시 축의 규율: 원격 경로는 `<host>:<path>` ────────────────────────────────────────
    //
    // 폴더줄이 그 규율을 지고, 판정은 `termCwdIsRemote` + `termDisplayHost` **하나**를 공유한다 —
    // 재구현하면 두 뷰가 같은 경로를 다르게 적는다(실제로 종료 안내가 그랬다).
    const sb = std.mem.indexOf(u8, app, "pub fn sidebarCwdPath") orelse return error.SidebarMissing;
    const sb_end = std.mem.indexOfPos(u8, app, sb, "\n}\n") orelse app.len;
    const sb_body = app[sb..sb_end];
    try std.testing.expect(std.mem.indexOf(u8, sb_body, "termCwdIsRemote(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sb_body, "termDisplayHost(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "`<host>:<path>` 로 적는다") != null);

    // ── ⑷ 쓰기 축의 규율: 원격 cwd 를 **로컬 spawn 에 안 넘긴다** ─────────────────────────────
    //
    // 표의 두 행(새 탭 상속·종료 Term 되살리기)이 주장하는 사실이다.
    const fresh = std.mem.indexOf(u8, app, "fn respawnEndedPlaceholder") orelse return error.RespawnMissing;
    const fresh_end = std.mem.indexOfPos(u8, app, fresh, "\n    }\n") orelse app.len;
    try std.testing.expect(std.mem.indexOf(u8, app[fresh..fresh_end], "if (!termCwdIsRemote(tomb))") != null);
    const term = try read(allocator, "src/platform/macos/app_session/term.zig", 4 * 1024 * 1024);
    defer allocator.free(term);
    const ft = std.mem.indexOf(u8, term, "pub fn focusedTermCwd") orelse return error.FocusedCwdMissing;
    const ft_end = std.mem.indexOfPos(u8, term, ft, "\n}\n") orelse term.len;
    try std.testing.expect(std.mem.indexOf(u8, term[ft..ft_end], "termCwdIsRemote(term)") != null);
}
