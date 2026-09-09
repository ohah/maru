//! Pinned GitHub CLI transport and private timing archive composition.

const std = @import("std");
const c = std.c;
const transport = @import("release_adapter_remote_release_pass_transport");
const artifact = @import("release_adapter_remote_release_pass_artifact");
const cli_authority = @import("release_adapter_github_cli_authority");
const context_mod = @import("release_adapter_context");

const source = "0123456789abcdef0123456789abcdef01234567";
const record =
    "{\"schema\":\"maru.session-host-release-remote-pass.v1\",\"profile\":\"baseline_a\",\"result\":\"passed\",\"repository\":{\"id\":1257870483,\"owner\":\"ohah\",\"name\":\"maru\"},\"release\":{\"id\":88,\"tag\":\"v1.2.3\"},\"source_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"workflow_ref\":\"ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3\",\"run_id\":333,\"run_attempt\":2,\"timing_artifact_id\":987,\"duration_ms\":1000}\n";
const protected_context: context_mod.Context = .{ .repository = .{ .id = 1257870483, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = source, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 }, .protected_tag = true };

test "metadata GET precedes selected archive GET and leaves only provenance" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.run();
    const value = fixture.result.value().?;
    try std.testing.expectEqual(@as(u64, 654), value.artifact_id);
    try std.testing.expectEqual(@as(u64, 2), value.record.run_attempt);
    try std.testing.expectEqual(@as(usize, 4), fixture.ops.revalidations);
    try std.testing.expectEqual(@as(usize, 1), fixture.ops.captures);
    try std.testing.expectEqual(@as(usize, 1), fixture.ops.downloads);
    try std.testing.expect(!try pathExists(fixture.workspace()));
}

test "metadata rejection prevents archive download and removes workspace" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.ops.metadata = "{}";
    try std.testing.expectError(error.InvalidMetadata, fixture.run());
    try std.testing.expectEqual(@as(usize, 0), fixture.ops.downloads);
    try std.testing.expect(fixture.result.value() == null);
    try std.testing.expect(!try pathExists(fixture.workspace()));
}

test "only zero-result visibility is retried within the fixed bound" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.ops.empty_before_success = 2;
    try fixture.run();
    try std.testing.expectEqual(@as(usize, 3), fixture.ops.captures);
    try std.testing.expectEqual(@as(usize, 2), fixture.ops.waits);
    try std.testing.expectEqual(@as(usize, 1), fixture.ops.downloads);

    var exhausted = try Fixture.init();
    defer exhausted.deinit();
    exhausted.ops.empty_before_success = transport.metadata_attempts;
    try std.testing.expectError(error.ArtifactNotVisible, exhausted.run());
    try std.testing.expectEqual(transport.metadata_attempts, exhausted.ops.captures);
    try std.testing.expectEqual(transport.metadata_attempts - 1, exhausted.ops.waits);
    try std.testing.expectEqual(@as(usize, 0), exhausted.ops.downloads);
}

test "malformed and duplicate metadata are never hidden by retry" {
    inline for (.{ "{}", "{\"total_count\":2,\"artifacts\":[]}" }) |invalid| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.ops.metadata = invalid;
        try std.testing.expectError(error.InvalidMetadata, fixture.run());
        try std.testing.expectEqual(@as(usize, 1), fixture.ops.captures);
        try std.testing.expectEqual(@as(usize, 0), fixture.ops.waits);
        try std.testing.expectEqual(@as(usize, 0), fixture.ops.downloads);
    }
}

test "short long and digest-drift downloads publish nothing" {
    inline for (.{ Failure.short, Failure.long, Failure.digest }) |failure| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.ops.failure = failure;
        try std.testing.expectError(if (failure == .digest) error.InvalidCapture else error.InvalidExpectedSize, fixture.run());
        try std.testing.expect(fixture.result.value() == null);
        try std.testing.expect(!try pathExists(fixture.workspace()));
    }
}

test "CLI drift at every fence is fail closed and residue free" {
    for (1..5) |fence| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.ops.fail_revalidate_at = fence;
        try std.testing.expectError(error.ExecutableChanged, fixture.run());
        try std.testing.expect(fixture.result.value() == null);
        try std.testing.expect(!try pathExists(fixture.workspace()));
    }
}

test "deadline expiry after a valid download revokes provenance after cleanup" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.ops.sleep_after_download_ms = 30;
    try @import("release_adapter_deadline").start(20 * std.time.ns_per_ms, &fixture.deadline);
    try std.testing.expectError(error.TimedOut, transport.fetchWithForTest(&fixture.ops, std.testing.allocator, fixture.cli(), "token", &protected_context, fixture.workspace(), &fixture.metadata_buffer, &fixture.deadline, &fixture.result));
    try std.testing.expect(fixture.result.value() == null);
    try std.testing.expect(!try pathExists(fixture.workspace()));
}

