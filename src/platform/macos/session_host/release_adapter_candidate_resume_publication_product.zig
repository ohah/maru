//! Product composition from one resumed candidate authority into the shared publication suffix.
//!
//! The retained resume execution remains borrowed. This owner holds the re-fenced asset graph and
//! the four local leaf results while the shared suffix alone owns remote ordering and audit state.

const std = @import("std");
const builtin = @import("builtin");
const suffix_phase = @import("release_adapter_candidate_publication_suffix_phase");
const graph_mod = @import("release_adapter_candidate_resume_asset_graph");
const resume_product = @import("release_adapter_candidate_resume_authority_product");
const deadline_mod = @import("release_adapter_deadline");
const draft_attachment = @import("release_adapter_github_draft_asset_attachment");
const draft_redownload = @import("release_adapter_github_draft_asset_redownload");
const draft_publication = @import("release_adapter_github_draft_publication");
const post_publish = @import("release_adapter_github_post_publish_attestation");
const cli_mod = @import("release_adapter_github_cli_authority");
const transport = @import("release_adapter_github_transport");

pub const AuditStage = suffix_phase.AuditStage;
pub const Context = resume_product.PublicationContext;
pub const PinnedCli = cli_mod.PinnedExecutable;
pub const Deadline = deadline_mod.Deadline;

const FencePoint = enum { none, first_fence, attach_empty, attach_terminal, after_attach_fence, redownload, after_redownload_fence, publish, after_publish_fence, verify, final_fence };

pub const Inputs = struct {
    source: *resume_product.Execution,
    context: Context,
    cli_path: [:0]const u8,
    cli: *const PinnedCli,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    transaction: suffix_phase.Publication = .{},
    graph: graph_mod.Authority = .{},
    attached: draft_attachment.DraftAssets = .{},
    redownloaded: draft_redownload.RedownloadValidation = .{},
    published: draft_publication.PublishedRelease = .{},
    verified: post_publish.VerifiedRelease = .{},
    deadline: Deadline = .{},
    graph_cleanup_required: bool = false,
    active_deadline_address: usize = 0,
    token: []const u8 = "",
    response: []u8 = &.{},

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.transaction.isPristineForComposition() and self.graph.isPristineForComposition() and
            pristineAttachment(&self.attached) and pristineRedownload(&self.redownloaded) and pristinePublished(&self.published) and
            pristineVerified(&self.verified) and self.deadline.isPristineForComposition() and !self.graph_cleanup_required and
            self.borrowCount() == 0;
    }

    pub fn ownsSuccessfulOutputs(self: *const @This()) bool {
        return self.owner == self and self.transaction.ownsCompletePublication() and self.graph.ownsPublicationAuthority() and
            self.attached.owner == &self.attached and self.redownloaded.owner == &self.redownloaded and
            self.published.owner == &self.published and self.verified.owner == &self.verified and
            self.deadline.isPristineForComposition() and !self.graph_cleanup_required and self.borrowCount() == 0;
    }

    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and self.transaction.needsAudit() and self.graph.ownsPublicationAuthority() and
            self.deadline.isPristineForComposition() and !self.graph_cleanup_required and self.borrowCount() == 0;
    }

    pub fn auditStage(self: *const @This()) AuditStage {
        return if (self.needsAudit()) self.transaction.auditStage() else .none;
    }

    pub fn needsCleanup(self: *const @This()) bool {
        if (self.owner != self or !self.graph.ownsPublicationAuthority() or !self.deadline.isPristineForComposition() or self.borrowCount() != 0)
            return false;
        return self.transaction.needsCleanup() or
            (self.transaction.isPristineForComposition() and self.graph_cleanup_required);
    }

    pub fn borrowCount(self: *const @This()) usize {
        return @intFromBool(self.active_deadline_address != 0) + @intFromBool(self.token.len != 0) + @intFromBool(self.response.len != 0);
    }

    pub fn cleanup(self: *@This()) !void {
        if (!self.ownsSuccessfulOutputs()) return error.InvalidOwner;
        var driver = ProductionDriver{ .execution = self };
        try cleanupBound(&driver, self, false);
    }

    /// Releases only process-local owners after the caller has captured the closed audit stage.
    /// Remote state is never retried, deleted, or reclassified by this transition.
    pub fn cleanupAudit(self: *@This()) !void {
        if (!self.needsAudit()) return error.InvalidOwner;
        self.transaction.audit_required = false;
        self.transaction.audit_stage = .none;
        var driver = ProductionDriver{ .execution = self };
        try cleanupBound(&driver, self, true);
    }

    pub fn retryCleanup(self: *@This()) !void {
        if (!self.needsCleanup()) return error.InvalidOwner;
        var driver = ProductionDriver{ .execution = self };
        try cleanupBound(&driver, self, true);
    }
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    token: []const u8,
    response: []u8,
    budget_ns: i128,
    execution: *Execution,
) !void {
    if (!execution.isPristineForComposition()) return error.InvalidOwner;
    try validateInputs(inputs, token, response, execution, null);
    try deadline_mod.start(budget_ns, &execution.deadline);
    return runBorrowed(io, allocator, inputs, token, response, &execution.deadline, true, execution);
}

