//! Staged upgrade image가 현재 release와 같은 Apple-designated requirement를 갖는지 검증한다.
//!
//! macOS에는 pathname exec만 있으므로 arbitrary same-UID executable을 승인하지 않는다. 두 image 모두 strict codesign
//! 검증을 통과하고 current requirement가 Apple certificate/team을 포함하며 exact requirement가 같아야 한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const upgrade_target = @import("upgrade_target.zig");

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const codesign_path: [:0]const u8 = "/usr/bin/codesign";
const capture_cap: usize = 16 * 1024;
const timeout_ns: i128 = 2 * std.time.ns_per_s;
const poll_quantum_ms: c_int = 50;

pub const Authorizer = struct {
    io: std.Io,
    current_executable: [:0]const u8,

    pub fn ops(self: *Authorizer) upgrade_target.Authorizer {
        return .{ .ctx = self, .allowed = allowedOpaque };
    }

    fn allowedOpaque(ctx: *anyopaque, staged_path: [:0]const u8) bool {
        const self: *Authorizer = @ptrCast(@alignCast(ctx));
        return sameReleaseSigner(self.io, self.current_executable, staged_path);
    }
};

pub fn sameReleaseSigner(io: std.Io, current: [:0]const u8, target: [:0]const u8) bool {
    if (!verify(io, current) or !verify(io, target)) return false;
    var current_buf: [capture_cap]u8 = undefined;
    const current_output = requirement(io, current, &current_buf) orelse return false;
    const current_line = requirementLine(current_output) orelse return false;
    if (!releaseRequirement(current_line)) return false;
    var target_buf: [capture_cap]u8 = undefined;
    const target_output = requirement(io, target, &target_buf) orelse return false;
    const target_line = requirementLine(target_output) orelse return false;
    return std.mem.eql(u8, current_line, target_line);
}

/// Release E2E artifact가 pathname 없이 어떤 designated requirement를 검증했는지 남길 비민감 fingerprint.
/// 승인 자체는 `sameReleaseSigner`의 exact line equality가 소유하며 이 digest로 대체하지 않는다.
pub fn releaseRequirementDigest(io: std.Io, executable: [:0]const u8) ?[32]u8 {
    if (!verify(io, executable)) return null;
    var output: [capture_cap]u8 = undefined;
    const line = requirementLine(requirement(io, executable, &output) orelse return null) orelse return null;
    if (!releaseRequirement(line)) return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(line, &digest, .{});
    return digest;
}

fn verify(io: std.Io, path: [:0]const u8) bool {
    var output: [capture_cap]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{
        codesign_path.ptr,
        "--verify",
        "--strict",
        "--verbose=0",
        path.ptr,
    };
    return runCapture(io, codesign_path, &argv, &output, timeout_ns) != null;
}

fn requirement(io: std.Io, path: [:0]const u8, output: *[capture_cap]u8) ?[]const u8 {
    const argv = [_:null]?[*:0]const u8{
        codesign_path.ptr,
        "-d",
        "-r-",
        "--verbose=0",
        path.ptr,
    };
    return runCapture(io, codesign_path, &argv, output, timeout_ns);
}

