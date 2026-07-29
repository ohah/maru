//! One-way blocking-to-external fd mode transaction.
//!
//! This leaf owns only the external-mode storage inventory and exact fd-flag rollback policy.
//! `Client` remains the fd/parser owner and decides when an indeterminate transition poisons and
//! closes the connection.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const protocol = @import("protocol.zig");
const framing = @import("framing.zig");
const owner_seal = @import("external_owner_seal.zig");
const external_rx_types = @import("external_rx_types.zig");

pub const max_tx_frames: usize = 64;

pub const ExternalTxFrame = struct {
    bytes: []u8,
    offset: usize = 0,
    kind: protocol.Kind,
    stream_id: u64,
    request_id: u64,
    activated_at_ns: i128,
    last_progress_at_ns: i128,
};

pub const RxProvenanceLifecycle = enum { unbound, bound, terminal };

pub const RxIdentity = external_rx_types.RxIdentity;

pub const ParserAuthoritySeal = struct {
    domain: [8]u8 = [_]u8{0} ** 8,
    version: u16 = 0,
    seal_addr: usize = 0,
    parser_addr: usize = 0,
    identity: RxIdentity = .{},
    destination_slot_len: usize = 0,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    expected_major: u16 = 0,
    backing_addr: usize = 0,
    items_len: usize = 0,
    capacity: usize = 0,
    head: usize = 0,
    buffer_start_absolute: u64 = 0,
    rx_absolute_next: u64 = 0,
    generation: u64 = 0,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
};

pub const RxProvenance = struct {
    identity: ?RxIdentity = null,
    destination_slot_len: usize = 0,
    rx_absolute_next: u64 = 0,
    buffer_start_absolute: u64 = 0,
    parser_seal: ParserAuthoritySeal = .{},
    lifecycle: RxProvenanceLifecycle = .unbound,
};

pub const RxRange = external_rx_types.RxRange;
pub const RxWatermark = external_rx_types.RxWatermark;
pub const ExternalRxFrameSeal = owner_seal.Digest;

pub const ExternalRxFrame = struct {
    frame: framing.Frame,
    range: RxRange,
    pair_seal: ExternalRxFrameSeal,
};

pub const MaxReadableResult = union(enum) {
    bytes: usize,
    turn_exhausted,
    resident_exhausted,
    counter_exhausted,
    invalid,
};

pub const Freshness = enum { fresh, stale, invalid };

pub const ExternalRxOutcome = union(enum) {
    incomplete,
    skipped: RxRange,
    frame: ExternalRxFrame,
};

pub const State = struct {
    saved_flags: c_int,
    external_tx: std.ArrayListUnmanaged(ExternalTxFrame) = .empty,
    external_tx_bytes: usize = 0,
    rx_provenance: RxProvenance = .{},
    rx_operation_busy: bool = false,
    fn stage(allocator: std.mem.Allocator) error{OutOfMemory}!State {
        var result = State{ .saved_flags = 0 };
        result.external_tx.ensureTotalCapacityPrecise(allocator, max_tx_frames) catch
            return error.OutOfMemory;
        return result;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.external_tx.items) |frame| allocator.free(frame.bytes);
        self.external_tx.deinit(allocator);
        self.* = undefined;
    }
};

const PreparedLifecycle = enum { empty, prepared, committed, aborted };

pub const PreparedRxBind = struct {
    saved_self_addr: usize = 0,
    source_state_addr: usize = 0,
    destination_slot_addr: usize = 0,
    destination_slot_len: usize = 0,
    normalized_addr: usize = 0,
    identity: ?RxIdentity = null,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    expected_major: u16 = 0,
    unread_len: u64 = 0,
    unread_digest: owner_seal.Digest = [_]u8{0} ** 32,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: PreparedLifecycle = .empty,

    pub fn deinit(self: *PreparedRxBind) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        self.* = .{ .lifecycle = .aborted };
    }

    pub fn validate(
        self: *const PreparedRxBind,
        source_state: *const State,
        attach_instance_id: u64,
        normalized: *const framing.PreparedNormalizeExact,
        destination_slot_addr: usize,
        destination_slot_len: usize,
    ) bool {
        if (self.lifecycle != .prepared or
            self.saved_self_addr != @intFromPtr(self) or
            self.source_state_addr != @intFromPtr(source_state) or
            self.normalized_addr != @intFromPtr(normalized) or
            self.destination_slot_addr != destination_slot_addr or
            self.destination_slot_len != destination_slot_len or
            self.identity == null or
            self.identity.?.attach_instance_id != attach_instance_id or
            self.identity.?.destination_slot_addr != destination_slot_addr or
            self.allocator_ptr_addr != normalized.allocator_ptr_addr or
            self.allocator_vtable_addr != normalized.allocator_vtable_addr or
            self.expected_major != normalized.expected_major or
            !std.meta.eql(source_state.rx_provenance, RxProvenance{}) or
            self.unread_len != normalized.replacement_len)
            return false;
        const unread = normalized.replacement orelse {
            if (self.unread_len != 0) return false;
            return std.mem.eql(u8, &self.digest, &rxBindDigest(self));
        };
        if (unread.len != self.unread_len or
            !std.mem.eql(u8, &self.unread_digest, &bytesDigest(unread)))
            return false;
        return std.mem.eql(u8, &self.digest, &rxBindDigest(self));
    }
};

pub const PreparedRxAppend = struct {
    saved_self_addr: usize = 0,
    state_addr: usize = 0,
    parser_addr: usize = 0,
    expected_start: u64 = 0,
    bytes_addr: usize = 0,
    bytes_len: usize = 0,
    bytes_digest: owner_seal.Digest = [_]u8{0} ** 32,
    source_seal: ParserAuthoritySeal = .{},
    unread_digest: owner_seal.Digest = [_]u8{0} ** 32,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    replacement_addr: usize = 0,
    replacement_len: usize = 0,
    final_items_len: usize = 0,
    replacement: ?[]u8 = null,
    cleanup_replacement: ?[]u8 = null,
    cleanup_digest: owner_seal.Digest = [_]u8{0} ** 32,
    digest: owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: PreparedLifecycle = .empty,

    fn deinitInternal(self: *PreparedRxAppend) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        if (self.lifecycle == .prepared) {
            const replacement = canonicalAppendReplacement(self);
            const allocator = self.allocator;
            self.replacement = null;
            self.cleanup_replacement = null;
            self.lifecycle = .aborted;
            if (replacement) |bytes| {
                allocator.free(bytes);
            }
            return;
        }
        self.replacement = null;
        self.cleanup_replacement = null;
        self.lifecycle = .aborted;
    }
};

pub const RxParseScratch = struct {
    saved_self_addr: usize = 0,
    parser_addr: usize = 0,
    source_seal: ParserAuthoritySeal = .{},
    frame_start_absolute: u64 = 0,
    frame_end_absolute: u64 = 0,
    header: ?protocol.Header = null,
    frame_digest: owner_seal.Digest = [_]u8{0} ** 32,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    allocator_ptr_addr: usize = 0,
    allocator_vtable_addr: usize = 0,
    payload_addr: usize = 0,
    payload_len: usize = 0,
    payload: ?[]u8 = null,
    cleanup_payload: ?[]u8 = null,
    cleanup_digest: owner_seal.Digest = [_]u8{0} ** 32,
    lifecycle: PreparedLifecycle = .empty,

    pub fn deinit(self: *RxParseScratch) void {
        if (self.saved_self_addr != 0 and self.saved_self_addr != @intFromPtr(self)) return;
        if (self.lifecycle == .prepared) {
            const payload = canonicalParsePayload(self);
            const allocator = self.allocator;
            self.payload = null;
            self.cleanup_payload = null;
            self.lifecycle = .aborted;
            if (payload) |owned| allocator.free(owned);
            return;
        }
        self.payload = null;
        self.cleanup_payload = null;
        self.lifecycle = .aborted;
    }
};

pub const RxPrepareError = error{
    InvalidState,
    InvalidDescriptor,
    InvalidSeal,
    InvalidIdentity,
    ArithmeticOverflow,
    ResidentCap,
    OutOfMemory,
};

pub const RxParseError = error{
    InvalidState,
    InvalidDescriptor,
    InvalidSeal,
    ArithmeticOverflow,
    Protocol,
    OutOfMemory,
};

const parser_seal_domain = "MARURXP1";
const parser_seal_version: u16 = 1;

fn bytesDigest(bytes: []const u8) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-bytes.v1");
    writer.writeBytes(bytes);
    return writer.finish();
}

