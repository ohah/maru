const std = @import("std");
const subject = @import("release_adapter_p5d_candidate_gate");
const dmg = @import("release_adapter_dmg_authority");
const evidence = @import("release_evidence");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const digest_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const digest_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const digest_c = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

const FakeRunner = struct {
    calls: usize = 0,
    fail: bool = false,

    pub fn run(self: *@This(), _: std.Io, execution: anytype, child_inputs: anytype, output: []u8) ![]const u8 {
        self.calls += 1;
        try std.testing.expectEqualStrings("/candidate/Maru.app/Contents/MacOS/maru", child_inputs.candidate_cli);
        try std.testing.expectEqualStrings("/candidate/Maru.app", child_inputs.candidate_app_bundle);
        try std.testing.expectEqualStrings("/repo/tools/session-host/p5d_ssh_smoke.sh", child_inputs.harness);
        try std.testing.expect(child_inputs.require_developer_id);
        try std.testing.expect(execution.owner == null);
        if (self.fail) return error.ChildFailed;
        @memcpy(output[0..6], "passed");
        return output[0..6];
    }
};

fn inputs(output_path: [:0]const u8) subject.Inputs {
    return .{
        .test_uuid = uuid,
        .candidate_dmg_sha256 = digest_a,
        .candidate_executable_sha256 = digest_b,
        .designated_requirement_sha256 = digest_c,
        .workspace_path = "/tmp/p5d-workspace",
        .harness = "/repo/tools/session-host/p5d_ssh_smoke.sh",
        .attach_product_test = "/repo/zig-out/bin/attach-test",
        .upload_product_test = "/repo/zig-out/bin/upload-test",
        .output_path = output_path,
        .require_developer_id = true,
        .budget_ns = std.time.ns_per_s,
    };
}

fn view() dmg.MountedCandidate {
    return .{
        .cli_path = "/candidate/Maru.app/Contents/MacOS/maru",
        .app_bundle_path = "/candidate/Maru.app",
        .main_sha256 = digest_b,
        .cli_sha256 = digest_c,
        .designated_requirement_sha256 = digest_c,
    };
}

test "candidate gate executes exact mounted CLI then publishes one canonical held leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    var output_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const output_path = try std.fmt.bufPrintZ(&output_buf, "{s}/signed-cli-ssh.json", .{root[0..len]});
    var capture: [128]u8 = undefined;
    var gate: subject.Gate = .{};
    try gate.init(std.testing.allocator, std.testing.io, inputs(output_path), &capture);
    var fake = FakeRunner{};
    try gate.executeWith(&fake, view());
    try gate.publish(view());
    var bytes = try gate.readPublished(std.testing.allocator);
    defer bytes.deinit(std.testing.allocator);
    var parsed = try evidence.parseSignedCliSshLeaf(std.testing.allocator, bytes.bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(digest_c, parsed.value.candidate_cli_sha256);
    try gate.finish();
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "candidate gate rejects candidate drift before child or publication" {
    var gate: subject.Gate = .{};
    var capture: [128]u8 = undefined;
    var fake = FakeRunner{};
    const bad = dmg.MountedCandidate{ .cli_path = "/candidate/Maru.app/Contents/MacOS/maru", .app_bundle_path = "/candidate/Maru.app", .main_sha256 = digest_a, .cli_sha256 = digest_c, .designated_requirement_sha256 = digest_c };
    try gate.init(std.testing.allocator, std.testing.io, inputs("/tmp/unused-leaf"), &capture);
    try std.testing.expectError(error.CandidateChanged, gate.executeWith(&fake, bad));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "candidate gate child failure cannot publish" {
    var gate: subject.Gate = .{};
    var capture: [128]u8 = undefined;
    var fake = FakeRunner{ .fail = true };
    try gate.init(std.testing.allocator, std.testing.io, inputs("/tmp/unused-leaf"), &capture);
    try std.testing.expectError(error.ChildFailed, gate.executeWith(&fake, view()));
    try std.testing.expectError(error.InvalidPhase, gate.publish(view()));
}

test "candidate gate snapshots caller scalars and paths before execution" {
    var gate: subject.Gate = .{};
    var capture: [128]u8 = undefined;
    var mutable_digest: [64]u8 = @splat('b');
    var mutable_harness: [128:0]u8 = @splat(0);
    const original_harness = "/repo/tools/session-host/p5d_ssh_smoke.sh";
    @memcpy(mutable_harness[0..original_harness.len], original_harness);
    var supplied = inputs("/tmp/unused-leaf");
    supplied.candidate_executable_sha256 = &mutable_digest;
    supplied.harness = mutable_harness[0..original_harness.len :0];
    try gate.init(std.testing.allocator, std.testing.io, supplied, &capture);
    @memset(&mutable_digest, 'a');
    @memset(mutable_harness[0..original_harness.len], 'x');
    var fake = FakeRunner{};
    try gate.executeWith(&fake, view());
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "candidate gate rejects CLI drift after execution before publication" {
    var gate: subject.Gate = .{};
    var capture: [128]u8 = undefined;
    var fake = FakeRunner{};
    try gate.init(std.testing.allocator, std.testing.io, inputs("/tmp/unused-leaf"), &capture);
    try gate.executeWith(&fake, view());
    const drifted = dmg.MountedCandidate{ .cli_path = "/candidate/Maru.app/Contents/MacOS/maru", .app_bundle_path = "/candidate/Maru.app", .main_sha256 = digest_b, .cli_sha256 = digest_a, .designated_requirement_sha256 = digest_c };
    try std.testing.expectError(error.CandidateChanged, gate.publish(drifted));
}

test "candidate gate never overwrites an occupied evidence destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "signed-cli-ssh.json", .data = "foreign" });
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    var output_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const output_path = try std.fmt.bufPrintZ(&output_buf, "{s}/signed-cli-ssh.json", .{root[0..len]});
    var gate: subject.Gate = .{};
    var capture: [128]u8 = undefined;
    var fake = FakeRunner{};
    try gate.init(std.testing.allocator, std.testing.io, inputs(output_path), &capture);
    try gate.executeWith(&fake, view());
    try std.testing.expectError(error.DestinationExists, gate.publish(view()));
    const foreign = try tmp.dir.readFileAlloc(std.testing.io, "signed-cli-ssh.json", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(foreign);
    try std.testing.expectEqualStrings("foreign", foreign);
}
