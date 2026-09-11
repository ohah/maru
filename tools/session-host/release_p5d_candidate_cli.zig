//! Token-free protected-workflow bridge for final-DMG P5d evidence production.

const std = @import("std");
const c = std.c;
const environment = @import("release_adapter_environment");
const files = @import("release_adapter_files");
const dmg = @import("release_adapter_dmg_authority");
const apple_transport = @import("release_adapter_apple_transport");
const product = @import("release_adapter_p5d_candidate_product");
const gate_mod = @import("release_adapter_p5d_candidate_gate");

const budget_ns: i128 = 12 * std.time.ns_per_min;
const capture_bytes: usize = 256 * 1024;
const option_count: usize = 10;

const Command = struct {
    test_uuid: [:0]const u8,
    dmg: [:0]const u8,
    frozen_executable: [:0]const u8,
    preflight_dmg_work: [:0]const u8,
    p5d_dmg_work: [:0]const u8,
    p5d_workspace: [:0]const u8,
    harness: [:0]const u8,
    attach_product_test: [:0]const u8,
    upload_product_test: [:0]const u8,
    output: [:0]const u8,
};

pub fn main(init: std.process.Init) void {
    mainFallible(init) catch std.process.exit(1);
}

fn mainFallible(init: std.process.Init) !void {
    var values: [1 + option_count * 2][:0]const u8 = undefined;
    var count: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |value| {
        if (count == values.len) return error.TooManyArguments;
        values[count] = value;
        count += 1;
    }
    const command = try parse(values[0..count]);
    const workflow = try environment.readCurrent();
    if (!workflow.protected_tag or workflow.tag.len < 2 or workflow.tag[0] != 'v') return error.InvalidContext;
    if (c.getenv("GH_TOKEN") != null) return error.CredentialPresent;
    try execute(init.gpa, init.io, command, workflow.tag[1..]);
}

fn parse(args: []const [:0]const u8) !Command {
    if (args.len != 1 + option_count * 2 or !std.mem.eql(u8, args[0], "run")) return error.InvalidArguments;
    var result: struct {
        test_uuid: ?[:0]const u8 = null,
        dmg: ?[:0]const u8 = null,
        frozen_executable: ?[:0]const u8 = null,
        preflight_dmg_work: ?[:0]const u8 = null,
        p5d_dmg_work: ?[:0]const u8 = null,
        p5d_workspace: ?[:0]const u8 = null,
        harness: ?[:0]const u8 = null,
        attach_product_test: ?[:0]const u8 = null,
        upload_product_test: ?[:0]const u8 = null,
        output: ?[:0]const u8 = null,
    } = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        const value = args[index + 1];
        if (value.len == 0 or value.len >= std.fs.max_path_bytes) return error.InvalidValue;
        const destination: *?[:0]const u8 = if (std.mem.eql(u8, args[index], "--test-uuid"))
            &result.test_uuid
        else if (std.mem.eql(u8, args[index], "--dmg"))
            &result.dmg
        else if (std.mem.eql(u8, args[index], "--frozen-executable"))
            &result.frozen_executable
        else if (std.mem.eql(u8, args[index], "--preflight-dmg-work"))
            &result.preflight_dmg_work
        else if (std.mem.eql(u8, args[index], "--p5d-dmg-work"))
            &result.p5d_dmg_work
        else if (std.mem.eql(u8, args[index], "--p5d-workspace"))
            &result.p5d_workspace
        else if (std.mem.eql(u8, args[index], "--harness"))
            &result.harness
        else if (std.mem.eql(u8, args[index], "--attach-product-test"))
            &result.attach_product_test
        else if (std.mem.eql(u8, args[index], "--upload-product-test"))
            &result.upload_product_test
        else if (std.mem.eql(u8, args[index], "--output"))
            &result.output
        else
            return error.UnknownOption;
        if (destination.* != null) return error.DuplicateOption;
        destination.* = value;
    }
    const command: Command = .{
        .test_uuid = result.test_uuid orelse return error.MissingOption,
        .dmg = result.dmg orelse return error.MissingOption,
        .frozen_executable = result.frozen_executable orelse return error.MissingOption,
        .preflight_dmg_work = result.preflight_dmg_work orelse return error.MissingOption,
        .p5d_dmg_work = result.p5d_dmg_work orelse return error.MissingOption,
        .p5d_workspace = result.p5d_workspace orelse return error.MissingOption,
        .harness = result.harness orelse return error.MissingOption,
        .attach_product_test = result.attach_product_test orelse return error.MissingOption,
        .upload_product_test = result.upload_product_test orelse return error.MissingOption,
        .output = result.output orelse return error.MissingOption,
    };
    if (!canonicalUuid(command.test_uuid) or !std.mem.eql(u8, std.fs.path.basename(command.output), "signed-cli-ssh.json"))
        return error.InvalidValue;
    const paths = [_][]const u8{ command.dmg, command.frozen_executable, command.preflight_dmg_work, command.p5d_dmg_work, command.p5d_workspace, command.harness, command.attach_product_test, command.upload_product_test, command.output };
    for (paths, 0..) |left, left_index| {
        if (!canonicalAbsolute(left)) return error.InvalidPath;
        for (paths[left_index + 1 ..]) |right| if (treeOverlap(left, right)) return error.PathAlias;
    }
    return command;
}

