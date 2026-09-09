//! Binds GitHub's artifact metadata to the protected run before archive bytes are trusted.

const std = @import("std");
const artifact = @import("release_adapter_live_timing_artifact");

const source = "0123456789abcdef0123456789abcdef01234567";
const record =
    "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"repository\":\"ohah/maru\",\"workflow\":\"release.yml\",\"run_id\":333,\"run_attempt\":2,\"source_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"job_name\":\"universal dmg (signed + notarized)\",\"step_name\":\"Run session host live release workflow\",\"started_at\":\"2026-09-09T00:00:00Z\",\"completed_at\":\"2026-09-09T00:00:01Z\",\"duration_ms\":1000}\n";
const metadata_response =
    "{\"total_count\":1,\"artifacts\":[{\"id\":987,\"name\":\"session-host-release-live-timing-2\",\"size_in_bytes\":321,\"url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/987\",\"archive_download_url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/987/zip\",\"expired\":false,\"digest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"workflow_run\":{\"id\":333,\"repository_id\":1257870483,\"head_repository_id\":1257870483,\"head_sha\":\"0123456789abcdef0123456789abcdef01234567\"}}]}";

pub fn makeProvenance(allocator: std.mem.Allocator, result: *artifact.Provenance) !void {
    const archive_bytes = try makeStoredArchive(allocator, record, false);
    defer allocator.free(archive_bytes);
    var selected: artifact.Metadata = .{};
    try selectForArchiveWithAllocator(allocator, archive_bytes, &selected);
    defer selected.deinit() catch unreachable;
    try artifact.bindArchive(allocator, &selected, archive_bytes, result);
}

test "one current-attempt timing artifact owns canonical remote identity" {
    var selected: artifact.Metadata = .{};
    try artifact.selectMetadata(std.testing.allocator, metadata_response, .{
        .repository_id = 1257870483,
        .run_id = 333,
        .run_attempt = 2,
        .source_sha = source,
    }, &selected);
    const value = selected.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 987), value.artifact_id);
    try std.testing.expectEqual(@as(u64, 321), value.archive_size);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &value.archive_sha256);
    try selected.deinit();
}

test "metadata rejects duplicate stale expired and foreign authority" {
    inline for (.{
        .{ "\"total_count\":1", "\"total_count\":2" },
        .{ "\"id\":987", "\"id\":0" },
        .{ "timing-2", "timing-1" },
        .{ "\"expired\":false", "\"expired\":true" },
        .{ "\"repository_id\":1257870483", "\"repository_id\":9" },
        .{ "\"head_repository_id\":1257870483", "\"head_repository_id\":9" },
        .{ "\"id\":333", "\"id\":334" },
        .{ source, "1123456789abcdef0123456789abcdef01234567" },
        .{ "sha256:aaaaaaaa", "sha512:aaaaaaaa" },
        .{ "/artifacts/987/zip", "/artifacts/988/zip" },
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
        try std.testing.expect(selected.value() == null);
    }
    const duplicate = try std.mem.replaceOwned(u8, std.testing.allocator, metadata_response, "\"total_count\":1", "\"total_count\":1,\"total_count\":1");
    defer std.testing.allocator.free(duplicate);
    var selected: artifact.Metadata = .{};
    try std.testing.expectError(error.InvalidMetadata, artifact.selectMetadata(std.testing.allocator, duplicate, .{
        .repository_id = 1257870483,
        .run_id = 333,
        .run_attempt = 2,
        .source_sha = source,
    }, &selected));
}

test "metadata owner rejects copy pre-owned alias and post-parse corruption" {
    var selected: artifact.Metadata = .{};
    try artifact.selectMetadata(std.testing.allocator, metadata_response, .{
        .repository_id = 1257870483,
        .run_id = 333,
        .run_attempt = 2,
        .source_sha = source,
    }, &selected);
    var copied = selected;
    try std.testing.expect(copied.value() == null);
    selected.archive_size += 1;
    try std.testing.expect(selected.value() == null);
    selected.archive_size -= 1;
    try selected.deinit();
    var alias_storage: [@sizeOf(artifact.Metadata)]u8 align(@alignOf(artifact.Metadata)) = @splat(0);
    const alias_result: *artifact.Metadata = @ptrCast(&alias_storage);
    try std.testing.expectError(error.InvalidOwner, artifact.selectMetadata(std.testing.allocator, &alias_storage, .{
        .repository_id = 1257870483,
        .run_id = 333,
        .run_attempt = 2,
        .source_sha = source,
    }, alias_result));
}

test "stored archive is digest-bound and publishes parsed timing" {
    const archive_bytes = try makeStoredArchive(std.testing.allocator, record, false);
    defer std.testing.allocator.free(archive_bytes);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive_bytes, &selected);
    defer selected.deinit() catch unreachable;
    var provenance: artifact.Provenance = .{};
    try artifact.bindArchive(std.testing.allocator, &selected, archive_bytes, &provenance);
    const value = provenance.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 987), value.artifact_id);
    try std.testing.expectEqual(@as(u64, 2), value.timing.run_attempt);
    try provenance.deinit();
}

