//! CR6e-a1 raw transport baseline producer: real hello-reply stall plus exact-host absent/backoff.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const mac = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/proc_info.h");
});
const session_host = @import("session_host");

const deadline_ms: u64 = 250;
const schema_name = "maru.session-host-cr6e-baseline-macos.v1";

const RssSample = struct {
    monotonic_ns: u64,
    resident_bytes: u64,
    footprint_bytes: u64,
    cpu_ns: u64,
};

const Scenario = struct {
    name: []const u8,
    start_ns: u64,
    deadline_ns: u64,
    end_ns: u64,
    failure_reason: []const u8,
    attempt_count: u32,
    backoff_wait_count: u32,
    peer_accepted: bool,
    peer_hello_bytes: u32,
    peer_closed: bool,
};

const Artifact = struct {
    schema: []const u8,
    build_mode: []const u8,
    sample_api: []const u8,
    os_release: []const u8,
    machine_model: []const u8,
    logical_cpu_count: u32,
    pid: u32,
    deadline_ms: u64,
    fd_count_before: u32,
    fd_count_after: u32,
    rss_before: RssSample,
    rss_after: RssSample,
    scenarios: [2]Scenario,
    peer_reaped: bool,
    socket_removed: bool,
    manifest_removed: bool,
    host_directory_removed: bool,
};

