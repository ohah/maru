//! 원격 runtime close의 final-address 권위와 callback 구간 pin을 소유한다.
//!
//! backend map은 이 값을 옮기거나 재발급하지 않는다. 불변 요청 identity와 mutable lifecycle을 서로 다른
//! process-keyed seal로 봉인해야 정상 전이를 허용하면서도 callback 전 권위를 잃지 않는다.

const std = @import("std");
const builtin = @import("builtin");
pub const contract = @import("remote_close_contract.zig");
pub const pending_owner = @import("pending_event_owner.zig");
const process_seal = @import("process_seal_service.zig");

pub const CloseRequestKind = enum(u8) {
    close_and_detach = 1,
    close_without_routing = 2,
    finish_after_termination = 3,
};

pub const CloseDisposition = enum(u8) {
    detach_preserve_host = 1,
    terminate_host = 2,
};

pub const Lifecycle = enum(u8) {
    pristine = 0,
    open = 1,
    routing_tombstoned = 2,
    settling = 3,
    ready_remove = 4,
    consumed = 5,
};

pub const PrepareParams = struct {
    runtime_addr: u64,
    handle: u64,
    runtime_generation: u64,
    host_id: u128,
    close_request_generation: u64,
    close_schedule_ticket: u64,
    request_kind: CloseRequestKind,
    disposition: CloseDisposition,
};

