//! Current private asset 세 개만 held-directory child에서 artifact attestation하는지 검증한다.

const std = @import("std");
const manifest = @import("release_manifest");
const attestation = @import("release_adapter_github_attestation");
const current_input = @import("release_adapter_github_current_manifest_input");
const asset_files = @import("release_adapter_github_current_asset_files");
const deadline_mod = @import("release_adapter_deadline");
const composition = @import("release_adapter_github_current_asset_attestation");

const source_sha = "0123456789abcdef0123456789abcdef01234567";
const hashes = [3][64]u8{
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".*,
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".*,
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc".*,
};
const assets = [3]manifest.Asset{
    .{ .role = .evidence_summary, .name = "evidence.json", .sha256 = &hashes[2], .size = 33 },
    .{ .role = .universal_dmg, .name = "Maru-1.2.3.dmg", .sha256 = &hashes[0], .size = 11 },
    .{ .role = .frozen_product_executable, .name = "maru-1.2.3", .sha256 = &hashes[1], .size = 22 },
};
const candidate: manifest.Manifest = .{
    .schema = manifest.schema,
    .role = .b,
    .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
    .release = .{ .id = 77, .tag = "v1.2.3", .version = "1.2.3" },
    .source = .{ .commit = source_sha, .tree = "2222222222222222222222222222222222222222" },
    .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
    .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
    .signing = .{ .bundle_id = "dev.maru.apphost", .bundle_short_version = "1.2.3", .bundle_version = "1", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
    .assets = &assets,
    .evidence = .{ .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .summary_name = "evidence.json", .summary_sha256 = &hashes[2], .result = "passed" },
    .predecessor = .{ .release_id = 76, .tag = "v1.2.2", .commit = "3333333333333333333333333333333333333333", .manifest_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" },
};

const Current = struct {
    copied: bool = false,
    drift: bool = false,

    const AuthorityView = struct { repository_id: u64, run_id: u64, run_attempt: u64, source_commit: []const u8, release_id: u64, tag: []const u8, protected_environment: bool };
    const View = struct { manifest: *const manifest.Manifest, authority: AuthorityView };

    pub fn value(self: *const @This()) ?View {
        if (self.copied) return null;
        return .{ .manifest = &candidate, .authority = .{
            .repository_id = if (self.drift) 999 else candidate.repository.id,
            .run_id = candidate.build.run_id,
            .run_attempt = candidate.build.run_attempt,
            .source_commit = candidate.source.commit,
            .release_id = candidate.release.id,
            .tag = candidate.release.tag,
            .protected_environment = true,
        } };
    }
};

const AssetOwner = struct {
    copied: bool = false,
    revalidations: usize = 0,
    fail_at: ?usize = null,

    const Observation = struct { role: manifest.AssetRole, name: []const u8, size: u64, sha256: []const u8, mode: u32 = 0o100400, link_count: u64 = 1 };
    const View = struct {
        directory_fd: std.c.fd_t = 77,
        pub fn asset(_: @This(), role: manifest.AssetRole) ?Observation {
            for (assets) |asset_value| if (asset_value.role == role) return .{ .role = role, .name = asset_value.name, .size = asset_value.size, .sha256 = asset_value.sha256 };
            return null;
        }
    };

    pub fn revalidate(self: *@This()) !View {
        if (self.copied) return error.InvalidOwner;
        self.revalidations += 1;
        if (self.fail_at == self.revalidations) return error.AssetChanged;
        return .{};
    }
};

const Authority = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    pub fn revalidate(self: *@This(), _: std.mem.Allocator, path: [:0]const u8) !void {
        try std.testing.expectEqualStrings("/opt/trusted/gh", path);
        self.calls += 1;
        if (self.fail_at == self.calls) return error.CliChanged;
    }
};

const Clock = struct {
    values: []const i128,
    cursor: usize = 0,
    pub fn now(self: *@This()) !i128 {
        if (self.cursor == self.values.len) return error.ClockExhausted;
        defer self.cursor += 1;
        return self.values[self.cursor];
    }
};

const SharedDeadline = struct {
    values: []const i128,
    cursor: usize = 0,

    pub fn remaining(self: *@This()) !i128 {
        if (self.cursor == self.values.len) return error.DeadlineExhausted;
        const value = self.values[self.cursor];
        self.cursor += 1;
        if (value <= 0) return error.TimedOut;
        return value;
    }
};

const Verifier = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    budgets: [3]i128 = @splat(0),

    pub fn verify(self: *@This(), _: anytype, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, directory_fd: std.c.fd_t, artifact_path: []const u8, expected: attestation.Expected, output: []u8, budget_ns: i128) !attestation.Observed {
        try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
        try std.testing.expectEqualStrings("secret", token);
        try std.testing.expectEqual(@as(std.c.fd_t, 77), directory_fd);
        try std.testing.expect(output.len > 0);
        const order = [_]manifest.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary };
        const expected_asset = assetFor(order[self.calls]).?;
        try std.testing.expectEqualStrings(expected_asset.name, expected.subject_name);
        try std.testing.expectEqualStrings(expected_asset.sha256, expected.subject_sha256);
        var relative_storage: [std.fs.max_name_bytes + 3]u8 = undefined;
        const relative = try std.fmt.bufPrint(&relative_storage, "./{s}", .{expected_asset.name});
        try std.testing.expectEqualStrings(relative, artifact_path);
        self.budgets[self.calls] = budget_ns;
        self.calls += 1;
        if (self.fail_at == self.calls) return error.VerifierFailed;
        return .{
            .parsed = try std.json.parseFromSlice(std.json.Value, allocator, "null", .{}),
            .verified = true,
            .run_id = expected.context.build.run_id,
            .run_attempt = expected.context.build.run_attempt,
            .subject_name = expected.subject_name,
            .subject_sha256 = expected.subject_sha256,
        };
    }
};

