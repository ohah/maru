//! Parent side of the R3b2 mounted-candidate runtime preparation boundary.
//!
//! The exact CLI pinned inside the mounted DMG owns the live session-host module graph. This
//! adapter launches its hidden one-shot command and accepts only a canonical identity receipt;
//! it never links a second host graph or discovers an ambient user registry.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const bounded = @import("bounded_process");
const contract = @import("release_adapter_notification_runtime_contract.zig");

pub const child_command = contract.child_command;

pub const Inputs = struct {
    executable: [:0]const u8,
    runner_root: [:0]const u8,
    runner_nonce: []const u8,
    visible_nonce: []const u8,
    before_marker: []const u8,
    deadline_ns: i128,
};

pub const Prepared = struct {
    owner: ?*Prepared = null,
    executable: [std.fs.max_path_bytes:0]u8 = undefined,
    executable_len: usize = 0,
    runner_root: [96:0]u8 = undefined,
    runner_root_len: usize = 0,
    host_id: [32]u8 = [_]u8{0} ** 32,
    runtime_id: [32]u8 = [_]u8{0} ** 32,
    request_identifier: [96]u8 = [_]u8{0} ** 96,
    request_identifier_len: usize = 0,
    trigger_path: [128:0]u8 = undefined,
    trigger_path_len: usize = 0,
    stdout: [256]u8 = undefined,
    stderr: [1]u8 = undefined,
    emitted: bool = false,

    pub fn hostId(self: *const @This()) []const u8 {
        return self.host_id[0..];
    }
    pub fn runtimeId(self: *const @This()) []const u8 {
        return self.runtime_id[0..];
    }
    pub fn requestIdentifier(self: *const @This()) []const u8 {
        return self.request_identifier[0..self.request_identifier_len];
    }
};

pub fn prepare(allocator: std.mem.Allocator, io: std.Io, inputs: Inputs, result: *Prepared) !void {
    if (builtin.os.tag != .macos) return error.Unsupported;
    if (result.owner != null or overlaps(std.mem.asBytes(result), inputs)) return error.InvalidOwner;
    try validate(inputs);
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    if (now >= inputs.deadline_ns) return error.TimedOut;
    result.owner = result;
    errdefer result.* = .{};
    const executable = std.fmt.bufPrintZ(&result.executable, "{s}", .{inputs.executable}) catch return error.InvalidInput;
    result.executable_len = executable.len;
    const root = std.fmt.bufPrintZ(&result.runner_root, "{s}", .{inputs.runner_root}) catch return error.InvalidInput;
    result.runner_root_len = root.len;
    const trigger = std.fmt.bufPrintZ(&result.trigger_path, "{s}/h/emit", .{root}) catch return error.InvalidInput;
    result.trigger_path_len = trigger.len;
    var deadline_storage: [48:0]u8 = undefined;
    const deadline = std.fmt.bufPrintZ(&deadline_storage, "{d}", .{inputs.deadline_ns}) catch return error.InvalidInput;
    var nonce_storage: [48:0]u8 = undefined;
    const nonce = std.fmt.bufPrintZ(&nonce_storage, "{s}", .{inputs.runner_nonce}) catch return error.InvalidInput;
    var visible_storage: [192:0]u8 = undefined;
    const visible = std.fmt.bufPrintZ(&visible_storage, "{s}", .{inputs.visible_nonce}) catch return error.InvalidInput;
    var before_storage: [144:0]u8 = undefined;
    const before = std.fmt.bufPrintZ(&before_storage, "{s}", .{inputs.before_marker}) catch return error.InvalidInput;
    var argv: [9:null]?[*:0]const u8 = .{ executable.ptr, child_command, "prepare", root.ptr, nonce.ptr, visible.ptr, before.ptr, deadline.ptr, null };
    var environment: [1:null]?[*:0]const u8 = @splat(null);
    const observed = try bounded.runObserveEnvironment(io, executable, &argv, &environment, &result.stdout, &result.stderr, inputs.deadline_ns - now);
    if (observed.stderr.len != 0 or observed.termination != .exited or observed.termination.exited != 0) return error.ChildFailed;
    try parseReceipt(allocator, observed.stdout, result);
}

pub fn emit(result: *Prepared) !void {
    if (result.owner != result or result.request_identifier_len == 0 or result.emitted) return error.InvalidOwner;
    const path = result.trigger_path[0..result.trigger_path_len :0];
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.TriggerFailed;
    var clean = c.fsync(fd) == 0;
    if (c.close(fd) != 0) clean = false;
    if (!clean) return error.TriggerFailed;
    result.emitted = true;
}

