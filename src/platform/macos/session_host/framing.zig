//! MRSH frame 조립 — partial I/O를 견디는 incremental parser와 frame 직렬화 helper(§10).
//!
//! 왜 incremental인가: session-host socket은 non-blocking이라 header/payload가 여러 read에 쪼개져 온다("header/payload
//! partial read/write는 정상 입력", §10). socket read loop(P3-d server)는 받은 바이트를 그대로 `FrameParser.push`에
//! 넣고 `next()`로 완성된 frame을 하나씩 꺼낸다. 이 parser는 순수 버퍼 state machine이라 socket·OS를 모르고
//! non-macOS에서 그대로 테스트된다(platform import 0). cap 적용·unknown frame 정책도 여기서 판정한다:
//!   - payload가 kind별 cap을 넘으면 `PayloadTooLarge`(payload를 읽어 버퍼를 채우기 **전에** 거부 — 메모리 폭주 방지).
//!   - 모르는 required kind/flag는 `UnknownRequiredFrame`(§10: connection만 닫고 runtime은 유지 — 상위가 처리).
//!   - 모르는 kind/flag라도 `optional` flag면 payload 길이만큼 안전하게 skip한다.

const std = @import("std");
const protocol = @import("protocol.zig");

/// 완성된 한 frame. `payload`는 caller 소유다(parser 버퍼에서 복사) — 다음 `next()` 호출과 독립적으로 유효하다.
pub const Frame = struct {
    header: protocol.Header,
    payload: []u8,
    /// Operation-local provenance only. Client clears this before an OOB frame enters a durable
    /// queue; a correlated response moves it into ExecutedBlockingRpcResponse.
    payload_observation_generation: u64 = 0,

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

pub const ParseError = error{
    /// 첫 4바이트가 "MRSH"가 아니다 — 이 connection은 MRSH가 아니다(다른 socket과 혼선). connection을 닫는다.
    BadMagic,
    /// payload_len이 이 kind의 cap을 넘었다. payload를 버퍼에 쌓기 전에 거부한다.
    PayloadTooLarge,
    /// 모르는 kind이거나 v1 미정의 flag 비트인데 optional이 아니다 — 안전하게 무시할 수 없어 connection을 닫는다.
    UnknownRequiredFrame,
    IncompatibleMajor,
    OutOfMemory,
};
pub const ObservedParseError = ParseError || error{
    PayloadIdentityExhausted,
    PayloadProvenanceRejected,
};

pub const PayloadAllocationObserver = struct {
    context: *anyopaque,
    reserve_fn: *const fn (*anyopaque, usize, std.mem.Allocator) error{
        OutOfMemory,
        IdentityExhausted,
        ProtocolError,
    }!u64,
    commit_fn: *const fn (*anyopaque, u64, []u8, std.mem.Allocator) error{ProtocolError}!void,
    abort_fn: *const fn (*anyopaque, u64) void,
    discard_fn: *const fn (*anyopaque, u64) void,
};
pub const EncodeError = error{ PayloadTooLarge, OutOfMemory };
pub const NormalizeError = error{ ResidentTooLarge, MalformedState, OutOfMemory };
pub const NormalizeCommitOutcome = enum { committed, quarantined };

const NormalizeLifecycle = enum { empty, prepared, committed, aborted };

/// Address-bound replacement staged without mutating its source parser.
///
/// The caller must keep this value at its final address. `validate` compares both the parser
/// descriptor and the unread bytes, so a stale or bitwise-copied token cannot authorize a swap.
pub const PreparedNormalizeExact = struct {
    saved_self_addr: usize = 0,
    source_addr: usize = 0,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    source_items_addr: usize = 0,
    source_items_len: usize = 0,
    source_capacity: usize = 0,
    source_head: usize = 0,
    expected_major: u16 = 0,
    replacement_addr: usize = 0,
    replacement_len: usize = 0,
    replacement: ?[]u8 = null,
    normalize_primary_allocator: ?std.mem.Allocator = null,
    normalize_cleanup_allocator: ?std.mem.Allocator = null,
    cleanup_replacement: ?[]u8 = null,
    lifecycle: NormalizeLifecycle = .empty,

    pub fn deinit(self: *PreparedNormalizeExact) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        if (self.lifecycle == .prepared) {
            const replacement = canonicalReplacement(self);
            const allocator = canonicalAllocator(self);
            self.replacement = null;
            self.normalize_primary_allocator = null;
            self.normalize_cleanup_allocator = null;
            self.cleanup_replacement = null;
            self.lifecycle = .aborted;
            if (replacement) |bytes| {
                if (allocator) |owner| owner.free(bytes);
            }
            return;
        }
        self.replacement = null;
        self.normalize_primary_allocator = null;
        self.normalize_cleanup_allocator = null;
        self.cleanup_replacement = null;
        self.lifecycle = .aborted;
    }

    pub fn validate(
        self: *const PreparedNormalizeExact,
        source: *const FrameParser,
    ) bool {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            self.source_addr != @intFromPtr(source) or
            self.allocator_ptr_addr != @intFromPtr(source.allocator.ptr) or
            self.allocator_vtable_addr != @intFromPtr(source.allocator.vtable) or
            self.source_items_addr != backingAddress(source.buf.items, source.buf.capacity) or
            self.source_items_len != source.buf.items.len or
            self.source_capacity != source.buf.capacity or
            self.source_head != source.head or
            self.expected_major != source.expected_major or
            !optionalAllocatorMatches(
                self.normalize_primary_allocator,
                self.allocator_ptr_addr,
                self.allocator_vtable_addr,
            ) or
            !allocatorMatches(
                self.normalize_cleanup_allocator orelse return false,
                self.allocator_ptr_addr,
                self.allocator_vtable_addr,
            ) or
            !optionalSliceMatchesSeal(
                self.replacement,
                self.replacement_addr,
                self.replacement_len,
            ) or
            !optionalSliceMatchesSeal(
                self.cleanup_replacement,
                self.replacement_addr,
                self.replacement_len,
            ) or
            source.head > source.buf.items.len or
            source.buf.items.len > source.buf.capacity)
            return false;
        const unread = source.buf.items[source.head..];
        return if (self.replacement) |replacement|
            replacement.len == unread.len and std.mem.eql(u8, replacement, unread)
        else
            unread.len == 0;
    }
};

