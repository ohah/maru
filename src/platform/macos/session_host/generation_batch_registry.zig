//! Generation GUI attachment가 인출한 화면 batch의 node-local canonical owner.
//!
//! 이 leaf는 Client, socket, GUI callback을 알지 않는다. attachment에는 pointer-free token만 내보내고,
//! 실제 payload descriptor와 accounting receipt는 final-address registry 안에 남긴다.

const std = @import("std");
const builtin = @import("builtin");
const process_identity = @import("process_identity.zig");

pub const max_entries: usize = 4096;

pub const Token = struct {
    registry_incarnation: u64,
    entry_slot: u16,
    entry_generation: u64,
    stream_id: u64,
};

pub const Reservation = Token;

pub const AccountingReceipt = struct {
    client_addr: usize,
    transfer_id: u64,
    byte_count: usize,
};

pub const GenerationReleaseResult = enum(u8) {
    completed,
    retryable_preserved,
    indeterminate_or_partial,
};

const PreparedReleaseLifecycle = enum(u8) { pristine, prepared, consumed, aborted };

/// 실제 registry row를 움직이기 전에 token과 accounting을 final-address scratch에 고정한다.
/// retryable 결과는 이 permit을 abort해 live row를 그대로 보존한 경우에만 발행할 수 있다.
pub const PreparedRelease = struct {
    self_addr: usize = 0,
    token: Token = std.mem.zeroes(Token),
    accounting: AccountingReceipt = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 },
    lifecycle: PreparedReleaseLifecycle = .pristine,

    pub fn pristine(self: *const PreparedRelease) bool {
        return self.self_addr == 0 and self.lifecycle == .pristine and
            self.accounting.client_addr == 0 and self.accounting.transfer_id == 0 and
            self.accounting.byte_count == 0;
    }
};

const TestingRetryableRelease = struct {
    registry_addr: usize = 0,
    token: Token = std.mem.zeroes(Token),
};
threadlocal var testing_retryable_release: TestingRetryableRelease = .{};

pub const testing = if (builtin.is_test) struct {
    pub fn armNextRetryable(registry: *Registry, token: Token) void {
        if (testing_retryable_release.registry_addr != 0)
            @panic("generation release test verdict is not pristine");
        testing_retryable_release = .{
            .registry_addr = @intFromPtr(registry),
            .token = token,
        };
    }
} else struct {};

const OwnedLifecycle = enum(u8) { empty, live, cleanup, settled };

pub const OwnedBatch = struct {
    self_addr: usize = 0,
    lifecycle: OwnedLifecycle = .empty,
    is_snapshot: bool = false,
    stream_id: u64 = 0,
    bytes: []u8 = &.{},
    allocator: ?std.mem.Allocator = null,
    accounting: AccountingReceipt = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 },

    pub fn initInPlace(
        out: *OwnedBatch,
        is_snapshot: bool,
        stream_id: u64,
        bytes: []u8,
        allocator: std.mem.Allocator,
        accounting: AccountingReceipt,
    ) Error!void {
        if (!out.pristine()) return error.DestinationOccupied;
        if (stream_id == 0 or bytes.len == 0 or accounting.client_addr == 0 or
            accounting.transfer_id == 0 or accounting.byte_count != bytes.len)
            return error.InvalidDescriptor;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .lifecycle = .live,
            .is_snapshot = is_snapshot,
            .stream_id = stream_id,
            .bytes = bytes,
            .allocator = allocator,
            .accounting = accounting,
        };
    }

    pub fn completeCleanup(self: *OwnedBatch) Error!void {
        if (self.self_addr != @intFromPtr(self) or self.lifecycle != .cleanup or
            self.bytes.len != 0 or self.allocator != null or self.accounting.client_addr != 0 or
            self.accounting.transfer_id != 0 or self.accounting.byte_count != 0)
            return error.InvalidDescriptor;
        self.lifecycle = .settled;
    }

    /// Callback 전 preflight와 descriptor move가 끝난 제품 release의 무검증 suffix다.
    pub fn completeCleanupUnchecked(self: *OwnedBatch) void {
        self.lifecycle = .settled;
    }

    pub fn pristine(self: *const OwnedBatch) bool {
        return self.self_addr == 0 and self.lifecycle == .empty and self.stream_id == 0 and
            self.bytes.len == 0 and self.allocator == null and self.accounting.client_addr == 0 and
            self.accounting.transfer_id == 0 and self.accounting.byte_count == 0;
    }

    fn validLive(self: *const OwnedBatch) bool {
        return self.self_addr == @intFromPtr(self) and self.lifecycle == .live and
            self.stream_id != 0 and self.bytes.len != 0 and self.allocator != null and
            self.accounting.client_addr != 0 and self.accounting.transfer_id != 0 and
            self.accounting.byte_count == self.bytes.len;
    }

    fn settle(self: *OwnedBatch) void {
        self.* = .{};
    }

    /// Client가 accounting reservation을 먼저 끝낸 뒤 실행하는 무실패 publication suffix다.
    pub fn initTransferredUnchecked(
        out: *OwnedBatch,
        is_snapshot: bool,
        stream_id: u64,
        bytes: []u8,
        allocator: std.mem.Allocator,
        accounting: AccountingReceipt,
    ) void {
        if (!out.pristine() or stream_id == 0 or bytes.len == 0 or
            accounting.client_addr == 0 or accounting.transfer_id == 0 or
            accounting.byte_count != bytes.len)
            @panic("invalid generation batch publication");
        out.* = .{
            .self_addr = @intFromPtr(out),
            .lifecycle = .live,
            .is_snapshot = is_snapshot,
            .stream_id = stream_id,
            .bytes = bytes,
            .allocator = allocator,
            .accounting = accounting,
        };
    }
};

pub const BatchView = struct {
    is_snapshot: bool,
    stream_id: u64,
    bytes: []const u8,
};

pub const Error = error{
    CapacityExhausted,
    DestinationOccupied,
    IdentityExhausted,
    InvalidDescriptor,
    InvalidIdentity,
    InvalidReservation,
    InvalidState,
    InvalidStream,
    MovedOrCopied,
};