test "GitHub-style signed data descriptor is accepted and cross-checked" {
    const archive_bytes = try makeStoredArchive(std.testing.allocator, record, true);
    defer std.testing.allocator.free(archive_bytes);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive_bytes, &selected);
    defer selected.deinit() catch unreachable;
    var provenance: artifact.Provenance = .{};
    try artifact.bindArchive(std.testing.allocator, &selected, archive_bytes, &provenance);
    try provenance.deinit();
}

test "deflated GitHub archive is bounded and parsed" {
    var output_storage: [artifact.archive_cap]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_storage);
    var compress_storage: [std.compress.flate.max_window_len * 2]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&output, &compress_storage, .raw, .default);
    try compressor.writer.writeAll(record);
    try compressor.finish();
    const archive_bytes = try makeArchive(std.testing.allocator, record, output.buffered(), 8, true);
    defer std.testing.allocator.free(archive_bytes);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive_bytes, &selected);
    defer selected.deinit() catch unreachable;
    var provenance: artifact.Provenance = .{};
    try artifact.bindArchive(std.testing.allocator, &selected, archive_bytes, &provenance);
    try provenance.deinit();

    const garbage_compressed = try std.testing.allocator.alloc(u8, output.buffered().len + 1);
    defer std.testing.allocator.free(garbage_compressed);
    @memcpy(garbage_compressed[0..output.buffered().len], output.buffered());
    garbage_compressed[output.buffered().len] = 0;
    const garbage_archive = try makeArchive(std.testing.allocator, record, garbage_compressed, 8, true);
    defer std.testing.allocator.free(garbage_archive);
    try expectArchiveRejected(garbage_archive);
}

test "record from another attempt cannot ride a current-attempt artifact" {
    const replay = try std.mem.replaceOwned(u8, std.testing.allocator, record, "\"run_attempt\":2", "\"run_attempt\":1");
    defer std.testing.allocator.free(replay);
    const archive_bytes = try makeStoredArchive(std.testing.allocator, replay, true);
    defer std.testing.allocator.free(archive_bytes);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive_bytes, &selected);
    defer selected.deinit() catch unreachable;
    var provenance: artifact.Provenance = .{};
    try std.testing.expectError(error.BindingMismatch, artifact.bindArchive(std.testing.allocator, &selected, archive_bytes, &provenance));
    try std.testing.expect(provenance.value() == null);
}