fn allocatorMatches(allocator: std.mem.Allocator, ptr_addr: usize, vtable_addr: usize) bool {
    return @intFromPtr(allocator.ptr) == ptr_addr and
        @intFromPtr(allocator.vtable) == vtable_addr;
}

fn optionalAllocatorMatches(
    allocator: ?std.mem.Allocator,
    ptr_addr: usize,
    vtable_addr: usize,
) bool {
    return if (allocator) |value| allocatorMatches(value, ptr_addr, vtable_addr) else false;
}

fn optionalSliceMatchesSeal(slice: ?[]const u8, addr: usize, len: usize) bool {
    if (len == 0) return slice == null and addr == 0;
    return if (slice) |bytes| @intFromPtr(bytes.ptr) == addr and bytes.len == len else false;
}

fn canonicalAllocator(prepared: *const PreparedNormalizeExact) ?std.mem.Allocator {
    if (optionalAllocatorMatches(
        prepared.normalize_cleanup_allocator,
        prepared.allocator_ptr_addr,
        prepared.allocator_vtable_addr,
    )) return prepared.normalize_cleanup_allocator;
    if (optionalAllocatorMatches(
        prepared.normalize_primary_allocator,
        prepared.allocator_ptr_addr,
        prepared.allocator_vtable_addr,
    )) return prepared.normalize_primary_allocator;
    return null;
}

fn canonicalReplacement(prepared: *const PreparedNormalizeExact) ?[]u8 {
    if (optionalSliceMatchesSeal(
        prepared.cleanup_replacement,
        prepared.replacement_addr,
        prepared.replacement_len,
    )) return prepared.cleanup_replacement;
    if (optionalSliceMatchesSeal(
        prepared.replacement,
        prepared.replacement_addr,
        prepared.replacement_len,
    )) return prepared.replacement;
    return null;
}

fn sliceAddress(bytes: []const u8) usize {
    return if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr);
}