pub const DeinitOutcome = enum { cleaned, busy, already_dead, corrupt };

const AccountingLifecycle = enum(u8) { pristine, live, dead };
const AccountingEntryLifecycle = enum(u8) { empty, live, releasing };
pub const AllocatorScopePurpose = enum(u8) {
    attachment_batch,
    initial_snapshot,
    rpc_prepare,
    rpc_execute,
};
const allocator_scope_purpose_max: u8 = @intFromEnum(AllocatorScopePurpose.rpc_execute);
const AllocatorScopeState = enum { idle, active, invalid };

const AllocatorScopeAuthority = struct {
    ledger_addr: usize = 0,
    client_addr: usize = 0,
    token_addr: usize = 0,
    epoch: u64 = 0,
    purpose_raw: u8 = 0,
    previous: ?std.mem.Allocator = null,
    installed: ?std.mem.Allocator = null,
    generation: u64 = 0,
};

var allocator_scope_authority_mutex: std.atomic.Mutex = .unlocked;
var allocator_scope_authorities: [max_entries]AllocatorScopeAuthority =
    [_]AllocatorScopeAuthority{.{}} ** max_entries;
var allocator_scope_authority_generation: u64 = 0;
var allocator_scope_authority_process_id: std.atomic.Value(u32) = .init(0);

fn allocatorScopeProcessMatches() bool {
    const current = process_identity.currentProcessId();
    if (current == 0) return false;
    const observed = allocator_scope_authority_process_id.load(.acquire);
    if (observed == current) return true;
    if (observed != 0) return false;
    return allocator_scope_authority_process_id.cmpxchgStrong(
        0,
        current,
        .acq_rel,
        .acquire,
    ) == null;
}

pub const PreparedAccountingConsume = struct {
    ledger_slot: u16,
    transfer_id: u64,
    byte_count: usize,
};

const AccountingEntry = struct {
    lifecycle: AccountingEntryLifecycle = .empty,
    transfer_id: u64 = 0,
    byte_count: usize = 0,
};

