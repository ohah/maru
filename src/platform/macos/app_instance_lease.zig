//! Maru GUI process lifetime lease.
//!
//! Workspace manifest를 atomic replace해도 writer 권위가 바뀌지 않도록 manifest 자체가 아닌
//! sibling `workspace.v1.lock` inode를 잠근다. 실제 secure open·metadata·flock 규칙은 session
//! host의 검증된 `OwnerLease` primitive를 재사용하되, 이 wrapper는 unlink/adopt를 노출하지 않는다.
//! GUI lease는 exec migration 대상이 아니며 process가 끝날 때 kernel이 fd와 lock을 함께 회수한다.

const std = @import("std");
const owner_lease = @import("session_host/owner_lease.zig");
const libc = @cImport({
    @cInclude("stdlib.h");
});

const c = std.c;
const posix = std.posix;

pub const Error = error{
    AlreadyOwned,
    UnsafeLock,
    IoFailure,
};

pub const AppInstanceLease = struct {
    inner: owner_lease.OwnerLease,

    pub fn acquire(path: [:0]const u8) Error!AppInstanceLease {
        const inner = owner_lease.OwnerLease.acquire(path) catch |err| return switch (err) {
            error.AlreadyOwned => error.AlreadyOwned,
            error.InvalidOwnerFile => error.UnsafeLock,
            error.OpenFailed, error.LockFailed, error.FcntlFailed, error.CleanupFailed => error.IoFailure,
        };
        var result: AppInstanceLease = .{ .inner = inner };
        const flags = c.fcntl(result.inner.descriptor(), c.F.GETFD, @as(c_int, 0));
        if (flags < 0 or flags & c.FD_CLOEXEC == 0) {
            result.deinit();
            return error.IoFailure;
        }
        return result;
    }

    pub fn deinit(self: *AppInstanceLease) void {
        self.inner.deinit();
    }

    fn descriptor(self: *const AppInstanceLease) c.fd_t {
        return self.inner.descriptor();
    }
};

fn createRegular(path: [:0]const u8, mode: c.mode_t) !void {
    const fd = c.open(
        path.ptr,
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        mode,
    );
    if (fd < 0) return error.CreateFailed;
    if (c.fchmod(fd, mode) != 0) {
        _ = c.close(fd);
        return error.ChmodFailed;
    }
    _ = c.close(fd);
}

fn readFull(fd: c.fd_t, buffer: []u8) bool {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const count = c.read(fd, buffer[offset..].ptr, buffer.len - offset);
        if (count <= 0) return false;
        offset += @intCast(count);
    }
    return true;
}

test "app instance lease is exclusive CLOEXEC and keeps the lock pathname" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/private/tmp/maru-app-lease-basic-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    var lease = try AppInstanceLease.acquire(path);
    try std.testing.expect(c.fcntl(lease.descriptor(), c.F.GETFD, @as(c_int, 0)) & c.FD_CLOEXEC != 0);
    try std.testing.expectError(error.AlreadyOwned, AppInstanceLease.acquire(path));

    var stat: posix.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW));
    try std.testing.expect(posix.S.ISREG(stat.mode));
    try std.testing.expectEqual(@as(posix.mode_t, 0o600), stat.mode & 0o777);

    lease.deinit();
    // 정상 종료는 lock file을 지우지 않는다. 다음 process는 같은 inode를 다시 잠근다.
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW));
    var reacquired = try AppInstanceLease.acquire(path);
    reacquired.deinit();
}

test "fresh app instance lease forces exact mode under a restrictive umask" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/private/tmp/maru-app-lease-umask-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    const previous_umask = c.umask(0o777);
    defer _ = c.umask(previous_umask);
    var lease = try AppInstanceLease.acquire(path);
    defer lease.deinit();

    var stat: posix.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstat(lease.descriptor(), &stat));
    try std.testing.expectEqual(@as(posix.mode_t, 0o600), stat.mode & 0o777);
}

