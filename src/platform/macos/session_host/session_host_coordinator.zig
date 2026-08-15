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
};

const testing = std.testing;
const host_adapter = @import("host_adapter.zig");

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
