//! CR2e-e3a2 ReleaseFast child-process RSS gate.
//! 측정 대상은 test runner 부모가 아니라 exec 뒤 실제 reconnect generation workload를
//! 소유하는 별도 PID다. FD 198은 고정 scalar transcript와 one-byte command만 운반한다.

const std = @import("std");
const remote_runtime = @import("remote_runtime");
const mac = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/proc_info.h");
});

const c = std.c;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn getdtablesize() c_int;
extern "c" fn arc4random_buf(buffer: *anyopaque, length: usize) void;
const child_fd: c.fd_t = 198;
const sentinel_fd: c.fd_t = 197;
const marker_name = "MARU_CR2E_E3A2_RSS_CHILD";
const sample_count = 7;
const measurement_tolerance_bytes: u64 = 64 * 1024 * 1024;
const deadline_ms: u64 = 10_000;
const artifact_path = "tests/artifacts/perf/session-host-reconnect-rss-macos.json";
const sol_local: c_int = 0;
const local_peerpid: c_int = 2;

const ChildArtifact = if (@import("builtin").is_test) struct {
    pub export var maru_cr2e_e3a2_rss_child_path: [1024]u8 = [_]u8{0} ** 1024;
    pub export var maru_cr2e_e3a2_rss_child_path_len: usize = 0;
} else struct {};

const Stage = enum(u8) { baseline = 1, pressure = 2, final_zero = 3 };

const Report = extern struct {
    run_nonce: [16]u8,
    pid: u32,
    stage_raw: u8,
    inherited_fd_closed: u8,
    reserved: [2]u8,
    generation_count: u64,
    live_bytes: u64,
    peak_bytes: u64,
    live_allocations: u64,
    peak_allocations: u64,

    fn valid(self: Report, expected: Stage, nonce: [16]u8) bool {
        return std.mem.eql(u8, &self.run_nonce, &nonce) and self.pid != 0 and
            self.stage_raw == @intFromEnum(expected) and
            self.inherited_fd_closed == 1 and
            std.mem.eql(u8, &self.reserved, &[_]u8{0} ** 2) and
            self.peak_bytes >= self.live_bytes and
            self.peak_allocations >= self.live_allocations;
    }
};

const RssSample = struct {
    resident: u64,
    footprint: u64,
    start_abstime: u64,
};

const SampleSet = struct {
    samples: [sample_count]RssSample,
    median: RssSample,
};

const Artifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    sample_api: []const u8,
    run_nonce: [16]u8,
    executable_path: []const u8,
    inherited_fd_closed: bool,
    child_pid: u32,
    child_start_abstime: u64,
    sample_count: u32,
    owner_count: u64,
    max_entry_bytes: u64,
    max_tracked_bytes: u64,
    baseline_samples: [sample_count]RssSample,
    pressure_samples: [sample_count]RssSample,
    baseline_generation_count: u64,
    pressure_generation_count: u64,
    baseline_logical_bytes: u64,
    pressure_logical_bytes: u64,
    logical_delta_bytes: u64,
    baseline_rss_bytes: u64,
    pressure_rss_bytes: u64,
    rss_delta_bytes: u64,
    baseline_footprint_bytes: u64,
    pressure_footprint_bytes: u64,
    footprint_delta_bytes: u64,
    measurement_tolerance_bytes: u64,
    allowed_delta_bytes: u64,
    final_generation_count: u64,
    final_logical_bytes: u64,
    final_live_allocations: u64,
    child_exit_code: u8,
};

fn parseNonce(raw: []const u8) ?[16]u8 {
    if (raw.len != 32) return null;
    var out: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, raw) catch return null;
    if (std.mem.allEqual(u8, &out, 0)) return null;
    return out;
}

fn childNonce() ?[16]u8 {
    const value = std.c.getenv(marker_name) orelse return null;
    return parseNonce(std.mem.span(value));
}

fn writeExact(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const wrote = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (wrote <= 0) return error.TestUnexpectedResult;
        offset += @intCast(wrote);
    }
}

fn unlinkArtifact() !void {
    const artifact_z = try std.testing.allocator.dupeZ(u8, artifact_path);
    defer std.testing.allocator.free(artifact_z);
    const result = c.unlink(artifact_z.ptr);
    if (result != 0 and std.posix.errno(result) != .NOENT)
        return error.TestUnexpectedResult;
}

