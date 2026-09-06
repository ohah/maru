//! Actual-process harness and diagnostic measurement for aggregate prepare/finalize.

const std = @import("std");
const c = std.c;
const report_mod = @import("release_aggregate_process_report");
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

const max_iterations: usize = @intCast(report_mod.max_iterations);
const source_sha = "0123456789abcdef0123456789abcdef01234567";

const Times = report_mod.Times;

pub fn main(init: std.process.Init) !void {
    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();
    _ = arguments.next();
    const validator_input = arguments.next() orelse return error.MissingValidator;
    const verifier_input = arguments.next() orelse return error.MissingVerifier;
    const iteration_text = arguments.next() orelse return error.MissingIterations;
    if (arguments.next() != null) return error.TooManyArguments;
    const iterations = try std.fmt.parseInt(usize, iteration_text, 10);
    if (iterations == 0 or iterations > max_iterations) return error.InvalidIterations;

    const validator = try std.Io.Dir.cwd().realPathFileAlloc(init.io, validator_input, init.gpa);
    defer init.gpa.free(validator);
    const verifier = try std.Io.Dir.cwd().realPathFileAlloc(init.io, verifier_input, init.gpa);
    defer init.gpa.free(verifier);

    const verifier_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, verifier, init.gpa, .limited(128 * 1024 * 1024));
    defer init.gpa.free(verifier_bytes);
    var verifier_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier_bytes, &verifier_digest, .{});
    const verifier_sha = std.fmt.bytesToHex(verifier_digest, .lower);

    var root_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const root_template = try std.fmt.bufPrintZ(&root_storage, "/private/tmp/maru-release-aggregate-process.XXXXXX", .{});
    const root_ptr = mkdtemp(root_template.ptr) orelse return error.TempRootFailed;
    const root: [:0]const u8 = std.mem.span(root_ptr);
    defer std.Io.Dir.cwd().deleteTree(init.io, root) catch {};

    const warmup = try std.process.run(init.gpa, init.io, .{
        .argv = &.{"/usr/bin/true"},
        .stdout_limit = .limited(1),
        .stderr_limit = .limited(1),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
    defer init.gpa.free(warmup.stdout);
    defer init.gpa.free(warmup.stderr);
    try expectSuccess(warmup.term);
    try sealNonStdioForExec();
    const fd_before = try openFdCount(init.io);
    if (try runPair(init.io, init.gpa, validator, verifier_bytes, &verifier_sha, root, 10_000, .existing_destination) != null)
        return error.UnexpectedNegativeSample;
    if (try runPair(init.io, init.gpa, validator, verifier_bytes, &verifier_sha, root, 10_001, .inventory_drift) != null)
        return error.UnexpectedNegativeSample;
    if (try runPair(init.io, init.gpa, validator, verifier_bytes, &verifier_sha, root, 10_002, .verifier_failure) != null)
        return error.UnexpectedNegativeSample;
    if (try runPair(init.io, init.gpa, validator, verifier_bytes, &verifier_sha, root, 10_003, .verifier_timeout) != null)
        return error.UnexpectedNegativeSample;
    if (try runPair(init.io, init.gpa, validator, verifier_bytes, &verifier_sha, root, 10_004, .cli_drift) != null)
        return error.UnexpectedNegativeSample;
    if (try runPair(init.io, init.gpa, validator, verifier_bytes, &verifier_sha, root, 10_005, .artifact_drift) != null)
        return error.UnexpectedNegativeSample;
    var prepare_ns: [max_iterations]u64 = undefined;
    var handoff_gap_ns: [max_iterations]u64 = undefined;
    var finalize_ns: [max_iterations]u64 = undefined;
    var total_ns: [max_iterations]u64 = undefined;
    var successful_pairs: usize = 0;
    var distinct_pid_pairs: usize = 0;
    var failures: usize = 0;
    var aggregate_residue: usize = 0;
    var staging_residue: usize = 0;

    for (0..iterations) |index| {
        const sample = (runPair(init.io, init.gpa, validator, verifier_bytes, &verifier_sha, root, index, .success) catch |err| {
            std.debug.print("aggregate process pair {d} failed: {s}\n", .{ index, @errorName(err) });
            failures += 1;
            continue;
        }) orelse return error.MissingPositiveSample;
        prepare_ns[successful_pairs] = sample.prepare_ns;
        handoff_gap_ns[successful_pairs] = sample.handoff_gap_ns;
        finalize_ns[successful_pairs] = sample.finalize_ns;
        total_ns[successful_pairs] = sample.total_ns;
        successful_pairs += 1;
        if (sample.prepare_pid != 0 and sample.finalize_pid != 0 and sample.prepare_pid != sample.finalize_pid)
            distinct_pid_pairs += 1;
        aggregate_residue += sample.aggregate_residue;
        staging_residue += sample.staging_residue;
    }
    if (successful_pairs == 0) return error.NoSuccessfulPairs;
    const fd_after = try openFdCount(init.io);
    if (fd_after < fd_before) return error.ProcessInvariantFailed;
    const parent_fd_delta: u64 = fd_after - fd_before;

    const prepare_stats = statistics(prepare_ns[0..successful_pairs]);
    const handoff_stats = statistics(handoff_gap_ns[0..successful_pairs]);
    const finalize_stats = statistics(finalize_ns[0..successful_pairs]);
    const total_stats = statistics(total_ns[0..successful_pairs]);
    const report: report_mod.Report = .{
        .schema = report_mod.schema,
        .iterations = iterations,
        .successful_pairs = successful_pairs,
        .distinct_pid_pairs = distinct_pid_pairs,
        .prepare_ns = prepare_stats,
        .handoff_gap_ns = handoff_stats,
        .finalize_ns = finalize_stats,
        .total_ns = total_stats,
        .failures = failures,
        .parent_fd_delta = parent_fd_delta,
        .aggregate_residue = aggregate_residue,
        .staging_residue = staging_residue,
    };
    var report_storage: [2048]u8 = undefined;
    const report_bytes = try report_mod.render(&report_storage, report);
    var parsed = try report_mod.parseCanonical(init.gpa, report_bytes);
    defer parsed.deinit();
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(report_bytes);
    try stdout.writeByte('\n');
    try stdout.flush();
    if (successful_pairs != iterations or distinct_pid_pairs != iterations or failures != 0 or
        parent_fd_delta != 0 or aggregate_residue != 0 or staging_residue != 0) return error.ProcessInvariantFailed;
}

const Sample = struct {
    prepare_pid: c.pid_t,
    finalize_pid: c.pid_t,
    prepare_ns: u64,
    handoff_gap_ns: u64,
    finalize_ns: u64,
    total_ns: u64,
    aggregate_residue: usize,
    staging_residue: usize,
};

const Scenario = enum { success, existing_destination, inventory_drift, verifier_failure, verifier_timeout, cli_drift, artifact_drift };

fn runPair(io: std.Io, allocator: std.mem.Allocator, validator: []const u8, verifier_bytes: []const u8, verifier_sha: []const u8, root: []const u8, index: usize, scenario: Scenario) !?Sample {
    var pair_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const pair = try std.fmt.bufPrintZ(&pair_storage, "{s}/pair-{d}", .{ root, index });
    try std.Io.Dir.createDirAbsolute(io, pair, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, pair) catch {};
    var source_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    var durable_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    var artifacts_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    var tools_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const source = try childPath(&source_storage, pair, "source");
    const durable = try childPath(&durable_storage, pair, "durable");
    const artifacts = try childPath(&artifacts_storage, pair, "artifacts");
    const tools = try childPath(&tools_storage, pair, "tools");
    try std.Io.Dir.createDirAbsolute(io, source, .default_dir);
    try std.Io.Dir.createDirAbsolute(io, durable, .default_dir);
    try std.Io.Dir.createDirAbsolute(io, artifacts, .default_dir);
    try std.Io.Dir.createDirAbsolute(io, tools, .default_dir);

    var paths: [9][std.fs.max_path_bytes:0]u8 = @splat(@splat(0));
    const evidence = try childPath(&paths[0], source, "release-evidence.json");
    const dmg_bundle = try childPath(&paths[1], source, "dmg.bundle.json");
    const frozen_bundle = try childPath(&paths[2], source, "frozen.bundle.json");
    const evidence_bundle = try childPath(&paths[3], source, "evidence.bundle.json");
    const manifest_bundle = try childPath(&paths[4], source, "manifest.bundle.json");
    const aggregate = try childPath(&paths[5], durable, "candidate-aggregate");
    const dmg = try childPath(&paths[6], artifacts, "Maru-1.2.3-universal.dmg");
    const frozen = try childPath(&paths[7], artifacts, "maru-session-host-1.2.3");
    const manifest = try childPath(&paths[8], artifacts, "Maru-1.2.3-session-host-release.json");
    var verifier_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const verifier = try childPath(&verifier_storage, tools, "gh");
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = evidence, .data = "{\"schema\":\"maru.session-host-release-evidence.v1\"}\n" });
    try cwd.writeFile(io, .{ .sub_path = dmg_bundle, .data = "dmg bundle\n" });
    try cwd.writeFile(io, .{ .sub_path = frozen_bundle, .data = "frozen bundle\n" });
    try cwd.writeFile(io, .{ .sub_path = evidence_bundle, .data = "evidence bundle\n" });
    try cwd.writeFile(io, .{ .sub_path = manifest_bundle, .data = "manifest bundle\n" });
    try cwd.writeFile(io, .{ .sub_path = dmg, .data = "candidate dmg bytes\n" });
    try cwd.writeFile(io, .{ .sub_path = frozen, .data = "frozen executable bytes\n" });
    try cwd.writeFile(io, .{ .sub_path = manifest, .data = "manifest bytes\n" });
    try cwd.writeFile(io, .{ .sub_path = verifier, .data = verifier_bytes });
    if (c.chmod(frozen.ptr, 0o700) != 0) return error.FixtureFailed;
    if (c.chmod(verifier.ptr, 0o700) != 0) return error.FixtureFailed;
    if (scenario == .verifier_failure)
        try cwd.writeFile(io, .{ .sub_path = dmg_bundle, .data = "FAIL\n" });
    if (scenario == .verifier_timeout)
        try cwd.writeFile(io, .{ .sub_path = dmg_bundle, .data = "HANG\n" });
    if (scenario == .artifact_drift)
        try cwd.writeFile(io, .{ .sub_path = dmg_bundle, .data = "MUTATE\n" });
    if (scenario == .existing_destination) {
        try std.Io.Dir.createDirAbsolute(io, aggregate, .default_dir);
        var sentinel_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const sentinel = try childPath(&sentinel_storage, aggregate, "foreign");
        try cwd.writeFile(io, .{ .sub_path = sentinel, .data = "foreign\n" });
    }

    var environment = try trustedEnvironment(allocator);
    defer environment.deinit();
    if (index % 2 == 1) try environment.put("GH_TOKEN", "hostile-ambient-token");
    const prepare_args = [_][]const u8{
        validator,             "prepare-candidate-aggregate", "--repo",            "ohah/maru",     "--tag",                  "v1.2.3",   "--github-cli",              verifier,
        "--github-cli-sha256", verifier_sha,                  "--evidence",        evidence,        "--candidate-dmg-bundle", dmg_bundle, "--candidate-frozen-bundle", frozen_bundle,
        "--evidence-bundle",   evidence_bundle,               "--manifest-bundle", manifest_bundle, "--aggregate",            aggregate,
    };
    const total_started = monotonicNs();
    const prepare_started = total_started;
    if (scenario == .existing_destination) {
        try runClosedAuditRequired(io, allocator, &prepare_args, &environment, 30 * std.time.ns_per_s);
        if (try directoryEntryCount(io, aggregate) != 1) return error.ExistingDestinationMutated;
        return null;
    }
    var prepare_child = try std.process.spawn(io, .{ .argv = &prepare_args, .environ_map = &environment, .stdin = .close, .stdout = .close, .stderr = if (scenario == .success) .inherit else .close, .pgid = 0 });
    const prepare_pid = prepare_child.id orelse return error.MissingPid;
    const prepare_succeeded = try waitResult(&prepare_child, 30 * std.time.ns_per_s);
    const prepare_reaped = monotonicNs();
    if (!prepare_succeeded) return error.ChildFailed;

    if (scenario == .cli_drift) {
        const verifier_fd = c.open(verifier.ptr, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true });
        if (verifier_fd < 0) return error.FixtureFailed;
        defer _ = c.close(verifier_fd);
        if (c.write(verifier_fd, "x", 1) != 1) return error.FixtureFailed;
    }

    if (scenario == .inventory_drift) {
        var foreign_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const foreign = try childPath(&foreign_storage, aggregate, "foreign");
        try cwd.writeFile(io, .{ .sub_path = foreign, .data = "foreign\n" });
    }

    const finalize_args = [_][]const u8{
        validator,             "finalize-candidate-aggregate", "--repo",      "ohah/maru", "--tag", "v1.2.3", "--github-cli",        verifier,
        "--github-cli-sha256", verifier_sha,                   "--aggregate", aggregate,   "--dmg", dmg,      "--frozen-executable", frozen,
        "--manifest",          manifest,
    };
    const finalize_spawned = monotonicNs();
    if (scenario == .inventory_drift or scenario == .verifier_failure or scenario == .cli_drift or scenario == .artifact_drift) {
        try runClosedAuditRequired(io, allocator, &finalize_args, &environment, 30 * std.time.ns_per_s);
        if (scenario == .inventory_drift) {
            if (try directoryEntryCount(io, aggregate) != 6) return error.DurableAggregateMutated;
            var order_path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
            const order_path = try childPath(&order_path_storage, durable, "verify-order");
            if (cwd.access(io, order_path, .{})) |_| return error.UnexpectedVerifier else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
            return null;
        }
        if (try directoryEntryCount(io, aggregate) != 5) return error.DurableAggregateMutated;
        var order_path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const order_path = try childPath(&order_path_storage, durable, "verify-order");
        if (scenario == .artifact_drift) {
            const order_bytes = try cwd.readFileAlloc(io, order_path, allocator, .limited(128));
            defer allocator.free(order_bytes);
            if (!std.mem.eql(u8, order_bytes, "Maru-1.2.3-universal.dmg\n")) return error.VerificationOrderDrift;
        } else if (cwd.access(io, order_path, .{})) |_| {
            return error.UnexpectedVerifierPublication;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        return null;
    }
    var finalize_child = try std.process.spawn(io, .{ .argv = &finalize_args, .environ_map = &environment, .stdin = .close, .stdout = .close, .stderr = if (scenario == .success) .inherit else .close, .pgid = 0 });
    const finalize_pid = finalize_child.id orelse return error.MissingPid;
    const finalize_succeeded = waitResult(&finalize_child, if (scenario == .verifier_timeout) std.time.ns_per_s else 30 * std.time.ns_per_s) catch |err| switch (err) {
        error.ChildTimedOut => if (scenario == .verifier_timeout) false else return err,
        else => return err,
    };
    const finalize_reaped = monotonicNs();
    if (scenario == .verifier_timeout) {
        if (finalize_succeeded or try directoryEntryCount(io, aggregate) != 5) return error.DurableAggregateMutated;
        var order_path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
        const order_path = try childPath(&order_path_storage, durable, "verify-order");
        if (cwd.access(io, order_path, .{})) |_| {
            return error.UnexpectedVerifierPublication;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        return null;
    }
    if (!finalize_succeeded) return error.ChildFailed;

    const aggregate_count = try directoryEntryCount(io, aggregate);
    const stage_count = try stagingCount(io, durable);
    var order_path_storage: [std.fs.max_path_bytes:0]u8 = @splat(0);
    const order_path = try childPath(&order_path_storage, durable, "verify-order");
    const order_bytes = try cwd.readFileAlloc(io, order_path, allocator, .limited(256));
    defer allocator.free(order_bytes);
    const expected_order =
        "Maru-1.2.3-universal.dmg\n" ++
        "maru-session-host-1.2.3\n" ++
        "release-evidence.json\n" ++
        "Maru-1.2.3-session-host-release.json\n";
    if (!std.mem.eql(u8, order_bytes, expected_order)) return error.VerificationOrderDrift;
    try cwd.deleteTree(io, aggregate);
    if (cwd.access(io, aggregate, .{})) |_| return error.AggregateResidue else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    return .{
        .prepare_pid = prepare_pid,
        .finalize_pid = finalize_pid,
        .prepare_ns = prepare_reaped - prepare_started,
        .handoff_gap_ns = finalize_spawned - prepare_reaped,
        .finalize_ns = finalize_reaped - finalize_spawned,
        .total_ns = finalize_reaped - total_started,
        .aggregate_residue = if (aggregate_count == 5) 0 else aggregate_count,
        .staging_residue = stage_count,
    };
}

fn runClosedAuditRequired(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, environment: *const std.process.Environ.Map, timeout_ns: u64) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = environment,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
        .timeout = .{ .duration = .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 21) return error.UnexpectedOutcome,
        else => return error.UnexpectedOutcome,
    }
    if (result.stdout.len != 0 or !std.mem.eql(u8, result.stderr, "audit_required\n"))
        return error.UnexpectedOutcome;
}

