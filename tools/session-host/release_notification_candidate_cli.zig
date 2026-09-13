//! Token-free protected-workflow bridge for the signed Notification Center product gate.
//!
//! GitHub owns delivery and attestation outside this process. This child receives only closed
//! local path/UUID authority, derives one monotonic deadline, and lets the mounted candidate
//! create every runtime identity used by the two real Notification Center scenarios.

const std = @import("std");
const c = std.c;
const environment = @import("release_adapter_environment");
const files = @import("release_adapter_files");
const dmg = @import("release_adapter_dmg_authority");
const apple_transport = @import("release_adapter_apple_transport");
const product = @import("release_adapter_notification_candidate_product");

const budget_ns: i128 = 12 * std.time.ns_per_min;
const option_count: usize = 11;

const Command = struct {
    test_uuid: [:0]const u8,
    zero_uuid: [:0]const u8,
    live_uuid: [:0]const u8,
    dmg: [:0]const u8,
    preflight_dmg_work: [:0]const u8,
    product_dmg_work: [:0]const u8,
    zero_root: [:0]const u8,
    live_root: [:0]const u8,
    zero_receipt: [:0]const u8,
    live_receipt: [:0]const u8,
    output: [:0]const u8,
};

pub fn main(init: std.process.Init) void {
    mainFallible(init) catch |err| std.process.exit(exitCode(err));
}

fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.AccessibilityNotProvisioned => 70,
        error.AquaNotProvisioned => 71,
        else => 1,
    };
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
    // Credential handling and artifact publication belong to Actions steps, never the app/AX
    // process graph that can observe user UI state.
    if (c.getenv("GH_TOKEN") != null) return error.CredentialPresent;
    try execute(init.gpa, init.io, command, workflow.tag[1..]);
}

fn parse(args: []const [:0]const u8) !Command {
    if (args.len != 1 + option_count * 2 or !std.mem.eql(u8, args[0], "run")) return error.InvalidArguments;
    var result: struct {
        test_uuid: ?[:0]const u8 = null,
        zero_uuid: ?[:0]const u8 = null,
        live_uuid: ?[:0]const u8 = null,
        dmg: ?[:0]const u8 = null,
        preflight_dmg_work: ?[:0]const u8 = null,
        product_dmg_work: ?[:0]const u8 = null,
        zero_root: ?[:0]const u8 = null,
        live_root: ?[:0]const u8 = null,
        zero_receipt: ?[:0]const u8 = null,
        live_receipt: ?[:0]const u8 = null,
        output: ?[:0]const u8 = null,
    } = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        const value = args[index + 1];
        if (value.len == 0 or value.len >= std.fs.max_path_bytes) return error.InvalidValue;
        const destination: *?[:0]const u8 = if (std.mem.eql(u8, args[index], "--test-uuid"))
            &result.test_uuid
        else if (std.mem.eql(u8, args[index], "--zero-uuid"))
            &result.zero_uuid
        else if (std.mem.eql(u8, args[index], "--live-uuid"))
            &result.live_uuid
        else if (std.mem.eql(u8, args[index], "--dmg"))
            &result.dmg
        else if (std.mem.eql(u8, args[index], "--preflight-dmg-work"))
            &result.preflight_dmg_work
        else if (std.mem.eql(u8, args[index], "--product-dmg-work"))
            &result.product_dmg_work
        else if (std.mem.eql(u8, args[index], "--zero-root"))
            &result.zero_root
        else if (std.mem.eql(u8, args[index], "--live-root"))
            &result.live_root
        else if (std.mem.eql(u8, args[index], "--zero-receipt"))
            &result.zero_receipt
        else if (std.mem.eql(u8, args[index], "--live-receipt"))
            &result.live_receipt
        else if (std.mem.eql(u8, args[index], "--output"))
            &result.output
        else
            return error.UnknownOption;
        if (destination.* != null) return error.DuplicateOption;
        destination.* = value;
    }
    const command: Command = .{
        .test_uuid = result.test_uuid orelse return error.MissingOption,
        .zero_uuid = result.zero_uuid orelse return error.MissingOption,
        .live_uuid = result.live_uuid orelse return error.MissingOption,
        .dmg = result.dmg orelse return error.MissingOption,
        .preflight_dmg_work = result.preflight_dmg_work orelse return error.MissingOption,
        .product_dmg_work = result.product_dmg_work orelse return error.MissingOption,
        .zero_root = result.zero_root orelse return error.MissingOption,
        .live_root = result.live_root orelse return error.MissingOption,
        .zero_receipt = result.zero_receipt orelse return error.MissingOption,
        .live_receipt = result.live_receipt orelse return error.MissingOption,
        .output = result.output orelse return error.MissingOption,
    };
    if (!canonicalUuid(command.test_uuid) or !canonicalUuid(command.zero_uuid) or !canonicalUuid(command.live_uuid) or
        std.mem.eql(u8, command.test_uuid, command.zero_uuid) or std.mem.eql(u8, command.test_uuid, command.live_uuid) or
        std.mem.eql(u8, command.zero_uuid, command.live_uuid) or
        !std.mem.eql(u8, std.fs.path.basename(command.output), "notification-center.json")) return error.InvalidValue;
    const paths = [_][]const u8{ command.dmg, command.preflight_dmg_work, command.product_dmg_work, command.zero_root, command.live_root, command.zero_receipt, command.live_receipt, command.output };
    for (paths, 0..) |left, left_index| {
        if (!canonicalAbsolute(left)) return error.InvalidPath;
        for (paths[left_index + 1 ..]) |right| if (treeOverlap(left, right)) return error.PathAlias;
    }
    if (!canonicalRunnerRoot(command.zero_root, command.zero_uuid) or !canonicalRunnerRoot(command.live_root, command.live_uuid))
        return error.InvalidPath;
    return command;
}

