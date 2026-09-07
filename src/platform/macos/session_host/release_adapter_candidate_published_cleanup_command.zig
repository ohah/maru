//! Sealed executable owner for stage-8 published aggregate cleanup.

const std = @import("std");
const builtin = @import("builtin");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const deadline_mod = @import("release_adapter_deadline");
const reopen_mod = @import("release_adapter_candidate_aggregate_reopen");
const cleanup_recovery = @import("release_adapter_candidate_aggregate_cleanup_recovery");
const published_authority = @import("release_adapter_candidate_published_cleanup_authority");
const post = @import("release_adapter_github_post_publish_attestation");
const outcome_contract = @import("release_adapter_command_outcome");

pub const Bootstrap = bootstrap_mod.Bootstrap;
pub const Plan = cleanup_recovery.Plan;
pub const max_response_bytes: usize = 64 * 1024;
pub const timing_schema = "maru.session-host-release-cleanup-command-perf.v1";
pub const Sample = enum { live, injected };

pub const Outcome = outcome_contract.Cleanup;
pub const exitCode = outcome_contract.cleanupExitCode;
pub const stderrLine = outcome_contract.cleanupStderrLine;

const StoredPath = struct {
    len: usize = 0,
    bytes: [std.fs.max_path_bytes:0]u8 = @splat(0),

    fn set(self: *@This(), path: []const u8) !void {
        if (path.len == 0 or path.len >= self.bytes.len or std.mem.indexOfScalar(u8, path, 0) != null)
            return error.InvalidBootstrap;
        @memcpy(self.bytes[0..path.len], path);
        self.bytes[path.len] = 0;
        self.len = path.len;
    }

    fn value(self: *const @This()) [:0]const u8 {
        return self.bytes[0..self.len :0];
    }
};

pub const Execution = struct {
    owner: ?*Execution = null,
    bootstrap: ?*Bootstrap = null,
    aggregate_path: StoredPath = .{},
    dmg_path: StoredPath = .{},
    frozen_path: StoredPath = .{},
    manifest_path: StoredPath = .{},
    aggregate: reopen_mod.ReopenedAggregate = .{},
    verified: post.VerifiedRelease = .{},
    recovery: cleanup_recovery.Recovery = .{},
    deadline: deadline_mod.Deadline = .{},
    remote_timing: published_authority.Timing = .{},
    classification_ns: u64 = 0,
    cleanup_ns: u64 = 0,
    total_ns: u64 = 0,
    timing_len: usize = 0,
    timing: [768]u8 = @splat(0),
    authority_digest: [32]u8 = @splat(0),

    pub fn isPristine(self: *const @This()) bool {
        return self.owner == null and self.bootstrap == null and self.aggregate.owner == null and
            self.verified.value() == null and self.recovery.isPristine() and self.deadline.isPristineForComposition() and
            storedPathPristine(&self.aggregate_path) and storedPathPristine(&self.dmg_path) and
            storedPathPristine(&self.frozen_path) and storedPathPristine(&self.manifest_path) and
            self.remote_timing.first_lookup_ns == null and self.remote_timing.attestation_ns == null and
            self.remote_timing.final_lookup_ns == null and self.classification_ns == 0 and self.cleanup_ns == 0 and
            self.total_ns == 0 and self.timing_len == 0 and std.mem.allEqual(u8, &self.timing, 0) and
            std.mem.allEqual(u8, &self.authority_digest, 0);
    }

    pub fn timingLine(self: *const @This()) []const u8 {
        return self.timing[0..self.timing_len];
    }
};

pub fn testingExecuteWith(driver: anytype) Outcome {
    if (!builtin.is_test) @compileError("published cleanup command driver is test-only");
    return executeWith(driver);
}

fn executeWith(driver: anytype) Outcome {
    const plan = driver.classify() catch |err| {
        driver.settle() catch return .descriptor_close_failed;
        return if (err == error.DescriptorCloseFailed) .descriptor_close_failed else .audit_required;
    };

    const outcome: Outcome = switch (plan) {
        .audit_required => .audit_required,
        .recoverable => driver.recover() catch .audit_required,
        .initial => blk: {
            driver.startDeadline() catch break :blk .audit_required;
            driver.reopen() catch break :blk .audit_required;
            driver.readToken() catch break :blk .audit_required;
            driver.authenticate() catch break :blk .audit_required;
            break :blk driver.begin() catch .audit_required;
        },
    };
    driver.settle() catch return .descriptor_close_failed;
    if (outcome == .success) driver.publishTiming() catch return .cleanup_required;
    return outcome;
}

