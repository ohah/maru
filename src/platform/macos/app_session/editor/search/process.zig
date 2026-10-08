//! 디스크 helper의 수명. worker 스레드에서만 실행하며 stdout을 작은 조각으로 처리한다.
//! 취소와 종료 대기는 UI 스레드로 돌아가지 않는다. 호출자는 고정 번들 경로만 넘긴다.
const std = @import("std");
const search = @import("maru").session.editor.search;
const c = std.c;
const posix = std.posix;
pub const Control = struct { cancelled: std.atomic.Value(bool) = .init(false) };
pub const Outcome = enum { complete, cancelled, partial };
pub const Stats = struct { child_pid: ?c.pid_t = null, reaped: bool = false, bytes: usize = 0, reads: usize = 0, first_output_ms: ?i64 = null, elapsed_ms: i64 = 0, exit: ?u8 = null };
pub const Timing = struct { execution_ms: i64, reap_ms: i64 };

pub const Root = struct {
    canonical: [:0]u8,
    directory: std.Io.Dir,
    stat: std.Io.Dir.Stat,
    device: @TypeOf(@as(std.posix.Stat, undefined).dev),
    pub fn deinit(self: *Root, a: std.mem.Allocator, io: std.Io) void {
        self.directory.close(io);
        a.free(self.canonical);
    }
};
pub fn openRoot(a: std.mem.Allocator, io: std.Io, path: []const u8) !Root {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidRoot;
    const normalized = try std.fs.path.resolve(a, &.{path});
    defer a.free(normalized);
    try rejectVcsRoot(normalized);
    const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, a);
    errdefer a.free(canonical);
    try rejectVcsRoot(canonical);
    const directory = try std.Io.Dir.openDirAbsolute(io, canonical, .{});
    errdefer directory.close(io);
    var native: std.posix.Stat = undefined;
    if (c.fstat(directory.handle, &native) != 0) return error.StatFailed;
    return .{ .canonical = canonical, .directory = directory, .stat = try directory.stat(io), .device = native.dev };
}

/// 메타데이터 준비 동안 root가 교체되었다면 모델 행도 게시하지 않는다.
pub fn validateRoot(io: std.Io, root: *Root) !void {
    const current = std.Io.Dir.cwd().statFile(io, root.canonical, .{}) catch return error.RootChanged;
    if (current.inode != root.stat.inode or current.kind != .directory or !sameDevice(root)) return error.RootChanged;
}