test "metadata and archive mutation invalidate publication" {
    const archive_bytes = try makeStoredArchive(std.testing.allocator, record, false);
    defer std.testing.allocator.free(archive_bytes);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive_bytes, &selected);
    selected.archive_size += 1;
    var provenance: artifact.Provenance = .{};
    try std.testing.expectError(error.InvalidMetadata, artifact.bindArchive(std.testing.allocator, &selected, archive_bytes, &provenance));
    selected.archive_size -= 1;
    try selected.deinit();

    var valid: artifact.Metadata = .{};
    try selectForArchive(archive_bytes, &valid);
    defer valid.deinit() catch unreachable;
    const changed = try std.testing.allocator.dupe(u8, archive_bytes);
    defer std.testing.allocator.free(changed);
    changed[40] ^= 1;
    try std.testing.expectError(error.InvalidArchive, artifact.bindArchive(std.testing.allocator, &valid, changed, &provenance));
}

test "provenance owner rejects copy and timing or seal corruption" {
    const archive_bytes = try makeStoredArchive(std.testing.allocator, record, true);
    defer std.testing.allocator.free(archive_bytes);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive_bytes, &selected);
    defer selected.deinit() catch unreachable;
    var provenance: artifact.Provenance = .{};
    try artifact.bindArchive(std.testing.allocator, &selected, archive_bytes, &provenance);
    var copied = provenance;
    try std.testing.expect(copied.value() == null);
    provenance.timing_record.duration_ms += 1;
    try std.testing.expect(provenance.value() == null);
    provenance.timing_record.duration_ms -= 1;
    provenance.seal[0] ^= 1;
    try std.testing.expect(provenance.value() == null);
    provenance.seal[0] ^= 1;
    try provenance.deinit();
}

test "archive structure rejects traversal duplicate encryption link and trailing bytes" {
    const clean = try makeStoredArchive(std.testing.allocator, record, true);
    defer std.testing.allocator.free(clean);
    const name_len = "session-host-release-live-timing.json".len;
    const central = 30 + name_len + record.len + 16;
    const eocd = central + 46 + name_len;
    const mutations = [_]struct { at: usize, value: u8 }{
        .{ .at = 30, .value = '/' },
        .{ .at = central + 8, .value = 9 },
        .{ .at = central + 10, .value = 99 },
        .{ .at = central + 12, .value = 1 },
        .{ .at = central + 41, .value = 0o120 },
        .{ .at = 30 + name_len + record.len + 4, .value = 0 },
        .{ .at = eocd + 8, .value = 2 },
    };
    for (mutations) |mutation| {
        const changed = try std.testing.allocator.dupe(u8, clean);
        defer std.testing.allocator.free(changed);
        changed[mutation.at] = mutation.value;
        try expectArchiveRejected(changed);
    }
    const trailing = try std.testing.allocator.alloc(u8, clean.len + 1);
    defer std.testing.allocator.free(trailing);
    @memcpy(trailing[0..clean.len], clean);
    trailing[clean.len] = 0;
    try expectArchiveRejected(trailing);
    const short_store = try makeArchive(std.testing.allocator, record, record[0 .. record.len - 1], 0, true);
    defer std.testing.allocator.free(short_store);
    try expectArchiveRejected(short_store);
}

test "metadata and archive successful allocations unwind at every fail index" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationMetadata, .{});
    const archive_bytes = try makeStoredArchive(std.testing.allocator, record, true);
    defer std.testing.allocator.free(archive_bytes);
    var selected: artifact.Metadata = .{};
    try selectForArchive(archive_bytes, &selected);
    defer selected.deinit() catch unreachable;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationArchive, .{ &selected, archive_bytes });
}

test "artifact value owner stays credential filesystem and process independent" {
    const source_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_live_timing_artifact.zig", std.testing.allocator, .limited(artifact.response_cap));
    defer std.testing.allocator.free(source_text);
    inline for (.{ "GH_TOKEN", "GITHUB_TOKEN", "std.process", "std.fs", "std.posix", "Child.run", "unzip" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, source_text, forbidden) == null);
}

fn allocationMetadata(allocator: std.mem.Allocator) !void {
    var selected: artifact.Metadata = .{};
    try artifact.selectMetadata(allocator, metadata_response, .{
        .repository_id = 1257870483,
        .run_id = 333,
        .run_attempt = 2,
        .source_sha = source,
    }, &selected);
    try selected.deinit();
}

