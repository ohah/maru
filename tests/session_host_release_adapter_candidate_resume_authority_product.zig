const std = @import("std");
const phase = @import("release_adapter_candidate_resume_authority_phase");
const product = @import("release_adapter_candidate_resume_authority_product");
const files = @import("release_adapter_files");
const manifest_mod = @import("release_manifest");

const Event = enum {
    preflight,
    open_preparation,
    fence_preparation_before_aggregate,
    open_aggregate,
    fence_aggregate_before_current,
    fence_preparation_before_current,
    authenticate_current,
    adopt_draft,
    fence_preparation_final,
    fence_aggregate_final,
    cleanup_draft,
    cleanup_current,
    cleanup_aggregate_audit,
    cleanup_preparation_audit,
    cleanup_aggregate_ready,
    cleanup_preparation_ready,
};

const Steps = struct {
    events: [32]Event = undefined,
    count: usize = 0,
    failure_at: ?Event = null,
    cleanup_fail_at: ?Event = null,
    descriptor_close_at: ?Event = null,

    fn push(self: *@This(), event: Event) !void {
        self.events[self.count] = event;
        self.count += 1;
        if (self.cleanup_fail_at == event) return error.CleanupFailed;
        if (self.failure_at == event) return error.Injected;
    }
    pub fn validatePreflight(self: *@This()) !void {
        try self.push(.preflight);
    }
    pub fn openPreparation(self: *@This()) !void {
        try self.push(.open_preparation);
    }
    pub fn fencePreparation(self: *@This(), final: bool) !void {
        const event: Event = if (final)
            .fence_preparation_final
        else if (self.count > 0 and self.events[self.count - 1] == .fence_aggregate_before_current)
            .fence_preparation_before_current
        else
            .fence_preparation_before_aggregate;
        try self.push(event);
    }
    pub fn openAggregate(self: *@This()) !void {
        try self.push(.open_aggregate);
    }
    pub fn fenceAggregate(self: *@This(), final: bool) !void {
        try self.push(if (final) .fence_aggregate_final else .fence_aggregate_before_current);
    }
    pub fn authenticateCurrent(self: *@This()) !void {
        try self.push(.authenticate_current);
    }
    pub fn adoptDraft(self: *@This()) !void {
        try self.push(.adopt_draft);
    }
    pub fn cleanupDraft(self: *@This()) !phase.CleanupDisposition {
        return self.cleanup(.cleanup_draft);
    }
    pub fn cleanupCurrent(self: *@This()) !phase.CleanupDisposition {
        return self.cleanup(.cleanup_current);
    }
    pub fn cleanupAggregateAudit(self: *@This()) !phase.CleanupDisposition {
        return self.cleanup(.cleanup_aggregate_audit);
    }
    pub fn cleanupPreparationAudit(self: *@This()) !phase.CleanupDisposition {
        return self.cleanup(.cleanup_preparation_audit);
    }
    pub fn cleanupAggregateReady(self: *@This()) !phase.CleanupDisposition {
        return self.cleanup(.cleanup_aggregate_ready);
    }
    pub fn cleanupPreparationReady(self: *@This()) !phase.CleanupDisposition {
        return self.cleanup(.cleanup_preparation_ready);
    }
    fn cleanup(self: *@This(), event: Event) !phase.CleanupDisposition {
        try self.push(event);
        return if (self.descriptor_close_at == event) .descriptor_close_failed else .complete;
    }
};

test "resume authority exact success order reaches one ready owner" {
    var steps = Steps{};
    var transaction = phase.Transaction{};
    try phase.executeWith(&steps, &transaction);
    try std.testing.expect(transaction.isReady());
    try std.testing.expectEqualSlices(Event, &.{
        .preflight,
        .open_preparation,
        .fence_preparation_before_aggregate,
        .open_aggregate,
        .fence_aggregate_before_current,
        .fence_preparation_before_current,
        .authenticate_current,
        .adopt_draft,
        .fence_preparation_final,
        .fence_aggregate_final,
    }, steps.events[0..steps.count]);
}

test "every post-stage4 failure is audit required and never local failure" {
    const checkpoints = [_]Event{
        .preflight,
        .open_preparation,
        .fence_preparation_before_aggregate,
        .open_aggregate,
        .fence_aggregate_before_current,
        .fence_preparation_before_current,
        .authenticate_current,
        .adopt_draft,
        .fence_preparation_final,
        .fence_aggregate_final,
    };
    for (checkpoints) |checkpoint| {
        var steps = Steps{ .failure_at = checkpoint };
        var transaction = phase.Transaction{};
        try std.testing.expectError(error.Injected, phase.executeWith(&steps, &transaction));
        try std.testing.expect(transaction.needsAudit());
        try std.testing.expect(!transaction.isReady());
    }
}