fn externalRxFrameDigest(frame: *const ExternalRxFrame) owner_seal.Digest {
    var writer = owner_seal.Writer.init("external-rx-frame.v1");
    writer.writeU64(frame.range.identity.attach_instance_id);
    writer.writeUsize(frame.range.identity.destination_slot_addr);
    writer.writeU64(frame.range.start_absolute);
    writer.writeU64(frame.range.end_absolute);
    const header_bytes = frame.frame.header.encode();
    writer.writeBytes(&header_bytes);
    writer.writeBytes(frame.frame.payload);
    return writer.finish();
}

pub fn validateExternalRxFrame(frame: *const ExternalRxFrame) bool {
    if (frame.range.identity.attach_instance_id == 0 or
        frame.range.identity.destination_slot_addr == 0 or
        frame.range.start_absolute >= frame.range.end_absolute or
        frame.frame.payload.len > std.math.maxInt(u32) or
        frame.frame.header.payload_len != @as(u32, @intCast(frame.frame.payload.len)))
        return false;
    const total = std.math.add(
        usize,
        protocol.header_size,
        frame.frame.payload.len,
    ) catch return false;
    const observed = std.math.sub(
        u64,
        frame.range.end_absolute,
        frame.range.start_absolute,
    ) catch return false;
    return observed == @as(u64, @intCast(total)) and
        std.mem.eql(u8, &frame.pair_seal, &externalRxFrameDigest(frame));
}

pub const testing = if (builtin.is_test) struct {
    pub fn sealExternalRxFrame(frame: *ExternalRxFrame) void {
        frame.pair_seal = externalRxFrameDigest(frame);
    }
} else struct {};

fn rxBindDigest(prepared: *const PreparedRxBind) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-bind.v1");
    writer.writeUsize(prepared.saved_self_addr);
    writer.writeUsize(prepared.source_state_addr);
    writer.writeUsize(prepared.destination_slot_addr);
    writer.writeUsize(prepared.destination_slot_len);
    writer.writeUsize(prepared.normalized_addr);
    const identity = prepared.identity orelse RxIdentity{};
    writer.writeU64(identity.attach_instance_id);
    writer.writeUsize(identity.destination_slot_addr);
    writer.writeUsize(prepared.allocator_ptr_addr);
    writer.writeUsize(prepared.allocator_vtable_addr);
    writer.writeU16(prepared.expected_major);
    writer.writeU64(prepared.unread_len);
    writer.writeBytes(&prepared.unread_digest);
    return writer.finish();
}

fn appendDigest(prepared: *const PreparedRxAppend) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-append.v1");
    writer.writeUsize(prepared.saved_self_addr);
    writer.writeUsize(prepared.state_addr);
    writer.writeUsize(prepared.parser_addr);
    writer.writeU64(prepared.expected_start);
    writer.writeUsize(prepared.bytes_addr);
    writer.writeUsize(prepared.bytes_len);
    writer.writeBytes(&prepared.bytes_digest);
    writer.writeBytes(&prepared.source_seal.digest);
    writer.writeBytes(&prepared.unread_digest);
    writer.writeUsize(prepared.allocator_ptr_addr);
    writer.writeUsize(prepared.allocator_vtable_addr);
    writer.writeUsize(prepared.replacement_addr);
    writer.writeUsize(prepared.replacement_len);
    writer.writeUsize(prepared.final_items_len);
    writer.writeBytes(&prepared.cleanup_digest);
    return writer.finish();
}

fn appendCleanupDigest(prepared: *const PreparedRxAppend) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-append-cleanup.v1");
    writer.writeUsize(prepared.saved_self_addr);
    writer.writeUsize(prepared.allocator_ptr_addr);
    writer.writeUsize(prepared.allocator_vtable_addr);
    writer.writeUsize(prepared.replacement_addr);
    writer.writeUsize(prepared.replacement_len);
    return writer.finish();
}

fn sameSlice(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return @intFromPtr(a.?.ptr) == @intFromPtr(b.?.ptr) and a.?.len == b.?.len;
}

fn canonicalAppendReplacement(prepared: *const PreparedRxAppend) ?[]u8 {
    if (@intFromPtr(prepared.allocator.ptr) != prepared.allocator_ptr_addr or
        @intFromPtr(prepared.allocator.vtable) != prepared.allocator_vtable_addr)
        return null;
    if (!std.mem.eql(u8, &prepared.cleanup_digest, &appendCleanupDigest(prepared)))
        return null;
    if (sameSlice(prepared.replacement, prepared.cleanup_replacement)) {
        const replacement = prepared.replacement orelse return if (prepared.replacement_len == 0)
            null
        else
            null;
        if (@intFromPtr(replacement.ptr) == prepared.replacement_addr and
            replacement.len == prepared.replacement_len)
            return replacement;
    }
    return null;
}

fn appendOutputPristine(out: *const PreparedRxAppend) bool {
    return out.saved_self_addr == 0 and out.state_addr == 0 and out.parser_addr == 0 and
        out.replacement == null and out.cleanup_replacement == null and
        out.replacement_addr == 0 and out.replacement_len == 0 and
        out.lifecycle == .empty;
}

fn parseCleanupDigest(scratch: *const RxParseScratch) owner_seal.Digest {
    var writer = owner_seal.Writer.init("rx-parse-cleanup.v1");
    writer.writeUsize(scratch.saved_self_addr);
    writer.writeUsize(scratch.allocator_ptr_addr);
    writer.writeUsize(scratch.allocator_vtable_addr);
    writer.writeUsize(scratch.payload_addr);
    writer.writeUsize(scratch.payload_len);
    return writer.finish();
}

fn parseCleanupValid(scratch: *const RxParseScratch) bool {
    return @intFromPtr(scratch.allocator.ptr) == scratch.allocator_ptr_addr and
        @intFromPtr(scratch.allocator.vtable) == scratch.allocator_vtable_addr and
        std.mem.eql(u8, &scratch.cleanup_digest, &parseCleanupDigest(scratch));
}

fn canonicalParsePayload(scratch: *const RxParseScratch) ?[]u8 {
    if (!parseCleanupValid(scratch) or
        !sameSlice(scratch.payload, scratch.cleanup_payload))
        return null;
    const payload = scratch.payload orelse return null;
    if (@intFromPtr(payload.ptr) != scratch.payload_addr or payload.len != scratch.payload_len)
        return null;
    return payload;
}

fn parseScratchPristine(scratch: *const RxParseScratch) bool {
    return scratch.saved_self_addr == 0 and scratch.parser_addr == 0 and
        scratch.payload == null and scratch.cleanup_payload == null and
        scratch.payload_addr == 0 and scratch.payload_len == 0 and
        scratch.lifecycle == .empty;
}

fn rangesOverlap(a_start: usize, a_len: usize, b_start: usize, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn parserSealDigest(seal: *const ParserAuthoritySeal) owner_seal.Digest {
    var writer = owner_seal.Writer.init(parser_seal_domain);
    writer.writeU16(parser_seal_version);
    writer.writeUsize(seal.seal_addr);
    writer.writeUsize(seal.parser_addr);
    writer.writeU64(seal.identity.attach_instance_id);
    writer.writeUsize(seal.identity.destination_slot_addr);
    writer.writeUsize(seal.destination_slot_len);
    writer.writeUsize(seal.allocator_ptr_addr);
    writer.writeUsize(seal.allocator_vtable_addr);
    writer.writeU16(seal.expected_major);
    writer.writeUsize(seal.backing_addr);
    writer.writeUsize(seal.items_len);
    writer.writeUsize(seal.capacity);
    writer.writeUsize(seal.head);
    writer.writeU64(seal.buffer_start_absolute);
    writer.writeU64(seal.rx_absolute_next);
    writer.writeU64(seal.generation);
    return writer.finish();
}

fn parserDescriptorValid(
    parser: *const framing.FrameParser,
    seal_addr: usize,
) bool {
    if (parser.head > parser.buf.items.len or parser.buf.items.len > parser.buf.capacity)
        return false;
    const backing_addr = if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr);
    if (parser.buf.capacity == 0 and parser.buf.items.len != 0) return false;
    _ = std.math.add(usize, backing_addr, parser.buf.capacity) catch return false;
    const parser_addr = @intFromPtr(parser);
    const parser_end = std.math.add(usize, parser_addr, @sizeOf(framing.FrameParser)) catch
        return false;
    const seal_end = std.math.add(usize, seal_addr, @sizeOf(ParserAuthoritySeal)) catch
        return false;
    const backing_end = std.math.add(usize, backing_addr, parser.buf.capacity) catch return false;
    if (parser.buf.capacity != 0 and
        (parser_addr < backing_end and backing_addr < parser_end or
            seal_addr < backing_end and backing_addr < seal_end))
        return false;
    return true;
}

