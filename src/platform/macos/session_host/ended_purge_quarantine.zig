const std = @import("std");
extern "c" fn usleep(usec: c_uint) c_int;

pub const max_ended_purge_quarantine_bytes: usize = 64 * 1024 * 1024;

pub const Error = error{
    InvalidOwner,
    InvalidState,
    ArithmeticOverflow,
    CapacityExceeded,
};

pub const Reservation = struct {
    const Lifecycle = enum { pristine, reserved, spent };

    self_addr: usize = 0,
    registry_addr: usize = 0,
    reservation_generation: u64 = 0,
    process_id: u64 = 0,
    node_incarnation: u64 = 0,
    operation_generation: u64 = 0,
    bytes: usize = 0,
    lifecycle: Lifecycle = .pristine,
};

pub const CommitReceipt = struct {
    const Lifecycle = enum { pristine, committed, consumed };

    self_addr: usize = 0,
    registry_addr: usize = 0,
    reservation_generation: u64 = 0,
    process_id: u64 = 0,
    node_incarnation: u64 = 0,
    operation_generation: u64 = 0,
    bytes: usize = 0,
    lifecycle: Lifecycle = .pristine,
};

/// Registry consumption을 마친 뒤 Client finalizer가 비교하는 pointer-free 상관관계 증거다.
/// 인증 capability가 아니므로 pointer나 mutable lifecycle을 넣지 않는다.
pub const ConsumedCommitProof = struct {
    reservation_generation: u64 = 0,
    process_id: u64 = 0,
    node_incarnation: u64 = 0,
    operation_generation: u64 = 0,
    bytes: usize = 0,

    pub fn matches(
        self: ConsumedCommitProof,
        process_id: u64,
        node_incarnation: u64,
        operation_generation: u64,
        bytes: usize,
    ) bool {
        return self.reservation_generation != 0 and
            self.process_id == process_id and
            self.node_incarnation == node_incarnation and
            self.operation_generation == operation_generation and
            self.bytes == bytes;
    }
};

