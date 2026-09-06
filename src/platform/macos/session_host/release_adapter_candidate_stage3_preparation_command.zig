//! Sealed executable owner for the stage-3 durable preparation command.

const std = @import("std");
const builtin = @import("builtin");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const source_authority = @import("release_adapter_source_directory_authority");
const zig_authority = @import("release_adapter_zig_toolchain_authority");
const stage3_product = @import("release_adapter_candidate_stage3_preparation_product");

pub const Bootstrap = bootstrap_mod.Bootstrap;
pub const max_scratch_bytes: usize = 64 * 1024;

pub const Outcome = enum { success, local_failure, audit_required, cleanup_failed };

pub fn exitCode(outcome: Outcome) u8 {
    return switch (outcome) {
        .success => 0,
        .local_failure => 20,
        .audit_required => 21,
        .cleanup_failed => 22,
    };
}

pub fn stderrLine(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .success => "success\n",
        .local_failure => "local_failure\n",
        .audit_required => "audit_required\n",
        .cleanup_failed => "cleanup_failed\n",
    };
}

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

const Paths = struct {
    dmg: StoredPath = .{},
    frozen: StoredPath = .{},
    candidate_dmg_bundle: StoredPath = .{},
    candidate_frozen_bundle: StoredPath = .{},
    dmg_work: StoredPath = .{},
    baseline: StoredPath = .{},
    app_main: StoredPath = .{},
    app_cli: StoredPath = .{},
    manifest: StoredPath = .{},
    zig: StoredPath = .{},
    durable: StoredPath = .{},
};

