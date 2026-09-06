//! A resumed release may enter the shared publication suffix only through its re-fenced asset
//! graph. These tests pin the product composition, audit retention, and reverse local cleanup.

const std = @import("std");
const builtin = @import("builtin");
const product = @import("release_adapter_candidate_resume_publication_product");
const graph = @import("release_adapter_candidate_resume_asset_graph");
const resume_product = @import("release_adapter_candidate_resume_authority_product");
const attachment = @import("release_adapter_github_draft_asset_attachment");
const redownload = @import("release_adapter_github_draft_asset_redownload");
const publication = @import("release_adapter_github_draft_publication");
const post_publish = @import("release_adapter_github_post_publish_attestation");
const cli_mod = @import("release_adapter_github_cli_authority");

const context = resume_product.PublicationContext{
    .repository = .{ .id = 7, .owner = "ohah", .name = "maru" },
    .tag = "v1.2.3",
    .source_commit = "0123456789abcdef0123456789abcdef01234567",
    .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/heads/main", .run_id = 81, .run_attempt = 2 },
    .protected_tag = true,
};

test "resume product binds one graph and delegates exact shared suffix order" {
    std.testing.refAllDecls(product);
    var fixture = Fixture.init();
    var deadline: u8 = 0;
    var driver = Driver{};
    var execution: product.Execution = .{};
    try product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution);
    try std.testing.expect(execution.ownsSuccessfulOutputs());
    try std.testing.expectEqualStrings("attach,redownload,publish,verify", driver.log());
    try std.testing.expectEqual(@as(usize, 11), fixture.source.calls);
    try std.testing.expect(execution.borrowCount() == 0);
    try product.testing_api.cleanupWith(&driver, &execution);
}

test "pre-remote graph or attachment failure is local and leaves source reusable" {
    inline for (.{ Point.first_fence, Point.attach_empty }) |point| {
        var fixture = Fixture.init();
        var deadline: u8 = 0;
        var driver = Driver{ .fail_at = point };
        var execution: product.Execution = .{};
        try std.testing.expectError(error.Injected, product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution));
        try std.testing.expect(execution.isPristineForComposition());
        try std.testing.expectEqual(@as(usize, 0), execution.borrowCount());
        var standalone = graph.Authority{};
        try graph.testing_api.bindWith(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &standalone);
        try standalone.deinit();
    }
}

test "remote attachment and every later failure preserve the exact suffix audit stage" {
    const cases = [_]struct { point: Point, stage: product.AuditStage }{
        .{ .point = .attach_terminal, .stage = .attachment },
        .{ .point = .after_attach_fence, .stage = .attachment },
        .{ .point = .redownload, .stage = .attachment },
        .{ .point = .after_redownload_fence, .stage = .attachment },
        .{ .point = .publish, .stage = .publication },
        .{ .point = .after_publish_fence, .stage = .publication },
        .{ .point = .verify, .stage = .post_publish },
        .{ .point = .final_fence, .stage = .post_publish },
    };
    for (cases) |case| {
        var fixture = Fixture.init();
        var deadline: u8 = 0;
        var driver = Driver{ .fail_at = case.point };
        var execution: product.Execution = .{};
        try std.testing.expectError(error.AuditRequired, product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution));
        try std.testing.expect(execution.needsAudit());
        try std.testing.expectEqual(case.stage, execution.auditStage());
        try std.testing.expectEqual(@as(usize, 0), execution.borrowCount());
        try std.testing.expectError(error.InvalidOwner, product.testing_api.retryCleanupWith(&driver, &execution));
    }
}

test "captured audit stage permits local-only reverse cleanup and exact retry" {
    var fixture = Fixture.init();
    var deadline: u8 = 0;
    var driver = Driver{ .fail_at = .publish };
    var execution: product.Execution = .{};
    try std.testing.expectError(error.AuditRequired, product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution));
    try std.testing.expectEqual(product.AuditStage.publication, execution.auditStage());
    driver.length = 0;
    driver.cleanup_fail = .redownload;
    try std.testing.expectError(error.CleanupFailed, product.testing_api.cleanupAuditWith(&driver, &execution));
    try std.testing.expect(execution.needsCleanup());
    try std.testing.expectEqualStrings("clean-publish,clean-redownload,clean-attach", driver.log());
    driver.length = 0;
    driver.cleanup_fail = .none;
    try product.testing_api.retryCleanupWith(&driver, &execution);
    try std.testing.expectEqualStrings("clean-redownload,clean-graph", driver.log());
    try std.testing.expect(execution.isPristineForComposition());
}