pub const Registry = struct {
    const State = enum { idle, reserved, committed };

    mutex: std.atomic.Mutex = .unlocked,
    owner_process_id: u64 = 0,
    state: State = .idle,
    next_generation: u64 = 1,
    reserved_reservation_addr: usize = 0,
    reserved_generation: u64 = 0,
    reserved_process_id: u64 = 0,
    reserved_node_incarnation: u64 = 0,
    reserved_operation_generation: u64 = 0,
    reserved_bytes: usize = 0,
    committed_receipt_addr: usize = 0,
    committed_generation: u64 = 0,
    committed_process_id: u64 = 0,
    committed_node_incarnation: u64 = 0,
    committed_operation_generation: u64 = 0,
    committed_bytes: usize = 0,
    finalization_consumed: bool = false,

    pub fn init() Registry {
        return .{ .owner_process_id = @intCast(std.c.getpid()) };
    }

    pub fn reserve(
        self: *Registry,
        node_incarnation: u64,
        operation_generation: u64,
        bytes: usize,
        out: *Reservation,
    ) Error!void {
        const process_id: u64 = @intCast(std.c.getpid());
        if (self.owner_process_id == 0 or self.owner_process_id != process_id)
            return error.InvalidOwner;
        // The caller supplies final-address authority storage. Reject overlap before reading that
        // storage: an aliased Reservation write could otherwise overwrite the mutex and canonical
        // registry mirrors while reserve is publishing them.
        if (objectsOverlap(self, out)) return error.InvalidOwner;
        if (node_incarnation == 0 or operation_generation == 0)
            return error.InvalidOwner;
        if (bytes > max_ended_purge_quarantine_bytes)
            return error.CapacityExceeded;
        if (out.lifecycle != .pristine or out.self_addr != 0)
            return error.InvalidState;

        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.state == .committed) return error.CapacityExceeded;
        if (self.state != .idle) return error.InvalidState;
        if (!idleProjectionValid(self)) return error.InvalidState;
        const generation = self.next_generation;
        if (generation == 0 or generation == std.math.maxInt(u64))
            return error.ArithmeticOverflow;

        self.state = .reserved;
        self.next_generation = generation + 1;
        self.reserved_reservation_addr = @intFromPtr(out);
        self.reserved_generation = generation;
        self.reserved_process_id = process_id;
        self.reserved_node_incarnation = node_incarnation;
        self.reserved_operation_generation = operation_generation;
        self.reserved_bytes = bytes;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .registry_addr = @intFromPtr(self),
            .reservation_generation = generation,
            .process_id = process_id,
            .node_incarnation = node_incarnation,
            .operation_generation = operation_generation,
            .bytes = bytes,
            .lifecycle = .reserved,
        };
    }

    pub fn release(self: *Registry, reservation: *Reservation) bool {
        const process_id: u64 = @intCast(std.c.getpid());
        if (self.owner_process_id == 0 or self.owner_process_id != process_id or
            objectsOverlap(self, reservation) or
            reservation.process_id != process_id)
            return false;
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (!matchesReservation(self, process_id, reservation)) return false;
        reservation.lifecycle = .spent;
        clearReserved(self);
        self.state = .idle;
        return true;
    }

    pub fn commit(
        self: *Registry,
        reservation: *Reservation,
        out: *CommitReceipt,
    ) bool {
        const process_id: u64 = @intCast(std.c.getpid());
        if (self.owner_process_id == 0 or self.owner_process_id != process_id or
            objectsOverlap(self, reservation) or
            objectsOverlap(self, out) or
            objectsOverlap(reservation, out) or
            reservation.process_id != process_id or
            !commitReceiptPristine(out))
            return false;
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (!matchesReservation(self, process_id, reservation)) return false;
        const bytes = self.reserved_bytes;
        const generation = self.reserved_generation;
        const node_incarnation = self.reserved_node_incarnation;
        const operation_generation = self.reserved_operation_generation;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .registry_addr = @intFromPtr(self),
            .reservation_generation = generation,
            .process_id = process_id,
            .node_incarnation = node_incarnation,
            .operation_generation = operation_generation,
            .bytes = bytes,
            .lifecycle = .committed,
        };
        reservation.lifecycle = .spent;
        clearReserved(self);
        self.committed_receipt_addr = @intFromPtr(out);
        self.committed_generation = generation;
        self.committed_process_id = process_id;
        self.committed_node_incarnation = node_incarnation;
        self.committed_operation_generation = operation_generation;
        self.committed_bytes = bytes;
        self.finalization_consumed = false;
        self.state = .committed;
        return true;
    }

    pub fn consumeCommitted(
        self: *Registry,
        receipt: *CommitReceipt,
        out: *ConsumedCommitProof,
    ) bool {
        const process_id: u64 = @intCast(std.c.getpid());
        if (self.owner_process_id == 0 or self.owner_process_id != process_id or
            objectsOverlap(self, receipt) or
            objectsOverlap(self, out) or
            objectsOverlap(receipt, out) or
            receipt.process_id != process_id or
            !consumedCommitProofPristine(out))
            return false;
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (!matchesCommittedReceipt(self, process_id, receipt)) return false;
        out.* = .{
            .reservation_generation = self.committed_generation,
            .process_id = self.committed_process_id,
            .node_incarnation = self.committed_node_incarnation,
            .operation_generation = self.committed_operation_generation,
            .bytes = self.committed_bytes,
        };
        receipt.lifecycle = .consumed;
        self.committed_receipt_addr = 0;
        self.finalization_consumed = true;
        return true;
    }
};

fn objectsOverlap(first: anytype, second: anytype) bool {
    const first_start = @intFromPtr(first);
    const second_start = @intFromPtr(second);
    const first_end = std.math.add(usize, first_start, @sizeOf(@TypeOf(first.*))) catch return true;
    const second_end = std.math.add(usize, second_start, @sizeOf(@TypeOf(second.*))) catch return true;
    return first_start < second_end and second_start < first_end;
}

fn matchesReservation(
    self: *const Registry,
    process_id: u64,
    reservation: *const Reservation,
) bool {
    return reservedProjectionValid(self) and
        reservation.lifecycle == .reserved and
        reservation.self_addr == @intFromPtr(reservation) and
        reservation.registry_addr == @intFromPtr(self) and
        self.reserved_reservation_addr == @intFromPtr(reservation) and
        reservation.reservation_generation == self.reserved_generation and
        reservation.process_id == process_id and
        reservation.process_id == self.reserved_process_id and
        reservation.node_incarnation == self.reserved_node_incarnation and
        reservation.operation_generation == self.reserved_operation_generation and
        reservation.bytes == self.reserved_bytes;
}

