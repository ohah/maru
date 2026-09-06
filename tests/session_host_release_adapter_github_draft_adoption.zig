//! A reauthenticated mutable draft becomes the existing publication authority without mutation.

const std = @import("std");
const manifest = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const current_mod = @import("release_adapter_github_current_release_authority");
const draft_mod = @import("release_adapter_github_draft_creation");
const adoption = @import("release_adapter_github_draft_adoption");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const commit = "0123456789abcdef0123456789abcdef01234567";

fn context() context_mod.Context {
    return .{
        .repository = .{ .id = 1_257_870_483, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = commit,
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 33_335_653_781, .run_attempt = 2 },
        .protected_tag = true,
    };
}

fn candidate() manifest.Manifest {
    return .{
        .schema = manifest.schema,
        .role = .a,
        .repository = context().repository,
        .release = .{ .id = 77, .tag = context().tag, .version = "1.2.3" },
        .source = .{ .commit = commit, .tree = "1111111111111111111111111111111111111111" },
        .build = context().build,
        .compatibility = .{ .mrsh_major = 1, .screen_codec = 1, .handoff_reader_min = 1, .handoff_reader_max = 1, .app_host_abi = 1 },
        .signing = .{ .bundle_id = "com.maru.app", .bundle_short_version = "1.2.3", .bundle_version = "123", .team_id = "TEAMID1234", .designated_requirement_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .architectures = &.{ "arm64", "x86_64" }, .notarization = "accepted", .stapled = true },
        .assets = &.{
            .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .size = 1 },
            .{ .role = .frozen_product_executable, .name = "maru-session-host", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .size = 1 },
            .{ .role = .evidence_summary, .name = "baseline-evidence.json", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .size = 1 },
        },
        .evidence = .{ .test_uuid = "123e4567-e89b-42d3-a456-426614174000", .summary_name = "baseline-evidence.json", .summary_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .result = "passed" },
    };
}

fn initCurrent(value: *current_mod.CurrentReleaseAuthority) void {
    value.* = .{
        .owner = value,
        .repository_id = context().repository.id,
        .run_id = context().build.run_id,
        .run_attempt = context().build.run_attempt,
        .job_id = 90_618_357_140,
        .deployment_id = 5_659_920_000,
        .environment_id = 161_088_068,
        .protected_environment = true,
        .release_id = 77,
        .tag_len = context().tag.len,
    };
    @memcpy(&value.source_commit, commit);
    @memcpy(value.tag[0..value.tag_len], context().tag);
}

test "current mutable draft adopts the exact existing ready authority" {
    var current: current_mod.CurrentReleaseAuthority = .{};
    initCurrent(&current);
    var result: draft_mod.DraftAuthority = .{};
    try adoption.adopt(context(), candidate(), &current, &result);
    const ready = result.value().?;
    try std.testing.expectEqual(@as(u64, 77), ready.id);
    try std.testing.expectEqualStrings("v1.2.3", ready.tag);
    try std.testing.expectEqualStrings(commit, ready.source_commit);
    try current.deinit();
    try std.testing.expect(result.value() != null);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try result.deinit();
}

test "role context and every current identity mismatch publish nothing" {
    var current: current_mod.CurrentReleaseAuthority = .{};
    initCurrent(&current);
    var result: draft_mod.DraftAuthority = .{};
    var value = candidate();
    value.role = .b;
    try std.testing.expectError(error.InvalidRolePolicy, adoption.adopt(context(), value, &current, &result));
    value = candidate();
    value.evidence.result = "failed";
    try std.testing.expectError(error.InvalidEvidence, adoption.adopt(context(), value, &current, &result));
    var wrong_context = context();
    wrong_context.build.run_attempt += 1;
    try std.testing.expectError(error.ManifestMismatch, adoption.adopt(wrong_context, candidate(), &current, &result));
    wrong_context = context();
    wrong_context.protected_tag = false;
    try std.testing.expectError(error.CurrentAuthorityMismatch, adoption.adopt(wrong_context, candidate(), &current, &result));

    inline for (.{ "repository", "run", "attempt", "source", "job", "deployment", "environment", "protected", "release", "tag" }) |field| {
        initCurrent(&current);
        if (std.mem.eql(u8, field, "repository")) current.repository_id += 1;
        if (std.mem.eql(u8, field, "run")) current.run_id += 1;
        if (std.mem.eql(u8, field, "attempt")) current.run_attempt += 1;
        if (std.mem.eql(u8, field, "source")) current.source_commit[0] = 'f';
        if (std.mem.eql(u8, field, "job")) current.job_id = 0;
        if (std.mem.eql(u8, field, "deployment")) current.deployment_id = 0;
        if (std.mem.eql(u8, field, "environment")) current.environment_id = 0;
        if (std.mem.eql(u8, field, "protected")) current.protected_environment = false;
        if (std.mem.eql(u8, field, "release")) current.release_id += 1;
        if (std.mem.eql(u8, field, "tag")) current.tag[1] = '9';
        try std.testing.expectError(error.CurrentAuthorityMismatch, adoption.adopt(context(), candidate(), &current, &result));
        try std.testing.expect(result.value() == null);
    }
}

