//! Binds the GitHub-preserved canonical pass artifact back to the protected run.

const std = @import("std");
const artifact = @import("release_adapter_remote_release_pass_artifact");
const context_mod = @import("release_adapter_context");

const source = "0123456789abcdef0123456789abcdef01234567";
const metadata_response =
    "{\"total_count\":1,\"artifacts\":[{\"id\":654,\"name\":\"session-host-release-remote-pass-2\",\"size_in_bytes\":321,\"url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/654\",\"archive_download_url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/654/zip\",\"expired\":false,\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"workflow_run\":{\"id\":333,\"repository_id\":1257870483,\"head_repository_id\":1257870483,\"head_sha\":\"0123456789abcdef0123456789abcdef01234567\"}}]}";
const record =
    "{\"schema\":\"maru.session-host-release-remote-pass.v1\",\"profile\":\"baseline_a\",\"result\":\"passed\",\"repository\":{\"id\":1257870483,\"owner\":\"ohah\",\"name\":\"maru\"},\"release\":{\"id\":88,\"tag\":\"v1.2.3\"},\"source_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"workflow_ref\":\"ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3\",\"run_id\":333,\"run_attempt\":2,\"timing_artifact_id\":987,\"duration_ms\":1000}\n";

test "one current-attempt pass artifact owns canonical remote identity" {
    var selected: artifact.Metadata = .{};
    try artifact.selectMetadata(std.testing.allocator, metadata_response, .{
        .repository_id = 1257870483,
        .run_id = 333,
        .run_attempt = 2,
        .source_sha = source,
    }, &selected);
    const value = selected.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 654), value.artifact_id);
    try std.testing.expectEqual(@as(u64, 321), value.archive_size);
    try selected.deinit();
}

test "pass artifact metadata rejects duplicate stale expired and foreign authority" {
    inline for (.{
        .{ "\"total_count\":1", "\"total_count\":2" },
        .{ "remote-pass-2", "remote-pass-1" },
        .{ "\"expired\":false", "\"expired\":true" },
        .{ "\"repository_id\":1257870483", "\"repository_id\":9" },
        .{ "\"id\":333", "\"id\":334" },
        .{ source, "1123456789abcdef0123456789abcdef01234567" },
        .{ "sha256:aaaaaaaa", "sha512:aaaaaaaa" },
        .{ "/artifacts/654/zip", "/artifacts/655/zip" },
    }) |replacement| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, metadata_response, replacement[0], replacement[1]);
        defer std.testing.allocator.free(changed);
        var selected: artifact.Metadata = .{};
        try std.testing.expectError(error.InvalidMetadata, artifact.selectMetadata(std.testing.allocator, changed, .{
            .repository_id = 1257870483,
            .run_id = 333,
            .run_attempt = 2,
            .source_sha = source,
        }, &selected));
    }
}

test "only an exact empty metadata response is retryable" {
    var selected: artifact.Metadata = .{};
    try std.testing.expectError(error.NotFound, artifact.selectMetadata(std.testing.allocator, "{\"total_count\":0,\"artifacts\":[]}", .{
        .repository_id = 1257870483,
        .run_id = 333,
        .run_attempt = 2,
        .source_sha = source,
    }, &selected));
    try std.testing.expectError(error.InvalidMetadata, artifact.selectMetadata(std.testing.allocator, "{\"total_count\":0,\"artifacts\":[{}]}", .{
        .repository_id = 1257870483,
        .run_id = 333,
        .run_attempt = 2,
        .source_sha = source,
    }, &selected));
}

test "stored pass archive publishes a context-bound credential-free owner" {
    const archive = try makeStoredArchive(std.testing.allocator, record);
    defer std.testing.allocator.free(archive);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive, &selected);
    defer selected.deinit() catch unreachable;
    var result: artifact.Provenance = .{};
    const ctx = context();
    try artifact.bindArchive(std.testing.allocator, &ctx, &selected, archive, &result);
    const value = result.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 654), value.artifact_id);
    try std.testing.expectEqualStrings("baseline_a", @tagName(value.record.profile));
    try result.deinit(std.testing.allocator);
}

test "deflated pass entry uses the shared bounded ZIP parser" {
    var compressed_storage: [artifact.archive_cap]u8 = undefined;
    var output: std.Io.Writer = .fixed(&compressed_storage);
    var compressor_storage: [std.compress.flate.max_window_len * 2]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&output, &compressor_storage, .raw, .default);
    try compressor.writer.writeAll(record);
    try compressor.finish();
    const archive = try makeArchive(std.testing.allocator, record, output.buffered(), 8);
    defer std.testing.allocator.free(archive);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive, &selected);
    defer selected.deinit() catch unreachable;
    var result: artifact.Provenance = .{};
    const ctx = context();
    try artifact.bindArchive(std.testing.allocator, &ctx, &selected, archive, &result);
    try result.deinit(std.testing.allocator);
}

