//! CR3a-2a neutral value contracts shared by generation transport and GUI attachment owners.
//!
//! This leaf must remain independent from Client, sockets, allocators, and GUI types.  It carries
//! only opaque identities and closed state needed to pair a prepared RPC with one final-address
//! attachment binding without exporting either backing owner.

const std = @import("std");

/// Identity of one request whose frame and request slot are still owned by a
/// GenerationTransport. Zero is excluded from every component so pristine
/// storage cannot be mistaken for a live request after a partial init.
pub const PreparedCallReceipt = struct {
    transport_incarnation: u64,
    request_id: u64,
    /// Non-authoritative drift detector over the transport's canonical tagged
    /// request encoding. Authority is the exact transport/request pair; a
    /// digest collision cannot authorize a foreign request ID.
    request_digest: u64,

    pub fn init(fields: @This()) ?@This() {
        return if (fields.valid()) fields else null;
    }

    pub fn valid(self: @This()) bool {
        return self.transport_incarnation != 0 and
            self.request_id != 0 and
            self.request_digest != 0;
    }

    pub fn matches(self: @This(), other: @This()) bool {
        return self.valid() and other.valid() and std.meta.eql(self, other);
    }
};

/// Pointer-free proof that execute settled the corresponding prepared owner.
/// `response_request_id` is kept separately because correlation must be
/// checked before an accepted payload can bind a stream cleanup reservation.
pub const ExecutedCallReceipt = struct {
    prepared_call: PreparedCallReceipt,

    pub fn fromPrepared(prepared: PreparedCallReceipt) ?@This() {
        if (!prepared.valid()) return null;
        return .{ .prepared_call = prepared };
    }

    pub fn valid(self: @This()) bool {
        return self.prepared_call.valid();
    }

    pub fn matchesPrepared(self: @This(), prepared: PreparedCallReceipt) bool {
        return self.valid() and self.prepared_call.matches(prepared);
    }
};

pub const CorrelatedExecutedCall = struct {
    executed_call: ExecutedCallReceipt,
    response_request_id: u64,

    pub fn init(executed_call: ExecutedCallReceipt, response_request_id: u64) ?@This() {
        if (!executed_call.valid() or response_request_id == 0) return null;
        return .{
            .executed_call = executed_call,
            .response_request_id = response_request_id,
        };
    }

    pub fn responseMatchesPrepared(self: @This()) bool {
        return self.executed_call.valid() and
            self.response_request_id == self.executed_call.prepared_call.request_id;
    }
};

pub const AttachmentRole = enum(u8) {
    controller,
    observer,
};

pub fn attachmentRoleRawValid(value: *const AttachmentRole) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(AttachmentRole.observer);
}

/// Immutable, storage-neutral half of a prepared attachment binding. The
/// actual pin and cleanup entry remain private to ClientNode; this value only
/// lets the final-address owner reject foreign request or generation splices.
pub const BindingIdentity = struct {
    binding_incarnation: u64,
    binding_storage_addr: usize,
    destination_addr: usize,
    binding_reservation_id: u64,
    slot_incarnation: u64,
    node_incarnation: u64,
    host_id: u128,
    connection_generation: u64,
    runtime_id: u128,
    role: AttachmentRole,
    pid: u32,
    process_nonce: u64,

    pub fn init(fields: @This()) ?@This() {
        return if (fields.valid()) fields else null;
    }

    pub fn valid(self: @This()) bool {
        return attachmentRoleRawValid(&self.role) and
            self.binding_incarnation != 0 and
            self.binding_storage_addr != 0 and
            self.destination_addr != 0 and
            self.binding_reservation_id != 0 and
            self.slot_incarnation != 0 and
            self.node_incarnation != 0 and
            self.host_id != 0 and
            self.connection_generation == 1 and
            self.runtime_id != 0 and
            self.pid != 0 and
            self.process_nonce != 0;
    }

    pub fn matches(self: @This(), other: @This()) bool {
        return self.valid() and other.valid() and std.meta.eql(self, other);
    }
};

/// Closed state vocabulary; the stateful final-address owner lives outside
/// this leaf and is the only code allowed to perform transitions.
pub const BindingLifecycle = enum(u8) {
    pristine,
    reserved,
    request_paired,
    executing,
    committed,
    terminal,
};

/// Final-address neutral state paired with the private pin/drop reservation in
/// ClientNode. It never owns or dereferences that backing; callers must mutate
/// the backing first and publish the matching no-fail transition here second.
pub const PreparedAttachmentBinding = struct {
    self_addr: usize = 0,
    lifecycle: BindingLifecycle = .pristine,
    identity: ?BindingIdentity = null,
    prepared_call: ?PreparedCallReceipt = null,

    pub const TransitionError = error{
        InvalidIdentity,
        InvalidReceipt,
        InvalidState,
        MovedOrCopied,
    };

    pub fn initReservedInPlace(out: *PreparedAttachmentBinding, identity: BindingIdentity) TransitionError!void {
        if (out.self_addr != 0 or out.lifecycle != .pristine or
            out.identity != null or out.prepared_call != null)
            return error.InvalidState;
        if (!identity.valid() or identity.binding_storage_addr != @intFromPtr(out))
            return error.InvalidIdentity;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .lifecycle = .reserved,
            .identity = identity,
        };
    }

    pub fn validAtFinalAddress(self: *const PreparedAttachmentBinding) bool {
        return self.self_addr == @intFromPtr(self) and
            self.identity != null and self.identity.?.valid() and
            self.identity.?.binding_storage_addr == self.self_addr and
            self.identity.?.destination_addr != 0;
    }

    pub fn pairRequest(self: *PreparedAttachmentBinding, prepared: PreparedCallReceipt) TransitionError!void {
        if (!self.validAtFinalAddress()) return error.MovedOrCopied;
        if (self.lifecycle != .reserved or self.prepared_call != null)
            return error.InvalidState;
        if (!prepared.valid()) return error.InvalidReceipt;
        self.prepared_call = prepared;
        self.lifecycle = .request_paired;
    }

    pub fn beginExecute(self: *PreparedAttachmentBinding, prepared: PreparedCallReceipt) TransitionError!void {
        if (!self.validAtFinalAddress()) return error.MovedOrCopied;
        if (self.lifecycle != .request_paired) return error.InvalidState;
        const canonical = self.prepared_call orelse return error.InvalidState;
        if (!canonical.matches(prepared)) return error.InvalidReceipt;
        self.lifecycle = .executing;
    }

    // Commit/abort/cleanup transitions deliberately have no leaf-only public
    // method. ClientSlot must first validate and mutate its canonical pin/drop
    // reservation, then publish the matching state in the same owner API.
};

