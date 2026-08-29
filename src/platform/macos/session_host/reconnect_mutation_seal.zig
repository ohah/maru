//! CR2e-b reconnect mutation sealing과 완전본 paste quarantine substrate.
//!
//! 제품 executor 배선 전 단계다. stable queue의 payload view는 호출 동안만 빌리고 저장하지 않으며,
//! 유일하게 보존하는 원문은 cap과 app-global budget을 선점한 `PausedPasteStore`의 secure buffer다.

const std = @import("std");

pub const max_paste_bytes: usize = 1024 * 1024;
pub const max_global_bytes: usize = 8 * 1024 * 1024;
pub const max_mutation_leases: usize = 64;
pub const ttl_ns: i96 = 10 * 60 * std.time.ns_per_s;

pub const MutationLifecycle = enum(u8) { pristine, open, sealing, sealed_clean, sealed_ambiguous };
pub const SealClassification = enum(u8) { clean, ambiguous };
pub const SealProgress = enum(u8) { ready, waiting_for_leases };
pub const SealResult = enum(u8) { sealed_clean, sealed_ambiguous };

pub const MutationLease = struct {
    owner_addr: usize = 0,
    shell_generation: u64 = 0,
    input_epoch: u64 = 0,
    ordinal: u64 = 0,
    active: bool = false,
};