test "provenance rejects copy context drift metadata drift and archive mutation" {
    const archive = try makeStoredArchive(std.testing.allocator, record);
    defer std.testing.allocator.free(archive);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive, &selected);
    var ctx = context();
    var result: artifact.Provenance = .{};
    try artifact.bindArchive(std.testing.allocator, &ctx, &selected, archive, &result);
    var copied = result;
    try std.testing.expect(copied.value() == null);
    ctx.build.run_attempt = 3;
    try std.testing.expect(result.value() == null);
    try result.deinit(std.testing.allocator);
    ctx.build.run_attempt = 2;

    selected.archive_size += 1;
    try std.testing.expectError(error.InvalidMetadata, artifact.bindArchive(std.testing.allocator, &ctx, &selected, archive, &result));
    selected.archive_size -= 1;
    try selected.deinit();

    var clean: artifact.Metadata = .{};
    try selectForArchive(archive, &clean);
    defer clean.deinit() catch unreachable;
    const changed = try std.testing.allocator.dupe(u8, archive);
    defer std.testing.allocator.free(changed);
    changed[40] ^= 1;
    try std.testing.expectError(error.InvalidArchive, artifact.bindArchive(std.testing.allocator, &ctx, &clean, changed, &result));
}

test "metadata and archive allocations unwind at every failure index" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationMetadata, .{});
    const archive = try makeStoredArchive(std.testing.allocator, record);
    defer std.testing.allocator.free(archive);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive, &selected);
    defer selected.deinit() catch unreachable;
    var ctx = context();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationArchive, .{ &ctx, &selected, archive });
}

test "pass artifact owner has no credential filesystem process or ZIP parser" {
    const source_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_remote_release_pass_artifact.zig", std.testing.allocator, .limited(artifact.response_cap));
    defer std.testing.allocator.free(source_text);
    inline for (.{ "GH_TOKEN", "GITHUB_TOKEN", "std.process", "std.fs", "std.posix", "unzip", "PK\\x03\\x04" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, source_text, forbidden) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source_text, "github_archive.extractAlloc("));
}

fn context() context_mod.Context {
    return .{ .repository = .{ .id = 1257870483, .owner = "ohah", .name = "maru" }, .tag = "v1.2.3", .source_commit = source, .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 }, .protected_tag = true };
}

fn allocationMetadata(allocator: std.mem.Allocator) !void {
    var selected: artifact.Metadata = .{};
    try artifact.selectMetadata(allocator, metadata_response, .{ .repository_id = 1257870483, .run_id = 333, .run_attempt = 2, .source_sha = source }, &selected);
    try selected.deinit();
}

fn allocationArchive(allocator: std.mem.Allocator, ctx: *const context_mod.Context, selected: *const artifact.Metadata, archive: []const u8) !void {
    var result: artifact.Provenance = .{};
    try artifact.bindArchive(allocator, ctx, selected, archive, &result);
    try result.deinit(allocator);
}

fn selectForArchive(archive: []const u8, selected: *artifact.Metadata) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const response = try std.fmt.allocPrint(std.testing.allocator, "{{\"total_count\":1,\"artifacts\":[{{\"id\":654,\"name\":\"session-host-release-remote-pass-2\",\"size_in_bytes\":{d},\"url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/654\",\"archive_download_url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/654/zip\",\"expired\":false,\"digest\":\"sha256:{s}\",\"workflow_run\":{{\"id\":333,\"repository_id\":1257870483,\"head_repository_id\":1257870483,\"head_sha\":\"{s}\"}}}}]}}", .{ archive.len, &hex, source });
    defer std.testing.allocator.free(response);
    try artifact.selectMetadata(std.testing.allocator, response, .{ .repository_id = 1257870483, .run_id = 333, .run_attempt = 2, .source_sha = source }, selected);
}

fn makeStoredArchive(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return makeArchive(allocator, content, content, 0);
}

fn makeArchive(allocator: std.mem.Allocator, content: []const u8, compressed: []const u8, method: u16) ![]u8 {
    const name = "session-host-release-remote-pass.json";
    const local_len = 30 + name.len + compressed.len;
    const central_len = 46 + name.len;
    const bytes = try allocator.alloc(u8, local_len + central_len + 22);
    @memset(bytes, 0);
    const crc = std.hash.Crc32.hash(content);
    @memcpy(bytes[0..4], "PK\x03\x04");
    put16(bytes, 4, 20);
    put32(bytes, 14, crc);
    put16(bytes, 8, method);
    put32(bytes, 18, @intCast(compressed.len));
    put32(bytes, 22, @intCast(content.len));
    put16(bytes, 26, @intCast(name.len));
    @memcpy(bytes[30..][0..name.len], name);
    @memcpy(bytes[30 + name.len ..][0..compressed.len], compressed);
    const central = local_len;
    @memcpy(bytes[central..][0..4], "PK\x01\x02");
    put16(bytes, central + 4, 0x0314);
    put16(bytes, central + 6, 20);
    put16(bytes, central + 10, method);
    put32(bytes, central + 16, crc);
    put32(bytes, central + 20, @intCast(compressed.len));
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

fn put16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

fn put32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
