//! Published predecessor manifest를 strict parse 전에 bounded bytes로만 획득하는 bootstrap 경계.

const std = @import("std");
const manifest = @import("release_manifest");
const identity = @import("release_adapter_identity");
const process = @import("bounded_process");
const download_command = @import("release_adapter_github_download_command");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");

const max_args = 9;
const max_token_bytes = manifest.max_scalar_string_bytes;

pub const Error = error{
    InvalidExpected,
    InvalidExecutable,
    InvalidToken,
    InvalidBudget,
    InvalidOutput,
    InvalidCapture,
    InvalidOwner,
    EmptyManifest,
    DigestMismatch,
} || process.Error;

pub const Expected = struct {
    tag: []const u8,
    sha256: []const u8,
};

pub const PlanStorage = struct {
    name: [manifest.max_asset_name_bytes]u8 = undefined,
    command: download_command.PlanStorage = undefined,
};

pub const Plan = struct {
    name: []const u8,
    args: []const []const u8,
};

pub const Observed = struct {
    name: []const u8,
    sha256: []const u8,
    bytes: []const u8,
};

pub const Cli = struct {
    path: [:0]const u8,
    pinned: *const cli_authority.PinnedExecutable,
};

const RealAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};

pub fn plan(storage: *PlanStorage, expected: Expected) Error!Plan {
    const storage_bytes = std.mem.asBytes(storage);
    if (rangesOverlap(storage_bytes, expected.tag) or rangesOverlap(storage_bytes, expected.sha256))
        return error.InvalidOwner;
    try validateExpected(expected);
    const name = std.fmt.bufPrint(&storage.name, "Maru-{s}-session-host-release.json", .{expected.tag[1..]}) catch
        return error.InvalidExpected;
    const command = download_command.plan(&storage.command, expected.tag, name) catch return error.InvalidExpected;
    return .{ .name = name, .args = command.args };
}

pub fn fetchWith(
    executor: anytype,
    storage: *PlanStorage,
    executable: []const u8,
    token: []const u8,
    expected: Expected,
    output: []u8,
    budget_ns: i128,
) Error!Observed {
    try validateInputs(storage, executable, token, expected, output);
    if (budget_ns <= 0) return error.InvalidBudget;
    const request = try plan(storage, expected);
    var token_storage: ["GH_TOKEN=".len + max_token_bytes]u8 = undefined;
    const token_entry = std.fmt.bufPrint(&token_storage, "GH_TOKEN={s}", .{token}) catch return error.InvalidToken;
    const environment = [_][]const u8{ token_entry, "GH_PROMPT_DISABLED=1" };
    const captured = executor.capture(executable, request.args, &environment, output, budget_ns) catch |narrow_err| switch (@as(anyerror, narrow_err)) {
        error.InvalidExecutable => return error.InvalidExecutable,
        error.InvalidBudget => return error.InvalidBudget,
        error.PipeFailed => return error.PipeFailed,
        error.SpawnSetupFailed => return error.SpawnSetupFailed,
        error.SpawnFailed => return error.SpawnFailed,
        error.ProcessGroupFailed => return error.ProcessGroupFailed,
        error.CaptureFailed => return error.CaptureFailed,
        error.OutputTooLarge => return error.OutputTooLarge,
        error.TimedOut => return error.TimedOut,
        error.WaitFailed => return error.WaitFailed,
        error.ChildFailed => return error.ChildFailed,
        else => return error.CaptureFailed,
    };
    if (captured.ptr != output.ptr or captured.len > output.len) return error.InvalidCapture;
    if (captured.len == 0) return error.EmptyManifest;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(captured, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected.sha256)) return error.DigestMismatch;
    return .{ .name = request.name, .sha256 = expected.sha256, .bytes = captured };
}

pub fn fetchUntil(
    io: std.Io,
    allocator: std.mem.Allocator,
    storage: *PlanStorage,
    cli: Cli,
    token: []const u8,
    expected_value: Expected,
    output: []u8,
    deadline: *deadline_mod.Deadline,
) !Observed {
    const pinned_bytes = std.mem.asBytes(cli.pinned);
    if (rangesOverlap(std.mem.asBytes(deadline), pinned_bytes) or
        rangesOverlap(std.mem.asBytes(storage), pinned_bytes) or
        rangesOverlap(cli.path, pinned_bytes) or rangesOverlap(token, pinned_bytes) or
        rangesOverlap(expected_value.tag, pinned_bytes) or rangesOverlap(expected_value.sha256, pinned_bytes) or
        rangesOverlap(output, pinned_bytes)) return error.InvalidOwner;
    var authority = RealAuthority{ .pinned = cli.pinned };
    var executor = BoundedExecutor{ .io = io };
    return fetchUntilWith(&authority, &executor, deadline, allocator, storage, cli.path, token, expected_value, output);
}