test "failure cleanup follows ready current aggregate preparation reverse order" {
    var steps = Steps{ .failure_at = .fence_aggregate_final };
    var transaction = phase.Transaction{};
    try std.testing.expectError(error.Injected, phase.executeWith(&steps, &transaction));
    try std.testing.expectEqual(phase.CleanupDisposition.complete, try phase.settleFailureWith(&steps, &transaction));
    try std.testing.expect(transaction.auditCleanupComplete());
    try std.testing.expectEqualSlices(Event, &.{
        .cleanup_draft,
        .cleanup_current,
        .cleanup_aggregate_audit,
        .cleanup_preparation_audit,
    }, steps.events[steps.count - 4 .. steps.count]);
}

test "every audit cleanup failure preserves the exact retry suffix" {
    const cleanup_order = [_]Event{ .cleanup_draft, .cleanup_current, .cleanup_aggregate_audit, .cleanup_preparation_audit };
    for (cleanup_order, 0..) |checkpoint, index| {
        var steps = Steps{ .failure_at = .fence_aggregate_final, .cleanup_fail_at = checkpoint };
        var transaction = phase.Transaction{};
        try std.testing.expectError(error.Injected, phase.executeWith(&steps, &transaction));
        try std.testing.expectError(error.CleanupFailed, phase.settleFailureWith(&steps, &transaction));
        try std.testing.expect(transaction.needsCleanup());
        steps.cleanup_fail_at = null;
        const retry_start = steps.count;
        try std.testing.expectEqual(phase.CleanupDisposition.complete, try phase.retryCleanupWith(&steps, &transaction));
        try std.testing.expect(transaction.auditCleanupComplete());
        try std.testing.expectEqualSlices(Event, cleanup_order[index..], steps.events[retry_start..steps.count]);
    }
}

test "every ready cleanup failure has a distinct retryable suffix" {
    const cleanup_order = [_]Event{ .cleanup_draft, .cleanup_current, .cleanup_aggregate_ready, .cleanup_preparation_ready };
    for (cleanup_order, 0..) |checkpoint, index| {
        var steps = Steps{ .cleanup_fail_at = checkpoint };
        var transaction = phase.Transaction{};
        try phase.executeWith(&steps, &transaction);
        try std.testing.expectError(error.CleanupFailed, phase.cleanupReadyWith(&steps, &transaction));
        try std.testing.expect(transaction.needsCleanup());
        try std.testing.expect(!transaction.needsAudit());
        steps.cleanup_fail_at = null;
        const retry_start = steps.count;
        try std.testing.expectEqual(phase.CleanupDisposition.complete, try phase.retryReadyCleanupWith(&steps, &transaction));
        try std.testing.expect(transaction.isPristineForComposition());
        try std.testing.expectEqualSlices(Event, cleanup_order[index..], steps.events[retry_start..steps.count]);
    }
}

test "ready transaction rejects replay and failure settlement" {
    var steps = Steps{};
    var transaction = phase.Transaction{};
    try phase.executeWith(&steps, &transaction);
    try std.testing.expectError(error.InvalidState, phase.executeWith(&steps, &transaction));
    try std.testing.expectError(error.InvalidState, phase.settleFailureWith(&steps, &transaction));
}

test "copied transaction cannot settle canonical cleanup authority" {
    var steps = Steps{ .failure_at = .fence_aggregate_final, .cleanup_fail_at = .cleanup_current };
    var transaction = phase.Transaction{};
    try std.testing.expectError(error.Injected, phase.executeWith(&steps, &transaction));
    try std.testing.expectError(error.CleanupFailed, phase.settleFailureWith(&steps, &transaction));
    var copied = transaction;
    steps.cleanup_fail_at = null;
    try std.testing.expectError(error.InvalidState, phase.retryCleanupWith(&steps, &copied));
    _ = try phase.retryCleanupWith(&steps, &transaction);
}

