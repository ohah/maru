//! CR2e-e3a2 reconnect generation resident budget.
//!
//! Screen/metadata 한 세대의 상한은 host `connection_slot`의 기존 base SSOT를 그대로 쓴다.
//! 이 owner는 allocation을 수행하지 않고, candidate가 실제 final-address node에 만들어지기 전에
//! exact byte/count 권위를 예약한다. e3b가 실제 generation initializer와 결속하기 전까지 제품 caller는 0이다.

const std = @import("std");
const connection_slot = @import("connection_slot.zig");
const reconnect_mutation = @import("reconnect_mutation_seal.zig");

pub const max_entry_bytes: usize = connection_slot.base_update_max_bytes;
pub const max_entries: usize = reconnect_mutation.max_mutation_leases;
/// Fixed inventory가 표현할 수 있는 구조적 최대치다. 실제 app-global admission 정책은
/// e3b의 동시 runtime 모델과 결속하기 전까지 이 값으로 선언하지 않는다.
pub const max_tracked_bytes: usize = max_entry_bytes * max_entries;

pub const Role = enum(u8) { candidate, current, retiring, retry };

const Lifecycle = enum(u8) { free, active };

const Entry = struct {
    lifecycle: Lifecycle = .free,
    generation: u64 = 0,
    lease_addr: usize = 0,
    bytes: usize = 0,
    role: Role = .candidate,
};

pub const Lease = struct {
    self_addr: usize = 0,
    owner_addr: usize = 0,
    slot: u8 = 0,
    generation: u64 = 0,
    bytes: usize = 0,
    role: Role = .candidate,
    active: bool = false,
};

pub const Snapshot = struct {
    live_entries: usize,
    live_bytes: usize,
    peak_entries: usize,
    peak_bytes: usize,
};