fn allocationArchive(allocator: std.mem.Allocator, selected: *const artifact.Metadata, archive_bytes: []const u8) !void {
    var provenance: artifact.Provenance = .{};
    try artifact.bindArchive(allocator, selected, archive_bytes, &provenance);
    try provenance.deinit();
}

fn expectArchiveRejected(bytes: []const u8) !void {
    var selected: artifact.Metadata = .{};
    try selectForArchive(bytes, &selected);
    defer selected.deinit() catch unreachable;
    var provenance: artifact.Provenance = .{};
    try std.testing.expectError(error.InvalidArchive, artifact.bindArchive(std.testing.allocator, &selected, bytes, &provenance));
    try std.testing.expect(provenance.value() == null);
}

fn selectForArchive(archive_bytes: []const u8, selected: *artifact.Metadata) !void {
    return selectForArchiveWithAllocator(std.testing.allocator, archive_bytes, selected);
}

fn selectForArchiveWithAllocator(allocator: std.mem.Allocator, archive_bytes: []const u8, selected: *artifact.Metadata) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive_bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{digest});
    const response = try std.fmt.allocPrint(allocator, "{{\"total_count\":1,\"artifacts\":[{{\"id\":987,\"name\":\"session-host-release-live-timing-2\",\"size_in_bytes\":{d},\"url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/987\",\"archive_download_url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/987/zip\",\"expired\":false,\"digest\":\"sha256:{s}\",\"workflow_run\":{{\"id\":333,\"repository_id\":1257870483,\"head_repository_id\":1257870483,\"head_sha\":\"{s}\"}}}}]}}", .{ archive_bytes.len, &hex, source });
    defer allocator.free(response);
    try artifact.selectMetadata(allocator, response, .{ .repository_id = 1257870483, .run_id = 333, .run_attempt = 2, .source_sha = source }, selected);
}

fn makeStoredArchive(allocator: std.mem.Allocator, content: []const u8, descriptor: bool) ![]u8 {
    return makeArchive(allocator, content, content, 0, descriptor);
}

fn makeArchive(allocator: std.mem.Allocator, content: []const u8, compressed: []const u8, method: u16, descriptor: bool) ![]u8 {
    const name = "session-host-release-live-timing.json";
    const descriptor_len: usize = if (descriptor) 16 else 0;
    const local_len = 30 + name.len + compressed.len + descriptor_len;
    const central_len = 46 + name.len;
    const bytes = try allocator.alloc(u8, local_len + central_len + 22);
    @memset(bytes, 0);
    const crc = std.hash.Crc32.hash(content);
    @memcpy(bytes[0..4], "PK\x03\x04");
    put16(bytes, 4, 20);
    put16(bytes, 6, if (descriptor) 8 else 0);
    put16(bytes, 8, method);
    put32(bytes, 14, if (descriptor) 0 else crc);
    put32(bytes, 18, if (descriptor) 0 else @intCast(compressed.len));
    put32(bytes, 22, if (descriptor) 0 else @intCast(content.len));
    put16(bytes, 26, @intCast(name.len));
    @memcpy(bytes[30..][0..name.len], name);
    @memcpy(bytes[30 + name.len ..][0..compressed.len], compressed);
    if (descriptor) {
        const at = 30 + name.len + compressed.len;
        @memcpy(bytes[at..][0..4], "PK\x07\x08");
        put32(bytes, at + 4, crc);
        put32(bytes, at + 8, @intCast(compressed.len));
        put32(bytes, at + 12, @intCast(content.len));
    }
    const central = local_len;
    @memcpy(bytes[central..][0..4], "PK\x01\x02");
    put16(bytes, central + 4, 0x0314);
    put16(bytes, central + 6, 20);
    put16(bytes, central + 8, if (descriptor) 8 else 0);
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