fn terminateAndReap(pid: c.pid_t, reaped: *bool) !u32 {
    var sent_kill = false;
    var polls: usize = 0;
    while (polls < 1_000) : (polls += 1) {
        var status: c_int = 0;
        const waited = c.waitpid(pid, &status, c.W.NOHANG);
        if (waited == pid) {
            reaped.* = true;
            return @bitCast(status);
        }
        if (waited < 0) {
            if (std.posix.errno(waited) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        if (!sent_kill) {
            const killed = c.kill(pid, c.SIG.KILL);
            if (killed != 0) switch (std.posix.errno(killed)) {
                .INTR => continue,
                .SRCH => {},
                else => return error.TestUnexpectedResult,
            };
            sent_kill = true;
        }
        _ = usleep(1_000);
    }
    return error.TestUnexpectedResult;
}

fn readExact(fd: c.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const got = c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (got <= 0) return error.TestUnexpectedResult;
        offset += @intCast(got);
    }
}

fn monotonicMs() !u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0)
        return error.TestUnexpectedResult;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn readExactDeadline(fd: c.fd_t, bytes: []u8, deadline: u64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const now = try monotonicMs();
        if (now >= deadline) return error.TestUnexpectedResult;
        var ready = c.pollfd{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
        const polled = c.poll(@ptrCast(&ready), 1, @intCast(deadline - now));
        if (polled <= 0 or ready.revents & (c.POLL.ERR | c.POLL.NVAL) != 0)
            return error.TestUnexpectedResult;
        const got = c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (got <= 0) return error.TestUnexpectedResult;
        offset += @intCast(got);
    }
}

fn writeReport(nonce: [16]u8, stage: Stage, snapshot: remote_runtime.rss_testing_api.Snapshot) !void {
    const report = Report{
        .run_nonce = nonce,
        .pid = @intCast(c.getpid()),
        .stage_raw = @intFromEnum(stage),
        .inherited_fd_closed = @intFromBool(c.fcntl(sentinel_fd, c.F.GETFD, @as(c_int, 0)) < 0 and
            std.posix.errno(-1) == .BADF),
        .reserved = .{ 0, 0 },
        .generation_count = snapshot.generation_count,
        .live_bytes = snapshot.live_bytes,
        .peak_bytes = snapshot.peak_bytes,
        .live_allocations = snapshot.live_allocations,
        .peak_allocations = snapshot.peak_allocations,
    };
    try writeExact(child_fd, std.mem.asBytes(&report));
}

fn readReport(fd: c.fd_t, expected: Stage, nonce: [16]u8, deadline: u64) !Report {
    var report: Report = undefined;
    try readExactDeadline(fd, std.mem.asBytes(&report), deadline);
    if (!report.valid(expected, nonce)) return error.TestUnexpectedResult;
    return report;
}

