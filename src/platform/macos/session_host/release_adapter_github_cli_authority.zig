//! Official GitHub Release CI가 checkout 전에 고정한 `gh` executable authority.
//!
//! PATH나 repository 파일을 신뢰하지 않는다. 파일은 no-follow fd에서 읽은 identity와 digest로
//! 고정하고 실제 transport 호출 직전에 같은 pathname을 다시 관측한다.

const std = @import("std");
const files = @import("release_adapter_files");

pub const max_executable_bytes: usize = 128 * 1024 * 1024;
pub const max_runner_value_bytes: usize = 4 * 1024;
pub const required_runner_names = [_][:0]const u8{
    "GITHUB_WORKFLOW_SHA",
    "RUNNER_ENVIRONMENT",
    "RUNNER_OS",
    "RUNNER_ARCH",
};

pub const RunnerInput = struct {
    workflow_sha: []const u8,
    runner_environment: []const u8,
    runner_os: []const u8,
    runner_arch: []const u8,
};

pub const RunnerAuthority = struct {
    workflow_sha: [40]u8,
};

pub const PinnedExecutable = struct {
    path_sha256: [32]u8,
    path_len: usize,
    identity: files.Identity,
    size: u64,
    mode: u32,
    sha256: [64]u8,
};

pub const Error = files.Error || error{
    InvalidSha,
    InvalidSha256,
    ForeignWorkflow,
    UntrustedRunner,
    DigestMismatch,
    NotExecutable,
    ExecutableChanged,
    MissingKey,
    EmptyValue,
    ValueTooLong,
    InvalidScalar,
};

/// Reads only GitHub's closed runner vocabulary; workflow shell code does not rename these facts.
pub fn readRunner(lookup: anytype, expected_source_sha: []const u8) Error!RunnerAuthority {
    var values: [required_runner_names.len][]const u8 = undefined;
    inline for (required_runner_names, 0..) |name, index| {
        const value = lookup.get(name) orelse return error.MissingKey;
        if (value.len == 0) return error.EmptyValue;
        if (value.len > max_runner_value_bytes) return error.ValueTooLong;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidScalar;
        values[index] = value;
    }
    return validateRunner(.{
        .workflow_sha = values[0],
        .runner_environment = values[1],
        .runner_os = values[2],
        .runner_arch = values[3],
    }, expected_source_sha);
}

pub fn readCurrentRunner(expected_source_sha: []const u8) Error!RunnerAuthority {
    var environment = CurrentEnvironment{};
    return readRunner(&environment, expected_source_sha);
}

const CurrentEnvironment = struct {
    fn get(_: *@This(), name: [:0]const u8) ?[]const u8 {
        const raw = std.c.getenv(name) orelse return null;
        return std.mem.span(raw);
    }
};

pub fn validateRunner(input: RunnerInput, expected_source_sha: []const u8) Error!RunnerAuthority {
    if (!validLowerHex(input.workflow_sha, 40) or !validLowerHex(expected_source_sha, 40))
        return error.InvalidSha;
    if (!std.mem.eql(u8, input.workflow_sha, expected_source_sha)) return error.ForeignWorkflow;
    if (!std.mem.eql(u8, input.runner_environment, "github-hosted") or
        !std.mem.eql(u8, input.runner_os, "macOS") or
        !std.mem.eql(u8, input.runner_arch, "ARM64")) return error.UntrustedRunner;
    var result: RunnerAuthority = undefined;
    @memcpy(&result.workflow_sha, input.workflow_sha);
    return result;
}

pub fn pin(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    expected_sha256: []const u8,
) Error!PinnedExecutable {
    if (!validLowerHex(expected_sha256, 64)) return error.InvalidSha256;
    var input = try files.readInputAlloc(allocator, path, max_executable_bytes);
    defer input.deinit(allocator);
    if (input.mode & 0o111 == 0) return error.NotExecutable;
    if (!std.mem.eql(u8, &input.sha256, expected_sha256)) return error.DigestMismatch;
    var path_sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &path_sha256, .{});
    return .{
        .path_sha256 = path_sha256,
        .path_len = path.len,
        .identity = input.identity,
        .size = input.size,
        .mode = input.mode,
        .sha256 = input.sha256,
    };
}

pub fn revalidate(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    pinned: *const PinnedExecutable,
) Error!void {
    var path_sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &path_sha256, .{});
    if (path.len != pinned.path_len or !std.mem.eql(u8, &path_sha256, &pinned.path_sha256))
        return error.ExecutableChanged;
    var current = try files.readInputAlloc(allocator, path, max_executable_bytes);
    defer current.deinit(allocator);
    if (current.mode & 0o111 == 0) return error.NotExecutable;
    if (current.identity.device != pinned.identity.device or
        current.identity.inode != pinned.identity.inode or
        current.size != pinned.size or current.mode != pinned.mode or
        !std.mem.eql(u8, &current.sha256, &pinned.sha256)) return error.ExecutableChanged;
}

fn validLowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