test "graph drift is local before upload and audit-required after upload" {
    inline for (.{ Point.first_fence, Point.after_attach_fence }) |point| {
        var fixture = Fixture.init();
        var deadline: u8 = 0;
        var driver = Driver{ .drift_at = point };
        var execution: product.Execution = .{};
        const expected = if (point == .first_fence) error.AuthorityChanged else error.AuditRequired;
        try std.testing.expectError(expected, product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution));
        if (point == .first_fence) try std.testing.expect(execution.isPristineForComposition()) else try std.testing.expectEqual(product.AuditStage.attachment, execution.auditStage());
    }
}

test "successful cleanup closes leaf owners then graph and never consumes source" {
    var fixture = Fixture.init();
    var deadline: u8 = 0;
    var driver = Driver{};
    var execution: product.Execution = .{};
    try product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution);
    driver.length = 0;
    try product.testing_api.cleanupWith(&driver, &execution);
    try std.testing.expectEqualStrings("clean-verify,clean-publish,clean-redownload,clean-attach,clean-graph", driver.log());
    try std.testing.expect(execution.isPristineForComposition());
    var rebound = graph.Authority{};
    try graph.testing_api.bindWith(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &rebound);
    try rebound.deinit();
}

test "cleanup failure retains only the failed suffix and graph for exact retry" {
    var fixture = Fixture.init();
    var deadline: u8 = 0;
    var driver = Driver{};
    var execution: product.Execution = .{};
    try product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution);
    driver.length = 0;
    driver.cleanup_fail = .redownload;
    try std.testing.expectError(error.CleanupFailed, product.testing_api.cleanupWith(&driver, &execution));
    try std.testing.expect(execution.needsCleanup());
    try std.testing.expectEqualStrings("clean-verify,clean-publish,clean-redownload,clean-attach", driver.log());
    driver.length = 0;
    driver.cleanup_fail = .none;
    try product.testing_api.retryCleanupWith(&driver, &execution);
    try std.testing.expectEqualStrings("clean-redownload,clean-graph", driver.log());
    try std.testing.expect(execution.isPristineForComposition());
}

test "pre-remote graph cleanup failure retains graph-only retry authority" {
    var fixture = Fixture.init();
    var deadline: u8 = 0;
    var driver = Driver{ .fail_at = .attach_empty, .cleanup_fail = .graph };
    var execution: product.Execution = .{};
    try std.testing.expectError(error.CleanupFailed, product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution));
    try std.testing.expect(execution.needsCleanup());
    try std.testing.expectEqualStrings("attach,clean-attach,clean-graph", driver.log());

    driver.length = 0;
    driver.cleanup_fail = .none;
    try product.testing_api.retryCleanupWith(&driver, &execution);
    try std.testing.expectEqualStrings("clean-graph", driver.log());
    try std.testing.expect(execution.isPristineForComposition());
}

test "copied and pre-owned execution are rejected before source access" {
    var fixture = Fixture.init();
    var deadline: u8 = 0;
    var driver = Driver{};
    var preowned: product.Execution = .{};
    preowned.owner = &preowned;
    try std.testing.expectError(error.InvalidOwner, product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &preowned));
    try std.testing.expectEqual(@as(usize, 0), fixture.source.calls);

    var execution: product.Execution = .{};
    try product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution);
    var copied = execution;
    try std.testing.expect(!copied.ownsSuccessfulOutputs());
    try std.testing.expectError(error.InvalidOwner, product.testing_api.cleanupWith(&driver, &copied));
    try product.testing_api.cleanupWith(&driver, &execution);
}

test "deadline identity and borrowed transport storage are cleared on every terminal return" {
    inline for (.{ Point.none, Point.attach_empty, Point.publish }) |point| {
        var fixture = Fixture.init();
        var deadline: u8 = 0;
        var driver = Driver{ .fail_at = point };
        var execution: product.Execution = .{};
        const outcome = product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution);
        if (point == .none) try outcome else if (point == .attach_empty) try std.testing.expectError(error.Injected, outcome) else try std.testing.expectError(error.AuditRequired, outcome);
        try std.testing.expectEqual(@as(usize, 0), execution.borrowCount());
        if (point == .none) try product.testing_api.cleanupWith(&driver, &execution);
    }
}

