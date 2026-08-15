//! App-global session-host policy coordinator의 reconnect-only CR2e-e3c1 shell.
//!
//! Incident admission/budget과 backend runtime map의 소유권은 기존 final-address owner에 남긴다.
//! 이 shell은 raw pointer를 저장하지 않고 owner turn마다 canonical backend singleton을 다시
//! 검증한 뒤 sealed admission drain 하나만 조합한다. 실제 socket reconnect와 host job은 CR4/CR5가 확장한다.

const std = @import("std");
const process_seal = @import("process_seal_service.zig");
const admission_mod = @import("reconnect_admission_owner.zig");
const budget_mod = @import("reconnect_resident_budget.zig");
const backend_mod = @import("remote_term_backend.zig");

const Lifecycle = enum(u8) { pristine = 0, ready = 1 };
const ReceiptLifecycle = enum(u8) { pristine = 0, prepared = 1, consumed = 2 };

/// CR4의 verified socket parser가 채울 pointer-free direct-release evidence다. e3c2는
/// 이 값의 producer를 열지 않고 consumer가 current runtime projection과 exact 비교하는 경계만 제공한다.
pub const DirectReleaseEvidence = struct {
    runtime_handle: u64 = 0,
    runtime_generation: u64 = 0,
    projection: @import("remote_runtime.zig").DirectReleaseProjection = .{},
};

pub const DirectReleaseReceipt = struct {
    self_addr: u64 = 0,
    coordinator_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: u64 = 0,
    backend_addr: u64 = 0,
    backend_generation: u64 = 0,
    target: backend_mod.DirectReleaseTarget = .{},
    lifecycle_raw: u8 = 0,
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,
};