fn makeParserSeal(
    parser: *const framing.FrameParser,
    provenance: *const RxProvenance,
    generation: u64,
) ?ParserAuthoritySeal {
    const identity = provenance.identity orelse return null;
    const seal_addr = @intFromPtr(&provenance.parser_seal);
    if (!parserDescriptorValid(parser, seal_addr)) return null;
    const backing_addr = if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr);
    if (rangesOverlap(
        backing_addr,
        parser.buf.capacity,
        @intFromPtr(provenance),
        @sizeOf(RxProvenance),
    ) or rangesOverlap(
        backing_addr,
        parser.buf.capacity,
        identity.destination_slot_addr,
        provenance.destination_slot_len,
    )) return null;
    var seal: ParserAuthoritySeal = .{
        .domain = parser_seal_domain.*,
        .version = parser_seal_version,
        .seal_addr = seal_addr,
        .parser_addr = @intFromPtr(parser),
        .identity = identity,
        .destination_slot_len = provenance.destination_slot_len,
        .allocator_ptr_addr = @intFromPtr(parser.allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(parser.allocator.vtable),
        .expected_major = parser.expected_major,
        .backing_addr = if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr),
        .items_len = parser.buf.items.len,
        .capacity = parser.buf.capacity,
        .head = parser.head,
        .buffer_start_absolute = provenance.buffer_start_absolute,
        .rx_absolute_next = provenance.rx_absolute_next,
        .generation = generation,
    };
    seal.digest = parserSealDigest(&seal);
    return seal;
}

pub fn parserSealValid(
    state: *const State,
    parser: *const framing.FrameParser,
) bool {
    const provenance = &state.rx_provenance;
    if (provenance.lifecycle != .bound or provenance.identity == null) return false;
    const seal = &provenance.parser_seal;
    if (!std.mem.eql(u8, &seal.domain, parser_seal_domain) or
        seal.version != parser_seal_version or
        seal.seal_addr != @intFromPtr(seal) or
        seal.parser_addr != @intFromPtr(parser) or
        !std.meta.eql(seal.identity, provenance.identity.?) or
        seal.destination_slot_len != provenance.destination_slot_len or
        seal.allocator_ptr_addr != @intFromPtr(parser.allocator.ptr) or
        seal.allocator_vtable_addr != @intFromPtr(parser.allocator.vtable) or
        seal.expected_major != parser.expected_major or
        seal.items_len != parser.buf.items.len or
        seal.capacity != parser.buf.capacity or
        seal.head != parser.head or
        seal.backing_addr !=
            (if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr)) or
        seal.buffer_start_absolute != provenance.buffer_start_absolute or
        seal.rx_absolute_next != provenance.rx_absolute_next or
        seal.generation == 0 or
        !parserDescriptorValid(parser, @intFromPtr(seal)) or
        rangesOverlap(
            seal.backing_addr,
            seal.capacity,
            @intFromPtr(state),
            @sizeOf(State),
        ) or
        rangesOverlap(
            seal.backing_addr,
            seal.capacity,
            seal.identity.destination_slot_addr,
            seal.destination_slot_len,
        ))
        return false;
    return std.mem.eql(u8, &seal.digest, &parserSealDigest(seal));
}

fn resealParserAuthority(state: *State, parser: *const framing.FrameParser) bool {
    const generation = std.math.add(
        u64,
        state.rx_provenance.parser_seal.generation,
        1,
    ) catch return false;
    state.rx_provenance.parser_seal =
        makeParserSeal(parser, &state.rx_provenance, generation) orelse return false;
    return parserSealValid(state, parser);
}

pub fn maxReadable(
    state: *const State,
    parser: *const framing.FrameParser,
    resident_cap: usize,
    turn_rx_remaining: usize,
) MaxReadableResult {
    if (state.rx_operation_busy or !parserSealValid(state, parser)) return .invalid;
    const provenance = state.rx_provenance;
    if (provenance.buffer_start_absolute > provenance.rx_absolute_next)
        return .invalid;
    const buffered = std.math.sub(
        usize,
        parser.buf.items.len,
        parser.head,
    ) catch return .invalid;
    const absolute_buffered = std.math.sub(
        u64,
        provenance.rx_absolute_next,
        provenance.buffer_start_absolute,
    ) catch return .invalid;
    if (absolute_buffered != buffered) return .invalid;
    if (provenance.rx_absolute_next == std.math.maxInt(u64))
        return .counter_exhausted;
    const resident_remaining = std.math.sub(usize, resident_cap, buffered) catch
        return .resident_exhausted;
    if (resident_remaining == 0) return .resident_exhausted;
    if (turn_rx_remaining == 0) return .turn_exhausted;
    const counter_remaining_u64 = std.math.maxInt(u64) - provenance.rx_absolute_next;
    const counter_remaining: usize = if (counter_remaining_u64 > std.math.maxInt(usize))
        std.math.maxInt(usize)
    else
        @intCast(counter_remaining_u64);
    const result = @min(turn_rx_remaining, resident_remaining, counter_remaining);
    return if (result == 0) .counter_exhausted else .{ .bytes = result };
}

pub fn isFresh(
    range: RxRange,
    barrier: RxWatermark,
    current_identity: RxIdentity,
    rx_absolute_next: u64,
) Freshness {
    if (!std.meta.eql(range.identity, current_identity) or
        !std.meta.eql(barrier.identity, current_identity) or
        range.start_absolute >= range.end_absolute or
        range.end_absolute > rx_absolute_next or
        barrier.absolute > rx_absolute_next)
        return .invalid;
    return if (range.start_absolute >= barrier.absolute) .fresh else .stale;
}

fn consumeValidated(
    state: *State,
    parser: *framing.FrameParser,
    count: usize,
    end_absolute: u64,
) void {
    if (!parserSealValid(state, parser) or
        state.rx_provenance.parser_seal.generation == std.math.maxInt(u64))
        @panic("RX consume entered without reseal capacity");
    const buffered = std.math.sub(usize, parser.buf.items.len, parser.head) catch
        @panic("preflighted RX consume descriptor drifted");
    if (count > buffered) @panic("RX consume exceeds buffered bytes");
    parser.head += count;
    if (parser.head == parser.buf.items.len) {
        parser.buf.clearRetainingCapacity();
        parser.head = 0;
    }
    state.rx_provenance.buffer_start_absolute = end_absolute;
    if (!resealParserAuthority(state, parser)) @panic("preflighted RX consume reseal failed");
}

