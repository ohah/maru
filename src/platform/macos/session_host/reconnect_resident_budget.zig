//! CR2e-e3a2 reconnect generation resident budget.
//!
//! Screen/metadata 한 세대의 상한은 host `connection_slot`의 기존 base SSOT를 그대로 쓴다.
//! 이 owner는 allocation을 수행하지 않고, candidate가 실제 final-address node에 만들어지기 전에
//! exact byte/count 권위를 예약한다. e3b가 실제 generation initializer와 결속하기 전까지 제품 caller는 0이다.

const std = @import("std");
const connection_slot = @import("connection_slot.zig");
const policy = @import("reconnect_admission_policy.zig");
const reconnect_mutation = @import("reconnect_mutation_seal.zig");
const process_seal = @import("process_seal_service.zig");

extern "c" fn usleep(usec: c_uint) c_int;

pub const max_entry_bytes: usize = connection_slot.base_update_max_bytes;
pub const max_entries: usize = reconnect_mutation.max_mutation_leases;
/// Fixed inventory가 표현할 수 있는 구조적 최대치다. 실제 app-global admission 정책은
/// e3b의 동시 runtime 모델과 결속하기 전까지 이 값으로 선언하지 않는다.
pub const max_tracked_bytes: usize = max_entry_bytes * max_entries;
pub const max_queued_admissions: usize = policy.max_queued_admissions;
pub const max_active_entries: usize = policy.max_active_resident_entries;
pub const max_policy_bytes: usize = policy.max_resident_bytes;

pub const Role = enum(u8) { candidate, current, retiring, retry };
pub const BudgetDomain = enum(u8) { structural_inventory, reconnect_admission };

const Lifecycle = enum(u8) { free, active };

const Entry = struct {
    lifecycle: Lifecycle = .free,
    generation: u64 = 0,
    owner_pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_incarnation: u64 = 0,
    lease_addr: usize = 0,
    bytes: usize = 0,
    role: Role = .candidate,
    domain: BudgetDomain = .structural_inventory,
};

pub const Lease = struct {
    self_addr: usize = 0,
    owner_addr: usize = 0,
    owner_pid: u32 = 0,
    process_nonce: u64 = 0,
    owner_incarnation: u64 = 0,
    slot: u8 = 0,
    generation: u64 = 0,
    bytes: usize = 0,
    role: Role = .candidate,
    domain: BudgetDomain = .structural_inventory,
    active: bool = false,
};

pub const Snapshot = struct {
    live_entries: usize,
    live_bytes: usize,
    peak_entries: usize,
    peak_bytes: usize,
};

var next_budget_owner_incarnation: std.atomic.Value(u64) = .init(1);

fn issueBudgetOwnerIncarnation() ?u64 {
    var observed = next_budget_owner_incarnation.load(.acquire);
    while (observed != 0 and observed != std.math.maxInt(u64)) {
        if (next_budget_owner_incarnation.cmpxchgWeak(
            observed,
            observed + 1,
            .acq_rel,
            .acquire,
        )) |actual| {
            observed = actual;
            continue;
        }
        return observed;
    }
    return null;
}