pub const MutationOwner = struct {
    self_addr: usize = 0,
    owner_thread: ?std.Thread.Id = null,
    shell_generation: u64 = 0,
    input_epoch: u64 = 0,
    next_ordinal: u64 = 0,
    active_leases: u32 = 0,
    active_ordinals: [max_mutation_leases]u64 = @splat(0),
    lifecycle: MutationLifecycle = .pristine,

    pub fn initInPlace(self: *MutationOwner, shell_generation: u64, input_epoch: u64) !void {
        if (!std.meta.eql(self.*, MutationOwner{})) return error.InvalidAuthority;
        if (shell_generation == 0 or input_epoch == 0) return error.InvalidAuthority;
        self.* = .{
            .self_addr = @intFromPtr(self),
            .owner_thread = std.Thread.getCurrentId(),
            .shell_generation = shell_generation,
            .input_epoch = input_epoch,
            .next_ordinal = 1,
            .active_leases = 0,
            .active_ordinals = @splat(0),
            .lifecycle = .open,
        };
    }

    pub fn beginMutation(
        self: *MutationOwner,
        shell_generation: u64,
        input_epoch: u64,
        out: *MutationLease,
    ) !void {
        try self.validateOwner();
        if (rangesOverlap(out, @sizeOf(MutationLease), self, @sizeOf(MutationOwner)))
            return error.InvalidAuthority;
        if (!std.meta.eql(out.*, MutationLease{})) return error.InvalidAuthority;
        if (self.lifecycle != .open) return error.ReconnectBusy;
        if (shell_generation != self.shell_generation or input_epoch != self.input_epoch)
            return error.InvalidAuthority;
        const slot = for (self.active_ordinals, 0..) |value, index| {
            if (value == 0) break index;
        } else return error.Busy;
        const ordinal = self.next_ordinal;
        const next_ordinal = std.math.add(u64, ordinal, 1) catch return error.Exhausted;
        const next_active = std.math.add(u32, self.active_leases, 1) catch return error.Exhausted;
        self.next_ordinal = next_ordinal;
        self.active_leases = next_active;
        self.active_ordinals[slot] = ordinal;
        out.* = .{
            .owner_addr = self.self_addr,
            .shell_generation = shell_generation,
            .input_epoch = input_epoch,
            .ordinal = ordinal,
            .active = true,
        };
    }

    pub fn finishMutation(self: *MutationOwner, lease: *MutationLease) !void {
        try self.validateOwner();
        if (rangesOverlap(lease, @sizeOf(MutationLease), self, @sizeOf(MutationOwner)))
            return error.InvalidAuthority;
        if (!lease.active or lease.owner_addr != self.self_addr or
            lease.shell_generation != self.shell_generation or lease.input_epoch != self.input_epoch or
            lease.ordinal == 0 or self.active_leases == 0) return error.InvalidAuthority;
        const slot = for (self.active_ordinals, 0..) |ordinal, index| {
            if (ordinal == lease.ordinal) break index;
        } else return error.InvalidAuthority;
        self.active_ordinals[slot] = 0;
        self.active_leases -= 1;
        lease.* = .{};
    }

    pub fn beginSeal(self: *MutationOwner, shell_generation: u64, input_epoch: u64) !SealProgress {
        try self.validateOwner();
        if ((self.lifecycle != .open and self.lifecycle != .sealing) or
            shell_generation != self.shell_generation or
            input_epoch != self.input_epoch) return error.InvalidAuthority;
        self.lifecycle = .sealing;
        return if (self.active_leases == 0) .ready else .waiting_for_leases;
    }

    /// Seal 준비가 allocation/preflight 단계에서 실패했을 때만 old generation mutation을 다시 연다.
    /// 이미 payload를 wipe했거나 forward publication을 시작한 caller는 이 rollback leaf를 호출할 수 없다.
    pub fn abortSeal(self: *MutationOwner, shell_generation: u64, input_epoch: u64) !void {
        try self.validateOwner();
        if (self.lifecycle != .sealing or self.active_leases != 0 or
            shell_generation != self.shell_generation or input_epoch != self.input_epoch)
            return error.InvalidAuthority;
        self.lifecycle = .open;
    }

    pub fn finishSeal(self: *MutationOwner, classification: SealClassification) !SealResult {
        try self.validateOwner();
        if (self.lifecycle != .sealing) return error.InvalidAuthority;
        if (self.active_leases != 0) return error.Busy;
        return switch (classification) {
            .clean => blk: {
                self.lifecycle = .sealed_clean;
                break :blk .sealed_clean;
            },
            .ambiguous => blk: {
                self.lifecycle = .sealed_ambiguous;
                break :blk .sealed_ambiguous;
            },
        };
    }

    /// CR4c publication suffix만 사용하는 allocation/callback-free 전환이다. 새 shell이
    /// stable screen에 게시되기 전에는 preflight만 수행하고, 게시 뒤에는 같은 값으로
    /// no-fail commit하여 old generation의 sealed lease가 다시 열리지 않게 한다.
    pub fn preflightReopen(
        self: *const MutationOwner,
        shell_generation: u64,
        input_epoch: u64,
    ) !void {
        try self.validateOwner();
        if ((self.lifecycle != .sealed_clean and self.lifecycle != .sealed_ambiguous) or
            self.active_leases != 0 or shell_generation <= self.shell_generation or
            input_epoch <= self.input_epoch)
            return error.InvalidAuthority;
    }

    pub fn reopenNoFail(
        self: *MutationOwner,
        shell_generation: u64,
        input_epoch: u64,
    ) void {
        self.preflightReopen(shell_generation, input_epoch) catch
            @panic("CR4c mutation reopen authority drifted after preflight");
        self.shell_generation = shell_generation;
        self.input_epoch = input_epoch;
        self.lifecycle = .open;
    }

    pub fn admits(
        self: *const MutationOwner,
        shell_generation: u64,
        input_epoch: u64,
    ) bool {
        self.validateOwner() catch return false;
        return self.lifecycle == .open and self.shell_generation == shell_generation and
            self.input_epoch == input_epoch;
    }

    fn validateOwner(self: *const MutationOwner) !void {
        const lifecycle_raw = @as(*const u8, @ptrCast(&self.lifecycle)).*;
        if (lifecycle_raw > @intFromEnum(MutationLifecycle.sealed_ambiguous) or
            self.self_addr != @intFromPtr(self) or self.owner_thread == null or
            self.owner_thread.? != std.Thread.getCurrentId() or
            self.shell_generation == 0 or self.input_epoch == 0 or self.next_ordinal == 0 or
            self.lifecycle == .pristine or !self.ordinalsValid()) return error.InvalidAuthority;
    }

    fn ordinalsValid(self: *const MutationOwner) bool {
        var count: u32 = 0;
        for (self.active_ordinals, 0..) |ordinal, index| {
            if (ordinal == 0) continue;
            if (ordinal >= self.next_ordinal) return false;
            count = std.math.add(u32, count, 1) catch return false;
            for (self.active_ordinals[0..index]) |previous| {
                if (previous == ordinal) return false;
            }
        }
        return count == self.active_leases;
    }
};