test "two fresh processes racing the same leaf elect exactly one winner" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/private/tmp/maru-app-lease-race-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    var start: [2]c_int = undefined;
    var result: [2]c_int = undefined;
    var hold: [2]c_int = undefined;
    if (c.pipe(&start) != 0 or c.pipe(&result) != 0 or c.pipe(&hold) != 0)
        return error.SkipZigTest;
    const previous_umask = c.umask(0o777);
    defer _ = c.umask(previous_umask);
    var children: [2]c.pid_t = undefined;
    for (&children) |*child_slot| {
        const child = c.fork();
        if (child < 0) return error.SkipZigTest;
        child_slot.* = child;
        if (child == 0) {
            _ = c.close(start[1]);
            _ = c.close(result[0]);
            _ = c.close(hold[1]);
            var byte: [1]u8 = undefined;
            if (c.read(start[0], &byte, byte.len) != byte.len) c._exit(2);
            var lease = AppInstanceLease.acquire(path) catch |err| {
                const outcome = [_]u8{if (err == error.AlreadyOwned) 'L' else 'E'};
                _ = c.write(result[1], &outcome, outcome.len);
                c._exit(if (err == error.AlreadyOwned) 0 else 3);
            };
            const outcome = [_]u8{'W'};
            if (c.write(result[1], &outcome, outcome.len) != outcome.len) c._exit(4);
            _ = c.read(hold[0], &byte, byte.len);
            lease.deinit();
            c._exit(0);
        }
    }
    _ = c.close(start[0]);
    _ = c.close(result[1]);
    _ = c.close(hold[0]);
    defer _ = c.close(start[1]);
    defer _ = c.close(result[0]);
    defer _ = c.close(hold[1]);

    const release = [_]u8{ 1, 1 };
    try std.testing.expectEqual(@as(isize, release.len), c.write(start[1], &release, release.len));
    var outcomes: [2]u8 = undefined;
    try std.testing.expect(readFull(result[0], &outcomes));
    const winners = @intFromBool(outcomes[0] == 'W') + @intFromBool(outcomes[1] == 'W');
    const losers = @intFromBool(outcomes[0] == 'L') + @intFromBool(outcomes[1] == 'L');
    try std.testing.expectEqual(@as(u2, 1), winners);
    try std.testing.expectEqual(@as(u2, 1), losers);
    _ = c.close(hold[1]);
    hold[1] = -1;
    for (children) |child| {
        var status: c_int = undefined;
        try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
    }
}

test "app instance lease rejects symlink non-regular and wrong mode" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    var base_buf: [256]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/private/tmp/maru-app-lease-invalid-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    if (c.mkdir(base.ptr, 0o700) != 0) return error.SkipZigTest;
    if (c.chmod(base.ptr, 0o700) != 0) return error.ChmodFailed;
    defer _ = c.rmdir(base.ptr);

    var target_buf: [320]u8 = undefined;
    const target = try std.fmt.bufPrintZ(&target_buf, "{s}/target", .{base});
    var link_buf: [320]u8 = undefined;
    const link = try std.fmt.bufPrintZ(&link_buf, "{s}/workspace.v1.lock", .{base});
    try createRegular(target, 0o600);
    defer _ = c.unlink(target.ptr);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(target.ptr, link.ptr));
    try std.testing.expectError(error.UnsafeLock, AppInstanceLease.acquire(link));
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(link.ptr));

    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(link.ptr, 0o600));
    try std.testing.expectError(error.UnsafeLock, AppInstanceLease.acquire(link));
    try std.testing.expectEqual(@as(c_int, 0), c.rmdir(link.ptr));

    try createRegular(link, 0o644);
    try std.testing.expectError(error.UnsafeLock, AppInstanceLease.acquire(link));
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(link.ptr));

    try createRegular(link, 0o644);
    var ready: [2]c_int = undefined;
    var hold: [2]c_int = undefined;
    if (c.pipe(&ready) != 0 or c.pipe(&hold) != 0) return error.SkipZigTest;
    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.close(ready[0]);
        _ = c.close(hold[1]);
        const fd = c.open(link.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
        if (fd < 0 or c.flock(fd, c.LOCK.EX) != 0) c._exit(2);
        const byte = [_]u8{1};
        _ = c.write(ready[1], &byte, byte.len);
        var ignored: [1]u8 = undefined;
        _ = c.read(hold[0], &ignored, ignored.len);
        c._exit(0);
    }
    _ = c.close(ready[1]);
    _ = c.close(hold[0]);
    var byte: [1]u8 = undefined;
    try std.testing.expect(readFull(ready[0], &byte));
    try std.testing.expectError(error.UnsafeLock, AppInstanceLease.acquire(link));
    _ = c.close(hold[1]);
    var status: c_int = undefined;
    try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
    _ = c.close(ready[0]);
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(link.ptr));
}