const PeerReport = extern struct {
    accepted: u8 = 0,
    closed: u8 = 0,
    reserved: u16 = 0,
    hello_bytes: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .macos) return error.UnsupportedPlatform;
    const allocator = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const artifact_path = args.next() orelse return error.MissingArtifactPath;
    if (args.next() != null) return error.TooManyArguments;

    try session_host.short_endpoint.prepareCurrentUserNamespace();
    var base_buf: [192]u8 = undefined;
    const base = try std.fmt.bufPrintZ(&base_buf, "/tmp/maru-session-host-cr6e-{d}", .{c.getpid()});
    if (c.mkdir(base.ptr, 0o700) != 0 and posix.errno(-1) != .EXIST) return error.BaseDirectoryCreateFailed;
    defer _ = c.rmdir(base.ptr);
    var dir_buf: [256]u8 = undefined;
    const session_dir = try session_host.discovery.sessionHostDirPath(&dir_buf, base);
    if (c.mkdir(session_dir.ptr, 0o700) != 0 and posix.errno(-1) != .EXIST)
        return error.SessionDirectoryCreateFailed;
    defer _ = c.rmdir(session_dir.ptr);

    const host_id: u128 = (@as(u128, @intCast(c.getpid())) << 64) | 0xC6E0_BA5E_0000_0001;
    var socket_buf: [160]u8 = undefined;
    const socket_path = try session_host.short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    _ = c.unlink(socket_path.ptr);

    const fd_before = try countOpenFds(io);
    const rss_before = try sampleRss(io);
    const listener = try openListener(socket_path);
    var listener_open = true;
    defer if (listener_open) {
        _ = c.close(listener);
    };

    var report_pipe: [2]c.fd_t = undefined;
    if (c.pipe(&report_pipe) != 0) return error.PipeFailed;
    var report_read_open = true;
    defer if (report_read_open) {
        _ = c.close(report_pipe[0]);
    };
    var report_write_open = true;
    defer if (report_write_open) {
        _ = c.close(report_pipe[1]);
    };

    const peer_pid = c.fork();
    if (peer_pid < 0) return error.ForkFailed;
    if (peer_pid == 0) peerMain(listener, report_pipe[0], report_pipe[1]);
    var peer_owned = true;
    defer if (peer_owned) terminateAndReap(peer_pid);
    _ = c.close(report_pipe[1]);
    report_write_open = false;

    var publication = try session_host.host_manifest.publish(allocator, session_dir, .{
        .host_id = host_id,
        .build_id = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .protocol_major = session_host.protocol.version_major,
        .screen_codec_version = session_host.screen_stream.codec_version,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = socket_path,
    });
    var publication_owned = true;
    defer if (publication_owned) publication.deinit();

    var hello_observation: session_host.host_connect.DeadlineConnectObservation = .{};
    const hello_start = monotonicNow(io);
    const hello_phase = session_host.attach_phase_deadline.PhaseDeadline.fromAbsolute(
        .connect_hello,
        try session_host.client_deadline.AbsoluteDeadline.after(io, deadline_ms * std.time.ns_per_ms),
    );
    const hello_outcome = session_host.host_connect.connectExistingHostUntilObserved(
        allocator,
        base,
        host_id,
        hello_phase,
        &hello_observation,
    );
    const hello_end = monotonicNow(io);
    const hello_reason = outcomeReason(hello_outcome);
    if (!std.mem.eql(u8, hello_reason, "deadline_exceeded")) return error.HelloStallDidNotTimeout;

    var peer_report: PeerReport = .{};
    try readExact(report_pipe[0], std.mem.asBytes(&peer_report));
    _ = c.close(report_pipe[0]);
    report_read_open = false;
    var peer_status: c_int = 0;
    if (c.waitpid(peer_pid, &peer_status, 0) != peer_pid or !exitedZero(peer_status))
        return error.PeerFailed;
    peer_owned = false;
    _ = c.close(listener);
    listener_open = false;
    _ = c.unlink(socket_path.ptr);

    var backoff_observation: session_host.host_connect.DeadlineConnectObservation = .{};
    const backoff_start = monotonicNow(io);
    const backoff_phase = session_host.attach_phase_deadline.PhaseDeadline.fromAbsolute(
        .connect_hello,
        try session_host.client_deadline.AbsoluteDeadline.after(io, deadline_ms * std.time.ns_per_ms),
    );
    const backoff_outcome = session_host.host_connect.connectExistingHostUntilObserved(
        allocator,
        base,
        host_id,
        backoff_phase,
        &backoff_observation,
    );
    const backoff_end = monotonicNow(io);
    const backoff_reason = outcomeReason(backoff_outcome);

    const withdraw = try publication.withdraw();
    if (withdraw != .removed) return error.ManifestCleanupFailed;
    const manifest_removed = c.access(publication.manifest_path.ptr, c.F_OK) != 0;
    publication.deinitMemory();
    publication_owned = false;
    var host_dir_buf: [768]u8 = undefined;
    const host_dir = try session_host.host_manifest.hostDirPathIn(&host_dir_buf, session_dir, host_id);
    const host_dir_removed = c.rmdir(host_dir.ptr) == 0;

    const rss_after = try sampleRss(io);
    const fd_after = try countOpenFds(io);
    const os_release = try sysctlString(allocator, "kern.osrelease");
    defer allocator.free(os_release);
    const machine_model = try sysctlString(allocator, "hw.model");
    defer allocator.free(machine_model);
    const logical_cpu = try sysctlU32("hw.logicalcpu");

    const artifact: Artifact = .{
        .schema = schema_name,
        .build_mode = "ReleaseFast",
        .sample_api = "proc_pid_rusage:RUSAGE_INFO_V4",
        .os_release = os_release,
        .machine_model = machine_model,
        .logical_cpu_count = logical_cpu,
        .pid = @intCast(c.getpid()),
        .deadline_ms = deadline_ms,
        .fd_count_before = fd_before,
        .fd_count_after = fd_after,
        .rss_before = rss_before,
        .rss_after = rss_after,
        .scenarios = .{
            .{
                .name = "hello_reply_stall",
                .start_ns = hello_start,
                .deadline_ns = @intCast(hello_phase.absolute.expires_at_ns),
                .end_ns = hello_end,
                .failure_reason = hello_reason,
                .attempt_count = hello_observation.attempt_count,
                .backoff_wait_count = hello_observation.backoff_wait_count,
                .peer_accepted = peer_report.accepted == 1,
                .peer_hello_bytes = peer_report.hello_bytes,
                .peer_closed = peer_report.closed == 1,
            },
            .{
                .name = "transient_backoff",
                .start_ns = backoff_start,
                .deadline_ns = @intCast(backoff_phase.absolute.expires_at_ns),
                .end_ns = backoff_end,
                .failure_reason = backoff_reason,
                .attempt_count = backoff_observation.attempt_count,
                .backoff_wait_count = backoff_observation.backoff_wait_count,
                .peer_accepted = false,
                .peer_hello_bytes = 0,
                .peer_closed = true,
            },
        },
        .peer_reaped = true,
        .socket_removed = c.access(socket_path.ptr, c.F_OK) != 0,
        .manifest_removed = manifest_removed,
        .host_directory_removed = host_dir_removed,
    };
    try writeArtifactAtomic(allocator, io, artifact_path, artifact);
}

fn openListener(path: [:0]const u8) !c.fd_t {
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    if (path.len >= addr.path.len) return error.SocketPathTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return error.BindFailed;
    if (c.chmod(path.ptr, 0o600) != 0) return error.ChmodFailed;
    if (c.listen(fd, 1) != 0) return error.ListenFailed;
    return fd;
}