/// `Client`가 단독으로 조작하고 generation node가 final-address storage를 제공하는 exact receipt ledger.
pub const AccountingLedger = struct {
    self_addr: usize = 0,
    client_addr: usize = 0,
    item_count: usize = 0,
    byte_count: usize = 0,
    releasing_item_count: usize = 0,
    releasing_byte_count: usize = 0,
    lifecycle: AccountingLifecycle = .pristine,
    allocator_scope_token_addr: usize = 0,
    allocator_scope_epoch: u64 = 0,
    allocator_scope_purpose_raw: u8 = 0,
    allocator_scope_previous: ?std.mem.Allocator = null,
    allocator_scope_installed: ?std.mem.Allocator = null,
    allocator_scope_authority_slot: u16 = 0,
    allocator_scope_authority_generation: u64 = 0,
    entries: [max_entries]AccountingEntry = [_]AccountingEntry{.{}} ** max_entries,

    pub fn initInPlace(out: *AccountingLedger) Error!void {
        if (out.self_addr != 0 or out.lifecycle != .pristine) return error.InvalidState;
        out.* = .{ .self_addr = @intFromPtr(out), .lifecycle = .live };
    }

    pub fn bindClient(self: *AccountingLedger, client_addr: usize) Error!void {
        if (!self.valid() or self.client_addr != 0 or client_addr == 0)
            return error.InvalidState;
        self.client_addr = client_addr;
    }

    fn valid(self: *const AccountingLedger) bool {
        return self.self_addr == @intFromPtr(self) and self.lifecycle == .live and
            self.item_count <= max_entries and self.releasing_item_count <= self.item_count and
            self.releasing_byte_count <= self.byte_count and self.allocatorScopeState() != .invalid;
    }

    fn allocatorScopeState(self: *const AccountingLedger) AllocatorScopeState {
        const idle = self.allocator_scope_token_addr == 0 and self.allocator_scope_epoch == 0 and
            self.allocator_scope_purpose_raw == 0 and self.allocator_scope_previous == null and
            self.allocator_scope_installed == null and self.allocator_scope_authority_slot == 0 and
            self.allocator_scope_authority_generation == 0;
        if (idle) return .idle;
        const active = self.allocator_scope_token_addr != 0 and self.allocator_scope_epoch != 0 and
            self.allocator_scope_purpose_raw <= allocator_scope_purpose_max and
            self.allocator_scope_previous != null and self.allocator_scope_installed != null and
            self.allocator_scope_authority_slot != 0 and self.allocator_scope_authority_generation != 0;
        return if (active) .active else .invalid;
    }

    pub fn matchesClient(self: *const AccountingLedger, client_addr: usize) bool {
        return self.valid() and self.client_addr == client_addr and client_addr != 0;
    }

    pub fn beginAllocatorScope(
        self: *AccountingLedger,
        client_addr: usize,
        token_addr: usize,
        epoch: u64,
        purpose_raw: u8,
        previous: std.mem.Allocator,
        installed: std.mem.Allocator,
    ) Error!void {
        if (!self.matchesClient(client_addr) or token_addr == 0 or epoch == 0 or
            purpose_raw > allocator_scope_purpose_max or self.allocatorScopeState() != .idle)
            return error.InvalidState;
        if (!allocatorScopeProcessMatches()) return error.InvalidState;
        while (!allocator_scope_authority_mutex.tryLock()) std.atomic.spinLoopHint();
        defer allocator_scope_authority_mutex.unlock();
        const slot = for (&allocator_scope_authorities, 0..) |*entry, index| {
            if (entry.ledger_addr == 0) break index;
        } else return error.CapacityExhausted;
        const generation = std.math.add(u64, allocator_scope_authority_generation, 1) catch
            return error.IdentityExhausted;
        if (generation == 0) return error.IdentityExhausted;
        allocator_scope_authorities[slot] = .{
            .ledger_addr = @intFromPtr(self),
            .client_addr = client_addr,
            .token_addr = token_addr,
            .epoch = epoch,
            .purpose_raw = purpose_raw,
            .previous = previous,
            .installed = installed,
            .generation = generation,
        };
        allocator_scope_authority_generation = generation;
        self.allocator_scope_token_addr = token_addr;
        self.allocator_scope_epoch = epoch;
        self.allocator_scope_purpose_raw = purpose_raw;
        self.allocator_scope_previous = previous;
        self.allocator_scope_installed = installed;
        self.allocator_scope_authority_slot = @intCast(slot + 1);
        self.allocator_scope_authority_generation = generation;
    }

    pub fn allocatorScopeMatches(
        self: *const AccountingLedger,
        client_addr: usize,
        token_addr: usize,
        epoch: u64,
        purpose_raw: u8,
        previous: std.mem.Allocator,
        installed: std.mem.Allocator,
    ) bool {
        if (!(self.matchesClient(client_addr) and self.allocatorScopeState() == .active and
            token_addr != 0 and epoch != 0 and purpose_raw <= allocator_scope_purpose_max and
            self.allocator_scope_token_addr == token_addr and self.allocator_scope_epoch == epoch and
            self.allocator_scope_purpose_raw == purpose_raw and
            allocatorEql(self.allocator_scope_previous orelse return false, previous) and
            allocatorEql(self.allocator_scope_installed orelse return false, installed))) return false;
        if (!allocatorScopeProcessMatches()) return false;
        while (!allocator_scope_authority_mutex.tryLock()) std.atomic.spinLoopHint();
        defer allocator_scope_authority_mutex.unlock();
        const slot = @as(usize, self.allocator_scope_authority_slot) - 1;
        if (slot >= allocator_scope_authorities.len) return false;
        const authority = allocator_scope_authorities[slot];
        return authority.ledger_addr == @intFromPtr(self) and authority.client_addr == client_addr and
            authority.token_addr == token_addr and authority.epoch == epoch and
            authority.purpose_raw == purpose_raw and
            authority.generation == self.allocator_scope_authority_generation and
            allocatorEql(authority.previous orelse return false, previous) and
            allocatorEql(authority.installed orelse return false, installed);
    }

    pub fn endAllocatorScope(
        self: *AccountingLedger,
        client_addr: usize,
        token_addr: usize,
        epoch: u64,
        purpose_raw: u8,
        previous: std.mem.Allocator,
        installed: std.mem.Allocator,
    ) Error!void {
        if (!self.matchesClient(client_addr) or self.allocatorScopeState() != .active or
            token_addr == 0 or epoch == 0 or purpose_raw > allocator_scope_purpose_max or
            self.allocator_scope_token_addr != token_addr or self.allocator_scope_epoch != epoch or
            self.allocator_scope_purpose_raw != purpose_raw or
            !allocatorEql(self.allocator_scope_previous orelse return error.InvalidState, previous) or
            !allocatorEql(self.allocator_scope_installed orelse return error.InvalidState, installed) or
            !allocatorScopeProcessMatches()) return error.InvalidState;
        while (!allocator_scope_authority_mutex.tryLock()) std.atomic.spinLoopHint();
        const slot = @as(usize, self.allocator_scope_authority_slot) - 1;
        if (slot >= allocator_scope_authorities.len) {
            allocator_scope_authority_mutex.unlock();
            return error.InvalidState;
        }
        const authority = allocator_scope_authorities[slot];
        if (authority.ledger_addr != @intFromPtr(self) or authority.client_addr != client_addr or
            authority.token_addr != token_addr or authority.epoch != epoch or
            authority.purpose_raw != purpose_raw or
            authority.generation != self.allocator_scope_authority_generation or
            !allocatorEql(authority.previous orelse {
                allocator_scope_authority_mutex.unlock();
                return error.InvalidState;
            }, previous) or
            !allocatorEql(authority.installed orelse {
                allocator_scope_authority_mutex.unlock();
                return error.InvalidState;
            }, installed))
        {
            allocator_scope_authority_mutex.unlock();
            return error.InvalidState;
        }
        allocator_scope_authorities[slot] = .{};
        allocator_scope_authority_mutex.unlock();
        self.allocator_scope_token_addr = 0;
        self.allocator_scope_epoch = 0;
        self.allocator_scope_purpose_raw = 0;
        self.allocator_scope_previous = null;
        self.allocator_scope_installed = null;
        self.allocator_scope_authority_slot = 0;
        self.allocator_scope_authority_generation = 0;
    }

    pub fn reserve(
        self: *AccountingLedger,
        transfer_id: u64,
        byte_count: usize,
    ) Error!void {
        if (!self.valid() or self.client_addr == 0) return error.InvalidState;
        if (transfer_id == 0 or byte_count == 0) return error.InvalidDescriptor;
        if (self.item_count == max_entries) return error.CapacityExhausted;
        for (self.entries) |entry|
            if (entry.lifecycle != .empty and entry.transfer_id == transfer_id)
                return error.InvalidIdentity;
        const index = for (&self.entries, 0..) |*entry, index| {
            if (entry.lifecycle == .empty) break index;
        } else return error.CapacityExhausted;
        const next_bytes = std.math.add(usize, self.byte_count, byte_count) catch
            return error.InvalidState;
        self.entries[index] = .{
            .lifecycle = .live,
            .transfer_id = transfer_id,
            .byte_count = byte_count,
        };
        self.item_count += 1;
        self.byte_count = next_bytes;
    }

    pub fn prepareConsume(
        self: *AccountingLedger,
        receipt: AccountingReceipt,
    ) Error!PreparedAccountingConsume {
        if (!self.matchesClient(receipt.client_addr)) return error.InvalidDescriptor;
        for (&self.entries, 0..) |*entry, index| {
            if (entry.transfer_id != receipt.transfer_id) continue;
            if (entry.lifecycle != .live or entry.byte_count != receipt.byte_count)
                return error.InvalidDescriptor;
            entry.lifecycle = .releasing;
            self.releasing_item_count += 1;
            self.releasing_byte_count += entry.byte_count;
            return .{
                .ledger_slot = @intCast(index),
                .transfer_id = entry.transfer_id,
                .byte_count = entry.byte_count,
            };
        }
        return error.InvalidDescriptor;
    }

    /// `prepareConsume`가 exact live entry를 releasing으로 봉인한 뒤의 무검증 suffix다.
    pub fn consumeUnchecked(
        self: *AccountingLedger,
        prepared: PreparedAccountingConsume,
    ) void {
        self.item_count -= 1;
        self.byte_count -= prepared.byte_count;
        self.releasing_item_count -= 1;
        self.releasing_byte_count -= prepared.byte_count;
        self.entries[prepared.ledger_slot] = .{};
    }

    pub fn preflightDeinit(self: *const AccountingLedger) DeinitOutcome {
        if (!self.valid()) return if (self.lifecycle == .dead) .already_dead else .corrupt;
        if (self.item_count != 0 or self.byte_count != 0 or self.releasing_item_count != 0 or
            self.releasing_byte_count != 0 or self.allocatorScopeState() != .idle)
            return .busy;
        for (self.entries) |entry| if (entry.lifecycle != .empty) return .corrupt;
        return .cleaned;
    }

    pub fn tryDeinit(self: *AccountingLedger) DeinitOutcome {
        const outcome = self.preflightDeinit();
        if (outcome == .cleaned) self.lifecycle = .dead;
        return outcome;
    }
};