pub const ExecutedResponseLifecycle = enum(u8) {
    pristine,
    accepted,
    typed_reject,
    uncertain_or_connection_failure,
    terminal,
};

pub const ExecuteOutcome = enum(u8) {
    accepted,
    typed_reject,
    uncertain_or_connection_failure,
};

pub const ExecuteResult = union(ExecuteOutcome) {
    accepted: CorrelatedExecutedCall,
    typed_reject: CorrelatedExecutedCall,
    uncertain_or_connection_failure: ExecutedCallReceipt,
};

pub const TransportOwnerLifecycle = enum(u8) { pristine, live, terminal };

/// Neutral canonical fence stored beside, rather than inside, GenerationTransport. Restoring stale
/// transport bytes at the same address cannot revive this owner seal after attachment teardown.
pub const TransportOwnerSeal = struct {
    self_addr: usize = 0,
    incarnation: u64 = 0,
    owner_addr: usize = 0,
    owner_size: usize = 0,
    transport_addr: usize = 0,
    prepared_storage_addr: usize = 0,
    rpc_response_addr: usize = 0,
    lifecycle: TransportOwnerLifecycle = .pristine,

    fn lifecycleRawValid(self: *const TransportOwnerSeal) bool {
        const raw = @as(*const u8, @ptrCast(&self.lifecycle)).*;
        return raw <= @intFromEnum(TransportOwnerLifecycle.terminal);
    }

    fn ownerRangeValid(self: *const TransportOwnerSeal) bool {
        if (self.owner_addr == 0 or self.owner_size == 0) return false;
        _ = std.math.add(usize, self.owner_addr, self.owner_size) catch return false;
        return true;
    }

    pub fn initInPlace(
        out: *TransportOwnerSeal,
        incarnation: u64,
        owner_addr: usize,
        owner_size: usize,
        transport_addr: usize,
        prepared_storage_addr: usize,
    ) error{ InvalidState, InvalidIncarnation }!void {
        return initCommon(
            out,
            incarnation,
            owner_addr,
            owner_size,
            transport_addr,
            prepared_storage_addr,
            0,
        );
    }

    pub fn initWithRpcResponseInPlace(
        out: *TransportOwnerSeal,
        incarnation: u64,
        owner_addr: usize,
        owner_size: usize,
        transport_addr: usize,
        prepared_storage_addr: usize,
        rpc_response_addr: usize,
    ) error{ InvalidState, InvalidIncarnation }!void {
        if (rpc_response_addr == 0) return error.InvalidIncarnation;
        return initCommon(
            out,
            incarnation,
            owner_addr,
            owner_size,
            transport_addr,
            prepared_storage_addr,
            rpc_response_addr,
        );
    }

    fn initCommon(
        out: *TransportOwnerSeal,
        incarnation: u64,
        owner_addr: usize,
        owner_size: usize,
        transport_addr: usize,
        prepared_storage_addr: usize,
        rpc_response_addr: usize,
    ) error{ InvalidState, InvalidIncarnation }!void {
        if (!out.lifecycleRawValid() or out.self_addr != 0 or out.incarnation != 0 or
            out.owner_addr != 0 or out.owner_size != 0 or out.transport_addr != 0 or
            out.prepared_storage_addr != 0 or out.rpc_response_addr != 0 or
            out.lifecycle != .pristine)
            return error.InvalidState;
        if (incarnation == 0 or owner_addr == 0 or owner_size == 0 or transport_addr == 0 or
            prepared_storage_addr == 0)
            return error.InvalidIncarnation;
        _ = std.math.add(usize, owner_addr, owner_size) catch return error.InvalidIncarnation;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .incarnation = incarnation,
            .owner_addr = owner_addr,
            .owner_size = owner_size,
            .transport_addr = transport_addr,
            .prepared_storage_addr = prepared_storage_addr,
            .rpc_response_addr = rpc_response_addr,
            .lifecycle = .live,
        };
    }

    pub fn valid(self: *const TransportOwnerSeal, incarnation: u64) bool {
        return self.lifecycleRawValid() and self.self_addr == @intFromPtr(self) and
            self.incarnation == incarnation and
            incarnation != 0 and self.ownerRangeValid() and
            self.transport_addr != 0 and self.prepared_storage_addr != 0 and
            self.lifecycle == .live;
    }

    pub fn terminalize(self: *TransportOwnerSeal, incarnation: u64) error{InvalidState}!void {
        if (!self.valid(incarnation)) return error.InvalidState;
        self.lifecycle = .terminal;
    }

    pub fn settledExact(self: *const TransportOwnerSeal) bool {
        if (!self.lifecycleRawValid()) return false;
        return switch (self.lifecycle) {
            .pristine => self.self_addr == 0 and self.incarnation == 0 and
                self.owner_addr == 0 and self.owner_size == 0 and self.transport_addr == 0 and
                self.prepared_storage_addr == 0 and self.rpc_response_addr == 0,
            .terminal => self.self_addr == @intFromPtr(self) and self.incarnation != 0 and
                self.ownerRangeValid() and
                self.transport_addr != 0 and self.prepared_storage_addr != 0 and
                self.lifecycle == .terminal,
            .live => false,
        };
    }
};

