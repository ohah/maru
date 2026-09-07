//! Sealed executable owner for stage-7 resumed candidate publication.

const std = @import("std");
const builtin = @import("builtin");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const deadline_mod = @import("release_adapter_deadline");
const resume_product = @import("release_adapter_candidate_resume_authority_product");
const publication_product = @import("release_adapter_candidate_resume_publication_product");
const outcome_contract = @import("release_adapter_command_outcome");

pub const Bootstrap = bootstrap_mod.Bootstrap;
pub const AuditStage = publication_product.AuditStage;
pub const max_response_bytes: usize = 64 * 1024;

pub const Outcome = outcome_contract.Publication;
pub const exitCode = outcome_contract.publicationExitCode;
pub const stderrLine = outcome_contract.publicationStderrLine;

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
    preparation: StoredPath = .{},
    aggregate: StoredPath = .{},
    dmg: StoredPath = .{},
    frozen: StoredPath = .{},
};

const State = enum { pristine, running, cleanup_required };
const Target = enum { none, success, audit_required };

pub const Execution = struct {
    owner: ?*Execution = null,
    state: State = .pristine,
    target: Target = .none,
    publication_audit_stage: AuditStage = .none,
    source_execution: resume_product.Execution = .{},
    publication: publication_product.Execution = .{},
    deadline: deadline_mod.Deadline = .{},
    paths: Paths = .{},
    authority_digest: [32]u8 = @splat(0),
    seal: [32]u8 = @splat(0),
    bootstrap: ?*Bootstrap = null,
    token: []const u8 = "",
    response: []u8 = &.{},
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.state == .pristine and self.target == .none and
            self.publication_audit_stage == .none and self.source_execution.isPristineForComposition() and
            self.publication.isPristineForComposition() and self.deadline.isPristineForComposition() and
            pathsPristine(&self.paths) and allZero(&self.authority_digest) and allZero(&self.seal) and !self.hasBorrowed();
    }

    pub fn needsCleanup(self: *const @This()) bool {
        return self.validSeal() and self.state == .cleanup_required and self.target != .none and !self.hasBorrowed();
    }

    pub fn retryCleanup(self: *@This()) !Outcome {
        if (!self.needsCleanup()) return error.InvalidOwner;
        return settle(self);
    }

    fn validSeal(self: *const @This()) bool {
        const expected = commandSeal(self) orelse return false;
        return self.owner == self and std.mem.eql(u8, &self.seal, &expected);
    }

    fn hasBorrowed(self: *const @This()) bool {
        return self.bootstrap != null or self.token.len != 0 or self.response.len != 0;
    }

    fn clearBorrowed(self: *@This()) void {
        self.bootstrap = null;
        self.token = "";
        self.response = &.{};
    }
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    bootstrap: *Bootstrap,
    token: []const u8,
    response: []u8,
    budget_ns: i128,
    execution: *Execution,
) !void {
    if (!execution.isPristineForComposition() or token.len == 0 or response.len == 0 or
        response.len > max_response_bytes or budget_ns <= 0) return error.InvalidOwner;
    const view = try bootstrapView(bootstrap);
    const command = switch (view.command) {
        .resume_candidate_publication => |value| value,
        else => return error.InvalidCommand,
    };
    try validateAliases(execution, bootstrap, view, command, token, response);

    var paths: Paths = .{};
    try paths.preparation.set(command.preparation);
    try paths.aggregate.set(command.aggregate);
    try paths.dmg.set(command.dmg);
    try paths.frozen.set(command.frozen_executable);
    execution.* = .{
        .owner = execution,
        .state = .running,
        .paths = paths,
        .authority_digest = authorityDigest(view),
        .bootstrap = bootstrap,
        .token = token,
        .response = response,
        .io = io,
        .allocator = allocator,
    };
    execution.seal = commandSeal(execution) orelse return error.InvalidOwner;
    var driver = ConcreteDriver{ .execution = execution, .budget_ns = budget_ns };
    try executeWith(&driver);
}