pub const Execution = struct {
    owner: ?*Execution = null,
    source: source_authority.SourceDirectory = .{},
    toolchain: zig_authority.ZigToolchainAuthority = .{},
    product: stage3_product.Execution = .{},
    paths: Paths = .{},
    bootstrap_sha256: [32]u8 = @splat(0),
    paths_sha256: [32]u8 = @splat(0),
    seal: [32]u8 = @splat(0),
    bootstrap: ?*Bootstrap = null,
    token: []const u8 = "",
    scratch: []u8 = &.{},
    budget_ns: i128 = 0,
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and sourcePristine(&self.source) and toolchainPristine(&self.toolchain) and
            self.product.isPristineForComposition() and pathsPristine(&self.paths) and
            allZero(&self.bootstrap_sha256) and allZero(&self.paths_sha256) and
            allZero(&self.seal) and !self.hasBorrowed();
    }

    pub fn needsAudit(self: *const @This()) bool {
        return self.validSeal() and self.product.needsAudit() and !self.hasBorrowed();
    }

    pub fn localCleanupComplete(self: *const @This()) bool {
        return self.needsAudit() and self.product.transaction.localCleanupComplete() and
            sourcePristine(&self.source) and toolchainPristine(&self.toolchain);
    }

    pub fn retryCleanup(self: *@This()) !void {
        if (!self.validSeal() or self.needsAudit() or self.hasBorrowed()) return error.InvalidOwner;
        if (self.product.transaction.needsCleanup()) try self.product.retryCleanup();
        if (!self.product.isPristineForComposition()) return error.CleanupFailed;
        try self.cleanupAuthorities();
        self.* = .{};
    }

    pub fn retryAuditCleanup(self: *@This()) !void {
        if (!self.needsAudit()) return error.InvalidOwner;
        if (!self.product.transaction.localCleanupComplete()) try self.product.retryAuditCleanup();
        try self.cleanupAuthorities();
        if (!self.localCleanupComplete()) return error.CleanupFailed;
    }

    fn validSeal(self: *const @This()) bool {
        const digest = pathsDigest(&self.paths) catch return false;
        return self.owner == self and std.mem.eql(u8, &self.paths_sha256, &digest) and
            std.mem.eql(u8, &self.seal, &driverSeal(self));
    }

    fn requireActive(self: *const @This(), view: bootstrap_mod.View) !void {
        if (!self.validSeal() or !std.mem.eql(u8, &self.bootstrap_sha256, &bootstrapDigest(view)))
            return error.AuthorityChanged;
    }

    fn hasBorrowed(self: *const @This()) bool {
        return self.bootstrap != null or self.token.len != 0 or self.scratch.len != 0 or self.budget_ns != 0;
    }

    fn clearBorrowed(self: *@This()) void {
        self.bootstrap = null;
        self.token = "";
        self.scratch = &.{};
        self.budget_ns = 0;
    }

    fn cleanupAuthorities(self: *@This()) !void {
        var failed = false;
        if (!toolchainPristine(&self.toolchain)) self.toolchain.deinit() catch {
            failed = true;
        };
        if (!sourcePristine(&self.source)) self.source.deinit() catch {
            failed = true;
        };
        if (failed) return error.CleanupFailed;
    }
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    bootstrap: *Bootstrap,
    token: []const u8,
    scratch: []u8,
    budget_ns: i128,
    execution: *Execution,
) !void {
    if (!execution.isPristineForComposition() or budget_ns <= 0 or scratch.len == 0 or scratch.len > max_scratch_bytes)
        return error.InvalidOwner;
    const view = try bootstrapView(bootstrap);
    const command = switch (view.command) {
        .prepare_candidate => |value| value,
        else => return error.InvalidCommand,
    };
    try validateAliases(execution, bootstrap, view, command, token, scratch);

    var paths: Paths = .{};
    try paths.dmg.set(command.dmg);
    try paths.frozen.set(command.frozen_executable);
    try paths.candidate_dmg_bundle.set(command.candidate_dmg_bundle);
    try paths.candidate_frozen_bundle.set(command.candidate_frozen_bundle);
    try paths.dmg_work.set(command.dmg_work);
    try paths.baseline.set(command.baseline_workspace);
    try paths.app_main.set(command.app_main_executable);
    try paths.app_cli.set(command.app_cli_executable);
    try paths.manifest.set(command.manifest);
    try paths.zig.set(command.zig);
    try paths.durable.set(command.durable_preparation);

    execution.* = .{
        .owner = execution,
        .paths = paths,
        .bootstrap_sha256 = bootstrapDigest(view),
        .paths_sha256 = try pathsDigest(&paths),
        .bootstrap = bootstrap,
        .token = token,
        .scratch = scratch,
        .budget_ns = budget_ns,
        .io = io,
        .allocator = allocator,
    };
    execution.seal = driverSeal(execution);
    runActive(execution, view, command) catch |err| {
        execution.clearBorrowed();
        return err;
    };
    execution.clearBorrowed();
    execution.cleanupAuthorities() catch return error.CleanupFailed;
    execution.* = .{};
}

pub fn runOutcome(
    io: std.Io,
    allocator: std.mem.Allocator,
    bootstrap: *Bootstrap,
    token: []const u8,
    scratch: []u8,
    budget_ns: i128,
    execution: *Execution,
) Outcome {
    run(io, allocator, bootstrap, token, scratch, budget_ns, execution) catch
        return settleExecution(execution);
    return .success;
}