/// callback 오류·본문 상한·취소·시간 초과는 모두 helper를 거둔 뒤 반환한다.
pub fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, environment: *const std.process.Environ.Map, root: *const Root, control: *Control, timing: Timing, event_bytes: usize, context: anytype, callback: anytype, stats: *Stats) !Outcome {
    if (control.cancelled.load(.acquire)) return .cancelled;
    if (timing.execution_ms <= 0 or timing.reap_ms <= 0) return error.InvalidTiming;
    const canonical = root.canonical;
    const directory = root.directory;
    const initial = root.stat;
    const before = try std.Io.Dir.cwd().statFile(io, canonical, .{});
    if (before.inode != initial.inode or before.kind != .directory or !sameDevice(root)) return error.RootChanged;
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = environment, .cwd = .{ .dir = directory }, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore });
    const pid = child.id.?;
    stats.child_pid = pid;
    const fd = child.stdout.?.handle;
    defer child.stdout.?.close(io);
    var reaped = false;
    defer if (!reaped) {
        _ = c.kill(pid, posix.SIG.KILL);
        // 오류 뒤에도 유한 기한으로 수거한다. 정상 경로는 아래에서 NOHANG으로 수거한다.
        const cleanup = std.Io.Timestamp.now(io, .awake);
        var status: c_int = 0;
        while (cleanup.untilNow(io, .awake).toMilliseconds() < timing.reap_ms) {
            const result = c.waitpid(pid, &status, c.W.NOHANG);
            if (result == pid or (result < 0 and posix.errno(result) == .CHILD)) {
                stats.reaped = true;
                break;
            }
            _ = c.poll(@constCast(&[_]std.posix.pollfd{}), 0, 1);
        }
    };
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0 or c.fcntl(fd, c.F.SETFL, flags | @as(c_int, @bitCast(posix.O{ .NONBLOCK = true }))) < 0) return error.NonblockingFailed;
    var stream: search.stream.Stream = .{ .max_event_bytes = event_bytes };
    defer stream.deinit(a);
    var buffer: [16 * 1024]u8 = undefined;
    var eof = false;
    var stopping: ?Outcome = null;
    const started = std.Io.Timestamp.now(io, .awake);
    var stop_time: ?std.Io.Timestamp = null;
    while (true) {
        const elapsed = started.untilNow(io, .awake).toMilliseconds();
        stats.elapsed_ms = elapsed;
        if (stopping == null and (control.cancelled.load(.acquire) or elapsed >= timing.execution_ms)) {
            stopping = if (control.cancelled.load(.acquire)) .cancelled else .partial;
            _ = c.kill(pid, posix.SIG.KILL);
            stop_time = std.Io.Timestamp.now(io, .awake);
        }
        if (!eof and stopping == null) {
            const n = c.read(fd, &buffer, buffer.len);
            if (n > 0) {
                stats.bytes += @intCast(n);
                stats.reads += 1;
                if (stats.first_output_ms == null) stats.first_output_ms = elapsed;
                try stream.consume(a, buffer[0..@intCast(n)], context, callback);
                // 출력이 계속 나와도 취소·deadline을 각 조각 사이에서 확인한다.
                continue;
            }
            if (n == 0) {
                eof = true;
                try stream.finish();
            } else if (posix.errno(n) != .AGAIN and posix.errno(n) != .INTR) return error.ReadFailed;
        }
        var status: c_int = 0;
        // stdout을 먼저 비운다. 종료가 먼저 관측되어도 pipe에 남은 결과를 버리지 않는다.
        if (eof or stopping != null) {
            const result = c.waitpid(pid, &status, c.W.NOHANG);
            if (result == pid) {
                reaped = true;
                stats.reaped = true;
                const current = std.Io.Dir.cwd().statFile(io, canonical, .{}) catch return error.RootChanged;
                if (current.inode != initial.inode or current.kind != .directory or !sameDevice(root)) return error.RootChanged;
                if (stopping) |outcome| return outcome;
                if (!c.W.IFEXITED(@intCast(status))) return error.HelperTerminated;
                const code: u8 = @intCast(c.W.EXITSTATUS(@intCast(status)));
                stats.exit = code;
                return if (code <= 1) .complete else .partial;
            }
            if (result < 0 and posix.errno(result) != .INTR) return error.WaitFailed;
        }
        if (stop_time) |time| if (time.untilNow(io, .awake).toMilliseconds() >= timing.reap_ms) return error.ReapDeadline;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        _ = c.poll(&fds, if (eof or stopping != null) 0 else 1, 5);
    }
}

fn sameDevice(root: *const Root) bool {
    var native: std.posix.Stat = undefined;
    return c.fstatat(std.posix.AT.FDCWD, root.canonical.ptr, &native, 0) == 0 and native.dev == root.device;
}

fn rejectVcsRoot(path: []const u8) !void {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        for ([_][]const u8{ ".git", ".hg", ".svn", "CVS" }) |vcs| if (std.mem.eql(u8, component, vcs)) return error.VcsRoot;
    }
}

test "EDPSROOT1 메타데이터 뒤 root 교체는 열린 옛 handle과 새 경로를 구분한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var fixture = std.testing.tmpDir(.{});
    defer fixture.cleanup();
    try fixture.dir.createDir(io, "root", .default_dir);
    var child = try fixture.dir.openDir(io, "root", .{});
    defer child.close(io);
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const name = path[0..try child.realPath(io, &path)];
    var root = try openRoot(a, io, name);
    defer root.deinit(a, io);
    try validateRoot(io, &root);
    try fixture.dir.rename("root", fixture.dir, "old", io);
    try fixture.dir.createDir(io, "root", .default_dir);
    try std.testing.expectError(error.RootChanged, validateRoot(io, &root));
    try std.testing.expectEqual(root.stat.inode, (try root.directory.stat(io)).inode);
}
