//! 앱 진단 통로(`app.log`)는 **앱 시작 직후**, **버려지는 stderr 에만** 연결한다.
//!
//! Dock·Finder 로 띄운 앱의 stderr 는 `/dev/null` 이다. 예전에는 첫 창 세션을 만들 때에야 `app.log` 로 돌려서
//! 그 전의 lease·config bootstrap 실패 줄이 사라졌다. 앞당기면서 기준도 「tty 가 아니면」에서 「`/dev/null` 이면」으로
//! 좁혔다 — 그대로 두면 `2> 파일` 로 세션 이전 줄을 기다리는 하네스(tools/test-macos-app-instance-lease.sh)가
//! 그 줄을 못 본다. 두 조건은 서로를 전제로 하므로 함께 고정한다.
const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(16 * 1024 * 1024));
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

test "app log redirect runs first in main and only for a /dev/null stderr" {
    const allocator = std.testing.allocator;
    const swift_raw = try read(allocator, "src/platform/macos/MaruAppHost.swift");
    defer allocator.free(swift_raw);
    const swift = try stripComments(allocator, swift_raw);
    defer allocator.free(swift);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, swift, "maru_macos_app_redirect_stderr()"));
    const main_at = std.mem.indexOf(u8, swift, "static func main() {") orelse return error.MainMissing;
    const call_at = std.mem.indexOf(u8, swift, "maru_macos_app_redirect_stderr()").?;
    // main 안의 **첫 진단 출력**과 lease 획득보다 앞이어야 한다 — 그보다 늦으면 그 줄들이 다시 사라진다.
    const lease_at = std.mem.indexOfPos(u8, swift, main_at, "acquireAppInstanceWriterLeaseBeforeAppKit()") orelse
        return error.LeaseCallMissing;
    const first_fputs = std.mem.indexOfPos(u8, swift, main_at, "fputs(") orelse return error.NoDiagnosticInMain;
    try std.testing.expect(main_at < call_at);
    try std.testing.expect(call_at < lease_at);
    try std.testing.expect(call_at < first_fputs);

    const abi_raw = try read(allocator, "src/platform/macos/app_host_abi.zig");
    defer allocator.free(abi_raw);
    const abi = try stripComments(allocator, abi_raw);
    defer allocator.free(abi);
    const start = std.mem.indexOf(u8, abi, "fn redirectStderrToAppLog() void {") orelse return error.RedirectMissing;
    const end = std.mem.indexOfPos(u8, abi, start, "std.c.dup2(fd, 2)") orelse return error.RedirectMissing;
    const before_dup = abi[start..end];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, before_dup, "if (!fdIsDevNull(2)) return;"));
    // 「tty 가 아니면」으로 되돌아가면 파일·파이프로 받는 실행의 출력을 빼앗는다.
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, before_dup, "isatty"));
    // 멱등 — 시작 직후와 창마다 두 번 이상 불린다.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, before_dup, "if (app_log_redirected) return;"));
}