test "CR4b mutation owner는 seal 동안 새 mutation을 막고 기존 lease drain만 허용한다" {
    var owner: MutationOwner = .{};
    try owner.initInPlace(2, 7);

    var lease: MutationLease = .{};
    try owner.beginMutation(2, 7, &lease);
    try std.testing.expectEqual(SealProgress.waiting_for_leases, try owner.beginSeal(2, 7));
    var blocked: MutationLease = .{};
    try std.testing.expectError(error.ReconnectBusy, owner.beginMutation(2, 7, &blocked));

    try owner.finishMutation(&lease);
    try std.testing.expectEqual(SealProgress.ready, try owner.beginSeal(2, 7));
    try std.testing.expectEqual(SealResult.sealed_clean, try owner.finishSeal(.clean));
    try std.testing.expect(!owner.admits(2, 7));
}

test "CR4c mutation owner는 sealed generation을 더 큰 shell과 epoch로만 다시 연다" {
    var owner: MutationOwner = .{};
    try owner.initInPlace(2, 7);
    try std.testing.expectEqual(SealProgress.ready, try owner.beginSeal(2, 7));
    try std.testing.expectEqual(SealResult.sealed_clean, try owner.finishSeal(.clean));
    try std.testing.expectError(error.InvalidAuthority, owner.preflightReopen(2, 8));
    try std.testing.expectError(error.InvalidAuthority, owner.preflightReopen(3, 7));
    try owner.preflightReopen(3, 8);
    owner.reopenNoFail(3, 8);
    try std.testing.expect(owner.admits(3, 8));
    try std.testing.expect(!owner.admits(2, 7));
}

pub const GlobalPasteBudget = struct {
    self_addr: usize = 0,
    live_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn initInPlace(self: *GlobalPasteBudget) !void {
        if (self.self_addr != 0 or self.live_bytes.load(.acquire) != 0)
            return error.InvalidAuthority;
        self.* = .{ .self_addr = @intFromPtr(self) };
    }

    fn reserve(self: *GlobalPasteBudget, bytes: usize) !void {
        if (!self.valid()) return error.InvalidAuthority;
        if (bytes == 0 or bytes > max_global_bytes) return error.GlobalPasteLimit;
        var observed = self.live_bytes.load(.acquire);
        while (true) {
            if (bytes > max_global_bytes -| observed) return error.GlobalPasteLimit;
            if (self.live_bytes.cmpxchgWeak(observed, observed + bytes, .acq_rel, .acquire)) |actual| {
                observed = actual;
                continue;
            }
            return;
        }
    }

    fn release(self: *GlobalPasteBudget, bytes: usize) void {
        if (!self.valid()) @panic("paused paste global budget lost final owner");
        const previous = self.live_bytes.fetchSub(bytes, .acq_rel);
        if (previous < bytes) @panic("paused paste global budget underflow");
    }

    pub fn reservedBytes(self: *const GlobalPasteBudget) usize {
        if (!self.valid()) return 0;
        return self.live_bytes.load(.acquire);
    }

    pub fn initialized(self: *const GlobalPasteBudget) bool {
        return self.valid();
    }

    pub fn deinit(self: *GlobalPasteBudget) void {
        if (!self.valid() or self.live_bytes.load(.acquire) != 0)
            @panic("paused paste global budget deinit with live ownership");
        self.* = .{};
    }

    fn valid(self: *const GlobalPasteBudget) bool {
        return self.self_addr == @intFromPtr(self);
    }
};

pub const SealKind = enum(u8) { key_bytes, paste, ime_commit, osc52_response, scroll_to_bottom, core_command, observation_probe };