test "descriptor close warning consumes the owner and completes every remaining cleanup" {
    const cases = [_]struct { audit: Event, ready: Event }{
        .{ .audit = .cleanup_aggregate_audit, .ready = .cleanup_aggregate_ready },
        .{ .audit = .cleanup_preparation_audit, .ready = .cleanup_preparation_ready },
    };
    for (cases) |case| {
        var audit_steps = Steps{ .failure_at = .fence_aggregate_final, .descriptor_close_at = case.audit };
        var audit = phase.Transaction{};
        try std.testing.expectError(error.Injected, phase.executeWith(&audit_steps, &audit));
        try std.testing.expectEqual(phase.CleanupDisposition.descriptor_close_failed, try phase.settleFailureWith(&audit_steps, &audit));
        try std.testing.expect(audit.auditCleanupComplete());
        try std.testing.expect(!audit.needsCleanup());
        try std.testing.expectError(error.InvalidState, phase.retryCleanupWith(&audit_steps, &audit));

        var ready_steps = Steps{ .descriptor_close_at = case.ready };
        var ready = phase.Transaction{};
        try phase.executeWith(&ready_steps, &ready);
        try std.testing.expectEqual(phase.CleanupDisposition.descriptor_close_failed, try phase.cleanupReadyWith(&ready_steps, &ready));
        try std.testing.expect(ready.isPristineForComposition());
        try std.testing.expectError(error.InvalidState, phase.retryReadyCleanupWith(&ready_steps, &ready));
    }
}

test "concrete cleanup classifies only descriptor close failure as a consumed warning" {
    try std.testing.expectEqual(
        phase.CleanupDisposition.descriptor_close_failed,
        try product.testing_api.classifyCloseError(error.DescriptorCloseFailed),
    );
    try std.testing.expectError(error.InvalidOwner, product.testing_api.classifyCloseError(error.InvalidOwner));
    try std.testing.expectError(error.FileChanged, product.testing_api.classifyCloseError(error.FileChanged));
}

test "product exposes only final-address ready cleanup and test-only transaction seam" {
    try std.testing.expect(@hasDecl(product.Execution, "value"));
    try std.testing.expect(@hasDecl(product.Execution, "cleanup"));
    try std.testing.expect(@hasDecl(product.Execution, "retryAuditCleanup"));
    try std.testing.expect(@hasDecl(product.Execution, "retryCleanup"));
    try std.testing.expect(@hasDecl(product, "testing_api"));
}

test "publication view rejects corrupt draft and current lengths before slicing" {
    var execution = product.Execution{};
    execution.draft.id = 1;
    execution.draft.tag_len = 1;
    execution.current.release_id = 1;
    execution.current.tag_len = 1;
    try std.testing.expect(product.testing_api.readyScalarsValid(&execution));

    execution.draft.tag_len = execution.draft.tag.len + 1;
    try std.testing.expect(!product.testing_api.readyScalarsValid(&execution));
    execution.draft.tag_len = 1;
    execution.current.tag_len = execution.current.tag.len + 1;
    try std.testing.expect(!product.testing_api.readyScalarsValid(&execution));
}

test "cross-owner identity graph requires the shared manifest and ten distinct vnodes" {
    var identities: [11]files.Identity = undefined;
    for (&identities, 0..) |*identity, index| identity.* = .{ .device = 1, .inode = index + 1 };
    identities[9] = identities[1];
    try product.testing_api.requireIdentityGraph(identities);

    identities[9] = .{ .device = 1, .inode = 10 };
    try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireIdentityGraph(identities));
    identities[9] = identities[1];

    const unique_positions = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 10 };
    for (unique_positions[1..]) |position| {
        const saved = identities[position];
        identities[position] = identities[0];
        if (position == 1) identities[9] = identities[1];
        try std.testing.expectError(error.PathAlias, product.testing_api.requireIdentityGraph(identities));
        identities[position] = saved;
        identities[9] = identities[1];
    }
}