fn matchesCommittedReceipt(
    self: *const Registry,
    process_id: u64,
    receipt: *const CommitReceipt,
) bool {
    return committedProjectionValid(self) and
        receipt.lifecycle == .committed and
        receipt.self_addr == @intFromPtr(receipt) and
        receipt.registry_addr == @intFromPtr(self) and
        self.committed_receipt_addr == @intFromPtr(receipt) and
        receipt.reservation_generation == self.committed_generation and
        receipt.process_id == process_id and
        receipt.process_id == self.committed_process_id and
        receipt.node_incarnation == self.committed_node_incarnation and
        receipt.operation_generation == self.committed_operation_generation and
        receipt.bytes == self.committed_bytes;
}

fn commitReceiptPristine(receipt: *const CommitReceipt) bool {
    return std.meta.eql(receipt.*, CommitReceipt{});
}

fn consumedCommitProofPristine(proof: *const ConsumedCommitProof) bool {
    return std.meta.eql(proof.*, ConsumedCommitProof{});
}

fn idleProjectionValid(self: *const Registry) bool {
    return self.state == .idle and
        self.next_generation != 0 and
        self.reserved_reservation_addr == 0 and
        self.reserved_generation == 0 and
        self.reserved_process_id == 0 and
        self.reserved_node_incarnation == 0 and
        self.reserved_operation_generation == 0 and
        self.reserved_bytes == 0 and
        committedProjectionEmpty(self);
}

fn reservedProjectionValid(self: *const Registry) bool {
    return self.state == .reserved and
        self.reserved_reservation_addr != 0 and
        self.reserved_generation != 0 and
        self.reserved_generation != std.math.maxInt(u64) and
        self.next_generation == self.reserved_generation + 1 and
        self.reserved_process_id == self.owner_process_id and
        self.reserved_node_incarnation != 0 and
        self.reserved_operation_generation != 0 and
        committedProjectionEmpty(self);
}

fn committedProjectionEmpty(self: *const Registry) bool {
    return self.committed_receipt_addr == 0 and
        self.committed_generation == 0 and
        self.committed_process_id == 0 and
        self.committed_node_incarnation == 0 and
        self.committed_operation_generation == 0 and
        self.committed_bytes == 0 and
        !self.finalization_consumed;
}

fn committedProjectionValid(self: *const Registry) bool {
    return self.state == .committed and
        self.reserved_reservation_addr == 0 and
        self.reserved_generation == 0 and
        self.reserved_process_id == 0 and
        self.reserved_node_incarnation == 0 and
        self.reserved_operation_generation == 0 and
        self.reserved_bytes == 0 and
        self.committed_generation != 0 and
        self.committed_generation != std.math.maxInt(u64) and
        self.committed_process_id == self.owner_process_id and
        self.committed_node_incarnation != 0 and
        self.committed_operation_generation != 0 and
        if (self.finalization_consumed)
            self.committed_receipt_addr == 0
        else
            self.committed_receipt_addr != 0;
}

fn clearReserved(self: *Registry) void {
    self.reserved_reservation_addr = 0;
    self.reserved_generation = 0;
    self.reserved_process_id = 0;
    self.reserved_node_incarnation = 0;
    self.reserved_operation_generation = 0;
    self.reserved_bytes = 0;
}

fn waitChildBounded(child: std.c.pid_t) !c_int {
    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
        if (waited == child) return status;
        if (waited < 0) {
            if (std.posix.errno(waited) == .INTR) continue;
            terminateAndReap(child);
            return error.TestUnexpectedResult;
        }
        _ = usleep(1000);
    }
    terminateAndReap(child);
    return error.TestUnexpectedResult;
}

fn terminateAndReap(child: std.c.pid_t) void {
    _ = std.c.kill(child, std.c.SIG.KILL);
    var status: c_int = 0;
    while (true) {
        const waited = std.c.waitpid(child, &status, 0);
        if (waited == child or (waited < 0 and std.posix.errno(waited) == .CHILD)) return;
        if (waited < 0 and std.posix.errno(waited) == .INTR) continue;
        return;
    }
}