pub fn runBorrowingDeadline(
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    token: []const u8,
    response: []u8,
    deadline: *Deadline,
    execution: *Execution,
) !void {
    if (!execution.isPristineForComposition()) return error.InvalidOwner;
    try validateInputs(inputs, token, response, execution, deadline);
    _ = try deadline.remaining();
    return runBorrowed(io, allocator, inputs, token, response, deadline, false, execution);
}

fn runBorrowed(
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    token: []const u8,
    response: []u8,
    deadline: *Deadline,
    owns_deadline: bool,
    execution: *Execution,
) !void {
    execution.owner = execution;
    execution.active_deadline_address = @intFromPtr(deadline);
    execution.token = token;
    execution.response = response;
    errdefer {
        if (execution.owner == execution and execution.graph.isPristineForComposition()) execution.* = .{};
    }
    try graph_mod.bind(inputs.source, allocator, inputs.context, inputs.cli_path, inputs.cli, &execution.graph);
    var driver = ProductionDriver{ .execution = execution, .io = io, .allocator = allocator };
    const outcome = executeBound(&driver, inputs.source, deadline, execution);
    clearBorrowed(execution);
    if (owns_deadline and execution.deadline.owner != null) execution.deadline.deinit() catch return error.CleanupFailed;
    outcome catch |err| {
        if (execution.transaction.isPristineForComposition()) {
            driver.cleanupGraph(&execution.graph) catch {
                execution.graph_cleanup_required = true;
                return error.CleanupFailed;
            };
            execution.* = .{};
        }
        return err;
    };
}

fn executeBound(driver: anytype, source: anytype, deadline: anytype, execution: *Execution) !void {
    const audit_seal = try execution.graph.publicationAuditSeal();
    var steps = Steps(@TypeOf(driver), @TypeOf(source), @TypeOf(deadline)){
        .execution = execution,
        .driver = driver,
        .source = source,
        .deadline = deadline,
        .expected_seal = audit_seal,
    };
    try suffix_phase.executeWith(&steps, deadline, audit_seal, &execution.transaction);
}