test "production preflight rejects transport context source and deadline aliases before source access" {
    var source: resume_product.Execution = .{};
    var cli = pinnedCli();
    var deadline: product.Deadline = .{};
    var execution: product.Execution = .{};
    var response: [64]u8 = undefined;
    const inputs = product.Inputs{ .source = &source, .context = context, .cli_path = cli_path, .cli = &cli };

    var shared: [32]u8 = @splat('x');
    try std.testing.expectError(error.InvalidOwner, product.runBorrowingDeadline(undefined, std.testing.allocator, inputs, shared[0..16], shared[8..], &deadline, &execution));

    var aliased_context = inputs;
    aliased_context.context.repository.owner = std.mem.asBytes(&execution)[0..4];
    try std.testing.expectError(error.InvalidOwner, product.runBorrowingDeadline(undefined, std.testing.allocator, aliased_context, "token", &response, &deadline, &execution));

    const aliased_source: *resume_product.Execution = @ptrCast(@alignCast(&execution));
    var source_alias = inputs;
    source_alias.source = aliased_source;
    try std.testing.expectError(error.InvalidOwner, product.runBorrowingDeadline(undefined, std.testing.allocator, source_alias, "token", &response, &deadline, &execution));

    const aliased_deadline: *product.Deadline = @ptrCast(@alignCast(&execution));
    try std.testing.expectError(error.InvalidOwner, product.runBorrowingDeadline(undefined, std.testing.allocator, inputs, "token", &response, aliased_deadline, &execution));
}

test "leaf snapshot entrypoints reject result-source alias before invoking source callbacks" {
    var deadline: product.Deadline = .{};
    var response: [64]u8 = undefined;

    var attached: attachment.DraftAssets = .{};
    const attachment_source: *RejectingSource = @ptrCast(@alignCast(&attached));
    try std.testing.expectError(error.InvalidOwner, attachment.attachSnapshotUntil(std.testing.io, std.testing.allocator, attachment_source, "token", &response, &deadline, &attached));

    var validated: redownload.RedownloadValidation = .{};
    const redownload_source: *RejectingSource = @ptrCast(@alignCast(&validated));
    try std.testing.expectError(error.InvalidOwner, redownload.validateSnapshotUntil(std.testing.io, redownload_source, "token", &deadline, &validated));

    var published: publication.PublishedRelease = .{};
    const publication_source: *RejectingSource = @ptrCast(@alignCast(&published));
    try std.testing.expectError(error.InvalidOwner, publication.publishSnapshotUntil(std.testing.io, std.testing.allocator, publication_source, "token", &response, &deadline, &published));

    var verified: post_publish.VerifiedRelease = .{};
    const post_publish_source: *RejectingSource = @ptrCast(@alignCast(&verified));
    try std.testing.expectError(error.InvalidOwner, post_publish.verifySnapshotUntil(std.testing.io, std.testing.allocator, post_publish_source, "token", &response, &deadline, &verified));
}

test "production source has four leaf entrypoints and no generic testing seam" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_resume_publication_product.zig", std.testing.allocator, .limited(128 * 1024));
    defer std.testing.allocator.free(source);
    const testing_api_offset = std.mem.indexOf(u8, source, "pub const testing_api =") orelse return error.MissingTestingBoundary;
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source[0..testing_api_offset], "testing_api."));
    inline for (.{
        "draft_attachment.attachSnapshotUntil(",
        "draft_redownload.validateSnapshotUntil(",
        "draft_publication.publishSnapshotUntil(",
        "post_publish.verifySnapshotUntil(",
    }) |call| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, call));
    inline for (.{
        "draft_attachment.testing_api",
        "draft_redownload.testing_api",
        "draft_publication.testing_api",
        "post_publish.testing_api",
    }) |bypass| try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, bypass));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "suffix_phase.executeWith("));
}

