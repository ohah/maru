//! Actual product-process smoke for the R3b2 one-shot runtime preparation boundary.

const std = @import("std");
const c = std.c;
const bounded = @import("bounded_process");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const executable_raw = args.next() orelse return error.MissingExecutable;
    if (args.next() != null or executable_raw.len == 0) return error.InvalidExecutable;
    const executable_path = try std.Io.Dir.cwd().realPathFileAlloc(io, executable_raw, allocator);
    defer allocator.free(executable_path);
    const executable = try allocator.dupeZ(u8, executable_path);
    defer allocator.free(executable);

    var random: [16]u8 = undefined;
    c.arc4random_buf(&random, random.len);
    random[6] = (random[6] & 0x0f) | 0x40;
    random[8] = (random[8] & 0x3f) | 0x80;
    const compact = std.fmt.bytesToHex(random, .lower);
    var uuid_storage: [37:0]u8 = undefined;
    const uuid = try std.fmt.bufPrintZ(
        &uuid_storage,
        "{s}-{s}-{s}-{s}-{s}",
        .{ compact[0..8], compact[8..12], compact[12..16], compact[16..20], compact[20..32] },
    );
    var root_storage: [48:0]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_storage, "/tmp/mn-{s}", .{compact});
    if (c.mkdir(root.ptr, 0o700) != 0) return error.CreateRootFailed;
    var host_proved_gone = false;
    defer if (host_proved_gone) std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var session_storage: [52:0]u8 = undefined;
    const session = try std.fmt.bufPrintZ(&session_storage, "{s}/s", .{root});
    if (c.mkdir(session.ptr, 0o700) != 0) return error.CreateRootFailed;
    var helper_storage: [52:0]u8 = undefined;
    const helper = try std.fmt.bufPrintZ(&helper_storage, "{s}/h", .{root});
    if (c.mkdir(helper.ptr, 0o700) != 0) return error.CreateRootFailed;

    const absolute_deadline = std.Io.Clock.awake.now(io).nanoseconds + 15 * std.time.ns_per_s;
    var deadline_storage: [48:0]u8 = undefined;
    const deadline = try std.fmt.bufPrintZ(&deadline_storage, "{d}", .{absolute_deadline});
    var visible_storage: [80:0]u8 = undefined;
    const visible = try std.fmt.bufPrintZ(&visible_storage, "{s}-gui-zero", .{uuid});
    var environment: [1:null]?[*:0]const u8 = @splat(null);
    var prepare_argv: [9:null]?[*:0]const u8 = .{
        executable.ptr,
        "__notification-release-runtime",
        "prepare",
        root.ptr,
        uuid.ptr,
        visible.ptr,
        "before-zero",
        deadline.ptr,
        null,
    };
    var stdout: [256]u8 = undefined;
    var stderr: [4096]u8 = undefined;
    const prepared = try bounded.runObserveEnvironment(
        io,
        executable,
        &prepare_argv,
        &environment,
        &stdout,
        &stderr,
        15 * std.time.ns_per_s,
    );
    if (prepared.stderr.len != 0 or prepared.termination != .exited or prepared.termination.exited != 0)
        return error.PrepareFailed;
    const Receipt = struct {
        schema: []const u8,
        host_id: []const u8,
        runtime_id: []const u8,
        event_id: u64,
    };
    var receipt = try std.json.parseFromSlice(Receipt, allocator, prepared.stdout, .{});
    defer receipt.deinit();
    if (!std.mem.eql(u8, receipt.value.schema, "maru.session-host-notification-runtime-preparation.v1") or
        receipt.value.host_id.len != 32 or receipt.value.runtime_id.len != 32 or receipt.value.event_id != 1)
        return error.InvalidReceipt;
    const host = try allocator.dupeZ(u8, receipt.value.host_id);
    defer allocator.free(host);
    const runtime = try allocator.dupeZ(u8, receipt.value.runtime_id);
    defer allocator.free(runtime);

    var cleanup_argv: [7:null]?[*:0]const u8 = .{
        executable.ptr,
        "__notification-release-runtime",
        "cleanup",
        root.ptr,
        host.ptr,
        runtime.ptr,
        null,
    };
    var cleanup_stdout: [1]u8 = undefined;
    var cleanup_stderr: [4096]u8 = undefined;
    const cleaned = try bounded.runObserveEnvironment(
        io,
        executable,
        &cleanup_argv,
        &environment,
        &cleanup_stdout,
        &cleanup_stderr,
        10 * std.time.ns_per_s,
    );
    if (cleaned.stdout.len != 0 or cleaned.stderr.len != 0 or cleaned.termination != .exited or cleaned.termination.exited != 0)
        return error.CleanupFailed;
    host_proved_gone = true;
}
