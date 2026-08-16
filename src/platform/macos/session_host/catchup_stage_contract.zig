//! CR4a candidate catch-up의 pointer-free accounting과 staged receipt 계약.
//!
//! 일반 Client inbox 상한은 여러 runtime의 정상 렌더 트래픽을 보호하지만, reconnect candidate가
//! takeover 전에 소비할 수 있는 작업량을 증명하지는 않는다. 이 모듈은 마지막 초과 batch를
//! 화면에 적용하기 전에 거부할 수 있도록 catch-up 전용 누적 상한과 final-address receipt를 둔다.

const std = @import("std");
const barrier_contract = @import("catchup_barrier_contract.zig");

pub const max_batches: u32 = 64;
pub const max_encoded_bytes: u64 = 16 * 1024 * 1024;
pub const max_decoded_cells: u64 = 1024 * 1024;

pub const Error = error{
    BatchLimitExceeded,
    ByteLimitExceeded,
    CellLimitExceeded,
    InvalidAuthority,
    Busy,
    DestinationOccupied,
};

pub const Accounting = struct {
    batches: u32 = 0,
    encoded_bytes: u64 = 0,
    decoded_cells: u64 = 0,

    pub fn admit(
        self: Accounting,
        encoded_bytes: usize,
        decoded_cells: u64,
    ) Error!Accounting {
        if (encoded_bytes == 0) return error.InvalidAuthority;
        const next_batches = std.math.add(u32, self.batches, 1) catch
            return error.BatchLimitExceeded;
        if (next_batches > max_batches) return error.BatchLimitExceeded;
        const next_bytes = std.math.add(u64, self.encoded_bytes, encoded_bytes) catch
            return error.ByteLimitExceeded;
        if (next_bytes > max_encoded_bytes) return error.ByteLimitExceeded;
        const next_cells = std.math.add(u64, self.decoded_cells, decoded_cells) catch
            return error.CellLimitExceeded;
        if (next_cells > max_decoded_cells) return error.CellLimitExceeded;
        return .{
            .batches = next_batches,
            .encoded_bytes = next_bytes,
            .decoded_cells = next_cells,
        };
    }
};

pub const Lifecycle = enum(u8) { pristine, staged, consumed, aborted };

/// Candidate final address와 GUI-local transport identity를 host wire identity와 함께 봉인한다.
/// CR4b는 이 값의 public fields를 신뢰하지 않고 canonical owner projection과 다시 대조한다.
pub const PreparedStage = struct {
    self_addr: usize = 0,
    attachment_addr: usize = 0,
    client_slot_addr: usize = 0,
    slot_incarnation: u64 = 0,
    node_incarnation: u64 = 0,
    connection_generation: u64 = 0,
    transport_incarnation: u64 = 0,
    pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_thread_id: std.Thread.Id = 0,
    stream_id: u64 = 0,
    owner_generation: u64 = 0,
    identity: barrier_contract.CatchupIdentity = .{
        .subscription = .{ .value = 0 },
        .runtime_id = 0,
        .connection = .{ .monotonic_id = 0, .slot_generation = 0 },
        .host_id = 0,
        .request_nonce = 0,
    },
    snapshot: barrier_contract.ScreenFrontier = .{ .generation = 0, .sequence = 0 },
    target: barrier_contract.ScreenFrontier = .{ .generation = 0, .sequence = 0 },
    accounting: Accounting = .{},
    deadline_expires_at_ns: i128 = 0,
    lifecycle: Lifecycle = .pristine,

    pub fn pristine(self: *const PreparedStage) bool {
        return self.self_addr == 0 and self.attachment_addr == 0 and
            self.client_slot_addr == 0 and self.slot_incarnation == 0 and
            self.node_incarnation == 0 and self.connection_generation == 0 and
            self.transport_incarnation == 0 and self.pid == 0 and
            self.process_nonce == 0 and self.owner_thread_id == 0 and
            self.stream_id == 0 and self.owner_generation == 0 and
            self.identity.subscription.value == 0 and
            self.identity.runtime_id == 0 and self.identity.connection.monotonic_id == 0 and
            self.identity.connection.slot_generation == 0 and self.identity.host_id == 0 and
            self.identity.request_nonce == 0 and self.snapshot.generation == 0 and
            self.snapshot.sequence == 0 and self.target.generation == 0 and
            self.target.sequence == 0 and self.accounting.batches == 0 and
            self.accounting.encoded_bytes == 0 and self.accounting.decoded_cells == 0 and
            self.deadline_expires_at_ns == 0 and
            self.lifecycle == .pristine;
    }
};

test "CR4a catchup accounting은 batch byte cell cap plus one을 apply 전에 거부한다" {
    const testing = std.testing;
    var accounting: Accounting = .{};
    accounting = try accounting.admit(max_encoded_bytes, max_decoded_cells);
    try testing.expectEqual(@as(u32, 1), accounting.batches);
    try testing.expectEqual(max_encoded_bytes, accounting.encoded_bytes);
    try testing.expectEqual(max_decoded_cells, accounting.decoded_cells);
    const before = accounting;
    try testing.expectError(error.ByteLimitExceeded, accounting.admit(1, 0));
    try testing.expectEqualDeep(before, accounting);
    try testing.expectError(
        error.CellLimitExceeded,
        (Accounting{}).admit(1, max_decoded_cells + 1),
    );

    accounting = .{};
    var i: u32 = 0;
    while (i < max_batches) : (i += 1) accounting = try accounting.admit(1, 0);
    try testing.expectEqual(max_batches, accounting.batches);
    const full = accounting;
    try testing.expectError(error.BatchLimitExceeded, accounting.admit(1, 0));
    try testing.expectEqualDeep(full, accounting);
}

test "CR4a catchup staged receipt는 pristine final address storage를 요구한다" {
    const testing = std.testing;
    var out: PreparedStage = .{};
    try testing.expect(out.pristine());
    out.self_addr = @intFromPtr(&out);
    try testing.expect(!out.pristine());
    out = .{};
    out.lifecycle = .staged;
    try testing.expect(!out.pristine());
}