test "manifest atomic replace cannot bypass the sibling lease" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    var lock_buf: [256]u8 = undefined;
    const lock = std.fmt.bufPrintZ(&lock_buf, "/private/tmp/maru-app-lease-replace-{d}.lock", .{c.getpid()}) catch
        return error.SkipZigTest;
    var manifest_buf: [256]u8 = undefined;
    const manifest = try std.fmt.bufPrintZ(&manifest_buf, "/private/tmp/maru-app-lease-replace-{d}.v1", .{c.getpid()});
    var temp_buf: [256]u8 = undefined;
    const temp = try std.fmt.bufPrintZ(&temp_buf, "/private/tmp/maru-app-lease-replace-{d}.tmp", .{c.getpid()});
    _ = c.unlink(lock.ptr);
    _ = c.unlink(manifest.ptr);
    _ = c.unlink(temp.ptr);
    defer {
        _ = c.unlink(lock.ptr);
        _ = c.unlink(manifest.ptr);
        _ = c.unlink(temp.ptr);
    }

    var lease = try AppInstanceLease.acquire(lock);
    defer lease.deinit();
    try createRegular(manifest, 0o600);
    try createRegular(temp, 0o600);

    var start: [2]c_int = undefined;
    var result: [2]c_int = undefined;
    if (c.pipe(&start) != 0 or c.pipe(&result) != 0) return error.SkipZigTest;
    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.close(start[1]);
        _ = c.close(result[0]);
        var byte: [1]u8 = undefined;
        if (c.read(start[0], &byte, byte.len) != byte.len) c._exit(2);
        var competitor = AppInstanceLease.acquire(lock) catch |err| {
            const outcome = [_]u8{if (err == error.AlreadyOwned) 'L' else 'E'};
            _ = c.write(result[1], &outcome, outcome.len);
            c._exit(if (outcome[0] == 'L') 0 else 3);
        };
        competitor.deinit();
        const outcome = [_]u8{'W'};
        _ = c.write(result[1], &outcome, outcome.len);
        c._exit(3);
    }
    _ = c.close(start[0]);
    _ = c.close(result[1]);
    defer _ = c.close(start[1]);
    defer _ = c.close(result[0]);
    const release = [_]u8{1};
    try std.testing.expectEqual(@as(isize, 1), c.write(start[1], &release, release.len));
    try std.testing.expectEqual(@as(c_int, 0), c.rename(temp.ptr, manifest.ptr));
    var outcome: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), c.read(result[0], &outcome, outcome.len));
    try std.testing.expectEqual(@as(u8, 'L'), outcome[0]);
    var status: c_int = undefined;
    try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
}

