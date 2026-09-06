//! Spawn/reap measurement for fixed workflow checkpoints across actual processes.

const std = @import("std");
const c = std.c;
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");
const report_mod = @import("release_workflow_checkpoint_process_report");
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn usleep(usec: c_uint) c_int;

const stages = [_]phase.Stage{ .candidate_pinning, .candidate_attestation, .draft_authoring, .authored_attestation, .aggregate_prepare, .aggregate_finalize, .publication, .aggregate_cleanup };
const max_iterations: usize = @intCast(report_mod.max_iterations);

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const child_input = args.next() orelse return error.MissingChild;
    const iteration_text = args.next() orelse return error.MissingIterations;
    if (args.next() != null) return error.TooManyArguments;
    const iterations = try std.fmt.parseInt(usize, iteration_text, 10);
    if (iterations == 0 or iterations > max_iterations) return error.InvalidIterations;
    const child = try std.Io.Dir.cwd().realPathFileAlloc(init.io, child_input, init.gpa);
    defer init.gpa.free(child);
    try sealNonStdioForExec();
    const fd_before = try openFdCount(init.io);
    var init_ns: [max_iterations]u64 = undefined;
    var stages_ns: [max_iterations]u64 = undefined;
    var total_ns: [max_iterations]u64 = undefined;
    var successful: usize = 0;
    var distinct: usize = 0;
    var failures: usize = 0;
    var leaf_residue: usize = 0;
    var root_residue: usize = 0;
    for (0..iterations) |index| {
        const sample = runOnce(init.io, init.gpa, child, index) catch |err| {
            std.debug.print("workflow checkpoint process {d} failed: {s}\n", .{ index, @errorName(err) });
            failures += 1;
            continue;
        };
        init_ns[successful] = sample.init_ns;
        stages_ns[successful] = sample.stages_ns;
        total_ns[successful] = sample.total_ns;
        leaf_residue += sample.leaf_residue;
        root_residue += sample.root_residue;
        if (sample.distinct) distinct += 1;
        successful += 1;
    }
    if (successful == 0) return error.NoSuccessfulRuns;
    const fd_after = try openFdCount(init.io);
    if (fd_after < fd_before) return error.ProcessInvariantFailed;
    const report: report_mod.Report = .{
        .schema = report_mod.schema,
        .iterations = iterations,
        .successful_runs = successful,
        .distinct_pid_runs = distinct,
        .init_ns = statistics(init_ns[0..successful]),
        .stages_ns = statistics(stages_ns[0..successful]),
        .total_ns = statistics(total_ns[0..successful]),
        .failures = failures,
        .parent_fd_delta = fd_after - fd_before,
        .leaf_residue = leaf_residue,
        .root_residue = root_residue,
    };
    var storage: [2048]u8 = undefined;
    const bytes = try report_mod.render(&storage, report);
    var parsed = try report_mod.parseCanonical(init.gpa, bytes);
    defer parsed.deinit();
    var output_buffer: [2048]u8 = undefined;
    var output_writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    try output_writer.interface.writeAll(bytes);
    try output_writer.interface.writeByte('\n');
    try output_writer.interface.flush();
    if (successful != iterations or distinct != iterations or failures != 0 or report.parent_fd_delta != 0 or leaf_residue != 0 or root_residue != 0)
        return error.ProcessInvariantFailed;
}

const Sample = struct { init_ns: u64, stages_ns: u64, total_ns: u64, distinct: bool, leaf_residue: usize, root_residue: usize };