fn backingAddress(bytes: []const u8, capacity: usize) usize {
    return if (capacity == 0) 0 else @intFromPtr(bytes.ptr);
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

/// 받은 바이트를 누적하다 완성된 frame을 하나씩 꺼내는 state machine. 소유는 caller(push/next/deinit).
pub const FrameParser = struct {
    allocator: std.mem.Allocator,
    expected_major: u16,
    /// 아직 완성 frame으로 소비되지 않은 바이트. header+payload 경계로 `next()`가 잘라 낸다.
    buf: std.ArrayListUnmanaged(u8) = .empty,
    head: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FrameParser {
        return initForMajor(allocator, protocol.version_major);
    }

    pub fn initForMajor(allocator: std.mem.Allocator, expected_major: u16) FrameParser {
        return .{ .allocator = allocator, .expected_major = expected_major };
    }

    pub fn usesAllocator(self: *const FrameParser, allocator: std.mem.Allocator) bool {
        return std.meta.eql(self.allocator, allocator);
    }

    pub fn restoreAllocatorAfterDrift(self: *FrameParser, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
    }

    pub fn deinit(self: *FrameParser) void {
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    /// socket에서 읽은 바이트를 누적한다. 여러 frame이 한 번에 와도 되고, 한 frame이 여러 push에 쪼개져도 된다.
    pub fn push(self: *FrameParser, bytes: []const u8) ParseError!void {
        self.compactIfUseful();
        self.buf.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
    }

    /// Readiness adapter admission with a physical allocation ceiling. Dead prefix is compacted
    /// before every bounded append and precise growth prevents ArrayList's geometric spare
    /// capacity from exceeding `resident_cap`.
    pub fn pushBounded(
        self: *FrameParser,
        bytes: []const u8,
        resident_cap: usize,
    ) ParseError!void {
        self.compactAll();
        const next_len = std.math.add(usize, self.buf.items.len, bytes.len) catch
            return error.PayloadTooLarge;
        if (next_len > resident_cap) return error.PayloadTooLarge;
        self.buf.ensureTotalCapacityPrecise(self.allocator, next_len) catch
            return error.OutOfMemory;
        self.buf.appendSliceAssumeCapacity(bytes);
    }

    /// 완성된 다음 frame을 꺼낸다(버퍼에서 제거). 부족하면 null(더 push하라). optional unknown frame은 조용히
    /// skip하고 그 다음 처리 대상 frame을 찾는다. cap 초과·bad magic·unknown required는 error(connection 닫기).
    pub fn next(self: *FrameParser) ParseError!?Frame {
        return self.nextWithAllocator(null);
    }

    pub fn nextWithAllocator(
        self: *FrameParser,
        payload_allocator_out: ?*std.mem.Allocator,
    ) ParseError!?Frame {
        while (true) {
            const outcome = self.nextOutcomeWithAllocator(payload_allocator_out, null) catch |err|
                return narrowUnobservedError(err);
            switch (outcome) {
                .incomplete => return null,
                .skipped => continue,
                .frame => |frame| return frame,
            }
        }
    }

    pub fn nextWithPayloadObserver(
        self: *FrameParser,
        payload_allocator_out: ?*std.mem.Allocator,
        observer: PayloadAllocationObserver,
    ) ObservedParseError!?Frame {
        while (true) {
            const outcome = try self.nextOutcomeWithAllocator(payload_allocator_out, observer);
            switch (outcome) {
                .incomplete => return null,
                .skipped => continue,
                .frame => |frame| return frame,
            }
        }
    }

    /// Reactor-facing parser step. Unlike `next`, this returns after consuming exactly one optional
    /// frame so skipped extension traffic is charged to the same per-turn frame budget as known
    /// frames and cannot monopolize the owner loop.
    pub const Outcome = union(enum) {
        incomplete,
        skipped,
        frame: Frame,
    };

    pub fn nextOutcome(self: *FrameParser) ParseError!Outcome {
        return self.nextOutcomeWithAllocator(null, null) catch |err|
            return narrowUnobservedError(err);
    }

    fn nextOutcomeWithAllocator(
        self: *FrameParser,
        payload_allocator_out: ?*std.mem.Allocator,
        observer: ?PayloadAllocationObserver,
    ) ObservedParseError!Outcome {
        const pending = self.buf.items[self.head..];
        if (pending.len < protocol.header_size) return .incomplete;
        const header_bytes: *const [protocol.header_size]u8 = @ptrCast(pending.ptr);
        const header = protocol.Header.decode(header_bytes) catch return error.BadMagic;
        if (header.major != self.expected_major) return error.IncompatibleMajor;
        if (header.payload_len > protocol.maxPayloadForKind(header.kind))
            return error.PayloadTooLarge;
        const total = protocol.header_size + @as(usize, header.payload_len);
        if (pending.len < total) return .incomplete;
        const understood = header.kind.isKnown() and
            !protocol.Flags.hasUnknownBits(header.flags);
        if (!understood) {
            if (!protocol.Flags.isOptional(header.flags))
                return error.UnknownRequiredFrame;
            self.consume(total);
            return .skipped;
        }
        const payload_allocator = self.allocator;
        const observer_reservation: ?u64 = if (observer) |active|
            active.reserve_fn(active.context, header.payload_len, payload_allocator) catch |err|
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.IdentityExhausted => error.PayloadIdentityExhausted,
                    error.ProtocolError => error.PayloadProvenanceRejected,
                }
        else
            null;
        const payload = payload_allocator.dupe(
            u8,
            pending[protocol.header_size..total],
        ) catch {
            if (observer) |active| active.abort_fn(active.context, observer_reservation.?);
            return error.OutOfMemory;
        };
        if (observer) |active| active.commit_fn(
            active.context,
            observer_reservation.?,
            payload,
            payload_allocator,
        ) catch {
            active.abort_fn(active.context, observer_reservation.?);
            payload_allocator.free(payload);
            return error.PayloadProvenanceRejected;
        };
        self.consume(total);
        if (payload_allocator_out) |out| out.* = payload_allocator;
        return .{ .frame = .{
            .header = header,
            .payload = payload,
            .payload_observation_generation = observer_reservation orelse 0,
        } };
    }

    pub fn bufferedBytes(self: *const FrameParser) usize {
        return self.buf.items.len - self.head;
    }

    pub fn residentBytes(self: *const FrameParser) usize {
        return self.buf.capacity;
    }

    /// Stage exact unread storage while preserving the source parser byte-for-byte on every
    /// failure. `out` must be pristine and remain at this address until commit or deinit.
    pub fn prepareNormalizeExact(
        self: *const FrameParser,
        out: *PreparedNormalizeExact,
        resident_cap: usize,
    ) NormalizeError!void {
        if (self.buf.capacity > resident_cap) return error.ResidentTooLarge;
        if (self.head > self.buf.items.len or self.buf.items.len > self.buf.capacity)
            return error.MalformedState;
        if (rangesOverlap(
            @intFromPtr(self),
            @sizeOf(FrameParser),
            backingAddress(self.buf.items, self.buf.capacity),
            self.buf.capacity,
        )) return error.MalformedState;
        if (rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedNormalizeExact),
            @intFromPtr(self),
            @sizeOf(FrameParser),
        ) or rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedNormalizeExact),
            backingAddress(self.buf.items, self.buf.capacity),
            self.buf.capacity,
        )) return error.MalformedState;
        if (out.lifecycle != .empty or out.replacement != null or
            out.normalize_primary_allocator != null or out.normalize_cleanup_allocator != null or
            out.cleanup_replacement != null)
            return error.MalformedState;
        const unread = self.buf.items[self.head..];
        const replacement = if (unread.len == 0)
            null
        else
            self.allocator.dupe(u8, unread) catch return error.OutOfMemory;
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .source_addr = @intFromPtr(self),
            .allocator_ptr_addr = @intFromPtr(self.allocator.ptr),
            .allocator_vtable_addr = @intFromPtr(self.allocator.vtable),
            .source_items_addr = backingAddress(self.buf.items, self.buf.capacity),
            .source_items_len = self.buf.items.len,
            .source_capacity = self.buf.capacity,
            .source_head = self.head,
            .expected_major = self.expected_major,
            .replacement_addr = if (replacement) |bytes| @intFromPtr(bytes.ptr) else 0,
            .replacement_len = if (replacement) |bytes| bytes.len else 0,
            .replacement = replacement,
            .normalize_primary_allocator = self.allocator,
            .normalize_cleanup_allocator = self.allocator,
            .cleanup_replacement = replacement,
            .lifecycle = .prepared,
        };
    }

    /// No-fail ownership suffix. Callers must validate immediately before entering the suffix.
    pub fn commitPreparedNormalizeExact(
        self: *FrameParser,
        prepared: *PreparedNormalizeExact,
    ) NormalizeCommitOutcome {
        if (!prepared.validate(self)) @panic("invalid prepared parser normalization");
        const allocator = self.allocator;
        var old = self.buf;
        const replacement = prepared.cleanup_replacement;
        const final_buf: std.ArrayListUnmanaged(u8) = if (replacement) |owned| .{
            .items = owned,
            .capacity = owned.len,
        } else .empty;
        // Publish and tombstone every ownership header before the old-backing free callback.
        // The caller validates normalized content and immutable parser metadata again after this
        // callback, so re-entry cannot silently authorize a different bind.
        self.buf = final_buf;
        self.head = 0;
        prepared.replacement = null;
        prepared.normalize_primary_allocator = null;
        prepared.normalize_cleanup_allocator = null;
        prepared.cleanup_replacement = null;
        prepared.lifecycle = .committed;
        const final_allocator = self.allocator;
        const final_expected_major = self.expected_major;
        var final_digest = [_]u8{0} ** 32;
        if (final_buf.items.len != 0)
            std.crypto.hash.Blake3.hash(final_buf.items, &final_digest, .{});
        old.deinit(allocator);
        const descriptor_matches =
            @intFromPtr(self.allocator.ptr) == @intFromPtr(final_allocator.ptr) and
            @intFromPtr(self.allocator.vtable) == @intFromPtr(final_allocator.vtable) and
            self.expected_major == final_expected_major and
            self.head == 0 and
            self.buf.capacity == final_buf.capacity and
            self.buf.items.len == final_buf.items.len and
            (self.buf.capacity == 0 or
                @intFromPtr(self.buf.items.ptr) == @intFromPtr(final_buf.items.ptr));
        var observed_digest = [_]u8{0} ** 32;
        if (descriptor_matches and final_buf.items.len != 0)
            std.crypto.hash.Blake3.hash(final_buf.items, &observed_digest, .{});
        const content_matches = descriptor_matches and
            std.mem.eql(u8, &final_digest, &observed_digest);
        if (!content_matches) {
            self.allocator = final_allocator;
            self.expected_major = final_expected_major;
            self.buf = .empty;
            self.head = 0;
            return .quarantined;
        }
        return .committed;
    }

    /// Rebind a validated token after its parser value is moved byte-for-byte to final storage.
    /// No allocation or allocator callback occurs here.
    pub fn rebindPreparedNormalizeExact(
        self: *const FrameParser,
        prepared: *PreparedNormalizeExact,
        destination: *const FrameParser,
    ) void {
        if (!prepared.validate(self)) @panic("invalid parser normalization rebind");
        prepared.source_addr = @intFromPtr(destination);
        if (!prepared.validate(destination)) @panic("parser normalization move changed state");
    }

    pub const BufferState = enum { empty, incomplete, complete_or_error };

    /// Readiness owner distinguishes a true partial frame (deadline applies) from a complete
    /// frame left behind by the 64-frame turn cap (schedule immediately, no socket read).
    pub fn bufferState(self: *const FrameParser) BufferState {
        const pending = self.buf.items[self.head..];
        if (pending.len == 0) return .empty;
        if (pending.len < protocol.header_size) return .incomplete;
        const header_bytes: *const [protocol.header_size]u8 = @ptrCast(pending.ptr);
        const header = protocol.Header.decode(header_bytes) catch return .complete_or_error;
        if (header.payload_len > protocol.maxPayloadForKind(header.kind))
            return .complete_or_error;
        const total = protocol.header_size + @as(usize, header.payload_len);
        return if (pending.len < total) .incomplete else .complete_or_error;
    }

    /// 버퍼 앞에서 `count`바이트를 제거하고 나머지를 앞으로 당긴다(capacity는 유지 — 다음 frame 재사용).
    fn consume(self: *FrameParser, count: usize) void {
        std.debug.assert(count <= self.bufferedBytes());
        self.head += count;
        if (self.head == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.head = 0;
        }
    }

    /// Avoid per-frame memmove. Compaction is amortized and happens only before append, after at
    /// least 64 KiB and half the resident buffer became dead prefix.
    fn compactIfUseful(self: *FrameParser) void {
        if (self.head < 64 * 1024 or self.head * 2 < self.buf.items.len) return;
        self.compactAll();
    }

    fn compactAll(self: *FrameParser) void {
        if (self.head == 0) return;
        const remaining = self.bufferedBytes();
        std.mem.copyForwards(
            u8,
            self.buf.items[0..remaining],
            self.buf.items[self.head..],
        );
        self.buf.shrinkRetainingCapacity(remaining);
        self.head = 0;
    }
};