fn runCapture(
    io: std.Io,
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    output: *[capture_cap]u8,
    budget_ns: i128,
) ?[]const u8 {
    if (budget_ns <= 0) return null;
    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return null;
    if (!setCloseOnExec(pipe_fds[0]) or !setCloseOnExec(pipe_fds[1])) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return null;
    }
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return null;
    }
    if (pid == 0) {
        if (c.dup2(pipe_fds[1], 1) < 0 or c.dup2(pipe_fds[1], 2) < 0) c._exit(126);
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        _ = execv(executable.ptr, argv);
        c._exit(126);
    }
    _ = c.close(pipe_fds[1]);
    var used: usize = 0;
    var eof = false;
    var child_reaped = false;
    var status: c_int = undefined;
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    const deadline = std.math.add(i128, start, budget_ns) catch std.math.maxInt(i128);
    var valid = true;
    while (!(eof and child_reaped)) {
        if (!child_reaped) switch (pollChild(pid, &status)) {
            .running => {},
            .reaped => child_reaped = true,
            .failed => {
                valid = false;
                break;
            },
        };
        if (eof and child_reaped) break;
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        if (now >= deadline) {
            valid = false;
            break;
        }
        const remaining_ms = @divTrunc(deadline - now + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        const wait_ms: c_int = @intCast(@min(remaining_ms, poll_quantum_ms));
        var fds = [_]c.pollfd{.{
            .fd = if (eof) -1 else pipe_fds[0],
            .events = c.POLL.IN,
            .revents = 0,
        }};
        const rc = c.poll(&fds, if (eof) 0 else 1, wait_ms);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            valid = false;
            break;
        }
        if (rc == 0 or eof) continue;
        if (fds[0].revents & (c.POLL.IN | c.POLL.HUP) == 0) break;
        if (used == output.len) {
            valid = false;
            break;
        }
        const count = c.read(pipe_fds[0], output.ptr + used, output.len - used);
        if (count < 0) {
            if (posix.errno(count) == .INTR) continue;
            valid = false;
            break;
        }
        if (count == 0) {
            eof = true;
            continue;
        }
        used += @intCast(count);
    }
    _ = c.close(pipe_fds[0]);
    if (!child_reaped) {
        _ = c.kill(pid, c.SIG.KILL);
        if (!reapChild(pid, &status)) return null;
        child_reaped = true;
    }
    if (!valid or !eof or !child_reaped or status != 0) return null;
    return output[0..used];
}

fn setCloseOnExec(fd: c.fd_t) bool {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    return flags >= 0 and c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) == 0;
}

const ChildPoll = enum { running, reaped, failed };

fn pollChild(pid: c.pid_t, status: *c_int) ChildPoll {
    while (true) {
        const rc = c.waitpid(pid, status, c.W.NOHANG);
        if (rc == pid) return .reaped;
        if (rc == 0) return .running;
        if (posix.errno(rc) != .INTR) return .failed;
    }
}

fn reapChild(pid: c.pid_t, status: *c_int) bool {
    while (true) {
        const rc = c.waitpid(pid, status, 0);
        if (rc == pid) return true;
        if (rc >= 0 or posix.errno(rc) != .INTR) return false;
    }
}

fn requirementLine(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "designated =>")) return line;
    }
    return null;
}

fn releaseRequirement(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "anchor apple") != null and
        std.mem.indexOf(u8, line, "certificate leaf[subject.OU]") != null;
}

test "code signature requirement parser accepts only Apple team-designated lines" {
    const release =
        \\Executable=/Applications/Maru.app/Contents/MacOS/maru
        \\designated => identifier "com.ohah.maru" and anchor apple generic and certificate leaf[subject.OU] = "2MS57VWFU8"
    ;
    const line = requirementLine(release).?;
    try std.testing.expect(releaseRequirement(line));
    try std.testing.expect(!releaseRequirement(
        "designated => identifier \"maru\" and cdhash H\"001122\"",
    ));
    try std.testing.expect(requirementLine("Executable=/tmp/no-requirement") == null);
}

test "code signature child runner captures output and enforces monotonic timeout after pipe EOF" {
    var output: [capture_cap]u8 = undefined;
    const shell: [:0]const u8 = "/bin/sh";
    const success = [_:null]?[*:0]const u8{
        shell.ptr,
        "-c",
        "printf ok",
    };
    try std.testing.expectEqualStrings(
        "ok",
        runCapture(std.testing.io, shell, &success, &output, std.time.ns_per_s).?,
    );

    const hangs_after_eof = [_:null]?[*:0]const u8{
        shell.ptr,
        "-c",
        "exec 1>&- 2>&-; exec /bin/sleep 10",
    };
    const start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    try std.testing.expect(
        runCapture(std.testing.io, shell, &hangs_after_eof, &output, 50 * std.time.ns_per_ms) == null,
    );
    const elapsed = std.Io.Clock.awake.now(std.testing.io).nanoseconds - start;
    try std.testing.expect(elapsed >= 30 * std.time.ns_per_ms);
    try std.testing.expect(elapsed < std.time.ns_per_s);
}