fn executeWith(driver: anytype) !void {
    driver.startDeadline() catch {
        try driver.failAudit();
        return error.AuditRequired;
    };
    driver.requireResumeAuthority() catch {
        try driver.failAudit();
        return error.AuditRequired;
    };
    driver.resumeAuthority() catch {
        try driver.failAudit();
        return error.AuditRequired;
    };
    driver.requirePublicationAuthority() catch {
        try driver.failAudit();
        return error.AuditRequired;
    };
    driver.publish() catch {
        try driver.failAudit();
        return error.AuditRequired;
    };
    try driver.succeed();
}

const ConcreteDriver = struct {
    execution: *Execution,
    budget_ns: i128,

    fn startDeadline(self: *@This()) !void {
        try deadline_mod.start(self.budget_ns, &self.execution.deadline);
    }

    fn requireResumeAuthority(self: *@This()) !void {
        const view = bootstrapView(self.execution.bootstrap.?) catch return error.AuthorityChanged;
        try requireActive(self.execution, view);
    }

    fn resumeAuthority(self: *@This()) !void {
        const view = bootstrapView(self.execution.bootstrap.?) catch return error.AuthorityChanged;
        try resume_product.runBorrowingDeadline(self.execution.io, self.execution.allocator, .{
            .context = view.context,
            .paths = .{
                .preparation = self.execution.paths.preparation.value(),
                .aggregate = self.execution.paths.aggregate.value(),
                .dmg = self.execution.paths.dmg.value(),
                .frozen_executable = self.execution.paths.frozen.value(),
            },
            .cli_path = view.github_cli,
            .cli = &self.execution.bootstrap.?.cli,
        }, self.execution.token, self.execution.response, &self.execution.deadline, &self.execution.source_execution);
    }

    fn requirePublicationAuthority(self: *@This()) !void {
        const view = bootstrapView(self.execution.bootstrap.?) catch return error.AuthorityChanged;
        try requireActive(self.execution, view);
    }

    fn publish(self: *@This()) !void {
        const view = bootstrapView(self.execution.bootstrap.?) catch return error.AuthorityChanged;
        publication_product.runBorrowingDeadline(self.execution.io, self.execution.allocator, .{
            .source = &self.execution.source_execution,
            .context = view.context,
            .cli_path = view.github_cli,
            .cli = &self.execution.bootstrap.?.cli,
        }, self.execution.token, self.execution.response, &self.execution.deadline, &self.execution.publication) catch |err| {
            self.execution.publication_audit_stage = self.execution.publication.auditStage();
            return err;
        };
    }

    fn failAudit(self: *@This()) !void {
        return settleAuditFailure(self.execution);
    }

    fn succeed(self: *@This()) !void {
        self.execution.target = .success;
        self.execution.state = .cleanup_required;
        self.execution.clearBorrowed();
        const outcome = try settle(self.execution);
        if (outcome != .success) return error.InvalidOwner;
    }
};

pub fn runOutcome(
    io: std.Io,
    allocator: std.mem.Allocator,
    bootstrap: *Bootstrap,
    token: []const u8,
    response: []u8,
    budget_ns: i128,
    execution: *Execution,
) Outcome {
    run(io, allocator, bootstrap, token, response, budget_ns, execution) catch {
        if (execution.needsCleanup()) return execution.retryCleanup() catch .cleanup_failed;
        return if (execution.isPristineForComposition()) .audit_required else .cleanup_failed;
    };
    return .success;
}