pub fn runOutcome(
    io: std.Io,
    allocator: std.mem.Allocator,
    bootstrap: *Bootstrap,
    token_reader: anytype,
    response: []u8,
    budget_ns: i128,
    execution: *Execution,
) Outcome {
    if (!execution.isPristine() or response.len == 0 or response.len > max_response_bytes or budget_ns <= 0)
        return .audit_required;
    const view = bootstrapView(bootstrap) catch return .audit_required;
    const command = switch (view.command) {
        .cleanup_candidate_aggregate => |value| value,
        else => return .audit_required,
    };
    var aggregate_path: StoredPath = .{};
    var dmg_path: StoredPath = .{};
    var frozen_path: StoredPath = .{};
    var manifest_path: StoredPath = .{};
    aggregate_path.set(command.aggregate) catch return .audit_required;
    dmg_path.set(command.dmg) catch return .audit_required;
    frozen_path.set(command.frozen_executable) catch return .audit_required;
    manifest_path.set(command.manifest) catch return .audit_required;
    validateBaseAliases(execution, bootstrap, view, command, response) catch return .audit_required;
    execution.* = .{
        .owner = execution,
        .bootstrap = bootstrap,
        .aggregate_path = aggregate_path,
        .dmg_path = dmg_path,
        .frozen_path = frozen_path,
        .manifest_path = manifest_path,
    };
    execution.authority_digest = executionAuthorityDigest(execution, view) catch {
        execution.* = .{};
        return .audit_required;
    };
    const started = monotonicNow() catch {
        execution.* = .{};
        return .audit_required;
    };
    var driver = ConcreteDriver(@TypeOf(token_reader)){
        .io = io,
        .allocator = allocator,
        .token_reader = token_reader,
        .response = response,
        .budget_ns = budget_ns,
        .execution = execution,
        .total_started = started,
    };
    return executeWith(&driver);
}

fn ConcreteDriver(comptime TokenReader: type) type {
    return struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        token_reader: TokenReader,
        response: []u8,
        budget_ns: i128,
        execution: *Execution,
        token: []const u8 = "",
        total_started: u64,

        pub fn classify(self: *@This()) !Plan {
            const started = try monotonicNow();
            const view = try activeView(self.execution);
            const plan = try cleanup_recovery.classify(self.allocator, view.context, self.execution.aggregate_path.value());
            self.execution.classification_ns = try elapsedSince(started);
            return plan;
        }

        pub fn recover(self: *@This()) !Outcome {
            const view = try activeView(self.execution);
            const started = try monotonicNow();
            const outcome = try cleanup_recovery.recover(
                self.allocator,
                view.context,
                self.execution.aggregate_path.value(),
                &self.execution.recovery,
            );
            self.execution.cleanup_ns = try elapsedSince(started);
            return recoveryOutcome(outcome);
        }

        pub fn startDeadline(self: *@This()) !void {
            try deadline_mod.start(self.budget_ns, &self.execution.deadline);
        }

        pub fn reopen(self: *@This()) !void {
            const view = try activeView(self.execution);
            try reopen_mod.openAndVerifyUntil(self.io, self.allocator, view.context, .{
                .directory = self.execution.aggregate_path.value(),
                .dmg = self.execution.dmg_path.value(),
                .frozen_executable = self.execution.frozen_path.value(),
                .manifest = self.execution.manifest_path.value(),
            }, .{ .path = view.github_cli, .pinned = &self.execution.bootstrap.?.cli }, self.response, &self.execution.deadline, &self.execution.aggregate);
        }

        pub fn readToken(self: *@This()) !void {
            self.token = try self.token_reader.read();
            if (self.token.len == 0) return error.InvalidToken;
            const view = try activeView(self.execution);
            const command = switch (view.command) {
                .cleanup_candidate_aggregate => |value| value,
                else => return error.InvalidCommand,
            };
            try validateTokenAliases(self.execution, self.execution.bootstrap.?, view, command, self.token, self.response);
        }

        pub fn authenticate(self: *@This()) !void {
            const view = try activeView(self.execution);
            try published_authority.authenticateUntilObserved(
                self.io,
                self.allocator,
                &self.execution.aggregate,
                .{ .path = view.github_cli, .pinned = &self.execution.bootstrap.?.cli },
                self.token,
                self.response,
                &self.execution.deadline,
                &self.execution.remote_timing,
                &self.execution.verified,
            );
        }

        pub fn begin(self: *@This()) !Outcome {
            const started = try monotonicNow();
            const outcome = try cleanup_recovery.begin(self.allocator, &self.execution.aggregate, &self.execution.verified, &self.execution.recovery);
            self.execution.cleanup_ns = try elapsedSince(started);
            return recoveryOutcome(outcome);
        }

        pub fn settle(self: *@This()) !void {
            var failed = false;
            if (self.execution.verified.value() != null) self.execution.verified.deinit() catch {
                failed = true;
            };
            if (self.execution.aggregate.owner != null) self.execution.aggregate.deinit() catch {
                failed = true;
            };
            if (self.execution.deadline.owner != null) self.execution.deadline.deinit() catch {
                failed = true;
            };
            self.token = "";
            self.execution.bootstrap = null;
            if (failed) return error.DescriptorCloseFailed;
        }

        pub fn publishTiming(self: *@This()) !void {
            self.execution.total_ns = try elapsedSince(self.total_started);
            self.execution.timing_len = try formatTiming(self.execution, .live);
        }
    };
}