fn expectEof(fd: c.fd_t, deadline: u64) !void {
    while (true) {
        const now = try monotonicMs();
        if (now >= deadline) return error.TestUnexpectedResult;
        var ready = c.pollfd{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
        const polled = c.poll(@ptrCast(&ready), 1, @intCast(deadline - now));
        if (polled <= 0 or ready.revents & (c.POLL.ERR | c.POLL.NVAL) != 0)
            return error.TestUnexpectedResult;
        if (ready.revents & (c.POLL.IN | c.POLL.HUP) == 0) continue;
        var trailing: [1]u8 = undefined;
        if (c.read(fd, &trailing, 1) != 0) return error.TestUnexpectedResult;
        return;
    }
}

fn reapBefore(pid: c.pid_t, deadline: u64, reaped: *bool) !u8 {
    while (true) {
        var status: c_int = 0;
        const waited = c.waitpid(pid, &status, c.W.NOHANG);
        if (waited == pid) {
            reaped.* = true;
            const raw: u32 = @bitCast(status);
            if (!c.W.IFEXITED(raw)) return error.TestUnexpectedResult;
            return c.W.EXITSTATUS(raw);
        }
        if (waited < 0 or try monotonicMs() >= deadline) return error.TestUnexpectedResult;
        _ = usleep(1_000);
    }
}

fn readCommand(expected: u8) !void {
    var command: [1]u8 = undefined;
    try readExact(child_fd, &command);
    if (command[0] != expected) return error.TestUnexpectedResult;
}

fn sampleRss(pid: c.pid_t) !RssSample {
    var info: mac.struct_proc_bsdinfo = std.mem.zeroes(mac.struct_proc_bsdinfo);
    if (mac.proc_pidinfo(pid, mac.PROC_PIDTBSDINFO, 0, &info, @sizeOf(@TypeOf(info))) !=
        @sizeOf(@TypeOf(info)) or info.pbi_pid != @as(u32, @intCast(pid)))
        return error.TestUnexpectedResult;
    var usage: mac.struct_rusage_info_v4 = std.mem.zeroes(mac.struct_rusage_info_v4);
    if (mac.proc_pid_rusage(pid, mac.RUSAGE_INFO_V4, @ptrCast(&usage)) != 0 or
        usage.ri_resident_size == 0 or usage.ri_phys_footprint == 0 or
        usage.ri_proc_start_abstime == 0)
        return error.TestUnexpectedResult;
    return .{
        .resident = usage.ri_resident_size,
        .footprint = usage.ri_phys_footprint,
        .start_abstime = usage.ri_proc_start_abstime,
    };
}

fn sampleMedian(pid: c.pid_t, expected_start: u64) !SampleSet {
    var samples: [sample_count]RssSample = undefined;
    var resident: [sample_count]u64 = undefined;
    var footprint: [sample_count]u64 = undefined;
    for (0..sample_count) |index| {
        const sample = try sampleRss(pid);
        if (sample.start_abstime != expected_start) return error.TestUnexpectedResult;
        samples[index] = sample;
        resident[index] = sample.resident;
        footprint[index] = sample.footprint;
        if (index + 1 != sample_count) _ = usleep(10_000);
    }
    std.mem.sort(u64, &resident, {}, std.sort.asc(u64));
    std.mem.sort(u64, &footprint, {}, std.sort.asc(u64));
    return .{
        .samples = samples,
        .median = .{
            .resident = resident[sample_count / 2],
            .footprint = footprint[sample_count / 2],
            .start_abstime = expected_start,
        },
    };
}

fn writeArtifact(artifact: Artifact) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.write(artifact);
    try out.writer.writeByte('\n');
    const temp = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}.tmp.{d}",
        .{ artifact_path, c.getpid() },
    );
    defer std.testing.allocator.free(temp);
    const temp_z = try std.testing.allocator.dupeZ(u8, temp);
    defer std.testing.allocator.free(temp_z);
    const path_z = try std.testing.allocator.dupeZ(u8, artifact_path);
    defer std.testing.allocator.free(path_z);
    defer _ = c.unlink(temp_z.ptr);
    const fd = c.open(temp_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.TestUnexpectedResult;
    var open = true;
    defer if (open) {
        _ = c.close(fd);
    };
    try writeExact(fd, out.written());
    if (c.close(fd) != 0) return error.TestUnexpectedResult;
    open = false;
    if (c.rename(temp_z.ptr, path_z.ptr) != 0) return error.TestUnexpectedResult;
}

test "CR2e-e3a2 RSS child는 baseline pressure final zero transcript를 exact 게시한다" {
    const nonce = childNonce() orelse return error.SkipZigTest;
    var socket_type: c_int = 0;
    var socket_type_len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(child_fd, std.posix.SOL.SOCKET, std.posix.SO.TYPE, &socket_type, &socket_type_len) != 0 or
        socket_type != std.posix.SOCK.STREAM or socket_type_len != @sizeOf(c_int))
        return error.TestUnexpectedResult;
    var peer_pid: c.pid_t = 0;
    var peer_pid_len: c.socklen_t = @sizeOf(c.pid_t);
    if (c.getsockopt(child_fd, sol_local, local_peerpid, &peer_pid, &peer_pid_len) != 0 or
        peer_pid_len != @sizeOf(c.pid_t) or peer_pid != c.getppid())
        return error.TestUnexpectedResult;
    var workload: remote_runtime.rss_testing_api.Workload = undefined;
    try workload.initInPlace(std.heap.c_allocator, std.testing.io);
    var live = true;
    defer if (live) workload.deinit();

    try writeReport(nonce, .baseline, workload.snapshot());
    try readCommand('p');
    try workload.pressure();
    try writeReport(nonce, .pressure, workload.snapshot());
    try readCommand('c');
    const final = workload.deinitAndSnapshot();
    live = false;
    try writeReport(nonce, .final_zero, final);
    _ = c.close(child_fd);
}

