//! U5 crash 뒤 owner-only host directory에 남은 upgrade attempt/target을 회수한다.
//!
//! Exact host owner lease를 획득한 제품 daemon만 호출한다. 이름만 보고 재귀 삭제하지 않고, closed
//! vocabulary와 pinned inode를 검증한 뒤 no-replace tomb rename을 거쳐 제거한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const test_scratch = @import("test_scratch.zig");

extern "c" fn renameatx_np(
    from_dir_fd: c_int,
    from: [*:0]const u8,
    to_dir_fd: c_int,
    to: [*:0]const u8,
    flags: c_uint,
) c_int;

const rename_excl: c_uint = 0x00000004;
const at_removedir: c_uint = 0x00000080;
const max_candidates: usize = 512;

pub const Error = error{
    InvalidDirectory,
    InvalidResidue,
    TooManyResidues,
    CleanupFailed,
};

pub const Summary = struct {
    attempts: usize = 0,
    targets: usize = 0,
};

const Kind = enum { attempt, target };

const Candidate = struct {
    kind: Kind,
    tomb: bool,
    id: u128,
    stat: posix.Stat,
};

pub fn sweep(owner_dir: [:0]const u8) Error!Summary {
    const owner_fd = c.open(owner_dir.ptr, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
        .NOFOLLOW = true,
    }, @as(c.mode_t, 0));
    if (owner_fd < 0) return error.InvalidDirectory;
    defer _ = c.close(owner_fd);
    try validateOwnerDirectory(owner_fd);

    var candidates: [max_candidates]Candidate = undefined;
    const count = try scan(owner_fd, &candidates);
    try rejectCanonicalTombCollisions(candidates[0..count]);

    // Validate every residue before the first mutation. Cleanup repeats all pathname-sensitive
    // checks after tomb rename, so a concurrent replacement can only fail closed.
    for (candidates[0..count]) |candidate| try validateCandidate(owner_fd, candidate);

    var summary: Summary = .{};
    for (candidates[0..count]) |candidate| {
        try cleanupCandidate(owner_fd, candidate);
        switch (candidate.kind) {
            .attempt => summary.attempts += 1,
            .target => summary.targets += 1,
        }
    }
    return summary;
}

fn scan(owner_fd: c.fd_t, out: *[max_candidates]Candidate) Error!usize {
    const scan_fd = c.dup(owner_fd);
    if (scan_fd < 0) return error.InvalidDirectory;
    const directory = c.fdopendir(scan_fd) orelse {
        _ = c.close(scan_fd);
        return error.InvalidDirectory;
    };
    defer _ = c.closedir(directory);
    var count: usize = 0;
    while (c.readdir(directory)) |entry| {
        const name = std.mem.sliceTo(entry.name[0..], 0);
        const parsed = parseName(name) orelse {
            if (looksManaged(name)) return error.InvalidResidue;
            continue;
        };
        if (count == out.len) return error.TooManyResidues;
        var name_buf: [80]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch
            return error.InvalidResidue;
        var stat: posix.Stat = undefined;
        if (c.fstatat(owner_fd, name_z.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0)
            return error.InvalidResidue;
        out[count] = .{ .kind = parsed.kind, .tomb = parsed.tomb, .id = parsed.id, .stat = stat };
        count += 1;
    }
    return count;
}

fn parseName(name: []const u8) ?struct { kind: Kind, tomb: bool, id: u128 } {
    const forms = [_]struct { prefix: []const u8, suffix: []const u8, kind: Kind, tomb: bool }{
        .{ .prefix = "attempt-", .suffix = "", .kind = .attempt, .tomb = false },
        .{ .prefix = ".sweep-attempt-", .suffix = "", .kind = .attempt, .tomb = true },
        .{ .prefix = "target-", .suffix = ".image", .kind = .target, .tomb = false },
        .{ .prefix = ".sweep-target-", .suffix = ".image", .kind = .target, .tomb = true },
    };
    for (forms) |form| {
        if (name.len != form.prefix.len + 32 + form.suffix.len or
            !std.mem.startsWith(u8, name, form.prefix) or
            !std.mem.endsWith(u8, name, form.suffix)) continue;
        const hex = name[form.prefix.len .. form.prefix.len + 32];
        for (hex) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return null;
        const id = std.fmt.parseInt(u128, hex, 16) catch return null;
        if (id == 0) return null;
        return .{ .kind = form.kind, .tomb = form.tomb, .id = id };
    }
    return null;
}

fn looksManaged(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "attempt-") or
        std.mem.startsWith(u8, name, ".sweep-attempt-") or
        std.mem.startsWith(u8, name, "target-") or
        std.mem.startsWith(u8, name, ".sweep-target-");
}