pub fn nextOutcomeWithRange(
    state: *State,
    parser: *framing.FrameParser,
    scratch: *RxParseScratch,
) RxParseError!ExternalRxOutcome {
    if (state.rx_operation_busy) return error.InvalidState;
    if (!parserSealValid(state, parser)) return error.InvalidSeal;
    state.rx_operation_busy = true;
    defer state.rx_operation_busy = false;
    const backing_addr =
        if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr);
    if (rangesOverlap(@intFromPtr(scratch), @sizeOf(RxParseScratch), @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(
            @intFromPtr(scratch),
            @sizeOf(RxParseScratch),
            @intFromPtr(parser),
            @sizeOf(framing.FrameParser),
        ) or
        rangesOverlap(
            @intFromPtr(scratch),
            @sizeOf(RxParseScratch),
            backing_addr,
            parser.buf.capacity,
        ))
        return error.InvalidDescriptor;
    if (!parseScratchPristine(scratch))
        return error.InvalidState;
    const provenance = state.rx_provenance;
    const identity = provenance.identity orelse return error.InvalidState;
    const buffered = std.math.sub(usize, parser.buf.items.len, parser.head) catch
        return error.InvalidDescriptor;
    const absolute_buffered = std.math.sub(
        u64,
        provenance.rx_absolute_next,
        provenance.buffer_start_absolute,
    ) catch return error.ArithmeticOverflow;
    if (absolute_buffered != buffered) return error.InvalidDescriptor;
    if (buffered < protocol.header_size) return .incomplete;
    const pending = parser.buf.items[parser.head..];
    const header_bytes: *const [protocol.header_size]u8 = @ptrCast(pending.ptr);
    const header = protocol.Header.decode(header_bytes) catch return error.Protocol;
    if (header.major != parser.expected_major) return error.Protocol;
    if (header.payload_len > protocol.maxPayloadForKind(header.kind))
        return error.Protocol;
    const total = std.math.add(
        usize,
        protocol.header_size,
        @as(usize, header.payload_len),
    ) catch return error.ArithmeticOverflow;
    if (pending.len < total) return .incomplete;
    const frame_end = std.math.add(
        u64,
        provenance.buffer_start_absolute,
        @as(u64, @intCast(total)),
    ) catch return error.ArithmeticOverflow;
    if (frame_end > provenance.rx_absolute_next) return error.InvalidDescriptor;
    if (state.rx_provenance.parser_seal.generation == std.math.maxInt(u64))
        return error.ArithmeticOverflow;
    const range = RxRange{
        .identity = identity,
        .start_absolute = provenance.buffer_start_absolute,
        .end_absolute = frame_end,
    };
    const understood = header.kind.isKnown() and
        !protocol.Flags.hasUnknownBits(header.flags);
    if (!understood) {
        if (!protocol.Flags.isOptional(header.flags)) return error.Protocol;
        consumeValidated(state, parser, total, frame_end);
        return .{ .skipped = range };
    }

    const source_seal = state.rx_provenance.parser_seal;
    const frame_digest = bytesDigest(pending[0..total]);
    const allocation_owner = parser.allocator;
    const payload_len: usize = @intCast(header.payload_len);
    const payload = allocation_owner.alloc(u8, payload_len) catch
        return error.OutOfMemory;
    errdefer allocation_owner.free(payload);
    if (!parserSealValid(state, parser) or
        !std.meta.eql(source_seal, state.rx_provenance.parser_seal) or
        !parseScratchPristine(scratch))
        return error.InvalidSeal;
    const current_pending = parser.buf.items[parser.head..];
    if (current_pending.len < total or
        !std.mem.eql(u8, &frame_digest, &bytesDigest(current_pending[0..total])))
        return error.InvalidSeal;
    const payload_addr = @intFromPtr(payload.ptr);
    _ = std.math.add(usize, payload_addr, payload.len) catch
        return error.InvalidDescriptor;
    if (payload.len != payload_len or
        rangesOverlap(payload_addr, payload.len, @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(
            payload_addr,
            payload.len,
            @intFromPtr(parser),
            @sizeOf(framing.FrameParser),
        ) or
        rangesOverlap(
            payload_addr,
            payload.len,
            @intFromPtr(scratch),
            @sizeOf(RxParseScratch),
        ) or
        rangesOverlap(payload_addr, payload.len, backing_addr, parser.buf.capacity))
        return error.InvalidDescriptor;
    scratch.* = .{
        .saved_self_addr = @intFromPtr(scratch),
        .parser_addr = @intFromPtr(parser),
        .source_seal = source_seal,
        .frame_start_absolute = range.start_absolute,
        .frame_end_absolute = range.end_absolute,
        .header = header,
        .frame_digest = frame_digest,
        .allocator = allocation_owner,
        .allocator_ptr_addr = @intFromPtr(allocation_owner.ptr),
        .allocator_vtable_addr = @intFromPtr(allocation_owner.vtable),
        .payload_addr = payload_addr,
        .payload_len = payload.len,
        .payload = payload,
        .cleanup_payload = payload,
        .lifecycle = .prepared,
    };
    scratch.cleanup_digest = parseCleanupDigest(scratch);
    @memcpy(payload, current_pending[protocol.header_size..total]);
    consumeValidated(state, parser, total, frame_end);
    scratch.payload = null;
    scratch.cleanup_payload = null;
    scratch.lifecycle = .committed;
    var result = ExternalRxFrame{
        .frame = .{ .header = header, .payload = payload },
        .range = range,
        .pair_seal = undefined,
    };
    result.pair_seal = externalRxFrameDigest(&result);
    return .{ .frame = result };
}

fn appendPreparedValid(
    state: *const State,
    parser: *const framing.FrameParser,
    bytes: []const u8,
    prepared: *const PreparedRxAppend,
) bool {
    if (prepared.lifecycle != .prepared or
        !state.rx_operation_busy or
        prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.state_addr != @intFromPtr(state) or
        prepared.parser_addr != @intFromPtr(parser) or
        prepared.expected_start != state.rx_provenance.rx_absolute_next or
        prepared.bytes_addr != (if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr)) or
        prepared.bytes_len != bytes.len or
        state.rx_provenance.parser_seal.generation == std.math.maxInt(u64) or
        !std.meta.eql(prepared.source_seal, state.rx_provenance.parser_seal) or
        !parserSealValid(state, parser) or
        !std.mem.eql(u8, &prepared.digest, &appendDigest(prepared)))
        return false;
    if (prepared.replacement != null) {
        if (!std.mem.eql(u8, &prepared.bytes_digest, &bytesDigest(bytes))) return false;
        const unread = parser.buf.items[parser.head..];
        if (!std.mem.eql(u8, &prepared.unread_digest, &bytesDigest(unread))) return false;
        const expected_len = std.math.add(usize, unread.len, bytes.len) catch return false;
        const replacement = canonicalAppendReplacement(prepared) orelse return false;
        return prepared.final_items_len == expected_len and
            replacement.len >= expected_len;
    }
    const next_items_len = std.math.add(usize, parser.buf.items.len, bytes.len) catch
        return false;
    return prepared.cleanup_replacement == null and
        prepared.replacement_addr == 0 and prepared.replacement_len == 0 and
        std.mem.eql(u8, &prepared.bytes_digest, &([_]u8{0} ** 32)) and
        std.mem.eql(u8, &prepared.unread_digest, &([_]u8{0} ** 32)) and
        next_items_len <= parser.buf.capacity;
}

