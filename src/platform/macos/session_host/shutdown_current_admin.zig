//! current host의 terminate ambiguity를 one-shot admin barrier와 inventory receipt로 해소한다.

const std = @import("std");
const contract = @import("maru").app.shutdown_wire_contract;
const attempt = @import("shutdown_attempt_authority.zig");

pub const Phase = enum(u8) { ready, terminate_live, awaiting_barrier, inventory_live, terminal };
pub const Membership = enum(u8) { present, absent };

pub const CurrentAdminCoordinator = struct {
    phase: Phase = .ready,
    request_count: u8 = 0,
    open_connection_count: u8 = 0,
    last_connection_identity: u64 = 0,
    live_lease_generation: u64 = 0,
    canonical_deinit_count: u8 = 0,
    inventory_retry_used: bool = false,

    pub fn beginTerminate(
        self: *CurrentAdminCoordinator,
        authority: *attempt.ShutdownAttemptAuthority,
        receipt: *contract.ShutdownConnectionReceipt,
        now_ns: u64,
        connection_identity: u64,
    ) !void {
        if (self.phase != .ready or self.open_connection_count != 0) return error.Busy;
        try attempt.issueConnection(authority, receipt, now_ns, connection_identity, .terminate, .none, terminateTranscript(authority));
        self.phase = .terminate_live;
        self.request_count += 1;
        self.openConnection(receipt);
    }

    pub fn terminateConfirmed(
        self: *CurrentAdminCoordinator,
        authority: *attempt.ShutdownAttemptAuthority,
        receipt: *contract.ShutdownConnectionReceipt,
    ) !void {
        if (self.phase != .terminate_live) return error.InvalidState;
        try attempt.consumeConnection(authority, receipt, true);
        self.closeConnection(receipt);
        self.phase = .terminal;
    }

    pub fn terminateAmbiguous(
        self: *CurrentAdminCoordinator,
        authority: *attempt.ShutdownAttemptAuthority,
        receipt: *contract.ShutdownConnectionReceipt,
    ) !void {
        if (self.phase != .terminate_live) return error.InvalidState;
        try attempt.consumeConnection(authority, receipt, false);
        self.closeConnection(receipt);
        self.phase = .awaiting_barrier;
    }

    /// connection은 발급됐지만 request byte가 0이면 barrier evidence가 필요 없다. attempt generation은 이미
    /// burn됐으므로 되감지 않고 receipt만 소비한 뒤 다음 tick의 새 terminate attempt를 허용한다.
    pub fn terminateNotExecuted(
        self: *CurrentAdminCoordinator,
        authority: *attempt.ShutdownAttemptAuthority,
        receipt: *contract.ShutdownConnectionReceipt,
    ) !void {
        if (self.phase != .terminate_live) return error.InvalidState;
        try attempt.consumeConnection(authority, receipt, false);
        self.closeConnection(receipt);
        self.phase = .ready;
    }

    pub fn beginInventory(
        self: *CurrentAdminCoordinator,
        authority: *attempt.ShutdownAttemptAuthority,
        receipt: *contract.ShutdownConnectionReceipt,
        now_ns: u64,
        connection_identity: u64,
        barrier_acquired: bool,
    ) !void {
        if (self.phase != .awaiting_barrier or self.open_connection_count != 0) return error.InvalidState;
        if (!barrier_acquired) return error.Busy;
        const inventory_kind: contract.InventoryAttempt = if (self.inventory_retry_used) .retry else .initial;
        try attempt.issueConnection(authority, receipt, now_ns, connection_identity, .inventory, inventory_kind, inventoryTranscript(authority, inventory_kind));
        self.phase = .inventory_live;
        self.openConnection(receipt);
    }

    pub fn inventoryConfirmed(
        self: *CurrentAdminCoordinator,
        authority: *attempt.ShutdownAttemptAuthority,
        receipt: *contract.ShutdownConnectionReceipt,
        membership: Membership,
    ) !void {
        if (self.phase != .inventory_live) return error.InvalidState;
        try attempt.consumeConnection(authority, receipt, membership == .absent);
        self.closeConnection(receipt);
        self.phase = if (membership == .absent) .terminal else .ready;
    }

    pub fn inventoryAmbiguous(
        self: *CurrentAdminCoordinator,
        authority: *attempt.ShutdownAttemptAuthority,
        receipt: *contract.ShutdownConnectionReceipt,
    ) !bool {
        if (self.phase != .inventory_live) return error.InvalidState;
        if (self.inventory_retry_used) {
            try attempt.consumeConnection(authority, receipt, true);
            self.closeConnection(receipt);
            self.phase = .terminal;
            return false;
        }
        try attempt.consumeConnection(authority, receipt, false);
        self.closeConnection(receipt);
        self.inventory_retry_used = true;
        self.phase = .awaiting_barrier;
        return true;
    }

    pub fn inventoryInvalid(
        self: *CurrentAdminCoordinator,
        authority: *attempt.ShutdownAttemptAuthority,
        receipt: *contract.ShutdownConnectionReceipt,
    ) !void {
        if (self.phase != .inventory_live) return error.InvalidState;
        try attempt.consumeConnection(authority, receipt, false);
        self.closeConnection(receipt);
        self.phase = .awaiting_barrier;
    }

    fn openConnection(self: *CurrentAdminCoordinator, receipt: *const contract.ShutdownConnectionReceipt) void {
        std.debug.assert(self.open_connection_count == 0 and self.live_lease_generation == 0);
        self.open_connection_count = 1;
        self.last_connection_identity = receipt.connection_identity;
        self.live_lease_generation = receipt.lease_generation;
    }

    fn closeConnection(self: *CurrentAdminCoordinator, receipt: *const contract.ShutdownConnectionReceipt) void {
        std.debug.assert(self.open_connection_count == 1 and
            self.last_connection_identity == receipt.connection_identity and
            self.live_lease_generation == receipt.lease_generation);
        self.open_connection_count = 0;
        self.live_lease_generation = 0;
        self.canonical_deinit_count += 1;
    }
};

