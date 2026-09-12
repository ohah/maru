//! Closed process boundary for the separately signed Notification Center Accessibility helper.

const std = @import("std");
const builtin = @import("builtin");
const bounded = @import("bounded_process");
const receipt = @import("release_adapter_notification_helper_receipt");

pub const Provisioning = enum { accessibility, aqua };
pub const Clicked = struct {
    observed_at_ns: u64,
    clicked_at_ns: u64,
    receipt_bytes: []const u8,
};
pub const Result = union(enum) {
    clicked: Clicked,
    not_provisioned: Provisioning,
};

pub const Error = receipt.Error || bounded.Error || error{
    InvalidInput,
    InvalidOwner,
    UnexpectedOutput,
    HelperFailed,
};

pub const Storage = struct {
    in_use: bool = false,
    nonce: [96:0]u8 = undefined,
    deadline: [32:0]u8 = undefined,
    argv: [5:null]?[*:0]const u8 = @splat(null),
    environment: [1:null]?[*:0]const u8 = @splat(null),
    stdout: [receipt.max_receipt_bytes]u8 = undefined,
    stderr: [1]u8 = undefined,
};

pub const Plan = struct {
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: [:0]const u8,
    expected: receipt.Expected,
    budget_ns: i128,
    storage: *Storage,
) Error!Result {
    var executor = RealExecutor{ .io = io };
    return runInternal(&executor, allocator, executable, expected, budget_ns, storage);
}

pub fn validateInputs(executable: [:0]const u8, expected: receipt.Expected, budget_ns: i128) !void {
    if (!canonicalAbsolute(executable) or budget_ns <= 0) return error.InvalidInput;
    try receipt.validateExpected(expected);
}

pub fn runWith(
    executor: anytype,
    allocator: std.mem.Allocator,
    executable: [:0]const u8,
    expected: receipt.Expected,
    budget_ns: i128,
    storage: *Storage,
) !Result {
    if (!builtin.is_test) @compileError("runWith is a test-only seam");
    return runInternal(executor, allocator, executable, expected, budget_ns, storage);
}

fn runInternal(
    executor: anytype,
    allocator: std.mem.Allocator,
    executable: [:0]const u8,
    expected: receipt.Expected,
    budget_ns: i128,
    storage: *Storage,
) !Result {
    if (storage.in_use or aliasesStorage(storage, executable, expected.visible_nonce)) return error.InvalidOwner;
    try validateInputs(executable, expected, budget_ns);

    storage.in_use = true;
    defer if (storage.in_use) clear(storage);
    const nonce = std.fmt.bufPrintZ(&storage.nonce, "{s}", .{expected.visible_nonce}) catch return error.InvalidInput;
    const deadline = std.fmt.bufPrintZ(&storage.deadline, "{d}", .{expected.deadline_ns}) catch return error.InvalidInput;
    storage.argv = .{ executable.ptr, "click", nonce.ptr, deadline.ptr, null };
    const observation = try executor.observe(.{
        .executable = executable,
        .argv = &storage.argv,
        .environment = &storage.environment,
    }, &storage.stdout, &storage.stderr, budget_ns);
    if (observation.stderr.len != 0) return error.UnexpectedOutput;
    if (observation.stdout.len > storage.stdout.len) return error.UnexpectedOutput;
    const owned_stdout = storage.stdout[0..observation.stdout.len];
    if (observation.stdout.ptr != owned_stdout.ptr) @memcpy(owned_stdout, observation.stdout);
    return switch (observation.termination) {
        .exited => |code| switch (code) {
            0 => blk: {
                const parsed = try receipt.parse(allocator, owned_stdout, expected);
                clearTransient(storage);
                storage.in_use = false;
                break :blk .{ .clicked = .{
                    .observed_at_ns = parsed.observed_at_ns,
                    .clicked_at_ns = parsed.clicked_at_ns,
                    .receipt_bytes = owned_stdout,
                } };
            },
            70 => if (observation.stdout.len == 0) .{ .not_provisioned = .accessibility } else error.UnexpectedOutput,
            71 => if (observation.stdout.len == 0) .{ .not_provisioned = .aqua } else error.UnexpectedOutput,
            else => error.HelperFailed,
        },
        .signal, .unknown => error.HelperFailed,
    };
}

const RealExecutor = struct {
    io: std.Io,

    fn observe(self: *@This(), plan: Plan, stdout: []u8, stderr: []u8, budget_ns: i128) bounded.Error!bounded.Observation {
        return bounded.runObserveEnvironment(
            self.io,
            plan.executable,
            plan.argv,
            plan.environment,
            stdout,
            stderr,
            budget_ns,
        );
    }
};

fn aliasesStorage(storage: *Storage, executable: []const u8, nonce: []const u8) bool {
    const bytes = std.mem.asBytes(storage);
    return overlaps(bytes, executable) or overlaps(bytes, nonce);
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn canonicalAbsolute(value: []const u8) bool {
    if (value.len < 2 or value.len >= std.fs.max_path_bytes or value[0] != '/' or value[value.len - 1] == '/') return false;
    for (value) |byte| if (byte == 0 or std.ascii.isControl(byte)) return false;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component|
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn clear(storage: *Storage) void {
    clearTransient(storage);
    @memset(&storage.stdout, 0);
    storage.in_use = false;
}

fn clearTransient(storage: *Storage) void {
    @memset(std.mem.asBytes(&storage.nonce), 0);
    @memset(std.mem.asBytes(&storage.deadline), 0);
    @memset(&storage.argv, null);
    @memset(&storage.environment, null);
    @memset(&storage.stderr, 0);
}
