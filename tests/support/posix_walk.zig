//! 소스 스캐너용 walker — `entry.path`를 **항상 `/` 구분**으로 준다.
//!
//! `std.Io.Dir.Walker`의 `entry.path`는 **호스트 native 구분자**를 쓴다: Windows에서는
//! `platform\macos\x.zig`. 그런데 boundary·doc-link·config-doc 스캐너들은 그 경로를
//! `"platform/macos/x.zig"` 같은 **`/` 리터럴과 비교**한다. 그대로 두면 제외 목록과 매칭이
//! 조용히 전부 빗나간다 — 실측에서 제외됐어야 할 파일이 집계에 섞여 boundary 카운트가 부풀었고,
//! 컴파일도 통과하고 macOS CI도 초록인 채로 Windows에서만 틀렸다.
//!
//! POSIX 호스트에서는 native 구분자가 이미 `/`라 `next`가 std walker를 그대로 통과시킨다
//! (분기가 comptime으로 접혀 무동작·무비용).
//!
//! `next`/`deinit` 시그니처를 std walker와 맞췄으므로 **호출하는 루프 본문은 바꿀 필요가 없다** —
//! `try dir.walk(alloc)`을 `try posixWalk(dir, alloc)`으로 바꾸는 것만으로 적용된다.

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
