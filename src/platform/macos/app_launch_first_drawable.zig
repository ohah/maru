//! L1 actual-AppKit launch-to-first-drawable baseline harness.
//!
//! Each child receives a unique profile and session-host namespace. The child follows the ordinary
//! product startup path; the only test seam records the parent's pre-fork monotonic timestamp and
//! terminates after the first successful Metal draw.

const std = @import("std");
const measurement_fingerprint = @import("measurement_fingerprint.zig");

extern "c" fn usleep(useconds: c_uint) c_int;

const sample_count = 5;

const Row = struct {
    index: u32,
    pre_fork_ns: u64,
    swift_start_ns: u64,
    submit_ns: u64,
    latency_ns: u64,
    metal_frames_drawn: u32,
    smoke_mode: bool,
};

const Artifact = struct {
    schema: []const u8 = "maru.macos-app-launch-first-drawable.v1",
    build_mode: []const u8 = "ReleaseFast",
    os_release: []const u8,
    machine_model: []const u8,
    logical_cpu_count: u32,
    executable_sha256: []const u8,
    rows: [sample_count]Row,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const app = std.c.getenv("MARU_APP_LAUNCH_FIRST_DRAWABLE_EXE") orelse return error.MissingAppExecutable;
    const root = std.c.getenv("MARU_APP_LAUNCH_FIRST_DRAWABLE_ROOT") orelse return error.MissingArtifactRoot;
    const artifact_path = std.c.getenv("MARU_APP_LAUNCH_FIRST_DRAWABLE_ARTIFACT") orelse return error.MissingArtifactPath;
    const app_path = try allocator.dupeZ(u8, std.mem.span(app));
    defer allocator.free(app_path);
    const root_path = try allocator.dupeZ(u8, std.mem.span(root));
    defer allocator.free(root_path);
    const final_artifact_path = try allocator.dupe(u8, std.mem.span(artifact_path));
    defer allocator.free(final_artifact_path);
    if (!std.fs.path.isAbsolute(app_path) or !std.fs.path.isAbsolute(root_path)) return error.InvalidHarnessPath;
    var environment = try measurement_fingerprint.Environment.capture(allocator);
    defer environment.deinit(allocator);
    const executable_digest = try measurement_fingerprint.sha256File(app_path.ptr);
    const executable_hex = std.fmt.bytesToHex(executable_digest, .lower);
    var artifact: Artifact = .{
        .os_release = environment.os_release,
        .machine_model = environment.machine_model,
        .logical_cpu_count = environment.logical_cpu_count,
        .executable_sha256 = &executable_hex,
        .rows = undefined,
    };
    for (0..sample_count) |index| {
        var home_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var cache_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var config_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var xdg_config_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var codex_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var claude_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var tmp_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var host_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        var summary_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const home = try std.fmt.bufPrintZ(&home_buf, "{s}/run-{d}/home", .{ root_path, index });
        const cache = try std.fmt.bufPrintZ(&cache_buf, "{s}/run-{d}/cache", .{ root_path, index });
        const config = try std.fmt.bufPrintZ(&config_buf, "{s}/run-{d}/home/.config/maru/config", .{ root_path, index });
        const xdg_config = try std.fmt.bufPrintZ(&xdg_config_buf, "{s}/run-{d}/config", .{ root_path, index });
        const codex = try std.fmt.bufPrintZ(&codex_buf, "{s}/run-{d}/codex", .{ root_path, index });
        const claude = try std.fmt.bufPrintZ(&claude_buf, "{s}/run-{d}/claude", .{ root_path, index });
        const tmp = try std.fmt.bufPrintZ(&tmp_buf, "{s}/run-{d}/tmp", .{ root_path, index });
        const host = try std.fmt.bufPrintZ(&host_buf, "{s}/run-{d}/session-host", .{ root_path, index });
        const summary = try std.fmt.bufPrintZ(&summary_buf, "{s}/run-{d}/app.summary.txt", .{ root_path, index });
        const fixed_child_env = [_]?[*:0]const u8{
            (try envPair(allocator, "PATH", "/usr/bin:/bin:/usr/sbin:/sbin")).ptr,
            (try envPair(allocator, "HOME", home)).ptr,
            (try envPair(allocator, "CFFIXED_USER_HOME", home)).ptr,
            (try envPair(allocator, "XDG_CACHE_HOME", cache)).ptr,
            (try envPair(allocator, "XDG_CONFIG_HOME", xdg_config)).ptr,
            (try envPair(allocator, "CODEX_HOME", codex)).ptr,
            (try envPair(allocator, "CLAUDE_CONFIG_DIR", claude)).ptr,
            (try envPair(allocator, "TMPDIR", tmp)).ptr,
            (try envPair(allocator, "MARU_CONFIG", config)).ptr,
            (try envPair(allocator, "MARU_SESSION_HOST_ROOT", host)).ptr,
            (try envPair(allocator, "MARU_APP_SUMMARY_PATH", summary)).ptr,
            (try envPair(allocator, "MARU_APP_LAUNCH_FIRST_DRAWABLE", "1")).ptr,
        };
        defer inline for (fixed_child_env) |entry| allocator.free(std.mem.span(entry.?));
        const pre_fork_ns = monotonicNow(io);
        var start_env_buf: [96]u8 = undefined;
        const start_env = try std.fmt.bufPrintZ(
            &start_env_buf,
            "MARU_APP_LAUNCH_FIRST_DRAWABLE_START_NS={d}",
            .{pre_fork_ns},
        );
        const child_env = fixed_child_env ++ [_:null]?[*:0]const u8{start_env.ptr};
        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{app_path.ptr};
            _ = std.c.execve(app_path.ptr, &argv, &child_env);
            std.c._exit(127);
        }
        try waitForExactExit(pid, 30_000);
        const summary_bytes = try std.Io.Dir.cwd().readFileAlloc(io, summary, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(summary_bytes);
        const row: Row = .{
            .index = @intCast(index),
            .pre_fork_ns = pre_fork_ns,
            .swift_start_ns = try summaryU64(summary_bytes, "app_launch_first_drawable_start_ns"),
            .submit_ns = try summaryU64(summary_bytes, "app_launch_first_drawable_submit_ns"),
            .latency_ns = try summaryU64(summary_bytes, "app_launch_first_drawable_latency_ns"),
            .metal_frames_drawn = try summaryU32(summary_bytes, "metal_frames_drawn"),
            .smoke_mode = try summaryBool(summary_bytes, "app_launch_first_drawable_smoke_mode"),
        };
        if (!(try summaryBool(summary_bytes, "app_launch_first_drawable_armed")) or
            row.swift_start_ns != row.pre_fork_ns or row.submit_ns <= row.swift_start_ns or
            row.latency_ns != row.submit_ns - row.swift_start_ns or row.metal_frames_drawn != 1 or row.smoke_mode)
            return error.InvalidAppSummary;
        artifact.rows[index] = row;
    }
    const executable_digest_after = try measurement_fingerprint.sha256File(app_path.ptr);
    if (!std.mem.eql(u8, &executable_digest, &executable_digest_after)) return error.ExecutableChanged;
    try writeArtifact(allocator, io, final_artifact_path, artifact);
}