fn allocatorEql(left: std.mem.Allocator, right: std.mem.Allocator) bool {
    return left.ptr == right.ptr and left.vtable == right.vtable;
}

test "CR3a-2c3d C1 allocator authority rejects raw and partial ledger states" {
    var ledger: AccountingLedger = .{};
    try ledger.initInPlace();
    try ledger.bindClient(1);
    const previous_allocator = std.testing.allocator;
    var installed_buffer: [1]u8 = undefined;
    var installed_fba = std.heap.FixedBufferAllocator.init(&installed_buffer);
    const installed_allocator = installed_fba.allocator();
    inline for (std.enums.values(AllocatorScopePurpose), 0..) |purpose, index| {
        const token = index + 2;
        const epoch = index + 3;
        try ledger.beginAllocatorScope(
            1,
            token,
            epoch,
            @intFromEnum(purpose),
            previous_allocator,
            installed_allocator,
        );
        try std.testing.expect(ledger.allocatorScopeMatches(
            1,
            token,
            epoch,
            @intFromEnum(purpose),
            previous_allocator,
            installed_allocator,
        ));
        try ledger.endAllocatorScope(
            1,
            token,
            epoch,
            @intFromEnum(purpose),
            previous_allocator,
            installed_allocator,
        );
    }
    try std.testing.expectError(error.InvalidState, ledger.beginAllocatorScope(
        1,
        2,
        3,
        allocator_scope_purpose_max + 1,
        previous_allocator,
        installed_allocator,
    ));
    try std.testing.expectEqual(DeinitOutcome.cleaned, ledger.preflightDeinit());

    ledger.allocator_scope_purpose_raw = 1;
    try std.testing.expectEqual(DeinitOutcome.corrupt, ledger.preflightDeinit());
    try std.testing.expectError(error.InvalidState, ledger.beginAllocatorScope(
        1,
        2,
        3,
        0,
        previous_allocator,
        installed_allocator,
    ));
    ledger.allocator_scope_purpose_raw = 0;
    try std.testing.expectEqual(DeinitOutcome.cleaned, ledger.preflightDeinit());
}

test "CR3a-2c3d C1 fork child rejects inherited allocator authority before mutex" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux)
        return error.SkipZigTest;
    try std.testing.expect(allocatorScopeProcessMatches());
    while (!allocator_scope_authority_mutex.tryLock()) std.atomic.spinLoopHint();
    const child = std.c.fork();
    if (child < 0) {
        allocator_scope_authority_mutex.unlock();
        return error.TestUnexpectedResult;
    }
    if (child == 0) {
        var ledger: AccountingLedger = .{};
        ledger.initInPlace() catch std.c._exit(2);
        ledger.bindClient(1) catch std.c._exit(3);
        const result = ledger.beginAllocatorScope(
            1,
            2,
            3,
            @intFromEnum(AllocatorScopePurpose.rpc_execute),
            std.testing.allocator,
            std.heap.page_allocator,
        );
        if (result) |_| std.c._exit(4) else |err| {
            if (err != error.InvalidState) std.c._exit(5);
        }
        std.c._exit(0);
    }
    allocator_scope_authority_mutex.unlock();
    var status: c_int = 0;
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
        if (waited == child) {
            const raw_status: u32 = @bitCast(status);
            try std.testing.expect(std.c.W.IFEXITED(raw_status));
            try std.testing.expectEqual(@as(u8, 0), std.c.W.EXITSTATUS(raw_status));
            return;
        }
        if (waited < 0) {
            if (std.posix.errno(waited) == .INTR) continue;
            _ = std.c.kill(child, std.c.SIG.KILL);
            _ = std.c.waitpid(child, &status, 0);
            return error.TestUnexpectedResult;
        }
        var delay_fd = std.c.pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = std.c.poll(@ptrCast(&delay_fd), 0, 1);
    }
    _ = std.c.kill(child, std.c.SIG.KILL);
    _ = std.c.waitpid(child, &status, 0);
    return error.TestUnexpectedResult;
}

const RegistryLifecycle = enum(u8) { pristine, live, dead };
const EntryLifecycle = enum(u8) { empty, reserved, ingress, live, releasing };

const Entry = struct {
    lifecycle: EntryLifecycle = .empty,
    generation: u64 = 0,
    stream_id: u64 = 0,
    is_snapshot: bool = false,
    bytes: []u8 = &.{},
    allocator: ?std.mem.Allocator = null,
    accounting: AccountingReceipt = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 },
    cleanup_addr: usize = 0,

    fn clear(self: *Entry) void {
        self.* = .{};
    }
};

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