fn Steps(comptime DriverType: type, comptime SourceType: type, comptime DeadlineType: type) type {
    return struct {
        execution: *Execution,
        driver: DriverType,
        source: SourceType,
        deadline: DeadlineType,
        expected_seal: [32]u8,
        fence_count: usize = 0,

        pub fn validateSuffixPreflight(self: *@This(), publication: *suffix_phase.Publication, deadline: DeadlineType, seal: [32]u8) !void {
            if (publication != &self.execution.transaction or deadline != self.deadline or
                self.execution.owner != self.execution or self.execution.active_deadline_address != @intFromPtr(deadline) or
                !std.mem.eql(u8, &seal, &self.expected_seal)) return error.InvalidOwner;
        }
        pub fn validateAuthority(self: *@This(), deadline: DeadlineType, seal: [32]u8) !void {
            if (deadline != self.deadline or self.execution.active_deadline_address != @intFromPtr(deadline) or
                !std.mem.eql(u8, &seal, &self.expected_seal)) return error.AuthorityChanged;
            self.fence_count += 1;
            const point: FencePoint = switch (self.fence_count) {
                1 => .first_fence,
                2 => .after_attach_fence,
                3 => .after_redownload_fence,
                4 => .after_publish_fence,
                5 => .final_fence,
                else => return error.InvalidOwner,
            };
            try self.driver.beforeFence(point, self.source);
            const current = try self.execution.graph.publicationAuditSeal();
            if (!std.mem.eql(u8, &current, &seal)) return error.AuthorityChanged;
        }
        pub fn attachAssets(self: *@This(), _: DeadlineType) !void {
            try self.driver.attachAssets(self.execution, &self.execution.graph, self.source);
        }
        pub fn attachmentRequiresAudit(self: *@This()) bool {
            return self.driver.attachmentRequiresAudit(self.execution);
        }
        pub fn validateRedownload(self: *@This(), _: DeadlineType) !void {
            try self.driver.validateRedownload(self.execution, &self.execution.graph);
        }
        pub fn publishDraft(self: *@This(), _: DeadlineType) !void {
            try self.driver.publishDraft(self.execution, &self.execution.graph);
        }
        pub fn verifyPublished(self: *@This(), _: DeadlineType) !void {
            try self.driver.verifyPublished(self.execution, &self.execution.graph);
        }
        pub fn cleanupAttachment(self: *@This()) !void {
            try self.driver.cleanupAttachment(self.execution);
        }
        pub fn cleanupRedownload(self: *@This()) !void {
            try self.driver.cleanupRedownload(self.execution);
        }
        pub fn cleanupPublication(self: *@This()) !void {
            try self.driver.cleanupPublication(self.execution);
        }
        pub fn cleanupVerification(self: *@This()) !void {
            try self.driver.cleanupVerification(self.execution);
        }
    };
}

const ProductionDriver = struct {
    execution: *Execution,
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn beforeFence(_: *@This(), _: FencePoint, _: *resume_product.Execution) !void {}
    pub fn attachAssets(self: *@This(), execution: *Execution, authority: *graph_mod.Authority, _: *resume_product.Execution) !void {
        var source = AttachmentSource{ .authority = authority };
        try draft_attachment.attachSnapshotUntil(self.io, self.allocator, &source, execution.token, execution.response, activeDeadline(execution), &execution.attached);
    }
    pub fn attachmentRequiresAudit(_: *const @This(), execution: *const Execution) bool {
        return execution.attached.state() != .empty;
    }
    pub fn validateRedownload(self: *@This(), execution: *Execution, authority: *graph_mod.Authority) !void {
        var source = RedownloadSource{ .authority = authority, .attached = &execution.attached };
        try draft_redownload.validateSnapshotUntil(self.io, &source, execution.token, activeDeadline(execution), &execution.redownloaded);
    }
    pub fn publishDraft(self: *@This(), execution: *Execution, authority: *graph_mod.Authority) !void {
        var source = PublicationSource{ .authority = authority, .attached = &execution.attached, .validated = &execution.redownloaded };
        try draft_publication.publishSnapshotUntil(self.io, self.allocator, &source, execution.token, execution.response, activeDeadline(execution), &execution.published);
    }
    pub fn verifyPublished(self: *@This(), execution: *Execution, authority: *graph_mod.Authority) !void {
        var source = PostPublishSource{ .authority = authority, .attached = &execution.attached, .validated = &execution.redownloaded, .published = &execution.published };
        try post_publish.verifySnapshotUntil(self.io, self.allocator, &source, execution.token, execution.response, activeDeadline(execution), &execution.verified);
    }
    pub fn cleanupAttachment(_: *@This(), execution: *Execution) !void {
        if (execution.attached.owner != null) try execution.attached.deinit();
    }
    pub fn cleanupRedownload(_: *@This(), execution: *Execution) !void {
        if (execution.redownloaded.owner != null) try execution.redownloaded.deinit();
    }
    pub fn cleanupPublication(_: *@This(), execution: *Execution) !void {
        if (execution.published.owner != null) try execution.published.deinit();
    }
    pub fn cleanupVerification(_: *@This(), execution: *Execution) !void {
        if (execution.verified.owner != null) try execution.verified.deinit();
    }
    pub fn cleanupGraph(_: *@This(), authority: *graph_mod.Authority) !void {
        try authority.deinit();
    }
};