pub const Budget = struct {
    self_addr: usize = 0,
    owner_pid: std.posix.pid_t = 0,
    owner_thread: ?std.Thread.Id = null,
    next_generation: u64 = 0,
    live_entries: usize = 0,
    live_bytes: usize = 0,
    peak_entries: usize = 0,
    peak_bytes: usize = 0,
    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,

    pub fn initInPlace(self: *Budget) !void {
        if (!std.meta.eql(self.*, Budget{})) return error.InvalidAuthority;
        self.* = .{
            .self_addr = @intFromPtr(self),
            .owner_pid = std.c.getpid(),
            .owner_thread = std.Thread.getCurrentId(),
            .next_generation = 1,
        };
    }

    pub fn reserve(self: *Budget, out: *Lease, bytes: usize, role: Role) !void {
        try self.validateOwner();
        if (rangesOverlap(self, @sizeOf(Budget), out, @sizeOf(Lease)) or
            !std.meta.eql(out.*, Lease{})) return error.InvalidAuthority;
        if (role != .candidate and role != .retry) return error.InvalidRole;
        if (bytes == 0 or bytes > max_entry_bytes) return error.ResidentLimit;
        if (self.live_entries >= max_entries or bytes > max_tracked_bytes -| self.live_bytes)
            return error.ResidentLimit;
        const slot = for (&self.entries, 0..) |*entry, index| {
            if (entry.lifecycle == .free) break index;
        } else return error.ResidentLimit;
        const generation = self.next_generation;
        const next_generation = std.math.add(u64, generation, 1) catch
            return error.IdentityExhausted;
        const next_entries = std.math.add(usize, self.live_entries, 1) catch
            return error.ResidentLimit;
        const next_bytes = std.math.add(usize, self.live_bytes, bytes) catch
            return error.ResidentLimit;
        self.next_generation = next_generation;
        self.live_entries = next_entries;
        self.live_bytes = next_bytes;
        self.peak_entries = @max(self.peak_entries, next_entries);
        self.peak_bytes = @max(self.peak_bytes, next_bytes);
        self.entries[slot] = .{
            .lifecycle = .active,
            .generation = generation,
            .lease_addr = @intFromPtr(out),
            .bytes = bytes,
            .role = role,
        };
        out.* = .{
            .self_addr = @intFromPtr(out),
            .owner_addr = self.self_addr,
            .slot = @intCast(slot),
            .generation = generation,
            .bytes = bytes,
            .role = role,
            .active = true,
        };
    }

    pub fn publishSwap(self: *Budget, old_current: ?*Lease, candidate: *Lease) !void {
        try self.validateOwner();
        const candidate_entry = try self.validateLease(candidate, .candidate);
        const old_entry = if (old_current) |old| try self.validateLease(old, .current) else null;
        if (old_current) |old| {
            if (rangesOverlap(old, @sizeOf(Lease), candidate, @sizeOf(Lease)))
                return error.InvalidAuthority;
        }
        if (old_entry) |entry| {
            entry.role = .retiring;
            old_current.?.role = .retiring;
        }
        candidate_entry.role = .current;
        candidate.role = .current;
    }

    pub fn release(self: *Budget, lease: *Lease, expected_role: Role) !void {
        try self.validateOwner();
        const entry = try self.validateLease(lease, expected_role);
        if (self.live_entries == 0 or self.live_bytes < entry.bytes)
            return error.InvalidAuthority;
        self.live_entries -= 1;
        self.live_bytes -= entry.bytes;
        entry.* = .{};
        lease.* = .{};
    }

    pub fn snapshot(self: *const Budget) !Snapshot {
        try self.validateOwner();
        return .{
            .live_entries = self.live_entries,
            .live_bytes = self.live_bytes,
            .peak_entries = self.peak_entries,
            .peak_bytes = self.peak_bytes,
        };
    }

    pub fn deinit(self: *Budget) !void {
        try self.validateOwner();
        if (self.live_entries != 0 or self.live_bytes != 0) return error.Busy;
        for (self.entries) |entry| if (entry.lifecycle != .free)
            return error.InvalidAuthority;
        self.* = .{};
    }

    fn validateOwner(self: *const Budget) !void {
        if (self.self_addr != @intFromPtr(self) or self.owner_pid != std.c.getpid() or
            self.owner_thread == null or self.owner_thread.? != std.Thread.getCurrentId() or
            self.next_generation == 0 or self.live_entries > max_entries or
            self.live_bytes > max_tracked_bytes or self.peak_entries < self.live_entries or
            self.peak_entries > max_entries or self.peak_bytes < self.live_bytes or
            self.peak_bytes > max_tracked_bytes or !self.inventoryValid())
            return error.InvalidAuthority;
    }

    fn inventoryValid(self: *const Budget) bool {
        var counted_entries: usize = 0;
        var counted_bytes: usize = 0;
        for (self.entries, 0..) |entry, index| switch (entry.lifecycle) {
            .free => if (!std.meta.eql(entry, Entry{})) return false,
            .active => {
                if (entry.generation == 0 or entry.generation >= self.next_generation or
                    entry.lease_addr == 0 or entry.bytes == 0 or entry.bytes > max_entry_bytes)
                    return false;
                counted_entries = std.math.add(usize, counted_entries, 1) catch return false;
                counted_bytes = std.math.add(usize, counted_bytes, entry.bytes) catch return false;
                for (self.entries[0..index]) |previous| {
                    if (previous.lifecycle == .active and
                        (previous.generation == entry.generation or
                            previous.lease_addr == entry.lease_addr)) return false;
                }
            },
        };
        return counted_entries == self.live_entries and counted_bytes == self.live_bytes;
    }

    fn validateLease(self: *Budget, lease: *Lease, expected_role: Role) !*Entry {
        if (rangesOverlap(self, @sizeOf(Budget), lease, @sizeOf(Lease)) or
            !lease.active or lease.self_addr != @intFromPtr(lease) or
            lease.owner_addr != self.self_addr or lease.slot >= max_entries or
            lease.generation == 0 or lease.bytes == 0 or lease.role != expected_role)
            return error.InvalidAuthority;
        const entry = &self.entries[lease.slot];
        if (entry.lifecycle != .active or entry.generation != lease.generation or
            entry.lease_addr != lease.self_addr or entry.bytes != lease.bytes or
            entry.role != expected_role) return error.InvalidAuthority;
        return entry;
    }
};

fn rangesOverlap(a: *const anyopaque, a_len: usize, b: *const anyopaque, b_len: usize) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn readBudgetFromForeignThread(budget: *const Budget, rejected: *std.atomic.Value(bool)) void {
    _ = budget.snapshot() catch |err| {
        rejected.store(err == error.InvalidAuthority, .release);
        return;
    };
}

test "CR2e-e3a2 resident budget은 fixed inventory byte bound와 cap plus one을 mutation 없이 닫는다" {
    var budget: Budget = .{};
    try budget.initInPlace();
    var leases: [max_entries]Lease = [_]Lease{.{}} ** max_entries;
    for (&leases) |*lease| try budget.reserve(lease, max_entry_bytes, .candidate);
    const at_cap = try budget.snapshot();
    try std.testing.expectEqual(max_tracked_bytes, at_cap.live_bytes);
    try std.testing.expectEqual(max_entries, at_cap.live_entries);
    var rejected: Lease = .{};
    try std.testing.expectError(error.ResidentLimit, budget.reserve(&rejected, 1, .candidate));
    try std.testing.expect(std.meta.eql(rejected, Lease{}));
    try std.testing.expectEqualDeep(at_cap, try budget.snapshot());
    for (&leases) |*lease| try budget.release(lease, .candidate);
    try budget.deinit();
}