pub const Registry = struct {
    self_addr: usize = 0,
    incarnation: u64 = 0,
    last_generation: u64 = 0,
    live_count: usize = 0,
    lifecycle: RegistryLifecycle = .pristine,
    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,

    pub fn initInPlace(out: *Registry, incarnation: u64) Error!void {
        if (incarnation == 0) return error.InvalidIdentity;
        if (out.lifecycle != .pristine or out.self_addr != 0 or out.incarnation != 0 or
            out.live_count != 0)
            return error.InvalidState;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .incarnation = incarnation,
            .lifecycle = .live,
        };
    }

    fn valid(self: *const Registry) bool {
        return self.self_addr == @intFromPtr(self) and self.incarnation != 0 and
            self.live_count <= max_entries and self.lifecycle == .live;
    }

    pub fn reserve(self: *Registry, stream_id: u64) Error!Reservation {
        if (!self.valid()) return error.MovedOrCopied;
        if (stream_id == 0) return error.InvalidStream;
        if (self.last_generation == std.math.maxInt(u64)) return error.IdentityExhausted;
        if (self.live_count == max_entries) return error.CapacityExhausted;
        const index = for (&self.entries, 0..) |*entry, index| {
            if (entry.lifecycle == .empty) break index;
        } else return error.InvalidState;
        const generation = self.last_generation + 1;
        self.last_generation = generation;
        self.entries[index] = .{
            .lifecycle = .reserved,
            .generation = generation,
            .stream_id = stream_id,
        };
        self.live_count += 1;
        return .{
            .registry_incarnation = self.incarnation,
            .entry_slot = @intCast(index),
            .entry_generation = generation,
            .stream_id = stream_id,
        };
    }

    fn exactEntry(self: *Registry, token: Token) Error!*Entry {
        if (!self.valid()) return error.MovedOrCopied;
        if (token.registry_incarnation != self.incarnation or token.entry_generation == 0 or
            token.stream_id == 0 or
            token.entry_slot >= max_entries)
            return error.InvalidReservation;
        const entry = &self.entries[token.entry_slot];
        if (entry.lifecycle == .empty or entry.generation != token.entry_generation or
            entry.stream_id != token.stream_id)
            return error.InvalidReservation;
        return entry;
    }

    pub fn abort(self: *Registry, reservation: Reservation) Error!void {
        const entry = try self.exactEntry(reservation);
        if ((entry.lifecycle != .reserved and entry.lifecycle != .ingress) or
            entry.is_snapshot or entry.bytes.len != 0 or entry.allocator != null or
            entry.accounting.client_addr != 0 or entry.accounting.transfer_id != 0 or
            entry.accounting.byte_count != 0 or entry.cleanup_addr != 0)
            return error.InvalidState;
        if (self.live_count == 0) return error.InvalidState;
        entry.clear();
        self.live_count -= 1;
    }

    /// Client owner를 건드리기 전에 destination entry와 reservation을 확정한다.
    pub fn prepareIngress(self: *Registry, reservation: Reservation) Error!void {
        const entry = try self.exactEntry(reservation);
        if (entry.lifecycle != .reserved or entry.is_snapshot or entry.bytes.len != 0 or
            entry.allocator != null or entry.accounting.client_addr != 0 or
            entry.accounting.transfer_id != 0 or entry.accounting.byte_count != 0 or
            entry.cleanup_addr != 0)
            return error.InvalidState;
        entry.lifecycle = .ingress;
    }

    pub fn commit(self: *Registry, reservation: Reservation, owned: *OwnedBatch) Error!Token {
        const entry = try self.exactEntry(reservation);
        if (entry.lifecycle != .ingress) return error.InvalidState;
        if (!owned.validLive() or owned.stream_id != reservation.stream_id or
            owned.accounting.transfer_id != reservation.entry_generation)
            return error.InvalidDescriptor;
        for (self.entries) |other|
            if (other.lifecycle == .live and slicesOverlap(other.bytes, owned.bytes))
                return error.InvalidDescriptor;
        entry.lifecycle = .live;
        entry.is_snapshot = owned.is_snapshot;
        entry.bytes = owned.bytes;
        entry.allocator = owned.allocator;
        entry.accounting = owned.accounting;
        entry.cleanup_addr = 0;
        owned.settle();
        return reservation;
    }

    pub fn commitIngressUnchecked(
        self: *Registry,
        reservation: Reservation,
        owned: *OwnedBatch,
    ) Token {
        return self.commit(reservation, owned) catch
            @panic("prepared generation batch ingress drifted");
    }

    pub fn borrow(self: *Registry, token: Token) Error!BatchView {
        const entry = try self.exactEntry(token);
        if (entry.lifecycle != .live or entry.bytes.len == 0 or entry.allocator == null or
            entry.accounting.transfer_id != entry.generation or
            entry.accounting.byte_count != entry.bytes.len or entry.cleanup_addr != 0)
            return error.InvalidState;
        return .{
            .is_snapshot = entry.is_snapshot,
            .stream_id = entry.stream_id,
            .bytes = entry.bytes,
        };
    }

    pub fn beginRelease(self: *Registry, token: Token, out: *OwnedBatch) Error!void {
        const entry = try self.exactEntry(token);
        if (entry.lifecycle != .live) return error.InvalidState;
        if (!out.pristine()) return error.DestinationOccupied;
        if (entry.bytes.len == 0 or entry.allocator == null or
            entry.accounting.client_addr == 0 or entry.accounting.transfer_id == 0 or
            entry.accounting.byte_count != entry.bytes.len or
            entry.accounting.transfer_id != entry.generation or entry.cleanup_addr != 0)
            return error.InvalidDescriptor;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .lifecycle = .cleanup,
            .is_snapshot = entry.is_snapshot,
            .stream_id = entry.stream_id,
            .bytes = entry.bytes,
            .allocator = entry.allocator,
            .accounting = entry.accounting,
        };
        entry.lifecycle = .releasing;
        entry.bytes = &.{};
        entry.allocator = null;
        entry.accounting = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 };
        entry.cleanup_addr = @intFromPtr(out);
    }

    pub fn preflightRelease(
        self: *Registry,
        token: Token,
        out: *const OwnedBatch,
    ) Error!AccountingReceipt {
        const entry = try self.exactEntry(token);
        if (entry.lifecycle != .live) return error.InvalidState;
        if (!out.pristine()) return error.DestinationOccupied;
        if (entry.bytes.len == 0 or entry.allocator == null or
            entry.accounting.client_addr == 0 or entry.accounting.transfer_id == 0 or
            entry.accounting.byte_count != entry.bytes.len or
            entry.accounting.transfer_id != entry.generation or entry.cleanup_addr != 0)
            return error.InvalidDescriptor;
        return entry.accounting;
    }

    pub fn prepareRelease(
        self: *Registry,
        token: Token,
        out: *PreparedRelease,
    ) Error!void {
        if (!out.pristine()) return error.DestinationOccupied;
        const pristine_cleanup: OwnedBatch = .{};
        const receipt = try self.preflightRelease(token, &pristine_cleanup);
        out.* = .{
            .self_addr = @intFromPtr(out),
            .token = token,
            .accounting = receipt,
            .lifecycle = .prepared,
        };
    }

    /// 준비된 row가 mutation 전 retryable이면 permit만 닫고 canonical live row는 보존한다.
    pub fn releaseDecision(self: *Registry, prepared: *PreparedRelease) GenerationReleaseResult {
        if (!self.preparedReleaseCurrent(prepared))
            @panic("prepared generation release authority drifted");
        if (!builtin.is_test) return .completed;
        if (testing_retryable_release.registry_addr == @intFromPtr(self) and
            std.meta.eql(testing_retryable_release.token, prepared.token))
        {
            testing_retryable_release = .{};
            return .retryable_preserved;
        }
        return .completed;
    }

    pub fn abortPreparedReleaseUnchecked(self: *Registry, prepared: *PreparedRelease) void {
        if (!self.preparedReleaseCurrent(prepared))
            @panic("prepared generation release abort drifted");
        prepared.lifecycle = .aborted;
    }

    pub fn beginPreparedReleaseUnchecked(
        self: *Registry,
        prepared: *PreparedRelease,
        out: *OwnedBatch,
    ) void {
        if (!self.preparedReleaseCurrent(prepared) or !out.pristine())
            @panic("prepared generation release begin drifted");
        self.beginReleaseUnchecked(prepared.token, out);
    }

    pub fn finishPreparedReleaseUnchecked(
        self: *Registry,
        prepared: *PreparedRelease,
        cleanup: *OwnedBatch,
    ) void {
        if (prepared.self_addr != @intFromPtr(prepared) or prepared.lifecycle != .prepared)
            @panic("prepared generation release finish drifted");
        self.finishReleaseUnchecked(prepared.token, cleanup);
        prepared.lifecycle = .consumed;
    }

    fn preparedReleaseCurrent(self: *Registry, prepared: *const PreparedRelease) bool {
        if (prepared.self_addr != @intFromPtr(prepared) or prepared.lifecycle != .prepared)
            return false;
        const entry = self.exactEntry(prepared.token) catch return false;
        return entry.lifecycle == .live and entry.cleanup_addr == 0 and
            entry.accounting.client_addr == prepared.accounting.client_addr and
            entry.accounting.transfer_id == prepared.accounting.transfer_id and
            entry.accounting.byte_count == prepared.accounting.byte_count;
    }

    pub fn beginReleaseUnchecked(self: *Registry, token: Token, out: *OwnedBatch) void {
        self.beginRelease(token, out) catch
            @panic("preflighted generation batch release drifted");
    }

    pub fn finishRelease(self: *Registry, token: Token, cleanup: *OwnedBatch) Error!void {
        const entry = try self.exactEntry(token);
        if (entry.lifecycle != .releasing or entry.cleanup_addr != @intFromPtr(cleanup) or
            cleanup.self_addr != @intFromPtr(cleanup) or cleanup.lifecycle != .settled)
            return error.InvalidState;
        if (self.live_count == 0) return error.InvalidState;
        cleanup.settle();
        entry.clear();
        self.live_count -= 1;
    }

    /// `finishRelease`의 모든 pairing 검증을 callback 전에 끝낸 제품 release의 무검증 suffix다.
    pub fn finishReleaseUnchecked(self: *Registry, token: Token, cleanup: *OwnedBatch) void {
        cleanup.settle();
        self.entries[token.entry_slot].clear();
        self.live_count -= 1;
    }

    pub fn count(self: *const Registry) Error!usize {
        if (!self.valid()) return error.MovedOrCopied;
        return self.live_count;
    }

    /// early demux purge는 해당 stream의 transferred owner가 어느 lifecycle에도 없을 때만 허용한다.
    /// reserved와 releasing도 canonical 권위를 아직 소유하므로 raw Client queue와 경합하거나
    /// 그 소유권을 다른 의미로 해석하면 안 된다.
    pub fn streamIdle(self: *const Registry, stream_id: u64) Error!bool {
        if (!self.valid()) return error.MovedOrCopied;
        if (stream_id == 0) return error.InvalidStream;
        for (self.entries) |entry| {
            if (entry.lifecycle != .empty and entry.stream_id == stream_id) return false;
        }
        return true;
    }

    pub fn preflightDeinit(self: *const Registry) DeinitOutcome {
        if (self.lifecycle == .dead and self.self_addr == @intFromPtr(self)) return .already_dead;
        if (!self.valid()) return .corrupt;
        if (self.live_count != 0) return .busy;
        for (self.entries) |entry| if (entry.lifecycle != .empty) return .corrupt;
        return .cleaned;
    }

    pub fn tryDeinit(self: *Registry) DeinitOutcome {
        const outcome = self.preflightDeinit();
        if (outcome == .cleaned) self.lifecycle = .dead;
        return outcome;
    }
};

