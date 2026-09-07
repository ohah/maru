//! Actual-process timing for candidate pinning with isolated bounded synthetic inputs.

const std = @import("std");
const c = std.c;
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const report_mod = @import("release_workflow_candidate_inputs_process_report");
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

const dmg_bytes: usize = 1024 * 1024;
const executable_bytes: usize = 256 * 1024;
const max_iterations: usize = @intCast(report_mod.max_iterations);

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const bootstrap_input = args.next() orelse return error.MissingBootstrap;
    const candidate_input = args.next() orelse return error.MissingCandidate;
    const iteration_text = args.next() orelse return error.MissingIterations;
    if (args.next() != null) return error.TooManyArguments;
    const iterations = try std.fmt.parseInt(usize, iteration_text, 10);
    if (iterations == 0 or iterations > max_iterations) return error.InvalidIterations;
    const bootstrap = try std.Io.Dir.cwd().realPathFileAlloc(init.io, bootstrap_input, init.gpa);
    defer init.gpa.free(bootstrap);
    const candidate = try std.Io.Dir.cwd().realPathFileAlloc(init.io, candidate_input, init.gpa);
    defer init.gpa.free(candidate);
    var environment = try trustedEnvironment(init.gpa);
    defer environment.deinit();
    // Initialize the process backend before the FD baseline so its persistent wake descriptor is
    // not misreported as a leak caused by the candidate child.
    const warm = try std.process.run(init.gpa, init.io, .{ .argv = &.{"/usr/bin/true"}, .stdout_limit = .limited(1), .stderr_limit = .limited(1) });
    defer init.gpa.free(warm.stdout);
    defer init.gpa.free(warm.stderr);
    switch (warm.term) {
        .exited => |code| if (code != 0) return error.WarmupFailed,
        else => return error.WarmupFailed,
    }
    const fd_before = try openFdCount(init.io);
    var durations: [max_iterations]u64 = undefined;
    var successful: usize = 0;
    var failures: usize = 0;
    var checkpoint_residue: usize = 0;
    var candidate_residue: usize = 0;
    for (0..iterations) |index| {
        const sample = runOnce(init.io, init.gpa, bootstrap, candidate, &environment, index, false) catch |err| {
            std.debug.print("candidate input process {d} failed: {s}\n", .{ index, @errorName(err) });
            failures += 1;
            continue;
        };
        durations[successful] = sample.duration_ns;
        checkpoint_residue += sample.checkpoint_residue;
        candidate_residue += sample.candidate_residue;
        successful += 1;
    }
    _ = try runOnce(init.io, init.gpa, bootstrap, candidate, &environment, iterations, true);
    if (successful == 0) return error.NoSuccessfulRuns;
    const fd_after = try openFdCount(init.io);
    if (fd_after < fd_before) return error.ProcessInvariantFailed;
    std.mem.sort(u64, durations[0..successful], {}, std.sort.asc(u64));
    const times: report_mod.Times = .{ .median = durations[successful / 2], .p95 = durations[@min(successful - 1, (successful * 95 + 99) / 100 - 1)], .max = durations[successful - 1] };
    const report: report_mod.Report = .{ .schema = report_mod.schema, .iterations = iterations, .successful_runs = successful, .dmg_bytes = dmg_bytes, .executable_bytes = executable_bytes, .stage_ns = times, .failures = failures, .parent_fd_delta = fd_after - fd_before, .checkpoint_residue = checkpoint_residue, .candidate_residue = candidate_residue };
    var storage: [2048]u8 = undefined;
    const bytes = try report_mod.render(&storage, report);
    var parsed = try report_mod.parseCanonical(init.gpa, bytes);
    defer parsed.deinit();
    var output_buffer: [2048]u8 = undefined;
    var output_writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    try output_writer.interface.writeAll(bytes);
    try output_writer.interface.writeByte('\n');
    try output_writer.interface.flush();
    if (successful != iterations or failures != 0 or report.parent_fd_delta != 0 or checkpoint_residue != 0 or candidate_residue != 0)
        return error.ProcessInvariantFailed;
}

const Sample = struct { duration_ns: u64, checkpoint_residue: usize, candidate_residue: usize };