const Executor = struct {};

fn assetFor(role: manifest.AssetRole) ?manifest.Asset {
    for (assets) |asset_value| if (asset_value.role == role) return asset_value;
    return null;
}

test "three roles use held cwd canonical order and one decreasing deadline" {
    var authority = Authority{};
    var verifier = Verifier{};
    var clock = Clock{ .values = &.{ 100, 110, 120, 130 } };
    var executor = Executor{};
    var current = Current{};
    var private = AssetOwner{};
    var result: composition.CurrentAssetAttestations = .{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    try composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, 100, &result);
    const view = result.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(candidate.repository.id, view.context.repository_id);
    try std.testing.expectEqual(candidate.release.id, view.context.release_id);
    try std.testing.expectEqual(candidate.build.run_id, view.context.run_id);
    try std.testing.expectEqualStrings(candidate.release.tag, view.context.tag);
    try std.testing.expectEqualStrings(candidate.source.commit, view.context.source_commit);
    try std.testing.expectEqualStrings(candidate.build.workflow_ref, view.context.workflow_ref);
    try std.testing.expectEqual(@as(usize, 3), authority.calls);
    try std.testing.expectEqual(@as(usize, 6), private.revalidations);
    try std.testing.expectEqualSlices(i128, &.{ 90, 80, 70 }, &verifier.budgets);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try result.deinit(std.testing.allocator);
    authority = .{};
    verifier = .{};
    clock = .{ .values = &.{ 200, 210, 220, 230 } };
    private = .{};
    try composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, 100, &result);
    try result.deinit(std.testing.allocator);
}