test "CR3a-2b1 batch registry reserve abort는 polling idle에서 slot을 소비하지 않는다" {
    var registry: Registry = .{};
    try registry.initInPlace(11);
    for (1..4097) |_| {
        const reservation = try registry.reserve(7);
        try registry.abort(reservation);
    }
    try std.testing.expectEqual(@as(usize, 0), try registry.count());
}

test "CR3a-2c2 stream idle includes reserved ingress live and releasing owners" {
    const allocator = std.testing.allocator;
    var registry: Registry = .{};
    try registry.initInPlace(12);
    try std.testing.expect(try registry.streamIdle(7));

    const reservation = try registry.reserve(7);
    try std.testing.expect(!(try registry.streamIdle(7)));
    try std.testing.expect(try registry.streamIdle(8));
    try registry.prepareIngress(reservation);
    try std.testing.expect(!(try registry.streamIdle(7)));

    const bytes = try allocator.dupe(u8, "batch");
    var owned: OwnedBatch = .{};
    try owned.initInPlace(
        false,
        7,
        bytes,
        allocator,
        .{ .client_addr = 17, .transfer_id = reservation.entry_generation, .byte_count = bytes.len },
    );
    const token = try registry.commit(reservation, &owned);
    try std.testing.expect(!(try registry.streamIdle(7)));

    var cleanup: OwnedBatch = .{};
    _ = try registry.preflightRelease(token, &cleanup);
    registry.beginReleaseUnchecked(token, &cleanup);
    try std.testing.expect(!(try registry.streamIdle(7)));
    cleanup.allocator.?.free(cleanup.bytes);
    cleanup.bytes = &.{};
    cleanup.allocator = null;
    cleanup.accounting = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 };
    cleanup.completeCleanupUnchecked();
    registry.finishReleaseUnchecked(token, &cleanup);
    try std.testing.expect(try registry.streamIdle(7));
}