pub const ExecutedResponseOwnerSeal = struct {
    self_addr: usize = 0,
    incarnation: u64 = 0,
    response_addr: usize = 0,
    response_digest: u64 = 0,
    terminal_digest: u64 = 0,
    lifecycle: ExecutedResponseOwnerLifecycle = .pristine,

    pub fn lifecycleRawValid(self: *const @This()) bool {
        const raw = @as(*const u8, @ptrCast(&self.lifecycle)).*;
        return raw <= @intFromEnum(ExecutedResponseOwnerLifecycle.terminal);
    }

    pub fn initInPlace(
        out: *@This(),
        incarnation: u64,
        response_addr: usize,
        response_digest: u64,
    ) error{ InvalidState, InvalidIncarnation }!void {
        // Lifecycle storage may have been restored from hostile/stale owner bytes. Prove the raw
        // discriminator before Zig performs a typed enum comparison.
        if (!out.lifecycleRawValid() or out.self_addr != 0 or out.incarnation != 0 or
            out.response_addr != 0 or out.response_digest != 0 or out.terminal_digest != 0 or
            out.lifecycle != .pristine)
            return error.InvalidState;
        if (incarnation == 0 or response_addr == 0 or response_digest == 0)
            return error.InvalidIncarnation;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .incarnation = incarnation,
            .response_addr = response_addr,
            .response_digest = response_digest,
            .lifecycle = .live,
        };
    }

    pub fn valid(self: *const @This(), incarnation: u64) bool {
        return self.lifecycleRawValid() and self.self_addr == @intFromPtr(self) and
            self.incarnation == incarnation and
            incarnation != 0 and self.response_addr != 0 and self.response_digest != 0 and
            self.terminal_digest == 0 and
            self.lifecycle == .live;
    }

    pub fn terminalize(self: *@This(), incarnation: u64) error{InvalidState}!void {
        if (!self.valid(incarnation)) return error.InvalidState;
        self.lifecycle = .terminal;
        self.terminal_digest = terminalDigest(self);
    }

    pub fn settledExact(self: *const @This()) bool {
        if (!self.lifecycleRawValid()) return false;
        return switch (self.lifecycle) {
            .pristine => self.self_addr == 0 and self.incarnation == 0 and
                self.response_addr == 0 and self.response_digest == 0 and self.terminal_digest == 0,
            .terminal => self.self_addr == @intFromPtr(self) and self.incarnation != 0 and
                self.response_addr != 0 and self.response_digest != 0 and
                self.terminal_digest != 0 and self.terminal_digest == terminalDigest(self),
            .live => false,
        };
    }

    fn terminalDigest(self: *const @This()) u64 {
        var hasher = std.hash.Wyhash.init(0x4d_52_53_48_52_53_45_41);
        inline for (.{
            self.self_addr,
            @as(usize, @intCast(self.incarnation)),
            self.response_addr,
            @as(usize, @intCast(self.response_digest)),
            @as(usize, @as(*const u8, @ptrCast(&self.lifecycle)).*),
        }) |value| hasher.update(std.mem.asBytes(&value));
        const digest = hasher.final();
        return if (digest == 0) 1 else digest;
    }
};

pub const ExecutedResponseOwnerLifecycle = enum(u8) {
    pristine,
    live,
    terminal,
};

/// Method strings and canonical parameter encoding remain inside ClientSlot; callers select only
/// one closed typed request and cannot supply an encoded payload or arbitrary stream identity.
pub const RuntimeRequestTag = enum(u8) {
    spawn_full,
    attach_controller,
    resize,
    observation,
    selected_text,
    link_at,
    clipboard_write,
    find,
    select_op,
    core_command,
    report_mouse,
    notification,
    terminate,
    detach,
};

pub fn runtimeRequestTagRawValid(value: *const RuntimeRequestTag) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(RuntimeRequestTag.detach);
}

pub const RequestFamily = enum(u8) {
    connection_only_denied,
    attach_only,
    bound_observation,
    bound_controller_mutation,
    bound_terminal,
};

pub fn requestFamilyRawValid(value: *const RequestFamily) bool {
    const raw = @as(*const u8, @ptrCast(value)).*;
    return raw <= @intFromEnum(RequestFamily.bound_terminal);
}

pub fn requestFamilyForTag(tag: RuntimeRequestTag) RequestFamily {
    return switch (tag) {
        .spawn_full => .connection_only_denied,
        .attach_controller => .attach_only,
        .observation, .selected_text, .link_at, .find, .select_op => .bound_observation,
        .resize, .clipboard_write, .core_command, .report_mouse, .notification => .bound_controller_mutation,
        .terminate, .detach => .bound_terminal,
    };
}

/// Most request tags have one static family. Find is the single reviewed
/// exception: its typed `scroll` discriminator promotes observation to a
/// controller mutation. Canonical authority stores the derived family, so
/// validators must admit both reviewed find outcomes without re-reading the
/// request payload.
pub fn requestFamilyAllowed(tag: RuntimeRequestTag, family: RequestFamily) bool {
    if (!runtimeRequestTagRawValid(&tag) or !requestFamilyRawValid(&family)) return false;
    return if (tag == .find)
        family == .bound_observation or family == .bound_controller_mutation
    else
        requestFamilyForTag(tag) == family;
}

pub fn requestMethod(tag: RuntimeRequestTag) []const u8 {
    return switch (tag) {
        .spawn_full => "runtime.spawn_full",
        .attach_controller => "runtime.attach",
        .resize => "runtime.resize",
        .observation => "runtime.observation",
        .selected_text => "runtime.selected_text",
        .link_at => "runtime.link_at",
        .clipboard_write => "runtime.clipboard_write",
        .find => "runtime.find",
        .select_op => "runtime.select_op",
        .core_command => "runtime.core_command",
        .report_mouse => "runtime.report_mouse",
        .notification => "runtime.notification",
        .terminate => "runtime.terminate",
        .detach => "runtime.detach",
    };
}

pub const ResizeRequest = extern struct {
    cols: u16,
    rows: u16,
    client_sequence: u64,
};

pub const SelectedTextRequest = struct {
    start_row: u64,
    start_col: u64,
    end_row: u64,
    end_col: u64,
    block: bool,
};

pub const LinkAtRequest = extern struct { row: u16, col: u16, scopes: u8 };
pub const FindRequest = struct {
    query: [256]u8 = [_]u8{0} ** 256,
    query_len: u16 = 0,
    current: u32,
    scroll: bool,

    pub fn init(text: []const u8, current: u32, scroll: bool) ?FindRequest {
        if (text.len > 256) return null;
        var result: FindRequest = .{ .current = current, .scroll = scroll };
        @memcpy(result.query[0..text.len], text);
        result.query_len = @intCast(text.len);
        return result;
    }

    pub fn bytes(self: *const FindRequest) ?[]const u8 {
        if (self.query_len > self.query.len) return null;
        return self.query[0..self.query_len];
    }
};
pub const SelectKind = enum(u8) { word, line };
pub const SelectRequest = struct { kind: SelectKind, row: u16, col: u16 };