pub const SealEntry = struct {
    kind: SealKind,
    sequence: u64,
    queued_payload: []u8,
    complete_original: ?[]u8 = null,
};

pub const KindMetadata = struct {
    count: u32 = 0,
    bytes: u64 = 0,
    first_sequence: u64 = 0,
    last_sequence: u64 = 0,
};

pub const PausedInputMetadata = struct {
    runtime_id: [16]u8,
    shell_generation: u64,
    input_epoch: u64,
    first_sequence: u64,
    last_sequence: u64,
    total_count: u32,
    total_bytes: u64,
    kinds: [@typeInfo(SealKind).@"enum".fields.len]KindMetadata,
};

pub const PausedPasteProjection = struct {
    id: u64,
    runtime_id: [16]u8,
    shell_generation: u64,
    input_epoch: u64,
    full_length: u64,
    hash: [32]u8,
    expires_at_ns: i96,
};

pub const PreparedResend = struct {
    self_addr: usize = 0,
    owner_thread: ?std.Thread.Id = null,
    allocator: ?std.mem.Allocator = null,
    budget: ?*GlobalPasteBudget = null,
    payload: ?[]u8 = null,
    runtime_id: [16]u8 = @splat(0),
    shell_generation: u64 = 0,
    input_epoch: u64 = 0,
    paste_id: u64 = 0,
    hash: [32]u8 = @splat(0),

    pub fn bytesView(self: *const PreparedResend) ![]const u8 {
        try self.validateStructural();
        if (!self.payloadMatches()) return error.InvalidAuthority;
        return self.payload.?;
    }

    pub fn deinit(self: *PreparedResend) void {
        self.validateStructural() catch @panic("prepared resend deinit lost final owner");
        const payload = self.payload.?;
        const hash_matches = self.payloadMatches();
        secureWipe(payload);
        self.allocator.?.free(payload);
        self.budget.?.release(payload.len);
        self.* = .{};
        if (!hash_matches) @panic("prepared resend payload integrity drift");
    }

    fn validateStructural(self: *const PreparedResend) !void {
        if (self.self_addr != @intFromPtr(self) or self.owner_thread == null or
            self.owner_thread.? != std.Thread.getCurrentId() or self.allocator == null or self.budget == null or
            !self.budget.?.valid() or self.payload == null or self.payload.?.len == 0 or
            allZero(&self.runtime_id) or self.shell_generation == 0 or self.input_epoch == 0 or
            self.paste_id == 0) return error.InvalidAuthority;
    }

    fn payloadMatches(self: *const PreparedResend) bool {
        var actual_hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(self.payload.?, &actual_hash, .{});
        return std.crypto.timing_safe.eql([32]u8, self.hash, actual_hash);
    }
};

const PausedPaste = struct {
    id: u64,
    payload: []u8,
    hash: [32]u8,
    expires_at_ns: i96,
};