fn terminateTranscript(authority: *const attempt.ShutdownAttemptAuthority) contract.Digest {
    return transcript(authority, 0);
}

fn inventoryTranscript(authority: *const attempt.ShutdownAttemptAuthority, kind: contract.InventoryAttempt) contract.Digest {
    return transcript(authority, @intFromEnum(kind) + 1);
}

fn transcript(authority: *const attempt.ShutdownAttemptAuthority, kind: u8) contract.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&authority.target_digest);
    var generation: [8]u8 = undefined;
    std.mem.writeInt(u64, &generation, authority.attempt_generation, .little);
    hasher.update(&generation);
    hasher.update(&.{kind});
    return hasher.finalResult();
}

fn fixture() !attempt.ShutdownAttemptAuthority {
    try attempt.testing.ensureSealReady();
    var authority: attempt.ShutdownAttemptAuthority = .{};
    try attempt.prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    return authority;
}

test "C3-3b6 current admin model은 terminate reply를 confirmed outcome으로 소비한다" {
    var authority_storage: attempt.ShutdownAttemptAuthority = .{};
    _ = try fixture();
    try attempt.prepare(&authority_storage, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var coordinator: CurrentAdminCoordinator = .{};
    var receipt: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginTerminate(&authority_storage, &receipt, 1, 11);
    try coordinator.terminateConfirmed(&authority_storage, &receipt);
    try std.testing.expectEqual(Phase.terminal, coordinator.phase);
}

test "C3-3b6 current admin model은 ambiguous 뒤 새 barrier의 absence만 확정한다" {
    var authority: attempt.ShutdownAttemptAuthority = .{};
    _ = try fixture();
    try attempt.prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var coordinator: CurrentAdminCoordinator = .{};
    var terminate_receipt: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginTerminate(&authority, &terminate_receipt, 1, 11);
    try coordinator.terminateAmbiguous(&authority, &terminate_receipt);
    var inventory_receipt: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginInventory(&authority, &inventory_receipt, 2, 12, true);
    try coordinator.inventoryConfirmed(&authority, &inventory_receipt, .absent);
    try std.testing.expectEqual(Phase.terminal, coordinator.phase);
}

test "C3-3b6 current admin model은 membership present 뒤 새 attempt를 발급한다" {
    var authority: attempt.ShutdownAttemptAuthority = .{};
    _ = try fixture();
    try attempt.prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var coordinator: CurrentAdminCoordinator = .{};
    var first: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginTerminate(&authority, &first, 1, 11);
    try coordinator.terminateAmbiguous(&authority, &first);
    var inventory: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginInventory(&authority, &inventory, 2, 12, true);
    try coordinator.inventoryConfirmed(&authority, &inventory, .present);
    var second: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginTerminate(&authority, &second, 3, 13);
    try std.testing.expectEqual(@as(u64, 2), authority.attempt_generation);
}

test "C3-3b6 current admin model은 barrier busy에서 request를 보내지 않는다" {
    var authority: attempt.ShutdownAttemptAuthority = .{};
    _ = try fixture();
    try attempt.prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var coordinator: CurrentAdminCoordinator = .{ .phase = .awaiting_barrier };
    var receipt: contract.ShutdownConnectionReceipt = .{};
    try std.testing.expectError(error.Busy, coordinator.beginInventory(&authority, &receipt, 1, 11, false));
    try std.testing.expectEqual(@as(u8, 0), coordinator.request_count);
}

test "C3-3b6 current admin model은 initial inventory ambiguity 뒤 read-only retry만 허용한다" {
    var authority: attempt.ShutdownAttemptAuthority = .{};
    _ = try fixture();
    try attempt.prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var coordinator: CurrentAdminCoordinator = .{ .phase = .awaiting_barrier };
    var initial: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginInventory(&authority, &initial, 1, 11, true);
    try std.testing.expect(try coordinator.inventoryAmbiguous(&authority, &initial));
    var retry: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginInventory(&authority, &retry, 2, 12, true);
    try std.testing.expectEqual(@intFromEnum(contract.InventoryAttempt.retry), retry.inventory_attempt_raw);
    try std.testing.expectEqual(@as(u8, 0), coordinator.request_count);
}

test "C3-3b6 current admin model은 retry inventory ambiguity를 bounded로 닫는다" {
    var authority: attempt.ShutdownAttemptAuthority = .{};
    _ = try fixture();
    try attempt.prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var coordinator: CurrentAdminCoordinator = .{ .phase = .awaiting_barrier, .inventory_retry_used = true };
    var retry: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginInventory(&authority, &retry, 1, 11, true);
    try std.testing.expect(!try coordinator.inventoryAmbiguous(&authority, &retry));
    try std.testing.expectEqual(Phase.terminal, coordinator.phase);
}

test "C3-3b6 current admin model은 malformed reply와 host drift를 absence로 쓰지 않는다" {
    var authority: attempt.ShutdownAttemptAuthority = .{};
    _ = try fixture();
    try attempt.prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var coordinator: CurrentAdminCoordinator = .{ .phase = .awaiting_barrier };
    var receipt: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginInventory(&authority, &receipt, 1, 11, true);
    try coordinator.inventoryInvalid(&authority, &receipt);
    try std.testing.expectEqual(Phase.awaiting_barrier, coordinator.phase);
}

test "C3-3b6 current admin model은 target connection을 순차로 열고 닫는다" {
    var authority: attempt.ShutdownAttemptAuthority = .{};
    _ = try fixture();
    try attempt.prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var coordinator: CurrentAdminCoordinator = .{};
    var receipt: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginTerminate(&authority, &receipt, 1, 11);
    var sibling: contract.ShutdownConnectionReceipt = .{};
    try std.testing.expectError(error.Busy, coordinator.beginTerminate(&authority, &sibling, 2, 12));
    try coordinator.terminateAmbiguous(&authority, &receipt);
    try std.testing.expectEqual(@as(u8, 0), coordinator.open_connection_count);
}

test "C3-3b6 current admin model은 one-shot admin lease를 canonical deinit에서만 반환한다" {
    var authority: attempt.ShutdownAttemptAuthority = .{};
    _ = try fixture();
    try attempt.prepare(&authority, 7, [_]u8{3} ** 32, .terminate_host, 100);
    var coordinator: CurrentAdminCoordinator = .{};
    var receipt: contract.ShutdownConnectionReceipt = .{};
    try coordinator.beginTerminate(&authority, &receipt, 1, 11);
    try std.testing.expectEqual(@as(u8, 1), coordinator.open_connection_count);
    try std.testing.expectEqual(receipt.lease_generation, coordinator.live_lease_generation);
    try coordinator.terminateAmbiguous(&authority, &receipt);
    try std.testing.expectEqual(@as(u8, 0), coordinator.open_connection_count);
    try std.testing.expectEqual(@as(u64, 0), coordinator.live_lease_generation);
    try std.testing.expectEqual(@as(u8, 1), coordinator.canonical_deinit_count);
    try std.testing.expectEqual(@as(u64, 1), authority.connection_lease_generation);
}