const AttachmentSource = struct {
    authority: *graph_mod.Authority,
    pub fn snapshot(self: *@This()) !draft_attachment.Snapshot {
        return self.authority.snapshotAttachment();
    }
    pub fn executablePath(self: *@This()) ![:0]const u8 {
        return self.authority.publicationCliPath();
    }
};
const RedownloadSource = struct {
    authority: *graph_mod.Authority,
    attached: *const draft_attachment.DraftAssets,
    pub fn snapshot(self: *@This()) !draft_redownload.Snapshot {
        return self.authority.snapshotRedownload(self.attached);
    }
    pub fn executablePath(self: *@This()) ![:0]const u8 {
        return self.authority.publicationCliPath();
    }
};
const PublicationSource = struct {
    authority: *graph_mod.Authority,
    attached: *const draft_attachment.DraftAssets,
    validated: *const draft_redownload.RedownloadValidation,
    pub fn snapshot(self: *@This()) !draft_publication.Snapshot {
        return self.authority.snapshotPublication(self.attached, self.validated);
    }
    pub fn executablePath(self: *@This()) ![:0]const u8 {
        return self.authority.publicationCliPath();
    }
};
const PostPublishSource = struct {
    authority: *graph_mod.Authority,
    attached: *const draft_attachment.DraftAssets,
    validated: *const draft_redownload.RedownloadValidation,
    published: *const draft_publication.PublishedRelease,
    pub fn snapshot(self: *@This()) !post_publish.Snapshot {
        return self.authority.snapshotPostPublish(self.attached, self.validated, self.published);
    }
    pub fn executablePath(self: *@This()) ![:0]const u8 {
        return self.authority.publicationCliPath();
    }
    pub fn releaseContext(self: *@This()) !Context {
        return self.authority.publicationContext();
    }
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, path: [:0]const u8) !void {
        const current = try self.authority.publicationCliPath();
        if (!std.mem.eql(u8, current, path)) return error.AuthorityChanged;
    }
};

fn activeDeadline(execution: *Execution) *Deadline {
    return @ptrFromInt(execution.active_deadline_address);
}

fn cleanupBound(driver: anytype, execution: *Execution, retry: bool) !void {
    if (execution.transaction.ownsCompletePublication()) {
        var steps = CleanupSteps(@TypeOf(driver)){ .execution = execution, .driver = driver };
        suffix_phase.cleanupWith(&steps, &execution.transaction) catch return error.CleanupFailed;
    } else if (retry and execution.transaction.needsCleanup()) {
        var steps = CleanupSteps(@TypeOf(driver)){ .execution = execution, .driver = driver };
        suffix_phase.retryCleanupWith(&steps, &execution.transaction) catch return error.CleanupFailed;
    } else if (!execution.transaction.isPristineForComposition()) return error.InvalidOwner;
    execution.graph_cleanup_required = true;
    driver.cleanupGraph(&execution.graph) catch return error.CleanupFailed;
    execution.* = .{};
}

fn CleanupSteps(comptime DriverType: type) type {
    return struct {
        execution: *Execution,
        driver: DriverType,
        pub fn cleanupAttachment(self: *@This()) !void {
            try self.driver.cleanupAttachment(self.execution);
        }
        pub fn cleanupRedownload(self: *@This()) !void {
            try self.driver.cleanupRedownload(self.execution);
        }
        pub fn cleanupPublication(self: *@This()) !void {
            try self.driver.cleanupPublication(self.execution);
        }
        pub fn cleanupVerification(self: *@This()) !void {
            try self.driver.cleanupVerification(self.execution);
        }
    };
}

