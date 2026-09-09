//! Zero-output product composition for auditing one same-run remote pass artifact.

const std = @import("std");
const context_mod = @import("release_adapter_context");
const artifact = @import("release_adapter_remote_release_pass_artifact");
const transport = @import("release_adapter_remote_release_pass_transport");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");

pub const Command = struct { cli_path: []const u8, cli_sha256: []const u8, workspace_path: []const u8 };
pub const max_token_bytes: usize = 16 * 1024;

pub fn parse(args: []const []const u8) !Command {
    if (args.len != 4) return error.InvalidArguments;
    if (!std.mem.eql(u8, args[0], "audit")) return error.InvalidCommand;
    if (!absoluteScalar(args[1]) or !absoluteScalar(args[3])) return error.InvalidPath;
    if (!lowerHex(args[2], 64)) return error.InvalidSha256;
    return .{ .cli_path = args[1], .cli_sha256 = args[2], .workspace_path = args[3] };
}

pub fn audit(io: std.Io, allocator: std.mem.Allocator, trusted: context_mod.Context, runner: cli_authority.RunnerAuthority, command: Command, token: []const u8, metadata_buffer: []u8, budget_ns: i128) !void {
    try context_mod.validateTrusted(trusted);
    if (!std.mem.eql(u8, &runner.workflow_sha, trusted.source_commit)) return error.ContextMismatch;
    if (!absoluteScalar(command.cli_path) or !absoluteScalar(command.workspace_path)) return error.InvalidPath;
    if (!lowerHex(command.cli_sha256, 64)) return error.InvalidSha256;
    var cli_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const cli_path = std.fmt.bufPrintZ(&cli_storage, "{s}", .{command.cli_path}) catch return error.InvalidPath;
    var workspace_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const workspace_path = std.fmt.bufPrintZ(&workspace_storage, "{s}", .{command.workspace_path}) catch return error.InvalidPath;
    const pinned = try cli_authority.pin(allocator, cli_path, command.cli_sha256);
    var deadline: deadline_mod.Deadline = .{};
    try deadline_mod.start(budget_ns, &deadline);
    var provenance: artifact.Provenance = .{};
    transport.fetchUntil(io, allocator, .{ .path = cli_path, .pinned = &pinned }, token, &trusted, workspace_path, metadata_buffer, &deadline, &provenance) catch |err| {
        deadline.deinit() catch {};
        return err;
    };
    const value = provenance.value() orelse {
        deadline.deinit() catch {};
        return error.InvalidProvenance;
    };
    if (value.record.run_id != trusted.build.run_id or value.record.run_attempt != trusted.build.run_attempt or
        !std.mem.eql(u8, value.record.source_sha, trusted.source_commit))
    {
        provenance.deinit(allocator) catch {};
        deadline.deinit() catch {};
        return error.ContextMismatch;
    }
    provenance.deinit(allocator) catch |err| {
        deadline.deinit() catch {};
        return err;
    };
    try deadline.deinit();
}

fn absoluteScalar(value: []const u8) bool {
    if (value.len < 2 or value[0] != '/') return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn lowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