fn envPair(allocator: std.mem.Allocator, comptime name: []const u8, value: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ name, value }, 0);
}

fn monotonicNow(io: std.Io) u64 {
    const ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(ns);
}

fn waitForExactExit(pid: c_int, timeout_ms: usize) !void {
    var status: c_int = 0;
    var elapsed: usize = 0;
    while (elapsed < timeout_ms) : (elapsed += 5) {
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) {
            const bits: u32 = @bitCast(status);
            if (!std.c.W.IFEXITED(bits) or std.c.W.EXITSTATUS(bits) != 0) return error.AppFailed;
            return;
        }
        if (rc < 0) return error.WaitFailed;
        _ = usleep(5 * 1000);
    }
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    while (std.c.waitpid(pid, &status, 0) < 0) if (std.posix.errno(-1) != .INTR) break;
    return error.AppTimedOut;
}

fn summaryValue(summary: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, summary, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..separator], key)) return line[separator + 1 ..];
    }
    return null;
}

fn summaryU64(summary: []const u8, key: []const u8) !u64 {
    return std.fmt.parseInt(u64, summaryValue(summary, key) orelse return error.InvalidAppSummary, 10) catch
        return error.InvalidAppSummary;
}

fn summaryU32(summary: []const u8, key: []const u8) !u32 {
    return std.fmt.parseInt(u32, summaryValue(summary, key) orelse return error.InvalidAppSummary, 10) catch
        return error.InvalidAppSummary;
}

fn summaryBool(summary: []const u8, key: []const u8) !bool {
    const value = summaryValue(summary, key) orelse return error.InvalidAppSummary;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidAppSummary;
}

fn writeArtifact(allocator: std.mem.Allocator, io: std.Io, path: []const u8, artifact: Artifact) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try json.write(artifact);
    try out.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}