fn execute(allocator: std.mem.Allocator, io: std.Io, command: Command, version: []const u8) !void {
    var held_dmg: files.PinnedReleaseFile = .{};
    defer if (held_dmg.owner == &held_dmg) held_dmg.deinit() catch {};
    try files.pinReleaseFileObserved(&held_dmg, command.dmg, false, files.max_release_asset_bytes);
    const initial = held_dmg.value() orelse return error.InvalidCandidate;
    const expected: dmg.ExpectedDmg = .{ .size = initial.size, .sha256 = initial.sha256 };

    var preflight_storage: apple_transport.Storage = undefined;
    var preflight = try dmg.observe(allocator, io, command.dmg, command.preflight_dmg_work, expected, version, &preflight_storage, budget_ns);
    defer preflight.deinit(allocator);
    _ = try held_dmg.revalidate(command.dmg);

    const submitted_i128 = std.Io.Clock.awake.now(io).nanoseconds;
    const deadline_i128 = std.math.add(i128, submitted_i128, budget_ns) catch return error.ClockOverflow;
    const submitted = std.math.cast(u64, submitted_i128) orelse return error.ClockOverflow;
    const deadline = std.math.cast(u64, deadline_i128) orelse return error.ClockOverflow;
    var zero_visible_storage: [80]u8 = undefined;
    var live_visible_storage: [96]u8 = undefined;
    const zero_visible = try std.fmt.bufPrint(&zero_visible_storage, "{s}-gui-zero", .{command.zero_uuid});
    const live_visible = try std.fmt.bufPrint(&live_visible_storage, "{s}-gui-live-then-quit", .{command.live_uuid});
    var zero_before_storage: [96]u8 = undefined;
    var zero_after_storage: [96]u8 = undefined;
    var live_before_storage: [96]u8 = undefined;
    var live_after_storage: [96]u8 = undefined;
    const zero_before = try std.fmt.bufPrint(&zero_before_storage, "MARU-N3-BEFORE-{s}", .{command.zero_uuid});
    const zero_after = try std.fmt.bufPrint(&zero_after_storage, "MARU-N3-AFTER-{s}", .{command.zero_uuid});
    const live_before = try std.fmt.bufPrint(&live_before_storage, "MARU-N3-BEFORE-{s}", .{command.live_uuid});
    const live_after = try std.fmt.bufPrint(&live_after_storage, "MARU-N3-AFTER-{s}", .{command.live_uuid});

    var adapter: product.Adapter = .{};
    var product_storage: apple_transport.Storage = undefined;
    var observed = product.run(allocator, io, .{
        .candidate_dmg = command.dmg,
        .private_dmg_work = command.product_dmg_work,
        .expected_dmg = expected,
        .expected_version = version,
        .test_uuid = command.test_uuid,
        .candidate_executable_sha256 = preflight.executableSha256(),
        .designated_requirement_sha256 = preflight.signing().designated_requirement_sha256,
        .gui_zero = scenario(.gui_zero, command.zero_uuid, command.zero_root, command.zero_receipt, zero_visible, zero_before, zero_after, submitted, deadline),
        .gui_live_then_quit = scenario(.gui_live_then_quit, command.live_uuid, command.live_root, command.live_receipt, live_visible, live_before, live_after, submitted, deadline),
        .output_path = command.output,
        .budget_ns = budget_ns,
    }, &product_storage, &adapter) catch |err| {
        if (err == error.NotProvisioned and adapter.owner == &adapter) {
            const provisioning = adapter.provisioning() orelse return error.InvalidProvisioning;
            try adapter.finishNotProvisioned();
            return switch (provisioning) {
                .accessibility => error.AccessibilityNotProvisioned,
                .aqua => error.AquaNotProvisioned,
            };
        }
        if (adapter.owner == &adapter) adapter.cleanup() catch return error.CleanupFailed;
        return err;
    };
    defer observed.deinit(allocator);
    if (!std.mem.eql(u8, observed.executableSha256(), preflight.executableSha256()) or
        !std.mem.eql(u8, observed.signing().designated_requirement_sha256, preflight.signing().designated_requirement_sha256))
    {
        adapter.cleanup() catch return error.CleanupFailed;
        return error.CandidateMismatch;
    }
    const final = held_dmg.revalidate(command.dmg) catch |err| {
        adapter.cleanup() catch return error.CleanupFailed;
        return err;
    };
    if (!sameObservation(initial, final)) {
        adapter.cleanup() catch return error.CleanupFailed;
        return error.CandidateChanged;
    }
    try adapter.finish();
}

