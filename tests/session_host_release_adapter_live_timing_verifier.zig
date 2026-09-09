//! Product boundary for one protected-run live timing verification.

const std = @import("std");
const verifier = @import("release_adapter_live_timing_verifier");
const context_mod = @import("release_adapter_context");
const cli_authority = @import("release_adapter_github_cli_authority");
const artifact = @import("release_adapter_live_timing_artifact");

const source = "0123456789abcdef0123456789abcdef01234567";
const record =
    "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"repository\":\"ohah/maru\",\"workflow\":\"release.yml\",\"run_id\":333,\"run_attempt\":2,\"source_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"job_name\":\"universal dmg (signed + notarized)\",\"step_name\":\"Run session host live release workflow\",\"started_at\":\"2026-09-09T00:00:00Z\",\"completed_at\":\"2026-09-09T00:00:01Z\",\"duration_ms\":1000}\n";

test "closed verifier command accepts only pinned CLI digest and absent absolute workspace" {
    const parsed = try verifier.parse(&.{ "verify", "/opt/hostedtoolcache/gh", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "/private/tmp/maru-live-timing-verifier" });
    try std.testing.expectEqualStrings("/opt/hostedtoolcache/gh", parsed.cli_path);
    try std.testing.expectError(error.InvalidArguments, verifier.parse(&.{"verify"}));
    try std.testing.expectError(error.InvalidCommand, verifier.parse(&.{ "fetch", "/a", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "/private/tmp/x" }));
    try std.testing.expectError(error.InvalidPath, verifier.parse(&.{ "verify", "gh", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "/private/tmp/x" }));
    try std.testing.expectError(error.InvalidSha256, verifier.parse(&.{ "verify", "/gh", "ABC", "/private/tmp/x" }));
}

test "product verifier derives current identity and consumes an actual pinned child transport" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const archive = try makeStoredArchive(std.testing.allocator, record);
    defer std.testing.allocator.free(archive);
    const metadata = try makeMetadata(std.testing.allocator, archive);
    defer std.testing.allocator.free(metadata);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fixture.zip", .data = archive });
    var archive_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const archive_path = try temporaryPath(&tmp, "fixture.zip", &archive_path_storage);
    const script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\n[ \"$GH_TOKEN\" = token ] || exit 71\n[ \"$GH_PROMPT_DISABLED\" = 1 ] || exit 72\ncase \"$*\" in\n  *\"runs/333/artifacts?per_page=100&name=session-host-release-live-timing-2\"*) /usr/bin/printf '%s' '{s}' ;;\n  *\"actions/artifacts/987/zip\"*) /bin/cat '{s}' ;;\n  *) exit 74 ;;\nesac\n", .{ metadata, archive_path });
    defer std.testing.allocator.free(script);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake-gh", .data = script });
    var cli_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const cli_path = try temporaryPath(&tmp, "fake-gh", &cli_path_storage);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(cli_path.ptr, 0o700));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var workspace_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const workspace = try temporaryPath(&tmp, "verifier-workspace", &workspace_storage);
    var metadata_buffer: [artifact.response_cap]u8 = undefined;
    try verifier.verify(std.testing.io, std.testing.allocator, context(), runner(), .{ .cli_path = cli_path, .cli_sha256 = &hex, .workspace_path = workspace }, "token", &metadata_buffer, 10 * std.time.ns_per_s);
    try std.testing.expect(!try pathExists(workspace));
}

test "context and runner mismatch fail before CLI or workspace access" {
    var metadata_buffer: [artifact.response_cap]u8 = undefined;
    var bad_context = context();
    bad_context.protected_tag = false;
    const command: verifier.Command = .{ .cli_path = "/does/not/exist", .cli_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", .workspace_path = "/private/tmp/unused-live-verifier" };
    try std.testing.expectError(error.UnprotectedRef, verifier.verify(std.testing.io, std.testing.allocator, bad_context, runner(), command, "token", &metadata_buffer, std.time.ns_per_s));
    var foreign = runner();
    foreign.workflow_sha[0] = 'f';
    try std.testing.expectError(error.ContextMismatch, verifier.verify(std.testing.io, std.testing.allocator, context(), foreign, command, "token", &metadata_buffer, std.time.ns_per_s));
}

test "verifier source owns no output or mutable GitHub operation" {
    const source_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_live_timing_verifier.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source_text);
    inline for (.{ "stdout", "stderr", "GITHUB_OUTPUT", "gh release", "gh run", "upload", "delete" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, source_text, forbidden) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source_text, "transport.fetchUntil("));
}

test "product CLI reads one token after trusted context and runner and wipes its bounded copy" {
    const source_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tools/session-host/release_live_timing_verifier_cli.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source_text);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source_text, "std.c.getenv(\"GH_TOKEN\")"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source_text, "@memset(&token_storage, 0)"));
    inline for (.{ "stdout", "stderr", "GITHUB_OUTPUT", "setenv", "putenv", "GH_PROMPT_DISABLED" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, source_text, forbidden) == null);
    const context_at = std.mem.indexOf(u8, source_text, "environment.readCurrent()") orelse return error.MissingContextRead;
    const runner_at = std.mem.indexOf(u8, source_text, "cli_authority.readCurrentRunner") orelse return error.MissingRunnerRead;
    const token_at = std.mem.indexOf(u8, source_text, "std.c.getenv(\"GH_TOKEN\")") orelse return error.MissingTokenRead;
    const verify_at = std.mem.indexOf(u8, source_text, "verifier.verify(") orelse return error.MissingVerifierCall;
    try std.testing.expect(context_at < runner_at and runner_at < token_at and token_at < verify_at);
}

fn context() context_mod.Context {
    return .{
        .repository = .{ .id = 1257870483, .owner = "ohah", .name = "maru" },
        .tag = "v1.2.3",
        .source_commit = source,
        .build = .{ .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3", .run_id = 333, .run_attempt = 2 },
        .protected_tag = true,
    };
}

fn runner() cli_authority.RunnerAuthority {
    return .{ .workflow_sha = source.* };
}

fn makeMetadata(allocator: std.mem.Allocator, archive: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{{\"total_count\":1,\"artifacts\":[{{\"id\":987,\"name\":\"session-host-release-live-timing-2\",\"size_in_bytes\":{d},\"url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/987\",\"archive_download_url\":\"https://api.github.com/repos/ohah/maru/actions/artifacts/987/zip\",\"expired\":false,\"digest\":\"sha256:{s}\",\"workflow_run\":{{\"id\":333,\"repository_id\":1257870483,\"head_repository_id\":1257870483,\"head_sha\":\"{s}\"}}}}]}}", .{ archive.len, &hex, source });
}

fn makeStoredArchive(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const name = "session-host-release-live-timing.json";
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