pub fn prepareAdmit(
    state: *State,
    parser: *framing.FrameParser,
    bytes: []const u8,
    expected_start: u64,
    resident_cap: usize,
    out: *PreparedRxAppend,
) RxPrepareError!void {
    if (state.rx_operation_busy) return error.InvalidState;
    if (!parserSealValid(state, parser)) return error.InvalidSeal;
    const parser_backing_addr =
        if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr);
    if (rangesOverlap(@intFromPtr(out), @sizeOf(PreparedRxAppend), @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedRxAppend),
            @intFromPtr(parser),
            @sizeOf(framing.FrameParser),
        ) or
        rangesOverlap(
            @intFromPtr(out),
            @sizeOf(PreparedRxAppend),
            parser_backing_addr,
            parser.buf.capacity,
        ))
        return error.InvalidDescriptor;
    if (expected_start != state.rx_provenance.rx_absolute_next)
        return error.InvalidState;
    if (!appendOutputPristine(out))
        return error.InvalidState;
    const unread_len = std.math.sub(usize, parser.buf.items.len, parser.head) catch
        return error.InvalidDescriptor;
    const next_unread_len = std.math.add(usize, unread_len, bytes.len) catch
        return error.ArithmeticOverflow;
    if (next_unread_len > resident_cap) return error.ResidentCap;
    _ = std.math.add(u64, expected_start, @as(u64, @intCast(bytes.len))) catch
        return error.ArithmeticOverflow;
    const bytes_addr = if (bytes.len == 0) 0 else @intFromPtr(bytes.ptr);
    if (rangesOverlap(bytes_addr, bytes.len, @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(bytes_addr, bytes.len, @intFromPtr(parser), @sizeOf(framing.FrameParser)) or
        rangesOverlap(bytes_addr, bytes.len, @intFromPtr(out), @sizeOf(PreparedRxAppend)) or
        rangesOverlap(bytes_addr, bytes.len, parser_backing_addr, parser.buf.capacity))
        return error.InvalidDescriptor;
    const next_items_len = std.math.add(usize, parser.buf.items.len, bytes.len) catch
        return error.ArithmeticOverflow;
    const needs_replacement = next_items_len > parser.buf.capacity;
    const source_seal = state.rx_provenance.parser_seal;
    const allocation_owner = parser.allocator;
    state.rx_operation_busy = true;
    errdefer state.rx_operation_busy = false;
    if (!needs_replacement) {
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .state_addr = @intFromPtr(state),
            .parser_addr = @intFromPtr(parser),
            .expected_start = expected_start,
            .bytes_addr = bytes_addr,
            .bytes_len = bytes.len,
            .source_seal = source_seal,
            .allocator = allocation_owner,
            .allocator_ptr_addr = @intFromPtr(allocation_owner.ptr),
            .allocator_vtable_addr = @intFromPtr(allocation_owner.vtable),
            .lifecycle = .prepared,
        };
        out.cleanup_digest = appendCleanupDigest(out);
        out.digest = appendDigest(out);
        return;
    }
    const unread = parser.buf.items[parser.head..];
    const unread_digest = bytesDigest(unread);
    const read_digest = bytesDigest(bytes);
    const doubled_capacity = std.math.mul(
        usize,
        @max(parser.buf.capacity, 8),
        2,
    ) catch resident_cap;
    const target_capacity = @min(
        resident_cap,
        @max(next_unread_len, doubled_capacity),
    );
    const replacement = allocation_owner.alloc(u8, target_capacity) catch
        return error.OutOfMemory;
    errdefer allocation_owner.free(replacement);
    if (!parserSealValid(state, parser) or
        !std.meta.eql(source_seal, state.rx_provenance.parser_seal) or
        !appendOutputPristine(out) or
        !std.mem.eql(u8, &unread_digest, &bytesDigest(parser.buf.items[parser.head..])) or
        !std.mem.eql(u8, &read_digest, &bytesDigest(bytes)))
        return error.InvalidSeal;
    const replacement_addr = if (replacement.len == 0) 0 else @intFromPtr(replacement.ptr);
    _ = std.math.add(usize, replacement_addr, replacement.len) catch
        return error.InvalidDescriptor;
    if (replacement.len != target_capacity or replacement.len < next_unread_len or
        rangesOverlap(replacement_addr, replacement.len, @intFromPtr(state), @sizeOf(State)) or
        rangesOverlap(
            replacement_addr,
            replacement.len,
            @intFromPtr(parser),
            @sizeOf(framing.FrameParser),
        ) or
        rangesOverlap(
            replacement_addr,
            replacement.len,
            @intFromPtr(out),
            @sizeOf(PreparedRxAppend),
        ) or
        rangesOverlap(replacement_addr, replacement.len, bytes_addr, bytes.len) or
        rangesOverlap(
            replacement_addr,
            replacement.len,
            parser_backing_addr,
            parser.buf.capacity,
        ))
        return error.InvalidDescriptor;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .state_addr = @intFromPtr(state),
        .parser_addr = @intFromPtr(parser),
        .expected_start = expected_start,
        .bytes_addr = bytes_addr,
        .bytes_len = bytes.len,
        .bytes_digest = read_digest,
        .source_seal = source_seal,
        .unread_digest = unread_digest,
        .allocator = allocation_owner,
        .allocator_ptr_addr = @intFromPtr(allocation_owner.ptr),
        .allocator_vtable_addr = @intFromPtr(allocation_owner.vtable),
        .replacement_addr = replacement_addr,
        .replacement_len = replacement.len,
        .final_items_len = next_unread_len,
        .replacement = replacement,
        .cleanup_replacement = replacement,
        .lifecycle = .prepared,
    };
    out.cleanup_digest = appendCleanupDigest(out);
    out.digest = appendDigest(out);
}

fn commitAdmitUnchecked(
    state: *State,
    parser: *framing.FrameParser,
    bytes: []const u8,
    prepared: *PreparedRxAppend,
) void {
    if (!appendPreparedValid(state, parser, bytes, prepared))
        @panic("invalid prepared RX append");
    const next_absolute = std.math.add(
        u64,
        state.rx_provenance.rx_absolute_next,
        @as(u64, @intCast(bytes.len)),
    ) catch @panic("RX append counter overflow");
    if (prepared.replacement) |replacement| {
        const unread = parser.buf.items[parser.head..];
        @memcpy(replacement[0..unread.len], unread);
        @memcpy(replacement[unread.len..prepared.final_items_len], bytes);
        var old = parser.buf;
        const cleanup_allocator = prepared.allocator;
        parser.buf = .{
            .items = replacement[0..prepared.final_items_len],
            .capacity = replacement.len,
        };
        parser.head = 0;
        prepared.replacement = null;
        prepared.cleanup_replacement = null;
        prepared.lifecycle = .committed;
        state.rx_provenance.rx_absolute_next = next_absolute;
        if (!resealParserAuthority(state, parser)) @panic("RX append reseal failed");
        // The old-backing free is the only callback in this suffix. Freeze the newly published
        // descriptor/scalars and restore them after the callback so re-entry cannot leave a
        // half-valid authority record. Never reread the prepared token after the callback.
        const frozen_buf = parser.buf;
        const frozen_head = parser.head;
        const frozen_provenance = state.rx_provenance;
        const frozen_allocator = parser.allocator;
        const frozen_expected_major = parser.expected_major;
        const frozen_content_digest = bytesDigest(frozen_buf.items);
        old.deinit(cleanup_allocator);
        const descriptor_matches =
            @intFromPtr(parser.allocator.ptr) == @intFromPtr(frozen_allocator.ptr) and
            @intFromPtr(parser.allocator.vtable) == @intFromPtr(frozen_allocator.vtable) and
            parser.expected_major == frozen_expected_major and
            parser.head == frozen_head and
            parser.buf.capacity == frozen_buf.capacity and
            parser.buf.items.len == frozen_buf.items.len and
            (parser.buf.capacity == 0 or
                @intFromPtr(parser.buf.items.ptr) == @intFromPtr(frozen_buf.items.ptr)) and
            std.meta.eql(state.rx_provenance, frozen_provenance);
        if (!descriptor_matches or
            !std.mem.eql(u8, &frozen_content_digest, &bytesDigest(frozen_buf.items)))
        {
            // The final allocation may have been invalidated by hostile callback code. Do not
            // resurrect or free a possibly dangling descriptor; quarantine at most resident-cap
            // bytes and make every later RX entry fail closed.
            parser.allocator = frozen_allocator;
            parser.expected_major = frozen_expected_major;
            parser.buf = .empty;
            parser.head = 0;
            state.rx_provenance = .{ .lifecycle = .terminal };
        }
        return;
    }
    parser.buf.appendSliceAssumeCapacity(bytes);
    state.rx_provenance.rx_absolute_next = next_absolute;
    if (!resealParserAuthority(state, parser)) @panic("RX append reseal failed");
    prepared.lifecycle = .committed;
}

pub fn commitPreparedAdmit(
    state: *State,
    parser: *framing.FrameParser,
    bytes: []const u8,
    prepared: *PreparedRxAppend,
) RxPrepareError!void {
    if (!appendPreparedValid(state, parser, bytes, prepared))
        return error.InvalidSeal;
    // No allocation, callback or outer action is permitted below this ReleaseFast validation.
    commitAdmitUnchecked(state, parser, bytes, prepared);
    state.rx_operation_busy = false;
}

pub fn abortPreparedAdmit(
    state: *State,
    prepared: *PreparedRxAppend,
) RxPrepareError!void {
    if (!state.rx_operation_busy or
        prepared.lifecycle != .prepared or
        prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.state_addr != @intFromPtr(state))
        return error.InvalidState;
    prepared.deinitInternal();
    state.rx_operation_busy = false;
}