test "CR2e-e3a2 RSS watchdog은 열린 무응답 transcript를 absolute deadline으로 거부한다" {
    try unlinkArtifact();
    const artifact_z = try std.testing.allocator.dupeZ(u8, artifact_path);
    defer std.testing.allocator.free(artifact_z);
    const stale_fd = c.open(artifact_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, @as(c.mode_t, 0o600));
    if (stale_fd < 0) return error.TestUnexpectedResult;
    try writeExact(stale_fd, "stale");
    if (c.close(stale_fd) != 0) return error.TestUnexpectedResult;
    try unlinkArtifact();

    var pair: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));
    const pid = c.fork();
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        _ = c.close(pair[0]);
        _ = c.write(pair[1], "x", 1);
        while (true) _ = usleep(1_000_000);
    }
    var reaped = false;
    defer if (!reaped) {
        _ = terminateAndReap(pid, &reaped) catch
            @panic("RSS watchdog child cleanup failed");
    };
    _ = c.close(pair[1]);
    defer _ = c.close(pair[0]);
    var bytes: [2]u8 = undefined;
    const deadline = try std.math.add(u64, try monotonicMs(), 20);
    try std.testing.expectError(
        error.TestUnexpectedResult,
        readExactDeadline(pair[0], &bytes, deadline),
    );
    const status = try terminateAndReap(pid, &reaped);
    try std.testing.expect(c.W.IFSIGNALED(status) and c.W.TERMSIG(status) == c.SIG.KILL);
    try std.testing.expectEqual(std.posix.E.NOENT, std.posix.errno(c.access(artifact_z.ptr, c.F_OK)));
}

