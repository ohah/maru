//! 턴 스냅샷 임시 index 의 **거두는 규칙**이 제품 자리에 실제로 걸려 있는지 센다.
//!
//! `turn_index_cache.zig` 의 판정자는 «지우는 함수가 옳게 지우는가»만 본다. 그 함수를 **아무도 안
//! 부르면** 그 판정자는 초록인 채 파일이 계속 쌓인다 — 실제로 2026-09-15 까지 그랬다(지우는 자리가 없이
//! 6,123 개). 그래서 여기서는 「쓰는가」를 센다: 창 닫기가 `removeIndexFile` 을, 스냅샷 워커가
//! `sweepStaleSiblingsOnce` 를, 이름 짓기가 `prefix` 를 부르는지.
const std = @import("std");

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 << 20));
}

/// 주석 줄은 뺀다 — 설명문 한 줄이 판정을 뒤집으면 안 된다.
fn countOutsideComments(text: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, needle)) |at| {
            total += 1;
            from = at + needle.len;
        }
    }
    return total;
}

/// `signature` 부터 `end_marker`(그 함수의 닫는 괄호 줄) 까지 — 한 함수의 본문. 최상위 함수는 `"\n}\n"`,
/// 구조체 메서드(4 칸 들여쓰기)는 `"\n    }\n"` 이다.
fn functionBody(text: []const u8, signature: []const u8, end_marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, signature) orelse return null;
    const end = std.mem.indexOfPos(u8, text, start, end_marker) orelse return null;
    return text[start..end];
}

test "창 닫기는 임시 index 파일을 지운 뒤에 경로를 푼다" {
    const src = try readSource(std.testing.allocator, "src/platform/macos/app_session.zig");
    defer std.testing.allocator.free(src);
    const body = functionBody(src, "pub fn deinit(self: *AppSession) void {", "\n    }\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "turn_index_cache.removeIndexFile(self.io, path);"));
    // 지우기가 풀기보다 **앞**이어야 한다 — 푼 뒤에 지우면 해제된 경로를 읽는다. 순서는 **그 블록 안**에서
    // 본다: 본문 뒤쪽의 다른 `free(path)` 를 잡으면 순서를 바꿔도 초록이다(돌연변이 M2 가 살아남았다).
    const block_start = std.mem.indexOf(u8, body, "if (self.turn_index_path) |path| {") orelse return error.TestUnexpectedResult;
    const block_end = std.mem.indexOfPos(u8, body, block_start, "\n        }\n") orelse return error.TestUnexpectedResult;
    const block = body[block_start..block_end];
    const remove_at = std.mem.indexOf(u8, block, "turn_index_cache.removeIndexFile(self.io, path);") orelse return error.TestUnexpectedResult;
    const free_at = std.mem.indexOf(u8, block, "self.allocator.free(path);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(remove_at < free_at);
}

test "이름 짓기는 모듈의 접두를 쓰고, 그 문자열을 따로 적지 않는다" {
    const src = try readSource(std.testing.allocator, "src/platform/macos/app_session.zig");
    defer std.testing.allocator.free(src);
    const body = functionBody(src, "pub fn turnIndexPath(self: *AppSession) ?[]const u8 {", "\n    }\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "turn_index_cache.prefix"));
    // 문자열을 두 자리에 적으면 한쪽만 바뀐 날 스윕이 공허해진다(아무것도 안 고른다).
    try std.testing.expectEqual(@as(usize, 0), countOutsideComments(src, "\"turn-index-"));
    try std.testing.expectEqual(@as(usize, 0), countOutsideComments(src, "/turn-index-"));
}

test "스냅샷 워커는 index 를 쓰기 전에 오래된 형제를 한 번 쓸어 낸다" {
    const src = try readSource(std.testing.allocator, "src/platform/macos/git_backend.zig");
    defer std.testing.allocator.free(src);
    const body = functionBody(src, "fn snapshotWorker(job: *SnapshotJob) void {", "\n}\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOutsideComments(body, "turn_index_cache.sweepStaleSiblingsOnce(state.io, job.index_file)"));
    const sweep_at = std.mem.indexOf(u8, body, "sweepStaleSiblingsOnce(") orelse return error.TestUnexpectedResult;
    const snapshot_at = std.mem.indexOfPos(u8, body, sweep_at, "takeTurnSnapshot(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(sweep_at < snapshot_at);
}