fn rejectCanonicalTombCollisions(candidates: []const Candidate) Error!void {
    for (candidates, 0..) |candidate, index| {
        for (candidates[index + 1 ..]) |other| {
            if (candidate.kind == other.kind and candidate.id == other.id)
                return error.InvalidResidue;
        }
    }
}

fn validateCandidate(owner_fd: c.fd_t, candidate: Candidate) Error!void {
    var name_buf: [80]u8 = undefined;
    const name = try candidateName(&name_buf, candidate.kind, candidate.tomb, candidate.id);
    switch (candidate.kind) {
        .attempt => {
            if (!validAttemptStat(candidate.stat)) return error.InvalidResidue;
            const fd = try openExactDirectory(owner_fd, name, candidate.stat);
            defer _ = c.close(fd);
            try validateAttemptChildren(fd);
        },
        .target => {
            if (!validTargetStat(candidate.stat)) return error.InvalidResidue;
            const fd = try openExactFile(owner_fd, name, candidate.stat, 0o700);
            _ = c.close(fd);
        },
    }
}

fn cleanupCandidate(owner_fd: c.fd_t, candidate: Candidate) Error!void {
    var source_buf: [80]u8 = undefined;
    var tomb_buf: [80]u8 = undefined;
    const source = try candidateName(&source_buf, candidate.kind, candidate.tomb, candidate.id);
    const tomb = try candidateName(&tomb_buf, candidate.kind, true, candidate.id);
    if (!candidate.tomb and renameatx_np(owner_fd, source.ptr, owner_fd, tomb.ptr, rename_excl) != 0)
        return error.CleanupFailed;

    switch (candidate.kind) {
        .target => {
            const fd = openExactFile(owner_fd, tomb, candidate.stat, 0o700) catch
                return error.CleanupFailed;
            defer _ = c.close(fd);
            if (c.unlinkat(owner_fd, tomb.ptr, 0) != 0) return error.CleanupFailed;
        },
        .attempt => {
            const fd = openExactDirectory(owner_fd, tomb, candidate.stat) catch
                return error.CleanupFailed;
            defer _ = c.close(fd);
            try cleanupAttemptChildren(fd);
            if (c.fsync(fd) != 0) return error.CleanupFailed;
            if (c.unlinkat(owner_fd, tomb.ptr, at_removedir) != 0) return error.CleanupFailed;
        },
    }
    if (c.fsync(owner_fd) != 0) return error.CleanupFailed;
}

