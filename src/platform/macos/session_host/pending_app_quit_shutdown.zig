//! `.terminateLater` 동안 AppSession과 backend 사이의 공통 종료 deadline과 target 진행 위치를 소유한다.

const std = @import("std");
const process_seal = @import("process_seal_service.zig");

pub const Lifecycle = enum(u8) { pristine, active, complete };

pub const PendingAppQuitShutdown = struct {
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    app_session_addr: u64 = 0,
    backend_addr: u64 = 0,
    started_at_ns: u64 = 0,
    deadline_ns: u64 = 0,
    target_count: u32 = 0,
    target_cursor: u32 = 0,
    lifecycle_raw: u8 = 0,
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

pub const Error = error{ InvalidOwner, InvalidRequest } || process_seal.ReadyError;

pub fn prepare(
    out: *PendingAppQuitShutdown,
    app_session_addr: u64,
    backend_addr: u64,
    started_at_ns: u64,
    deadline_ns: u64,
    target_count: u32,
) Error!void {
    if (!std.meta.eql(out.*, PendingAppQuitShutdown{})) return error.InvalidOwner;
    if (app_session_addr == 0 or backend_addr == 0 or started_at_ns == 0 or
        deadline_ns <= started_at_ns or target_count == 0) return error.InvalidRequest;
    const ready = try process_seal.currentReadyIdentity();
    out.* = .{
        .pid = ready.pid,
        .process_nonce = ready.process_nonce,
        .thread_id = @intCast(std.Thread.getCurrentId()),
        .app_session_addr = app_session_addr,
        .backend_addr = backend_addr,
        .started_at_ns = started_at_ns,
        .deadline_ns = deadline_ns,
        .target_count = target_count,
        .lifecycle_raw = @intFromEnum(Lifecycle.active),
    };
    out.seal = try authoritySeal(out);
}

pub fn valid(owner: *const PendingAppQuitShutdown, app_session_addr: u64, backend_addr: u64) bool {
    if (owner.app_session_addr != app_session_addr or owner.backend_addr != backend_addr or
        owner.pid != process_seal.currentProcessId() or
        owner.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
        owner.started_at_ns == 0 or owner.deadline_ns <= owner.started_at_ns or
        owner.target_count == 0 or owner.target_cursor > owner.target_count) return false;
    const lifecycle: Lifecycle = switch (owner.lifecycle_raw) {
        1...2 => @enumFromInt(owner.lifecycle_raw),
        else => return false,
    };
    if ((lifecycle == .active) != (owner.target_cursor < owner.target_count)) return false;
    const expected = authoritySeal(owner) catch return false;
    return std.crypto.timing_safe.eql(process_seal.CleanupSeal, expected, owner.seal);
}

pub fn advance(owner: *PendingAppQuitShutdown, app_session_addr: u64, backend_addr: u64) Error!bool {
    if (!valid(owner, app_session_addr, backend_addr) or owner.lifecycle_raw != @intFromEnum(Lifecycle.active))
        return error.InvalidOwner;
    owner.target_cursor += 1;
    if (owner.target_cursor == owner.target_count) owner.lifecycle_raw = @intFromEnum(Lifecycle.complete);
    owner.seal = try authoritySeal(owner);
    return owner.lifecycle_raw == @intFromEnum(Lifecycle.complete);
}

pub fn deadlineReached(owner: *const PendingAppQuitShutdown, app_session_addr: u64, backend_addr: u64, now_ns: u64) Error!bool {
    if (!valid(owner, app_session_addr, backend_addr)) return error.InvalidOwner;
    return now_ns >= owner.deadline_ns;
}

fn authoritySeal(owner: *const PendingAppQuitShutdown) process_seal.ReadyError!process_seal.CleanupSeal {
    return process_seal.pendingAppQuitShutdownSeal(owner.pid, owner.process_nonce, .{
        .self_addr = @intFromPtr(owner),
        .app_session_addr = owner.app_session_addr,
        .backend_addr = owner.backend_addr,
        .thread_id = owner.thread_id,
        .started_at_ns = owner.started_at_ns,
        .deadline_ns = owner.deadline_ns,
        .target_count = owner.target_count,
        .target_cursor = owner.target_cursor,
        .lifecycle_raw = owner.lifecycle_raw,
    });
}

fn ensureReady() !void {
    _ = process_seal.currentReadyIdentity() catch |err| switch (err) {
        error.NotReady => {
            const prepared = try process_seal.prepare(process_seal.currentProcessId(), 0x3B36_0002);
            process_seal.commitReady(prepared);
        },
        else => return err,
    };
}

test "C3-3b6 app quit owner는 final address와 공통 deadline을 봉인한다" {
    try ensureReady();
    var owner: PendingAppQuitShutdown = .{};
    try prepare(&owner, 11, 22, 100, 200, 2);
    try std.testing.expect(valid(&owner, 11, 22));
    const copied = owner;
    try std.testing.expect(!valid(&copied, 11, 22));
    try std.testing.expect(!(try deadlineReached(&owner, 11, 22, 199)));
    try std.testing.expect(try deadlineReached(&owner, 11, 22, 200));
}

test "C3-3b6 app quit owner는 tick마다 target 하나를 진행하고 마지막에만 complete다" {
    try ensureReady();
    var owner: PendingAppQuitShutdown = .{};
    try prepare(&owner, 11, 22, 100, 200, 2);
    try std.testing.expect(!(try advance(&owner, 11, 22)));
    try std.testing.expectEqual(@as(u32, 1), owner.target_cursor);
    try std.testing.expect(try advance(&owner, 11, 22));
    try std.testing.expectEqual(@intFromEnum(Lifecycle.complete), owner.lifecycle_raw);
    try std.testing.expectError(error.InvalidOwner, advance(&owner, 11, 22));
}