fn settle(execution: *Execution) !Outcome {
    if (!execution.validSeal() or execution.state != .cleanup_required or execution.target == .none or execution.hasBorrowed())
        return error.InvalidOwner;
    var failed = false;

    if (execution.publication.needsAudit()) {
        if (execution.publication_audit_stage == .none) return error.InvalidOwner;
        execution.publication.cleanupAudit() catch {
            failed = true;
        };
    } else if (execution.publication.ownsSuccessfulOutputs()) {
        execution.publication.cleanup() catch {
            failed = true;
        };
    } else if (execution.publication.needsCleanup()) {
        execution.publication.retryCleanup() catch {
            failed = true;
        };
    } else if (!execution.publication.isPristineForComposition()) {
        return error.InvalidOwner;
    }

    if (execution.source_execution.value() != null) {
        execution.source_execution.cleanup() catch {
            failed = true;
        };
    } else if (execution.source_execution.transaction.needsAudit()) {
        execution.source_execution.retryAuditCleanup() catch {
            failed = true;
        };
    } else if (execution.source_execution.transaction.state == .ready_cleanup_required) {
        execution.source_execution.retryCleanup() catch {
            failed = true;
        };
    } else if (execution.source_execution.owner != null) {
        return error.InvalidOwner;
    }

    if (execution.deadline.owner != null) execution.deadline.deinit() catch {
        failed = true;
    };
    if (failed) return error.CleanupFailed;
    const outcome: Outcome = switch (execution.target) {
        .success => .success,
        .audit_required => .audit_required,
        .none => return error.InvalidOwner,
    };
    execution.* = .{};
    return outcome;
}

fn settleAuditFailure(execution: *Execution) !void {
    execution.target = .audit_required;
    execution.state = .cleanup_required;
    execution.clearBorrowed();
    _ = try settle(execution);
}

fn requireActive(self: *Execution, view: bootstrap_mod.View) !void {
    if (!self.validSeal() or self.bootstrap == null or self.bootstrap.?.owner != self.bootstrap.? or
        !std.mem.eql(u8, &self.authority_digest, &authorityDigest(view)) or
        !sameContext(view.context, self.bootstrap.?.context) or !std.mem.eql(u8, view.github_cli, self.bootstrap.?.cli_path_storage[0..self.bootstrap.?.cli_path_len]))
        return error.AuthorityChanged;
    _ = try self.deadline.remaining();
}

fn bootstrapView(bootstrap: *Bootstrap) !bootstrap_mod.View {
    if (bootstrap.owner != bootstrap or bootstrap.cli_path_len >= bootstrap.cli_path_storage.len or
        bootstrap.cli_path_storage[bootstrap.cli_path_len] != 0) return error.InvalidBootstrap;
    return bootstrap.value() orelse error.InvalidBootstrap;
}

fn validateAliases(execution: *Execution, bootstrap: *Bootstrap, view: bootstrap_mod.View, command: bootstrap_mod.ResumeCandidatePublication, token: []const u8, response: []u8) !void {
    const owner = std.mem.asBytes(execution);
    const boot = std.mem.asBytes(bootstrap);
    const borrowed = [_][]const u8{
        command.repo,
        command.tag,
        view.context.repository.owner,
        view.context.repository.name,
        view.context.tag,
        view.context.source_commit,
        view.context.build.workflow_ref,
        command.preparation,
        command.aggregate,
        command.dmg,
        command.frozen_executable,
    };
    if (overlaps(owner, boot) or overlaps(owner, token) or overlaps(owner, response) or
        overlaps(boot, token) or overlaps(boot, response) or overlaps(token, response)) return error.InvalidOwner;
    if (overlaps(owner, view.github_cli) or overlaps(token, view.github_cli) or overlaps(response, view.github_cli))
        return error.InvalidOwner;
    for (borrowed) |value| {
        if (overlaps(owner, value) or overlaps(boot, value) or overlaps(token, value) or overlaps(response, value))
            return error.InvalidOwner;
    }
    for (borrowed, 0..) |left, index| for (borrowed[index + 1 ..]) |right|
        if (overlaps(left, right)) return error.InvalidOwner;
}

fn sameContext(left: anytype, right: anytype) bool {
    return left.repository.id == right.repository.id and left.build.run_id == right.build.run_id and
        left.build.run_attempt == right.build.run_attempt and left.protected_tag == right.protected_tag and
        std.mem.eql(u8, left.repository.owner, right.repository.owner) and
        std.mem.eql(u8, left.repository.name, right.repository.name) and
        std.mem.eql(u8, left.tag, right.tag) and std.mem.eql(u8, left.source_commit, right.source_commit) and
        std.mem.eql(u8, left.build.workflow_ref, right.build.workflow_ref);
}