test "reservation enforces exact cap and consumes release once" {
    var registry = Registry.init();
    var reservation: Reservation = .{};
    try registry.reserve(7, 11, max_ended_purge_quarantine_bytes, &reservation);
    try std.testing.expect(registry.release(&reservation));
    try std.testing.expect(!registry.release(&reservation));
}

test "default registry and zero identities reject before state mutation" {
    var unbound: Registry = .{};
    var out: Reservation = .{};
    try std.testing.expectError(error.InvalidOwner, unbound.reserve(1, 1, 1, &out));
    try std.testing.expectEqual(Reservation{}, out);

    var registry = Registry.init();
    try std.testing.expectError(error.InvalidOwner, registry.reserve(0, 1, 1, &out));
    try std.testing.expectError(error.InvalidOwner, registry.reserve(1, 0, 1, &out));
    try std.testing.expect(idleProjectionValid(&registry));
}

test "committed quarantine is absorbing and rejects replay" {
    var registry = Registry.init();
    var reservation: Reservation = .{};
    var receipt: CommitReceipt = .{};
    try registry.reserve(7, 11, 4096, &reservation);
    try std.testing.expect(registry.commit(&reservation, &receipt));
    try std.testing.expectEqual(@as(usize, 4096), registry.committed_bytes);
    var replay_receipt: CommitReceipt = .{};
    try std.testing.expect(!registry.commit(&reservation, &replay_receipt));

    var later: Reservation = .{};
    try std.testing.expectError(
        error.CapacityExceeded,
        registry.reserve(7, 12, 1, &later),
    );
}

test "copied reservation and cap plus one cannot consume authority" {
    var registry = Registry.init();
    var reservation: Reservation = .{};
    try std.testing.expectError(
        error.CapacityExceeded,
        registry.reserve(7, 11, max_ended_purge_quarantine_bytes + 1, &reservation),
    );
    try registry.reserve(7, 11, 8, &reservation);
    var copied = reservation;
    copied.self_addr = @intFromPtr(&copied);
    var receipt: CommitReceipt = .{};
    try std.testing.expect(!registry.commit(&copied, &receipt));
    try std.testing.expect(registry.release(&reservation));
}

test "reservation storage cannot overlap registry state" {
    var registry = Registry.init();
    const exact_alias: *Reservation = @ptrCast(@alignCast(&registry));
    try std.testing.expectError(error.InvalidOwner, registry.reserve(7, 11, 8, exact_alias));
    try std.testing.expect(idleProjectionValid(&registry));

    const registry_bytes: [*]u8 = @ptrCast(&registry);
    const partial_alias: *Reservation = @ptrCast(@alignCast(
        registry_bytes + @alignOf(Reservation),
    ));
    try std.testing.expectError(error.InvalidOwner, registry.reserve(7, 11, 8, partial_alias));
    try std.testing.expect(idleProjectionValid(&registry));

    var reservation: Reservation = .{};
    try registry.reserve(7, 11, 8, &reservation);
    try std.testing.expect(!registry.release(exact_alias));
    var receipt: CommitReceipt = .{};
    try std.testing.expect(!registry.commit(partial_alias, &receipt));
    try std.testing.expect(registry.release(&reservation));
}

test "busy and exhausted generation preserve pristine output and registry" {
    var registry = Registry.init();
    var first: Reservation = .{};
    try registry.reserve(3, 5, 16, &first);
    var second: Reservation = .{};
    try std.testing.expectError(error.InvalidState, registry.reserve(3, 6, 8, &second));
    try std.testing.expectEqual(Reservation{}, second);
    try std.testing.expect(registry.release(&first));

    registry.next_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.ArithmeticOverflow, registry.reserve(3, 7, 8, &second));
    try std.testing.expectEqual(Registry.State.idle, registry.state);
    try std.testing.expectEqual(Reservation{}, second);
}