fn runOnce(io: std.Io, allocator: std.mem.Allocator, child: []const u8, index: usize) !Sample {
    var template_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const template = try std.fmt.bufPrintZ(&template_storage, "/private/tmp/maru-workflow-checkpoint-{d}.XXXXXX", .{index});
    const root_ptr = mkdtemp(template.ptr) orelse return error.TempRootFailed;
    const root: [:0]const u8 = std.mem.span(root_ptr);
    if (c.chmod(root.ptr, 0o700) != 0) return error.TempRootFailed;
    var root_present = true;
    defer if (root_present) std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var initial_root: checkpoint.Root = .{};
    try checkpoint.openRoot(&initial_root, root);
    const identity = try initial_root.value();
    try initial_root.deinit();
    var identity_storage: [checkpoint.max_root_identity_token_bytes:0]u8 = undefined;
    const identity_token = try checkpoint.encodeRootIdentity(&identity_storage, identity);
    const total_start = monotonicNs();
    const init_start = total_start;
    var pids: [9]c.pid_t = undefined;
    pids[0] = try runChild(io, &.{ child, root, "init", identity_token });
    const init_end = monotonicNs();
    const stages_start = init_end;
    for (stages, 0..) |stage, stage_index|
        pids[stage_index + 1] = try runChild(io, &.{ child, root, "advance", identity_token, @tagName(stage) });
    const stages_end = monotonicNs();
    var authority: checkpoint.Root = .{};
    try checkpoint.openRoot(&authority, root);
    var authority_open = true;
    defer {
        if (authority_open) authority.deinit() catch {};
    }
    const final = try checkpoint.reopen(allocator, &authority, 8, workflowContext());
    if (final.outcome != .succeeded or try entryCount(io, root) != checkpoint.leaf_count) return error.InvalidFinalState;
    var all_distinct = true;
    for (pids, 0..) |left, left_index| for (pids[left_index + 1 ..]) |right| if (left == 0 or left == right) {
        all_distinct = false;
    };
    try authority.deinit();
    authority_open = false;
    try std.Io.Dir.cwd().deleteTree(io, root);
    root_present = false;
    const root_residue: usize = if (std.Io.Dir.cwd().access(io, root, .{})) |_| 1 else |err| switch (err) {
        error.FileNotFound => 0,
        else => return err,
    };
    return .{ .init_ns = init_end - init_start, .stages_ns = stages_end - stages_start, .total_ns = monotonicNs() - total_start, .distinct = all_distinct, .leaf_residue = 0, .root_residue = root_residue };
}

fn runChild(io: std.Io, argv: []const []const u8) !c.pid_t {
    var process = try std.process.spawn(io, .{ .argv = argv, .stdin = .close, .stdout = .close, .stderr = .inherit, .pgid = 0 });
    const pid = process.id orelse return error.MissingPid;
    if (!try waitResult(&process, 10 * std.time.ns_per_s)) return error.ChildFailed;
    return pid;
}

fn waitResult(child: *std.process.Child, timeout_ns: u64) !bool {
    const pid = child.id orelse return error.MissingPid;
    const deadline = monotonicNs() + timeout_ns;
    var status: c_int = undefined;
    while (monotonicNs() < deadline) {
        const waited = c.waitpid(pid, &status, c.W.NOHANG);
        if (waited == pid) {
            child.id = null;
            const unsigned: u32 = @bitCast(status);
            return c.W.IFEXITED(unsigned) and c.W.EXITSTATUS(unsigned) == 0;
        }
        if (waited < 0 and std.posix.errno(waited) != .INTR) return error.WaitFailed;
        _ = usleep(1_000);
    }
    _ = c.kill(-pid, std.posix.SIG.KILL);
    while (c.waitpid(pid, &status, 0) < 0 and std.posix.errno(-1) == .INTR) {}
    child.id = null;
    return error.ChildTimedOut;
}

fn entryCount(io: std.Io, root: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

fn openFdCount(io: std.Io) !u64 {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/dev/fd", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: u64 = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

fn sealNonStdioForExec() !void {
    var fd: c_int = 3;
    while (fd < 1024) : (fd += 1) {
        const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
        if (flags < 0) continue;
        if (c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0) return error.DescriptorSealFailed;
    }
}

fn monotonicNs() u64 {
    var now: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC_RAW, &now) != 0) return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn statistics(values: []u64) report_mod.Times {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return .{ .median = values[values.len / 2], .p95 = values[@min(values.len - 1, (values.len * 95 + 99) / 100 - 1)], .max = values[values.len - 1] };
}

fn workflowContext() context.Context {
    return .{
        .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = "0123456789abcdef0123456789abcdef01234567",
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .protected_tag = true,
    };
}
