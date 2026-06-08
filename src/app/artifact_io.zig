//! smoke/demo가 summary·screen·snapshot·frame 같은 artifact를 디스크에 쓰는 공통 IO다.
//! headless demo, app host, frame loop, 모든 PTY smoke가 같은 truncate-write / dir-create
//! 정책을 공유하도록 한 곳에 둔다. 이전에는 각 파일이 이 trio를 복사해, write flag나 에러
//! 처리 정책을 바꿀 때 일부만 갱신될 위험이 있었다.

const std = @import("std");

/// `path`를 truncate하고 `contents`를 쓴다(디렉터리는 caller가 ensureDir로 먼저 만든다).
pub fn writeText(io: std.Io, path: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
}

/// `contents` 뒤에 줄바꿈 하나를 붙여 쓴다. 사람이 보는 단일 값 artifact(screen 등)가
/// 항상 trailing newline으로 끝나게 한다.
pub fn writeTextWithFinalNewline(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
) !void {
    const with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{contents});
    defer allocator.free(with_newline);
    try writeText(io, path, with_newline);
}

/// artifact 디렉터리를 만든다(비어 있으면 no-op).
pub fn ensureDir(io: std.Io, dir: []const u8) !void {
    if (dir.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(io, dir);
}
