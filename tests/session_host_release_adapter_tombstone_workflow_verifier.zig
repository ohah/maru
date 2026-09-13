const std = @import("std");
const context_mod = @import("release_adapter_context");
const evidence = @import("release_adapter_tombstone_evidence");
const record = @import("release_adapter_tombstone_workflow_record");
const verifier = @import("release_adapter_tombstone_workflow_verifier");

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
    leaf: [std.fs.max_path_bytes:0]u8 = @splat(0),
    bundle: [std.fs.max_path_bytes:0]u8 = @splat(0),
    output: [std.fs.max_path_bytes:0]u8 = @splat(0),
    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        const bytes = try evidence.encode(std.testing.allocator, leafValue());
        defer std.testing.allocator.free(bytes);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tombstone-relaunch.json", .data = bytes });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tombstone-relaunch.bundle.json", .data = "bundle\n" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gh", .data = "fixture\n" });
        self.root_len = try self.tmp.dir.realPath(std.testing.io, &self.root);
        _ = try std.fmt.bufPrintZ(&self.cli, "{s}/gh", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.leaf, "{s}/tombstone-relaunch.json", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.bundle, "{s}/tombstone-relaunch.bundle.json", .{self.root[0..self.root_len]});
        _ = try std.fmt.bufPrintZ(&self.output, "{s}/{s}", .{ self.root[0..self.root_len], verifier.final_name });
    }
    fn deinit(self: *@This()) void {
        self.tmp.cleanup();
    }
    fn command(self: *@This()) verifier.Command {
        return .{ .cli_path = std.mem.sliceTo(&self.cli, 0), .cli_sha256 = digest, .evidence_path = std.mem.sliceTo(&self.leaf, 0), .bundle_path = std.mem.sliceTo(&self.bundle, 0), .output_path = std.mem.sliceTo(&self.output, 0) };
    }
};

test "held leaf and bundle publish one read-only protected verdict" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var remote: Remote = .{};
    try verifier.verifyWith(std.testing.allocator, context, fixture.command(), &remote);
    try std.testing.expectEqual(@as(usize, 1), remote.authenticate_calls);
    try std.testing.expectEqual(@as(usize, 1), remote.attest_calls);
    try std.testing.expectEqual(@as(usize, 2), remote.revalidate_calls);
    const stat = try fixture.tmp.dir.statFile(std.testing.io, verifier.final_name, .{});
    try std.testing.expectEqual(@as(u32, 0o400), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
}

test "authority drift alias and hardlink publish nothing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var remote: Remote = .{ .drift = true };
    try std.testing.expectError(error.AuthorityMismatch, verifier.verifyWith(std.testing.allocator, context, fixture.command(), &remote));
    var command = fixture.command();
    command.bundle_path = command.evidence_path;
    try std.testing.expectError(error.InvalidPath, verifier.verifyWith(std.testing.allocator, context, command, &remote));
    try fixture.tmp.dir.deleteFile(std.testing.io, "tombstone-relaunch.bundle.json");
    try std.testing.expectEqual(@as(i32, 0), std.c.linkat(fixture.tmp.dir.handle, "tombstone-relaunch.json", fixture.tmp.dir.handle, "tombstone-relaunch.bundle.json", 0));
    remote = .{};
    try std.testing.expectError(error.PathAlias, verifier.verifyWith(std.testing.allocator, context, fixture.command(), &remote));
    try std.testing.expectEqual(@as(usize, 0), remote.authenticate_calls);
}

fn leafValue() evidence.Record {
    return .{ .schema = evidence.schema, .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .result = .passed, .candidate_dmg_sha256 = digest, .candidate_executable_sha256 = digest, .designated_requirement_sha256 = digest, .runtime_handle = "1234567890abcdef1234567890abcdef:fedcba0987654321fedcba0987654321", .runtime_state = .ended, .relaunch_count = 2, .normal_quit_count = 2, .final_checkpoint_count = 2, .checkpoint_first_sha256 = digest, .checkpoint_second_sha256 = digest, .probe_count = 0, .attach_count = 0, .spawn_count = 0, .output_event_count = 0, .terminal_input_event_count = 0, .cleanup_complete = true };
}