pub const SessionHostCoordinator = struct {
    self_addr: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread: u64 = 0,
    lifecycle_raw: u8 = 0,
    seal: process_seal.CleanupSeal = [_]u8{0} ** 32,

    pub fn initInPlace(self: *SessionHostCoordinator, process_nonce: u64) !void {
        if (!std.meta.eql(self.*, SessionHostCoordinator{}) or process_nonce == 0)
            return error.InvalidAuthority;
        const identity = try process_seal.currentReadyIdentity();
        const thread_id: u64 = @intCast(std.Thread.getCurrentId());
        if (identity.pid == 0 or identity.process_nonce != process_nonce or thread_id == 0)
            return error.InvalidAuthority;
        self.* = .{
            .self_addr = @intFromPtr(self),
            .pid = identity.pid,
            .process_nonce = identity.process_nonce,
            .owner_thread = thread_id,
            .lifecycle_raw = @intFromEnum(Lifecycle.ready),
        };
        self.seal = try self.expectedSeal();
        try self.validate();
    }

    pub fn ensureReady(self: *SessionHostCoordinator, process_nonce: u64) !void {
        if (self.lifecycle_raw == @intFromEnum(Lifecycle.pristine))
            return self.initInPlace(process_nonce);
        try self.validate();
        if (self.process_nonce != process_nonce) return error.InvalidAuthority;
    }

    /// AppSession frame의 유일한 reconnect drain composition point다. 세 owner 주소는 이 호출을
    /// 넘겨 보존하지 않으며 backend singleton과 각 owner가 자기 권위를 같은 turn에서 재검증한다.
    pub fn drainReconnectAdmission(
        self: *SessionHostCoordinator,
        backend: *backend_mod.RemoteTermBackend,
        admissions: *admission_mod.Owner,
        budget: *budget_mod.ReconnectAdmissionBudget,
    ) !backend_mod.ReconnectDrainResult {
        try self.validate();
        try backend.validateReconnectCoordinatorTarget();
        if (!admissions.ownedBy(self.pid, self.process_nonce, self.owner_thread) or
            !budget.ownedBy(self.pid, self.process_nonce, self.owner_thread))
            return error.InvalidAuthority;
        return backend.drainReconnectAdmission(admissions, budget);
    }

    /// CR4의 verified socket response owner가 호출할 consumer-side 준비 경계다. e3c2는
    /// 실제 wire issuer를 주장하지 않고 canonical backend/runtime 상태와 one-shot receipt만 닫는다.
    pub fn prepareDirectReleaseReceipt(
        self: *SessionHostCoordinator,
        backend: *backend_mod.RemoteTermBackend,
        evidence: DirectReleaseEvidence,
        out: *DirectReleaseReceipt,
    ) !void {
        try self.validate();
        if (!std.meta.eql(out.*, DirectReleaseReceipt{})) return error.InvalidAuthority;
        try backend.validateReconnectCoordinatorTarget();
        const target = try backend.directReleaseTarget(evidence.runtime_handle);
        if (target.runtime_generation != evidence.runtime_generation or
            !std.meta.eql(target.projection, evidence.projection))
            return error.StaleExternalEvent;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .coordinator_addr = @intFromPtr(self),
            .pid = self.pid,
            .process_nonce = self.process_nonce,
            .owner_thread = self.owner_thread,
            .backend_addr = @intFromPtr(backend),
            .backend_generation = try backend.singletonGenerationForCoordinator(),
            .target = target,
            .lifecycle_raw = @intFromEnum(ReceiptLifecycle.prepared),
        };
        errdefer out.* = .{};
        out.seal = try self.expectedReceiptSeal(out);
        try self.validateReceipt(backend, out);
    }

    pub fn applyExternalReconnectEvent(
        self: *SessionHostCoordinator,
        backend: *backend_mod.RemoteTermBackend,
        receipt: *DirectReleaseReceipt,
    ) !void {
        try self.validate();
        try self.validateReceipt(backend, receipt);
        const now_ns = try monotonicNs();
        if (now_ns >= receipt.target.projection.deadline_ns)
            return error.ExpiredExternalEvent;
        var consumed = receipt.*;
        consumed.lifecycle_raw = @intFromEnum(ReceiptLifecycle.consumed);
        const consumed_seal = try self.expectedReceiptSeal(&consumed);
        try backend.applyDirectReleaseTarget(receipt.target);
        receipt.lifecycle_raw = @intFromEnum(ReceiptLifecycle.consumed);
        receipt.seal = consumed_seal;
    }

    fn validate(self: *const SessionHostCoordinator) !void {
        const thread_id: u64 = @intCast(std.Thread.getCurrentId());
        if (self.self_addr != @intFromPtr(self) or self.pid == 0 or self.process_nonce == 0 or
            self.owner_thread == 0 or self.owner_thread != thread_id or
            self.lifecycle_raw != @intFromEnum(Lifecycle.ready)) return error.InvalidAuthority;
        const identity = try process_seal.currentReadyIdentity();
        if (identity.pid != self.pid or identity.process_nonce != self.process_nonce)
            return error.InvalidAuthority;
        const expected = self.expectedSeal() catch return error.InvalidAuthority;
        if (!std.crypto.timing_safe.eql(process_seal.CleanupSeal, self.seal, expected))
            return error.InvalidAuthority;
    }

    fn expectedSeal(self: *const SessionHostCoordinator) !process_seal.CleanupSeal {
        return process_seal.sessionHostCoordinatorSeal(self.pid, self.process_nonce, .{
            .self_addr = self.self_addr,
            .thread_id = self.owner_thread,
            .lifecycle_raw = self.lifecycle_raw,
        });
    }

    fn validateReceipt(
        self: *const SessionHostCoordinator,
        backend: *backend_mod.RemoteTermBackend,
        receipt: *const DirectReleaseReceipt,
    ) !void {
        if (receipt.self_addr != @intFromPtr(receipt) or
            receipt.coordinator_addr != @intFromPtr(self) or receipt.pid != self.pid or
            receipt.process_nonce != self.process_nonce or receipt.owner_thread != self.owner_thread or
            receipt.backend_addr != @intFromPtr(backend) or
            receipt.backend_generation != try backend.singletonGenerationForCoordinator() or
            receipt.lifecycle_raw != @intFromEnum(ReceiptLifecycle.prepared))
            return error.InvalidAuthority;
        const expected = try self.expectedReceiptSeal(receipt);
        if (!std.crypto.timing_safe.eql(process_seal.CleanupSeal, receipt.seal, expected))
            return error.InvalidAuthority;
    }

    fn expectedReceiptSeal(
        self: *const SessionHostCoordinator,
        receipt: *const DirectReleaseReceipt,
    ) !process_seal.CleanupSeal {
        const p = receipt.target.projection;
        return process_seal.externalReconnectReceiptSeal(self.pid, self.process_nonce, .{
            .self_addr = receipt.self_addr,
            .coordinator_addr = receipt.coordinator_addr,
            .thread_id = receipt.owner_thread,
            .backend_addr = receipt.backend_addr,
            .backend_generation = receipt.backend_generation,
            .runtime_handle = receipt.target.runtime_handle,
            .runtime_generation = receipt.target.runtime_generation,
            .host_id = p.host_id,
            .host_adapter_generation = p.host_adapter_generation,
            .connection_generation = p.connection_generation,
            .incident_app_instance_nonce = p.incident_app_instance_nonce,
            .incident_sequence = p.incident_sequence,
            .job_generation = p.job_generation,
            .shell_generation = p.shell_generation,
            .attempt = p.attempt,
            .candidate_connection_generation = p.candidate_connection_generation,
            .deadline_ns = p.deadline_ns,
            .runtime_id = p.runtime_id,
            .lifecycle_raw = receipt.lifecycle_raw,
        });
    }
};