test "copied current and pre-owned or copied result are rejected" {
    var current: current_mod.CurrentReleaseAuthority = .{};
    initCurrent(&current);
    var copied_current = current;
    var result: draft_mod.DraftAuthority = .{};
    try std.testing.expectError(error.InvalidCurrentAuthority, adoption.adopt(context(), candidate(), &copied_current, &result));
    current.tag_len = current.tag.len + 1;
    try std.testing.expectError(error.InvalidCurrentAuthority, adoption.adopt(context(), candidate(), &current, &result));
    initCurrent(&current);
    result.source_commit[0] = 'x';
    try std.testing.expectError(error.InvalidOwner, adoption.adopt(context(), candidate(), &current, &result));
    result = .{};
    try adoption.adopt(context(), candidate(), &current, &result);
    try std.testing.expectError(error.InvalidOwner, adoption.adopt(context(), candidate(), &current, &result));
    var copied_result = result;
    try std.testing.expectError(error.InvalidOwner, adoption.adopt(context(), candidate(), &current, &copied_result));
    try result.deinit();
}

test "result cannot overlap current manifest or context backing storage" {
    var current: current_mod.CurrentReleaseAuthority = .{};
    initCurrent(&current);
    const aliased_result: *draft_mod.DraftAuthority = @ptrCast(@alignCast(&current));
    try std.testing.expectError(error.StorageAlias, adoption.adopt(context(), candidate(), &current, aliased_result));
    try std.testing.expect(current.value() != null);

    var result: draft_mod.DraftAuthority = .{};
    var value = candidate();
    value.release.tag = std.mem.asBytes(&result)[0..6];
    try std.testing.expectError(error.StorageAlias, adoption.adopt(context(), value, &current, &result));
    var aliased_context = context();
    aliased_context.tag = std.mem.asBytes(&result)[0..6];
    try std.testing.expectError(error.StorageAlias, adoption.adopt(aliased_context, candidate(), &current, &result));
}

test "adoption is credential free mutation free with one resume product caller" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_github_draft_adoption.zig", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{ "GH_TOKEN", "std.process", "bounded_process", "capture(", "create(" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, forbidden));
    var src = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer src.close(std.testing.io);
    var walker = try posixWalk(src, std.testing.allocator);
    defer walker.deinit();
    var callers: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const product = try src.readFileAlloc(std.testing.io, entry.path, std.testing.allocator, .limited(16 * 1024 * 1024));
        defer std.testing.allocator.free(product);
        callers += std.mem.count(u8, product, "release_adapter_github_draft_adoption");
    }
    try std.testing.expectEqual(@as(usize, 1), callers);
}

test "current draft adoption records batched diagnostic latency without FD growth" {
    const sample_count = 40;
    const iterations_per_sample = 10_000;
    var per_call_ns: [sample_count]u64 = undefined;
    const fd_before = try openFdCount();
    var current: current_mod.CurrentReleaseAuthority = .{};
    initCurrent(&current);
    defer current.deinit() catch unreachable;

    for (&per_call_ns) |*sample| {
        const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        for (0..iterations_per_sample) |_| {
            var result: draft_mod.DraftAuthority = .{};
            try adoption.adopt(context(), candidate(), &current, &result);
            try result.deinit();
        }
        sample.* = @intCast(@divTrunc(std.Io.Clock.awake.now(std.testing.io).nanoseconds - started, iterations_per_sample));
    }

    const fd_after = try openFdCount();
    try std.testing.expectEqual(fd_before, fd_after);
    std.mem.sort(u64, &per_call_ns, {}, std.sort.asc(u64));
    std.debug.print("github_draft_adoption mode={s} samples=40 iterations_per_sample=10000 failures=0 fd_delta=0 per_call_median_ns={d} per_call_p95_ns={d} per_call_max_ns={d}\n", .{
        @tagName(@import("builtin").mode),
        per_call_ns[20],
        per_call_ns[37],
        per_call_ns[39],
    });
}

fn openFdCount() !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: u32 = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
