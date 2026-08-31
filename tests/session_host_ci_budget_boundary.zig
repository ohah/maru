//! Session-host Debug 전수 스위트의 CI 시간 예산과 문서 SSOT가 함께 움직이는지 고정한다.
//!
//! 이 게이트가 없으면 테스트 수가 늘어 성공 경로가 20분을 넘겨도 workflow 상한만 오래된 채 남고,
//! assertion 실패가 아닌 `The operation was canceled`가 required check를 막는다.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

fn jobBody(workflow: []const u8, name: []const u8, next_name: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, workflow, name) orelse return error.JobMissing;
    const tail = workflow[start..];
    const end = std.mem.indexOf(u8, tail, next_name) orelse return error.NextJobMissing;
    return tail[0..end];
}

test "session host Debug required job owns the measured 35 minute completion budget" {
    const allocator = std.testing.allocator;
    const workflow = try read(allocator, ".github/workflows/ci.yml", 256 * 1024);
    defer allocator.free(workflow);
    const budget = try read(allocator, "docs/performance-budget.md", 256 * 1024);
    defer allocator.free(budget);

    const debug_job = try jobBody(
        workflow,
        "  session-host-macos-debug:\n",
        "  session-host-bundled-cli-macos:\n",
    );
    const bundled_job = try jobBody(
        workflow,
        "  session-host-bundled-cli-macos:\n",
        "  session-host-keepalive-macos:\n",
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, debug_job, "    timeout-minutes:"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, debug_job, "    timeout-minutes: 35\n"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, debug_job, "    timeout-minutes: 20\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bundled_job, "    timeout-minutes:"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bundled_job, "    timeout-minutes: 35\n"));
    try std.testing.expect(std.mem.indexOf(u8, budget, "`session host macOS (Debug)`") != null);
    try std.testing.expect(std.mem.indexOf(u8, budget, "**job 상한은 35분**") != null);
    try std.testing.expect(std.mem.indexOf(u8, budget, "각각 35분 상한") != null);
}