fn peerMain(listener: c.fd_t, report_read: c.fd_t, report_write: c.fd_t) noreturn {
    _ = c.close(report_read);
    var report: PeerReport = .{};
    const fd = c.accept(listener, null, null);
    if (fd >= 0) {
        report.accepted = 1;
        var bytes: [4096]u8 = undefined;
        const amount = c.read(fd, &bytes, bytes.len);
        if (amount > 0) report.hello_bytes = @intCast(amount);
        _ = usleep(350 * 1000);
        _ = c.close(fd);
        report.closed = 1;
    }
    _ = writeAll(report_write, std.mem.asBytes(&report));
    _ = c.close(report_write);
    _ = c.close(listener);
    c._exit(if (report.accepted == 1 and report.hello_bytes > 0 and report.closed == 1) 0 else 1);
}

extern "c" fn usleep(useconds: c_uint) c_int;
extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: *usize, newp: ?*anyopaque, newlen: usize) c_int;

fn outcomeReason(outcome: session_host.host_connect.Outcome) []const u8 {
    return switch (outcome) {
        .failed => |reason| @tagName(reason),
        .connected => |value| blk: {
            var client = value;
            client.deinit();
            break :blk "connected";
        },
    };
}

fn monotonicNow(io: std.Io) u64 {
    const ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(ns);
}

fn sampleRss(io: std.Io) !RssSample {
    var usage: mac.struct_rusage_info_v4 = std.mem.zeroes(mac.struct_rusage_info_v4);
    if (mac.proc_pid_rusage(c.getpid(), mac.RUSAGE_INFO_V4, @ptrCast(&usage)) != 0)
        return error.RusageUnavailable;
    return .{
        .monotonic_ns = monotonicNow(io),
        .resident_bytes = usage.ri_resident_size,
        .footprint_bytes = usage.ri_phys_footprint,
        .cpu_ns = usage.ri_user_time +| usage.ri_system_time,
    };
}

fn countOpenFds(io: std.Io) !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/dev/fd", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: u32 = 0;
    while (try iterator.next(io)) |entry| if (entry.kind != .directory) {
        count +|= 1;
    };
    return count -| 1;
}

fn sysctlString(allocator: std.mem.Allocator, comptime name: [:0]const u8) ![]u8 {
    var len: usize = 0;
    if (sysctlbyname(name.ptr, null, &len, null, 0) != 0 or len <= 1 or len > 4096)
        return error.SysctlUnavailable;
    const bytes = try allocator.alloc(u8, len - 1);
    errdefer allocator.free(bytes);
    var actual = len;
    if (sysctlbyname(name.ptr, bytes.ptr, &actual, null, 0) != 0 or actual != len)
        return error.SysctlUnavailable;
    return bytes;
}

fn sysctlU32(comptime name: [:0]const u8) !u32 {
    var value: u32 = 0;
    var len: usize = @sizeOf(u32);
    if (sysctlbyname(name.ptr, &value, &len, null, 0) != 0 or len != @sizeOf(u32) or value == 0)
        return error.SysctlUnavailable;
    return value;
}

fn readExact(fd: c.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount = c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (amount < 0 and posix.errno(amount) == .INTR) continue;
        if (amount <= 0) return error.ReportReadFailed;
        offset += @intCast(amount);
    }
}

fn writeAll(fd: c.fd_t, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (amount < 0 and posix.errno(amount) == .INTR) continue;
        if (amount <= 0) return false;
        offset += @intCast(amount);
    }
    return true;
}

fn exitedZero(status: c_int) bool {
    const unsigned: u32 = @bitCast(status);
    return c.W.IFEXITED(unsigned) and c.W.EXITSTATUS(unsigned) == 0;
}

fn terminateAndReap(pid: c.pid_t) void {
    _ = c.kill(pid, posix.SIG.TERM);
    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const rc = c.waitpid(pid, &status, c.W.NOHANG);
        if (rc == pid or rc < 0) return;
        _ = usleep(5 * 1000);
    }
    _ = c.kill(pid, posix.SIG.KILL);
    while (c.waitpid(pid, &status, 0) < 0) {
        if (posix.errno(-1) != .INTR) return;
    }
}

fn writeArtifactAtomic(allocator: std.mem.Allocator, io: std.Io, path: []const u8, artifact: Artifact) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try json.write(artifact);
    try out.writer.writeByte('\n');
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, c.getpid() });
    defer allocator.free(temp);
    const temp_z = try allocator.dupeZ(u8, temp);
    defer allocator.free(temp_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    defer _ = c.unlink(temp_z.ptr);
    const fd = c.open(temp_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.ArtifactCreateFailed;
    var artifact_fd_open = true;
    defer if (artifact_fd_open) {
        _ = c.close(fd);
    };
    if (!writeAll(fd, out.written())) return error.ArtifactWriteFailed;
    if (c.close(fd) != 0) return error.ArtifactWriteFailed;
    artifact_fd_open = false;
    if (c.rename(temp_z.ptr, path_z.ptr) != 0) return error.ArtifactRenameFailed;
}