test "cleanup failure takes precedence over archive validation failure" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.ops.close_archive_fd = true;
    try std.testing.expectError(error.CleanupFailed, fixture.run());
    try std.testing.expect(fixture.result.value() == null);
    try std.testing.expect(!try pathExists(fixture.workspace()));
}

test "pre-owned result and existing workspace have zero child calls" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.result.owner = &fixture.result;
    try std.testing.expectError(error.InvalidOwner, fixture.run());
    try std.testing.expectEqual(@as(usize, 0), fixture.ops.revalidations);
    fixture.result = .{};
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(fixture.workspace().ptr, 0o700));
    defer _ = c.rmdir(fixture.workspace().ptr);
    try std.testing.expectError(error.WorkspaceExists, fixture.run());
    try std.testing.expectEqual(@as(usize, 0), fixture.ops.revalidations);
}

test "undersized metadata storage is rejected before filesystem and child access" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.startDeadline();
    var short: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidInput, transport.fetchWithForTest(&fixture.ops, std.testing.allocator, fixture.cli(), "token", &protected_context, fixture.workspace(), &short, &fixture.deadline, &fixture.result));
    try std.testing.expectEqual(@as(usize, 0), fixture.ops.revalidations);
    try std.testing.expect(!try pathExists(fixture.workspace()));
}

test "closed argv derive repository run attempt and selected artifact ID" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.run();
    try std.testing.expect(fixture.ops.list_shape_ok);
    try std.testing.expect(fixture.ops.download_shape_ok);
}

test "production transport runs an exact clean-environment child into the held archive fd" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fixture.zip", .data = fixture.archive });
    var archive_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const archive_path = try temporaryPath(&fixture.tmp, "fixture.zip", &archive_path_storage);
    const script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\n[ \"$GH_TOKEN\" = token ] || exit 71\n[ \"$GH_PROMPT_DISABLED\" = 1 ] || exit 72\n[ -z \"${{HOME+x}}\" ] || exit 73\ncase \"$*\" in\n  *\"runs/333/artifacts?per_page=100&name=session-host-release-remote-pass-2\"*) /usr/bin/printf '%s' '{s}' ;;\n  *\"actions/artifacts/654/zip\"*) /bin/cat '{s}' ;;\n  *) exit 74 ;;\nesac\n", .{ fixture.metadata, archive_path });
    defer std.testing.allocator.free(script);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake-gh", .data = script });
    var cli_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const cli_path = try temporaryPath(&fixture.tmp, "fake-gh", &cli_path_storage);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(cli_path.ptr, 0o700));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const pinned = try cli_authority.pin(std.testing.allocator, cli_path, &hex);
    try transport.fetch(std.testing.io, std.testing.allocator, .{ .path = cli_path, .pinned = &pinned }, "token", &protected_context, fixture.workspace(), &fixture.metadata_buffer, 10 * std.time.ns_per_s, &fixture.result);
    try std.testing.expectEqual(@as(u64, 654), fixture.result.value().?.artifact_id);
    try std.testing.expect(!try pathExists(fixture.workspace()));
}

test "production child short long failure and timeout leave no archive residue" {
    try expectProductionFailure(.short, error.InvalidExpectedSize, 10 * std.time.ns_per_s);
    try expectProductionFailure(.long, error.OutputTooLarge, 10 * std.time.ns_per_s);
    try expectProductionFailure(.child, error.ChildFailed, 10 * std.time.ns_per_s);
    try expectProductionFailure(.timeout, error.TimedOut, 80 * std.time.ns_per_ms);
}

test "transport source has no shell PATH token persistence or generic downloader" {
    const source_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_remote_release_pass_transport.zig", std.testing.allocator, .limited(128 * 1024));
    defer std.testing.allocator.free(source_text);
    inline for (.{ "std.process", "/bin/sh", "curl", "unzip", "getenv", "PATH=" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, source_text, forbidden) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source_text, "process.runWriteEnvironmentStdout("));
}

const Failure = enum { none, short, long, digest };
const ProcessFailure = enum { short, long, child, timeout };