fn monotonicNs() !u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0)
        return error.ClockFailed;
    const seconds: u64 = @intCast(ts.sec);
    const nanos: u64 = @intCast(ts.nsec);
    return std.math.add(u64, std.math.mul(u64, seconds, std.time.ns_per_s) catch
        return error.ClockFailed, nanos) catch return error.ClockFailed;
}

const testing = std.testing;
const host_adapter = @import("host_adapter.zig");

fn recursivelyContainsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .@"fn" => true,
        .array => |info| recursivelyContainsPointer(info.child),
        .optional => |info| recursivelyContainsPointer(info.child),
        .error_union => |info| recursivelyContainsPointer(info.payload),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (recursivelyContainsPointer(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| if (recursivelyContainsPointer(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

test "CR2e-e3c1 coordinator는 sole drain과 copied stale backend mutation 0을 고정한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try host_adapter.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;
    var admissions: admission_mod.Owner = .{};
    try admissions.initInPlace(identity.process_nonce);
    var budget: budget_mod.ReconnectAdmissionBudget = .{};
    try budget.initInPlace(identity.process_nonce);
    defer budget.deinit() catch @panic("test reconnect budget deinit failed");
    var backend = backend_mod.RemoteTermBackend.initAttachOnlyWithPool(
        testing.allocator,
        testing.io,
        @ptrFromInt(0x1000),
        @ptrFromInt(0x2000),
    );
    try backend.claimProductSingleton();
    var backend_live = true;
    defer if (backend_live) backend.deinit();
    var coordinator: SessionHostCoordinator = .{};
    try coordinator.initInPlace(identity.process_nonce);

    try testing.expectEqual(
        backend_mod.ReconnectDrainResult.idle,
        try coordinator.drainReconnectAdmission(&backend, &admissions, &budget),
    );
    const admissions_before = admissions;
    const budget_before = try budget.snapshot();
    var copied_coordinator = coordinator;
    try testing.expectError(
        error.InvalidAuthority,
        copied_coordinator.drainReconnectAdmission(&backend, &admissions, &budget),
    );
    copied_coordinator.self_addr = @intFromPtr(&copied_coordinator);
    try testing.expectError(
        error.InvalidAuthority,
        copied_coordinator.drainReconnectAdmission(&backend, &admissions, &budget),
    );
    const Foreign = struct {
        fn run(
            coordinator_ptr: *SessionHostCoordinator,
            backend_ptr: *backend_mod.RemoteTermBackend,
            admissions_ptr: *admission_mod.Owner,
            budget_ptr: *budget_mod.ReconnectAdmissionBudget,
            rejected: *std.atomic.Value(bool),
        ) void {
            _ = coordinator_ptr.drainReconnectAdmission(backend_ptr, admissions_ptr, budget_ptr) catch |err| {
                rejected.store(err == error.InvalidAuthority, .release);
                return;
            };
        }
    };
    var foreign_rejected = std.atomic.Value(bool).init(false);
    const foreign = try std.Thread.spawn(
        .{},
        Foreign.run,
        .{ &coordinator, &backend, &admissions, &budget, &foreign_rejected },
    );
    foreign.join();
    try testing.expect(foreign_rejected.load(.acquire));
    var copied_backend = backend;
    try testing.expectError(
        error.InvalidSingletonOwner,
        coordinator.drainReconnectAdmission(&copied_backend, &admissions, &budget),
    );
    const stale_backend = backend;
    backend.deinit();
    backend_live = false;
    var replacement_backend = backend_mod.RemoteTermBackend.initAttachOnlyWithPool(
        testing.allocator,
        testing.io,
        @ptrFromInt(0x3000),
        @ptrFromInt(0x4000),
    );
    try replacement_backend.claimProductSingleton();
    defer replacement_backend.deinit();
    var stale_backend_copy = stale_backend;
    try testing.expectError(
        error.InvalidSingletonOwner,
        coordinator.drainReconnectAdmission(&stale_backend_copy, &admissions, &budget),
    );
    try testing.expectEqual(
        backend_mod.ReconnectDrainResult.idle,
        try coordinator.drainReconnectAdmission(&replacement_backend, &admissions, &budget),
    );
    try testing.expect(std.meta.eql(admissions_before, admissions));
    try testing.expectEqualDeep(budget_before, try budget.snapshot());
}

test "CR2e-e3c2 typed direct release receipt는 exact runtime에 one-shot 적용된다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try host_adapter.HostAdapter.initializeProcessRuntime();
    const identity = host_adapter.HostAdapter.publicationProcessIdentity() orelse
        return error.TestUnexpectedResult;
    try testing.expect(!recursivelyContainsPointer(DirectReleaseReceipt));
    try testing.expect(!recursivelyContainsPointer(DirectReleaseEvidence));
    var coordinator: SessionHostCoordinator = .{};
    try coordinator.initInPlace(identity.process_nonce);
    var fixture: @import("remote_runtime.zig").testing_api.SemanticFixture = undefined;
    try fixture.initInPlace();
    defer fixture.deinit();
    var budget: budget_mod.ReconnectAdmissionBudget = .{};
    try budget.initInPlace(identity.process_nonce);
    defer budget.deinit() catch @panic("test reconnect budget deinit failed");
    const admission: admission_mod.Projection = .{
        .slot_index = 0,
        .slot_generation = 1,
        .host_id = 1,
        .host_adapter_generation = 3,
        .connection_generation = fixture.adapter.connectionGeneration(),
        .incident_id = .{ .app_instance_nonce = 0xE3C2, .sequence = 7 },
    };
    try @import("remote_runtime.zig").testing_api.armDirectReleaseWait(
        &fixture.runtime,
        &budget,
        admission,
        [_]u8{0xA5} ** 16,
        1,
    );
    var executor_reset = false;
    defer if (!executor_reset) {
        @import("remote_runtime.zig").testing_api.resetDirectReleaseFixture(&fixture.runtime);
        @import("remote_runtime.zig").testing_api.releaseBoundReconnectAdmission(
            &fixture.runtime,
            &budget,
        ) catch @panic("test reconnect admission release failed");
    };
    var backend = backend_mod.RemoteTermBackend.initAttachOnlyWithPool(
        testing.allocator,
        testing.io,
        @ptrFromInt(0x1000),
        @ptrFromInt(0x2000),
    );
    try backend.claimProductSingleton();
    defer backend.deinit();
    try backend_mod.RemoteTermBackend.testing_api.installReconnectRuntime(
        &backend,
        9,
        &fixture.runtime,
        1,
        3,
    );
    defer testing.expect(backend_mod.RemoteTermBackend.testing_api.removeEventCursorRuntime(&backend, 9)) catch
        @panic("test runtime row cleanup failed");

    const expired_projection = try @import("remote_runtime.zig").testing_api.directReleaseProjection(&fixture.runtime);
    const expired_snapshot = try @import("remote_runtime.zig").testing_api.directReleaseSnapshot(&fixture.runtime);
    const expired_budget = try budget.snapshot();
    const expired_evidence: DirectReleaseEvidence = .{
        .runtime_handle = 9,
        .runtime_generation = 1,
        .projection = expired_projection,
    };
    var expired_receipt: DirectReleaseReceipt = .{};
    try coordinator.prepareDirectReleaseReceipt(&backend, expired_evidence, &expired_receipt);
    try testing.expectError(
        error.ExpiredExternalEvent,
        coordinator.applyExternalReconnectEvent(&backend, &expired_receipt),
    );
    try testing.expectEqualDeep(
        expired_snapshot,
        try @import("remote_runtime.zig").testing_api.directReleaseSnapshot(&fixture.runtime),
    );
    try testing.expectEqualDeep(expired_budget, try budget.snapshot());
    @import("remote_runtime.zig").testing_api.resetDirectReleaseFixture(&fixture.runtime);
    try @import("remote_runtime.zig").testing_api.releaseBoundReconnectAdmission(&fixture.runtime, &budget);
    try @import("remote_runtime.zig").testing_api.armDirectReleaseWait(
        &fixture.runtime,
        &budget,
        admission,
        [_]u8{0xA5} ** 16,
        std.math.maxInt(u64),
    );
    const state_before = try @import("remote_runtime.zig").testing_api.directReleaseProjection(&fixture.runtime);
    const executor_before = try @import("remote_runtime.zig").testing_api.directReleaseSnapshot(&fixture.runtime);
    const budget_before = try budget.snapshot();
    try testing.expect(!std.meta.eql(executor_before.prepared, @import("remote_runtime.zig").PreparedReconnect{}));
    const evidence: DirectReleaseEvidence = .{
        .runtime_handle = 9,
        .runtime_generation = 1,
        .projection = state_before,
    };
    var mismatched_evidence = evidence;
    mismatched_evidence.projection.incident_sequence +%= 1;
    var mismatch_destination: DirectReleaseReceipt = .{};
    try testing.expectError(
        error.StaleExternalEvent,
        coordinator.prepareDirectReleaseReceipt(&backend, mismatched_evidence, &mismatch_destination),
    );
    try testing.expect(std.meta.eql(mismatch_destination, DirectReleaseReceipt{}));
    try testing.expectEqualDeep(
        executor_before,
        try @import("remote_runtime.zig").testing_api.directReleaseSnapshot(&fixture.runtime),
    );
    try testing.expectEqualDeep(budget_before, try budget.snapshot());
    var stale_receipt: DirectReleaseReceipt = .{};
    try coordinator.prepareDirectReleaseReceipt(&backend, evidence, &stale_receipt);
    try testing.expect(backend_mod.RemoteTermBackend.testing_api.removeEventCursorRuntime(&backend, 9));
    try backend_mod.RemoteTermBackend.testing_api.installReconnectRuntime(
        &backend,
        9,
        &fixture.runtime,
        2,
        3,
    );
    try testing.expectError(
        error.StaleExternalEvent,
        coordinator.applyExternalReconnectEvent(&backend, &stale_receipt),
    );
    try testing.expectEqualDeep(
        executor_before,
        try @import("remote_runtime.zig").testing_api.directReleaseSnapshot(&fixture.runtime),
    );
    try testing.expectEqualDeep(budget_before, try budget.snapshot());
    var receipt: DirectReleaseReceipt = .{};
    var replacement_evidence = evidence;
    replacement_evidence.runtime_generation = 2;
    try coordinator.prepareDirectReleaseReceipt(&backend, replacement_evidence, &receipt);
    var copied = receipt;
    try testing.expectError(
        error.InvalidAuthority,
        coordinator.applyExternalReconnectEvent(&backend, &copied),
    );
    copied.self_addr = @intFromPtr(&copied);
    try testing.expectError(
        error.InvalidAuthority,
        coordinator.applyExternalReconnectEvent(&backend, &copied),
    );
    try testing.expectEqualDeep(
        executor_before,
        try @import("remote_runtime.zig").testing_api.directReleaseSnapshot(&fixture.runtime),
    );
    try testing.expectEqualDeep(budget_before, try budget.snapshot());
    try coordinator.applyExternalReconnectEvent(&backend, &receipt);
    try testing.expectError(
        error.InvalidAuthority,
        coordinator.applyExternalReconnectEvent(&backend, &receipt),
    );
    try testing.expectError(
        error.IllegalTransition,
        @import("remote_runtime.zig").testing_api.directReleaseProjection(&fixture.runtime),
    );
    @import("remote_runtime.zig").testing_api.resetDirectReleaseFixture(&fixture.runtime);
    try @import("remote_runtime.zig").testing_api.releaseBoundReconnectAdmission(&fixture.runtime, &budget);
    executor_reset = true;
}