fn activeView(execution: *Execution) !bootstrap_mod.View {
    if (execution.owner != execution or execution.bootstrap == null or execution.bootstrap.?.owner != execution.bootstrap.?)
        return error.InvalidOwner;
    const view = bootstrapView(execution.bootstrap.?) catch return error.InvalidOwner;
    const digest = try executionAuthorityDigest(execution, view);
    if (!std.mem.eql(u8, &execution.authority_digest, &digest)) return error.AuthorityChanged;
    return view;
}

fn recoveryOutcome(value: cleanup_recovery.Outcome) Outcome {
    return switch (value) {
        .success => .success,
        .audit_required => .audit_required,
        .cleanup_required => .cleanup_required,
        .descriptor_close_failed => .descriptor_close_failed,
    };
}

fn formatTiming(execution: *Execution, sample: Sample) !usize {
    const first = nullableNumber(execution.remote_timing.first_lookup_ns);
    const attest = nullableNumber(execution.remote_timing.attestation_ns);
    const final = nullableNumber(execution.remote_timing.final_lookup_ns);
    const line = try std.fmt.bufPrint(&execution.timing, "{{\"schema\":\"{s}\",\"sample\":\"{s}\",\"classification_ns\":{d},\"first_lookup_ns\":{s},\"attestation_ns\":{s},\"final_lookup_ns\":{s},\"cleanup_ns\":{d},\"total_ns\":{d}}}\n", .{ timing_schema, @tagName(sample), execution.classification_ns, first.value(), attest.value(), final.value(), execution.cleanup_ns, execution.total_ns });
    return line.len;
}

pub fn testingFormatTiming(execution: *Execution, sample: Sample) ![]const u8 {
    if (!builtin.is_test) @compileError("published cleanup timing formatter is test-only");
    execution.timing_len = try formatTiming(execution, sample);
    return execution.timingLine();
}