pub fn prepareRxBind(
    source_state: *const State,
    attach_instance_id: u64,
    normalized: *const framing.PreparedNormalizeExact,
    destination_slot_addr: usize,
    destination_slot_len: usize,
    out: *PreparedRxBind,
) RxPrepareError!void {
    if (!std.meta.eql(source_state.rx_provenance, RxProvenance{}))
        return error.InvalidState;
    if (source_state.rx_operation_busy) return error.InvalidState;
    if (attach_instance_id == 0 or destination_slot_addr == 0 or destination_slot_len == 0)
        return error.InvalidIdentity;
    _ = std.math.add(usize, destination_slot_addr, destination_slot_len) catch
        return error.ArithmeticOverflow;
    if (normalized.saved_self_addr != @intFromPtr(normalized) or
        normalized.replacement_len > std.math.maxInt(u64))
        return error.InvalidDescriptor;
    const out_addr = @intFromPtr(out);
    const normalized_addr = @intFromPtr(normalized);
    const replacement_addr = if (normalized.replacement) |bytes|
        @intFromPtr(bytes.ptr)
    else
        0;
    if (rangesOverlap(out_addr, @sizeOf(PreparedRxBind), @intFromPtr(source_state), @sizeOf(State)) or
        rangesOverlap(
            out_addr,
            @sizeOf(PreparedRxBind),
            normalized_addr,
            @sizeOf(framing.PreparedNormalizeExact),
        ) or
        rangesOverlap(
            out_addr,
            @sizeOf(PreparedRxBind),
            replacement_addr,
            normalized.replacement_len,
        ) or
        rangesOverlap(
            out_addr,
            @sizeOf(PreparedRxBind),
            destination_slot_addr,
            destination_slot_len,
        ))
        return error.InvalidDescriptor;
    if (!std.meta.eql(out.*, PreparedRxBind{}))
        return error.InvalidState;
    const unread = normalized.replacement orelse {
        if (normalized.replacement_len != 0) return error.InvalidDescriptor;
        out.* = .{
            .saved_self_addr = @intFromPtr(out),
            .source_state_addr = @intFromPtr(source_state),
            .destination_slot_addr = destination_slot_addr,
            .destination_slot_len = destination_slot_len,
            .normalized_addr = @intFromPtr(normalized),
            .identity = .{
                .attach_instance_id = attach_instance_id,
                .destination_slot_addr = destination_slot_addr,
            },
            .allocator_ptr_addr = normalized.allocator_ptr_addr,
            .allocator_vtable_addr = normalized.allocator_vtable_addr,
            .expected_major = normalized.expected_major,
            .unread_len = 0,
            .unread_digest = bytesDigest(""),
            .lifecycle = .prepared,
        };
        out.digest = rxBindDigest(out);
        return;
    };
    if (unread.len != normalized.replacement_len) return error.InvalidDescriptor;
    out.* = .{
        .saved_self_addr = @intFromPtr(out),
        .source_state_addr = @intFromPtr(source_state),
        .destination_slot_addr = destination_slot_addr,
        .destination_slot_len = destination_slot_len,
        .normalized_addr = @intFromPtr(normalized),
        .identity = .{
            .attach_instance_id = attach_instance_id,
            .destination_slot_addr = destination_slot_addr,
        },
        .allocator_ptr_addr = normalized.allocator_ptr_addr,
        .allocator_vtable_addr = normalized.allocator_vtable_addr,
        .expected_major = normalized.expected_major,
        .unread_len = @intCast(unread.len),
        .unread_digest = bytesDigest(unread),
        .lifecycle = .prepared,
    };
    out.digest = rxBindDigest(out);
}

pub fn commitPreparedRxBind(
    state: *State,
    parser: *const framing.FrameParser,
    prepared: *PreparedRxBind,
    destination_slot_addr: usize,
    destination_slot_len: usize,
) void {
    if (prepared.lifecycle != .prepared or
        prepared.saved_self_addr != @intFromPtr(prepared) or
        prepared.destination_slot_addr != destination_slot_addr or
        prepared.destination_slot_len != destination_slot_len or
        !std.meta.eql(state.rx_provenance, RxProvenance{}) or
        !std.mem.eql(u8, &prepared.digest, &rxBindDigest(prepared)) or
        parser.head != 0 or parser.buf.items.len != prepared.unread_len or
        @intFromPtr(parser.allocator.ptr) != prepared.allocator_ptr_addr or
        @intFromPtr(parser.allocator.vtable) != prepared.allocator_vtable_addr or
        parser.expected_major != prepared.expected_major or
        !parserDescriptorValid(
            parser,
            @intFromPtr(&state.rx_provenance.parser_seal),
        ) or
        rangesOverlap(
            if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr),
            parser.buf.capacity,
            @intFromPtr(state),
            @sizeOf(State),
        ) or
        rangesOverlap(
            if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr),
            parser.buf.capacity,
            destination_slot_addr,
            destination_slot_len,
        ) or
        rangesOverlap(
            if (parser.buf.capacity == 0) 0 else @intFromPtr(parser.buf.items.ptr),
            parser.buf.capacity,
            @intFromPtr(prepared),
            @sizeOf(PreparedRxBind),
        ) or
        !std.mem.eql(u8, &prepared.unread_digest, &bytesDigest(parser.buf.items)))
        @panic("invalid prepared RX bind");
    const identity = prepared.identity orelse @panic("missing RX identity");
    state.rx_provenance = .{
        .identity = identity,
        .destination_slot_len = destination_slot_len,
        .rx_absolute_next = prepared.unread_len,
        .buffer_start_absolute = 0,
        .lifecycle = .bound,
    };
    state.rx_provenance.parser_seal =
        makeParserSeal(parser, &state.rx_provenance, 1) orelse
        @panic("invalid parser descriptor at RX bind");
    if (!parserSealValid(state, parser)) @panic("RX bind seal mismatch");
    state.rx_operation_busy = false;
    prepared.lifecycle = .committed;
}

pub const Mode = union(enum) {
    blocking,
    external: State,
};

pub const FlagOps = struct {
    context: *anyopaque,
    get_flags: *const fn (context: *anyopaque, fd: c.fd_t) ?c_int,
    set_flags: *const fn (context: *anyopaque, fd: c.fd_t, flags: c_int) bool,
};

pub const Outcome = union(enum) {
    external: State,
    flag_failed,
    invalid_blocking_flags,
    indeterminate,
};

/// Stage every 2a-owned allocation before observing or mutating fd flags. A successful target
/// verification returns owned state; every other outcome has already reclaimed staged storage.
pub fn transition(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    ops: FlagOps,
) error{OutOfMemory}!Outcome {
    var staged = try State.stage(allocator);
    errdefer staged.deinit(allocator);

    const saved_flags = ops.get_flags(ops.context, fd) orelse {
        staged.deinit(allocator);
        return .flag_failed;
    };
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (saved_flags & nonblocking != 0) {
        staged.deinit(allocator);
        return .invalid_blocking_flags;
    }
    staged.saved_flags = saved_flags;
    const target_flags = saved_flags | nonblocking;
    const set_ok = ops.set_flags(ops.context, fd, target_flags);
    const observed = ops.get_flags(ops.context, fd);
    if (set_ok and observed != null and observed.? == target_flags)
        return .{ .external = staged };

    // A failing adapter may still have changed the open-file-description. Only an exact observed
    // original value, or an explicitly successful and verified rollback, is reusable.
    if (!set_ok and observed != null and observed.? == saved_flags) {
        staged.deinit(allocator);
        return .flag_failed;
    }
    if (!ops.set_flags(ops.context, fd, saved_flags)) {
        staged.deinit(allocator);
        return .indeterminate;
    }
    const restored = ops.get_flags(ops.context, fd);
    staged.deinit(allocator);
    return if (restored != null and restored.? == saved_flags)
        .flag_failed
    else
        .indeterminate;
}

const FakeFlags = struct {
    flags: c_int = 0x20,
    get_results: []const ?c_int = &.{},
    get_index: usize = 0,
    set_results: []const bool = &.{true},
    set_index: usize = 0,
    mutate_on_set: bool = true,

    fn ops(self: *FakeFlags) FlagOps {
        return .{
            .context = self,
            .get_flags = getFlags,
            .set_flags = setFlags,
        };
    }

    fn cast(context: *anyopaque) *FakeFlags {
        return @ptrCast(@alignCast(context));
    }

    fn getFlags(context: *anyopaque, _: c.fd_t) ?c_int {
        const self = cast(context);
        if (self.get_index < self.get_results.len) {
            const result = self.get_results[self.get_index];
            self.get_index += 1;
            return result;
        }
        self.get_index += 1;
        return self.flags;
    }

    fn setFlags(context: *anyopaque, _: c.fd_t, flags: c_int) bool {
        const self = cast(context);
        const result = if (self.set_index < self.set_results.len)
            self.set_results[self.set_index]
        else
            true;
        self.set_index += 1;
        if (self.mutate_on_set) self.flags = flags;
        return result;
    }
};

test "external mode transition preserves unrelated flags and stages exact descriptor capacity" {
    var fake = FakeFlags{ .flags = 0x20 };
    const outcome = try transition(std.testing.allocator, 7, fake.ops());
    var state = outcome.external;
    defer state.deinit(std.testing.allocator);
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try std.testing.expectEqual(@as(c_int, 0x20), state.saved_flags);
    try std.testing.expectEqual(@as(c_int, 0x20) | nonblocking, fake.flags);
    try std.testing.expectEqual(max_tx_frames, state.external_tx.capacity);
    try std.testing.expectEqual(@as(usize, 0), state.external_tx.items.len);
    try std.testing.expectEqual(@as(usize, 1), fake.set_index);
    try std.testing.expectEqual(@as(usize, 2), fake.get_index);
}

