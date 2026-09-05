//! Executable driver for one baseline-A candidate release.
//!
//! The caller-owned object keeps every cleanup capability alive across failure. In particular, a
//! draft-side failure remains an audit graph and is never passed through ordinary settlement.

const std = @import("std");
const builtin = @import("builtin");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const source_authority = @import("release_adapter_source_directory_authority");
const zig_authority = @import("release_adapter_zig_toolchain_authority");
const candidate_product = @import("release_adapter_candidate_release_product");

pub const Bootstrap = bootstrap_mod.Bootstrap;
pub const max_scratch_bytes: usize = 64 * 1024;

const DriverProductState = enum { pristine, complete, cleanup_required, audit_required, invalid };

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
};

pub const Execution = struct {
    owner: ?*Execution = null,
    source: source_authority.SourceDirectory = .{},
    toolchain: zig_authority.ZigToolchainAuthority = .{},
    product: candidate_product.Execution = .{},
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
        return self.pristine();
    }

    pub fn needsAudit(self: *const @This()) bool {
        const digest = pathsDigest(&self.paths) catch return false;
        return self.owner == self and std.mem.eql(u8, &self.seal, &driverSeal(self)) and
            std.mem.eql(u8, &self.paths_sha256, &digest) and self.product.needsAudit() and
            sourceLive(&self.source) and toolchainLive(&self.toolchain) and !self.hasBorrowed();
    }

    pub fn retryCleanup(self: *@This()) !void {
        if (self.owner != self or self.needsAudit() or self.hasBorrowed()) return error.InvalidOwner;
        const digest = pathsDigest(&self.paths) catch return error.InvalidOwner;
        if (!std.mem.eql(u8, &self.seal, &driverSeal(self)) or
            !std.mem.eql(u8, &self.paths_sha256, &digest)) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        return retryCoordinator(&steps);
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and sourcePristine(&self.source) and toolchainPristine(&self.toolchain) and
            self.product.isPristineForComposition() and pathsPristine(&self.paths) and
            allZero(&self.bootstrap_sha256) and allZero(&self.paths_sha256) and allZero(&self.seal) and
            !self.hasBorrowed();
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

    fn requireActive(self: *@This(), view: bootstrap_mod.View) !void {
        if (self.owner != self or !std.mem.eql(u8, &self.seal, &driverSeal(self)) or
            !std.mem.eql(u8, &self.bootstrap_sha256, &bootstrapDigest(view))) return error.AuthorityChanged;
        const digest = pathsDigest(&self.paths) catch return error.AuthorityChanged;
        if (!std.mem.eql(u8, &self.paths_sha256, &digest)) return error.AuthorityChanged;
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
    if (!execution.pristine() or budget_ns <= 0 or scratch.len == 0 or scratch.len > max_scratch_bytes)
        return error.InvalidOwner;
    const view = try bootstrapView(bootstrap);
    const command = switch (view.command) {
        .publish_candidate => |candidate| candidate,
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
    const bootstrap_sha256 = bootstrapDigest(view);
    const paths_sha256 = pathsDigest(&paths) catch return error.InvalidBootstrap;

    execution.* = .{
        .owner = execution,
        .paths = paths,
        .bootstrap_sha256 = bootstrap_sha256,
        .paths_sha256 = paths_sha256,
        .bootstrap = bootstrap,
        .token = token,
        .scratch = scratch,
        .budget_ns = budget_ns,
        .io = io,
        .allocator = allocator,
    };
    execution.seal = driverSeal(execution);
    var steps = ConcreteSteps{ .execution = execution };
    driveCoordinator(&steps) catch |err| {
        if (execution.owner == execution) execution.clearBorrowed();
        return err;
    };
}

const ConcreteSteps = struct {
    execution: *Execution,

    pub fn validatePreflight(self: *@This()) !void {
        const execution = self.execution;
        if (execution.owner != execution or execution.bootstrap == null or execution.budget_ns <= 0 or
            sourceLive(&execution.source) or toolchainLive(&execution.toolchain) or
            !execution.product.isPristineForComposition()) return error.InvalidOwner;
        const view = try bootstrapView(execution.bootstrap.?);
        const command = switch (view.command) {
            .publish_candidate => |candidate| candidate,
            else => return error.InvalidCommand,
        };
        try validateAliases(execution, execution.bootstrap.?, view, command, execution.token, execution.scratch);
        try execution.requireActive(view);
    }

    pub fn prepareSource(self: *@This()) !void {
        try self.requireActive();
        try source_authority.prepareCurrent(&self.execution.source, self.execution.bootstrap.?);
    }

    pub fn prepareToolchain(self: *@This()) !void {
        try self.requireActive();
        const view = try bootstrapView(self.execution.bootstrap.?);
        const command = switch (view.command) {
            .publish_candidate => |candidate| candidate,
            else => return error.InvalidCommand,
        };
        if (command.zig_sha256.len != 64) return error.InvalidBootstrap;
        var digest: [64]u8 = undefined;
        @memcpy(&digest, command.zig_sha256);
        try zig_authority.bind(view.context, view.runner, self.execution.paths.zig.value(), .{
            .size = command.zig_size,
            .sha256 = digest,
        }, &self.execution.toolchain);
    }

    pub fn runProduct(self: *@This()) !void {
        const execution = self.execution;
        const bootstrap = execution.bootstrap.?;
        const view = try bootstrapView(bootstrap);
        const command = switch (view.command) {
            .publish_candidate => |candidate| candidate,
            else => return error.InvalidCommand,
        };
        try execution.requireActive(view);
        try execution.source.revalidate(bootstrap);
        const source = try execution.source.value();
        _ = try execution.toolchain.revalidate();
        try candidate_product.run(execution.io, execution.allocator, .{
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
                .cli = .{ .path = view.github_cli, .pinned = &bootstrap.cli },
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
            .publication = .{ .manifest = execution.paths.manifest.value() },
        }, execution.token, execution.scratch, execution.budget_ns, &execution.product);
        try execution.requireActive(try bootstrapView(bootstrap));
        try execution.source.revalidate(bootstrap);
        _ = try execution.toolchain.revalidate();
    }

    pub fn productState(self: *@This()) DriverProductState {
        const product = &self.execution.product;
        if (product.needsAudit()) return .audit_required;
        if (product.ownsCompleteRelease()) return .complete;
        if (product.transaction.needsCleanup()) return .cleanup_required;
        if (product.isPristineForComposition()) return .pristine;
        return .invalid;
    }

    pub fn cleanupProduct(self: *@This()) !void {
        try self.execution.product.cleanup();
    }

    pub fn retryProduct(self: *@This()) !void {
        try self.execution.product.retryCleanup();
    }

    pub fn cleanupToolchain(self: *@This()) !void {
        if (toolchainLive(&self.execution.toolchain)) try self.execution.toolchain.deinit();
    }

    pub fn cleanupSource(self: *@This()) !void {
        if (sourceLive(&self.execution.source)) try self.execution.source.deinit();
    }

    pub fn finish(self: *@This()) void {
        self.execution.* = .{};
    }

    fn requireActive(self: *@This()) !void {
        const bootstrap = self.execution.bootstrap orelse return error.InvalidOwner;
        try self.execution.requireActive(try bootstrapView(bootstrap));
    }
};

fn driveCoordinator(steps: anytype) !void {
    try steps.validatePreflight();
    steps.prepareSource() catch |err| return settleFailure(steps, err);
    steps.prepareToolchain() catch |err| return settleFailure(steps, err);
    steps.runProduct() catch |err| {
        if (steps.productState() == .audit_required) return err;
        return settleFailure(steps, err);
    };
    if (steps.productState() != .complete) return error.CleanupFailed;
    if (!cleanupAll(steps, .complete)) return error.CleanupFailed;
}

fn settleFailure(steps: anytype, original: anyerror) anyerror {
    const state = steps.productState();
    if (state == .audit_required) return original;
    if (state == .invalid or !cleanupAll(steps, state)) return error.CleanupFailed;
    return original;
}

fn retryCoordinator(steps: anytype) !void {
    const state = steps.productState();
    if (state == .audit_required or state == .invalid or !cleanupAll(steps, state))
        return error.CleanupFailed;
}

fn cleanupAll(steps: anytype, state: DriverProductState) bool {
    var clean = true;
    switch (state) {
        .complete => steps.cleanupProduct() catch {
            clean = false;
        },
        .cleanup_required => steps.retryProduct() catch {
            clean = false;
        },
        .pristine => {},
        .audit_required, .invalid => return false,
    }
    steps.cleanupToolchain() catch {
        clean = false;
    };
    steps.cleanupSource() catch {
        clean = false;
    };
    if (clean) steps.finish();
    return clean;
}

fn bootstrapView(bootstrap: *Bootstrap) !bootstrap_mod.View {
    if (bootstrap.owner != bootstrap or bootstrap.cli_path_len >= bootstrap.cli_path_storage.len or
        bootstrap.cli_path_storage[bootstrap.cli_path_len] != 0) return error.InvalidBootstrap;
    return bootstrap.value() orelse error.InvalidBootstrap;
}

fn validateAliases(
    execution: *Execution,
    bootstrap: *Bootstrap,
    view: bootstrap_mod.View,
    command: bootstrap_mod.PublishCandidate,
    token: []const u8,
    scratch: []u8,
) !void {
    const result = std.mem.asBytes(execution);
    const bootstrap_bytes = std.mem.asBytes(bootstrap);
    if (overlaps(result, bootstrap_bytes) or overlaps(result, token) or overlaps(result, scratch) or
        overlaps(bootstrap_bytes, token) or overlaps(bootstrap_bytes, scratch) or overlaps(token, scratch))
        return error.InvalidOwner;
    const values = [_][]const u8{
        view.context.repository.owner, view.context.repository.name,    view.context.tag,
        view.context.source_commit,    view.context.build.workflow_ref, command.repo,
        command.tag,                   command.test_uuid,               command.dmg,
        command.frozen_executable,     command.candidate_dmg_bundle,    command.candidate_frozen_bundle,
        command.dmg_work,              command.baseline_workspace,      command.app_main_executable,
        command.app_cli_executable,    command.manifest,                command.source_root,
        command.zig,                   command.zig_sha256,
    };
    for (values, 0..) |value, index| {
        if (overlaps(result, value) or overlaps(token, value) or overlaps(scratch, value)) return error.InvalidOwner;
        for (values[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
    }
}

fn sourceLive(source: *const source_authority.SourceDirectory) bool {
    return !sourcePristine(source);
}

fn toolchainLive(toolchain: *const zig_authority.ZigToolchainAuthority) bool {
    return !toolchainPristine(toolchain);
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
    inline for (std.meta.fields(Paths)) |field| {
        const path = &@field(paths, field.name);
        if (path.len != 0 or !allZero(&path.bytes)) return false;
    }
    return true;
}

fn pathsDigest(paths: *const Paths) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (std.meta.fields(Paths)) |field| {
        const path = &@field(paths, field.name);
        if (path.len == 0 or path.len >= path.bytes.len or path.bytes[path.len] != 0)
            return error.InvalidPath;
        hash.update(path.bytes[0..path.len]);
        hash.update(&.{0});
    }
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
        .publish_candidate => |command| {
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
        },
        .pre_publish => hash.update("pre-publish"),
        .verify_predecessor => hash.update("verify-predecessor"),
        .prepare_candidate_aggregate => hash.update("prepare-candidate-aggregate"),
        .finalize_candidate_aggregate => hash.update("finalize-candidate-aggregate"),
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
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

fn hashSlice(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hash.update(value);
    hash.update(&.{0});
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

pub const testing_api = if (builtin.is_test) struct {
    pub const ProductState = DriverProductState;

    pub fn driveWith(steps: anytype) !void {
        return driveCoordinator(steps);
    }

    pub fn retryWith(steps: anytype) !void {
        return retryCoordinator(steps);
    }
} else struct {};