pub fn cleanup(io: std.Io, result: *Prepared) !void {
    if (result.owner != result) return error.InvalidOwner;
    const executable = result.executable[0..result.executable_len :0];
    const root = result.runner_root[0..result.runner_root_len :0];
    var host_storage: [33:0]u8 = undefined;
    const host = std.fmt.bufPrintZ(&host_storage, "{s}", .{result.host_id}) catch return error.CleanupFailed;
    var runtime_storage: [33:0]u8 = undefined;
    const runtime = std.fmt.bufPrintZ(&runtime_storage, "{s}", .{result.runtime_id}) catch return error.CleanupFailed;
    var argv: [7:null]?[*:0]const u8 = .{ executable.ptr, child_command, "cleanup", root.ptr, host.ptr, runtime.ptr, null };
    var environment: [1:null]?[*:0]const u8 = @splat(null);
    var stdout: [1]u8 = undefined;
    var stderr: [1]u8 = undefined;
    const observed = bounded.runObserveEnvironment(io, executable, &argv, &environment, &stdout, &stderr, 15 * std.time.ns_per_s) catch return error.CleanupFailed;
    if (observed.stderr.len != 0 or observed.stdout.len != 0 or observed.termination != .exited or observed.termination.exited != 0) return error.CleanupFailed;
    if (result.trigger_path_len != 0) {
        const trigger = result.trigger_path[0..result.trigger_path_len :0];
        const rc = c.unlink(trigger.ptr);
        if (rc != 0 and posix.errno(rc) != .NOENT) return error.CleanupFailed;
    }
    result.* = .{};
}

/// The app child returns its cleanup receipt only after the product Quit-and-End-All state machine
/// has reached source-zero and exited successfully. At that point this parent owns no live daemon;
/// it only has to retire the exact trigger pathname before releasing its local identity receipt.
pub fn releaseAfterAppCleanup(result: *Prepared) !void {
    if (result.owner != result) return error.InvalidOwner;
    if (result.trigger_path_len != 0) {
        const trigger = result.trigger_path[0..result.trigger_path_len :0];
        const rc = c.unlink(trigger.ptr);
        if (rc != 0 and posix.errno(rc) != .NOENT) return error.CleanupFailed;
    }
    result.* = .{};
}

pub fn validateForTest(inputs: Inputs) !void {
    if (!builtin.is_test) @compileError("test-only validation seam");
    try validate(inputs);
}

fn parseReceipt(allocator: std.mem.Allocator, bytes: []const u8, result: *Prepared) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidReceipt;
    defer parsed.deinit();
    const object = parsed.value.object;
    if (object.count() != 4 or !stringEquals(object.get("schema"), contract.receipt_schema) or !integerEquals(object.get("event_id"), 1)) return error.InvalidReceipt;
    const host = string(object.get("host_id")) orelse return error.InvalidReceipt;
    const runtime = string(object.get("runtime_id")) orelse return error.InvalidReceipt;
    if (!lowerHex32(host) or !lowerHex32(runtime)) return error.InvalidReceipt;
    @memcpy(&result.host_id, host);
    @memcpy(&result.runtime_id, runtime);
    result.request_identifier_len = (std.fmt.bufPrint(&result.request_identifier, "maru-{s}-{s}-1", .{ host, runtime }) catch return error.InvalidReceipt).len;
    var canonical: [256]u8 = undefined;
    const expected = std.fmt.bufPrint(&canonical, "{{\"schema\":\"{s}\",\"host_id\":\"{s}\",\"runtime_id\":\"{s}\",\"event_id\":1}}\n", .{ contract.receipt_schema, host, runtime }) catch return error.InvalidReceipt;
    if (!std.mem.eql(u8, bytes, expected)) return error.InvalidReceipt;
}

fn validate(inputs: Inputs) !void {
    if (inputs.deadline_ns <= 0 or !canonicalAbsolute(inputs.executable) or !canonicalRunnerRoot(inputs.runner_root, inputs.runner_nonce) or !scalar(inputs.visible_nonce, 160) or !scalar(inputs.before_marker, 128)) return error.InvalidInput;
}
fn canonicalAbsolute(path: []const u8) bool {
    if (path.len < 2 or path.len >= std.fs.max_path_bytes or path[0] != '/' or path[path.len - 1] == '/') return false;
    for (path) |byte| if (byte == 0 or std.ascii.isControl(byte)) return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}
fn canonicalRunnerRoot(path: []const u8, nonce: []const u8) bool {
    if (nonce.len != 36 or path.len != "/tmp/mn-".len + 32 or !std.mem.startsWith(u8, path, "/tmp/mn-")) return false;
    var compact: [32]u8 = undefined;
    var at: usize = 0;
    for (nonce, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else {
            if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f') or at == compact.len) return false;
            compact[at] = byte;
            at += 1;
        }
    }
    return at == compact.len and std.mem.eql(u8, path["/tmp/mn-".len..], &compact);
}
fn scalar(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}
fn lowerHex32(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
fn string(value: ?std.json.Value) ?[]const u8 {
    const item = value orelse return null;
    return if (item == .string) item.string else null;
}
fn stringEquals(value: ?std.json.Value, expected: []const u8) bool {
    return if (string(value)) |actual| std.mem.eql(u8, actual, expected) else false;
}
fn integerEquals(value: ?std.json.Value, expected: i64) bool {
    const item = value orelse return false;
    return item == .integer and item.integer == expected;
}
fn overlaps(destination: []const u8, inputs: Inputs) bool {
    for ([_][]const u8{ inputs.executable, inputs.runner_root, inputs.runner_nonce, inputs.visible_nonce, inputs.before_marker }) |source| {
        if (source.len == 0) continue;
        const destination_end = std.math.add(usize, @intFromPtr(destination.ptr), destination.len) catch return true;
        const source_end = std.math.add(usize, @intFromPtr(source.ptr), source.len) catch return true;
        if (@intFromPtr(destination.ptr) < source_end and @intFromPtr(source.ptr) < destination_end) return true;
    }
    return false;
}