test "resume publication composition records local orchestration latency without FD growth" {
    const sample_count = 40;
    const iterations_per_sample = 100;
    var samples: [sample_count]u64 = undefined;
    var fixture = Fixture.init();
    const fd_before = try openFdCount();

    for (&samples) |*sample| {
        const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        for (0..iterations_per_sample) |_| {
            var deadline: u8 = 0;
            var driver = Driver{};
            var execution: product.Execution = .{};
            try product.testing_api.runWithSource(&fixture.source, std.testing.allocator, context, cli_path, &fixture.cli, &deadline, &driver, &execution);
            try product.testing_api.cleanupWith(&driver, &execution);
        }
        sample.* = @intCast(@divTrunc(std.Io.Clock.awake.now(std.testing.io).nanoseconds - started, iterations_per_sample));
    }

    const fd_after = try openFdCount();
    try std.testing.expectEqual(fd_before, fd_after);
    try std.testing.expectEqual(@as(usize, sample_count * iterations_per_sample * 11), fixture.source.calls);
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("resume_publication_composition_local mode={s} samples=40 iterations_per_sample=100 failures=0 fd_delta=0 per_run_median_ns={d} per_run_p95_ns={d} per_run_max_ns={d}\n", .{
        @tagName(builtin.mode),
        samples[20],
        samples[37],
        samples[39],
    });
}

const cli_path: [:0]const u8 = "/usr/local/bin/gh";
const Point = product.testing_api.Point;
const Cleanup = enum { none, attachment, redownload, publication, verification, graph };

const RejectingSource = struct {
    marker: u8 = 0,
    pub fn snapshot(_: *@This()) !noreturn {
        return error.CallbackReached;
    }
    pub fn executablePath(_: *@This()) ![:0]const u8 {
        return error.CallbackReached;
    }
    pub fn releaseContext(_: *@This()) !resume_product.PublicationContext {
        return error.CallbackReached;
    }
    pub fn revalidate(_: *@This(), _: std.mem.Allocator, _: [:0]const u8) !void {
        return error.CallbackReached;
    }
};

const Fixture = struct {
    source: FakeSource,
    cli: cli_mod.PinnedExecutable,
    fn init() @This() {
        return .{ .source = .{ .view = sourceView() }, .cli = pinnedCli() };
    }
};

const FakeSource = struct {
    view: resume_product.PublicationView,
    calls: usize = 0,
    pub fn publicationView(self: *@This(), _: std.mem.Allocator, _: resume_product.PublicationContext, path: [:0]const u8, cli: *const cli_mod.PinnedExecutable) !resume_product.PublicationView {
        self.calls += 1;
        if (!std.mem.eql(u8, path, cli_path) or !std.mem.eql(u8, &cli.sha256, &self.view.cli_sha256)) return error.AuthorityChanged;
        return self.view;
    }
};

fn sourceView() resume_product.PublicationView {
    return .{ .context = context, .release_id = 91, .tag = context.tag, .source_commit = context.source_commit, .cli_sha256 = @splat('a'), .assets = .{
        .{ .path = "/tmp/candidate.dmg", .observation = observation(11, 101, 'b'), .fd = 31 },
        .{ .path = "/tmp/maru-session-host", .observation = observation(12, 102, 'c'), .fd = 32 },
        .{ .path = "/tmp/aggregate/baseline-evidence.json", .observation = observation(13, 103, 'd'), .fd = 33 },
        .{ .path = "/tmp/preparation/Maru-1.2.3-session-host-release.json", .observation = observation(14, 104, 'e'), .fd = 34 },
    } };
}
fn observation(inode: u64, size: u64, byte: u8) resume_product.PublicationObservation {
    return .{ .identity = .{ .device = 3, .inode = inode }, .size = size, .mode = 0o600, .sha256 = @splat(byte) };
}
fn pinnedCli() cli_mod.PinnedExecutable {
    return .{ .path_sha256 = @splat('f'), .path_len = cli_path.len, .identity = .{ .device = 5, .inode = 50 }, .size = 500, .mode = 0o755, .sha256 = @splat('a') };
}

fn openFdCount() !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: u32 = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}