fn executionAuthorityDigest(execution: *const Execution, view: bootstrap_mod.View) ![32]u8 {
    const command = switch (view.command) {
        .cleanup_candidate_aggregate => |value| value,
        else => return error.InvalidCommand,
    };
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.session-host.published-cleanup-command.authority.v1\x00");
    var address: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &address, @intFromPtr(execution), .little);
    hasher.update(&address);
    hasher.update(std.mem.asBytes(&view.context.repository.id));
    hasher.update(std.mem.asBytes(&view.context.build.run_id));
    hasher.update(std.mem.asBytes(&view.context.build.run_attempt));
    hasher.update(std.mem.asBytes(&view.context.protected_tag));
    hasher.update(&view.runner.workflow_sha);
    const fields = [_][]const u8{
        view.context.repository.owner, view.context.repository.name,     view.context.tag,
        view.context.source_commit,    view.context.build.workflow_ref,  view.github_cli,
        &view.cli.sha256,              command.repo,                     command.tag,
        command.aggregate,             command.dmg,                      command.frozen_executable,
        command.manifest,              execution.aggregate_path.value(), execution.dmg_path.value(),
        execution.frozen_path.value(), execution.manifest_path.value(),
    };
    for (fields) |field| {
        hasher.update(std.mem.asBytes(&field.len));
        hasher.update(field);
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn bootstrapView(bootstrap: *Bootstrap) !bootstrap_mod.View {
    if (bootstrap.owner != bootstrap or bootstrap.cli_path_len >= bootstrap.cli_path_storage.len or
        bootstrap.cli_path_storage[bootstrap.cli_path_len] != 0) return error.InvalidBootstrap;
    return bootstrap.value() orelse error.InvalidBootstrap;
}

fn validateBaseAliases(execution: *Execution, bootstrap: *Bootstrap, view: bootstrap_mod.View, command: bootstrap_mod.CleanupCandidateAggregate, response: []u8) !void {
    const owner = std.mem.asBytes(execution);
    const boot = std.mem.asBytes(bootstrap);
    try validateFourAliases(owner, boot, response, &.{});
    const borrowed = [_][]const u8{
        view.context.repository.owner, view.context.repository.name,    view.context.tag,
        view.context.source_commit,    view.context.build.workflow_ref, command.repo,
        command.tag,                   command.aggregate,               command.dmg,
        command.frozen_executable,     command.manifest,
    };
    for (borrowed, 0..) |value, index| {
        if (overlaps(owner, value) or overlaps(boot, value) or overlaps(response, value)) return error.InvalidOwner;
        for (borrowed[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
    }
}

fn validateTokenAliases(execution: *Execution, bootstrap: *Bootstrap, view: bootstrap_mod.View, command: bootstrap_mod.CleanupCandidateAggregate, token: []const u8, response: []u8) !void {
    const owner = std.mem.asBytes(execution);
    const boot = std.mem.asBytes(bootstrap);
    try validateFourAliases(owner, boot, response, token);
    const borrowed = [_][]const u8{
        view.context.repository.owner, view.context.repository.name,    view.context.tag,
        view.context.source_commit,    view.context.build.workflow_ref, view.github_cli,
        command.repo,                  command.tag,                     command.aggregate,
        command.dmg,                   command.frozen_executable,       command.manifest,
    };
    for (borrowed) |value|
        if (overlaps(owner, value) or overlaps(token, value) or overlaps(response, value)) return error.InvalidOwner;
}

fn validateFourAliases(first: []const u8, second: []const u8, third: []const u8, fourth: []const u8) !void {
    const regions = [_][]const u8{ first, second, third, fourth };
    for (regions, 0..) |left, index| for (regions[index + 1 ..]) |right|
        if (overlaps(left, right)) return error.InvalidOwner;
}

pub fn testingValidateAliases(first: []const u8, second: []const u8, third: []const u8, fourth: []const u8) !void {
    if (!builtin.is_test) @compileError("published cleanup alias validator is test-only");
    return validateFourAliases(first, second, third, fourth);
}

fn storedPathPristine(path: *const StoredPath) bool {
    return path.len == 0 and std.mem.allEqual(u8, &path.bytes, 0);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

const NullableNumber = struct {
    bytes: [32]u8 = @splat(0),
    len: usize = 0,
    fn value(self: *const @This()) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn nullableNumber(value: ?u64) NullableNumber {
    var result: NullableNumber = .{};
    if (value) |number| {
        const rendered = std.fmt.bufPrint(&result.bytes, "{d}", .{number}) catch unreachable;
        result.len = rendered.len;
    } else {
        @memcpy(result.bytes[0..4], "null");
        result.len = 4;
    }
    return result;
}

fn monotonicNow() !u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return error.ClockFailed;
    return std.math.add(u64, try std.math.mul(u64, @intCast(ts.sec), std.time.ns_per_s), @intCast(ts.nsec));
}

fn elapsedSince(started: u64) !u64 {
    const now = try monotonicNow();
    if (now < started) return error.ClockFailed;
    return now - started;
}

pub fn assertProductionBoundary() void {
    _ = &runOutcome;
}