fn narrowUnobservedError(err: ObservedParseError) ParseError {
    return switch (err) {
        error.BadMagic => error.BadMagic,
        error.IncompatibleMajor => error.IncompatibleMajor,
        error.OutOfMemory => error.OutOfMemory,
        error.PayloadTooLarge => error.PayloadTooLarge,
        error.UnknownRequiredFrame => error.UnknownRequiredFrame,
        error.PayloadIdentityExhausted, error.PayloadProvenanceRejected => unreachable,
    };
}

/// 한 frame(header + payload)을 하나의 연속 버퍼로 직렬화한다(caller 소유). socket write loop가 이 버퍼를 partial write로
/// 흘려 보낸다. payload가 kind cap을 넘으면 `PayloadTooLarge`(보내는 쪽에서도 계약 위반을 조기에 잡는다).
pub fn encodeFrame(
    allocator: std.mem.Allocator,
    header_in: protocol.Header,
    payload: []const u8,
) EncodeError![]u8 {
    if (payload.len > protocol.maxPayloadForKind(header_in.kind)) return error.PayloadTooLarge;
    var header = header_in;
    header.payload_len = @intCast(payload.len);
    var out = allocator.alloc(u8, protocol.header_size + payload.len) catch return error.OutOfMemory;
    @memcpy(out[0..protocol.header_size], &header.encode());
    @memcpy(out[protocol.header_size..], payload);
    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): non-blocking session-host socket은 frame을 임의 경계로