fn runActive(execution: *Execution, view: bootstrap_mod.View, command: bootstrap_mod.PrepareCandidate) !void {
    try execution.requireActive(view);
    try source_authority.prepareCurrent(&execution.source, execution.bootstrap.?);
    try execution.requireActive(bootstrapView(execution.bootstrap.?) catch return error.AuthorityChanged);
    try execution.source.revalidate(execution.bootstrap.?);
    var digest: [64]u8 = undefined;
    @memcpy(&digest, command.zig_sha256);
    try zig_authority.bind(view.context, view.runner, execution.paths.zig.value(), .{
        .size = command.zig_size,
        .sha256 = digest,
    }, &execution.toolchain);
    const current_view = bootstrapView(execution.bootstrap.?) catch return error.AuthorityChanged;
    try execution.requireActive(current_view);
    try execution.source.revalidate(execution.bootstrap.?);
    _ = try execution.toolchain.revalidate();
    const source = try execution.source.value();
    try stage3_product.run(execution.io, execution.allocator, .{
        .prerequisite = .{
            .context = view.context,
            .test_uuid = command.test_uuid,
            .paths = .{
                .dmg = execution.paths.dmg.value(),
                .frozen_executable = execution.paths.frozen.value(),
                .dmg_work = execution.paths.dmg_work.value(),
            },
            .bundles = .{
                .dmg_bundle = execution.paths.candidate_dmg_bundle.value(),
                .frozen_bundle = execution.paths.candidate_frozen_bundle.value(),
            },
            .cli = .{ .path = view.github_cli, .pinned = &execution.bootstrap.?.cli },
        },
        .baseline = .{
            .workspace_root = execution.paths.baseline.value(),
            .app_paths = .{
                .main_executable = execution.paths.app_main.value(),
                .cli_executable = execution.paths.app_cli.value(),
            },
            .toolchain = &execution.toolchain,
            .source_directory_fd = source.fd,
        },
        .manifest = execution.paths.manifest.value(),
        .durable_preparation = execution.paths.durable.value(),
    }, execution.token, execution.scratch, execution.budget_ns, &execution.product);
    const final_view = bootstrapView(execution.bootstrap.?) catch return error.AuthorityChanged;
    try execution.requireActive(final_view);
    try execution.source.revalidate(execution.bootstrap.?);
    _ = try execution.toolchain.revalidate();
}

fn settleExecution(execution: anytype) Outcome {
    if (execution.owner == null) return .local_failure;
    if (execution.needsAudit()) {
        if (!execution.localCleanupComplete()) execution.retryAuditCleanup() catch return .cleanup_failed;
        return .audit_required;
    }
    execution.retryCleanup() catch return .cleanup_failed;
    return .local_failure;
}