pub const PausedPasteStore = struct {
    self_addr: usize = 0,
    owner_thread: ?std.Thread.Id = null,
    allocator: ?std.mem.Allocator = null,
    budget: ?*GlobalPasteBudget = null,
    runtime_id: [16]u8 = @splat(0),
    shell_generation: u64 = 0,
    input_epoch: u64 = 0,
    paste: ?PausedPaste = null,
    resend_staging: ?[]u8 = null,
    resend_input_epoch: u64 = 0,

    pub fn initInPlace(
        self: *PausedPasteStore,
        allocator: std.mem.Allocator,
        budget: *GlobalPasteBudget,
        runtime_id: [16]u8,
        shell_generation: u64,
        input_epoch: u64,
    ) !void {
        if (!std.meta.eql(self.*, PausedPasteStore{})) return error.InvalidAuthority;
        if (!budget.valid() or allZero(&runtime_id) or shell_generation == 0 or input_epoch == 0)
            return error.InvalidAuthority;
        self.* = .{
            .self_addr = @intFromPtr(self),
            .owner_thread = std.Thread.getCurrentId(),
            .allocator = allocator,
            .budget = budget,
            .runtime_id = runtime_id,
            .shell_generation = shell_generation,
            .input_epoch = input_epoch,
            .paste = null,
            .resend_staging = null,
            .resend_input_epoch = 0,
        };
    }

    pub fn deinit(self: *PausedPasteStore) void {
        self.validateOwner() catch @panic("paused paste deinit lost final owner");
        self.destroyStaging();
        self.destroyPaste();
        self.* = .{};
    }

    pub fn initialized(self: *const PausedPasteStore) bool {
        return self.self_addr == @intFromPtr(self);
    }

    pub fn hasPausedPaste(self: *const PausedPasteStore) bool {
        self.validateOwner() catch return false;
        return self.paste != null;
    }

    pub fn projection(self: *const PausedPasteStore) !?PausedPasteProjection {
        try self.validateOwner();
        const paste = self.paste orelse return null;
        return .{
            .id = paste.id,
            .runtime_id = self.runtime_id,
            .shell_generation = self.shell_generation,
            .input_epoch = self.input_epoch,
            .full_length = @intCast(paste.payload.len),
            .hash = paste.hash,
            .expires_at_ns = paste.expires_at_ns,
        };
    }

    pub fn capturePaste(self: *PausedPasteStore, source: []u8, id: u64, io: std.Io) !void {
        const now = std.Io.Clock.boot.now(io).nanoseconds;
        return self.capturePasteAt(source, id, now);
    }

    pub fn capturePasteAt(self: *PausedPasteStore, source: []u8, id: u64, now_ns: i96) !void {
        try self.validateOwner();
        if (id == 0 or source.len == 0) return error.InvalidAuthority;
        if (rangesOverlap(source.ptr, source.len, self, @sizeOf(PausedPasteStore)) or
            rangesOverlap(source.ptr, source.len, self.budget.?, @sizeOf(GlobalPasteBudget)))
            return error.InvalidAuthority;
        if (source.len > max_paste_bytes) return error.PasteTooLarge;
        if (self.paste != null or self.resend_staging != null) return error.RuntimePasteLimit;
        const expires_at = std.math.add(i96, now_ns, ttl_ns) catch return error.InvalidAuthority;
        try self.budget.?.reserve(source.len);
        errdefer self.budget.?.release(source.len);
        const payload = try self.allocator.?.dupe(u8, source);
        errdefer self.allocator.?.free(payload);
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(payload, &hash, .{});
        self.paste = .{ .id = id, .payload = payload, .hash = hash, .expires_at_ns = expires_at };
        secureWipe(source);
    }

    pub fn sealEntries(
        self: *PausedPasteStore,
        entries: []const SealEntry,
        paste_id: u64,
        io: std.Io,
    ) !PausedInputMetadata {
        try self.validateOwner();
        if (entries.len == 0 or entries.len > std.math.maxInt(u32)) return error.InvalidAuthority;
        const entries_bytes = std.math.mul(usize, @sizeOf(SealEntry), entries.len) catch
            return error.InvalidAuthority;
        if (rangesOverlap(entries.ptr, entries_bytes, self, @sizeOf(PausedPasteStore)) or
            rangesOverlap(entries.ptr, entries_bytes, self.budget.?, @sizeOf(GlobalPasteBudget)))
            return error.InvalidAuthority;
        var summary = PausedInputMetadata{
            .runtime_id = self.runtime_id,
            .shell_generation = self.shell_generation,
            .input_epoch = self.input_epoch,
            .first_sequence = entries[0].sequence,
            .last_sequence = entries[entries.len - 1].sequence,
            .total_count = @intCast(entries.len),
            .total_bytes = 0,
            .kinds = @splat(.{}),
        };
        if (summary.first_sequence == 0) return error.InvalidAuthority;
        var complete_paste: ?[]u8 = null;
        for (entries, 0..) |entry, index| {
            if (rangesOverlap(entry.queued_payload.ptr, entry.queued_payload.len, self, @sizeOf(PausedPasteStore)) or
                rangesOverlap(entry.queued_payload.ptr, entry.queued_payload.len, self.budget.?, @sizeOf(GlobalPasteBudget)) or
                rangesOverlap(
                    entry.queued_payload.ptr,
                    entry.queued_payload.len,
                    entries.ptr,
                    entries_bytes,
                ))
                return error.InvalidAuthority;
            for (entries[0..index]) |previous| {
                if (rangesOverlap(
                    entry.queued_payload.ptr,
                    entry.queued_payload.len,
                    previous.queued_payload.ptr,
                    previous.queued_payload.len,
                )) return error.InvalidAuthority;
            }
            const expected_sequence = std.math.add(u64, summary.first_sequence, index) catch
                return error.InvalidAuthority;
            if (entry.sequence != expected_sequence) return error.InvalidAuthority;
            summary.total_bytes = std.math.add(u64, summary.total_bytes, entry.queued_payload.len) catch
                return error.InvalidAuthority;
            const kind = &summary.kinds[@intFromEnum(entry.kind)];
            kind.count = std.math.add(u32, kind.count, 1) catch return error.InvalidAuthority;
            kind.bytes = std.math.add(u64, kind.bytes, entry.queued_payload.len) catch
                return error.InvalidAuthority;
            if (kind.first_sequence == 0) kind.first_sequence = entry.sequence;
            kind.last_sequence = entry.sequence;
            if (entry.complete_original) |original| {
                if (entry.kind != .paste or complete_paste != null or original.len == 0 or
                    rangesOverlap(original.ptr, original.len, self, @sizeOf(PausedPasteStore)) or
                    rangesOverlap(original.ptr, original.len, self.budget.?, @sizeOf(GlobalPasteBudget)) or
                    rangesOverlap(
                        original.ptr,
                        original.len,
                        entries.ptr,
                        entries_bytes,
                    ))
                    return error.InvalidAuthority;
                for (entries) |candidate| {
                    const exact_same = original.ptr == candidate.queued_payload.ptr and
                        original.len == candidate.queued_payload.len;
                    if (!exact_same and rangesOverlap(
                        original.ptr,
                        original.len,
                        candidate.queued_payload.ptr,
                        candidate.queued_payload.len,
                    )) return error.InvalidAuthority;
                }
                complete_paste = original;
            }
        }
        if (complete_paste) |paste| try self.capturePaste(paste, paste_id, io);
        for (entries) |entry| secureWipe(entry.queued_payload);
        return summary;
    }

    pub fn prepareResend(
        self: *PausedPasteStore,
        expected_shell_generation: u64,
        new_input_epoch: u64,
        io: std.Io,
    ) !void {
        try self.validateOwner();
        if (expected_shell_generation != self.shell_generation or
            new_input_epoch <= self.input_epoch or self.resend_staging != null)
            return error.InvalidAuthority;
        const paste = self.paste orelse return error.InvalidAuthority;
        if (std.Io.Clock.boot.now(io).nanoseconds >= paste.expires_at_ns) {
            self.destroyPaste();
            return error.Expired;
        }
        var actual_hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(paste.payload, &actual_hash, .{});
        if (!std.crypto.timing_safe.eql([32]u8, paste.hash, actual_hash))
            return error.InvalidAuthority;
        try self.budget.?.reserve(paste.payload.len);
        errdefer self.budget.?.release(paste.payload.len);
        const staging = try self.allocator.?.dupe(u8, paste.payload);
        self.resend_staging = staging;
        self.resend_input_epoch = new_input_epoch;
    }

    pub fn consumeResend(self: *PausedPasteStore, out: *PreparedResend) !void {
        try self.validateOwner();
        if (rangesOverlap(out, @sizeOf(PreparedResend), self, @sizeOf(PausedPasteStore)) or
            rangesOverlap(out, @sizeOf(PreparedResend), self.budget.?, @sizeOf(GlobalPasteBudget)))
            return error.InvalidAuthority;
        if (!std.meta.eql(out.*, PreparedResend{})) return error.InvalidAuthority;
        const staging = self.resend_staging orelse return error.InvalidAuthority;
        const paste = self.paste orelse return error.InvalidAuthority;
        var staging_hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(staging, &staging_hash, .{});
        if (!std.crypto.timing_safe.eql([32]u8, paste.hash, staging_hash) or
            self.resend_input_epoch <= self.input_epoch) return error.InvalidAuthority;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .owner_thread = std.Thread.getCurrentId(),
            .allocator = self.allocator.?,
            .budget = self.budget.?,
            .payload = staging,
            .runtime_id = self.runtime_id,
            .shell_generation = self.shell_generation,
            .input_epoch = self.resend_input_epoch,
            .paste_id = paste.id,
            .hash = paste.hash,
        };
        self.resend_staging = null;
        self.resend_input_epoch = 0;
        self.destroyPaste();
    }

    pub fn discard(self: *PausedPasteStore) !void {
        try self.validateOwner();
        self.destroyStaging();
        self.destroyPaste();
    }

    pub fn expireAt(self: *PausedPasteStore, now_ns: i96) !bool {
        try self.validateOwner();
        const paste = self.paste orelse return false;
        if (now_ns < paste.expires_at_ns) return false;
        self.destroyStaging();
        self.destroyPaste();
        return true;
    }

    fn destroyStaging(self: *PausedPasteStore) void {
        const staging = self.resend_staging orelse return;
        secureWipe(staging);
        self.allocator.?.free(staging);
        self.budget.?.release(staging.len);
        self.resend_staging = null;
        self.resend_input_epoch = 0;
    }

    fn destroyPaste(self: *PausedPasteStore) void {
        const paste = self.paste orelse return;
        secureWipe(paste.payload);
        self.allocator.?.free(paste.payload);
        self.budget.?.release(paste.payload.len);
        self.paste = null;
    }

    fn validateOwner(self: *const PausedPasteStore) !void {
        if (self.self_addr != @intFromPtr(self) or self.owner_thread == null or
            self.owner_thread.? != std.Thread.getCurrentId() or self.allocator == null or self.budget == null or
            !self.budget.?.valid() or allZero(&self.runtime_id) or self.shell_generation == 0 or
            self.input_epoch == 0 or (self.resend_staging == null) != (self.resend_input_epoch == 0) or
            (self.resend_staging != null and self.paste == null)) return error.InvalidAuthority;
    }
};