/// Closed mirror of the host core-command wire. It deliberately contains no method string,
/// encoded JSON, stream id, allocator, or process-local pointer.
pub const CoreCommandRequest = union(enum) {
    scroll: i64,
    scroll_to_bottom,
    scroll_to_abs: u64,
    scroll_to_offset: u64,
    report_focus: bool,
    set_cell_metrics: struct { width: u32, height: u32 },
    set_default_colors: struct { foreground: u32, background: u32 },
    set_config_palette: [16]?u32,
    set_max_scrollback: u64,
    set_ambiguous_wide: bool,
    set_emoji_wide: bool,
    set_default_cursor_shape: u8,
    set_runtime_config: struct {
        max_scrollback: u64,
        ambiguous_wide: bool,
        emoji_wide: bool,
        palette: [16]?u32,
        foreground: u32,
        background: u32,
        cell_width: u32,
        cell_height: u32,
        cursor_shape: u8,
    },
    jump_to_prompt: i8,
    reset_input_modes,
};

pub const MouseReportRequest = struct {
    button: u8,
    col: u16,
    row: u16,
    x_px: u32,
    y_px: u32,
    pressed: bool,
    motion: bool,
    mods: u8,
};

const RawOptionalU32 = extern struct { present: u8, value: u32 };
const RawSelectedTextRequest = extern struct {
    start_row: u64,
    start_col: u64,
    end_row: u64,
    end_col: u64,
    block: u8,
};
const RawFindRequest = extern struct {
    query: [256]u8,
    query_len: u16,
    current: u32,
    scroll: u8,
};
const RawSelectRequest = extern struct { kind: u8, row: u16, col: u16 };
const RawMouseReportRequest = extern struct {
    button: u8,
    col: u16,
    row: u16,
    x_px: u32,
    y_px: u32,
    pressed: u8,
    motion: u8,
    mods: u8,
};
const RawRuntimeConfig = extern struct {
    max_scrollback: u64,
    ambiguous_wide: u8,
    emoji_wide: u8,
    palette: [16]RawOptionalU32,
    foreground: u32,
    background: u32,
    cell_width: u32,
    cell_height: u32,
    cursor_shape: u8,
};
const RawCorePayload = extern union {
    empty: u8,
    scroll: i64,
    unsigned: u64,
    flag: u8,
    cell_metrics: extern struct { width: u32, height: u32 },
    colors: extern struct { foreground: u32, background: u32 },
    palette: [16]RawOptionalU32,
    shape: u8,
    runtime_config: RawRuntimeConfig,
    direction: i8,
};
const RawCoreCommand = extern struct { tag: u8, payload: RawCorePayload };
const RuntimeRequestPayload = extern union {
    empty: u8,
    resize: ResizeRequest,
    selected_text: RawSelectedTextRequest,
    link_at: LinkAtRequest,
    find: RawFindRequest,
    select_op: RawSelectRequest,
    core_command: RawCoreCommand,
    report_mouse: RawMouseReportRequest,
};

/// Public request boundary with an explicit raw discriminator. A Zig tagged
/// union cannot inspect an invalid discriminant without already invoking
/// undefined behavior, so callers construct this closed DTO and ClientSlot
/// decodes it before any tagged-union switch or semantic read.
pub const RuntimeRequest = extern struct {
    tag: u8,
    payload: RuntimeRequestPayload,

    fn empty(comptime tag: RuntimeRequestTag) RuntimeRequest {
        return .{ .tag = @intFromEnum(tag), .payload = .{ .empty = 0 } };
    }

    pub fn spawnFull() RuntimeRequest {
        return empty(.spawn_full);
    }
    pub fn attachController() RuntimeRequest {
        return empty(.attach_controller);
    }
    pub fn resize(value: ResizeRequest) RuntimeRequest {
        return .{ .tag = @intFromEnum(RuntimeRequestTag.resize), .payload = .{ .resize = value } };
    }
    pub fn observation() RuntimeRequest {
        return empty(.observation);
    }
    pub fn selectedText(value: SelectedTextRequest) RuntimeRequest {
        return .{ .tag = @intFromEnum(RuntimeRequestTag.selected_text), .payload = .{ .selected_text = .{
            .start_row = value.start_row,
            .start_col = value.start_col,
            .end_row = value.end_row,
            .end_col = value.end_col,
            .block = @intFromBool(value.block),
        } } };
    }
    pub fn linkAt(value: LinkAtRequest) RuntimeRequest {
        return .{ .tag = @intFromEnum(RuntimeRequestTag.link_at), .payload = .{ .link_at = value } };
    }
    pub fn clipboardWrite() RuntimeRequest {
        return empty(.clipboard_write);
    }
    pub fn find(value: FindRequest) RuntimeRequest {
        return .{ .tag = @intFromEnum(RuntimeRequestTag.find), .payload = .{ .find = .{
            .query = value.query,
            .query_len = value.query_len,
            .current = value.current,
            .scroll = @intFromBool(value.scroll),
        } } };
    }
    pub fn selectOp(value: SelectRequest) RuntimeRequest {
        return .{ .tag = @intFromEnum(RuntimeRequestTag.select_op), .payload = .{ .select_op = .{
            .kind = @intFromEnum(value.kind),
            .row = value.row,
            .col = value.col,
        } } };
    }
    pub fn coreCommand(value: CoreCommandRequest) RuntimeRequest {
        return .{ .tag = @intFromEnum(RuntimeRequestTag.core_command), .payload = .{
            .core_command = encodeRawCoreCommand(value),
        } };
    }
    pub fn reportMouse(value: MouseReportRequest) RuntimeRequest {
        return .{ .tag = @intFromEnum(RuntimeRequestTag.report_mouse), .payload = .{ .report_mouse = .{
            .button = value.button,
            .col = value.col,
            .row = value.row,
            .x_px = value.x_px,
            .y_px = value.y_px,
            .pressed = @intFromBool(value.pressed),
            .motion = @intFromBool(value.motion),
            .mods = value.mods,
        } } };
    }
    pub fn notification() RuntimeRequest {
        return empty(.notification);
    }
    pub fn terminate() RuntimeRequest {
        return empty(.terminate);
    }
    pub fn detach() RuntimeRequest {
        return empty(.detach);
    }

    pub fn decode(self: *const RuntimeRequest) ?ValidatedRuntimeRequest {
        return switch (self.tag) {
            @intFromEnum(RuntimeRequestTag.spawn_full) => .spawn_full,
            @intFromEnum(RuntimeRequestTag.attach_controller) => .attach_controller,
            @intFromEnum(RuntimeRequestTag.resize) => blk: {
                const value = self.payload.resize;
                if (value.cols == 0 or value.rows == 0 or value.client_sequence == 0)
                    break :blk null;
                break :blk .{ .resize = value };
            },
            @intFromEnum(RuntimeRequestTag.observation) => .observation,
            @intFromEnum(RuntimeRequestTag.selected_text) => blk: {
                const value = self.payload.selected_text;
                if (value.block > 1) break :blk null;
                break :blk .{ .selected_text = .{
                    .start_row = value.start_row,
                    .start_col = value.start_col,
                    .end_row = value.end_row,
                    .end_col = value.end_col,
                    .block = value.block == 1,
                } };
            },
            @intFromEnum(RuntimeRequestTag.link_at) => .{ .link_at = self.payload.link_at },
            @intFromEnum(RuntimeRequestTag.clipboard_write) => .clipboard_write,
            @intFromEnum(RuntimeRequestTag.find) => blk: {
                const value = self.payload.find;
                if (value.scroll > 1 or value.query_len > value.query.len) break :blk null;
                break :blk .{ .find = .{
                    .query = value.query,
                    .query_len = value.query_len,
                    .current = value.current,
                    .scroll = value.scroll == 1,
                } };
            },
            @intFromEnum(RuntimeRequestTag.select_op) => blk: {
                const value = self.payload.select_op;
                const kind: SelectKind = switch (value.kind) {
                    @intFromEnum(SelectKind.word) => .word,
                    @intFromEnum(SelectKind.line) => .line,
                    else => break :blk null,
                };
                break :blk .{ .select_op = .{ .kind = kind, .row = value.row, .col = value.col } };
            },
            @intFromEnum(RuntimeRequestTag.core_command) => .{
                .core_command = decodeRawCoreCommand(&self.payload.core_command) orelse return null,
            },
            @intFromEnum(RuntimeRequestTag.report_mouse) => blk: {
                const value = self.payload.report_mouse;
                if (value.pressed > 1 or value.motion > 1) break :blk null;
                break :blk .{ .report_mouse = .{
                    .button = value.button,
                    .col = value.col,
                    .row = value.row,
                    .x_px = value.x_px,
                    .y_px = value.y_px,
                    .pressed = value.pressed == 1,
                    .motion = value.motion == 1,
                    .mods = value.mods,
                } };
            },
            @intFromEnum(RuntimeRequestTag.notification) => .notification,
            @intFromEnum(RuntimeRequestTag.terminate) => .terminate,
            @intFromEnum(RuntimeRequestTag.detach) => .detach,
            else => null,
        };
    }
};

