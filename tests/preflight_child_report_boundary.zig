//! **원인을 알아야 하는 순간의 부모는 항상 옛 빌드다.**
//!
//! ## 무엇이 있었나
//!
//! 2026-09-10, 새 빌드를 깔 때마다 host 가 하나 더 생겼다. 앱 로그는
//! `upgrade result: upgrade_failed … reason=target_invalid` 라고만 적었다. 그 이름을 내는 자리가 **둘**인데
//! 구분이 안 됐다 — preflight 자식의 non-zero 종료(`upgrade_preflight.zig`)와, preflight 를 돌기도 전에
//! 접히는 `beginExecution` 의 `verify` 실패(`upgrade_target.verifyOpaque`).
//!
//! 앞서 그 이유를 부모(`waitPreflight`)에 적게 했는데 **한 번도 안 찍혔다.** 부모는 fork 하는 쪽,
//! 곧 **옛 host** 다. 새 빌드를 깔아야 업그레이드가 일어나므로 그 순간 부모는 정의상 옛 이미지이고,
//! 진단은 새 빌드에만 있다. 실측: 옛 host 이미지에 그 문자열 0 건, 새 설치본에 2 건.
//!
//! ## 그래서 어디에 적는가
//!
//! **자식은 새 빌드다**(부모가 staged target 을 exec 한다). 그래서 자식이 적으면 부모가 무엇이든 남는다.
//! 단 **물려받은 fd 에 적으면 안 된다** — stderr 의 행선지를 정하는 것은 부모이고, 옛 부모는 그것을
//! `/dev/null` 로 보낸다. 자식이 **자기가 연 파일**에 적어야 한다.
//!
//! **성공도 적어야 한다.** 「preflight 는 통과했는데 결과는 `target_invalid`」이면 범인은 `verify` 다.
//! 실패만 적으면 그 둘이 「로그 없음」으로 똑같아 보인다.

const std = @import("std");

const preflight_path = "src/platform/macos/session_host/upgrade_preflight.zig";
const main_path = "src/main.zig";
const target_path = "src/platform/macos/session_host/upgrade_target.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 벗긴다 — 위 머리말과 코드 주석이 옛 모습을 인용하므로, 벗기지 않으면 「설명하는 주석」이
/// 「쓰는 코드」로 세어진다.
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

fn has(src: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, src, needle) != null;
}

test "preflight 자식은 자기가 연 파일에 결과를 남긴다 (부모가 옛 빌드여도)" {
    const a = std.testing.allocator;
    const raw = try read(a, preflight_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① 자식이 부를 수 있는 공개 함수여야 한다.
    try std.testing.expect(has(src, "pub fn noteChildOutcome(ok: bool, detail: []const u8) void"));

    // ② **자기가 연 파일**이어야 한다. 물려받은 fd 2 에 적으면 옛 부모가 `/dev/null` 로 보내 사라진다 —
    //    이 진단이 존재하는 이유가 정확히 그것이므로, `host_log.line`(fd 2 로 쓴다)으로 바꾸면 빨개진다.
    const fn_at = std.mem.indexOf(u8, src, "pub fn noteChildOutcome").?;
    const body = src[fn_at..];
    const body_end = std.mem.indexOf(u8, body, "\nfn ") orelse body.len;
    const fn_body = body[0..body_end];
    try std.testing.expect(has(fn_body, "/tmp/maru-{d}/session-host/preflight.log"));
    try std.testing.expect(has(fn_body, "c.open("));
    try std.testing.expect(!has(fn_body, "host_log.line"));
    try std.testing.expect(!has(fn_body, "c.write(2,"));

    // ③ 이어 붙여야 한다 — 덮어쓰면 직전 시도가 사라져 「두 번 실패했다」를 못 본다.
    try std.testing.expect(has(fn_body, ".APPEND = true"));

    // ④ 결과를 **양쪽 다** 적어야 한다. 성공 줄이 없으면 「preflight 통과 + verify 실패」가
    //    「preflight 자체가 안 돌았다」와 구분되지 않는다.
    try std.testing.expect(has(fn_body, "if (ok) \"ok\" else \"failed\""));

    // ⑤ 자식 진입점이 **성공·실패 둘 다** 부르는가.
    const main_raw = try read(a, main_path);
    defer a.free(main_raw);
    const main_src = try stripComments(a, main_raw);
    defer a.free(main_src);
    try std.testing.expect(has(main_src, "noteChildOutcome(false, @errorName(err))"));
    try std.testing.expect(has(main_src, "noteChildOutcome(true,"));
}

test "target verify 는 넷 중 어디서 접혔는지 남긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, target_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // `verifyOpaque` 의 `false` 는 넷이고, 전부 같은 `reason=target_invalid` 로 접힌다. 넷을 가르지
    // 않으면 「고정 fd 가 딴 것을 가리킨다」와 「경로가 사라졌다」가 한 이름이 된다.
    for ([_][]const u8{
        "at=pinned_fd",
        "at=pinned_identity",
        "at=path_open",
        "at=path_identity",
    }) |label| {
        try std.testing.expect(has(src, label));
    }

    // 조용한 `catch return false` 가 남아 있으면 그 갈래는 여전히 이름 없이 사라진다.
    try std.testing.expect(!has(src, "catch return false"));
}
