//! Published predecessor manifest를 strict parse 전에 bounded bytes로만 획득하는 bootstrap 경계.

const std = @import("std");
const manifest = @import("release_manifest");
const identity = @import("release_adapter_identity");
const process = @import("bounded_process");
const download_command = @import("release_adapter_github_download_command");

const max_args = 9;
const max_token_bytes = manifest.max_scalar_string_bytes;

pub const Error = error{
    InvalidExpected,
    InvalidExecutable,
    InvalidToken,
    InvalidBudget,
    InvalidOutput,
    InvalidCapture,
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

pub fn plan(storage: *PlanStorage, expected: Expected) Error!Plan {
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
    if (!validAbsoluteExecutable(executable)) return error.InvalidExecutable;
    if (!validScalar(token)) return error.InvalidToken;
    if (budget_ns <= 0) return error.InvalidBudget;
    if (output.len == 0 or output.len > manifest.max_manifest_bytes) return error.InvalidOutput;
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