pub const ValidatedRuntimeRequest = union(RuntimeRequestTag) {
    spawn_full,
    attach_controller,
    resize: ResizeRequest,
    observation,
    selected_text: SelectedTextRequest,
    link_at: LinkAtRequest,
    clipboard_write,
    find: FindRequest,
    select_op: SelectRequest,
    core_command: CoreCommandRequest,
    report_mouse: MouseReportRequest,
    notification,
    terminate,
    detach,

    pub fn family(self: @This()) RequestFamily {
        return switch (self) {
            .find => |value| if (value.scroll) .bound_controller_mutation else .bound_observation,
            else => requestFamilyForTag(std.meta.activeTag(self)),
        };
    }
};

fn encodeRawOptional(value: ?u32) RawOptionalU32 {
    return if (value) |color|
        .{ .present = 1, .value = color }
    else
        .{ .present = 0, .value = 0 };
}

fn encodeRawPalette(values: [16]?u32) [16]RawOptionalU32 {
    var result: [16]RawOptionalU32 = undefined;
    for (&result, values) |*out, value| out.* = encodeRawOptional(value);
    return result;
}

fn decodeRawPalette(values: *const [16]RawOptionalU32) ?[16]?u32 {
    var result: [16]?u32 = undefined;
    for (values, &result) |value, *out| {
        out.* = switch (value.present) {
            0 => null,
            1 => value.value,
            else => return null,
        };
    }
    return result;
}

fn encodeRawCoreCommand(value: CoreCommandRequest) RawCoreCommand {
    const Tag = std.meta.Tag(CoreCommandRequest);
    return switch (value) {
        .scroll => |arg| .{ .tag = @intFromEnum(Tag.scroll), .payload = .{ .scroll = arg } },
        .scroll_to_bottom => .{ .tag = @intFromEnum(Tag.scroll_to_bottom), .payload = .{ .empty = 0 } },
        .scroll_to_abs => |arg| .{ .tag = @intFromEnum(Tag.scroll_to_abs), .payload = .{ .unsigned = arg } },
        .scroll_to_offset => |arg| .{ .tag = @intFromEnum(Tag.scroll_to_offset), .payload = .{ .unsigned = arg } },
        .report_focus => |flag| .{ .tag = @intFromEnum(Tag.report_focus), .payload = .{ .flag = @intFromBool(flag) } },
        .set_cell_metrics => |metrics| .{ .tag = @intFromEnum(Tag.set_cell_metrics), .payload = .{ .cell_metrics = .{
            .width = metrics.width,
            .height = metrics.height,
        } } },
        .set_default_colors => |colors| .{ .tag = @intFromEnum(Tag.set_default_colors), .payload = .{ .colors = .{
            .foreground = colors.foreground,
            .background = colors.background,
        } } },
        .set_config_palette => |palette| .{ .tag = @intFromEnum(Tag.set_config_palette), .payload = .{ .palette = encodeRawPalette(palette) } },
        .set_max_scrollback => |lines| .{ .tag = @intFromEnum(Tag.set_max_scrollback), .payload = .{ .unsigned = lines } },
        .set_ambiguous_wide => |flag| .{ .tag = @intFromEnum(Tag.set_ambiguous_wide), .payload = .{ .flag = @intFromBool(flag) } },
        .set_emoji_wide => |flag| .{ .tag = @intFromEnum(Tag.set_emoji_wide), .payload = .{ .flag = @intFromBool(flag) } },
        .set_default_cursor_shape => |shape| .{ .tag = @intFromEnum(Tag.set_default_cursor_shape), .payload = .{ .shape = shape } },
        .set_runtime_config => |config| .{ .tag = @intFromEnum(Tag.set_runtime_config), .payload = .{ .runtime_config = .{
            .max_scrollback = config.max_scrollback,
            .ambiguous_wide = @intFromBool(config.ambiguous_wide),
            .emoji_wide = @intFromBool(config.emoji_wide),
            .palette = encodeRawPalette(config.palette),
            .foreground = config.foreground,
            .background = config.background,
            .cell_width = config.cell_width,
            .cell_height = config.cell_height,
            .cursor_shape = config.cursor_shape,
        } } },
        .jump_to_prompt => |direction| .{ .tag = @intFromEnum(Tag.jump_to_prompt), .payload = .{ .direction = direction } },
        .reset_input_modes => .{ .tag = @intFromEnum(Tag.reset_input_modes), .payload = .{ .empty = 0 } },
    };
}