fn scenario(kind: @import("release_adapter_notification_app_receipt").Scenario, uuid: []const u8, root: [:0]const u8, output: [:0]const u8, visible: []const u8, before: []const u8, after: []const u8, submitted: u64, deadline: u64) product.Scenario {
    return .{
        .runner_nonce = uuid,
        .runner_root = root,
        .output_path = output,
        .app_expected = .{ .scenario = kind, .request_identifier = "", .host_id = "", .runtime_id = "", .event_id = 0, .clicked_at_ns = 0, .deadline_ns = deadline },
        .helper_expected = .{ .visible_nonce = visible, .deadline_ns = deadline },
        .submitted_at_ns = submitted,
        .before_marker = before,
        .after_marker = after,
        .budget_ns = budget_ns,
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

fn canonicalRunnerRoot(path: []const u8, uuid: []const u8) bool {
    var compact: [32]u8 = undefined;
    var at: usize = 0;
    for (uuid) |byte| if (byte != '-') {
        compact[at] = byte;
        at += 1;
    };
    var expected: [40]u8 = undefined;
    const value = std.fmt.bufPrint(&expected, "/tmp/mn-{s}", .{compact[0..at]}) catch return false;
    return std.mem.eql(u8, path, value);
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

test "notification product CLI accepts only the closed UUID and path graph" {
    const args = validArgs();
    const command = try parse(&args);
    try std.testing.expectEqualStrings("123e4567-e89b-42d3-a456-426614174000", command.test_uuid);
    try std.testing.expectEqualStrings("/tmp/n3/notification-center.json", command.output);
}

test "notification product CLI rejects missing duplicate unknown and excess arguments" {
    const args = validArgs();
    try std.testing.expectError(error.InvalidArguments, parse(args[0 .. args.len - 2]));
    var duplicate = args;
    duplicate[duplicate.len - 2] = "--dmg";
    try std.testing.expectError(error.DuplicateOption, parse(&duplicate));
    var unknown = args;
    unknown[1] = "--candidate";
    try std.testing.expectError(error.UnknownOption, parse(&unknown));
}

test "notification product CLI rejects UUID reuse and path alias" {
    var args = validArgs();
    args[4] = args[2];
    try std.testing.expectError(error.InvalidValue, parse(&args));
    args = validArgs();
    args[12] = "/tmp/n3";
    try std.testing.expectError(error.PathAlias, parse(&args));
}

test "notification product CLI binds each private root to its UUID and final basename" {
    var args = validArgs();
    args[14] = "/tmp/mn-ffffffffffffffffffffffffffffffff";
    try std.testing.expectError(error.InvalidPath, parse(&args));
    args = validArgs();
    args[args.len - 1] = "/tmp/n3/foreign.json";
    try std.testing.expectError(error.InvalidValue, parse(&args));
}

test "notification product CLI preserves typed provisioning exit codes" {
    try std.testing.expectEqual(@as(u8, 70), exitCode(error.AccessibilityNotProvisioned));
    try std.testing.expectEqual(@as(u8, 71), exitCode(error.AquaNotProvisioned));
    try std.testing.expectEqual(@as(u8, 1), exitCode(error.InvalidCandidate));
}

fn validArgs() [1 + option_count * 2][:0]const u8 {
    return .{
        "run",
        "--test-uuid",
        "123e4567-e89b-42d3-a456-426614174000",
        "--zero-uuid",
        "123e4567-e89b-42d3-a456-426614174001",
        "--live-uuid",
        "123e4567-e89b-42d3-a456-426614174002",
        "--dmg",
        "/tmp/candidate/Maru-1.2.3-universal.dmg",
        "--preflight-dmg-work",
        "/tmp/n3-preflight",
        "--product-dmg-work",
        "/tmp/n3-product",
        "--zero-root",
        "/tmp/mn-123e4567e89b42d3a456426614174001",
        "--live-root",
        "/tmp/mn-123e4567e89b42d3a456426614174002",
        "--zero-receipt",
        "/tmp/n3/gui-zero.json",
        "--live-receipt",
        "/tmp/n3/gui-live.json",
        "--output",
        "/tmp/n3/notification-center.json",
    };
}