fn validateAliases(execution: *Execution, bootstrap: *Bootstrap, view: bootstrap_mod.View, command: bootstrap_mod.PrepareCandidate, token: []const u8, scratch: []u8) !void {
    const owner = std.mem.asBytes(execution);
    const boot = std.mem.asBytes(bootstrap);
    if (overlaps(owner, boot) or overlaps(owner, token) or overlaps(owner, scratch) or
        overlaps(boot, token) or overlaps(boot, scratch) or overlaps(token, scratch)) return error.InvalidOwner;
    const values = [_][]const u8{
        view.context.repository.owner, view.context.repository.name, view.context.tag,                view.context.source_commit, view.context.build.workflow_ref,
        view.github_cli,               command.repo,                 command.tag,                     command.test_uuid,          command.dmg,
        command.frozen_executable,     command.candidate_dmg_bundle, command.candidate_frozen_bundle, command.dmg_work,           command.baseline_workspace,
        command.app_main_executable,   command.app_cli_executable,   command.manifest,                command.source_root,        command.zig,
        command.zig_sha256,            command.durable_preparation,
    };
    for (values, 0..) |value, index| {
        if (overlaps(owner, value) or overlaps(token, value) or overlaps(scratch, value)) return error.InvalidOwner;
        for (values[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
    }
}

fn bootstrapView(bootstrap: *Bootstrap) !bootstrap_mod.View {
    if (bootstrap.owner != bootstrap or bootstrap.cli_path_len >= bootstrap.cli_path_storage.len or
        bootstrap.cli_path_storage[bootstrap.cli_path_len] != 0) return error.InvalidBootstrap;
    return bootstrap.value() orelse error.InvalidBootstrap;
}

fn pathsDigest(paths: *const Paths) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    try hashPath(&hash, &paths.dmg);
    try hashPath(&hash, &paths.frozen);
    try hashPath(&hash, &paths.candidate_dmg_bundle);
    try hashPath(&hash, &paths.candidate_frozen_bundle);
    try hashPath(&hash, &paths.dmg_work);
    try hashPath(&hash, &paths.baseline);
    try hashPath(&hash, &paths.app_main);
    try hashPath(&hash, &paths.app_cli);
    try hashPath(&hash, &paths.manifest);
    try hashPath(&hash, &paths.zig);
    try hashPath(&hash, &paths.durable);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashPath(hash: *std.crypto.hash.sha2.Sha256, path: *const StoredPath) !void {
    if (path.len == 0 or path.len >= path.bytes.len or path.bytes[path.len] != 0) return error.InvalidPath;
    hash.update(path.bytes[0..path.len]);
    hash.update(&.{0});
}

fn driverSeal(execution: *const Execution) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const address = @intFromPtr(execution);
    hash.update(std.mem.asBytes(&address));
    hash.update(&execution.bootstrap_sha256);
    hash.update(&execution.paths_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn bootstrapDigest(view: bootstrap_mod.View) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashSlice(&hash, view.context.repository.owner);
    hashSlice(&hash, view.context.repository.name);
    hash.update(std.mem.asBytes(&view.context.repository.id));
    hashSlice(&hash, view.context.tag);
    hashSlice(&hash, view.context.source_commit);
    hashSlice(&hash, view.context.build.workflow_ref);
    hash.update(std.mem.asBytes(&view.context.build.run_id));
    hash.update(std.mem.asBytes(&view.context.build.run_attempt));
    hash.update(std.mem.asBytes(&view.context.protected_tag));
    hash.update(&view.runner.workflow_sha);
    hashSlice(&hash, view.github_cli);
    hash.update(&view.cli.path_sha256);
    hash.update(std.mem.asBytes(&view.cli.path_len));
    hash.update(std.mem.asBytes(&view.cli.identity.device));
    hash.update(std.mem.asBytes(&view.cli.identity.inode));
    hash.update(std.mem.asBytes(&view.cli.size));
    hash.update(std.mem.asBytes(&view.cli.mode));
    hash.update(&view.cli.sha256);
    switch (view.command) {
        .prepare_candidate => |command| {
            hashSlice(&hash, command.repo);
            hashSlice(&hash, command.tag);
            hashSlice(&hash, command.test_uuid);
            hashSlice(&hash, command.dmg);
            hashSlice(&hash, command.frozen_executable);
            hashSlice(&hash, command.candidate_dmg_bundle);
            hashSlice(&hash, command.candidate_frozen_bundle);
            hashSlice(&hash, command.dmg_work);
            hashSlice(&hash, command.baseline_workspace);
            hashSlice(&hash, command.app_main_executable);
            hashSlice(&hash, command.app_cli_executable);
            hashSlice(&hash, command.manifest);
            hashSlice(&hash, command.source_root);
            hashSlice(&hash, command.zig);
            hash.update(std.mem.asBytes(&command.zig_size));
            hashSlice(&hash, command.zig_sha256);
            hashSlice(&hash, command.durable_preparation);
        },
        else => hash.update(@tagName(view.command)),
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashSlice(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hash.update(value);
    hash.update(&.{0});
}

fn sourcePristine(source: *const source_authority.SourceDirectory) bool {
    return source.owner == null and source.fd < 0 and source.identity.device == 0 and
        source.identity.inode == 0 and source.identity.uid == 0 and source.path_len == 0 and
        allZero(&source.path_sha256) and allZero(&source.source_commit) and allZero(&source.seal) and
        allZero(&source.path_storage);
}

fn toolchainPristine(toolchain: *const zig_authority.ZigToolchainAuthority) bool {
    return toolchain.owner == null and toolchain.pinned.owner == null and toolchain.pinned.fd < 0 and
        toolchain.pinned.parent_fd < 0 and toolchain.path_len == 0;
}

fn pathsPristine(paths: *const Paths) bool {
    return pathPristine(&paths.dmg) and pathPristine(&paths.frozen) and
        pathPristine(&paths.candidate_dmg_bundle) and pathPristine(&paths.candidate_frozen_bundle) and
        pathPristine(&paths.dmg_work) and pathPristine(&paths.baseline) and
        pathPristine(&paths.app_main) and pathPristine(&paths.app_cli) and
        pathPristine(&paths.manifest) and pathPristine(&paths.zig) and pathPristine(&paths.durable);
}

fn pathPristine(path: *const StoredPath) bool {
    return path.len == 0 and allZero(&path.bytes);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn settle(execution: anytype) Outcome {
        return settleExecution(execution);
    }
} else struct {};