test "shared deadline spans every role and expiry before child or final publication unwinds" {
    var authority = Authority{};
    var verifier = Verifier{};
    var deadline = SharedDeadline{ .values = &.{ 100, 90, 90, 70, 60, 50, 40 } };
    var executor = Executor{};
    var current = Current{};
    var private = AssetOwner{};
    var result: composition.CurrentAssetAttestations = .{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    try composition.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, &result);
    try std.testing.expectEqual(@as(usize, 7), deadline.cursor);
    try std.testing.expectEqualSlices(i128, &.{ 90, 70, 50 }, &verifier.budgets);
    try result.deinit(std.testing.allocator);

    authority = .{};
    verifier = .{};
    deadline = .{ .values = &.{ 100, 90, 80, 70, 60, 50, 0 } };
    private = .{};
    try std.testing.expectError(error.TimedOut, composition.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, &result));
    try std.testing.expectEqual(@as(usize, 3), verifier.calls);
    try std.testing.expectEqual(@as(usize, 3), authority.calls);
    try std.testing.expectEqual(@as(usize, 6), private.revalidations);
    try std.testing.expect(result.value() == null);

    authority = .{};
    verifier = .{};
    deadline = .{ .values = &.{ 100, 90, 80, 0 } };
    private = .{};
    try std.testing.expectError(error.TimedOut, composition.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, &result));
    try std.testing.expectEqual(@as(usize, 1), verifier.calls);
    try std.testing.expectEqual(@as(usize, 2), authority.calls);
    try std.testing.expectEqual(@as(usize, 3), private.revalidations);
    try std.testing.expect(result.value() == null);

    authority = .{};
    verifier = .{};
    deadline = .{ .values = &.{0} };
    private = .{};
    try std.testing.expectError(error.TimedOut, composition.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), private.revalidations);
    try std.testing.expectEqual(@as(usize, 0), authority.calls);
    try std.testing.expectEqual(@as(usize, 0), verifier.calls);

    authority = .{};
    verifier = .{};
    deadline = .{ .values = &.{ 100, 90, 0 } };
    private = .{};
    try std.testing.expectError(error.TimedOut, composition.composeUntilWith(&authority, &verifier, &executor, &deadline, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, &result));
    try std.testing.expectEqual(@as(usize, 2), private.revalidations);
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(usize, 1), verifier.calls);
    try std.testing.expect(result.value() == null);

    var untouched = SharedDeadline{ .values = &.{100} };
    var drift = Current{ .drift = true };
    try std.testing.expectError(error.InvalidCurrent, composition.composeUntilWith(&authority, &verifier, &executor, &untouched, std.testing.allocator, &drift, &private, "/opt/trusted/gh", "secret", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), untouched.cursor);
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &verifier, &executor, &untouched, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, &result));
    try std.testing.expectEqual(@as(usize, 0), untouched.cursor);

    result = .{};
    var output_alias = SharedDeadline{ .values = &.{100} };
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &verifier, &executor, &output_alias, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", std.mem.asBytes(&output_alias), &result));
    try std.testing.expectEqual(@as(usize, 0), output_alias.cursor);

    const result_alias: *SharedDeadline = @ptrCast(@alignCast(&result));
    try std.testing.expectError(error.InvalidOwner, composition.composeUntilWith(&authority, &verifier, &executor, result_alias, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, &result));
    try std.testing.expect(result.value() == null);
}

test "partial verifier failure unwinds and publishes nothing" {
    var authority = Authority{};
    var verifier = Verifier{ .fail_at = 2 };
    var clock = Clock{ .values = &.{ 100, 110, 120 } };
    var executor = Executor{};
    var current = Current{};
    var private = AssetOwner{};
    var result: composition.CurrentAssetAttestations = .{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    try std.testing.expectError(error.VerifierFailed, composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, 100, &result));
    try std.testing.expect(result.value() == null);
}

test "copied context cli and filesystem drift fail closed" {
    var output: [attestation.max_response_bytes]u8 = undefined;
    inline for (.{ "current", "assets", "cli", "post" }) |failure| {
        var authority = Authority{ .fail_at = if (std.mem.eql(u8, failure, "cli")) 1 else null };
        var verifier = Verifier{};
        var clock = Clock{ .values = &.{ 100, 110, 120, 130 } };
        var executor = Executor{};
        var current = Current{ .copied = std.mem.eql(u8, failure, "current") };
        var private = AssetOwner{ .copied = std.mem.eql(u8, failure, "assets"), .fail_at = if (std.mem.eql(u8, failure, "post")) 2 else null };
        var result: composition.CurrentAssetAttestations = .{};
        try std.testing.expectError(if (std.mem.eql(u8, failure, "current")) error.InvalidCurrent else if (std.mem.eql(u8, failure, "cli")) error.CliChanged else error.InvalidAssets, composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, 100, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "authority drift preowned result and expired deadline make zero calls" {
    var authority = Authority{};
    var verifier = Verifier{};
    var executor = Executor{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    var private = AssetOwner{};
    var result: composition.CurrentAssetAttestations = .{};
    var drift = Current{ .drift = true };
    var clock = Clock{ .values = &.{100} };
    try std.testing.expectError(error.InvalidCurrent, composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &drift, &private, "/opt/trusted/gh", "secret", &output, 100, &result));
    var current = Current{};
    result.owner = &result;
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, 100, &result));
    result = .{};
    clock = .{ .values = &.{ 100, 200 } };
    try std.testing.expectError(error.TimedOut, composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, 100, &result));
    try std.testing.expectEqual(@as(usize, 0), verifier.calls);
}