test "CR2e-e3a2 resident budget은 entry exact cap과 copied lease replay를 거부한다" {
    var budget: Budget = .{};
    try budget.initInPlace();
    var leases: [max_entries]Lease = [_]Lease{.{}} ** max_entries;
    for (&leases) |*lease| try budget.reserve(lease, 1, .candidate);
    var rejected: Lease = .{};
    try std.testing.expectError(error.ResidentLimit, budget.reserve(&rejected, 1, .candidate));
    const before = try budget.snapshot();
    var copied = leases[0];
    try std.testing.expectError(error.InvalidAuthority, budget.release(&copied, .candidate));
    try std.testing.expectEqualDeep(before, try budget.snapshot());
    for (&leases) |*lease| try budget.release(lease, .candidate);
    try budget.deinit();
}

test "CR2e-e3a2 resident budget은 candidate current retiring swap과 final zero를 고정한다" {
    var budget: Budget = .{};
    try budget.initInPlace();
    var first: Lease = .{};
    try budget.reserve(&first, 7, .candidate);
    try budget.publishSwap(null, &first);
    try std.testing.expectEqual(Role.current, first.role);
    var second: Lease = .{};
    try budget.reserve(&second, 11, .candidate);
    var copied_first = first;
    const before_rejected_swap = try budget.snapshot();
    try std.testing.expectError(
        error.InvalidAuthority,
        budget.publishSwap(&copied_first, &second),
    );
    try std.testing.expectEqualDeep(before_rejected_swap, try budget.snapshot());
    try std.testing.expectEqual(Role.current, first.role);
    try std.testing.expectEqual(Role.candidate, second.role);
    try budget.publishSwap(&first, &second);
    try std.testing.expectEqual(Role.retiring, first.role);
    try std.testing.expectEqual(Role.current, second.role);
    var retry: Lease = .{};
    try budget.reserve(&retry, 3, .retry);
    try std.testing.expectEqual(Role.retry, retry.role);
    try budget.release(&retry, .retry);
    try budget.release(&first, .retiring);
    try budget.release(&second, .current);
    const final = try budget.snapshot();
    try std.testing.expectEqual(@as(usize, 0), final.live_entries);
    try std.testing.expectEqual(@as(usize, 0), final.live_bytes);
    try std.testing.expectEqual(@as(usize, 3), final.peak_entries);
    try std.testing.expectEqual(@as(usize, 21), final.peak_bytes);
    try budget.deinit();
}

test "CR2e-e3a2 resident budget은 copied owner와 identity exhaustion을 mutation 없이 거부한다" {
    var budget: Budget = .{};
    try budget.initInPlace();
    var copied = budget;
    var rejected: Lease = .{};
    try std.testing.expectError(error.InvalidAuthority, copied.reserve(&rejected, 1, .candidate));
    try std.testing.expect(std.meta.eql(rejected, Lease{}));
    const identity_before = try budget.snapshot();
    var thread_rejected = std.atomic.Value(bool).init(false);
    var thread = try std.Thread.spawn(.{}, readBudgetFromForeignThread, .{ &budget, &thread_rejected });
    thread.join();
    try std.testing.expect(thread_rejected.load(.acquire));
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = budget.snapshot() catch |err| std.c._exit(if (err == error.InvalidAuthority) 86 else 75);
        std.c._exit(75);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    const raw: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(raw));
    try std.testing.expectEqual(@as(u8, 86), std.c.W.EXITSTATUS(raw));
    try std.testing.expectEqualDeep(identity_before, try budget.snapshot());
    budget.next_generation = std.math.maxInt(u64);
    const before = try budget.snapshot();
    try std.testing.expectError(error.IdentityExhausted, budget.reserve(&rejected, 1, .candidate));
    try std.testing.expectEqualDeep(before, try budget.snapshot());
    budget.next_generation = 1;
    try budget.deinit();
}

test "CR2e-e3a2 resident budget은 fixed entry inventory drift를 공개 projection 전에 거부한다" {
    var budget: Budget = .{};
    try budget.initInPlace();
    var lease: Lease = .{};
    try budget.reserve(&lease, 7, .candidate);
    budget.peak_bytes = 0;
    try std.testing.expectError(error.InvalidAuthority, budget.snapshot());
    budget.peak_bytes = 7;
    budget.entries[lease.slot].bytes += 1;
    try std.testing.expectError(error.InvalidAuthority, budget.snapshot());
    try std.testing.expectError(error.InvalidAuthority, budget.release(&lease, .candidate));
    budget.entries[lease.slot].bytes -= 1;
    try budget.release(&lease, .candidate);
    try budget.deinit();
}

comptime {
    if (max_entries != 64) @compileError("reconnect resident entry cap drifted from mutation lease cap");
    if (max_tracked_bytes != max_entries * max_entry_bytes)
        @compileError("reconnect resident tracked byte bound drifted from fixed inventory");
}
