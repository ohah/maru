//! **업그레이드 선행 검사가 왜 거부했는지** 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-10 실측 — 업그레이드가 `result=upgrade_failed … reason=target_invalid` 로 접혔다. 세션
//! 23 개는 안전했다(`status=resumed` — 선행 검사가 목적대로 destructive exec 을 막았다). 그런데 **왜**
//! 거부했는지는 알 길이 없었다.
//!
//! 부모는 자식의 종료 상태를 손에 쥐고도 버렸다:
//!
//!     if (waited == pid) return if (status == 0) {} else error.InvalidTarget;
//!
//! 그리고 자식은 첫 줄에서 **stdout·stderr 를 함께** `/dev/null` 로 돌려, exec 뒤의 실패가 찍는
//! «maru session host preflight failed: …» 가 아무 데도 안 남았다. host 로그에 preflight 한 줄이 없던
//! 것이 그 증거다.
//!
//! 그래서 여덟 갈래가 한 이름으로 뭉쳤다 — 자식 준비 다섯(fd 복제·슬롯 준비·fd 집합·redirect·exec)과
//! exec 뒤 셋(`InvalidFd`·handoff 읽기·`validateExecutable`).

const std = @import("std");

const source_path = "src/platform/macos/session_host/upgrade_preflight.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 벗긴다 — 위 머리말이 옛 모습을 그대로 인용하므로, 벗기지 않으면 「설명하는 주석」이
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

test "선행 검사 거부는 종료 상태를 남기고, 자식의 stderr 를 죽이지 않는다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① 부모가 종료 상태를 남긴다 — exit / signal / 그 밖 셋 다.
    for ([_][]const u8{
        "upgrade preflight rejected target: exit={d}",
        "upgrade preflight rejected target: signal={d}",
        "upgrade preflight rejected target: raw_status=0x{x}",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, src, needle) != null);

    // ② 버리던 옛 한 줄이 되살아나면 빨개진다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (waited == pid) return if (status == 0) {} else error.InvalidTarget;",
    ) == null);

    // ③ **자식의 stderr 를 죽이지 않는다.** exec 뒤의 실패는 stderr 로만 말한다 — 그것을 `/dev/null`
    //    로 보내면 다시 침묵이다. host 의 fd 2 는 `host-<id>.log` 라 물려받으면 그대로 남는다.
    try std.testing.expect(std.mem.indexOf(u8, src, "redirectStdinStdoutToDevNull") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "redirectStdioToDevNull") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "while (fd <= 2) : (fd += 1)") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "while (fd <= 1) : (fd += 1)") != null);

    // ④ 준비 단계는 **저마다 다른 코드**로 끝난다. 전부 125 면 다섯이 한 숫자로 뭉친다.
    for ([_][]const u8{
        "exit_redirect_failed: u8 = 121",
        "exit_dup_failed: u8 = 122",
        "exit_prepare_failed: u8 = 123",
        "exit_fd_set_invalid: u8 = 124",
        "exit_exec_failed: u8 = 125",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, src, needle) != null);
    // 같은 숫자를 두 자리에서 쓰면 갈리지 않는다 — `_exit(125)` 리터럴이 남아 있으면 빨개진다.
    try std.testing.expect(std.mem.indexOf(u8, src, "_exit(125)") == null);
}