fn secureWipe(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    if (comptime @import("builtin").is_test) testing_api.recordWipe(bytes);
}

fn allZero(bytes: []const u8) bool {
    var aggregate: u8 = 0;
    for (bytes) |byte| aggregate |= byte;
    return aggregate == 0;
}

fn rangesOverlap(a_ptr: anytype, a_len: usize, b_ptr: anytype, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_start = @intFromPtr(a_ptr);
    const b_start = @intFromPtr(b_ptr);
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

pub const testing_api = if (@import("builtin").is_test) struct {
    pub const WipeTrace = struct { calls: usize = 0, bytes: usize = 0 };
    var armed: ?*WipeTrace = null;

    pub fn armWipeTrace(trace: *WipeTrace) void {
        std.debug.assert(armed == null);
        armed = trace;
    }

    pub fn disarmWipeTrace() void {
        armed = null;
    }

    pub fn corruptPasteByte(store: *PausedPasteStore, index: usize) void {
        store.validateOwner() catch @panic("test corruption lost paused paste owner");
        const paste = store.paste orelse @panic("test corruption requires paused paste");
        if (index >= paste.payload.len) @panic("test corruption index out of range");
        paste.payload[index] ^= 0xFF;
    }

    pub fn corruptResendByte(resend: *PreparedResend, index: usize) void {
        resend.validateStructural() catch @panic("test corruption lost prepared resend owner");
        const payload = resend.payload.?;
        if (index >= payload.len) @panic("test corruption index out of range");
        payload[index] ^= 0xFF;
    }

    fn recordWipe(bytes: []const u8) void {
        var aggregate: u8 = 0;
        for (bytes) |byte| aggregate |= byte;
        if (aggregate != 0) @panic("secure wipe trace observed nonzero bytes");
        if (armed) |trace| {
            trace.calls += 1;
            trace.bytes += bytes.len;
        }
    }
} else struct {};

test "CR4b paused paste는 runtime global cap TTL과 secure wipe를 exact 정산한다" {
    const allocator = std.testing.allocator;
    var budget: GlobalPasteBudget = .{};
    try budget.initInPlace();
    defer budget.deinit();
    var store: PausedPasteStore = .{};
    try store.initInPlace(
        allocator,
        &budget,
        [_]u8{0x2a} ++ [_]u8{0} ** 15,
        2,
        7,
    );
    defer store.deinit();

    var trace: testing_api.WipeTrace = .{};
    testing_api.armWipeTrace(&trace);
    defer testing_api.disarmWipeTrace();
    const source = try allocator.dupe(u8, "secret");
    defer allocator.free(source);
    try store.capturePasteAt(source, 9, 100);
    try std.testing.expect(std.mem.allEqual(u8, source, 0));
    try std.testing.expectEqual(@as(usize, 6), budget.reservedBytes());
    const projection = (try store.projection()).?;
    try std.testing.expectEqual(@as(u64, 9), projection.id);
    try std.testing.expectEqual(@as(u64, 6), projection.full_length);
    try std.testing.expectEqual(@as(i96, 100 + ttl_ns), projection.expires_at_ns);
    try std.testing.expect(!(try store.expireAt(projection.expires_at_ns - 1)));
    try std.testing.expect(try store.expireAt(projection.expires_at_ns));
    try std.testing.expectEqual(@as(usize, 0), budget.reservedBytes());
    try std.testing.expectEqual(@as(usize, 2), trace.calls);
    try std.testing.expectEqual(@as(usize, 12), trace.bytes);

    const over_cap = try allocator.alloc(u8, max_paste_bytes + 1);
    defer allocator.free(over_cap);
    @memset(over_cap, 'x');
    const over_cap_before = over_cap[0];
    try std.testing.expectError(error.PasteTooLarge, store.capturePasteAt(over_cap, 10, 200));
    try std.testing.expectEqual(over_cap_before, over_cap[0]);
    try std.testing.expectEqual(@as(usize, 0), budget.reservedBytes());

    try budget.reserve(max_global_bytes);
    defer budget.release(max_global_bytes);
    var one = [_]u8{'x'};
    try std.testing.expectError(error.GlobalPasteLimit, store.capturePasteAt(&one, 11, 200));
    try std.testing.expectEqual(@as(u8, 'x'), one[0]);
    try std.testing.expectEqual(max_global_bytes, budget.reservedBytes());
}

test "CR4b paused paste는 full resend를 single use로 이동하고 변조를 거부한다" {
    const allocator = std.testing.allocator;
    var budget: GlobalPasteBudget = .{};
    try budget.initInPlace();
    defer budget.deinit();
    var store: PausedPasteStore = .{};
    try store.initInPlace(
        allocator,
        &budget,
        [_]u8{0x2b} ++ [_]u8{0} ** 15,
        3,
        8,
    );
    defer store.deinit();
    const source = try allocator.dupe(u8, "paste-body");
    defer allocator.free(source);
    try store.capturePaste(source, 12, std.testing.io);
    try store.prepareResend(3, 9, std.testing.io);
    try std.testing.expectEqual(@as(usize, 20), budget.reservedBytes());
    try std.testing.expectError(error.InvalidAuthority, store.prepareResend(3, 10, std.testing.io));

    var prepared: PreparedResend = .{};
    try store.consumeResend(&prepared);
    try std.testing.expectEqualStrings("paste-body", try prepared.bytesView());
    try std.testing.expectEqual(@as(usize, 10), budget.reservedBytes());
    try std.testing.expect((try store.projection()) == null);
    var copied = prepared;
    try std.testing.expectError(error.InvalidAuthority, copied.bytesView());
    testing_api.corruptResendByte(&prepared, 0);
    try std.testing.expectError(error.InvalidAuthority, prepared.bytesView());
    testing_api.corruptResendByte(&prepared, 0);
    prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.reservedBytes());
    try std.testing.expectError(error.InvalidAuthority, store.consumeResend(&prepared));
}