test "CR2e-e3a2 RSS parent는 별도 ReleaseFast PID의 logical delta와 측정 tolerance를 고정한다" {
    if (@import("builtin").mode != .ReleaseFast or @import("builtin").os.tag != .macos)
        return error.SkipZigTest;
    if (ChildArtifact.maru_cr2e_e3a2_rss_child_path_len == 0)
        return error.TestUnexpectedResult;

    try unlinkArtifact();
    const path = ChildArtifact.maru_cr2e_e3a2_rss_child_path[0..ChildArtifact.maru_cr2e_e3a2_rss_child_path_len :0];
    var sentinel_pipe: [2]c.fd_t = undefined;
    if (c.pipe(&sentinel_pipe) != 0) return error.TestUnexpectedResult;
    if (c.dup2(sentinel_pipe[0], sentinel_fd) < 0) return error.TestUnexpectedResult;
    for (sentinel_pipe) |fd| {
        if (fd != sentinel_fd) _ = c.close(fd);
    }
    const sentinel_flags = c.fcntl(sentinel_fd, c.F.GETFD, @as(c_int, 0));
    if (sentinel_flags < 0 or c.fcntl(sentinel_fd, c.F.SETFD, sentinel_flags & ~@as(c_int, c.FD_CLOEXEC)) < 0)
        return error.TestUnexpectedResult;
    defer _ = c.close(sentinel_fd);
    const deadline = try std.math.add(u64, try monotonicMs(), deadline_ms);
    var pair: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair));
    inline for (pair) |fd| {
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (flags < 0 or c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0)
            return error.TestUnexpectedResult;
    }
    var nonce: [16]u8 = undefined;
    arc4random_buf(&nonce, nonce.len);
    if (std.mem.allEqual(u8, &nonce, 0)) return error.TestUnexpectedResult;
    var nonce_hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&nonce_hex, "{x}", .{nonce}) catch return error.TestUnexpectedResult;
    var env_storage: [marker_name.len + 1 + 32 + 1]u8 = undefined;
    const env_value = try std.fmt.bufPrintZ(&env_storage, "{s}={s}", .{ marker_name, nonce_hex });
    const pid = c.fork();
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        _ = c.close(pair[0]);
        if (pair[1] != child_fd) {
            if (c.dup2(pair[1], child_fd) < 0) c._exit(121);
            _ = c.close(pair[1]);
        }
        const child_flags = c.fcntl(child_fd, c.F.GETFD, @as(c_int, 0));
        if (child_flags < 0 or c.fcntl(child_fd, c.F.SETFD, child_flags & ~@as(c_int, c.FD_CLOEXEC)) < 0)
            c._exit(121);
        var inherited_fd: c_int = 3;
        while (inherited_fd < getdtablesize()) : (inherited_fd += 1) {
            if (inherited_fd != child_fd) _ = c.close(inherited_fd);
        }
        const argv = [_:null]?[*:0]const u8{ path.ptr, "--maru-expect-tests=1" };
        const env = [_:null]?[*:0]const u8{env_value.ptr};
        _ = c.execve(path.ptr, &argv, &env);
        c._exit(122);
    }
    _ = c.close(pair[1]);
    var reaped = false;
    defer if (!reaped) {
        _ = terminateAndReap(pid, &reaped) catch @panic("RSS child kill/reap failed");
    };
    defer _ = c.close(pair[0]);

    const baseline_report = try readReport(pair[0], .baseline, nonce, deadline);
    try std.testing.expectEqual(@as(u8, 1), baseline_report.inherited_fd_closed);
    try std.testing.expectEqual(@as(u32, @intCast(pid)), baseline_report.pid);
    try std.testing.expectEqual(@as(u64, remote_runtime.rss_testing_api.owner_count), baseline_report.generation_count);
    const first_sample = try sampleRss(pid);
    const baseline_set = try sampleMedian(pid, first_sample.start_abstime);
    const baseline = baseline_set.median;

    try writeExact(pair[0], "p");
    const pressure_report = try readReport(pair[0], .pressure, nonce, deadline);
    try std.testing.expectEqual(@as(u64, remote_runtime.rss_testing_api.owner_count * 2), pressure_report.generation_count);
    try std.testing.expect(pressure_report.live_bytes > baseline_report.live_bytes);
    const pressure_set = try sampleMedian(pid, first_sample.start_abstime);
    const pressure = pressure_set.median;
    const logical_delta = pressure_report.live_bytes - baseline_report.live_bytes;
    const rss_delta = pressure.resident -| baseline.resident;
    const footprint_delta = pressure.footprint -| baseline.footprint;
    const allowed = try std.math.add(u64, logical_delta, measurement_tolerance_bytes);
    try std.testing.expect(rss_delta <= allowed);
    try std.testing.expect(footprint_delta <= allowed);
    try std.testing.expect(logical_delta <= remote_runtime.rss_testing_api.max_tracked_bytes);

    try writeExact(pair[0], "c");
    const final_report = try readReport(pair[0], .final_zero, nonce, deadline);
    try std.testing.expectEqual(@as(u64, 0), final_report.generation_count);
    try std.testing.expectEqual(@as(u64, 0), final_report.live_bytes);
    try std.testing.expectEqual(@as(u64, 0), final_report.live_allocations);
    try expectEof(pair[0], deadline);
    const exit_code = try reapBefore(pid, deadline, &reaped);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try writeArtifact(.{
        .schema = "maru.session-host-reconnect-rss-macos.v2",
        .build_mode = "ReleaseFast",
        .sample_api = "proc_pid_rusage:RUSAGE_INFO_V4",
        .run_nonce = nonce,
        .executable_path = path,
        .inherited_fd_closed = true,
        .child_pid = @intCast(pid),
        .child_start_abstime = first_sample.start_abstime,
        .sample_count = sample_count,
        .owner_count = remote_runtime.rss_testing_api.owner_count,
        .max_entry_bytes = remote_runtime.rss_testing_api.max_entry_bytes,
        .max_tracked_bytes = remote_runtime.rss_testing_api.max_tracked_bytes,
        .baseline_samples = baseline_set.samples,
        .pressure_samples = pressure_set.samples,
        .baseline_generation_count = baseline_report.generation_count,
        .pressure_generation_count = pressure_report.generation_count,
        .baseline_logical_bytes = baseline_report.live_bytes,
        .pressure_logical_bytes = pressure_report.live_bytes,
        .logical_delta_bytes = logical_delta,
        .baseline_rss_bytes = baseline.resident,
        .pressure_rss_bytes = pressure.resident,
        .rss_delta_bytes = rss_delta,
        .baseline_footprint_bytes = baseline.footprint,
        .pressure_footprint_bytes = pressure.footprint,
        .footprint_delta_bytes = footprint_delta,
        .measurement_tolerance_bytes = measurement_tolerance_bytes,
        .allowed_delta_bytes = allowed,
        .final_generation_count = final_report.generation_count,
        .final_logical_bytes = final_report.live_bytes,
        .final_live_allocations = final_report.live_allocations,
        .child_exit_code = exit_code,
    });
}
