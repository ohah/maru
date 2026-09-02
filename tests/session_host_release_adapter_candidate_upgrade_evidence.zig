//! Candidate and predecessor authorities must both remain current until upgrade evidence publication.

const std = @import("std");
const evidence = @import("release_evidence");
const upgrade = @import("release_adapter_candidate_upgrade_evidence");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const sha_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const sha_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const sha_c = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const sha_d = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const sha_e = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const sha_f = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

fn common() evidence.Common {
    return .{ .test_uuid = uuid, .repository = .{ .id = 123, .owner = "ohah", .name = "maru" }, .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" }, .source = .{ .commit = "1111111111111111111111111111111111111111", .tree = "2222222222222222222222222222222222222222" }, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 789, .run_attempt = 2 }, .candidate = .{ .dmg_sha256 = sha_a, .executable_sha256 = sha_b } };
}
fn predecessor() evidence.Predecessor {
    return .{ .release_id = 400, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = sha_c, .dmg_sha256 = sha_d, .executable_sha256 = sha_e };
}
fn leaf(comptime count: u64) []const u8 {
    return std.fmt.comptimePrint("{{\"schema\":\"maru.session-host-signed-upgrade-e2e.v2\",\"test_uuid\":\"{s}\",\"result\":\"passed\",\"predecessor_executable_sha256\":\"{s}\",\"candidate_executable_sha256\":\"{s}\",\"signer_requirement_sha256\":\"{s}\",\"runtime_count\":{d},\"runtime_set_sha256\":\"{s}\",\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"gui_exact_reattach\":true,\"runtime_reaped_after_exit\":true,\"runtime_inventory_absent_observations\":2,\"status_committed\":true,\"status_reason\":\"none\",\"upgrade_capability_preserved\":true,\"epoch_before\":3,\"epoch_after\":4}}\n", .{ uuid, sha_e, sha_b, sha_f, count, if (count == 1) sha_f else sha_c });
}

const Authority = struct {
    owner: ?*@This() = null,
    calls: usize = 0,
    drift_candidate: bool = false,
    drift_predecessor: bool = false,
    alias_bytes: ?[]const u8 = null,
    fn init(self: *@This()) void {
        self.* = .{};
        self.owner = self;
    }
    pub fn revalidate(self: *@This()) !upgrade.IdentityView {
        if (self.owner != self) return error.InvalidOwner;
        self.calls += 1;
        var c = common();
        var p = predecessor();
        if (self.alias_bytes) |bytes| c.test_uuid = bytes[0..36];
        if (self.calls >= 2 and self.drift_candidate) c.source.tree = "9999999999999999999999999999999999999999";
        if (self.calls >= 2 and self.drift_predecessor) p.manifest_sha256 = sha_f;
        return .{ .common = c, .designated_requirement_sha256 = sha_f, .predecessor = p };
    }
};
const Fixture = struct {
    tmp: std.testing.TmpDir,
    one: [std.fs.max_path_bytes:0]u8 = @splat(0),
    many: [std.fs.max_path_bytes:0]u8 = @splat(0),
    output: [std.fs.max_path_bytes:0]u8 = @splat(0),
    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one.json", .data = leaf(1) });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "many.json", .data = leaf(evidence.near_max_runtime_count) });
        _ = try absolute(&self.tmp, "one.json", &self.one);
        _ = try absolute(&self.tmp, "many.json", &self.many);
        _ = try absolute(&self.tmp, "evidence.json", &self.output);
    }
    fn deinit(self: *@This()) void {
        self.tmp.cleanup();
    }
    fn paths(self: *@This()) upgrade.Paths {
        return .{ .signed_upgrade_one = std.mem.sliceTo(&self.one, 0), .signed_upgrade_near_max = std.mem.sliceTo(&self.many, 0), .output = std.mem.sliceTo(&self.output, 0) };
    }
};
fn absolute(tmp: *std.testing.TmpDir, leaf_name: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf_name });
}
fn expectAbsent(tmp: *std.testing.TmpDir) !void {
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "evidence.json", .{}));
}