test "every reservation scalar and registry mirror drift fails without consumption" {
    var registry = Registry.init();
    var reservation: Reservation = .{};
    try registry.reserve(13, 17, 32, &reservation);

    inline for (.{
        "registry_addr",
        "reservation_generation",
        "process_id",
        "node_incarnation",
        "operation_generation",
        "bytes",
    }) |field_name| {
        var forged = reservation;
        forged.self_addr = @intFromPtr(&forged);
        @field(forged, field_name) +%= 1;
        var receipt: CommitReceipt = .{};
        try std.testing.expect(!registry.commit(&forged, &receipt));
    }
    const saved_bytes = registry.reserved_bytes;
    registry.reserved_bytes +%= 1;
    var drift_receipt: CommitReceipt = .{};
    try std.testing.expect(!registry.commit(&reservation, &drift_receipt));
    registry.reserved_bytes = saved_bytes;
    try std.testing.expect(registry.release(&reservation));
    try std.testing.expectEqual(@as(usize, 0), registry.reserved_reservation_addr);
    try std.testing.expectEqual(@as(u64, 0), registry.reserved_generation);
    try std.testing.expectEqual(@as(u64, 0), registry.reserved_process_id);
    try std.testing.expectEqual(@as(u64, 0), registry.reserved_node_incarnation);
    try std.testing.expectEqual(@as(u64, 0), registry.reserved_operation_generation);
    try std.testing.expectEqual(@as(usize, 0), registry.reserved_bytes);
}

test "idle and reserved projection drift fails closed without overwriting evidence" {
    inline for (.{
        "reserved_reservation_addr",
        "reserved_generation",
        "reserved_process_id",
        "reserved_node_incarnation",
        "reserved_operation_generation",
        "reserved_bytes",
        "committed_bytes",
    }) |field_name| {
        var registry = Registry.init();
        @field(registry, field_name) = 1;
        const before = registry;
        var out: Reservation = .{};
        try std.testing.expectError(error.InvalidState, registry.reserve(31, 37, 1, &out));
        try std.testing.expectEqual(before.state, registry.state);
        try std.testing.expectEqual(@field(before, field_name), @field(registry, field_name));
        try std.testing.expectEqual(Reservation{}, out);
    }
    var zero_generation = Registry.init();
    zero_generation.next_generation = 0;
    var out: Reservation = .{};
    try std.testing.expectError(error.InvalidState, zero_generation.reserve(31, 37, 1, &out));

    var reserved = Registry.init();
    var reservation: Reservation = .{};
    try reserved.reserve(31, 37, 3, &reservation);
    reserved.next_generation +%= 1;
    try std.testing.expect(!reserved.release(&reservation));
    try std.testing.expectEqual(Reservation.Lifecycle.reserved, reservation.lifecycle);
}

test "cross registry is rejected and committed projection clears every reserved mirror" {
    var registry = Registry.init();
    var other = Registry.init();
    var reservation: Reservation = .{};
    try registry.reserve(41, 43, 0, &reservation);
    var other_receipt: CommitReceipt = .{};
    try std.testing.expect(!other.commit(&reservation, &other_receipt));
    var receipt: CommitReceipt = .{};
    try std.testing.expect(registry.commit(&reservation, &receipt));
    try std.testing.expectEqual(Registry.State.committed, registry.state);
    try std.testing.expectEqual(@as(usize, 0), registry.committed_bytes);
    try std.testing.expectEqual(@as(usize, 0), registry.reserved_reservation_addr);
    try std.testing.expectEqual(@as(u64, 0), registry.reserved_generation);
    try std.testing.expectEqual(@as(u64, 0), registry.reserved_process_id);
    try std.testing.expectEqual(@as(u64, 0), registry.reserved_node_incarnation);
    try std.testing.expectEqual(@as(u64, 0), registry.reserved_operation_generation);
    try std.testing.expectEqual(@as(usize, 0), registry.reserved_bytes);
}

test "commit receipt is final-address and consumed proof is exact once" {
    var registry = Registry.init();
    var reservation: Reservation = .{};
    var receipt: CommitReceipt = .{};
    try registry.reserve(41, 43, 128, &reservation);
    try std.testing.expect(registry.commit(&reservation, &receipt));
    try std.testing.expectEqual(CommitReceipt.Lifecycle.committed, receipt.lifecycle);
    try std.testing.expect(committedProjectionValid(&registry));

    var proof: ConsumedCommitProof = .{};
    try std.testing.expect(registry.consumeCommitted(&receipt, &proof));
    try std.testing.expectEqual(CommitReceipt.Lifecycle.consumed, receipt.lifecycle);
    try std.testing.expect(proof.matches(physProcessId(), 41, 43, 128));
    try std.testing.expect(registry.finalization_consumed);
    try std.testing.expectEqual(@as(usize, 0), registry.committed_receipt_addr);

    var replay: ConsumedCommitProof = .{};
    try std.testing.expect(!registry.consumeCommitted(&receipt, &replay));
    try std.testing.expectEqual(ConsumedCommitProof{}, replay);
}