const Driver = struct {
    events: [512]u8 = undefined,
    length: usize = 0,
    fail_at: Point = .none,
    drift_at: Point = .none,
    cleanup_fail: Cleanup = .none,
    terminal_attachment: bool = false,

    fn add(self: *@This(), value: []const u8) void {
        if (self.length != 0) {
            self.events[self.length] = ',';
            self.length += 1;
        }
        @memcpy(self.events[self.length..][0..value.len], value);
        self.length += value.len;
    }
    fn log(self: *const @This()) []const u8 {
        return self.events[0..self.length];
    }
    pub fn beforeFence(self: *@This(), point: Point, source: *FakeSource) !void {
        if (self.drift_at == point) source.view.release_id +%= 1;
        if (self.fail_at == point) return error.Injected;
    }
    pub fn attachAssets(self: *@This(), execution: *product.Execution, authority: *graph.Authority, source: *FakeSource) !void {
        self.add("attach");
        if (self.fail_at == .attach_empty) return error.Injected;
        const snapshot = try authority.snapshotAttachment();
        if (self.fail_at == .attach_terminal) {
            self.terminal_attachment = true;
            execution.attached.status = .remote_state_unknown;
            return error.Injected;
        }
        execution.attached = attachedFrom(snapshot);
        rebindAttached(&execution.attached);
        _ = source;
    }
    pub fn attachmentRequiresAudit(self: *const @This(), execution: *const product.Execution) bool {
        return self.terminal_attachment or execution.attached.state() != .empty;
    }
    pub fn validateRedownload(self: *@This(), execution: *product.Execution, authority: *graph.Authority) !void {
        self.add("redownload");
        if (self.fail_at == .redownload) return error.Injected;
        _ = try authority.snapshotRedownload(&execution.attached);
        execution.redownloaded = validatedFrom(&execution.attached);
        execution.redownloaded.owner = &execution.redownloaded;
    }
    pub fn publishDraft(self: *@This(), execution: *product.Execution, authority: *graph.Authority) !void {
        self.add("publish");
        if (self.fail_at == .publish) return error.Injected;
        _ = try authority.snapshotPublication(&execution.attached, &execution.redownloaded);
        execution.published = publishedFrom(sourceView(), &execution.attached);
        execution.published.owner = &execution.published;
    }
    pub fn verifyPublished(self: *@This(), execution: *product.Execution, authority: *graph.Authority) !void {
        self.add("verify");
        if (self.fail_at == .verify) return error.Injected;
        _ = try authority.snapshotPostPublish(&execution.attached, &execution.redownloaded, &execution.published);
        execution.verified.owner = &execution.verified;
    }
    pub fn cleanupAttachment(self: *@This(), execution: *product.Execution) !void {
        try self.clean("clean-attach", .attachment);
        execution.attached = .{};
    }
    pub fn cleanupRedownload(self: *@This(), execution: *product.Execution) !void {
        try self.clean("clean-redownload", .redownload);
        execution.redownloaded = .{};
    }
    pub fn cleanupPublication(self: *@This(), execution: *product.Execution) !void {
        try self.clean("clean-publish", .publication);
        execution.published = .{};
    }
    pub fn cleanupVerification(self: *@This(), execution: *product.Execution) !void {
        try self.clean("clean-verify", .verification);
        execution.verified = .{};
    }
    pub fn cleanupGraph(self: *@This(), authority: *graph.Authority) !void {
        try self.clean("clean-graph", .graph);
        try authority.deinit();
    }
    fn clean(self: *@This(), name: []const u8, target: Cleanup) !void {
        self.add(name);
        if (self.cleanup_fail == target) return error.InjectedCleanup;
    }
};

fn attachedFrom(snapshot: attachment.Snapshot) attachment.DraftAssets {
    var result = attachment.DraftAssets{ .status = .ready, .release_id = snapshot.release_id, .known_count = attachment.asset_count };
    result.owner = &result;
    for (snapshot.assets, 0..) |asset, index| {
        result.ids[index] = 201 + index;
        result.sizes[index] = asset.size;
        result.name_lens[index] = asset.name.len;
        @memcpy(result.names[index][0..asset.name.len], asset.name);
    }
    return result;
}
fn rebindAttached(result: *attachment.DraftAssets) void {
    result.owner = result;
    for (&result.views, 0..) |*view, index| view.* = .{ .id = result.ids[index], .name = result.names[index][0..result.name_lens[index]], .size = result.sizes[index] };
}
fn validatedFrom(attached: *const attachment.DraftAssets) redownload.RedownloadValidation {
    var result = redownload.RedownloadValidation{ .status = .ready, .release_id = attached.release_id, .asset_ids = attached.ids };
    result.owner = &result;
    return result;
}
fn publishedFrom(view: resume_product.PublicationView, attached: *const attachment.DraftAssets) publication.PublishedRelease {
    var result = publication.PublishedRelease{ .status = .ready, .release_id = view.release_id, .tag_len = view.tag.len, .asset_ids = attached.ids };
    result.owner = &result;
    @memcpy(result.tag[0..view.tag.len], view.tag);
    @memcpy(&result.source_commit, view.source_commit);
    return result;
}
