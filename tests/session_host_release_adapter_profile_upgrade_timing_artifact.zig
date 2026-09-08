//! Credential-free canonical timing artifact publication contract.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const artifact = @import("release_adapter_profile_upgrade_timing_artifact");

const context = @import("release_adapter_context").Context{
    .repository = .{ .id = 12345, .owner = "ohah", .name = "maru" },
    .tag = "v1.2.3",
    .source_commit = "0123456789abcdef0123456789abcdef01234567",
    .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
    .protected_tag = true,
};

const timing: artifact.TimingView = .{ .predecessor_auth_ns = 10, .signed_one_ns = 20, .signed_near_max_ns = 30, .runner_phase_ns = 60, .profile_phase_ns = 80 };

const Authority = struct {
    calls: usize = 0,
    drift_after_first: bool = false,
    pub fn revalidate(self: *@This()) !artifact.Snapshot {
        self.calls += 1;
        var current = context;
        if (self.drift_after_first and self.calls > 1) current.build.run_attempt += 1;
        return .{ .context = current, .timing = timing };
    }
};

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

fn privateDirectory(tmp: *std.testing.TmpDir) !void {
    try tmp.dir.createDir(std.testing.io, "private", .default_dir);
    if (std.c.fchmodat(tmp.dir.handle, "private", 0o700, 0) != 0) return error.FixtureFailed;
}

test "artifact is a final-address owner with explicit audit state" {
    var value: artifact.Artifact = .{};
    try std.testing.expect(value.isPristineForComposition());
    try std.testing.expect(value.value() == null);
    try std.testing.expect(@hasDecl(artifact.Artifact, "revalidate"));
    try std.testing.expect(@hasDecl(artifact.Artifact, "cleanup"));
}

test "production surface accepts typed context execution and output only" {
    _ = &artifact.publish;
    try std.testing.expect(!@hasDecl(artifact, "publishDurations"));
    try std.testing.expect(!@hasDecl(artifact, "publishSuccess"));
    try std.testing.expect(!@hasDecl(artifact, "publishProfile"));
}

test "canonical projection rejects invalid timing sums and overflow" {
    const valid: artifact.TimingView = .{
        .predecessor_auth_ns = 10,
        .signed_one_ns = 20,
        .signed_near_max_ns = 30,
        .runner_phase_ns = 60,
        .profile_phase_ns = 80,
    };
    try artifact.validateTiming(valid);
    var invalid = valid;
    invalid.runner_phase_ns = 49;
    try std.testing.expectError(error.InvalidTiming, artifact.validateTiming(invalid));
    invalid = valid;
    invalid.signed_one_ns = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidTiming, artifact.validateTiming(invalid));
}

test "canonical schema and profile are closed constants" {
    try std.testing.expectEqualStrings("maru.session-host-profile-upgrade-timing.v1", artifact.schema);
    try std.testing.expectEqualStrings("upgrade_b", artifact.profile);
}

test "test seam exists for deterministic publication and post-owner fence failures" {
    _ = &artifact.publishWith;
    _ = &artifact.reopen;
}

test "actual private filesystem publication emits exact canonical bytes and cleans exact leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try privateDirectory(&tmp);
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "private/profile-timing.json", &path_buf);
    var authority = Authority{};
    var result: artifact.Artifact = .{};
    try artifact.publishWith(std.testing.allocator, &authority, path, &result);
    const expected = "{\"schema\":\"maru.session-host-profile-upgrade-timing.v1\",\"profile\":\"upgrade_b\",\"repository_id\":12345,\"repository\":\"ohah/maru\",\"tag\":\"v1.2.3\",\"source_commit\":\"0123456789abcdef0123456789abcdef01234567\",\"workflow_ref\":\"ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3\",\"run_id\":333,\"run_attempt\":2,\"predecessor_auth_ns\":10,\"signed_one_ns\":20,\"signed_near_max_ns\":30,\"runner_phase_ns\":60,\"profile_phase_ns\":80}\n";
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "private/profile-timing.json", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast((try tmp.dir.statFile(std.testing.io, "private/profile-timing.json", .{})).permissions.toMode() & 0o777)));
    _ = try result.revalidate();
    try result.cleanup();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "private/profile-timing.json", .{}));
}

test "retained close releases descriptors while preserving canonical bytes for fresh reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try privateDirectory(&tmp);
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "private/profile-timing.json", &path_buf);
    var authority = Authority{};
    var result: artifact.Artifact = .{};
    const fd_before = try openFdCount();
    try artifact.publishWith(std.testing.allocator, &authority, path, &result);
    try result.closeRetaining();
    try std.testing.expectEqual(artifact.Phase.retained_closed, result.phase);
    try std.testing.expect(result.value() == null);
    try std.testing.expectEqual(fd_before, try openFdCount());
    var reopened: artifact.Artifact = .{};
    try artifact.reopen(std.testing.allocator, path, context, &reopened);
    _ = try reopened.revalidate();
    try reopened.cleanup();
}

