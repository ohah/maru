const std = @import("std");
const context_mod = @import("release_adapter_context");
const evidence = @import("release_evidence");
const record = @import("release_adapter_notification_workflow_record");
const verifier = @import("release_adapter_notification_workflow_verifier");

const source = "0123456789abcdef0123456789abcdef01234567";
const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const context: context_mod.Context = .{ .repository = .{ .id = 1_257_870_483, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = source, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 33, .run_attempt = 2 }, .protected_tag = true };

const Remote = struct {
    drift: bool = false,
    authenticate_calls: usize = 0,
    attest_calls: usize = 0,
    revalidate_calls: usize = 0,

    pub fn authenticate(self: *@This()) !record.Authority {
        self.authenticate_calls += 1;
        return .{ .repository_id = context.repository.id, .run_id = context.build.run_id, .run_attempt = if (self.drift) 1 else context.build.run_attempt, .source_commit = source, .job_id = 4, .deployment_id = 5, .environment_id = 6, .protected_environment = true };
    }
    pub fn attest(self: *@This(), _: []const u8, _: []const u8, name: []const u8, sha256: []const u8) !record.Attestation {
        self.attest_calls += 1;
        return .{ .verified = true, .run_id = context.build.run_id, .run_attempt = context.build.run_attempt, .subject_name = name, .subject_sha256 = sha256, .self_hosted = true };
    }
    pub fn revalidateCli(self: *@This()) !void {
        self.revalidate_calls += 1;
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    cli: [std.fs.max_path_bytes:0]u8 = @splat(0),
    evidence_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    bundle: [std.fs.max_path_bytes:0]u8 = @splat(0),
    output: [std.fs.max_path_bytes:0]u8 = @splat(0),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        const bytes = try evidence.writeNotificationCenterLeaf(std.testing.allocator, leafInput());
        defer std.testing.allocator.free(bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notification-center.json", .data = bytes });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notification-center.bundle.json", .data = "bundle\n" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gh", .data = "fixture\n" });
        self.root_len = try self.tmp.dir.realPath(std.testing.io, &self.root);
        _ = try std.fmt.bufPrintZ(&self.cli, "{s}/gh", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.evidence_path, "{s}/notification-center.json", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.bundle, "{s}/notification-center.bundle.json", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.output, "{s}/{s}", .{ self.root[0..self.root_len], verifier.final_name });
    }
    fn deinit(self: *@This()) void {
        self.tmp.cleanup();
    }
    fn command(self: *@This()) verifier.Command {
        return .{ .cli_path = std.mem.sliceTo(&self.cli, 0), .cli_sha256 = digest, .evidence_path = std.mem.sliceTo(&self.evidence_path, 0), .bundle_path = std.mem.sliceTo(&self.bundle, 0), .output_path = std.mem.sliceTo(&self.output, 0) };
    }
};

test "actual no-follow inputs publish one read-only canonical protected verdict" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var remote: Remote = .{};
    try verifier.verifyWith(std.testing.allocator, context, fixture.command(), &remote);
    try std.testing.expectEqual(@as(usize, 1), remote.authenticate_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.attest_calls);
    try std.testing.expectEqual(@as(usize, 2), remote.revalidate_calls);
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, verifier.final_name, std.testing.allocator, .limited(record.max_bytes));
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parse(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(context.build.run_attempt, parsed.value.run_attempt);
    const stat = try fixture.tmp.dir.statFile(std.testing.io, verifier.final_name, .{});
    try std.testing.expectEqual(@as(u32, 0o400), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
}

test "authority drift and aliased paths leave final output absent" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var remote: Remote = .{ .drift = true };
    try std.testing.expectError(error.AuthorityMismatch, verifier.verifyWith(std.testing.allocator, context, fixture.command(), &remote));
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.access(std.testing.io, verifier.final_name, .{}));
    var command = fixture.command();
    command.bundle_path = command.evidence_path;
    try std.testing.expectError(error.InvalidPath, verifier.verifyWith(std.testing.allocator, context, command, &remote));
}

test "hardlinked evidence and bundle are rejected before remote authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.deleteFile(std.testing.io, "notification-center.bundle.json");
    try std.testing.expectEqual(@as(i32, 0), std.c.linkat(fixture.tmp.dir.handle, "notification-center.json", fixture.tmp.dir.handle, "notification-center.bundle.json", 0));
    var remote: Remote = .{};
    try std.testing.expectError(error.PathAlias, verifier.verifyWith(std.testing.allocator, context, fixture.command(), &remote));
    try std.testing.expectEqual(@as(usize, 0), remote.authenticate_calls);
}

fn leafInput() evidence.NotificationCenterInput {
    return .{ .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .candidate_dmg_sha256 = digest, .candidate_executable_sha256 = digest, .designated_requirement_sha256 = digest, .permission = .authorized, .gui_zero = scenario(7, "gui-zero", 10), .gui_live_then_quit = scenario(8, "gui-live-then-quit", 20), .cleanup_complete = true };
}

fn scenario(event_id: u64, comptime suffix: []const u8, base: u64) evidence.NotificationCenterScenarioInput {
    const request = if (event_id == 7) "maru-11111111111111111111111111111111-22222222222222222222222222222222-7" else "maru-11111111111111111111111111111111-22222222222222222222222222222222-8";
    return .{ .host_id = "11111111111111111111111111111111", .runtime_id = "22222222222222222222222222222222", .event_id = event_id, .request_identifier = request, .visible_nonce = "123e4567-e89b-42d3-a456-426614174000-" ++ suffix, .daemon_pid_before = 1, .daemon_pid_after = 1, .child_pid_before = 2, .child_pid_after = 2, .submitted_at_ns = base, .delivered_at_ns = base + 1, .clicked_at_ns = base + 2, .callback_at_ns = base + 3, .attached_at_ns = base + 4, .os_delivered = true, .actual_click = true, .exact_attach = true, .screen_before_preserved = true, .screen_after_writable = true };
}