fn commandSeal(execution: *const Execution) ?[32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.session-host.resume-publication-command.v1\x00");
    var address: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &address, @intFromPtr(execution), .little);
    hasher.update(&address);
    hasher.update(&execution.authority_digest);
    inline for (.{ &execution.paths.preparation, &execution.paths.aggregate, &execution.paths.dmg, &execution.paths.frozen }) |path| {
        if (path.len == 0 or path.len >= path.bytes.len or path.bytes[path.len] != 0) return null;
        var len: [@sizeOf(usize)]u8 = undefined;
        std.mem.writeInt(usize, &len, path.len, .little);
        hasher.update(&len);
        hasher.update(path.bytes[0..path.len]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn authorityDigest(view: bootstrap_mod.View) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.session-host.resume-publication-authority.v1\x00");
    hashInt(&hasher, view.context.repository.id);
    hashBytes(&hasher, view.context.repository.owner);
    hashBytes(&hasher, view.context.repository.name);
    hashBytes(&hasher, view.context.tag);
    hashBytes(&hasher, view.context.source_commit);
    hashBytes(&hasher, view.context.build.workflow_ref);
    hashInt(&hasher, view.context.build.run_id);
    hashInt(&hasher, view.context.build.run_attempt);
    hashInt(&hasher, @as(u8, @intFromBool(view.context.protected_tag)));
    hasher.update(&view.runner.workflow_sha);
    hashBytes(&hasher, view.github_cli);
    hasher.update(&view.cli.path_sha256);
    hashInt(&hasher, view.cli.path_len);
    hashInt(&hasher, view.cli.identity.device);
    hashInt(&hasher, view.cli.identity.inode);
    hashInt(&hasher, view.cli.size);
    hashInt(&hasher, view.cli.mode);
    hasher.update(&view.cli.sha256);
    switch (view.command) {
        .resume_candidate_publication => |command| {
            hashBytes(&hasher, command.repo);
            hashBytes(&hasher, command.tag);
            hashBytes(&hasher, command.preparation);
            hashBytes(&hasher, command.aggregate);
            hashBytes(&hasher, command.dmg);
            hashBytes(&hasher, command.frozen_executable);
        },
        else => hasher.update("invalid-command"),
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashBytes(hasher: *std.crypto.hash.Blake3, value: []const u8) void {
    hashInt(hasher, value.len);
    hasher.update(value);
}

fn hashInt(hasher: *std.crypto.hash.Blake3, value: anytype) void {
    const Int = @TypeOf(value);
    var bytes: [@sizeOf(Int)]u8 = undefined;
    std.mem.writeInt(Int, &bytes, value, .little);
    hasher.update(&bytes);
}

fn pathsPristine(paths: *const Paths) bool {
    inline for (.{ &paths.preparation, &paths.aggregate, &paths.dmg, &paths.frozen }) |path|
        if (path.len != 0 or !allZero(&path.bytes)) return false;
    return true;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn allZero(value: []const u8) bool {
    return std.mem.allEqual(u8, value, 0);
}

pub const testing_api = if (builtin.is_test) struct {
    pub const CommandState = State;
    pub const CommandTarget = Target;

    pub fn snapshot(view: bootstrap_mod.View) [32]u8 {
        return authorityDigest(view);
    }

    pub fn execute(driver: anytype) !void {
        return executeWith(driver);
    }

    pub fn validateAliasGraph(execution: *Execution, bootstrap: *Bootstrap, token: []const u8, response: []u8) !void {
        const view = try bootstrapView(bootstrap);
        const command = switch (view.command) {
            .resume_candidate_publication => |value| value,
            else => return error.InvalidCommand,
        };
        return validateAliases(execution, bootstrap, view, command, token, response);
    }

    pub fn corruptStoredPathLength(execution: *Execution) void {
        execution.paths.preparation.len = execution.paths.preparation.bytes.len;
    }

    pub fn corruptStoredPathByte(execution: *Execution) void {
        execution.paths.preparation.bytes[0] = 1;
    }
} else struct {};