// 쪼개 전달한다. parser가 partial header/payload를 견디고, 한 read에 여러 frame이 와도 순서대로 꺼내며, oversize
// 선언·bad magic·unknown required를 payload 적재 전에 거부하고, optional unknown은 안전히 skip해야 — 재접속·screen
// stream이 엉키지 않는다. 순수 state machine이라 실제 socket 없이 non-macOS에서 회귀를 고정한다.
// ─────────────────────────────────────────────────────────────────────────────

test "framing: parses a whole frame and returns owned payload" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();

    const wire = try encodeFrame(allocator, .{ .kind = .request, .request_id = 42 }, "hello world");
    defer allocator.free(wire);

    try parser.push(wire);
    const frame = (try parser.next()).?;
    defer frame.deinit(allocator);
    try std.testing.expectEqual(protocol.Kind.request, frame.header.kind);
    try std.testing.expectEqual(@as(u64, 42), frame.header.request_id);
    try std.testing.expectEqualStrings("hello world", frame.payload);
    try std.testing.expect((try parser.next()) == null); // 더 없음
}

test "framing: reassembles a frame split across many pushes (partial I/O)" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();

    const wire = try encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 7 }, "abcdef");
    defer allocator.free(wire);

    // 1바이트씩 흘려 넣는다 — 마지막 바이트 전까지는 항상 null(미완성).
    for (wire[0 .. wire.len - 1]) |b| {
        try parser.push(&.{b});
        try std.testing.expect((try parser.next()) == null);
    }
    try parser.push(wire[wire.len - 1 ..]);
    const frame = (try parser.next()).?;
    defer frame.deinit(allocator);
    try std.testing.expectEqual(protocol.Kind.input_bytes, frame.header.kind);
    try std.testing.expectEqualStrings("abcdef", frame.payload);
}

test "framing: yields multiple frames from a single push in order" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();

    const a = try encodeFrame(allocator, .{ .kind = .ping, .request_id = 1 }, "");
    defer allocator.free(a);
    const b = try encodeFrame(allocator, .{ .kind = .request, .request_id = 2 }, "cmd");
    defer allocator.free(b);
    const both = try std.mem.concat(allocator, u8, &.{ a, b });
    defer allocator.free(both);

    try parser.push(both);
    const f1 = (try parser.next()).?;
    defer f1.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), f1.header.request_id);
    const f2 = (try parser.next()).?;
    defer f2.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), f2.header.request_id);
    try std.testing.expectEqualStrings("cmd", f2.payload);
    try std.testing.expect((try parser.next()) == null);
}

test "framing: rejects oversize payload before buffering it" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();

    // request(control)는 256 KiB cap. 그보다 큰 payload_len을 선언한 header만 push해도(payload는 아직 안 보냄) 거부.
    var header = (protocol.Header{ .kind = .request }).encode();
    std.mem.writeInt(u32, header[28..32], protocol.max_control_json + 1, .big);
    try parser.push(&header);
    try std.testing.expectError(error.PayloadTooLarge, parser.next());
}