fn validateAttemptChildren(attempt_fd: c.fd_t) Error!void {
    const scan_fd = c.dup(attempt_fd);
    if (scan_fd < 0) return error.InvalidResidue;
    const directory = c.fdopendir(scan_fd) orelse {
        _ = c.close(scan_fd);
        return error.InvalidResidue;
    };
    defer _ = c.closedir(directory);
    var seen: u4 = 0;
    while (c.readdir(directory)) |entry| {
        const name = std.mem.sliceTo(entry.name[0..], 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const bit = childBit(name) orelse return error.InvalidResidue;
        if (seen & bit != 0) return error.InvalidResidue;
        seen |= bit;
        var name_buf: [32]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return error.InvalidResidue;
        var stat: posix.Stat = undefined;
        if (c.fstatat(attempt_fd, name_z.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !validLeafStat(stat)) return error.InvalidResidue;
        const fd = try openExactFile(attempt_fd, name_z, stat, 0o600);
        _ = c.close(fd);
    }
}

fn cleanupAttemptChildren(attempt_fd: c.fd_t) Error!void {
    try validateAttemptChildren(attempt_fd);
    for ([_][]const u8{ "primary", "backup", ".sweep-primary", ".sweep-backup" }) |raw| {
        var source_buf: [32]u8 = undefined;
        const source = std.fmt.bufPrintZ(&source_buf, "{s}", .{raw}) catch unreachable;
        var stat: posix.Stat = undefined;
        if (c.fstatat(attempt_fd, source.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0) {
            if (posix.errno(-1) == .NOENT) continue;
            return error.CleanupFailed;
        }
        const is_tomb = std.mem.startsWith(u8, raw, ".sweep-");
        const base = if (is_tomb) raw[".sweep-".len..] else raw;
        var tomb_buf: [32]u8 = undefined;
        const tomb = std.fmt.bufPrintZ(&tomb_buf, ".sweep-{s}", .{base}) catch unreachable;
        if (!is_tomb and renameatx_np(attempt_fd, source.ptr, attempt_fd, tomb.ptr, rename_excl) != 0)
            return error.CleanupFailed;
        const fd = openExactFile(attempt_fd, tomb, stat, 0o600) catch return error.CleanupFailed;
        defer _ = c.close(fd);
        if (c.unlinkat(attempt_fd, tomb.ptr, 0) != 0) return error.CleanupFailed;
    }
}

fn childBit(name: []const u8) ?u4 {
    if (std.mem.eql(u8, name, "primary")) return 1;
    if (std.mem.eql(u8, name, "backup")) return 2;
    // canonical+tomb is an interrupted/corrupt double publication, not two independent leaves.
    if (std.mem.eql(u8, name, ".sweep-primary")) return 1;
    if (std.mem.eql(u8, name, ".sweep-backup")) return 2;
    return null;
}

fn candidateName(buf: []u8, kind: Kind, tomb: bool, id: u128) Error![:0]u8 {
    return switch (kind) {
        .attempt => if (tomb)
            std.fmt.bufPrintZ(buf, ".sweep-attempt-{x:0>32}", .{id})
        else
            std.fmt.bufPrintZ(buf, "attempt-{x:0>32}", .{id}),
        .target => if (tomb)
            std.fmt.bufPrintZ(buf, ".sweep-target-{x:0>32}.image", .{id})
        else
            std.fmt.bufPrintZ(buf, "target-{x:0>32}.image", .{id}),
    } catch error.InvalidResidue;
}

fn openExactDirectory(parent_fd: c.fd_t, name: [:0]const u8, expected: posix.Stat) Error!c.fd_t {
    const fd = c.openat(parent_fd, name.ptr, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
        .NOFOLLOW = true,
    }, @as(c.mode_t, 0));
    if (fd < 0) return error.InvalidResidue;
    errdefer _ = c.close(fd);
    var actual: posix.Stat = undefined;
    if (c.fstat(fd, &actual) != 0 or !sameIdentity(expected, actual) or !validAttemptStat(actual))
        return error.InvalidResidue;
    return fd;
}

fn openExactFile(parent_fd: c.fd_t, name: [:0]const u8, expected: posix.Stat, mode: c.mode_t) Error!c.fd_t {
    const fd = c.openat(parent_fd, name.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.InvalidResidue;
    errdefer _ = c.close(fd);
    var actual: posix.Stat = undefined;
    if (c.fstat(fd, &actual) != 0 or !sameIdentity(expected, actual) or
        !posix.S.ISREG(actual.mode) or actual.uid != c.getuid() or actual.mode & 0o777 != mode or actual.nlink != 1)
        return error.InvalidResidue;
    return fd;
}

fn validateOwnerDirectory(fd: c.fd_t) Error!void {
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISDIR(stat.mode) or stat.uid != c.getuid() or
        stat.mode & 0o777 != 0o700) return error.InvalidDirectory;
}

fn validAttemptStat(stat: posix.Stat) bool {
    return posix.S.ISDIR(stat.mode) and stat.uid == c.getuid() and stat.mode & 0o777 == 0o700;
}

fn validTargetStat(stat: posix.Stat) bool {
    return posix.S.ISREG(stat.mode) and stat.uid == c.getuid() and stat.mode & 0o777 == 0o700 and stat.nlink == 1;
}

fn validLeafStat(stat: posix.Stat) bool {
    return posix.S.ISREG(stat.mode) and stat.uid == c.getuid() and stat.mode & 0o777 == 0o600 and stat.nlink == 1;
}

fn sameIdentity(a: posix.Stat, b: posix.Stat) bool {
    return a.dev == b.dev and a.ino == b.ino and a.mode == b.mode and a.uid == b.uid and
        a.nlink == b.nlink and a.size == b.size;
}

fn createFile(dir_fd: c.fd_t, name: [:0]const u8, mode: c.mode_t) !void {
    const fd = c.openat(dir_fd, name.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, mode);
    if (fd < 0) return error.TestUnexpectedResult;
    _ = c.close(fd);
}

test "stale sweep removes exact attempts targets and interrupted tombs" {
    const io = std.testing.io;
    var root_buf: [192]u8 = undefined;
    const root = try test_scratch.open(io, &root_buf, "upgrade-stale-sweep");
    defer test_scratch.close(io, root);
    const root_fd = c.open(root.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    try std.testing.expect(root_fd >= 0);
    defer _ = c.close(root_fd);
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(root_fd, "attempt-00000000000000000000000000000001", 0o700));
    const attempt_fd = c.openat(root_fd, "attempt-00000000000000000000000000000001", .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    try std.testing.expect(attempt_fd >= 0);
    try createFile(attempt_fd, "primary", 0o600);
    try createFile(attempt_fd, ".sweep-backup", 0o600);
    _ = c.close(attempt_fd);
    try createFile(root_fd, "target-00000000000000000000000000000002.image", 0o700);
    try createFile(root_fd, ".sweep-target-00000000000000000000000000000003.image", 0o700);
    try createFile(root_fd, "unrelated", 0o600);

    const result = try sweep(root);
    try std.testing.expectEqual(@as(usize, 1), result.attempts);
    try std.testing.expectEqual(@as(usize, 2), result.targets);
    try std.testing.expect(c.faccessat(root_fd, "unrelated", c.F_OK, 0) == 0);
}

test "stale sweep rejects unknown children without mutation" {
    const io = std.testing.io;
    var root_buf: [192]u8 = undefined;
    const root = try test_scratch.open(io, &root_buf, "upgrade-stale-sweep-hostile");
    defer test_scratch.close(io, root);
    const root_fd = c.open(root.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    try std.testing.expect(root_fd >= 0);
    defer _ = c.close(root_fd);
    const attempt = "attempt-00000000000000000000000000000004";
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(root_fd, attempt, 0o700));
    const attempt_fd = c.openat(root_fd, attempt, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    try std.testing.expect(attempt_fd >= 0);
    try createFile(attempt_fd, "primary", 0o600);
    try createFile(attempt_fd, "foreign", 0o600);
    _ = c.close(attempt_fd);
    try std.testing.expectError(error.InvalidResidue, sweep(root));
    try std.testing.expect(c.faccessat(root_fd, attempt, c.F_OK, 0) == 0);
}

test "stale sweep rejects canonical tomb collision without mutation" {
    const io = std.testing.io;
    var root_buf: [192]u8 = undefined;
    const root = try test_scratch.open(io, &root_buf, "upgrade-stale-sweep-collision");
    defer test_scratch.close(io, root);
    const root_fd = c.open(root.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    try std.testing.expect(root_fd >= 0);
    defer _ = c.close(root_fd);
    const canonical = "target-00000000000000000000000000000005.image";
    const tomb = ".sweep-target-00000000000000000000000000000005.image";
    try createFile(root_fd, canonical, 0o700);
    try createFile(root_fd, tomb, 0o700);
    try std.testing.expectError(error.InvalidResidue, sweep(root));
    try std.testing.expect(c.faccessat(root_fd, canonical, c.F_OK, 0) == 0);
    try std.testing.expect(c.faccessat(root_fd, tomb, c.F_OK, 0) == 0);
}

test "stale sweep rejects managed malformed names symlinks and hard links" {
    const io = std.testing.io;
    var root_buf: [192]u8 = undefined;
    const root = try test_scratch.open(io, &root_buf, "upgrade-stale-sweep-shapes");
    defer test_scratch.close(io, root);
    const root_fd = c.open(root.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    try std.testing.expect(root_fd >= 0);
    defer _ = c.close(root_fd);
    try createFile(root_fd, "target-not-an-id.image", 0o700);
    try std.testing.expectError(error.InvalidResidue, sweep(root));
    try std.testing.expect(c.unlinkat(root_fd, "target-not-an-id.image", 0) == 0);

    const target = "target-00000000000000000000000000000006.image";
    try createFile(root_fd, target, 0o700);
    try std.testing.expect(c.linkat(root_fd, target, root_fd, "hardlink", 0) == 0);
    try std.testing.expectError(error.InvalidResidue, sweep(root));
    try std.testing.expect(c.unlinkat(root_fd, "hardlink", 0) == 0);
    try std.testing.expect(c.unlinkat(root_fd, target, 0) == 0);

    const attempt = "attempt-00000000000000000000000000000007";
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("unrelated", root_fd, attempt));
    try std.testing.expectError(error.InvalidResidue, sweep(root));
    try std.testing.expect(c.faccessat(root_fd, attempt, c.F_OK, posix.AT.SYMLINK_NOFOLLOW) == 0);
}