test "capture storage cannot overlap the final-address result owner" {
    var authority = Authority{};
    var verifier = Verifier{};
    var executor = Executor{};
    var clock = Clock{ .values = &.{100} };
    var current = Current{};
    var private = AssetOwner{};
    var aliased_storage: [@sizeOf(composition.CurrentAssetAttestations)]u8 align(@alignOf(composition.CurrentAssetAttestations)) = @splat(0);
    const result: *composition.CurrentAssetAttestations = @ptrCast(&aliased_storage);
    result.* = .{};
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(
        &authority,
        &verifier,
        &executor,
        &clock,
        std.testing.allocator,
        &current,
        &private,
        "/opt/trusted/gh",
        "secret",
        &aliased_storage,
        100,
        result,
    ));
    try std.testing.expectEqual(@as(usize, 0), verifier.calls);
}

test "capture storage cannot overlap current private executable or token authority" {
    var authority = Authority{};
    var verifier = Verifier{};
    var executor = Executor{};
    var clock = Clock{ .values = &.{100} };
    var private = AssetOwner{};
    var result: composition.CurrentAssetAttestations = .{};

    var current_storage: [@sizeOf(Current)]u8 align(@alignOf(Current)) = @splat(0);
    const current: *Current = @ptrCast(&current_storage);
    current.* = .{};
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, current, &private, "/opt/trusted/gh", "secret", &current_storage, 100, &result));

    var current_value = Current{};
    var private_storage: [@sizeOf(AssetOwner)]u8 align(@alignOf(AssetOwner)) = @splat(0);
    const private_alias: *AssetOwner = @ptrCast(&private_storage);
    private_alias.* = .{};
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &current_value, private_alias, "/opt/trusted/gh", "secret", &private_storage, 100, &result));

    var executable_storage: ["/opt/trusted/gh".len:0]u8 = "/opt/trusted/gh".*;
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &current_value, &private, &executable_storage, "secret", executable_storage[0..], 100, &result));

    var token_storage = "secret".*;
    try std.testing.expectError(error.InvalidOwner, composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &current_value, &private, "/opt/trusted/gh", &token_storage, &token_storage, 100, &result));
    try std.testing.expectEqual(@as(usize, 0), verifier.calls);
}

test "production current and private owner types instantiate the composition boundary" {
    var authority = Authority{};
    var verifier = Verifier{};
    var clock = Clock{ .values = &.{100} };
    var executor = Executor{};
    var current: current_input.CurrentManifestInput = .{};
    var private: asset_files.CurrentAssetFiles = .{};
    var result: composition.CurrentAssetAttestations = .{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidCurrent, composition.composeWith(&authority, &verifier, &executor, &clock, std.testing.allocator, &current, &private, "/opt/trusted/gh", "secret", &output, 100, &result));
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(100, &deadline);
    defer deadline.deinit() catch unreachable;
    try std.testing.expectError(error.InvalidCurrent, composition.composeUntil(std.testing.io, std.testing.allocator, &current, &private, .{ .path = "/opt/trusted/gh", .pinned = undefined }, "secret", &output, &deadline, &result));
}

test "successful three-observation composition unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, composeForAllocationTest, .{});
}

fn composeForAllocationTest(allocator: std.mem.Allocator) !void {
    var authority = Authority{};
    var verifier = Verifier{};
    var clock = Clock{ .values = &.{ 100, 110, 120, 130 } };
    var executor = Executor{};
    var current = Current{};
    var private = AssetOwner{};
    var result: composition.CurrentAssetAttestations = .{};
    var output: [attestation.max_response_bytes]u8 = undefined;
    try composition.composeWith(&authority, &verifier, &executor, &clock, allocator, &current, &private, "/opt/trusted/gh", "secret", &output, 100, &result);
    try result.deinit(allocator);
}