test "post-owner authority drift retains an auditable artifact that fresh process can reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try privateDirectory(&tmp);
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "private/profile-timing.json", &path_buf);
    var authority = Authority{ .drift_after_first = true };
    var failed: artifact.Artifact = .{};
    try std.testing.expectError(error.AuthorityChanged, artifact.publishWith(std.testing.allocator, &authority, path, &failed));
    try std.testing.expect((failed.value() orelse return error.TestUnexpectedResult).audit_required);
    try failed.file.deinit();
    failed = .{};
    var reopened: artifact.Artifact = .{};
    try artifact.reopen(std.testing.allocator, path, context, &reopened);
    try std.testing.expect(!(try reopened.revalidate()).audit_required);
    try reopened.cleanup();
}

test "existing destination and non-private parent publish no owner and preserve foreign bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try privateDirectory(&tmp);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "private/existing.json", .data = "foreign" });
    var existing_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var authority = Authority{};
    var result: artifact.Artifact = .{};
    try std.testing.expectError(error.DestinationExists, artifact.publishWith(std.testing.allocator, &authority, try absolute(&tmp, "private/existing.json", &existing_buf), &result));
    try std.testing.expect(result.isPristineForComposition());
    const foreign = try tmp.dir.readFileAlloc(std.testing.io, "private/existing.json", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(foreign);
    try std.testing.expectEqualStrings("foreign", foreign);
    try tmp.dir.createDir(std.testing.io, "public", .default_dir);
    if (std.c.fchmodat(tmp.dir.handle, "public", 0o755, 0) != 0) return error.FixtureFailed;
    var public_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    try std.testing.expectError(error.UnsafePath, artifact.publishWith(std.testing.allocator, &authority, try absolute(&tmp, "public/new.json", &public_buf), &result));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "public/new.json", .{}));
}

test "profile timing artifact records actual APFS publication samples without FD or staging leaks" {
    const samples: usize = if (builtin.mode == .ReleaseFast) 40 else 1;
    var elapsed: [40]u64 = undefined;
    const fd_before = try openFdCount();
    for (0..samples) |index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try privateDirectory(&tmp);
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = try absolute(&tmp, "private/profile-timing.json", &path_buf);
        var authority = Authority{};
        var result: artifact.Artifact = .{};
        const started = monotonicNs();
        try artifact.publishWith(std.testing.allocator, &authority, path, &result);
        _ = try result.revalidate();
        elapsed[index] = monotonicNs() - started;
        try expectNoStaging(&tmp);
        try result.cleanup();
    }
    const fd_after = try openFdCount();
    try std.testing.expectEqual(fd_before, fd_after);
    std.mem.sort(u64, elapsed[0..samples], {}, std.sort.asc(u64));
    std.debug.print("profile_upgrade_timing_artifact_apfs schema=maru.session-host-profile-upgrade-timing-artifact-perf.v1 mode={s} samples={d} failures=0 fd_delta=0 median_ns={d} p95_ns={d} max_ns={d} staging_residue=0\n", .{
        @tagName(builtin.mode), samples, elapsed[samples / 2], elapsed[(samples * 95 - 1) / 100], elapsed[samples - 1],
    });
}

test "copied owners and pathname mode link and inode drift fail closed without deleting replacements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try privateDirectory(&tmp);
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var moved_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try absolute(&tmp, "private/profile-timing.json", &path_buf);
    const moved = try absolute(&tmp, "private/original.json", &moved_buf);
    var authority = Authority{};
    var result: artifact.Artifact = .{};
    try artifact.publishWith(std.testing.allocator, &authority, path, &result);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    try std.testing.expectError(error.InvalidOwner, copied.cleanup());
    if (std.c.linkat(tmp.dir.handle, "private/profile-timing.json", tmp.dir.handle, "private/alias.json", 0) != 0) return error.FixtureFailed;
    try std.testing.expectError(error.FileChanged, result.revalidate());
    try tmp.dir.deleteFile(std.testing.io, "private/alias.json");
    if (std.c.rename(path.ptr, moved.ptr) != 0) return error.FixtureFailed;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "private/profile-timing.json", .data = "foreign" });
    try std.testing.expectError(error.CleanupFailed, result.cleanup());
    const foreign = try tmp.dir.readFileAlloc(std.testing.io, "private/profile-timing.json", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(foreign);
    try std.testing.expectEqualStrings("foreign", foreign);
    try result.file.deinit();
}

test "publisher source remains credential and live-session independent" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_profile_upgrade_timing_artifact.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{ "GH_TOKEN", "GITHUB_TOKEN", "std.process", "getenv", "registry", "manifest.json", "session-host.sock", "kill(" }) |forbidden|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, forbidden));
}

fn expectNoStaging(tmp: *std.testing.TmpDir) !void {
    var dir = try tmp.dir.openDir(std.testing.io, "private", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry|
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".maru-release-summary-"));
}

fn openFdCount() !u32 {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/dev/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var result: u32 = 0;
    while (try iterator.next(std.testing.io)) |_| result += 1;
    return result;
}

fn monotonicNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