test "external mode transition classifies initial and unexpected blocking flag failures" {
    var get_failed = FakeFlags{ .get_results = &.{null} };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, get_failed.ops())) == .flag_failed,
    );
    try std.testing.expectEqual(@as(usize, 0), get_failed.set_index);

    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    var already_nonblocking = FakeFlags{ .flags = 0x20 | nonblocking };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, already_nonblocking.ops())) ==
            .invalid_blocking_flags,
    );
    try std.testing.expectEqual(@as(usize, 0), already_nonblocking.set_index);
}

test "external mode transition verifies mutate-then-fail rollback and poisons ambiguity" {
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    const original: c_int = 0x20;
    const target = original | nonblocking;

    var restored = FakeFlags{
        .flags = original,
        .get_results = &.{ original, target, original },
        .set_results = &.{ false, true },
    };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, restored.ops())) == .flag_failed,
    );
    try std.testing.expectEqual(original, restored.flags);

    var successful_set_not_observed = FakeFlags{
        .flags = original,
        .get_results = &.{ original, original, original },
        .set_results = &.{ true, true },
    };
    try std.testing.expect(
        (try transition(
            std.testing.allocator,
            7,
            successful_set_not_observed.ops(),
        )) == .flag_failed,
    );
    try std.testing.expectEqual(@as(usize, 2), successful_set_not_observed.set_index);

    var rollback_failed = FakeFlags{
        .flags = original,
        .get_results = &.{ original, target },
        .set_results = &.{ false, false },
    };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, rollback_failed.ops())) == .indeterminate,
    );

    var verify_failed = FakeFlags{
        .flags = original,
        .get_results = &.{ original, null, null },
        .set_results = &.{ true, true },
    };
    try std.testing.expect(
        (try transition(std.testing.allocator, 7, verify_failed.ops())) == .indeterminate,
    );
}

fn checkTransitionAllocation(allocator: std.mem.Allocator) !void {
    var fake = FakeFlags{};
    const outcome = transition(allocator, 7, fake.ops()) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), fake.get_index);
        try std.testing.expectEqual(@as(usize, 0), fake.set_index);
        return err;
    };
    var state = outcome.external;
    state.deinit(allocator);
}

test "external mode transition is leak free at every allocation fail index" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkTransitionAllocation,
        .{},
    );
}

test "prepared RX bind opens a bind-local epoch on normalized unread bytes" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.push("deadpending");
    parser.head = 4;
    var normalized: framing.PreparedNormalizeExact = .{};
    defer normalized.deinit();
    try parser.prepareNormalizeExact(&normalized, parser.residentBytes());
    var destination_slot: usize = 0;
    var prepared: PreparedRxBind = .{};
    defer prepared.deinit();
    try prepareRxBind(
        &state,
        77,
        &normalized,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
        &prepared,
    );
    try std.testing.expect(prepared.validate(
        &state,
        77,
        &normalized,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    ));
    try std.testing.expectEqual(
        framing.NormalizeCommitOutcome.committed,
        parser.commitPreparedNormalizeExact(&normalized),
    );
    commitPreparedRxBind(
        &state,
        &parser,
        &prepared,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    );
    try std.testing.expectEqual(RxProvenanceLifecycle.bound, state.rx_provenance.lifecycle);
    try std.testing.expectEqual(@as(u64, 7), state.rx_provenance.rx_absolute_next);
    try std.testing.expectEqual(@as(u64, 0), state.rx_provenance.buffer_start_absolute);
    try std.testing.expectEqual(@as(u64, 77), state.rx_provenance.identity.?.attach_instance_id);
    try std.testing.expect(parserSealValid(&state, &parser));
}

test "prepared RX bind rejects zero identity and stale or copied authority" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var normalized: framing.PreparedNormalizeExact = .{};
    defer normalized.deinit();
    try parser.prepareNormalizeExact(&normalized, 0);
    var destination_slot: usize = 0;
    var prepared: PreparedRxBind = .{};
    try std.testing.expectError(
        error.InvalidIdentity,
        prepareRxBind(
            &state,
            0,
            &normalized,
            @intFromPtr(&destination_slot),
            @sizeOf(usize),
            &prepared,
        ),
    );
    try prepareRxBind(
        &state,
        9,
        &normalized,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
        &prepared,
    );
    var copied = prepared;
    defer copied.deinit();
    try std.testing.expect(!copied.validate(
        &state,
        9,
        &normalized,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    ));
    prepared.unread_len += 1;
    try std.testing.expect(!prepared.validate(
        &state,
        9,
        &normalized,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    ));
    prepared.deinit();
}

test "max readable uses tagged precedence and checked RX ceilings" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.push("abc");
    var normalized: framing.PreparedNormalizeExact = .{};
    defer normalized.deinit();
    try parser.prepareNormalizeExact(&normalized, parser.residentBytes());
    var destination_slot: usize = 0;
    var prepared: PreparedRxBind = .{};
    defer prepared.deinit();
    try prepareRxBind(
        &state,
        11,
        &normalized,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
        &prepared,
    );
    try std.testing.expectEqual(
        framing.NormalizeCommitOutcome.committed,
        parser.commitPreparedNormalizeExact(&normalized),
    );
    commitPreparedRxBind(
        &state,
        &parser,
        &prepared,
        @intFromPtr(&destination_slot),
        @sizeOf(usize),
    );

    try std.testing.expectEqual(
        @as(usize, 5),
        maxReadable(&state, &parser, 8, 9).bytes,
    );
    try std.testing.expect(maxReadable(&state, &parser, 3, 9) == .resident_exhausted);
    try std.testing.expect(maxReadable(&state, &parser, 8, 0) == .turn_exhausted);

    state.rx_provenance.rx_absolute_next = std.math.maxInt(u64);
    state.rx_provenance.buffer_start_absolute = std.math.maxInt(u64) - 3;
    try std.testing.expect(resealParserAuthority(&state, &parser));
    try std.testing.expect(maxReadable(&state, &parser, 8, 9) == .counter_exhausted);

    parser.head = parser.buf.items.len + 1;
    try std.testing.expect(maxReadable(&state, &parser, 8, 9) == .invalid);
}

fn bindParserForTest(
    state: *State,
    parser: *framing.FrameParser,
    attach_instance_id: u64,
    destination_slot: *usize,
) !void {
    var normalized: framing.PreparedNormalizeExact = .{};
    defer normalized.deinit();
    try parser.prepareNormalizeExact(&normalized, parser.residentBytes());
    var prepared: PreparedRxBind = .{};
    defer prepared.deinit();
    try prepareRxBind(
        state,
        attach_instance_id,
        &normalized,
        @intFromPtr(destination_slot),
        @sizeOf(usize),
        &prepared,
    );
    try std.testing.expectEqual(
        framing.NormalizeCommitOutcome.committed,
        parser.commitPreparedNormalizeExact(&normalized),
    );
    commitPreparedRxBind(
        state,
        parser,
        &prepared,
        @intFromPtr(destination_slot),
        @sizeOf(usize),
    );
}

fn admitForTest(
    state: *State,
    parser: *framing.FrameParser,
    bytes: []const u8,
    resident_cap: usize,
) !void {
    var prepared: PreparedRxAppend = .{};
    defer prepared.deinitInternal();
    try prepareAdmit(
        state,
        parser,
        bytes,
        state.rx_provenance.rx_absolute_next,
        resident_cap,
        &prepared,
    );
    try commitPreparedAdmit(state, parser, bytes, &prepared);
}

test "prepared RX append preserves source on prepare failure and commits replacement exactly" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.push("abc");
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 31, &destination_slot);
    const source_ptr = parser.buf.items.ptr;
    const source_len = parser.buf.items.len;
    var rejected: PreparedRxAppend = .{};
    try std.testing.expectError(
        error.ResidentCap,
        prepareAdmit(
            &state,
            &parser,
            "def",
            state.rx_provenance.rx_absolute_next,
            5,
            &rejected,
        ),
    );
    try std.testing.expectEqual(source_ptr, parser.buf.items.ptr);
    try std.testing.expectEqual(source_len, parser.buf.items.len);
    try std.testing.expectEqual(@as(u64, 3), state.rx_provenance.rx_absolute_next);

    var prepared: PreparedRxAppend = .{};
    defer prepared.deinitInternal();
    try prepareAdmit(
        &state,
        &parser,
        "def",
        state.rx_provenance.rx_absolute_next,
        6,
        &prepared,
    );
    try commitPreparedAdmit(&state, &parser, "def", &prepared);
    try std.testing.expectEqualStrings("abcdef", parser.buf.items);
    try std.testing.expectEqual(@as(u64, 6), state.rx_provenance.rx_absolute_next);
    try std.testing.expect(parserSealValid(&state, &parser));
}

