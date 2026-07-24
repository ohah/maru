//! Host별 짧은 Unix socket namespace.
//!
//! Cache path 길이와 무관하게 macOS `sun_path` 상한을 만족하고, host ID가 routing identity에 포함되게 한다.
//! `/tmp` 자체의 플랫폼 symlink는 계약 밖이며, 우리가 소유하는 per-UID directory와 `sh` leaf만 no-follow,
//! same-UID, exact 0700으로 검증한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;

pub const Error = error{
    InvalidHostId,
    InvalidDirectory,
    PathTooLong,
};

pub fn userRootPathIn(buf: []u8, uid: posix.uid_t) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/maru-{d}", .{uid});
}

pub fn socketDirPathIn(buf: []u8, uid: posix.uid_t) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/maru-{d}/sh", .{uid});
}

pub fn socketPathIn(buf: []u8, uid: posix.uid_t, host_id: u128) error{ NoSpaceLeft, InvalidHostId }![:0]u8 {
    if (host_id == 0) return error.InvalidHostId;
    return std.fmt.bufPrintZ(buf, "/tmp/maru-{d}/sh/{x:0>32}.sock", .{ uid, host_id });
}

pub fn currentSocketPathIn(buf: []u8, host_id: u128) error{ NoSpaceLeft, InvalidHostId }![:0]u8 {
    return socketPathIn(buf, c.getuid(), host_id);
}

pub fn validateCurrentSocketPath(path: []const u8, host_id: u128) Error!void {
    var expected_buf: [128]u8 = undefined;
    const expected = currentSocketPathIn(&expected_buf, host_id) catch return error.PathTooLong;
    if (!std.mem.eql(u8, expected, path)) return error.PathTooLong;
}

/// Product launch 전에 호출한다. 기존 directory의 mode를 고쳐 신뢰하는 대신 exact 계약이 아니면 거부한다.
pub fn prepareCurrentUserNamespace() Error!void {
    var root_buf: [96]u8 = undefined;
    const root = userRootPathIn(&root_buf, c.getuid()) catch return error.PathTooLong;
    try ensureExactOwnerDir(root);
    var dir_buf: [112]u8 = undefined;
    const dir = socketDirPathIn(&dir_buf, c.getuid()) catch return error.PathTooLong;
    try ensureExactOwnerDir(dir);
}

fn ensureExactOwnerDir(path: [:0]const u8) Error!void {
    const rc = c.mkdir(path.ptr, 0o700);
    if (rc != 0 and posix.errno(rc) != .EXIST) return error.InvalidDirectory;
    var stat: posix.Stat = undefined;
    if (c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
        !posix.S.ISDIR(stat.mode) or stat.uid != c.getuid() or (stat.mode & 0o777) != 0o700)
        return error.InvalidDirectory;
}

test "short endpoint is host-id keyed, bounded, and under the current UID namespace" {
    var path_buf: [128]u8 = undefined;
    const path = try currentSocketPathIn(&path_buf, 0xAABB);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "/tmp/maru-{d}/sh/0000000000000000000000000000aabb.sock", .{c.getuid()});
    try std.testing.expectEqualStrings(expected, path);
    try std.testing.expect(path.len + 1 <= @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len);
    try validateCurrentSocketPath(path, 0xAABB);
    try std.testing.expectError(error.PathTooLong, validateCurrentSocketPath("/tmp/maru-0/sh/other.sock", 0xAABB));
}

test "short endpoint namespace is owner-only" {
    try prepareCurrentUserNamespace();
    var dir_buf: [112]u8 = undefined;
    const dir = try socketDirPathIn(&dir_buf, c.getuid());
    var stat: posix.Stat = undefined;
    try std.testing.expect(c.fstatat(posix.AT.FDCWD, dir.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) == 0);
    try std.testing.expect(posix.S.ISDIR(stat.mode));
    try std.testing.expectEqual(c.getuid(), stat.uid);
    try std.testing.expectEqual(@as(c.mode_t, 0o700), stat.mode & 0o777);
}