fn trustedEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    const values = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "GITHUB_REPOSITORY", .value = "ohah/maru" },                                                  .{ .key = "GITHUB_REPOSITORY_ID", .value = "12345" },
        .{ .key = "GITHUB_REF", .value = "refs/tags/v1.2.3" },                                                  .{ .key = "GITHUB_REF_TYPE", .value = "tag" },
        .{ .key = "GITHUB_REF_NAME", .value = "v1.2.3" },                                                       .{ .key = "GITHUB_SHA", .value = source_sha },
        .{ .key = "GITHUB_WORKFLOW_REF", .value = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3" }, .{ .key = "GITHUB_RUN_ID", .value = "333" },
        .{ .key = "GITHUB_RUN_ATTEMPT", .value = "2" },                                                         .{ .key = "GITHUB_EVENT_NAME", .value = "push" },
        .{ .key = "GITHUB_REF_PROTECTED", .value = "true" },                                                    .{ .key = "GITHUB_WORKFLOW_SHA", .value = source_sha },
        .{ .key = "RUNNER_ENVIRONMENT", .value = "github-hosted" },                                             .{ .key = "RUNNER_OS", .value = "macOS" },
        .{ .key = "RUNNER_ARCH", .value = "ARM64" },
    };
    for (values) |entry| try map.put(entry.key, entry.value);
    return map;
}

fn childPath(storage: *[std.fs.max_path_bytes:0]u8, parent: []const u8, leaf: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ parent, leaf });
}

fn expectSuccess(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }
}

fn waitSuccess(child: *std.process.Child, timeout_ns: u64) !void {
    if (!try waitResult(child, timeout_ns)) return error.ChildFailed;
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

fn directoryEntryCount(io: std.Io, path: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

fn stagingCount(io: std.Io, path: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| if (std.mem.startsWith(u8, entry.name, ".maru-aggregate-")) {
        count += 1;
    };
    return count;
}

fn openFdCount(io: std.Io) !u32 {
    return @intCast(try directoryEntryCount(io, "/dev/fd"));
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
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn statistics(values: []u64) Times {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const p95_index = (values.len * 95 + 99) / 100 - 1;
    return .{ .median = values[values.len / 2], .p95 = values[p95_index], .max = values[values.len - 1] };
}