test "prepared RX append uses callback-free spare capacity commit without content hashing" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 32, &destination_slot);
    try parser.buf.ensureTotalCapacityPrecise(parser.allocator, 8);
    try std.testing.expect(resealParserAuthority(&state, &parser));
    const backing = parser.buf.items.ptr;
    var prepared: PreparedRxAppend = .{};
    defer prepared.deinitInternal();
    var read_buffer = [_]u8{ 'x', 'y' };
    try prepareAdmit(
        &state,
        &parser,
        &read_buffer,
        0,
        8,
        &prepared,
    );
    try std.testing.expect(prepared.replacement == null);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &prepared.bytes_digest);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &prepared.unread_digest);
    try commitPreparedAdmit(&state, &parser, &read_buffer, &prepared);
    try std.testing.expectEqual(backing, parser.buf.items.ptr);
    try std.testing.expectEqualStrings("xy", parser.buf.items);
    try std.testing.expectEqual(@as(u64, 2), state.rx_provenance.rx_absolute_next);
}

test "prepared RX append lease rejects reentry and abort clears authority before cleanup" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 33, &destination_slot);
    var prepared: PreparedRxAppend = .{};
    try prepareAdmit(&state, &parser, "x", 0, 1, &prepared);
    try std.testing.expect(state.rx_operation_busy);
    try std.testing.expect(maxReadable(&state, &parser, 1, 1) == .invalid);
    var scratch: RxParseScratch = .{};
    try std.testing.expectError(
        error.InvalidState,
        nextOutcomeWithRange(&state, &parser, &scratch),
    );
    try abortPreparedAdmit(&state, &prepared);
    try std.testing.expect(!state.rx_operation_busy);
    try std.testing.expect(prepared.lifecycle == .aborted);
}

test "one-byte RX drip grows replacement capacity geometrically within resident cap" {
    var state = State{ .saved_flags = 7 };
    defer state.deinit(std.testing.allocator);
    var parser = framing.FrameParser.init(std.testing.allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 34, &destination_slot);
    var backing_changes: usize = 0;
    var previous_capacity = parser.buf.capacity;
    for (0..1024) |_| {
        try admitForTest(&state, &parser, "x", 1024);
        if (parser.buf.capacity != previous_capacity) {
            backing_changes += 1;
            previous_capacity = parser.buf.capacity;
        }
        try std.testing.expect(parser.buf.capacity <= 1024);
    }
    try std.testing.expect(backing_changes <= 8);
    try std.testing.expectEqual(@as(usize, 1024), parser.buf.items.len);
}

test "RX freshness compares identity before half-open offsets" {
    const identity = RxIdentity{
        .attach_instance_id = 5,
        .destination_slot_addr = 9,
    };
    try std.testing.expectEqual(
        Freshness.stale,
        isFresh(
            .{ .identity = identity, .start_absolute = 3, .end_absolute = 8 },
            .{ .identity = identity, .absolute = 5 },
            identity,
            8,
        ),
    );
    try std.testing.expectEqual(
        Freshness.fresh,
        isFresh(
            .{ .identity = identity, .start_absolute = 5, .end_absolute = 8 },
            .{ .identity = identity, .absolute = 5 },
            identity,
            8,
        ),
    );
    var other = identity;
    other.attach_instance_id += 1;
    try std.testing.expectEqual(
        Freshness.invalid,
        isFresh(
            .{ .identity = other, .start_absolute = 5, .end_absolute = 8 },
            .{ .identity = identity, .absolute = 5 },
            identity,
            8,
        ),
    );
}

test "range-aware RX parser preserves partial start and emits contiguous frames" {
    const allocator = std.testing.allocator;
    const first = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "one",
    );
    defer allocator.free(first);
    const second = try framing.encodeFrame(
        allocator,
        .{ .kind = .event, .request_id = 2 },
        "two",
    );
    defer allocator.free(second);
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 41, &destination_slot);

    try admitForTest(&state, &parser, first[0..1], first.len + second.len);
    var incomplete_scratch: RxParseScratch = .{};
    defer incomplete_scratch.deinit();
    try std.testing.expect(
        (try nextOutcomeWithRange(&state, &parser, &incomplete_scratch)) == .incomplete,
    );
    try std.testing.expectEqual(@as(u64, 0), state.rx_provenance.buffer_start_absolute);
    try admitForTest(&state, &parser, first[1..], first.len + second.len);
    try admitForTest(&state, &parser, second, first.len + second.len);

    var first_scratch: RxParseScratch = .{};
    defer first_scratch.deinit();
    const first_outcome = try nextOutcomeWithRange(&state, &parser, &first_scratch);
    const first_frame = first_outcome.frame;
    defer first_frame.frame.deinit(allocator);
    try std.testing.expect(validateExternalRxFrame(&first_frame));
    try std.testing.expectEqual(@as(u64, 0), first_frame.range.start_absolute);
    try std.testing.expectEqual(@as(u64, @intCast(first.len)), first_frame.range.end_absolute);
    try std.testing.expectEqualStrings("one", first_frame.frame.payload);

    var second_scratch: RxParseScratch = .{};
    defer second_scratch.deinit();
    const second_outcome = try nextOutcomeWithRange(&state, &parser, &second_scratch);
    const second_frame = second_outcome.frame;
    defer second_frame.frame.deinit(allocator);
    try std.testing.expect(validateExternalRxFrame(&second_frame));
    try std.testing.expectEqual(first_frame.range.end_absolute, second_frame.range.start_absolute);
    try std.testing.expectEqual(
        @as(u64, @intCast(first.len + second.len)),
        second_frame.range.end_absolute,
    );
    try std.testing.expectEqualStrings("two", second_frame.frame.payload);
    try std.testing.expectEqual(
        state.rx_provenance.rx_absolute_next,
        state.rx_provenance.buffer_start_absolute,
    );
    try std.testing.expect(parserSealValid(&state, &parser));

    var shifted = second_frame;
    shifted.range.start_absolute += 1;
    shifted.range.end_absolute += 1;
    try std.testing.expect(!validateExternalRxFrame(&shifted));
    var changed_header = second_frame;
    changed_header.frame.header.request_id += 1;
    try std.testing.expect(!validateExternalRxFrame(&changed_header));
    var changed_payload = second_frame;
    changed_payload.frame.payload[0] ^= 1;
    try std.testing.expect(!validateExternalRxFrame(&changed_payload));
    changed_payload.frame.payload[0] ^= 1;
}

test "range-aware RX parser charges optional skipped frame one exact range" {
    const allocator = std.testing.allocator;
    const wire = try framing.encodeFrame(
        allocator,
        .{ .kind = @enumFromInt(55001), .flags = protocol.Flags.optional },
        "ignored",
    );
    defer allocator.free(wire);
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push(wire);
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 42, &destination_slot);
    var scratch: RxParseScratch = .{};
    defer scratch.deinit();
    const outcome = try nextOutcomeWithRange(&state, &parser, &scratch);
    try std.testing.expectEqual(@as(u64, 0), outcome.skipped.start_absolute);
    try std.testing.expectEqual(@as(u64, @intCast(wire.len)), outcome.skipped.end_absolute);
    try std.testing.expectEqual(
        state.rx_provenance.rx_absolute_next,
        state.rx_provenance.buffer_start_absolute,
    );
}

test "range-aware RX parser preflights generation exhaustion before consume" {
    const allocator = std.testing.allocator;
    const wire = try framing.encodeFrame(allocator, .{ .kind = .ping }, "");
    defer allocator.free(wire);
    var state = State{ .saved_flags = 7 };
    defer state.deinit(allocator);
    var parser = framing.FrameParser.init(allocator);
    defer parser.deinit();
    try parser.push(wire);
    var destination_slot: usize = 0;
    try bindParserForTest(&state, &parser, 43, &destination_slot);
    state.rx_provenance.parser_seal.generation = std.math.maxInt(u64);
    state.rx_provenance.parser_seal.digest =
        parserSealDigest(&state.rx_provenance.parser_seal);
    const before_head = parser.head;
    const before_start = state.rx_provenance.buffer_start_absolute;
    var scratch: RxParseScratch = .{};
    try std.testing.expectError(
        error.ArithmeticOverflow,
        nextOutcomeWithRange(&state, &parser, &scratch),
    );
    try std.testing.expectEqual(before_head, parser.head);
    try std.testing.expectEqual(before_start, state.rx_provenance.buffer_start_absolute);
}
