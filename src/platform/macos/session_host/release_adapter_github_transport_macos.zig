//! macOS execution leaf for the closed GitHub REST request plans.
//!
//! The product entry point delegates process lifetime to `bounded_process`; `fetchWith` keeps the
//! request/environment join injectable so tests do not need network access or a real credential.

const std = @import("std");
const process = @import("bounded_process");
const transport = @import("release_adapter_github_transport");

pub const Error = transport.Error || process.Error;
pub const Request = transport.Request;

pub fn fetch(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: [:0]const u8,
    token: []const u8,
    request: transport.Request,
    output: []u8,
    budget_ns: i128,
) Error![]const u8 {
    var executor = BoundedExecutor{ .io = io };
    return fetchWith(&executor, allocator, executable, token, request, output, budget_ns);
}

pub fn fetchWith(
    executor: anytype,
    allocator: std.mem.Allocator,
    executable: []const u8,
    token: []const u8,
    request: transport.Request,
    output: []u8,
    budget_ns: i128,
) ![]const u8 {
    try transport.validateToken(token);
    if (budget_ns <= 0) return error.InvalidBudget;
    if (output.len == 0) return error.InvalidResponse;

    var endpoint_storage: transport.EndpointStorage = undefined;
    const request_plan = try transport.plan(&endpoint_storage, request);
    var args_storage: transport.ArgsStorage = undefined;
    const child_args = transport.args(&args_storage, request_plan);

    var token_storage: ["GH_TOKEN=".len + transport.max_token_bytes]u8 = undefined;
    const token_entry = std.fmt.bufPrint(&token_storage, "GH_TOKEN={s}", .{token}) catch
        return error.InvalidToken;
    const environment = [_][]const u8{ token_entry, "GH_PROMPT_DISABLED=1" };

    var capture: [transport.max_capture_bytes]u8 = undefined;
    const captured = try executor.capture(
        executable,
        child_args,
        &environment,
        &capture,
        budget_ns,
    );
    if (!borrowedFrom(captured, &capture)) return error.InvalidCapture;
    return transport.normalizeOutput(allocator, request_plan, captured, output);
}

fn borrowedFrom(captured: []const u8, supplied: []const u8) bool {
    const supplied_start = @intFromPtr(supplied.ptr);
    const supplied_end = std.math.add(usize, supplied_start, supplied.len) catch return false;
    const captured_start = @intFromPtr(captured.ptr);
    const captured_end = std.math.add(usize, captured_start, captured.len) catch return false;
    return captured_start >= supplied_start and captured_end <= supplied_end;
}

pub const BoundedExecutor = struct {
    io: std.Io,

    pub fn capture(
        self: *@This(),
        executable: []const u8,
        child_args: []const []const u8,
        environment: []const []const u8,
        output: []u8,
        budget_ns: i128,
    ) Error![]const u8 {
        var executable_storage: [transport.max_token_bytes + 1]u8 = undefined;
        const executable_z = std.fmt.bufPrintZ(&executable_storage, "{s}", .{executable}) catch
            return error.InvalidExecutable;

        var arg_bytes: [transport.max_args][transport.endpoint_storage_bytes]u8 = undefined;
        var argv: [transport.max_args + 1:null]?[*:0]const u8 = @splat(null);
        argv[0] = executable_z.ptr;
        for (child_args, 0..) |arg, index| {
            const value = std.fmt.bufPrintZ(&arg_bytes[index], "{s}", .{arg}) catch
                return error.InvalidBudget;
            argv[index + 1] = value.ptr;
        }

        var environment_bytes: [2]["GH_TOKEN=".len + transport.max_token_bytes + 1]u8 = undefined;
        var envp: [2:null]?[*:0]const u8 = @splat(null);
        for (environment, 0..) |entry, index| {
            const value = std.fmt.bufPrintZ(&environment_bytes[index], "{s}", .{entry}) catch
                return error.InvalidBudget;
            envp[index] = value.ptr;
        }
        return process.runCaptureEnvironmentStdout(
            self.io,
            executable_z,
            &argv,
            &envp,
            output,
            budget_ns,
        );
    }
};