pub const CloseAuthority = struct {
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    runtime_addr: u64 = 0,
    handle: u64 = 0,
    runtime_generation: u64 = 0,
    host_id: u128 = 0,
    close_request_generation: u64 = 0,
    close_schedule_ticket: u64 = 0,
    request_kind_raw: u8 = 0,
    disposition_raw: u8 = 0,
    lifecycle_raw: u8 = 0,
    state_generation: u64 = 0,
    identity_seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
    state_seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

pub const CloseOperationOwner = struct {
    operation_generation: u64 = 0,
    active: bool = false,
    target_handle: u64 = 0,
    target_runtime_generation: u64 = 0,
    target_close_request_generation: u64 = 0,
};

pub const PinLifecycle = enum(u8) { pristine, active, consumed, aborted };

pub const CloseOperationPin = struct {
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    backend_addr: u64 = 0,
    operation_generation: u64 = 0,
    handle: u64 = 0,
    runtime_addr: u64 = 0,
    runtime_generation: u64 = 0,
    close_request_generation: u64 = 0,
    close_schedule_ticket: u64 = 0,
    expected_state_generation: u64 = 0,
    expected_lifecycle_raw: u8 = 0,
    lifecycle_raw: u8 = 0,
    authority_identity_seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

pub const Error = error{ InvalidOwner, InvalidRequest, Busy, Exhausted } || process_seal.ReadyError;

pub fn validRequestPair(kind: CloseRequestKind, disposition: CloseDisposition) bool {
    return switch (kind) {
        .close_and_detach => disposition == .terminate_host,
        .close_without_routing => true,
        .finish_after_termination => disposition == .terminate_host,
    };
}

pub fn prepare(out: *CloseAuthority, ready: process_seal.ReadyIdentity, params: PrepareParams) Error!void {
    if (!std.meta.eql(out.*, CloseAuthority{})) return error.InvalidOwner;
    if (params.runtime_addr == 0 or params.handle == 0 or params.runtime_generation == 0 or
        params.close_request_generation == 0 or !contract.validCloseScheduleTicket(params.close_schedule_ticket) or
        !validRequestPair(params.request_kind, params.disposition)) return error.InvalidRequest;
    const thread_id: u64 = @intCast(std.Thread.getCurrentId());
    if (thread_id == 0) return error.InvalidOwner;
    out.* = .{
        .pid = ready.pid,
        .process_nonce = ready.process_nonce,
        .thread_id = thread_id,
        .runtime_addr = params.runtime_addr,
        .handle = params.handle,
        .runtime_generation = params.runtime_generation,
        .host_id = params.host_id,
        .close_request_generation = params.close_request_generation,
        .close_schedule_ticket = params.close_schedule_ticket,
        .request_kind_raw = @intFromEnum(params.request_kind),
        .disposition_raw = @intFromEnum(params.disposition),
        .lifecycle_raw = @intFromEnum(Lifecycle.open),
        .state_generation = 1,
    };
    out.identity_seal = try identitySeal(out);
    out.state_seal = try stateSeal(out);
    if (!valid(out)) return error.InvalidOwner;
}

pub fn prepareCurrent(out: *CloseAuthority, params: PrepareParams) Error!void {
    return prepare(out, try process_seal.currentReadyIdentity(), params);
}

pub fn valid(authority: *const CloseAuthority) bool {
    if (@intFromPtr(authority) == 0 or authority.pid == 0 or authority.process_nonce == 0 or
        authority.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or authority.state_generation == 0) return false;
    const lifecycle: Lifecycle = switch (authority.lifecycle_raw) {
        0...5 => @enumFromInt(authority.lifecycle_raw),
        else => return false,
    };
    if (lifecycle == .pristine or !contract.validCloseScheduleTicket(authority.close_schedule_ticket)) return false;
    const kind: CloseRequestKind = switch (authority.request_kind_raw) {
        1...3 => @enumFromInt(authority.request_kind_raw),
        else => return false,
    };
    const disposition: CloseDisposition = switch (authority.disposition_raw) {
        1...2 => @enumFromInt(authority.disposition_raw),
        else => return false,
    };
    if (!validRequestPair(kind, disposition)) return false;
    const identity = identitySeal(authority) catch return false;
    const state = stateSeal(authority) catch return false;
    return std.crypto.timing_safe.eql(process_seal.CleanupSeal, identity, authority.identity_seal) and
        std.crypto.timing_safe.eql(process_seal.CleanupSeal, state, authority.state_seal);
}

pub fn advance(authority: *CloseAuthority, expected: Lifecycle, next: Lifecycle) Error!void {
    if (!valid(authority) or authority.lifecycle_raw != @intFromEnum(expected) or !validTransition(expected, next))
        return error.InvalidOwner;
    authority.lifecycle_raw = @intFromEnum(next);
    authority.state_generation = std.math.add(u64, authority.state_generation, 1) catch return error.Exhausted;
    authority.state_seal = try stateSeal(authority);
}

pub fn publishReadyRemove(authority: *CloseAuthority, readiness_complete: bool) Error!bool {
    if (!readiness_complete) return false;
    try advance(authority, .settling, .ready_remove);
    return true;
}

pub fn acquirePin(
    owner: *CloseOperationOwner,
    out: *CloseOperationPin,
    backend_addr: u64,
    authority: *const CloseAuthority,
) Error!void {
    if (owner.active) return error.Busy;
    if (!std.meta.eql(out.*, CloseOperationPin{}) or backend_addr == 0 or !valid(authority)) return error.InvalidOwner;
    owner.operation_generation = std.math.add(u64, owner.operation_generation, 1) catch return error.Exhausted;
    owner.active = true;
    owner.target_handle = authority.handle;
    owner.target_runtime_generation = authority.runtime_generation;
    owner.target_close_request_generation = authority.close_request_generation;
    out.* = .{
        .pid = authority.pid,
        .process_nonce = authority.process_nonce,
        .thread_id = authority.thread_id,
        .backend_addr = backend_addr,
        .operation_generation = owner.operation_generation,
        .handle = authority.handle,
        .runtime_addr = authority.runtime_addr,
        .runtime_generation = authority.runtime_generation,
        .close_request_generation = authority.close_request_generation,
        .close_schedule_ticket = authority.close_schedule_ticket,
        .expected_state_generation = authority.state_generation,
        .expected_lifecycle_raw = authority.lifecycle_raw,
        .lifecycle_raw = @intFromEnum(PinLifecycle.active),
        .authority_identity_seal = authority.identity_seal,
    };
    out.seal = try pinSeal(out);
    if (!validPin(owner, out, authority)) return error.InvalidOwner;
}

pub fn validPin(owner: *const CloseOperationOwner, pin: *const CloseOperationPin, authority: *const CloseAuthority) bool {
    if (!owner.active or !valid(authority) or pin.lifecycle_raw != @intFromEnum(PinLifecycle.active) or
        pin.operation_generation != owner.operation_generation or pin.handle != owner.target_handle or
        pin.runtime_generation != owner.target_runtime_generation or
        pin.close_request_generation != owner.target_close_request_generation or
        !pinStateMatches(pin, authority) or
        !std.crypto.timing_safe.eql(process_seal.CleanupSeal, pin.authority_identity_seal, authority.identity_seal)) return false;
    const expected = pinSeal(pin) catch return false;
    return std.crypto.timing_safe.eql(process_seal.CleanupSeal, expected, pin.seal);
}

pub fn consumePin(owner: *CloseOperationOwner, pin: *CloseOperationPin, authority: *const CloseAuthority) Error!void {
    if (!validPin(owner, pin, authority)) return error.InvalidOwner;
    pin.lifecycle_raw = @intFromEnum(PinLifecycle.consumed);
    pin.seal = [_]u8{0} ** 32;
    owner.active = false;
    owner.target_handle = 0;
    owner.target_runtime_generation = 0;
    owner.target_close_request_generation = 0;
}

fn validTransition(expected: Lifecycle, next: Lifecycle) bool {
    return switch (expected) {
        .open => next == .routing_tombstoned,
        .routing_tombstoned => next == .settling,
        .settling => next == .ready_remove,
        .ready_remove => next == .consumed,
        else => false,
    };
}

fn pinStateMatches(pin: *const CloseOperationPin, authority: *const CloseAuthority) bool {
    if (authority.state_generation < pin.expected_state_generation or
        authority.lifecycle_raw < pin.expected_lifecycle_raw) return false;
    const state_delta = authority.state_generation - pin.expected_state_generation;
    const lifecycle_delta = authority.lifecycle_raw - pin.expected_lifecycle_raw;
    if (state_delta != lifecycle_delta) return false;
    var raw = pin.expected_lifecycle_raw;
    while (raw < authority.lifecycle_raw) : (raw += 1) {
        const expected: Lifecycle = switch (raw) {
            0...5 => @enumFromInt(raw),
            else => return false,
        };
        const next: Lifecycle = switch (raw + 1) {
            0...5 => @enumFromInt(raw + 1),
            else => return false,
        };
        if (!validTransition(expected, next)) return false;
    }
    return true;
}

fn identitySeal(authority: *const CloseAuthority) process_seal.ReadyError!process_seal.CleanupSeal {
    return process_seal.closeAuthorityIdentitySeal(authority.pid, authority.process_nonce, .{
        .self_addr = @intFromPtr(authority),
        .thread_id = authority.thread_id,
        .runtime_addr = authority.runtime_addr,
        .handle = authority.handle,
        .runtime_generation = authority.runtime_generation,
        .host_id = authority.host_id,
        .close_request_generation = authority.close_request_generation,
        .close_schedule_ticket = authority.close_schedule_ticket,
        .request_kind_raw = authority.request_kind_raw,
        .disposition_raw = authority.disposition_raw,
    });
}

fn stateSeal(authority: *const CloseAuthority) process_seal.ReadyError!process_seal.CleanupSeal {
    return process_seal.closeAuthorityStateSeal(authority.pid, authority.process_nonce, .{
        .self_addr = @intFromPtr(authority),
        .state_generation = authority.state_generation,
        .lifecycle_raw = authority.lifecycle_raw,
        .identity_seal = authority.identity_seal,
    });
}

fn pinSeal(pin: *const CloseOperationPin) process_seal.ReadyError!process_seal.CleanupSeal {
    return process_seal.closeOperationPinSeal(pin.pid, pin.process_nonce, .{
        .self_addr = @intFromPtr(pin),
        .backend_addr = pin.backend_addr,
        .thread_id = pin.thread_id,
        .operation_generation = pin.operation_generation,
        .handle = pin.handle,
        .runtime_addr = pin.runtime_addr,
        .runtime_generation = pin.runtime_generation,
        .close_request_generation = pin.close_request_generation,
        .close_schedule_ticket = pin.close_schedule_ticket,
        .expected_state_generation = pin.expected_state_generation,
        .expected_lifecycle_raw = pin.expected_lifecycle_raw,
        .lifecycle_raw = pin.lifecycle_raw,
        .identity_seal = pin.authority_identity_seal,
    });
}

pub const testing = if (builtin.is_test) struct {
    pub fn ensureSealReady() !process_seal.ReadyIdentity {
        return process_seal.currentReadyIdentity() catch |err| switch (err) {
            error.NotReady => blk: {
                const prepared = try process_seal.prepare(process_seal.currentProcessId(), 0x3B35_0001);
                process_seal.commitReady(prepared);
                break :blk try process_seal.currentReadyIdentity();
            },
            else => err,
        };
    }
} else struct {};