const FakeOperations = struct {
    metadata: []const u8,
    archive: []const u8,
    revalidations: usize = 0,
    captures: usize = 0,
    downloads: usize = 0,
    fail_revalidate_at: usize = 0,
    failure: Failure = .none,
    list_shape_ok: bool = false,
    download_shape_ok: bool = false,
    sleep_after_download_ms: u64 = 0,
    close_archive_fd: bool = false,
    empty_before_success: usize = 0,
    waits: usize = 0,

    pub fn revalidateCli(self: *@This(), _: std.mem.Allocator, _: [:0]const u8, _: *const transport.PinnedExecutable) !void {
        self.revalidations += 1;
        if (self.revalidations == self.fail_revalidate_at) return error.ExecutableChanged;
    }

    pub fn capture(self: *@This(), _: [:0]const u8, token: []const u8, args: []const []const u8, output: []u8, _: i128) ![]const u8 {
        self.captures += 1;
        self.list_shape_ok = std.mem.eql(u8, token, "token") and args.len == 10 and
            std.mem.eql(u8, args[0], "api") and std.mem.eql(u8, args[1], "--method") and std.mem.eql(u8, args[2], "GET") and
            std.mem.eql(u8, args[9], "repos/ohah/maru/actions/runs/333/artifacts?per_page=100&name=session-host-release-remote-pass-2");
        const bytes = if (self.captures <= self.empty_before_success) "{\"total_count\":0,\"artifacts\":[]}" else self.metadata;
        if (bytes.len > output.len) return error.OutputTooLarge;
        @memcpy(output[0..bytes.len], bytes);
        return output[0..bytes.len];
    }

    pub fn download(self: *@This(), _: [:0]const u8, token: []const u8, args: []const []const u8, fd: c.fd_t, expected_size: u64, _: i128) !@import("bounded_process").Digest {
        self.downloads += 1;
        self.download_shape_ok = std.mem.eql(u8, token, "token") and args.len == 10 and
            std.mem.eql(u8, args[9], "repos/ohah/maru/actions/artifacts/654/zip");
        if (self.failure == .long) return error.InvalidExpectedSize;
        const bytes = if (self.failure == .short) self.archive[0 .. self.archive.len - 1] else self.archive;
        var used: usize = 0;
        while (used < bytes.len) {
            const count = c.pwrite(fd, bytes[used..].ptr, bytes.len - used, @intCast(used));
            if (count <= 0) return error.CaptureFailed;
            used += @intCast(count);
        }
        if (bytes.len != expected_size) return error.InvalidExpectedSize;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var value: @import("bounded_process").Digest = .{ .size = bytes.len, .sha256 = std.fmt.bytesToHex(digest, .lower) };
        if (self.failure == .digest) value.sha256[0] = if (value.sha256[0] == '0') '1' else '0';
        if (self.sleep_after_download_ms != 0)
            try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(@intCast(self.sleep_after_download_ms)), .awake);
        if (self.close_archive_fd) _ = c.close(fd);
        return value;
    }

    pub fn waitRetry(self: *@This(), delay_ns: i128) !void {
        self.waits += 1;
        try std.testing.expectEqual(transport.metadata_retry_ns, delay_ns);
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    workspace_storage: [std.fs.max_path_bytes:0]u8,
    workspace_len: usize,
    archive: []u8,
    metadata: []u8,
    ops: FakeOperations,
    deadline: @import("release_adapter_deadline").Deadline = .{},
    pinned: transport.PinnedExecutable = undefined,
    result: artifact.Provenance = .{},
    metadata_buffer: [artifact.response_cap]u8 = undefined,

    fn init() !@This() {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const archive = try makeStoredArchive(std.testing.allocator, record);
        errdefer std.testing.allocator.free(archive);
        const metadata = try makeMetadata(std.testing.allocator, archive);
        errdefer std.testing.allocator.free(metadata);
        var storage: [std.fs.max_path_bytes:0]u8 = undefined;
        const workspace_path = try temporaryPath(&tmp, "transport", &storage);
        const result: @This() = .{
            .tmp = tmp,
            .workspace_storage = storage,
            .workspace_len = workspace_path.len,
            .archive = archive,
            .metadata = metadata,
            .ops = .{ .metadata = metadata, .archive = archive },
        };
        return result;
    }

    fn workspace(self: *@This()) [:0]const u8 {
        return self.workspace_storage[0..self.workspace_len :0];
    }

    fn deinit(self: *@This()) void {
        if (self.result.value() != null) self.result.deinit(std.testing.allocator) catch {};
        if (self.deadline.owner == &self.deadline) self.deadline.deinit() catch {};
        std.testing.allocator.free(self.metadata);
        std.testing.allocator.free(self.archive);
        self.tmp.cleanup();
    }

    fn cli(self: *@This()) transport.Cli {
        return .{ .path = "/usr/bin/false", .pinned = &self.pinned };
    }

    fn run(self: *@This()) !void {
        try self.startDeadline();
        try transport.fetchWithForTest(&self.ops, std.testing.allocator, self.cli(), "token", &protected_context, self.workspace(), &self.metadata_buffer, &self.deadline, &self.result);
    }

    fn startDeadline(self: *@This()) !void {
        if (self.deadline.owner == null)
            try @import("release_adapter_deadline").start(10 * std.time.ns_per_s, &self.deadline);
    }
};

