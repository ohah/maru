//! CR1 reconnect scheduler admission facade.
//!
//! 이 단계는 socket을 열거나 HostAdapter를 교체하지 않는다. process-local admission row를
//! scheduler-owned final-address dispatch로 한 번 claim하고, 같은 inline row의 다음 상태만
//! 게시한다. 실제 reconnect 실행은 CR4가 소유한다.

const std = @import("std");
const owner_mod = @import("reconnect_admission_owner.zig");
const process_seal = @import("process_seal_service.zig");
const poison = @import("client_poison.zig");
const publication = @import("maru").observability.incident_publication_contract;
const incident = @import("maru").observability.connection_incident;

pub const Error = owner_mod.Error;

pub const DispatchDecision = enum {
    schedule,
    retry_later,
    discard_stale,
};

pub const Result = union(enum) {
    idle,
    scheduled: owner_mod.Projection,
    retry_later: owner_mod.Projection,
    discarded_stale: owner_mod.Projection,
};

/// Scheduler cycle의 단일 제품 leaf다. prepared dispatch는 이 stack frame을 벗어나지 않고,
/// row transition이 끝난 뒤 consumed seal로 바뀌므로 callback이나 heap queue 권위를 만들지 않는다.
pub fn runOnce(owner: *owner_mod.Owner, decision: DispatchDecision) Error!Result {
    var dispatch: owner_mod.PreparedReconnectDispatch = .{};
    owner.prepareDispatch(&dispatch) catch |err| switch (err) {
        error.NotFound => return .idle,
        else => return err,
    };
    const value: owner_mod.Projection = .{
        .slot_index = dispatch.slot_index,
        .slot_generation = dispatch.slot_generation,
        .host_id = dispatch.host_id,
        .host_adapter_generation = dispatch.host_adapter_generation,
        .connection_generation = dispatch.connection_generation,
        .incident_id = dispatch.incident_id,
    };
    return switch (decision) {
        .schedule => blk: {
            owner.settleDispatch(&dispatch, .scheduled) catch
                process_seal.fatalIntegrity(.incident_authority);
            break :blk .{ .scheduled = value };
        },
        .retry_later => blk: {
            owner.settleDispatch(&dispatch, .retry_later) catch
                process_seal.fatalIntegrity(.incident_authority);
            break :blk .{ .retry_later = value };
        },
        .discard_stale => blk: {
            owner.settleDispatch(&dispatch, .discarded_stale) catch
                process_seal.fatalIntegrity(.incident_authority);
            break :blk .{ .discarded_stale = value };
        },
    };
}

fn fixtureResult(sequence: u64, wake: publication.WakeOutcome) publication.IncidentCommitResult {
    return .{
        .publication = .{
            .incident_id = .{ .app_instance_nonce = 1, .sequence = sequence },
            .detail_present = true,
            .detail_slot = 0,
            .aggregate_slot = 0,
            .aggregate_generation = 1,
        },
        .wake = wake,
        .kind_raw = @intFromEnum(publication.PublicationKind.first),
    };
}

fn fixtureInput(host_id: u128, generation: u64, reason: incident.ConnectionReason, source: incident.SourceSite) publication.IncidentInput {
    var value: publication.IncidentInput = .{
        .timestamp_ns = generation,
        .host_id = host_id,
        .host_adapter_generation = 3,
        .connection_generation = generation,
        .wire_major = 1,
        .reason_raw = @intFromEnum(reason),
        .scope_raw = @intFromEnum(incident.Scope.connection),
        .disposition_raw = @intFromEnum(incident.Disposition.reconnect),
        .source_site_raw = @intFromEnum(source),
        .host_class_raw = @intFromEnum(incident.HostClass.current),
        .parser_phase_raw = @intFromEnum(incident.ParserPhase.idle),
        .outbound_phase_raw = @intFromEnum(incident.OutboundPhase.idle),
    };
    if (reason == .outbound_partial_write or reason == .outbound_write_ambiguous) {
        value.pending_request_count = 1;
        value.queue_bytes = 8;
        value.outbound_phase_raw = @intFromEnum(incident.OutboundPhase.partial);
        value.outbound_offset = 2;
        value.outbound_length = 10;
    }
    return value;
}

fn initOwner(owner: *owner_mod.Owner) !void {
    try @import("client_slot.zig").ClientSlot.initializeProcessRuntime();
    try owner.initInPlace(@import("client_slot.zig").ClientSlot.publicationProcessIdentity().?.process_nonce);
}

test "CR1 bounded semantic 오류는 reconnect admission을 만들지 않는다" {
    var owner: owner_mod.Owner = .{};
    try initOwner(&owner);
    const generation_rejected = poison.decisionFor(.stream_generation_rejected);
    const controller_busy = poison.decisionFor(.controller_busy);
    try std.testing.expectEqual(poison.Scope.stream, generation_rejected.scope);
    try std.testing.expectEqual(poison.Disposition.retry_status, generation_rejected.disposition);
    try std.testing.expect(generation_rejected.transport_usable);
    try std.testing.expectEqual(poison.Scope.stream, controller_busy.scope);
    try std.testing.expectEqual(poison.Disposition.no_retry, controller_busy.disposition);
    try std.testing.expect(controller_busy.transport_usable);
    try std.testing.expectEqual(@as(u8, 0), owner.count);
    try std.testing.expect((try runOnce(&owner, .schedule)) == .idle);
}

