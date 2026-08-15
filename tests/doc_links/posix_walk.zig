//! **복제본이다.** 정본은 `tests/support/posix_walk.zig`이고 내용은 그쪽 문서주석을 본다.
//!
//! Zig는 모듈 루트 디렉터리 밖의 상대 `@import`를 막는다(`import of file outside module path` — 실측).
//! 이 디렉터리의 테스트 파일들은 각자가 모듈 루트라 `../support/posix_walk.zig`에 닿지 못한다.
//! 그래서 `tests/` 직하 18개 파일은 정본을 그대로 import하고, 하위 디렉터리 3곳만 이 복제본을 둔다.
//! 정본을 고치면 이 세 복제본도 함께 고친다.

const std = @import("std");

/// 정규화 버퍼는 **힙**에 둔다. 인라인 배열로 두면 안 되는 이유가 측정으로 드러났다:
/// `std.fs.max_path_bytes`가 Windows에서 **98,302바이트(≈96KB)** 다(macOS는 4,096). 구조체에 박으면
/// walker 하나가 스택 96KB를 먹고, `posixWalk`가 값으로 반환하므로 전달 중 한 번 더 복사된다.
/// 힙으로 옮기면 구조체가 포인터 두 개로 줄어 반환 복사가 사실상 공짜가 된다.
/// POSIX 호스트에서는 정규화 자체가 필요 없으므로 **할당도 하지 않는다**(comptime 분기).
pub const PosixWalker = struct {
    inner: std.Io.Dir.Walker,
    allocator: std.mem.Allocator,
    path_buf: []u8,

    pub fn next(self: *PosixWalker, io: std.Io) !?std.Io.Dir.Walker.Entry {
        var entry = (try self.inner.next(io)) orelse return null;
        if (std.fs.path.sep == '/') return entry;
        // 잘라내면 "제외 목록에 없는 경로"로 조용히 바뀌어 게이트가 거짓 초록이 된다 — 시끄럽게 실패시킨다.
        if (entry.path.len >= self.path_buf.len) return error.NameTooLong;
        for (entry.path, 0..) |byte, i|
            self.path_buf[i] = if (byte == std.fs.path.sep) '/' else byte;
        self.path_buf[entry.path.len] = 0;
        entry.path = self.path_buf[0..entry.path.len :0];
        return entry;
    }

    pub fn deinit(self: *PosixWalker) void {
        self.inner.deinit();
        self.allocator.free(self.path_buf);
    }
};

pub fn posixWalk(dir: std.Io.Dir, allocator: std.mem.Allocator) !PosixWalker {
    const path_buf = if (std.fs.path.sep == '/')
        try allocator.alloc(u8, 0) // POSIX: 정규화를 안 하므로 버퍼가 필요 없다(free 대칭만 유지).
    else
        try allocator.alloc(u8, std.fs.max_path_bytes);
    errdefer allocator.free(path_buf);
    return .{ .inner = try dir.walk(allocator), .allocator = allocator, .path_buf = path_buf };
}