fn expectProductionFailure(mode: ProcessFailure, expected_error: anyerror, budget_ns: i128) !void {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fixture.zip", .data = fixture.archive });
    var archive_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const archive_path = try temporaryPath(&fixture.tmp, "fixture.zip", &archive_path_storage);
    var action_storage: [std.fs.max_path_bytes + 96]u8 = undefined;
    const action = switch (mode) {
        .short => try std.fmt.bufPrint(&action_storage, "/usr/bin/head -c {d} '{s}'", .{ fixture.archive.len - 1, archive_path }),
        .long => try std.fmt.bufPrint(&action_storage, "/bin/cat '{s}'; /usr/bin/printf x", .{archive_path}),
        .child => "exit 75",
        .timeout => "/bin/sleep 2",
    };
    const script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\ncase \"$*\" in\n  *\"runs/333/artifacts?per_page=100&name=session-host-release-remote-pass-2\"*) /usr/bin/printf '%s' '{s}' ;;\n  *\"actions/artifacts/654/zip\"*) {s} ;;\n  *) exit 74 ;;\nesac\n", .{ fixture.metadata, action });
    defer std.testing.allocator.free(script);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "failing-gh", .data = script });
    var cli_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const cli_path = try temporaryPath(&fixture.tmp, "failing-gh", &cli_path_storage);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(cli_path.ptr, 0o700));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const pinned = try cli_authority.pin(std.testing.allocator, cli_path, &hex);
    try std.testing.expectError(expected_error, transport.fetch(std.testing.io, std.testing.allocator, .{ .path = cli_path, .pinned = &pinned }, "token", &protected_context, fixture.workspace(), &fixture.metadata_buffer, budget_ns, &fixture.result));
    try std.testing.expect(fixture.result.value() == null);
    try std.testing.expect(!try pathExists(fixture.workspace()));
}

fn makeMetadata(allocator: std.mem.Allocator, archive: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{{\"total_count\":1,\"artifacts\":[{{\"id\":654,\"name\":\"session-host-release-remote-pass-2\",\"size_in_bytes\":{d},\"url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/654\",\"archive_download_url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/654/zip\",\"expired\":false,\"digest\":\"sha256:{s}\",\"workflow_run\":{{\"id\":333,\"repository_id\":1257870483,\"head_repository_id\":1257870483,\"head_sha\":\"{s}\"}}}}]}}", .{ archive.len, &hex, source });
}

fn makeStoredArchive(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const name = "session-host-release-remote-pass.json";
    const local_len = 30 + name.len + content.len + 16;
    const central_len = 46 + name.len;
    const bytes = try allocator.alloc(u8, local_len + central_len + 22);
    @memset(bytes, 0);
    const crc = std.hash.Crc32.hash(content);
    @memcpy(bytes[0..4], "PK\x03\x04");
    put16(bytes, 4, 20);
    put16(bytes, 6, 8);
    put16(bytes, 26, @intCast(name.len));
    @memcpy(bytes[30..][0..name.len], name);
    @memcpy(bytes[30 + name.len ..][0..content.len], content);
    const descriptor = 30 + name.len + content.len;
    @memcpy(bytes[descriptor..][0..4], "PK\x07\x08");
    put32(bytes, descriptor + 4, crc);
    put32(bytes, descriptor + 8, @intCast(content.len));
    put32(bytes, descriptor + 12, @intCast(content.len));
    const central = local_len;
    @memcpy(bytes[central..][0..4], "PK\x01\x02");
    put16(bytes, central + 4, 0x0314);
    put16(bytes, central + 6, 20);
    put16(bytes, central + 8, 8);
    put32(bytes, central + 16, crc);
    put32(bytes, central + 20, @intCast(content.len));
    put32(bytes, central + 24, @intCast(content.len));
    put16(bytes, central + 28, @intCast(name.len));
    put32(bytes, central + 38, @as(u32, 0o100644) << 16);
    @memcpy(bytes[central + 46 ..][0..name.len], name);
    const eocd = central + central_len;
    @memcpy(bytes[eocd..][0..4], "PK\x05\x06");
    put16(bytes, eocd + 8, 1);
    put16(bytes, eocd + 10, 1);
    put32(bytes, eocd + 12, @intCast(central_len));
    put32(bytes, eocd + 16, @intCast(central));
    return bytes;
}

fn temporaryPath(tmp: *std.testing.TmpDir, leaf: []const u8, storage: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root[0..root_len], leaf });
}

fn pathExists(path: [:0]const u8) !bool {
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn put16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}
fn put32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
