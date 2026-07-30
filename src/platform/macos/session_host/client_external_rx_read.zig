//! Sealed storage and closed DTOs for one injected external-session RX read turn.
//!
//! C1 deliberately defines no collector or syscall adapter. The final-address scratch and limits
//! land first so later transport code cannot invent a second backing owner or grow the turn
//! budget without crossing a compile-time boundary.

const std = @import("std");
const client_external_mode = @import("client_external_mode.zig");
const external_owner_seal = @import("external_owner_seal.zig");

pub const max_rx_read_bytes_per_turn: usize = 1024 * 1024;
pub const max_rx_read_attempts_per_turn: usize = 64;
pub const max_rx_staged_prefix_validation_bytes_per_turn: usize =
    max_rx_read_attempts_per_turn * max_rx_read_bytes_per_turn;
pub const max_external_rx_read_metadata_bytes: usize = 256 * 1024;
pub const max_external_rx_read_scratch_bytes: usize =
    max_rx_read_bytes_per_turn + max_external_rx_read_metadata_bytes;

pub const RxReadOutcome = union(enum) {
    bytes: usize,
    would_block,
    interrupted,
    eof,
    socket_error,
};

pub const RxReadOps = struct {
    context: *anyopaque,
    read: *const fn (
        context: *anyopaque,
        fd: std.posix.fd_t,
        destination: []u8,
    ) RxReadOutcome,
};

pub const RxReadableAllowance = client_external_mode.ReadableAllowance;

pub const FinalParserState = enum {
    empty,
    incomplete,
};

pub const AcceptedAllowanceStop = enum {
    continue_collecting,
    counter_terminal,
    resident_incomplete_terminal,
    immediate,
    invalid,
};

pub fn classifyAcceptedAllowanceStop(
    allowance: RxReadableAllowance,
    accepted_bytes: usize,
    final_parser: FinalParserState,
) AcceptedAllowanceStop {
    if (allowance.bytes == 0 or accepted_bytes > allowance.bytes or
        (!allowance.resident_limited and
            !allowance.turn_limited and
            !allowance.counter_limited))
        return .invalid;
    if (accepted_bytes < allowance.bytes) return .continue_collecting;
    if (allowance.counter_limited) return .counter_terminal;
    if (allowance.resident_limited and final_parser == .incomplete)
        return .resident_incomplete_terminal;
    if (allowance.turn_limited or allowance.resident_limited)
        return .immediate;
    return .invalid;
}

pub const RxReadAuthorityView = struct {
    storage_addr: usize,
    lease_addr: usize,
    scratch_addr: usize,
    scratch_generation: u64,
    client_addr: usize,
    fd: std.posix.fd_t,
    parser_addr: usize,
    parser_seal: client_external_mode.ParserAuthoritySeal,
    owner_snapshot_digest: external_owner_seal.Digest,
};

pub const RxReadAuthorityOps = struct {
    context: *anyopaque,
    current: *const fn (context: *anyopaque) ?RxReadAuthorityView,
};

const Lifecycle = enum {
    empty,
    ready,
    busy,
    closed,
};