fn execute(allocator: std.mem.Allocator, io: std.Io, command: Command, version: []const u8) !void {
    var held_dmg: files.PinnedReleaseFile = .{};
    defer if (held_dmg.owner == &held_dmg) held_dmg.deinit() catch {};
    var held_frozen: files.PinnedReleaseFile = .{};
    defer if (held_frozen.owner == &held_frozen) held_frozen.deinit() catch {};
    try files.pinReleaseFileObserved(&held_dmg, command.dmg, false, files.max_release_asset_bytes);
    try files.pinReleaseFileObserved(&held_frozen, command.frozen_executable, true, files.max_release_asset_bytes);
    const initial_dmg = held_dmg.value() orelse return error.InvalidCandidate;
    const initial_frozen = held_frozen.value() orelse return error.InvalidCandidate;
    try files.requireDistinct(&.{ initial_dmg.identity, initial_frozen.identity });
    const expected_sha = initial_dmg.sha256;
    const expected: dmg.ExpectedDmg = .{ .size = initial_dmg.size, .sha256 = expected_sha };

    var preflight_storage: apple_transport.Storage = undefined;
    var preflight = try dmg.observe(allocator, io, command.dmg, command.preflight_dmg_work, expected, version, &preflight_storage, budget_ns);
    defer preflight.deinit(allocator);
    if (!std.mem.eql(u8, preflight.executableSha256(), &initial_frozen.sha256)) return error.CandidateMismatch;
    _ = try held_dmg.revalidate(command.dmg);
    _ = try held_frozen.revalidate(command.frozen_executable);

    var gate: gate_mod.Gate = .{};
    const capture = try allocator.alloc(u8, capture_bytes);
    defer allocator.free(capture);
    var product_storage: apple_transport.Storage = undefined;
    var observed = product.run(allocator, io, .{
        .candidate_dmg = command.dmg,
        .private_dmg_work = command.p5d_dmg_work,
        .expected_dmg = expected,
        .expected_version = version,
        .gate = .{
            .test_uuid = command.test_uuid,
            .candidate_dmg_sha256 = &initial_dmg.sha256,
            .candidate_executable_sha256 = &initial_frozen.sha256,
            .designated_requirement_sha256 = preflight.signing().designated_requirement_sha256,
            .workspace_path = command.p5d_workspace,
            .harness = command.harness,
            .attach_product_test = command.attach_product_test,
            .upload_product_test = command.upload_product_test,
            .output_path = command.output,
            .require_developer_id = true,
            .budget_ns = budget_ns,
        },
        .budget_ns = budget_ns,
    }, capture, &product_storage, &gate) catch |err| {
        if (gate.owner == &gate) gate.cleanup() catch return error.CleanupFailed;
        return err;
    };
    defer observed.deinit(allocator);
    if (!std.mem.eql(u8, observed.executableSha256(), &initial_frozen.sha256) or
        !std.mem.eql(u8, observed.signing().designated_requirement_sha256, preflight.signing().designated_requirement_sha256))
    {
        gate.cleanup() catch return error.CleanupFailed;
        return error.CandidateMismatch;
    }
    const final_dmg = held_dmg.revalidate(command.dmg) catch |err| {
        gate.cleanup() catch return error.CleanupFailed;
        return err;
    };
    const final_frozen = held_frozen.revalidate(command.frozen_executable) catch |err| {
        gate.cleanup() catch return error.CleanupFailed;
        return err;
    };
    if (!sameObservation(initial_dmg, final_dmg) or !sameObservation(initial_frozen, final_frozen)) {
        gate.cleanup() catch return error.CleanupFailed;
        return error.CandidateChanged;
    }
    gate.finish() catch |err| {
        if (gate.owner == &gate) gate.cleanup() catch return error.CleanupFailed;
        return err;
    };
}