test "CR1 partial read와 write는 sealed dispatch를 exact once schedule한다" {
    var owner: owner_mod.Owner = .{};
    try initOwner(&owner);
    const read_input = fixtureInput(3, 12, .transport_read_failure, .client_read);
    const write_input = fixtureInput(4, 13, .outbound_write_ambiguous, .client_response);
    _ = try publication.serviceInput(read_input);
    _ = try publication.serviceInput(write_input);
    try owner.admit(fixtureResult(2, .queued), read_input);
    try owner.admit(fixtureResult(3, .coalesced), write_input);

    const first = try runOnce(&owner, .schedule);
    const second = try runOnce(&owner, .schedule);
    try std.testing.expect(first == .scheduled);
    try std.testing.expect(second == .scheduled);
    try std.testing.expectEqual(@as(u8, 2), owner.count);
    const first_projection = first.scheduled;
    const second_projection = second.scheduled;
    try std.testing.expect(first_projection.connection_generation != second_projection.connection_generation);
    try owner.consumeScheduled(first_projection);
    try owner.consumeScheduled(second_projection);
    try std.testing.expect((try runOnce(&owner, .schedule)) == .idle);
}

test "CR1 artifact degraded는 disk를 기다리지 않고 dispatch를 schedule한다" {
    var owner: owner_mod.Owner = .{};
    try initOwner(&owner);
    const input = fixtureInput(5, 14, .connection_eof, .client_read);
    _ = try publication.serviceInput(input);
    try owner.admit(fixtureResult(4, .degraded), input);

    const result = try runOnce(&owner, .schedule);
    try std.testing.expect(result == .scheduled);
    try std.testing.expectEqual(@as(u64, 4), result.scheduled.incident_id.sequence);
    try owner.consumeScheduled(result.scheduled);
}

test "CR1 scheduler dispatch는 retry stale copy replay를 closed transition으로 정산한다" {
    var owner: owner_mod.Owner = .{};
    try initOwner(&owner);
    const input = fixtureInput(6, 15, .connection_eof, .client_read);
    _ = try publication.serviceInput(input);
    try owner.admit(fixtureResult(5, .queued), input);

    const retry = try runOnce(&owner, .retry_later);
    try std.testing.expect(retry == .retry_later);
    try std.testing.expectEqualDeep(retry.retry_later, (try owner.peek()).?);

    const before_alias = owner;
    const alias: *owner_mod.PreparedReconnectDispatch = @ptrCast(&owner);
    try std.testing.expectError(error.InvalidOwner, owner.prepareDispatch(alias));
    const partial_alias: *owner_mod.PreparedReconnectDispatch = @ptrFromInt(
        @intFromPtr(&owner) + @offsetOf(owner_mod.Owner, "rows"),
    );
    try std.testing.expectError(error.InvalidOwner, owner.prepareDispatch(partial_alias));
    try std.testing.expectEqualDeep(before_alias, owner);
    const saved_attempt_generation = owner.next_attempt_generation;
    owner.next_attempt_generation = std.math.maxInt(u64);
    var exhausted: owner_mod.PreparedReconnectDispatch = .{};
    try std.testing.expectError(error.AttemptExhausted, owner.prepareDispatch(&exhausted));
    owner.next_attempt_generation = saved_attempt_generation;

    const stale = try runOnce(&owner, .discard_stale);
    try std.testing.expect(stale == .discarded_stale);
    try std.testing.expectEqual(@as(u8, 0), owner.count);
    try std.testing.expect((try runOnce(&owner, .schedule)) == .idle);

    // Scheduler facade가 사용하는 raw claim leaf도 copied address, foreign thread, replay를
    // mutation 전에 거부해야 한다. 이 hostile oracle은 제품 caller를 추가하지 않는다.
    try owner.admit(fixtureResult(6, .queued), fixtureInput(7, 16, .connection_eof, .client_read));
    var dispatch: owner_mod.PreparedReconnectDispatch = .{};
    try owner.prepareDispatch(&dispatch);
    var copied = dispatch;
    try std.testing.expectError(error.InvalidOwner, owner.settleDispatch(&copied, .scheduled));
    const Foreign = struct {
        fn run(owner_ptr: *owner_mod.Owner, dispatch_ptr: *owner_mod.PreparedReconnectDispatch, rejected: *bool) void {
            owner_ptr.settleDispatch(dispatch_ptr, .scheduled) catch |err| {
                rejected.* = err == error.InvalidOwner;
                return;
            };
        }
    };
    var rejected = false;
    const thread = try std.Thread.spawn(.{}, Foreign.run, .{ &owner, &dispatch, &rejected });
    thread.join();
    try std.testing.expect(rejected);
    try owner.settleDispatch(&dispatch, .scheduled);
    try std.testing.expectError(error.InvalidOwner, owner.settleDispatch(&dispatch, .scheduled));
    try owner.consumeScheduled((try owner.peekScheduled()).?);
}