test "SIGKILL releases the winner lease for a new process" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/private/tmp/maru-app-lease-kill-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    var ready: [2]c_int = undefined;
    if (c.pipe(&ready) != 0) return error.SkipZigTest;
    var hold: [2]c_int = undefined;
    if (c.pipe(&hold) != 0) {
        _ = c.close(ready[0]);
        _ = c.close(ready[1]);
        return error.SkipZigTest;
    }
    const child = c.fork();
    if (child < 0) {
        _ = c.close(ready[0]);
        _ = c.close(ready[1]);
        _ = c.close(hold[0]);
        _ = c.close(hold[1]);
        return error.SkipZigTest;
    }
    if (child == 0) {
        _ = c.close(ready[0]);
        _ = c.close(hold[1]);
        var lease = AppInstanceLease.acquire(path) catch c._exit(2);
        const byte = [_]u8{1};
        if (c.write(ready[1], &byte, byte.len) != byte.len) c._exit(3);
        // parent가 write end를 닫거나 process를 종료할 때까지 block한다. 시간 기반 sleep을
        // 쓰지 않아 winner 준비와 SIGKILL 순서가 결정적이다.
        var ignored: [1]u8 = undefined;
        _ = c.read(hold[0], &ignored, ignored.len);
        lease.deinit();
        c._exit(0);
    }

    _ = c.close(ready[1]);
    _ = c.close(hold[0]);
    defer _ = c.close(ready[0]);
    defer _ = c.close(hold[1]);
    var byte: [1]u8 = undefined;
    if (c.read(ready[0], &byte, byte.len) != byte.len) {
        _ = c.kill(child, posix.SIG.KILL);
        var failed_status: c_int = undefined;
        _ = c.waitpid(child, &failed_status, 0);
        return error.ChildNotReady;
    }
    try std.testing.expectError(error.AlreadyOwned, AppInstanceLease.acquire(path));
    try std.testing.expectEqual(@as(c_int, 0), c.kill(child, posix.SIG.KILL));
    var status: c_int = undefined;
    try std.testing.expectEqual(child, c.waitpid(child, &status, 0));

    var reacquired = try AppInstanceLease.acquire(path);
    reacquired.deinit();
}

test "CLOEXEC keeps an exec descendant from retaining the winner lease" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/private/tmp/maru-app-lease-exec-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);

    var ready: [2]c_int = undefined;
    if (c.pipe(&ready) != 0) return error.SkipZigTest;
    const holder = c.fork();
    if (holder < 0) return error.SkipZigTest;
    if (holder == 0) {
        _ = c.close(ready[0]);
        var lease = AppInstanceLease.acquire(path) catch c._exit(2);
        var command_buf: [128]u8 = undefined;
        const command = std.fmt.bufPrintZ(
            &command_buf,
            "printf '%d\\n' $$ >&{d}; exec /bin/sleep 30",
            .{ready[1]},
        ) catch c._exit(3);
        _ = libc.system(command.ptr);
        lease.deinit();
        c._exit(4);
    }
    _ = c.close(ready[1]);
    defer _ = c.close(ready[0]);

    var pid_text: [32]u8 = undefined;
    var pid_len: usize = 0;
    while (pid_len < pid_text.len) {
        const count = c.read(ready[0], pid_text[pid_len..].ptr, 1);
        if (count != 1) {
            _ = c.kill(holder, posix.SIG.KILL);
            return error.DescendantNotReady;
        }
        if (pid_text[pid_len] == '\n') break;
        pid_len += 1;
    }
    const descendant = std.fmt.parseInt(c.pid_t, pid_text[0..pid_len], 10) catch
        return error.InvalidDescendantPid;
    try std.testing.expect(descendant > 0);
    try std.testing.expectEqual(@as(c_int, 0), c.kill(descendant, @enumFromInt(0)));

    try std.testing.expectEqual(@as(c_int, 0), c.kill(holder, posix.SIG.KILL));
    var status: c_int = undefined;
    try std.testing.expectEqual(holder, c.waitpid(holder, &status, 0));
    defer {
        _ = c.kill(descendant, posix.SIG.KILL);
        _ = c.waitpid(descendant, &status, 0);
    }
    // exec된 sleep가 살아 있는 동안에도 holder만 끝나면 lease를 얻어야 한다. fd가
    // exec에 새었다면 이 acquire는 AlreadyOwned로 실패한다.
    var reacquired = try AppInstanceLease.acquire(path);
    reacquired.deinit();
}