test "commit and consume outputs reject alias and occupied storage before mutation" {
    var registry = Registry.init();
    var reservation: Reservation = .{};
    try registry.reserve(47, 53, 64, &reservation);

    const registry_receipt_alias: *CommitReceipt = @ptrCast(@alignCast(&registry));
    try std.testing.expect(!registry.commit(&reservation, registry_receipt_alias));
    try std.testing.expectEqual(Reservation.Lifecycle.reserved, reservation.lifecycle);

    var occupied: CommitReceipt = .{ .reservation_generation = 1 };
    try std.testing.expect(!registry.commit(&reservation, &occupied));
    try std.testing.expectEqual(@as(u64, 1), occupied.reservation_generation);

    var receipt: CommitReceipt = .{};
    try std.testing.expect(registry.commit(&reservation, &receipt));
    const receipt_proof_alias: *ConsumedCommitProof = @ptrCast(@alignCast(&receipt));
    try std.testing.expect(!registry.consumeCommitted(&receipt, receipt_proof_alias));
    try std.testing.expectEqual(CommitReceipt.Lifecycle.committed, receipt.lifecycle);

    var occupied_proof: ConsumedCommitProof = .{ .reservation_generation = 1 };
    try std.testing.expect(!registry.consumeCommitted(&receipt, &occupied_proof));
    try std.testing.expectEqual(@as(u64, 1), occupied_proof.reservation_generation);
}

test "copied and cross-registry commit receipts cannot mint proof" {
    var registry = Registry.init();
    var reservation: Reservation = .{};
    var receipt: CommitReceipt = .{};
    try registry.reserve(59, 61, 32, &reservation);
    try std.testing.expect(registry.commit(&reservation, &receipt));

    var copied = receipt;
    copied.self_addr = @intFromPtr(&copied);
    var proof: ConsumedCommitProof = .{};
    try std.testing.expect(!registry.consumeCommitted(&copied, &proof));
    var other = Registry.init();
    try std.testing.expect(!other.consumeCommitted(&receipt, &proof));
    try std.testing.expectEqual(ConsumedCommitProof{}, proof);
    try std.testing.expect(registry.consumeCommitted(&receipt, &proof));
}

test "fork child rejects inherited reservation before an inherited locked mutex" {
    var registry = Registry.init();
    var reservation: Reservation = .{};
    try registry.reserve(19, 23, 64, &reservation);
    while (!registry.mutex.tryLock()) std.atomic.spinLoopHint();
    const child = std.c.fork();
    if (child < 0) {
        registry.mutex.unlock();
        return error.SkipZigTest;
    }
    if (child == 0) {
        var receipt: CommitReceipt = .{};
        const rejected = !registry.commit(&reservation, &receipt);
        std.c._exit(if (rejected) 0 else 1);
    }
    const status = waitChildBounded(child) catch |err| {
        registry.mutex.unlock();
        return err;
    };
    registry.mutex.unlock();
    try std.testing.expectEqual(@as(c_int, 0), status);
    try std.testing.expect(registry.release(&reservation));
}

test "fork child rejects committed receipt before an inherited locked mutex" {
    var registry = Registry.init();
    var reservation: Reservation = .{};
    var receipt: CommitReceipt = .{};
    try registry.reserve(67, 71, 64, &reservation);
    try std.testing.expect(registry.commit(&reservation, &receipt));
    while (!registry.mutex.tryLock()) std.atomic.spinLoopHint();
    const child = std.c.fork();
    if (child < 0) {
        registry.mutex.unlock();
        return error.SkipZigTest;
    }
    if (child == 0) {
        var proof: ConsumedCommitProof = .{};
        const rejected = !registry.consumeCommitted(&receipt, &proof);
        std.c._exit(if (rejected) 0 else 1);
    }
    const status = waitChildBounded(child) catch |err| {
        registry.mutex.unlock();
        return err;
    };
    registry.mutex.unlock();
    try std.testing.expectEqual(@as(c_int, 0), status);
    var proof: ConsumedCommitProof = .{};
    try std.testing.expect(registry.consumeCommitted(&receipt, &proof));
}

fn physProcessId() u64 {
    return @intCast(std.c.getpid());
}