fn decodeRawCoreCommand(raw: *const RawCoreCommand) ?CoreCommandRequest {
    const Tag = std.meta.Tag(CoreCommandRequest);
    return switch (raw.tag) {
        @intFromEnum(Tag.scroll) => .{ .scroll = raw.payload.scroll },
        @intFromEnum(Tag.scroll_to_bottom) => .scroll_to_bottom,
        @intFromEnum(Tag.scroll_to_abs) => .{ .scroll_to_abs = raw.payload.unsigned },
        @intFromEnum(Tag.scroll_to_offset) => .{ .scroll_to_offset = raw.payload.unsigned },
        @intFromEnum(Tag.report_focus) => if (raw.payload.flag <= 1)
            .{ .report_focus = raw.payload.flag == 1 }
        else
            null,
        @intFromEnum(Tag.set_cell_metrics) => .{ .set_cell_metrics = .{
            .width = raw.payload.cell_metrics.width,
            .height = raw.payload.cell_metrics.height,
        } },
        @intFromEnum(Tag.set_default_colors) => .{ .set_default_colors = .{
            .foreground = raw.payload.colors.foreground,
            .background = raw.payload.colors.background,
        } },
        @intFromEnum(Tag.set_config_palette) => .{
            .set_config_palette = decodeRawPalette(&raw.payload.palette) orelse return null,
        },
        @intFromEnum(Tag.set_max_scrollback) => .{ .set_max_scrollback = raw.payload.unsigned },
        @intFromEnum(Tag.set_ambiguous_wide) => if (raw.payload.flag <= 1)
            .{ .set_ambiguous_wide = raw.payload.flag == 1 }
        else
            null,
        @intFromEnum(Tag.set_emoji_wide) => if (raw.payload.flag <= 1)
            .{ .set_emoji_wide = raw.payload.flag == 1 }
        else
            null,
        @intFromEnum(Tag.set_default_cursor_shape) => .{ .set_default_cursor_shape = raw.payload.shape },
        @intFromEnum(Tag.set_runtime_config) => blk: {
            const config = raw.payload.runtime_config;
            if (config.ambiguous_wide > 1 or config.emoji_wide > 1) break :blk null;
            break :blk .{ .set_runtime_config = .{
                .max_scrollback = config.max_scrollback,
                .ambiguous_wide = config.ambiguous_wide == 1,
                .emoji_wide = config.emoji_wide == 1,
                .palette = decodeRawPalette(&config.palette) orelse break :blk null,
                .foreground = config.foreground,
                .background = config.background,
                .cell_width = config.cell_width,
                .cell_height = config.cell_height,
                .cursor_shape = config.cursor_shape,
            } };
        },
        @intFromEnum(Tag.jump_to_prompt) => .{ .jump_to_prompt = raw.payload.direction },
        @intFromEnum(Tag.reset_input_modes) => .reset_input_modes,
        else => null,
    };
}

/// Capability projection exposed by GenerationTransport. Optional feature
/// support is represented as booleans; no Client or wire storage escapes.
pub const GenerationCapabilities = struct {
    wire_major: u16,
    screen_codec_version: u16,
    attach_schema: AttachSchema,
    metadata_support: MetadataSupport,
    peer_attach_generation: bool,
    screen_viewport_scrolled: bool,
    async_scroll_to_bottom: bool,
    notification_stream_auth: bool,
    runtime_clipboard: bool,
    runtime_core_command: bool,
    runtime_link_at: bool,
    runtime_selected_text: bool,
};

comptime {
    const Expected = struct {
        wire_major: u16,
        screen_codec_version: u16,
        attach_schema: AttachSchema,
        metadata_support: MetadataSupport,
        peer_attach_generation: bool,
        screen_viewport_scrolled: bool,
        async_scroll_to_bottom: bool,
        notification_stream_auth: bool,
        runtime_clipboard: bool,
        runtime_core_command: bool,
        runtime_link_at: bool,
        runtime_selected_text: bool,
    };
    const actual = std.meta.fields(GenerationCapabilities);
    const expected = std.meta.fields(Expected);
    if (actual.len != expected.len)
        @compileError("GenerationCapabilities schema changed without updating CR3a SSOT");
    for (actual, expected) |a, e| {
        if (!std.mem.eql(u8, a.name, e.name) or a.type != e.type)
            @compileError("GenerationCapabilities schema changed without updating CR3a SSOT");
    }
}

pub const AttachSchema = enum(u8) {
    frozen_controller_only,
    granted_roles,
};

pub const MetadataSupport = enum(u8) {
    unsupported,
    supported,
};