test "CR3a-2b1 batch registry는 pointer-free token으로 exact owner를 release한다" {
    const allocator = std.testing.allocator;
    var registry: Registry = .{};
    try registry.initInPlace(13);
    const reservation = try registry.reserve(7);
    try registry.prepareIngress(reservation);
    const bytes = try allocator.dupe(u8, "snapshot");
    var owned: OwnedBatch = .{};
    try owned.initInPlace(
        true,
        7,
        bytes,
        allocator,
        .{ .client_addr = 17, .transfer_id = reservation.entry_generation, .byte_count = 8 },
    );
    errdefer if (owned.allocator) |owner| owner.free(owned.bytes);
    const token = try registry.commit(reservation, &owned);
    try std.testing.expect(owned.allocator == null and owned.bytes.len == 0);
    const view = try registry.borrow(token);
    try std.testing.expect(view.is_snapshot);
    try std.testing.expectEqual(@as(u64, 7), view.stream_id);
    try std.testing.expectEqualStrings("snapshot", view.bytes);

    registry.entries[token.entry_slot].accounting.transfer_id += 1;
    var rejected_cleanup: OwnedBatch = .{};
    try std.testing.expectError(
        error.InvalidDescriptor,
        registry.preflightRelease(token, &rejected_cleanup),
    );
    registry.entries[token.entry_slot].accounting.transfer_id = token.entry_generation;
    try std.testing.expectEqualStrings("snapshot", (try registry.borrow(token)).bytes);

    var cleanup: OwnedBatch = .{};
    try registry.beginRelease(token, &cleanup);
    const cleanup_allocator = cleanup.allocator.?;
    cleanup_allocator.free(cleanup.bytes);
    cleanup.bytes = &.{};
    cleanup.allocator = null;
    cleanup.accounting = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 };
    try cleanup.completeCleanup();
    try registry.finishRelease(token, &cleanup);
    try std.testing.expectEqual(@as(usize, 0), try registry.count());
    try std.testing.expectEqual(DeinitOutcome.cleaned, registry.tryDeinit());
}

test "CR3a-2b1 batch registry는 독립 fixed table의 4096 cap을 고정한다" {
    var registry: Registry = .{};
    try registry.initInPlace(23);
    var reservations: [max_entries]Reservation = undefined;
    for (&reservations) |*reservation|
        reservation.* = try registry.reserve(7);
    try std.testing.expectEqual(max_entries, try registry.count());
    try std.testing.expectError(error.CapacityExhausted, registry.reserve(8));
    for (reservations) |reservation| try registry.abort(reservation);
    try std.testing.expectEqual(@as(usize, 0), try registry.count());
}

test "CR3a-2b1 consumed slot 재사용은 stale generation과 registry copy를 거부한다" {
    const allocator = std.testing.allocator;
    var registry: Registry = .{};
    try registry.initInPlace(29);
    const first = try registry.reserve(7);
    try registry.prepareIngress(first);
    const bytes = try allocator.dupe(u8, "a");
    var owned: OwnedBatch = .{};
    try owned.initInPlace(
        false,
        7,
        bytes,
        allocator,
        .{ .client_addr = 31, .transfer_id = first.entry_generation, .byte_count = 1 },
    );
    _ = try registry.commit(first, &owned);
    var cleanup: OwnedBatch = .{};
    try registry.beginRelease(first, &cleanup);
    cleanup.allocator.?.free(cleanup.bytes);
    cleanup.bytes = &.{};
    cleanup.allocator = null;
    cleanup.accounting = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 };
    try cleanup.completeCleanup();
    try registry.finishRelease(first, &cleanup);

    const second = try registry.reserve(7);
    try std.testing.expectEqual(first.entry_slot, second.entry_slot);
    try std.testing.expectError(error.InvalidReservation, registry.borrow(first));
    try registry.abort(second);

    var copied = registry;
    try std.testing.expectError(error.MovedOrCopied, copied.count());
}

test "CR3a-2b1 token은 registry incarnation과 결속되어 cross-node splice를 거부한다" {
    const allocator = std.testing.allocator;
    var first_registry: Registry = .{};
    var second_registry: Registry = .{};
    try first_registry.initInPlace(41);
    try second_registry.initInPlace(43);
    const reservation = try first_registry.reserve(7);
    try first_registry.prepareIngress(reservation);
    const bytes = try allocator.dupe(u8, "sealed");
    var owned: OwnedBatch = .{};
    try owned.initInPlace(
        false,
        7,
        bytes,
        allocator,
        .{ .client_addr = 47, .transfer_id = reservation.entry_generation, .byte_count = bytes.len },
    );
    const token = try first_registry.commit(reservation, &owned);

    const foreign = try second_registry.reserve(7);
    try std.testing.expectEqual(token.entry_slot, foreign.entry_slot);
    try std.testing.expectEqual(token.entry_generation, foreign.entry_generation);
    try std.testing.expectError(error.InvalidReservation, second_registry.borrow(token));
    try second_registry.abort(foreign);

    var cleanup: OwnedBatch = .{};
    try first_registry.beginRelease(token, &cleanup);
    cleanup.allocator.?.free(cleanup.bytes);
    cleanup.bytes = &.{};
    cleanup.allocator = null;
    cleanup.accounting = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 };
    try cleanup.completeCleanup();
    try first_registry.finishRelease(token, &cleanup);
}

