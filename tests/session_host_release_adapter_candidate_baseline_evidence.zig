//! Trusted candidate identity must still be current at the baseline evidence publication point.

const std = @import("std");
const evidence = @import("release_evidence");
const baseline = @import("release_adapter_candidate_baseline_evidence");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const dmg_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const executable_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const requirement_sha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

fn common() evidence.Common {
    return .{
        .test_uuid = uuid,
        .repository = .{ .id = 123, .owner = "ohah", .name = "maru" },
        .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" },
        .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" },
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 789, .run_attempt = 2 },
        .candidate = .{ .dmg_sha256 = dmg_sha, .executable_sha256 = executable_sha },
    };
}

fn defaultLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-default-false-baseline.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ executable_sha ++ "\",\"resolved_default\":false,\"explicit_override_present\":false,\"signed_product\":true}\n";
}

fn quitLeaf() []const u8 {
    return "{\"schema\":\"maru.session-host-signed-app-quit-reattach.v1\",\"test_uuid\":\"" ++ uuid ++ "\",\"result\":\"passed\",\"candidate_dmg_sha256\":\"" ++ dmg_sha ++ "\",\"candidate_executable_sha256\":\"" ++ executable_sha ++ "\",\"runtime_count\":1,\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"gui_exact_reattach\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"cleanup_complete\":true}\n";
}

const Authority = struct {
    owner: ?*@This() = null,
    calls: usize = 0,
    drift_on_second: bool = false,

    fn init(self: *@This()) void {
        self.* = .{};
        self.owner = self;
    }

    pub fn revalidate(self: *@This()) !baseline.IdentityView {
        if (self.owner != self) return error.InvalidOwner;
        self.calls += 1;
        var value = common();
        if (self.drift_on_second and self.calls >= 2)
            value.source.tree = "3333333333333333333333333333333333333333";
        return .{ .common = value, .designated_requirement_sha256 = requirement_sha };
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    default_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    quit_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    output_path: [std.fs.max_path_bytes:0]u8 = @splat(0),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "default.json", .data = defaultLeaf() });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "quit.json", .data = quitLeaf() });
        _ = try absolute(&self.tmp, "default.json", &self.default_path);
        _ = try absolute(&self.tmp, "quit.json", &self.quit_path);
        _ = try absolute(&self.tmp, "evidence.json", &self.output_path);
    }

    fn deinit(self: *@This()) void {
        self.tmp.cleanup();
    }

    fn paths(self: *@This()) baseline.Paths {
        return .{
            .default_false = std.mem.sliceTo(&self.default_path, 0),
            .signed_app_quit = std.mem.sliceTo(&self.quit_path, 0),
            .output = std.mem.sliceTo(&self.output_path, 0),
        };
    }
};

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

fn expectAbsent(tmp: *std.testing.TmpDir) !void {
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "evidence.json", .{}));
}

test "trusted identity publishes one baseline aggregate and held output inode" {
    comptime {
        _ = baseline.publish;
    }
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var authority: Authority = undefined;
    authority.init();
    var published: baseline.PublishedEvidence = .{};
    try baseline.publishWith(std.testing.allocator, &authority, fixture.paths(), &published);
    try std.testing.expectEqual(@as(usize, 2), authority.calls);
    _ = try published.revalidate(fixture.paths().output);
    try published.deinit();
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, "evidence.json", std.testing.allocator, .limited(evidence.max_evidence_bytes));
    defer std.testing.allocator.free(bytes);
    var parsed = try evidence.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try evidence.bind(parsed.value(), .{ .baseline_a = common() });
}

test "publication-point authority drift leaves output absent" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var authority: Authority = undefined;
    authority.init();
    authority.drift_on_second = true;
    var published: baseline.PublishedEvidence = .{};
    try std.testing.expectError(error.AuthorityChanged, baseline.publishWith(std.testing.allocator, &authority, fixture.paths(), &published));
    try std.testing.expectEqual(@as(usize, 2), authority.calls);
    try expectAbsent(&fixture.tmp);
}

test "copied authority preowned result and result-path alias fail before publication" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var authority: Authority = undefined;
    authority.init();
    var copied = authority;
    var published: baseline.PublishedEvidence = .{};
    try std.testing.expectError(error.InvalidOwner, baseline.publishWith(std.testing.allocator, &copied, fixture.paths(), &published));
    published.owner = &published;
    try std.testing.expectError(error.InvalidOwner, baseline.publishWith(std.testing.allocator, &authority, fixture.paths(), &published));
    published = .{};
    const bytes = std.mem.asBytes(&published);
    const alias: [:0]const u8 = bytes[0..1 :0];
    var paths = fixture.paths();
    paths.output = alias;
    try std.testing.expectError(error.InvalidOwner, baseline.publishWith(std.testing.allocator, &authority, paths, &published));
    try expectAbsent(&fixture.tmp);
}

test "malformed and exchanged baseline leaves never reach publication validation" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "default.json", .data = quitLeaf() });
    var authority: Authority = undefined;
    authority.init();
    var published: baseline.PublishedEvidence = .{};
    try std.testing.expectError(error.InvalidLeaf, baseline.publishWith(std.testing.allocator, &authority, fixture.paths(), &published));
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try expectAbsent(&fixture.tmp);
}

test "existing output is preserved after final authority validation" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence.json", .data = "existing" });
    var authority: Authority = undefined;
    authority.init();
    var published: baseline.PublishedEvidence = .{};
    try std.testing.expectError(error.DestinationExists, baseline.publishWith(std.testing.allocator, &authority, fixture.paths(), &published));
    try std.testing.expectEqual(@as(usize, 2), authority.calls);
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, "evidence.json", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("existing", bytes);
}

fn publishAllocation(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var authority: Authority = undefined;
    authority.init();
    var published: baseline.PublishedEvidence = .{};
    baseline.publishWith(allocator, &authority, fixture.paths(), &published) catch |err| {
        try expectAbsent(&fixture.tmp);
        return err;
    };
    try published.deinit();
}

test "allocation failure cannot leave partial baseline evidence" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, publishAllocation, .{});
}