fn containsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |info| containsPointer(info.child),
        .optional => |info| containsPointer(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (containsPointer(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (containsPointer(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

test "CR3a-2a prepared and executed call receipts are pointer-free exact identities" {
    const prepared = PreparedCallReceipt.init(.{
        .transport_incarnation = 11,
        .request_id = 17,
        .request_digest = 23,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(prepared.matches(prepared));
    try std.testing.expect(!prepared.matches(.{
        .transport_incarnation = 11,
        .request_id = 18,
        .request_digest = 23,
    }));

    const executed = ExecutedCallReceipt.fromPrepared(prepared) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(executed.matchesPrepared(prepared));
    try std.testing.expect(!executed.matchesPrepared(.{
        .transport_incarnation = 12,
        .request_id = 17,
        .request_digest = 23,
    }));
}

test "CR3a-2a binding identity rejects zero and foreign request splices" {
    const prepared = PreparedCallReceipt.init(.{
        .transport_incarnation = 31,
        .request_id = 37,
        .request_digest = 41,
    }).?;
    const binding = BindingIdentity.init(.{
        .binding_incarnation = 43,
        .binding_storage_addr = 45,
        .destination_addr = 47,
        .binding_reservation_id = 49,
        .slot_incarnation = 53,
        .node_incarnation = 59,
        .host_id = 61,
        .connection_generation = 1,
        .runtime_id = 67,
        .role = .controller,
        .pid = 71,
        .process_nonce = 73,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(binding.valid());

    var foreign = prepared;
    foreign.request_id += 1;
    try std.testing.expect(!prepared.matches(foreign));
    try std.testing.expect(BindingIdentity.init(.{
        .binding_incarnation = 0,
        .binding_storage_addr = 45,
        .destination_addr = 47,
        .binding_reservation_id = 49,
        .slot_incarnation = 53,
        .node_incarnation = 59,
        .host_id = 61,
        .connection_generation = 1,
        .runtime_id = 67,
        .role = .controller,
        .pid = 71,
        .process_nonce = 73,
    }) == null);
}

test "CR3a-2c3a binding identity rejects every invalid raw attachment role" {
    var identity = BindingIdentity{
        .binding_incarnation = 1,
        .binding_storage_addr = 2,
        .destination_addr = 3,
        .binding_reservation_id = 4,
        .slot_incarnation = 5,
        .node_incarnation = 6,
        .host_id = 7,
        .connection_generation = 1,
        .runtime_id = 8,
        .role = .controller,
        .pid = 9,
        .process_nonce = 10,
    };
    const role_raw: *u8 = @ptrCast(&identity.role);
    var raw: u16 = @intFromEnum(AttachmentRole.observer) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        role_raw.* = @intCast(raw);
        try std.testing.expect(!identity.valid());
        try std.testing.expect(!identity.matches(identity));
    }
}

test "CR3a-2a neutral lifecycle and request vocabularies are closed" {
    try std.testing.expectEqual(@as(usize, 6), std.enums.values(BindingLifecycle).len);
    try std.testing.expectEqual(@as(usize, 5), std.enums.values(ExecutedResponseLifecycle).len);
    // The SSOT list contains fourteen variants; an earlier RED inventory
    // accidentally omitted detach while the written list still included it.
    try std.testing.expectEqual(@as(usize, 14), std.meta.fields(RuntimeRequestTag).len);
    try std.testing.expectEqual(@as(usize, 5), std.enums.values(RequestFamily).len);
    try std.testing.expectEqual(@as(usize, 3), std.enums.values(ExecuteOutcome).len);
}

test "CR3a-2c3b every request tag has one closed request family" {
    const expected = [_]RequestFamily{
        .connection_only_denied,
        .attach_only,
        .bound_controller_mutation,
        .bound_observation,
        .bound_observation,
        .bound_observation,
        .bound_controller_mutation,
        .bound_observation,
        .bound_observation,
        .bound_controller_mutation,
        .bound_controller_mutation,
        .bound_controller_mutation,
        .bound_terminal,
        .bound_terminal,
    };
    inline for (std.enums.values(RuntimeRequestTag), expected) |tag, family|
        try std.testing.expectEqual(family, requestFamilyForTag(tag));
}

test "CR3a-2c3b canonical family admission has one role-sensitive exception" {
    inline for (std.enums.values(RuntimeRequestTag)) |tag| {
        inline for (std.enums.values(RequestFamily)) |family| {
            const expected = if (tag == .find)
                family == .bound_observation or family == .bound_controller_mutation
            else
                family == requestFamilyForTag(tag);
            try std.testing.expectEqual(expected, requestFamilyAllowed(tag, family));
        }
    }
}

test "CR3a-2c3b find scroll is the sole role-sensitive family discriminator" {
    const observe = RuntimeRequest.find(FindRequest.init("needle", 3, false).?);
    const mutate = RuntimeRequest.find(FindRequest.init("needle", 3, true).?);
    const observed = observe.decode().?;
    const mutated = mutate.decode().?;
    try std.testing.expectEqual(RequestFamily.bound_observation, observed.family());
    try std.testing.expectEqual(RequestFamily.bound_controller_mutation, mutated.family());
    try std.testing.expectEqual(RuntimeRequestTag.find, std.meta.activeTag(observed));
    try std.testing.expectEqual(RuntimeRequestTag.find, std.meta.activeTag(mutated));
}

test "CR3a-2c3b request raw discriminators fail closed before semantic reads" {
    var request = RuntimeRequest.find(FindRequest.init("x", 0, false).?);
    try std.testing.expect(request.decode() != null);
    request.payload.find.scroll = 0xff;
    try std.testing.expect(request.decode() == null);

    request = RuntimeRequest.selectOp(.{ .kind = .word, .row = 1, .col = 2 });
    request.payload.select_op.kind = 0xff;
    try std.testing.expect(request.decode() == null);

    var raw: u16 = @intFromEnum(RuntimeRequestTag.detach) + 1;
    while (raw <= std.math.maxInt(u8)) : (raw += 1) {
        request.tag = @intCast(raw);
        try std.testing.expect(request.decode() == null);
    }

    request = RuntimeRequest.coreCommand(.{ .report_focus = true });
    request.payload.core_command.payload.flag = 2;
    try std.testing.expect(request.decode() == null);
    request = RuntimeRequest.coreCommand(.{ .set_config_palette = [_]?u32{null} ** 16 });
    request.payload.core_command.payload.palette[7].present = 2;
    try std.testing.expect(request.decode() == null);
    request = RuntimeRequest.coreCommand(.reset_input_modes);
    request.payload.core_command.tag = 0xff;
    try std.testing.expect(request.decode() == null);

    request = RuntimeRequest.attachController();
    @memset(std.mem.asBytes(&request.payload), 0xa5);
    try std.testing.expectEqual(
        RuntimeRequestTag.attach_controller,
        std.meta.activeTag(request.decode().?),
    );
}

test "CR3a-2a neutral identities and capabilities recursively contain no pointers" {
    try std.testing.expect(!containsPointer(PreparedCallReceipt));
    try std.testing.expect(!containsPointer(ExecutedCallReceipt));
    try std.testing.expect(!containsPointer(CorrelatedExecutedCall));
    try std.testing.expect(!containsPointer(ExecuteResult));
    try std.testing.expect(!containsPointer(BindingIdentity));
    try std.testing.expect(!containsPointer(RuntimeRequest));
    try std.testing.expect(!containsPointer(GenerationCapabilities));
}

test "CR3a-2a zero receipt components never become authority" {
    inline for (0..3) |zero_index| {
        var fields = PreparedCallReceipt{
            .transport_incarnation = 11,
            .request_id = 17,
            .request_digest = 23,
        };
        switch (zero_index) {
            0 => fields.transport_incarnation = 0,
            1 => fields.request_id = 0,
            2 => fields.request_digest = 0,
            else => unreachable,
        }
        try std.testing.expect(PreparedCallReceipt.init(fields) == null);
    }

    const prepared = PreparedCallReceipt.init(.{
        .transport_incarnation = 11,
        .request_id = 17,
        .request_digest = 23,
    }).?;
    var invalid_prepared = prepared;
    invalid_prepared.request_id = 0;
    try std.testing.expect(ExecutedCallReceipt.fromPrepared(invalid_prepared) == null);
}

test "CR3a-2a prepared binding reserves before request and rejects copied execution" {
    var attachment_owner_marker: u64 = 0;
    var binding: PreparedAttachmentBinding = .{};
    const destination_addr = @intFromPtr(&attachment_owner_marker);
    const identity = BindingIdentity.init(.{
        .binding_incarnation = 3,
        .binding_storage_addr = @intFromPtr(&binding),
        .destination_addr = destination_addr,
        .binding_reservation_id = 5,
        .slot_incarnation = 7,
        .node_incarnation = 9,
        .host_id = (@as(u128, 1) << 96) | 11,
        .connection_generation = 1,
        .runtime_id = (@as(u128, 1) << 80) | 13,
        .role = .controller,
        .pid = 17,
        .process_nonce = 19,
    }).?;
    try std.testing.expect(destination_addr != @intFromPtr(&binding));
    try PreparedAttachmentBinding.initReservedInPlace(&binding, identity);
    try std.testing.expectEqual(BindingLifecycle.reserved, binding.lifecycle);

    const prepared = PreparedCallReceipt.init(.{
        .transport_incarnation = 23,
        .request_id = 29,
        .request_digest = 31,
    }).?;
    try binding.pairRequest(prepared);
    var copied = binding;
    try std.testing.expectError(error.MovedOrCopied, copied.beginExecute(prepared));
    try std.testing.expectEqual(BindingLifecycle.request_paired, binding.lifecycle);

    try binding.beginExecute(prepared);
    try std.testing.expectError(error.InvalidState, binding.beginExecute(prepared));
    try std.testing.expectEqual(BindingLifecycle.executing, binding.lifecycle);
}

test "CR3a-2a generation one and full-width host runtime identities are exact" {
    var binding: PreparedAttachmentBinding = .{};
    const canonical = BindingIdentity.init(.{
        .binding_incarnation = 3,
        .binding_storage_addr = @intFromPtr(&binding),
        .destination_addr = @intFromPtr(&binding),
        .binding_reservation_id = 5,
        .slot_incarnation = 7,
        .node_incarnation = 9,
        .host_id = (@as(u128, 1) << 96) | 11,
        .connection_generation = 1,
        .runtime_id = (@as(u128, 1) << 80) | 13,
        .role = .controller,
        .pid = 17,
        .process_nonce = 19,
    }).?;
    var foreign_host = canonical;
    foreign_host.host_id ^= @as(u128, 1) << 96;
    var foreign_runtime = canonical;
    foreign_runtime.runtime_id ^= @as(u128, 1) << 80;
    try std.testing.expect(!canonical.matches(foreign_host));
    try std.testing.expect(!canonical.matches(foreign_runtime));

    var future_generation = canonical;
    future_generation.connection_generation = 2;
    try std.testing.expect(!future_generation.valid());
}

test "CR3a-2a every scalar binding authority rejects zero and every foreign field mismatches" {
    var binding: PreparedAttachmentBinding = .{};
    const canonical = BindingIdentity.init(.{
        .binding_incarnation = 3,
        .binding_storage_addr = @intFromPtr(&binding),
        .destination_addr = @intFromPtr(&binding),
        .binding_reservation_id = 5,
        .slot_incarnation = 7,
        .node_incarnation = 9,
        .host_id = (@as(u128, 1) << 96) | 11,
        .connection_generation = 1,
        .runtime_id = (@as(u128, 1) << 80) | 13,
        .role = .controller,
        .pid = 17,
        .process_nonce = 19,
    }).?;

    inline for (0..11) |index| {
        var candidate = canonical;
        switch (index) {
            0 => candidate.binding_incarnation = 0,
            1 => candidate.binding_storage_addr = 0,
            2 => candidate.destination_addr = 0,
            3 => candidate.binding_reservation_id = 0,
            4 => candidate.slot_incarnation = 0,
            5 => candidate.node_incarnation = 0,
            6 => candidate.host_id = 0,
            7 => candidate.connection_generation = 0,
            8 => candidate.runtime_id = 0,
            9 => candidate.pid = 0,
            10 => candidate.process_nonce = 0,
            else => unreachable,
        }
        try std.testing.expect(!candidate.valid());
    }

    inline for (0..12) |index| {
        var foreign = canonical;
        switch (index) {
            0 => foreign.binding_incarnation += 1,
            1 => foreign.binding_storage_addr += 1,
            2 => foreign.destination_addr += 1,
            3 => foreign.binding_reservation_id += 1,
            4 => foreign.slot_incarnation += 1,
            5 => foreign.node_incarnation += 1,
            6 => foreign.host_id += 1,
            7 => foreign.connection_generation = 2,
            8 => foreign.runtime_id += 1,
            9 => foreign.role = .observer,
            10 => foreign.pid += 1,
            11 => foreign.process_nonce += 1,
            else => unreachable,
        }
        try std.testing.expect(!canonical.matches(foreign));
    }
}

test "CR3a-2a execute result preserves correlation only for response-bearing outcomes" {
    const prepared = PreparedCallReceipt.init(.{
        .transport_incarnation = 3,
        .request_id = 5,
        .request_digest = 7,
    }).?;
    const executed = ExecutedCallReceipt.fromPrepared(prepared).?;
    const correlated = CorrelatedExecutedCall.init(executed, prepared.request_id).?;
    try std.testing.expect(correlated.responseMatchesPrepared());

    const accepted: ExecuteResult = .{ .accepted = correlated };
    try std.testing.expect(accepted.accepted.responseMatchesPrepared());
    const uncertain: ExecuteResult = .{ .uncertain_or_connection_failure = executed };
    try std.testing.expect(uncertain.uncertain_or_connection_failure.matchesPrepared(prepared));

    const mismatched = CorrelatedExecutedCall.init(executed, prepared.request_id + 1).?;
    try std.testing.expect(!mismatched.responseMatchesPrepared());
    try std.testing.expect(CorrelatedExecutedCall.init(executed, 0) == null);
}