test "framing: rejects non-MRSH magic" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    var junk = [_]u8{0} ** protocol.header_size;
    @memcpy(junk[0..4], "XXXX");
    try parser.push(&junk);
    try std.testing.expectError(error.BadMagic, parser.next());
}

test "framing: unknown required kind closes; unknown optional kind is skipped" {
    const allocator = std.testing.allocator;

    // (1) unknown required → error.
    {
        var parser = FrameParser.init(allocator);
        defer parser.deinit();
        var h = (protocol.Header{ .kind = .request }).encode();
        std.mem.writeInt(u16, h[6..8], 55000, .big); // 미지 kind, optional flag 없음
        try parser.push(&h);
        try std.testing.expectError(error.UnknownRequiredFrame, parser.next());
    }
    // (2) unknown optional → skip하고 그 다음 known frame을 반환.
    {
        var parser = FrameParser.init(allocator);
        defer parser.deinit();
        const skipped = try encodeFrame(allocator, .{ .kind = @enumFromInt(55001), .flags = protocol.Flags.optional }, "ignore me");
        defer allocator.free(skipped);
        const real = try encodeFrame(allocator, .{ .kind = .response, .request_id = 9 }, "ok");
        defer allocator.free(real);
        const both = try std.mem.concat(allocator, u8, &.{ skipped, real });
        defer allocator.free(both);
        try parser.push(both);
        const frame = (try parser.next()).?;
        defer frame.deinit(allocator);
        try std.testing.expectEqual(@as(u64, 9), frame.header.request_id);
        try std.testing.expectEqualStrings("ok", frame.payload);
    }
}

test "framing: reactor step charges every optional frame instead of skipping without bound" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    const header = (protocol.Header{
        .kind = @enumFromInt(55_000),
        .flags = protocol.Flags.optional,
    }).encode();
    for (0..65) |_| try parser.push(&header);
    for (0..64) |_| switch (try parser.nextOutcome()) {
        .skipped => {},
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, protocol.header_size), parser.bufferedBytes());
    switch (try parser.nextOutcome()) {
        .skipped => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), parser.bufferedBytes());
}

test "framing: large optional backlog advances a cursor without per-frame memmove" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    const header = (protocol.Header{
        .kind = @enumFromInt(55_000),
        .flags = protocol.Flags.optional,
    }).encode();
    for (0..32 * 1024) |_| try parser.push(&header);
    const resident_before = parser.buf.items.len;
    for (0..64) |_| switch (try parser.nextOutcome()) {
        .skipped => {},
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, protocol.header_size * 64), parser.head);
    try std.testing.expectEqual(resident_before, parser.buf.items.len);
    try std.testing.expectEqual(
        resident_before - protocol.header_size * 64,
        parser.bufferedBytes(),
    );
}

test "framing: optional unknown frame cannot bypass exact header major" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    const header = (protocol.Header{
        .major = protocol.version_major - 1,
        .kind = @enumFromInt(55_000),
        .flags = protocol.Flags.optional,
    }).encode();
    try parser.push(&header);
    try std.testing.expectError(error.IncompatibleMajor, parser.nextOutcome());
}

test "framing: bounded append compacts dead prefix and caps physical allocation" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    const cap: usize = 1000;
    const first_payload = try allocator.alloc(u8, 368);
    defer allocator.free(first_payload);
    @memset(first_payload, 'a');
    const first = try encodeFrame(allocator, .{ .kind = .ping }, first_payload);
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 400), first.len);

    const second_header = (protocol.Header{
        .kind = .snapshot_chunk,
        .payload_len = 968,
    }).encode();
    const initial = try allocator.alloc(u8, cap);
    defer allocator.free(initial);
    @memcpy(initial[0..first.len], first);
    @memcpy(initial[first.len..][0..protocol.header_size], &second_header);
    @memset(initial[first.len + protocol.header_size ..], 'b');
    try parser.pushBounded(initial, cap);
    const consumed = switch (try parser.nextOutcome()) {
        .frame => |frame| frame,
        else => return error.TestUnexpectedResult,
    };
    consumed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 600), parser.bufferedBytes());

    const tail = try allocator.alloc(u8, 400);
    defer allocator.free(tail);
    @memset(tail, 'c');
    try parser.pushBounded(tail, cap);
    try std.testing.expect(parser.residentBytes() <= cap);
    const second = switch (try parser.nextOutcome()) {
        .frame => |frame| frame,
        else => return error.TestUnexpectedResult,
    };
    defer second.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 968), second.payload.len);
}

test "framing: unknown flag bit on a required frame closes the connection" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    var h = (protocol.Header{ .kind = .request, .flags = 0x4 }).encode(); // v1 미정의 비트, optional 아님
    try parser.push(&h);
    try std.testing.expectError(error.UnknownRequiredFrame, parser.next());
}