fn runOnce(io: std.Io, allocator: std.mem.Allocator, bootstrap: []const u8, candidate: []const u8, environment: *const std.process.Environ.Map, index: usize, expect_failure: bool) !Sample {
    var template_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const template = try std.fmt.bufPrintZ(&template_storage, "/private/tmp/maru-candidate-inputs-{d}.XXXXXX", .{index});
    const root: [:0]const u8 = std.mem.span(mkdtemp(template.ptr) orelse return error.TempRootFailed);
    var root_present = true;
    defer if (root_present) std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer root_dir.close(io);
    try root_dir.createDir(io, "checkpoint", .default_dir);
    try root_dir.createDir(io, "session-host-candidate-1.2.3", .default_dir);
    try root_dir.createDir(io, "session-host-candidate-1.2.3/Maru.app", .default_dir);
    try root_dir.createDir(io, "session-host-candidate-1.2.3/Maru.app/Contents", .default_dir);
    try root_dir.createDir(io, "session-host-candidate-1.2.3/Maru.app/Contents/MacOS", .default_dir);
    var checkpoint_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var candidate_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var frozen_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    var app_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const checkpoint_path = try std.fmt.bufPrintZ(&checkpoint_storage, "{s}/checkpoint", .{root});
    const candidate_path = try std.fmt.bufPrintZ(&candidate_storage, "{s}/session-host-candidate-1.2.3", .{root});
    const frozen_path = try std.fmt.bufPrintZ(&frozen_storage, "{s}/maru-session-host-1.2.3", .{candidate_path});
    const app_path = try std.fmt.bufPrintZ(&app_storage, "{s}/Maru.app/Contents/MacOS/maru-macos-app", .{candidate_path});
    if (c.chmod(checkpoint_path.ptr, 0o700) != 0 or c.chmod(candidate_path.ptr, 0o700) != 0) return error.PrivateRootFailed;
    const dmg = try allocator.alloc(u8, dmg_bytes);
    defer allocator.free(dmg);
    @memset(dmg, 'D');
    const executable = try allocator.alloc(u8, executable_bytes);
    defer allocator.free(executable);
    @memset(executable, 'E');
    try root_dir.writeFile(io, .{ .sub_path = "session-host-candidate-1.2.3/Maru-1.2.3-universal.dmg", .data = dmg });
    try root_dir.writeFile(io, .{ .sub_path = "session-host-candidate-1.2.3/maru-session-host-1.2.3", .data = executable });
    try root_dir.writeFile(io, .{ .sub_path = "session-host-candidate-1.2.3/Maru.app/Contents/MacOS/maru-macos-app", .data = executable });
    if (expect_failure) try root_dir.writeFile(io, .{ .sub_path = "session-host-candidate-1.2.3/foreign", .data = "foreign" });
    if (c.chmod(frozen_path.ptr, 0o755) != 0 or c.chmod(app_path.ptr, 0o755) != 0) return error.ExecutableModeFailed;
    const boot = try std.process.run(allocator, io, .{ .argv = &.{ bootstrap, "initialize", checkpoint_path }, .environ_map = environment, .stdout_limit = .limited(checkpoint.max_root_identity_token_bytes + 2), .stderr_limit = .limited(1) });
    defer allocator.free(boot.stdout);
    defer allocator.free(boot.stderr);
    switch (boot.term) {
        .exited => |code| if (code != 0) return error.BootstrapFailed,
        else => return error.BootstrapFailed,
    }
    if (boot.stderr.len != 0 or boot.stdout.len < 2 or boot.stdout[boot.stdout.len - 1] != '\n') return error.BootstrapFailed;
    const token = boot.stdout[0 .. boot.stdout.len - 1];
    const start = monotonicNs();
    const result = try std.process.run(allocator, io, .{ .argv = &.{ candidate, "pin", checkpoint_path, token, candidate_path }, .environ_map = environment, .stdout_limit = .limited(1), .stderr_limit = .limited(1) });
    const end = monotonicNs();
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if ((expect_failure and code == 0) or (!expect_failure and code != 0)) return error.CandidateFailed,
        else => return error.CandidateFailed,
    }
    if (result.stdout.len != 0 or result.stderr.len != 0) return error.UnexpectedOutput;
    if (expect_failure and try entryCount(io, checkpoint_path) != 2) return error.InvalidFailureCheckpoint;
    try std.Io.Dir.cwd().deleteTree(io, root);
    root_present = false;
    const checkpoint_residue: usize = if (std.Io.Dir.cwd().access(io, checkpoint_path, .{})) |_| 1 else |err| switch (err) {
        error.FileNotFound => 0,
        else => return err,
    };
    const candidate_residue: usize = if (std.Io.Dir.cwd().access(io, candidate_path, .{})) |_| 1 else |err| switch (err) {
        error.FileNotFound => 0,
        else => return err,
    };
    return .{ .duration_ns = end - start, .checkpoint_residue = checkpoint_residue, .candidate_residue = candidate_residue };
}

fn entryCount(io: std.Io, path: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

fn trustedEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    const values = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "GITHUB_REPOSITORY", .value = "ohah/maru" },                                                  .{ .key = "GITHUB_REPOSITORY_ID", .value = "12345" },
        .{ .key = "GITHUB_REF", .value = "refs/tags/v1.2.3" },                                                  .{ .key = "GITHUB_REF_TYPE", .value = "tag" },
        .{ .key = "GITHUB_REF_NAME", .value = "v1.2.3" },                                                       .{ .key = "GITHUB_SHA", .value = "0123456789abcdef0123456789abcdef01234567" },
        .{ .key = "GITHUB_WORKFLOW_REF", .value = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3" }, .{ .key = "GITHUB_RUN_ID", .value = "333" },
        .{ .key = "GITHUB_RUN_ATTEMPT", .value = "2" },                                                         .{ .key = "GITHUB_EVENT_NAME", .value = "push" },
        .{ .key = "GITHUB_REF_PROTECTED", .value = "true" },
    };
    for (values) |entry| try map.put(entry.key, entry.value);
    return map;
}

fn openFdCount(io: std.Io) !u64 {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/dev/fd", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: u64 = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

fn monotonicNs() u64 {
    var now: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC_RAW, &now) != 0) return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}