fn sameObservation(left: files.ExecutableObservation, right: files.ExecutableObservation) bool {
    return left.size == right.size and left.identity.device == right.identity.device and left.identity.inode == right.identity.inode and
        left.mode == right.mode and std.mem.eql(u8, &left.sha256, &right.sha256);
}

fn canonicalAbsolute(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path[path.len - 1] == '/') return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn treeOverlap(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    if (left.len < right.len and std.mem.startsWith(u8, right, left) and right[left.len] == '/') return true;
    return right.len < left.len and std.mem.startsWith(u8, left, right) and left[right.len] == '/';
}

fn canonicalUuid(value: []const u8) bool {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-' or
        value[14] != '4' or (value[19] != '8' and value[19] != '9' and value[19] != 'a' and value[19] != 'b')) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) continue;
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

test "P5d product CLI accepts only the exact closed path graph" {
    const args = validArgs();
    const command = try parse(&args);
    try std.testing.expectEqualStrings("123e4567-e89b-42d3-a456-426614174000", command.test_uuid);
    try std.testing.expectEqualStrings("/tmp/p5d/signed-cli-ssh.json", command.output);
}

test "P5d product CLI rejects missing duplicate unknown and excess arguments" {
    const args = validArgs();
    try std.testing.expectError(error.InvalidArguments, parse(args[0 .. args.len - 2]));
    var duplicate = args;
    duplicate[duplicate.len - 2] = "--dmg";
    try std.testing.expectError(error.DuplicateOption, parse(&duplicate));
    var unknown = args;
    unknown[1] = "--candidate";
    try std.testing.expectError(error.UnknownOption, parse(&unknown));
    var excess: [validArgs().len + 2][:0]const u8 = undefined;
    @memcpy(excess[0..args.len], &args);
    excess[args.len] = "--extra";
    excess[args.len + 1] = "/tmp/extra";
    try std.testing.expectError(error.InvalidArguments, parse(&excess));
}

test "P5d product CLI rejects relative noncanonical and overlapping authorities" {
    var args = validArgs();
    args[4] = "relative";
    try std.testing.expectError(error.InvalidPath, parse(&args));
    args = validArgs();
    args[8] = "/tmp/p5d/../preflight";
    try std.testing.expectError(error.InvalidPath, parse(&args));
    args = validArgs();
    args[12] = "/tmp/p5d";
    try std.testing.expectError(error.PathAlias, parse(&args));
}

test "P5d product CLI rejects noncanonical UUID and foreign output basename before execution" {
    var args = validArgs();
    args[2] = "123e4567-e89b-12d3-a456-426614174000";
    try std.testing.expectError(error.InvalidValue, parse(&args));
    args = validArgs();
    args[args.len - 1] = "/tmp/p5d/foreign.json";
    try std.testing.expectError(error.InvalidValue, parse(&args));
}

fn validArgs() [1 + option_count * 2][:0]const u8 {
    return .{
        "run",
        "--test-uuid",
        "123e4567-e89b-42d3-a456-426614174000",
        "--dmg",
        "/tmp/candidate/Maru-1.2.3-universal.dmg",
        "--frozen-executable",
        "/tmp/candidate/maru-session-host-1.2.3",
        "--preflight-dmg-work",
        "/tmp/p5d-preflight",
        "--p5d-dmg-work",
        "/tmp/p5d-mount",
        "--p5d-workspace",
        "/tmp/p5d-workspace",
        "--harness",
        "/tmp/tools/p5d_ssh_smoke.sh",
        "--attach-product-test",
        "/tmp/bin/attach-product-test",
        "--upload-product-test",
        "/tmp/bin/upload-product-test",
        "--output",
        "/tmp/p5d/signed-cli-ssh.json",
    };
}