fn clearBorrowed(execution: *Execution) void {
    execution.active_deadline_address = 0;
    execution.token = "";
    execution.response = &.{};
}

fn validateInputs(inputs: Inputs, token: []const u8, response: []u8, execution: *Execution, deadline: ?*Deadline) !void {
    try transport.validateToken(token);
    if (response.len == 0 or response.len > transport.max_response_bytes) return error.InvalidOutput;
    const result = std.mem.asBytes(execution);
    const owners = [_][]const u8{ std.mem.asBytes(inputs.source), std.mem.asBytes(inputs.cli) };
    const borrowed = [_][]const u8{ inputs.context.repository.owner, inputs.context.repository.name, inputs.context.tag, inputs.context.source_commit, inputs.context.build.workflow_ref, inputs.cli_path, token, response };
    for (owners, 0..) |value, index| {
        if (overlaps(result, value)) return error.InvalidOwner;
        for (owners[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
        for (borrowed) |item| if (overlaps(value, item)) return error.InvalidOwner;
    }
    for (borrowed, 0..) |value, index| {
        if (overlaps(result, value)) return error.InvalidOwner;
        for (borrowed[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
    }
    if (deadline) |value| {
        const bytes = std.mem.asBytes(value);
        if (overlaps(result, bytes) or overlaps(token, bytes) or overlaps(response, bytes)) return error.InvalidOwner;
        for (owners ++ borrowed) |item| if (overlaps(bytes, item)) return error.InvalidOwner;
    }
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn pristineAttachment(value: *const draft_attachment.DraftAssets) bool {
    return value.owner == null and value.state() == .empty;
}
fn pristineRedownload(value: *const draft_redownload.RedownloadValidation) bool {
    return value.owner == null and value.state() == .empty;
}
fn pristinePublished(value: *const draft_publication.PublishedRelease) bool {
    return value.owner == null and value.state() == .empty;
}
fn pristineVerified(value: *const post_publish.VerifiedRelease) bool {
    return value.owner == null and value.release_id == 0;
}

pub const testing_api = if (builtin.is_test) struct {
    pub const Point = FencePoint;

    pub fn runWithSource(source: anytype, allocator: std.mem.Allocator, context: Context, cli_path: [:0]const u8, cli: *const PinnedCli, deadline: anytype, driver: anytype, execution: *Execution) !void {
        if (!execution.isPristineForComposition()) return error.InvalidOwner;
        execution.owner = execution;
        execution.active_deadline_address = @intFromPtr(deadline);
        try graph_mod.testing_api.bindWith(source, allocator, context, cli_path, cli, &execution.graph);
        const outcome = executeBound(driver, source, deadline, execution);
        clearBorrowed(execution);
        outcome catch |err| {
            if (execution.transaction.isPristineForComposition()) {
                driver.cleanupGraph(&execution.graph) catch {
                    execution.graph_cleanup_required = true;
                    return error.CleanupFailed;
                };
                execution.* = .{};
            }
            return err;
        };
    }
    pub fn cleanupWith(driver: anytype, execution: *Execution) !void {
        if (!execution.ownsSuccessfulOutputs()) return error.InvalidOwner;
        try cleanupBound(driver, execution, false);
    }
    pub fn cleanupAuditWith(driver: anytype, execution: *Execution) !void {
        if (!execution.needsAudit()) return error.InvalidOwner;
        execution.transaction.audit_required = false;
        execution.transaction.audit_stage = .none;
        try cleanupBound(driver, execution, true);
    }
    pub fn retryCleanupWith(driver: anytype, execution: *Execution) !void {
        if (!execution.needsCleanup()) return error.InvalidOwner;
        try cleanupBound(driver, execution, true);
    }
} else struct {};