pub fn fetchUntilWith(
    authority: anytype,
    executor: anytype,
    deadline: anytype,
    allocator: std.mem.Allocator,
    storage: *PlanStorage,
    executable: [:0]const u8,
    token: []const u8,
    expected_value: Expected,
    output: []u8,
) !Observed {
    try validateInputs(storage, executable, token, expected_value, output);
    const deadline_bytes = std.mem.asBytes(deadline);
    if (rangesOverlap(deadline_bytes, std.mem.asBytes(storage)) or
        rangesOverlap(deadline_bytes, executable) or rangesOverlap(deadline_bytes, token) or
        rangesOverlap(deadline_bytes, expected_value.tag) or rangesOverlap(deadline_bytes, expected_value.sha256) or
        rangesOverlap(deadline_bytes, output)) return error.InvalidOwner;
    _ = try deadline.remaining();
    try authority.revalidate(allocator, executable);
    const budget = try deadline.remaining();
    const observed = try fetchWith(executor, storage, executable, token, expected_value, output, budget);
    _ = try deadline.remaining();
    return observed;
}

pub fn fetch(
    io: std.Io,
    storage: *PlanStorage,
    executable: []const u8,
    token: []const u8,
    expected: Expected,
    output: []u8,
    budget_ns: i128,
) Error!Observed {
    var executor = BoundedExecutor{ .io = io };
    return fetchWith(&executor, storage, executable, token, expected, output, budget_ns);
}

fn validateExpected(expected: Expected) Error!void {
    if (!identity.canonicalTag(expected.tag) or !identity.lowerHex(expected.sha256, 64))
        return error.InvalidExpected;
}

fn validateInputs(storage: *const PlanStorage, executable: []const u8, token: []const u8, expected_value: Expected, output: []u8) Error!void {
    const storage_bytes = std.mem.asBytes(storage);
    if (rangesOverlap(storage_bytes, executable) or rangesOverlap(storage_bytes, token) or
        rangesOverlap(storage_bytes, expected_value.tag) or rangesOverlap(storage_bytes, expected_value.sha256) or
        rangesOverlap(storage_bytes, output) or rangesOverlap(output, executable) or
        rangesOverlap(output, token) or rangesOverlap(output, expected_value.tag) or
        rangesOverlap(output, expected_value.sha256)) return error.InvalidOwner;
    if (!validAbsoluteExecutable(executable)) return error.InvalidExecutable;
    if (!validScalar(token)) return error.InvalidToken;
    if (output.len == 0 or output.len > manifest.max_manifest_bytes) return error.InvalidOutput;
    try validateExpected(expected_value);
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn validAbsoluteExecutable(value: []const u8) bool {
    return value.len >= 2 and value[0] == '/' and validScalar(value);
}

fn validScalar(value: []const u8) bool {
    if (value.len == 0 or value.len > max_token_bytes) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

const BoundedExecutor = struct {
    io: std.Io,

    fn capture(self: *@This(), executable: []const u8, child_args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) Error![]const u8 {
        var executable_storage: [max_token_bytes + 1]u8 = undefined;
        const executable_z = std.fmt.bufPrintZ(&executable_storage, "{s}", .{executable}) catch return error.InvalidExecutable;
        var args_storage: [max_args][manifest.max_scalar_string_bytes + 1]u8 = undefined;
        var argv: [max_args + 1:null]?[*:0]const u8 = @splat(null);
        argv[0] = executable_z.ptr;
        for (child_args, 0..) |arg, index| argv[index + 1] = (std.fmt.bufPrintZ(&args_storage[index], "{s}", .{arg}) catch return error.InvalidExpected).ptr;
        var environment_storage: [2]["GH_TOKEN=".len + max_token_bytes + 1]u8 = undefined;
        var envp: [2:null]?[*:0]const u8 = @splat(null);
        for (environment, 0..) |entry, index| envp[index] = (std.fmt.bufPrintZ(&environment_storage[index], "{s}", .{entry}) catch return error.InvalidToken).ptr;
        return process.runCaptureEnvironmentStdout(self.io, executable_z, &argv, &envp, output, budget_ns);
    }
};
