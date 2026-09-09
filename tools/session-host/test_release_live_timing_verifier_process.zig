//! Fresh-process product smoke for the protected-run live timing verifier.

const std = @import("std");
const c = std.c;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

const source = "0123456789abcdef0123456789abcdef01234567";
const record =
    "{\"schema\":\"maru.session-host-release-live-timing.v1\",\"repository\":\"ohah/maru\",\"workflow\":\"release.yml\",\"run_id\":333,\"run_attempt\":2,\"source_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"job_name\":\"universal dmg (signed + notarized)\",\"step_name\":\"Run session host live release workflow\",\"started_at\":\"2026-09-09T00:00:00Z\",\"completed_at\":\"2026-09-09T00:00:01Z\",\"duration_ms\":1000}\n";

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const executable_input = args.next() orelse return error.MissingExecutable;
    if (args.next() != null) return error.TooManyArguments;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(init.io, executable_input, init.gpa);
    defer init.gpa.free(executable);

    var root_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const template = try std.fmt.bufPrintZ(&root_storage, "/private/tmp/maru-live-timing-verifier.XXXXXX", .{});
    const root: [:0]const u8 = std.mem.span(mkdtemp(template.ptr) orelse return error.TempRootFailed);
    defer std.Io.Dir.cwd().deleteTree(init.io, root) catch {};
    if (c.chmod(root.ptr, 0o700) != 0) return error.PrivateRootFailed;
    const archive = try makeStoredArchive(init.gpa, record);
    defer init.gpa.free(archive);
    const metadata = try makeMetadata(init.gpa, archive);
    defer init.gpa.free(metadata);
    var archive_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const archive_path = try childPath(root, "fixture.zip", &archive_path_storage);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = archive_path, .data = archive });
    const script = try std.fmt.allocPrint(init.gpa, "#!/bin/sh\n[ \"$GH_TOKEN\" = token ] || exit 71\n[ \"$GH_PROMPT_DISABLED\" = 1 ] || exit 72\ncase \"$*\" in\n  *\"runs/333/artifacts?per_page=100&name=session-host-release-live-timing-2\"*) /usr/bin/printf '%s' '{s}' ;;\n  *\"actions/artifacts/987/zip\"*) /bin/cat '{s}' ;;\n  *) exit 74 ;;\nesac\n", .{ metadata, archive_path });
    defer init.gpa.free(script);
    var cli_path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const cli_path = try childPath(root, "fake-gh", &cli_path_storage);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = cli_path, .data = script });
    if (c.chmod(cli_path.ptr, 0o700) != 0) return error.ChmodFailed;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var workspace_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const workspace = try childPath(root, "verifier-workspace", &workspace_storage);

    var environment = try trustedEnvironment(init.gpa, true);
    defer environment.deinit();
    try warmProcessRunner(init.io, init.gpa);
    const before_fds = try countOpenFds(init.io);
    var no_token = try trustedEnvironment(init.gpa, false);
    defer no_token.deinit();
    for (0..2) |_| {
        try run(init.io, init.gpa, executable, cli_path, &hex, workspace, &environment, true);
        try expectMissing(init.io, workspace);
        try run(init.io, init.gpa, executable, cli_path, &hex, workspace, &no_token, false);
        try expectMissing(init.io, workspace);
    }
    if (try countOpenFds(init.io) != before_fds) return error.FileDescriptorLeak;
}

fn warmProcessRunner(io: std.Io, allocator: std.mem.Allocator) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{"/usr/bin/true"},
        .stdout_limit = .limited(1),
        .stderr_limit = .limited(1),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ProcessRunnerWarmupFailed,
        else => return error.ProcessRunnerWarmupFailed,
    }
}

fn run(io: std.Io, allocator: std.mem.Allocator, executable: []const u8, cli_path: []const u8, digest: []const u8, workspace: []const u8, environment: *const std.process.Environ.Map, want_success: bool) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ executable, "verify", cli_path, digest, workspace },
        .environ_map = environment,
        .stdout_limit = .limited(1),
        .stderr_limit = .limited(1),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (succeeded != want_success) return error.UnexpectedExit;
    if (result.stdout.len != 0 or result.stderr.len != 0) return error.UnexpectedOutput;
}

fn trustedEnvironment(allocator: std.mem.Allocator, with_token: bool) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    const values = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "GITHUB_REPOSITORY", .value = "ohah/maru" },                                                  .{ .key = "GITHUB_REPOSITORY_ID", .value = "1257870483" },
        .{ .key = "GITHUB_REF", .value = "refs/tags/v1.2.3" },                                                  .{ .key = "GITHUB_REF_TYPE", .value = "tag" },
        .{ .key = "GITHUB_REF_NAME", .value = "v1.2.3" },                                                       .{ .key = "GITHUB_SHA", .value = source },
        .{ .key = "GITHUB_WORKFLOW_REF", .value = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3" }, .{ .key = "GITHUB_RUN_ID", .value = "333" },
        .{ .key = "GITHUB_RUN_ATTEMPT", .value = "2" },                                                         .{ .key = "GITHUB_EVENT_NAME", .value = "push" },
        .{ .key = "GITHUB_REF_PROTECTED", .value = "true" },                                                    .{ .key = "GITHUB_WORKFLOW_SHA", .value = source },
        .{ .key = "RUNNER_ENVIRONMENT", .value = "github-hosted" },                                             .{ .key = "RUNNER_OS", .value = "macOS" },
        .{ .key = "RUNNER_ARCH", .value = "ARM64" },
    };
    for (values) |entry| try map.put(entry.key, entry.value);
    if (with_token) try map.put("GH_TOKEN", "token");
    return map;
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

fn childPath(root: []const u8, leaf: []const u8, storage: []u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(storage, "{s}/{s}", .{ root, leaf });
}

fn expectMissing(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.Residue;
}

fn countOpenFds(io: std.Io) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, "/dev/fd", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

fn put16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

fn put32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
