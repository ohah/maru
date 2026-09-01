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

/// 함수 하나의 본문을 자른다. **`max` 를 넘으면 실패한다** — 경계 문자열이 안 맞으면 슬라이스가 파일
/// 끝까지 달아나고, 그러면 아래 needle 들이 **아무 데서나** 걸려 판정자가 통째로 초록이 된다
/// (적대적 검증 1회차: 경계를 지워도 통과했다). 「못 찾았다」와 「달아났다」를 함께 막는다.
fn bodyOf(src: []const u8, head: []const u8, close: []const u8, max: usize) ![]const u8 {
    const at = std.mem.indexOf(u8, src, head) orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at, close) orelse return error.FunctionUnterminated;
    const body = src[at..end];
    if (body.len > max) return error.FunctionBodyRunaway;
    return body;
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
    const wt_body = try bodyOf(workspace, "pub fn windowTitle", "\n}\n", 2048);
    try std.testing.expect(std.mem.indexOf(u8, wt_body, "observation.window_title") != null);
    try std.testing.expect(std.mem.indexOf(u8, wt_body, "currentCwd") == null); // 다시 엮이면 표도 고쳐야 한다
    try std.testing.expect(std.mem.indexOf(u8, doc, "| 창 제목 | **cwd 를 안 쓴다.**") != null);

    // ── ⑵ `maru_macos_app_session_cwd` 는 **제품 소비자가 0** 이다 ─────────────────────────────
    //
    // 헤더 선언과 Zig export 는 있고 Swift 호출자가 없다. 생기면 표의 그 행부터 고쳐야 한다.
    const abi = try read(allocator, "src/platform/macos/app_host_abi.zig", 4 * 1024 * 1024);
    defer allocator.free(abi);
    try std.testing.expect(std.mem.indexOf(u8, abi, "pub export fn maru_macos_app_session_cwd") != null);
    // ⚠️ **Swift 파일은 하나가 아니다**(적대적 검증 2회차 — 16 개다). `MaruAppHost.swift` 만 보고
    //    「소비자 0」이라고 하면, 다른 파일이 부르는 순간 그 주장이 거짓이 되는데 판정자는 초록이다.
    //    디렉터리를 훑어 **전수**로 센다.
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src/platform/macos", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var swift_seen: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".swift")) continue;
        const body = try dir.readFileAlloc(std.testing.io, entry.name, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(body);
        swift_seen += 1;
        if (std.mem.indexOf(u8, body, "maru_macos_app_session_cwd(") != null) {
            std.debug.print("소비자가 생겼다: {s} — §9.4 표의 그 행을 고쳐야 한다\n", .{entry.name});
            return error.CwdAbiConsumerAppeared;
        }
    }
    // **훑은 파일이 0 이면 경로가 바뀐 것이다** — 0 을 통과시키면 「아무도 안 부른다」와 「아무것도 안
    // 봤다」가 구분되지 않는다.
    try std.testing.expect(swift_seen >= 10);

    // ── ⑶ 표시 축의 규율: 원격 경로는 `<host>:<path>` ────────────────────────────────────────
    //
    // 폴더줄이 그 규율을 지고, 판정은 `termCwdIsRemote` + `termDisplayHost` **하나**를 공유한다 —
    // 재구현하면 두 뷰가 같은 경로를 다르게 적는다(실제로 종료 안내가 그랬다).
    const sb_body = try bodyOf(app, "pub fn sidebarCwdPath", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, sb_body, "termCwdIsRemote(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sb_body, "termDisplayHost(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "`<host>:<path>` 로 적는다") != null);

    // 그 규율을 지나는 자리는 **둘**이다 — 폴더줄과 종료 안내. 표에 행만 늘리고 여기서 안 세면,
    // 이 판정자가 막으려던 낡음이 **새 행에서 다시 시작**된다.
    const eg_body = try bodyOf(app, "pub fn writeEndedPlaceholderGuidance", "\n    }\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, eg_body, "termCwdIsRemote(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, eg_body, "termDisplayHost(term)") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "| 종료 placeholder 안내(`마지막 위치`) |") != null);

    // ── ⑷ 쓰기 축의 규율: 원격 cwd 를 **로컬 spawn 에 안 넘긴다** ─────────────────────────────
    //
    // 표의 두 행(새 탭 상속·종료 Term 되살리기)이 주장하는 사실이다.
    const respawn_body = try bodyOf(app, "fn respawnEndedPlaceholder", "\n    }\n", 8192);
    try std.testing.expect(std.mem.indexOf(u8, respawn_body, "if (!termCwdIsRemote(tomb))") != null);
    const term = try read(allocator, "src/platform/macos/app_session/term.zig", 4 * 1024 * 1024);
    defer allocator.free(term);
    const ft_body = try bodyOf(term, "pub fn focusedTermCwd", "\n}\n", 2048);
    try std.testing.expect(std.mem.indexOf(u8, ft_body, "termCwdIsRemote(term)") != null);
}