test "framing: prepared normalize preserves source until no-fail commit" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.initForMajor(allocator, 7);
    defer parser.deinit();
    try parser.push("deadunread");
    parser.head = 4;

    const source_addr = sliceAddress(parser.buf.items);
    const source_capacity = parser.buf.capacity;
    var prepared: PreparedNormalizeExact = .{};
    defer prepared.deinit();
    try parser.prepareNormalizeExact(&prepared, source_capacity);

    try std.testing.expectEqual(source_addr, sliceAddress(parser.buf.items));
    try std.testing.expectEqual(@as(usize, 4), parser.head);
    try std.testing.expect(prepared.validate(&parser));
    try std.testing.expectEqual(
        NormalizeCommitOutcome.committed,
        parser.commitPreparedNormalizeExact(&prepared),
    );
    try std.testing.expectEqualStrings("unread", parser.buf.items);
    try std.testing.expectEqual(@as(usize, 0), parser.head);
    try std.testing.expectEqual(parser.buf.items.len, parser.buf.capacity);
    try std.testing.expectEqual(@as(u16, 7), parser.expected_major);
}

test "framing: prepared normalize releases retained capacity when unread is empty" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push("consumed");
    parser.head = parser.buf.items.len;
    try std.testing.expect(parser.buf.capacity > 0);

    var prepared: PreparedNormalizeExact = .{};
    defer prepared.deinit();
    try parser.prepareNormalizeExact(&prepared, parser.residentBytes());
    // An empty unread window stages no replacement allocation at all.
    try std.testing.expect(prepared.replacement == null);
    try std.testing.expect(prepared.validate(&parser));

    try std.testing.expectEqual(
        NormalizeCommitOutcome.committed,
        parser.commitPreparedNormalizeExact(&prepared),
    );
    try std.testing.expectEqual(@as(usize, 0), parser.buf.capacity);
    try std.testing.expectEqual(@as(usize, 0), parser.buf.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.head);
}

test "framing: prepared normalize rejects malformed head without mutation" {
    var parser = FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.push("pending");
    const original_head = parser.head;
    const original_addr = sliceAddress(parser.buf.items);
    parser.head = parser.buf.items.len + 1;

    var prepared: PreparedNormalizeExact = .{};
    defer prepared.deinit();
    try std.testing.expectError(
        error.MalformedState,
        parser.prepareNormalizeExact(&prepared, parser.residentBytes()),
    );
    try std.testing.expectEqual(NormalizeLifecycle.empty, prepared.lifecycle);
    try std.testing.expectEqual(original_addr, sliceAddress(parser.buf.items));
    parser.head = original_head;
}

test "framing: prepared normalize rejects moved token and stale source content" {
    var parser = FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.push("pending");

    var prepared: PreparedNormalizeExact = .{};
    defer prepared.deinit();
    try parser.prepareNormalizeExact(&prepared, parser.residentBytes());
    var copied = prepared;
    defer copied.deinit();
    try std.testing.expect(!copied.validate(&parser));

    parser.buf.items[0] = 'P';
    try std.testing.expect(!prepared.validate(&parser));
    parser.buf.items[0] = 'p';
    try std.testing.expect(prepared.validate(&parser));
}

test "framing: prepared normalize cleanup mirror ignores poisoned replacement descriptor" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push("pending");
    var prepared: PreparedNormalizeExact = .{};
    defer prepared.deinit();
    try parser.prepareNormalizeExact(&prepared, parser.residentBytes());
    const poisoned = try allocator.dupe(u8, "poison!");
    prepared.replacement = poisoned;
    try std.testing.expect(!prepared.validate(&parser));
    prepared.deinit(); // canonical replacement is freed; poisoned bytes are not treated as owned.
    allocator.free(poisoned);
}

test "framing: prepared normalize primary mirror recovers cleanup descriptor drift" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push("pending");
    var prepared: PreparedNormalizeExact = .{};
    defer prepared.deinit();
    try parser.prepareNormalizeExact(&prepared, parser.residentBytes());
    const poisoned = try allocator.dupe(u8, "poison!");
    prepared.cleanup_replacement = poisoned;
    try std.testing.expect(!prepared.validate(&parser));
    prepared.deinit(); // primary descriptor still identifies the canonical replacement.
    allocator.free(poisoned);
}

test "framing: prepared normalize OOM and cap failure preserve source and destination" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var parser = FrameParser.init(failing.allocator());
    defer parser.deinit();
    try parser.push("12345678");
    const before = parser.bufferedBytes();
    const before_addr = sliceAddress(parser.buf.items);

    var prepared: PreparedNormalizeExact = .{};
    defer prepared.deinit();
    try std.testing.expectError(
        error.ResidentTooLarge,
        parser.prepareNormalizeExact(&prepared, parser.residentBytes() - 1),
    );
    try std.testing.expectEqual(NormalizeLifecycle.empty, prepared.lifecycle);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        parser.prepareNormalizeExact(&prepared, parser.residentBytes()),
    );
    try std.testing.expectEqual(NormalizeLifecycle.empty, prepared.lifecycle);
    try std.testing.expectEqual(before, parser.bufferedBytes());
    try std.testing.expectEqual(before_addr, sliceAddress(parser.buf.items));
}

test "framing: prepared normalize rejects parser backing that aliases its owner" {
    var parser = FrameParser.init(std.testing.allocator);
    const self_bytes: [*]u8 = @ptrCast(&parser);
    parser.buf = .{
        .items = self_bytes[0..1],
        .capacity = @sizeOf(FrameParser),
    };
    var prepared: PreparedNormalizeExact = .{};
    defer prepared.deinit();
    try std.testing.expectError(
        error.MalformedState,
        parser.prepareNormalizeExact(&prepared, @sizeOf(FrameParser)),
    );
    parser.buf = .empty; // the forged stack alias was never owned.
    parser.deinit();
}