test "semantic graph binds preparation evidence and every manifest asset to aggregate bytes" {
    const dmg = observed(4, 41, 'a');
    const frozen = observed(5, 42, 'b');
    const evidence = observed(6, 43, 'c');
    const manifest_file = observed(7, 44, 'd');
    const assets = [_]manifest_mod.Asset{
        .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = &dmg.sha256, .size = dmg.size },
        .{ .role = .frozen_product_executable, .name = "maru-session-host-1.2.3", .sha256 = &frozen.sha256, .size = frozen.size },
        .{ .role = .evidence_summary, .name = "baseline-evidence.json", .sha256 = &evidence.sha256, .size = evidence.size },
    };
    var manifest: manifest_mod.Manifest = undefined;
    manifest.assets = &assets;
    const canonical = product.testing_api.SemanticGraph{
        .preparation_evidence = evidence,
        .preparation_manifest = manifest_file,
        .aggregate_evidence = observed(8, evidence.size, 'c'),
        .aggregate_dmg = dmg,
        .aggregate_frozen = frozen,
        .aggregate_manifest = manifest_file,
        .dmg_name = assets[0].name,
        .frozen_name = assets[1].name,
        .evidence_name = assets[2].name,
    };
    try product.testing_api.requireSemanticGraph(&manifest, canonical);

    var changed = canonical;
    changed.aggregate_evidence.sha256[0] = 'e';
    try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, changed));
    changed = canonical;
    changed.aggregate_evidence.size += 1;
    try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, changed));
    changed = canonical;
    changed.aggregate_evidence.identity = changed.preparation_evidence.identity;
    try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, changed));
    changed = canonical;
    changed.aggregate_manifest.identity.inode += 1;
    try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, changed));
    changed = canonical;
    changed.aggregate_manifest.size += 1;
    try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, changed));
    changed = canonical;
    changed.aggregate_manifest.mode ^= 0o100;
    try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, changed));
    changed = canonical;
    changed.aggregate_manifest.sha256[0] = 'e';
    try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, changed));

    const wrong_sha: [64]u8 = @splat('f');
    for (0..assets.len) |index| {
        var hostile_assets = assets;
        hostile_assets[index].size += 1;
        manifest.assets = &hostile_assets;
        try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, canonical));

        hostile_assets = assets;
        hostile_assets[index].sha256 = &wrong_sha;
        manifest.assets = &hostile_assets;
        try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, canonical));

        hostile_assets = assets;
        hostile_assets[index].role = if (index == 2) .universal_dmg else .evidence_summary;
        manifest.assets = &hostile_assets;
        try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, canonical));

        hostile_assets = assets;
        hostile_assets[index].name = "other";
        manifest.assets = &hostile_assets;
        try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, canonical));
    }

    manifest.assets = assets[0..2];
    try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, canonical));
    const extra_assets = assets ++ [_]manifest_mod.Asset{assets[0]};
    manifest.assets = &extra_assets;
    try std.testing.expectError(error.AuthorityChanged, product.testing_api.requireSemanticGraph(&manifest, canonical));
}

fn observed(inode: u64, size: u64, digest_byte: u8) files.ExecutableObservation {
    return .{
        .identity = .{ .device = 1, .inode = inode },
        .size = size,
        .mode = 0o600,
        .sha256 = @splat(digest_byte),
    };
}

test "concrete product run rejects before filesystem credential or child work" {
    var execution = product.Execution{};
    var response: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidInput, product.run(undefined, std.testing.allocator, .{
        .context = .{
            .repository = .{ .id = 1, .owner = "ohah", .name = "maru" },
            .tag = "v1.2.3",
            .source_commit = "0123456789abcdef0123456789abcdef01234567",
            .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/heads/main", .run_id = 1, .run_attempt = 1 },
            .protected_tag = true,
        },
        .paths = .{ .preparation = "/tmp/preparation", .aggregate = "/tmp/aggregate", .dmg = "/tmp/candidate.dmg", .frozen_executable = "/tmp/frozen" },
        .cli_path = "/tmp/gh",
        .cli = undefined,
    }, "", &response, 1, &execution));
    try std.testing.expect(execution.value() == null);
}

test "product source has one existing-component path and borrows the aggregate deadline" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_resume_authority_product.zig", std.testing.allocator, .limited(128 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "preparation_mod.open("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "aggregate_mod.openAndVerifyUntil("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "aggregate_mod.openAndVerify("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "current_mod.authenticateUntil("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "adoption.adopt("));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "requireCrossIdentityGraph("));
    // One production call, one implementation declaration, and one test-only forwarding seam.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, source, "requireSemanticGraphImpl("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "cli_mod.revalidate("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "self.execution.aggregate.deinit()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "self.execution.preparation.deinit()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "pub fn runBorrowingDeadline("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "return runBound(io, allocator, inputs, token, response, deadline, false, execution);"));
}

test "borrowed deadline preflight does not consume caller authority" {
    var execution = product.Execution{};
    var deadline = product.Deadline{};
    try product.startDeadline(std.time.ns_per_s, &deadline);
    defer deadline.deinit() catch {};
    var response: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidInput, product.runBorrowingDeadline(undefined, std.testing.allocator, .{
        .context = .{
            .repository = .{ .id = 1, .owner = "ohah", .name = "maru" },
            .tag = "v1.2.3",
            .source_commit = "0123456789abcdef0123456789abcdef01234567",
            .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/heads/main", .run_id = 1, .run_attempt = 1 },
            .protected_tag = true,
        },
        .paths = .{ .preparation = "/tmp/preparation", .aggregate = "/tmp/aggregate", .dmg = "/tmp/candidate.dmg", .frozen_executable = "/tmp/frozen" },
        .cli_path = "/tmp/gh",
        .cli = undefined,
    }, "", &response, &deadline, &execution));
    _ = try deadline.remaining();
    try std.testing.expect(execution.value() == null);
}