fn BudgetType(
    comptime domain: BudgetDomain,
    comptime entry_limit: usize,
    comptime byte_limit: usize,
) type {
    return struct {
        const Self = @This();
        self_addr: usize = 0,
        owner_pid: u32 = 0,
        process_nonce: u64 = 0,
        owner_thread: ?std.Thread.Id = null,
        owner_incarnation: u64 = 0,
        next_generation: u64 = 0,
        live_entries: usize = 0,
        live_bytes: usize = 0,
        peak_entries: usize = 0,
        peak_bytes: usize = 0,
        entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,

        pub fn initInPlace(self: *Self, process_nonce: u64) !void {
            if (!std.meta.eql(self.*, Self{}) or process_nonce == 0)
                return error.InvalidAuthority;
            const identity = process_seal.currentReadyIdentity() catch
                return error.InvalidAuthority;
            if (identity.process_nonce != process_nonce) return error.InvalidAuthority;
            const owner_incarnation = issueBudgetOwnerIncarnation() orelse
                return error.IdentityExhausted;
            self.* = .{
                .self_addr = @intFromPtr(self),
                .owner_pid = identity.pid,
                .process_nonce = identity.process_nonce,
                .owner_thread = std.Thread.getCurrentId(),
                .owner_incarnation = owner_incarnation,
                .next_generation = 1,
            };
        }

        pub fn reserve(self: *Self, out: *Lease, bytes: usize, role: Role) !void {
            try self.validateOwner();
            if (rangesOverlap(self, @sizeOf(Self), out, @sizeOf(Lease)) or
                !std.meta.eql(out.*, Lease{})) return error.InvalidAuthority;
            if (role != .candidate and role != .retry) return error.InvalidRole;
            if (bytes == 0 or bytes > max_entry_bytes) return error.ResidentLimit;
            if (self.live_entries >= entry_limit or bytes > byte_limit -| self.live_bytes)
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
                .owner_pid = self.owner_pid,
                .process_nonce = self.process_nonce,
                .owner_incarnation = self.owner_incarnation,
                .lease_addr = @intFromPtr(out),
                .bytes = bytes,
                .role = role,
                .domain = domain,
            };
            out.* = .{
                .self_addr = @intFromPtr(out),
                .owner_addr = self.self_addr,
                .owner_pid = self.owner_pid,
                .process_nonce = self.process_nonce,
                .owner_incarnation = self.owner_incarnation,
                .slot = @intCast(slot),
                .generation = generation,
                .bytes = bytes,
                .role = role,
                .domain = domain,
                .active = true,
            };
        }

        pub fn publishSwap(self: *Self, old_current: ?*Lease, candidate: *Lease) !void {
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

        pub fn release(self: *Self, lease: *Lease, expected_role: Role) !void {
            try self.validateOwner();
            const entry = try self.validateLease(lease, expected_role);
            if (self.live_entries == 0 or self.live_bytes < entry.bytes)
                return error.InvalidAuthority;
            self.live_entries -= 1;
            self.live_bytes -= entry.bytes;
            entry.* = .{};
            lease.* = .{};
        }

        pub fn snapshot(self: *const Self) !Snapshot {
            try self.validateOwner();
            return .{
                .live_entries = self.live_entries,
                .live_bytes = self.live_bytes,
                .peak_entries = self.peak_entries,
                .peak_bytes = self.peak_bytes,
            };
        }

        pub fn validateLeaseRole(self: *Self, lease: *Lease, expected_role: Role) !void {
            try self.validateOwner();
            _ = try self.validateLease(lease, expected_role);
        }

        pub fn canReserveBatch(self: *const Self, count: usize, bytes_each: usize) !bool {
            try self.validateOwner();
            if (count == 0 or bytes_each == 0 or bytes_each > max_entry_bytes) return false;
            const next_entries = std.math.add(usize, self.live_entries, count) catch return false;
            const added_bytes = std.math.mul(usize, count, bytes_each) catch return false;
            const next_bytes = std.math.add(usize, self.live_bytes, added_bytes) catch return false;
            _ = std.math.add(u64, self.next_generation, @as(u64, @intCast(count))) catch return false;
            return next_entries <= entry_limit and next_bytes <= byte_limit;
        }

        pub fn ownedBy(self: *const Self, pid: u32, process_nonce: u64, owner_thread: u64) bool {
            self.validateOwner() catch return false;
            return self.owner_pid == pid and self.process_nonce == process_nonce and
                self.owner_thread == @as(std.Thread.Id, @intCast(owner_thread));
        }

        pub fn deinit(self: *Self) !void {
            try self.validateOwner();
            if (self.live_entries != 0 or self.live_bytes != 0) return error.Busy;
            for (self.entries) |entry| if (entry.lifecycle != .free)
                return error.InvalidAuthority;
            self.* = .{};
        }

        fn validateOwner(self: *const Self) !void {
            const identity = process_seal.currentReadyIdentity() catch
                return error.InvalidAuthority;
            if (self.self_addr != @intFromPtr(self) or self.owner_pid != identity.pid or
                self.process_nonce == 0 or self.process_nonce != identity.process_nonce or
                self.owner_thread == null or self.owner_thread.? != std.Thread.getCurrentId() or
                self.owner_incarnation == 0 or self.next_generation == 0 or
                self.live_entries > entry_limit or
                self.live_bytes > byte_limit or self.peak_entries < self.live_entries or
                self.peak_entries > entry_limit or self.peak_bytes < self.live_bytes or
                self.peak_bytes > byte_limit or !self.inventoryValid())
                return error.InvalidAuthority;
        }

        fn inventoryValid(self: *const Self) bool {
            var counted_entries: usize = 0;
            var counted_bytes: usize = 0;
            for (self.entries, 0..) |entry, index| switch (entry.lifecycle) {
                .free => if (!std.meta.eql(entry, Entry{})) return false,
                .active => {
                    if (entry.generation == 0 or entry.generation >= self.next_generation or
                        entry.owner_pid != self.owner_pid or
                        entry.process_nonce != self.process_nonce or
                        entry.owner_incarnation != self.owner_incarnation or
                        entry.lease_addr == 0 or entry.bytes == 0 or entry.bytes > max_entry_bytes or
                        entry.domain != domain)
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

        fn validateLease(self: *Self, lease: *Lease, expected_role: Role) !*Entry {
            if (rangesOverlap(self, @sizeOf(Self), lease, @sizeOf(Lease)) or
                !lease.active or lease.self_addr != @intFromPtr(lease) or
                lease.owner_addr != self.self_addr or
                lease.owner_pid != self.owner_pid or lease.process_nonce != self.process_nonce or
                lease.owner_incarnation != self.owner_incarnation or
                lease.slot >= max_entries or
                lease.generation == 0 or lease.bytes == 0 or lease.role != expected_role)
                return error.InvalidAuthority;
            const entry = &self.entries[lease.slot];
            if (entry.lifecycle != .active or entry.generation != lease.generation or
                entry.owner_pid != lease.owner_pid or entry.process_nonce != lease.process_nonce or
                entry.owner_incarnation != lease.owner_incarnation or
                entry.lease_addr != lease.self_addr or entry.bytes != lease.bytes or
                entry.role != expected_role or entry.domain != domain or lease.domain != domain)
                return error.InvalidAuthority;
            return entry;
        }
    };
}

pub const ReconnectAdmissionBudget = BudgetType(
    .reconnect_admission,
    max_active_entries,
    max_policy_bytes,
);
const StructuralInventoryBudget = BudgetType(
    .structural_inventory,
    max_entries,
    max_tracked_bytes,
);

fn rangesOverlap(a: *const anyopaque, a_len: usize, b: *const anyopaque, b_len: usize) bool {
    const a_start = @intFromPtr(a);
    const b_start = @intFromPtr(b);
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn readStructuralBudgetFromForeignThread(
    budget: *const StructuralInventoryBudget,
    rejected: *std.atomic.Value(bool),
) void {
    _ = budget.snapshot() catch |err| {
        rejected.store(err == error.InvalidAuthority, .release);
        return;
    };
}

fn readyProcessNonceForTest() !u64 {
    if (process_seal.currentReadyIdentity()) |identity| return identity.process_nonce else |err| switch (err) {
        error.NotReady => {},
        else => return error.TestUnexpectedResult,
    }
    const nonce = try process_seal.generateProcessNonce();
    const receipt = try process_seal.prepare(process_seal.currentProcessId(), nonce);
    process_seal.commitReady(receipt);
    return (try process_seal.currentReadyIdentity()).process_nonce;
}

fn monotonicMsForTest() ?u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0)
        return null;
    return @as(u64, @intCast(ts.sec)) * 1000 +
        @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn readExactBeforeForTest(fd: std.c.fd_t, bytes: []u8, deadline_ms: u64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const now = monotonicMsForTest() orelse return error.TestUnexpectedResult;
        if (now >= deadline_ms) return error.TestUnexpectedResult;
        var ready = std.c.pollfd{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 };
        const polled = std.c.poll(@ptrCast(&ready), 1, @intCast(deadline_ms - now));
        if (polled < 0) {
            if (std.posix.errno(polled) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        if (polled == 0 or ready.revents & (std.c.POLL.ERR | std.c.POLL.NVAL) != 0)
            return error.TestUnexpectedResult;
        const got = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (got < 0) {
            if (std.posix.errno(got) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        if (got == 0) return error.TestUnexpectedResult;
        offset += @intCast(got);
    }
}

fn reapChildForTest(pid: std.c.pid_t, terminate: bool, reaped: *bool) !u32 {
    var sent_kill = false;
    var polls: usize = 0;
    while (polls < 2_000) : (polls += 1) {
        var status: c_int = 0;
        const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (waited == pid) {
            reaped.* = true;
            return @bitCast(status);
        }
        if (waited < 0) {
            if (std.posix.errno(waited) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        if (terminate and !sent_kill) {
            const killed = std.c.kill(pid, std.c.SIG.KILL);
            if (killed != 0) switch (std.posix.errno(killed)) {
                .INTR => continue,
                .SRCH => {},
                else => return error.TestUnexpectedResult,
            };
            sent_kill = true;
        }
        _ = usleep(1_000);
    }
    return error.TestUnexpectedResult;
}

test "CR2e-e3a2 resident budget은 fixed inventory byte bound와 cap plus one을 mutation 없이 닫는다" {
    const process_nonce = try readyProcessNonceForTest();
    var budget: StructuralInventoryBudget = .{};
    try budget.initInPlace(process_nonce);
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
    const process_nonce = try readyProcessNonceForTest();
    var budget: StructuralInventoryBudget = .{};
    try budget.initInPlace(process_nonce);
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
    const process_nonce = try readyProcessNonceForTest();
    var budget: StructuralInventoryBudget = .{};
    try budget.initInPlace(process_nonce);
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
    const process_nonce = try readyProcessNonceForTest();
    var budget: StructuralInventoryBudget = .{};
    try budget.initInPlace(process_nonce);
    var copied = budget;
    var rejected: Lease = .{};
    try std.testing.expectError(error.InvalidAuthority, copied.reserve(&rejected, 1, .candidate));
    try std.testing.expect(std.meta.eql(rejected, Lease{}));
    const identity_before = try budget.snapshot();
    var thread_rejected = std.atomic.Value(bool).init(false);
    var thread = try std.Thread.spawn(
        .{},
        readStructuralBudgetFromForeignThread,
        .{ &budget, &thread_rejected },
    );
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
    const process_nonce = try readyProcessNonceForTest();
    var budget: StructuralInventoryBudget = .{};
    try budget.initInPlace(process_nonce);
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

test "CR2e-e3b1 reconnect admission budget은 128 MiB와 max charge 일곱 개를 고정한다" {
    const process_nonce = try readyProcessNonceForTest();
    try std.testing.expectEqual(@as(usize, 128 * 1024 * 1024), max_policy_bytes);
    try std.testing.expectEqual(@as(usize, 64), max_queued_admissions);
    try std.testing.expectEqual(@as(usize, 8), max_active_entries);
    try std.testing.expectEqual(@as(usize, 7), max_policy_bytes / max_entry_bytes);

    var budget: ReconnectAdmissionBudget = .{};
    try budget.initInPlace(process_nonce);
    var leases: [8]Lease = [_]Lease{.{}} ** 8;
    for (leases[0..7]) |*lease| try budget.reserve(lease, max_entry_bytes, .candidate);
    const at_cap = try budget.snapshot();
    const owner_at_cap = budget;
    const leases_at_cap = leases;
    try std.testing.expectEqual(@as(usize, 7), at_cap.live_entries);
    try std.testing.expectEqual(7 * max_entry_bytes, at_cap.live_bytes);
    try std.testing.expectError(
        error.ResidentLimit,
        budget.reserve(&leases[7], max_entry_bytes, .candidate),
    );
    try std.testing.expect(std.meta.eql(leases[7], Lease{}));
    try std.testing.expectEqualDeep(at_cap, try budget.snapshot());
    try std.testing.expectEqualDeep(owner_at_cap, budget);
    try std.testing.expectEqualDeep(leases_at_cap, leases);
    const stale_same_address = leases[0];
    for (leases[0..7]) |*lease| try budget.release(lease, .candidate);
    try std.testing.expectEqualDeep([_]Lease{.{}} ** 8, leases);
    try budget.deinit();
    try budget.initInPlace(process_nonce);
    try budget.reserve(&leases[0], max_entry_bytes, .candidate);
    const current_same_address = leases[0];
    try std.testing.expect(current_same_address.owner_incarnation != stale_same_address.owner_incarnation);
    const before_stale_replay = budget;
    leases[0] = stale_same_address;
    try std.testing.expectError(error.InvalidAuthority, budget.release(&leases[0], .candidate));
    try std.testing.expectEqualDeep(before_stale_replay, budget);
    leases[0] = current_same_address;
    try budget.release(&leases[0], .candidate);

    var small: [9]Lease = [_]Lease{.{}} ** 9;
    for (small[0..max_active_entries]) |*lease| try budget.reserve(lease, 1, .candidate);
    const at_count_cap = try budget.snapshot();
    const owner_at_count_cap = budget;
    const small_at_count_cap = small;
    try std.testing.expectError(error.ResidentLimit, budget.reserve(&small[8], 1, .candidate));
    try std.testing.expect(std.meta.eql(small[8], Lease{}));
    try std.testing.expectEqualDeep(at_count_cap, try budget.snapshot());
    try std.testing.expectEqualDeep(owner_at_count_cap, budget);
    try std.testing.expectEqualDeep(small_at_count_cap, small);
    for (small[0..max_active_entries]) |*lease| try budget.release(lease, .candidate);
    try std.testing.expectEqualDeep([_]Lease{.{}} ** 9, small);
    try budget.deinit();
    try std.testing.expectEqualDeep(ReconnectAdmissionBudget{}, budget);

    var splice_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&splice_pipe));
    var read_open = true;
    var write_open = true;
    defer if (read_open) {
        _ = std.c.close(splice_pipe[0]);
    };
    defer if (write_open) {
        _ = std.c.close(splice_pipe[1]);
    };
    var cross_budget: ReconnectAdmissionBudget = .{};
    var cross_lease: Lease = .{};
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = std.c.close(splice_pipe[0]);
        process_seal.testing_api.resetInheritedForkedDaemonProcessSealIfPresent() catch
            std.c._exit(75);
        const child_nonce = process_seal.generateProcessNonce() catch std.c._exit(75);
        const receipt = process_seal.prepare(process_seal.currentProcessId(), child_nonce) catch
            std.c._exit(75);
        process_seal.commitReady(receipt);
        cross_budget.initInPlace(child_nonce) catch std.c._exit(75);
        cross_budget.reserve(&cross_lease, 1, .candidate) catch std.c._exit(75);
        const bytes = std.mem.asBytes(&cross_lease);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const wrote = std.c.write(
                splice_pipe[1],
                bytes[offset..].ptr,
                bytes.len - offset,
            );
            if (wrote <= 0) std.c._exit(75);
            offset += @intCast(wrote);
        }
        std.c._exit(86);
    }
    var child_reaped = false;
    defer if (!child_reaped) {
        _ = reapChildForTest(child, true, &child_reaped) catch
            @panic("reconnect budget fork child cleanup failed");
    };
    _ = std.c.close(splice_pipe[1]);
    write_open = false;
    try cross_budget.initInPlace(process_nonce);
    try cross_budget.reserve(&cross_lease, 1, .candidate);
    const parent_lease = cross_lease;
    var child_lease: Lease = undefined;
    const child_bytes = std.mem.asBytes(&child_lease);
    const read_started = monotonicMsForTest() orelse return error.TestUnexpectedResult;
    const read_deadline = std.math.add(u64, read_started, 2_000) catch
        return error.TestUnexpectedResult;
    try readExactBeforeForTest(splice_pipe[0], child_bytes, read_deadline);
    _ = std.c.close(splice_pipe[0]);
    read_open = false;
    const raw_status = try reapChildForTest(child, false, &child_reaped);
    try std.testing.expect(std.c.W.IFEXITED(raw_status));
    try std.testing.expectEqual(@as(u8, 86), std.c.W.EXITSTATUS(raw_status));
    try std.testing.expectEqual(parent_lease.self_addr, child_lease.self_addr);
    try std.testing.expectEqual(parent_lease.owner_addr, child_lease.owner_addr);
    try std.testing.expectEqual(parent_lease.owner_incarnation, child_lease.owner_incarnation);
    try std.testing.expect(parent_lease.owner_pid != child_lease.owner_pid);
    try std.testing.expect(parent_lease.process_nonce != child_lease.process_nonce);
    const before_child_splice = cross_budget;
    cross_lease = child_lease;
    try std.testing.expectError(
        error.InvalidAuthority,
        cross_budget.release(&cross_lease, .candidate),
    );
    try std.testing.expectEqualDeep(before_child_splice, cross_budget);
    cross_lease = parent_lease;
    try cross_budget.release(&cross_lease, .candidate);
    try cross_budget.deinit();
}

comptime {
    if (max_entries != 64) @compileError("reconnect resident entry cap drifted from mutation lease cap");
    if (max_tracked_bytes != max_entries * max_entry_bytes)
        @compileError("reconnect resident tracked byte bound drifted from fixed inventory");
    if (max_queued_admissions != 64 or max_active_entries != 8 or
        max_active_entries > max_queued_admissions or max_policy_bytes != 128 * 1024 * 1024)
        @compileError("reconnect admission policy drifted");
}