test "two authority graphs publish one bound upgrade aggregate" {
    comptime {
        _ = upgrade.publish;
    }
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var a: Authority = undefined;
    a.init();
    var out: upgrade.PublishedEvidence = .{};
    try upgrade.publishWith(std.testing.allocator, &a, f.paths(), &out);
    try std.testing.expectEqual(@as(usize, 2), a.calls);
    _ = try out.revalidate(f.paths().output);
    try out.deinit();
    const bytes = try f.tmp.dir.readFileAlloc(std.testing.io, "evidence.json", std.testing.allocator, .limited(evidence.max_evidence_bytes));
    defer std.testing.allocator.free(bytes);
    var parsed = try evidence.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try evidence.bind(parsed.value(), .{ .upgrade_b = .{ .common = common(), .predecessor = predecessor(), .designated_requirement_sha256 = sha_f } });
}
test "candidate drift leaves output absent" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var a: Authority = undefined;
    a.init();
    a.drift_candidate = true;
    var out: upgrade.PublishedEvidence = .{};
    try std.testing.expectError(error.AuthorityChanged, upgrade.publishWith(std.testing.allocator, &a, f.paths(), &out));
    try expectAbsent(&f.tmp);
}
test "predecessor drift leaves output absent" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var a: Authority = undefined;
    a.init();
    a.drift_predecessor = true;
    var out: upgrade.PublishedEvidence = .{};
    try std.testing.expectError(error.AuthorityChanged, upgrade.publishWith(std.testing.allocator, &a, f.paths(), &out));
    try expectAbsent(&f.tmp);
}
test "copied preowned and alias owners fail closed" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var a: Authority = undefined;
    a.init();
    var copied = a;
    var out: upgrade.PublishedEvidence = .{};
    try std.testing.expectError(error.InvalidOwner, upgrade.publishWith(std.testing.allocator, &copied, f.paths(), &out));
    out.owner = &out;
    try std.testing.expectError(error.InvalidOwner, upgrade.publishWith(std.testing.allocator, &a, f.paths(), &out));
    out = .{};
    var paths = f.paths();
    paths.output = std.mem.asBytes(&out)[0..1 :0];
    try std.testing.expectError(error.InvalidOwner, upgrade.publishWith(std.testing.allocator, &a, paths, &out));
    try expectAbsent(&f.tmp);
}
test "nested authority view cannot alias result storage" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var a: Authority = undefined;
    a.init();
    var out: upgrade.PublishedEvidence = .{};
    a.alias_bytes = std.mem.asBytes(&out);
    try std.testing.expectError(error.InvalidOwner, upgrade.publishWith(std.testing.allocator, &a, f.paths(), &out));
    try expectAbsent(&f.tmp);
}
test "exchanged leaves and existing output never become success" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one.json", .data = leaf(evidence.near_max_runtime_count) });
    var a: Authority = undefined;
    a.init();
    var out: upgrade.PublishedEvidence = .{};
    try std.testing.expectError(error.InvalidRuntimeCount, upgrade.publishWith(std.testing.allocator, &a, f.paths(), &out));
    try expectAbsent(&f.tmp);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one.json", .data = leaf(1) });
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "evidence.json", .data = "existing" });
    try std.testing.expectError(error.DestinationExists, upgrade.publishWith(std.testing.allocator, &a, f.paths(), &out));
    const existing = try f.tmp.dir.readFileAlloc(std.testing.io, "evidence.json", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(existing);
    try std.testing.expectEqualStrings("existing", existing);
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var a: Authority = undefined;
    a.init();
    var out: upgrade.PublishedEvidence = .{};
    upgrade.publishWith(allocator, &a, f.paths(), &out) catch |err| {
        try expectAbsent(&f.tmp);
        return err;
    };
    try out.deinit();
}
test "allocation failure leaves no partial upgrade evidence" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