const NormalizeReentrantFreeAllocator = struct {
    parent: std.mem.Allocator,
    target: ?*PreparedNormalizeExact = null,
    free_calls: usize = 0,
    reentered: bool = false,

    fn allocator(self: *NormalizeReentrantFreeAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *NormalizeReentrantFreeAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *NormalizeReentrantFreeAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *NormalizeReentrantFreeAllocator = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *NormalizeReentrantFreeAllocator = @ptrCast(@alignCast(context));
        self.free_calls += 1;
        if (!self.reentered) {
            self.reentered = true;
            if (self.target) |target| target.deinit();
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

test "framing: prepared normalize tombstones before allocator free callback reentry" {
    var probe = NormalizeReentrantFreeAllocator{ .parent = std.testing.allocator };
    var parser = FrameParser.init(probe.allocator());
    defer {
        probe.target = null;
        parser.deinit();
    }
    try parser.push("pending");
    var prepared: PreparedNormalizeExact = .{};
    try parser.prepareNormalizeExact(&prepared, parser.residentBytes());
    probe.target = &prepared;
    prepared.deinit();
    try std.testing.expect(probe.reentered);
    try std.testing.expectEqual(@as(usize, 1), probe.free_calls);
    try std.testing.expect(prepared.lifecycle == .aborted);
}

test "B3-0a payload observer sees only completed known frame payload allocation" {
    const allocator = std.testing.allocator;
    const Probe = struct {
        reserve_count: usize = 0,
        commit_count: usize = 0,
        abort_count: usize = 0,
        last_len: usize = 0,

        fn observer(self: *@This()) PayloadAllocationObserver {
            return .{
                .context = self,
                .reserve_fn = reserve,
                .commit_fn = commit,
                .abort_fn = abort,
                .discard_fn = discard,
            };
        }

        fn reserve(
            context: *anyopaque,
            len: usize,
            _: std.mem.Allocator,
        ) error{ OutOfMemory, IdentityExhausted, ProtocolError }!u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.reserve_count += 1;
            self.last_len = len;
            return self.reserve_count;
        }

        fn commit(
            context: *anyopaque,
            _: u64,
            payload: []u8,
            _: std.mem.Allocator,
        ) error{ProtocolError}!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (payload.len != self.last_len) return error.ProtocolError;
            self.commit_count += 1;
        }

        fn abort(context: *anyopaque, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.abort_count += 1;
        }

        fn discard(_: *anyopaque, _: u64) void {}
    };

    const wire = try encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 7 },
        "payload",
    );
    defer allocator.free(wire);
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push(wire[0 .. wire.len - 1]);
    var probe: Probe = .{};
    try std.testing.expect((try parser.nextWithPayloadObserver(null, probe.observer())) == null);
    try std.testing.expectEqual(@as(usize, 0), probe.reserve_count);
    try parser.push(wire[wire.len - 1 ..]);
    const frame = (try parser.nextWithPayloadObserver(null, probe.observer())).?;
    defer frame.deinit(allocator);
    try std.testing.expectEqualStrings("payload", frame.payload);
    try std.testing.expectEqual(@as(usize, 1), probe.reserve_count);
    try std.testing.expectEqual(@as(usize, 1), probe.commit_count);
    try std.testing.expectEqual(@as(usize, 0), probe.abort_count);
}

test "B3-0a payload observer aborts reservation when payload allocation fails" {
    const allocator = std.testing.allocator;
    const Probe = struct {
        reserved: bool = false,
        aborted: bool = false,

        fn observer(self: *@This()) PayloadAllocationObserver {
            return .{
                .context = self,
                .reserve_fn = reserve,
                .commit_fn = commit,
                .abort_fn = abort,
                .discard_fn = discard,
            };
        }
        fn reserve(_: *anyopaque, _: usize, _: std.mem.Allocator) error{
            OutOfMemory,
            IdentityExhausted,
            ProtocolError,
        }!u64 {
            return 1;
        }
        fn commit(_: *anyopaque, _: u64, _: []u8, _: std.mem.Allocator) error{ProtocolError}!void {}
        fn abort(context: *anyopaque, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.aborted = true;
        }
        fn discard(_: *anyopaque, _: u64) void {}
    };
    const Failing = struct {
        fn makeAllocator() std.mem.Allocator {
            return .{ .ptr = undefined, .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            } };
        }
        fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            return null;
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
    };

    const wire = try encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 8 },
        "x",
    );
    defer allocator.free(wire);
    var parser = FrameParser.init(Failing.makeAllocator());
    defer parser.deinit();
    // Seed through the test allocator so only the owned payload allocation uses the failure path.
    parser.allocator = allocator;
    try parser.push(wire);
    parser.allocator = Failing.makeAllocator();
    var probe: Probe = .{};
    try std.testing.expectError(
        error.OutOfMemory,
        parser.nextWithPayloadObserver(null, probe.observer()),
    );
    try std.testing.expect(probe.aborted);
    parser.allocator = allocator;
}