const ChunkSeal = struct {
    start: usize = 0,
    len: usize = 0,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

const AttemptLifecycle = enum {
    empty,
    callback_active,
    returned,
    consumed,
    aborted,
};

const ReadAttemptPermit = struct {
    saved_self_addr: usize = 0,
    attempt_generation: u64 = 0,
    destination_addr: usize = 0,
    destination_len: usize = 0,
    authority: RxReadAuthorityView = undefined,
    ops_addr: usize = 0,
    frozen_context: *anyopaque = undefined,
    frozen_read: *const fn (
        context: *anyopaque,
        fd: std.posix.fd_t,
        destination: []u8,
    ) RxReadOutcome = undefined,
    lifecycle: AttemptLifecycle = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

const RawWouldBlockObservation = struct {
    attempt_generation: u64 = 0,
    lifecycle: enum { empty, observed, consumed, aborted } = .empty,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,
};

pub const ExternalRxReadScratch = struct {
    saved_self_addr: usize = 0,
    generation: u64 = 0,
    lifecycle: Lifecycle = .empty,
    staged_len: usize = 0,
    attempt_count: u8 = 0,
    consecutive_interrupts: u8 = 0,
    chunks: [max_rx_read_attempts_per_turn]ChunkSeal =
        [_]ChunkSeal{.{}} ** max_rx_read_attempts_per_turn,
    prepared_admit: client_external_mode.PreparedRxAppend = .{},
    attempt: ReadAttemptPermit = .{},
    would_block: RawWouldBlockObservation = .{},
    backing: [max_rx_read_bytes_per_turn]u8 = undefined,
    digest: external_owner_seal.Digest = [_]u8{0} ** 32,

    pub fn initInPlace(out: *ExternalRxReadScratch) bool {
        if (out.saved_self_addr != 0 or out.generation != 0 or
            out.lifecycle != .empty)
            return false;
        out.saved_self_addr = @intFromPtr(out);
        out.generation = 1;
        out.lifecycle = .ready;
        out.staged_len = 0;
        out.attempt_count = 0;
        out.consecutive_interrupts = 0;
        out.chunks = [_]ChunkSeal{.{}} ** max_rx_read_attempts_per_turn;
        out.prepared_admit = .{};
        out.attempt = .{};
        out.would_block = .{};
        out.digest = scratchDigest(out);
        return true;
    }

    pub fn isReady(self: *const ExternalRxReadScratch) bool {
        if (self.saved_self_addr != @intFromPtr(self) or
            self.generation == 0 or
            self.lifecycle != .ready or
            self.staged_len != 0 or
            self.attempt_count != 0 or
            self.consecutive_interrupts != 0 or
            !client_external_mode.preparedRxAppendPristine(
                &self.prepared_admit,
            ) or
            self.attempt.saved_self_addr != 0 or
            self.attempt.attempt_generation != 0 or
            self.attempt.destination_addr != 0 or
            self.attempt.destination_len != 0 or
            self.attempt.ops_addr != 0 or
            self.attempt.lifecycle != .empty or
            !std.mem.allEqual(u8, &self.attempt.digest, 0) or
            self.would_block.attempt_generation != 0 or
            self.would_block.lifecycle != .empty or
            !std.mem.allEqual(u8, &self.would_block.digest, 0) or
            !std.mem.eql(u8, &self.digest, &scratchDigest(self)))
            return false;
        for (self.chunks) |chunk| {
            if (chunk.start != 0 or chunk.len != 0 or
                !std.mem.allEqual(u8, &chunk.digest, 0))
                return false;
        }
        return true;
    }
};

fn scratchDigest(
    scratch: *const ExternalRxReadScratch,
) external_owner_seal.Digest {
    var writer = external_owner_seal.Writer.init("MARURDS1");
    writer.writeUsize(scratch.saved_self_addr);
    writer.writeU64(scratch.generation);
    writer.writeU8(@intFromEnum(scratch.lifecycle));
    writer.writeUsize(@intFromPtr(&scratch.backing));
    writer.writeUsize(scratch.backing.len);
    writer.writeUsize(scratch.staged_len);
    writer.writeU8(scratch.attempt_count);
    writer.writeU8(scratch.consecutive_interrupts);
    for (scratch.chunks) |chunk| {
        writer.writeUsize(chunk.start);
        writer.writeUsize(chunk.len);
        writer.writeBytes(&chunk.digest);
    }
    writer.writeUsize(scratch.prepared_admit.saved_self_addr);
    writer.writeUsize(scratch.prepared_admit.state_addr);
    writer.writeUsize(scratch.prepared_admit.parser_addr);
    writer.writeU8(@intFromEnum(scratch.prepared_admit.lifecycle));
    writer.writeUsize(scratch.attempt.saved_self_addr);
    writer.writeU64(scratch.attempt.attempt_generation);
    writer.writeUsize(scratch.attempt.destination_addr);
    writer.writeUsize(scratch.attempt.destination_len);
    writer.writeUsize(scratch.attempt.ops_addr);
    writer.writeU8(@intFromEnum(scratch.attempt.lifecycle));
    writer.writeBytes(&scratch.attempt.digest);
    writer.writeU64(scratch.would_block.attempt_generation);
    writer.writeU8(@intFromEnum(scratch.would_block.lifecycle));
    writer.writeBytes(&scratch.would_block.digest);
    return writer.finish();
}

comptime {
    if (@sizeOf(ExternalRxReadScratch) > max_external_rx_read_scratch_bytes)
        @compileError("external RX read scratch exceeds 1.25 MiB");
    if (@sizeOf(ExternalRxReadScratch) - max_rx_read_bytes_per_turn >
        max_external_rx_read_metadata_bytes)
        @compileError("external RX read metadata exceeds 256 KiB");
}

test "C1 read scratch is final-address sealed within its analytic budget" {
    const scratch = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(scratch);
    scratch.saved_self_addr = 0;
    scratch.generation = 0;
    scratch.lifecycle = .empty;
    try std.testing.expect(ExternalRxReadScratch.initInPlace(scratch));
    if (!scratch.isReady()) {
        std.debug.print("C1 read scratch initial ready seal mismatch\n", .{});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(!ExternalRxReadScratch.initInPlace(scratch));
    const copied = try std.testing.allocator.create(ExternalRxReadScratch);
    defer std.testing.allocator.destroy(copied);
    copied.saved_self_addr = 0;
    copied.generation = 0;
    copied.lifecycle = .empty;
    try std.testing.expect(ExternalRxReadScratch.initInPlace(copied));
    copied.saved_self_addr = scratch.saved_self_addr;
    copied.digest = scratch.digest;
    if (copied.isReady()) {
        std.debug.print("C1 read scratch copied address was accepted\n", .{});
        return error.TestUnexpectedResult;
    }
    scratch.chunks[0].len = 1;
    try std.testing.expect(!scratch.isReady());
    scratch.chunks[0] = .{};
    scratch.attempt.destination_len = 1;
    try std.testing.expect(!scratch.isReady());
    scratch.attempt.destination_len = 0;
    scratch.would_block.attempt_generation = 1;
    try std.testing.expect(!scratch.isReady());
    scratch.would_block.attempt_generation = 0;
    scratch.prepared_admit.allocator = std.testing.allocator;
    try std.testing.expect(!scratch.isReady());
    try std.testing.expect(
        @sizeOf(ExternalRxReadScratch) <= max_external_rx_read_scratch_bytes,
    );
    try std.testing.expectEqual(
        max_rx_staged_prefix_validation_bytes_per_turn,
        64 * 1024 * 1024,
    );
}

test "C1 accepted allowance stop table fixes every limit tie precedence" {
    const Limit = struct {
        resident: bool,
        turn: bool,
        counter: bool,
        empty: AcceptedAllowanceStop,
        incomplete: AcceptedAllowanceStop,
    };
    const limits = [_]Limit{
        .{
            .resident = true,
            .turn = false,
            .counter = false,
            .empty = .immediate,
            .incomplete = .resident_incomplete_terminal,
        },
        .{
            .resident = false,
            .turn = true,
            .counter = false,
            .empty = .immediate,
            .incomplete = .immediate,
        },
        .{
            .resident = false,
            .turn = false,
            .counter = true,
            .empty = .counter_terminal,
            .incomplete = .counter_terminal,
        },
        .{
            .resident = true,
            .turn = true,
            .counter = false,
            .empty = .immediate,
            .incomplete = .resident_incomplete_terminal,
        },
        .{
            .resident = true,
            .turn = false,
            .counter = true,
            .empty = .counter_terminal,
            .incomplete = .counter_terminal,
        },
        .{
            .resident = false,
            .turn = true,
            .counter = true,
            .empty = .counter_terminal,
            .incomplete = .counter_terminal,
        },
        .{
            .resident = true,
            .turn = true,
            .counter = true,
            .empty = .counter_terminal,
            .incomplete = .counter_terminal,
        },
    };
    for (limits) |limit| {
        const allowance = RxReadableAllowance{
            .bytes = 1,
            .resident_limited = limit.resident,
            .turn_limited = limit.turn,
            .counter_limited = limit.counter,
        };
        try std.testing.expectEqual(
            AcceptedAllowanceStop.continue_collecting,
            classifyAcceptedAllowanceStop(allowance, 0, .empty),
        );
        try std.testing.expectEqual(
            limit.empty,
            classifyAcceptedAllowanceStop(allowance, 1, .empty),
        );
        try std.testing.expectEqual(
            limit.incomplete,
            classifyAcceptedAllowanceStop(allowance, 1, .incomplete),
        );
        try std.testing.expectEqual(
            AcceptedAllowanceStop.invalid,
            classifyAcceptedAllowanceStop(allowance, 2, .empty),
        );
    }
    try std.testing.expectEqual(
        AcceptedAllowanceStop.invalid,
        classifyAcceptedAllowanceStop(.{
            .bytes = 1,
            .resident_limited = false,
            .turn_limited = false,
            .counter_limited = false,
        }, 1, .empty),
    );
    try std.testing.expectEqual(
        AcceptedAllowanceStop.invalid,
        classifyAcceptedAllowanceStop(.{
            .bytes = 0,
            .resident_limited = true,
            .turn_limited = false,
            .counter_limited = false,
        }, 0, .empty),
    );
}