test "CR3a-2b1 releasing entry는 exact callback-local cleanup 주소만 settle한다" {
    const allocator = std.testing.allocator;
    var registry: Registry = .{};
    try registry.initInPlace(53);
    var tokens: [2]Token = undefined;
    for (&tokens, 0..) |*token, index| {
        const reservation = try registry.reserve(index + 1);
        try registry.prepareIngress(reservation);
        const bytes = try allocator.dupe(u8, if (index == 0) "a" else "b");
        var owned: OwnedBatch = .{};
        try owned.initInPlace(
            false,
            reservation.stream_id,
            bytes,
            allocator,
            .{ .client_addr = 59, .transfer_id = reservation.entry_generation, .byte_count = 1 },
        );
        token.* = try registry.commit(reservation, &owned);
    }
    var cleanups: [2]OwnedBatch = .{ .{}, .{} };
    for (tokens, &cleanups) |token, *cleanup| {
        try registry.beginRelease(token, cleanup);
        cleanup.allocator.?.free(cleanup.bytes);
        cleanup.bytes = &.{};
        cleanup.allocator = null;
        cleanup.accounting = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 };
        try cleanup.completeCleanup();
    }
    try std.testing.expectError(error.InvalidState, registry.finishRelease(tokens[0], &cleanups[1]));
    try registry.finishRelease(tokens[0], &cleanups[0]);
    try registry.finishRelease(tokens[1], &cleanups[1]);
    try std.testing.expectEqual(@as(usize, 0), try registry.count());
}

test "CR3a-2b1 registry generation exhaustion은 기존 entry mutation 없이 닫힌다" {
    var registry: Registry = .{};
    try registry.initInPlace(61);
    registry.last_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.IdentityExhausted, registry.reserve(7));
    try std.testing.expectEqual(@as(usize, 0), try registry.count());
}

test "CR3a-2b1 registry commit은 live sibling payload overlap을 publication 전에 거부한다" {
    const allocator = std.testing.allocator;
    var registry: Registry = .{};
    try registry.initInPlace(67);
    const bytes = try allocator.dupe(u8, "shared");
    const first_reservation = try registry.reserve(7);
    try registry.prepareIngress(first_reservation);
    var first: OwnedBatch = .{};
    try first.initInPlace(
        false,
        7,
        bytes,
        allocator,
        .{ .client_addr = 71, .transfer_id = first_reservation.entry_generation, .byte_count = bytes.len },
    );
    const first_token = try registry.commit(first_reservation, &first);

    const second_reservation = try registry.reserve(8);
    try registry.prepareIngress(second_reservation);
    var alias: OwnedBatch = .{};
    try alias.initInPlace(
        false,
        8,
        bytes,
        allocator,
        .{ .client_addr = 71, .transfer_id = second_reservation.entry_generation, .byte_count = bytes.len },
    );
    try std.testing.expectError(
        error.InvalidDescriptor,
        registry.commit(second_reservation, &alias),
    );
    // alias descriptor에는 독립 free 권위가 없으므로 tombstone만 하고 canonical first owner만 해제한다.
    alias = .{};
    try registry.abort(second_reservation);
    var cleanup: OwnedBatch = .{};
    try registry.beginRelease(first_token, &cleanup);
    cleanup.allocator.?.free(cleanup.bytes);
    cleanup.bytes = &.{};
    cleanup.allocator = null;
    cleanup.accounting = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 };
    try cleanup.completeCleanup();
    try registry.finishRelease(first_token, &cleanup);
}

test "CR3a-2d1 registry generation release completed raw는 고정된다" {
    try std.testing.expectEqual(@as(usize, 3), std.enums.values(GenerationReleaseResult).len);
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(GenerationReleaseResult.completed));
}

test "CR3a-2d1 registry generation release retryable raw는 고정된다" {
    try std.testing.expectEqual(@as(usize, 3), std.enums.values(GenerationReleaseResult).len);
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(GenerationReleaseResult.retryable_preserved));
}

test "CR3a-2d1 registry generation release indeterminate raw는 고정된다" {
    try std.testing.expectEqual(@as(usize, 3), std.enums.values(GenerationReleaseResult).len);
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(GenerationReleaseResult.indeterminate_or_partial));
}

test "CR3a-2d1 registry prepared release는 final address 복사와 stale token을 거부한다" {
    var registry: Registry = .{};
    try registry.initInPlace(0x2D01);
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "prepared-release");
    var owned: OwnedBatch = .{};
    const reservation = try registry.reserve(7);
    try registry.prepareIngress(reservation);
    try OwnedBatch.initInPlace(&owned, false, 7, bytes, allocator, .{
        .client_addr = 1,
        .transfer_id = reservation.entry_generation,
        .byte_count = bytes.len,
    });
    const token = try registry.commit(reservation, &owned);
    var prepared: PreparedRelease = .{};
    try registry.prepareRelease(token, &prepared);
    var copied = prepared;
    try std.testing.expect(!registry.preparedReleaseCurrent(&copied));
    registry.abortPreparedReleaseUnchecked(&prepared);
    try std.testing.expectEqual(@as(usize, 1), try registry.count());

    var cleanup: OwnedBatch = .{};
    registry.beginReleaseUnchecked(token, &cleanup);
    cleanup.allocator.?.free(cleanup.bytes);
    cleanup.bytes = &.{};
    cleanup.allocator = null;
    cleanup.accounting = .{ .client_addr = 0, .transfer_id = 0, .byte_count = 0 };
    cleanup.completeCleanupUnchecked();
    registry.finishReleaseUnchecked(token, &cleanup);
}

comptime {
    for (std.meta.fields(Token)) |field| switch (@typeInfo(field.type)) {
        .pointer => @compileError("generation batch token must stay pointer-free"),
        else => {},
    };
}
