//! GUI `RemoteRuntime`과 public attach가 공유할 stream role/authority wire boundary.
//! Connection transport와 GUI Surface를 소유하지 않으며 strict host result/event를 attachment-local state로 접는다.

const std = @import("std");
const protocol = @import("protocol.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");
const client_mod = @import("client.zig");
const external_inbox_ledger = @import("external_inbox_ledger.zig");
const remote_screen = @import("remote_screen.zig");
const screen_assembler = @import("screen_assembler.zig");

pub const AttachmentBatchLease = union(enum) {
    untracked: client_mod.StreamBatch,
    charged: external_inbox_ledger.Token,

    fn borrow(
        self: AttachmentBatchLease,
        transport: AttachmentTransport,
    ) LeaseError!external_inbox_ledger.BatchView {
        return switch (self) {
            .untracked => |batch| .{
                .is_snapshot = batch.is_snapshot,
                .stream_id = batch.stream_id,
                .provenance = .untracked,
                .bytes = batch.bytes,
            },
            .charged => |token| {
                const borrow_charged = transport.borrow_charged orelse
                    return error.LedgerInvariant;
                return borrow_charged(transport.context, token) catch
                    return error.LedgerInvariant;
            },
        };
    }

    fn release(
        self: AttachmentBatchLease,
        transport: AttachmentTransport,
    ) enum { ok, invariant_failure } {
        switch (self) {
            .untracked => |batch| {
                batch.deinit();
                return .ok;
            },
            .charged => |token| {
                const release_charged = transport.release_charged orelse
                    return .invariant_failure;
                release_charged(transport.context, token) catch
                    return .invariant_failure;
                return .ok;
            },
        }
    }
};

pub const LeaseError = error{LedgerInvariant};

pub const AttachmentTransport = struct {
    context: *anyopaque,
    read_batch: *const fn (
        context: *anyopaque,
        stream_id: u64,
    ) client_mod.ClientError!?AttachmentBatchLease,
    borrow_charged: ?*const fn (
        context: *anyopaque,
        token: external_inbox_ledger.Token,
    ) external_inbox_ledger.InvariantError!external_inbox_ledger.BatchView = null,
    release_charged: ?*const fn (
        context: *anyopaque,
        token: external_inbox_ledger.Token,
    ) external_inbox_ledger.InvariantError!void = null,
    drop_stream: *const fn (context: *anyopaque, stream_id: u64) void,
    fail_closed: *const fn (context: *anyopaque) void,
};

pub const Role = enum { observer, controller };
pub const Mode = enum { observer, controller };

pub const State = struct {
    runtime_id: u128,
    stream_id: u64,
    role: Role,
    controller_generation: u64,
};

/// Attachment-local authority SSOT shared by GUI and the external adapter. It borrows the single
/// connection transport while owning its stream-local queue and screen; callers use the same
/// object for every mutation gate so a busy demotion cannot act like a controller.
pub const RemoteAttachment = struct {
    allocator: std.mem.Allocator,
    state: State,
    transport: ?AttachmentTransport = null,
    screen: ?remote_screen.RemoteScreen = null,
    pending_batches: std.ArrayListUnmanaged(AttachmentBatchLease) = .empty,
    pending_batch_head: usize = 0,
    failed_release: ?AttachmentBatchLease = null,

    pub fn init(allocator: std.mem.Allocator, state: State) RemoteAttachment {
        return .{ .allocator = allocator, .state = state };
    }

    pub fn streamId(self: *const RemoteAttachment) u64 {
        return self.state.stream_id;
    }

    pub fn allowsMutation(self: *const RemoteAttachment) bool {
        return self.state.role == .controller;
    }

    pub fn bindTransport(self: *RemoteAttachment, transport: AttachmentTransport) error{AlreadyBound}!void {
        if (self.transport != null) return error.AlreadyBound;
        self.transport = transport;
    }

    pub fn initScreen(self: *RemoteAttachment, codec: u16) anyerror!void {
        if (self.screen != null) return;
        self.screen = try remote_screen.RemoteScreen.initForCodec(self.allocator, codec);
    }

    pub fn deinit(self: *RemoteAttachment) void {
        if (self.transport) |transport| {
            if (self.failed_release) |lease| {
                if (lease.release(transport) == .invariant_failure) {
                    transport.fail_closed(transport.context);
                }
            }
            for (self.pending_batches.items[self.pending_batch_head..]) |lease| {
                if (lease.release(transport) == .invariant_failure) {
                    transport.fail_closed(transport.context);
                }
            }
            transport.drop_stream(transport.context, self.state.stream_id);
        } else {
            if (self.failed_release) |lease| switch (lease) {
                .untracked => |batch| batch.deinit(),
                .charged => {},
            };
            for (self.pending_batches.items[self.pending_batch_head..]) |lease| switch (lease) {
                .untracked => |batch| batch.deinit(),
                .charged => {},
            };
        }
        self.pending_batches.deinit(self.allocator);
        if (self.screen) |*screen| screen.deinit();
        self.* = undefined;
    }

    /// Pull one stream-local batch from the borrowed connection into attachment-owned storage,
    /// then apply it to the attachment-owned screen. The queue owns bytes across any future split
    /// between transport and render turns.
    pub fn pumpScreen(
        self: *RemoteAttachment,
        io: std.Io,
    ) (client_mod.ClientError || screen_assembler.ApplyError || LeaseError)!bool {
        const transport = self.transport orelse return error.ConnectionClosed;
        // A failed release is already a terminal ownership invariant. Never consume another
        // transport batch and risk needing a second allocation-free recovery slot.
        if (self.failed_release != null) {
            transport.fail_closed(transport.context);
            return error.LedgerInvariant;
        }
        if (try transport.read_batch(transport.context, self.state.stream_id)) |lease| {
            self.pending_batches.append(self.allocator, lease) catch {
                const released = self.releaseOrRetain(lease, transport);
                transport.fail_closed(transport.context);
                if (!released) return error.LedgerInvariant;
                return error.OutOfMemory;
            };
        }
        if (self.pending_batch_head == self.pending_batches.items.len) return false;
        const lease = self.pending_batches.items[self.pending_batch_head];
        self.pending_batch_head += 1;
        const batch = lease.borrow(transport) catch {
            _ = self.releaseOrRetain(lease, transport);
            self.compactConsumedBatches();
            transport.fail_closed(transport.context);
            return error.LedgerInvariant;
        };
        if (batch.stream_id != self.state.stream_id) {
            const released = self.releaseOrRetain(lease, transport);
            self.compactConsumedBatches();
            transport.fail_closed(transport.context);
            if (!released) return error.LedgerInvariant;
            return error.LedgerInvariant;
        }
        const screen = &(self.screen orelse {
            const released = self.releaseOrRetain(lease, transport);
            self.compactConsumedBatches();
            transport.fail_closed(transport.context);
            if (!released) return error.LedgerInvariant;
            return error.ProtocolError;
        });
        if (batch.is_snapshot) {
            screen.applySnapshot(batch.bytes, io) catch |err| {
                const released = self.releaseOrRetain(lease, transport);
                self.compactConsumedBatches();
                transport.fail_closed(transport.context);
                if (!released) return error.LedgerInvariant;
                return err;
            };
        } else {
            screen.applyDelta(batch.bytes, io) catch |err| {
                const released = self.releaseOrRetain(lease, transport);
                self.compactConsumedBatches();
                transport.fail_closed(transport.context);
                if (!released) return error.LedgerInvariant;
                return err;
            };
        }
        if (!self.releaseOrRetain(lease, transport)) {
            self.compactConsumedBatches();
            transport.fail_closed(transport.context);
            return error.LedgerInvariant;
        }
        self.compactConsumedBatches();
        return true;
    }

    /// A callback invariant can fail after the transport already handed ownership to us. Keep the
    /// one terminal lease in allocation-free storage so teardown can retry instead of losing the
    /// only token capable of releasing the stable ledger slot.
    fn releaseOrRetain(
        self: *RemoteAttachment,
        lease: AttachmentBatchLease,
        transport: AttachmentTransport,
    ) bool {
        if (lease.release(transport) == .ok) return true;
        if (self.failed_release == null) self.failed_release = lease;
        return false;
    }

    /// Preserve FIFO without `orderedRemove(0)`'s quadratic drain. Consumed prefix copies carry no
    /// ownership; compaction is amortized and only moves still-live leases.
    fn compactConsumedBatches(self: *RemoteAttachment) void {
        const len = self.pending_batches.items.len;
        if (self.pending_batch_head == len) {
            self.pending_batches.clearRetainingCapacity();
            self.pending_batch_head = 0;
            return;
        }
        if (self.pending_batch_head < len / 2) return;
        const remaining = len - self.pending_batch_head;
        std.mem.copyForwards(
            AttachmentBatchLease,
            self.pending_batches.items[0..remaining],
            self.pending_batches.items[self.pending_batch_head..],
        );
        self.pending_batches.items.len = remaining;
        self.pending_batch_head = 0;
    }

    /// Applies a revoke already bound to this attachment by `runtime_event_types`.
    pub fn applyValidatedRevoked(
        self: *RemoteAttachment,
        successor_generation: u64,
    ) error{InvalidAuthority}!void {
        if (self.state.role != .controller) return error.InvalidAuthority;
        const expected = std.math.add(u64, self.state.controller_generation, 1) catch
            return error.InvalidAuthority;
        if (successor_generation != expected) return error.InvalidAuthority;
        self.state.role = .observer;
        self.state.controller_generation = successor_generation;
    }
};

pub const AttachResult = struct {
    state: State,
    controller_busy: bool,
    initial_metadata: runtime_metadata_wire.InitialMetadataSeed = .unsupported,

    pub fn deinit(self: *AttachResult) void {
        self.initial_metadata.deinit();
        self.* = undefined;
    }
};

pub const AttachDecodeProfile = runtime_metadata_wire.AttachDecodeProfile;
pub const AttachDecodeError = runtime_metadata_wire.DecodeError;

pub const AttachResponse = union(enum) {
    wire_error: protocol.ErrorCode,
    accepted: AttachResult,

    pub fn deinit(self: *AttachResponse) void {
        switch (self.*) {
            .accepted => |*accepted| accepted.deinit(),
            .wire_error => {},
        }
        self.* = undefined;
    }
};

pub const Status = struct {
    stream_id: u64,
    controller_generation: u64,
    controller: bool,
};

pub const DecodeError = error{ OutOfMemory, Malformed };

pub fn decodeAttachResponse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    runtime_id: u128,
    requested: Mode,
    profile: AttachDecodeProfile,
) AttachDecodeError!AttachResponse {
    var envelope = try runtime_metadata_wire.decodeAttachEnvelope(allocator, bytes, profile);
    defer envelope.deinit();
    return switch (envelope) {
        .wire_error => |code| .{ .wire_error = code },
        .accepted => |*accepted| blk: {
            const role: Role = if (accepted.input) .controller else .observer;
            if (profile.generation_schema == .granted_with_generation and
                accepted.controller_generation == 0 and
                (role == .controller or accepted.controller_busy))
                return error.Malformed;
            switch (requested) {
                .observer => if (role != .observer or accepted.controller_busy)
                    return error.Malformed,
                .controller => switch (role) {
                    .controller => if (accepted.controller_busy) return error.Malformed,
                    .observer => if (!accepted.controller_busy) return error.Malformed,
                },
            }
            break :blk .{ .accepted = .{
                .state = .{
                    .runtime_id = runtime_id,
                    .stream_id = accepted.stream_id,
                    .role = role,
                    .controller_generation = accepted.controller_generation,
                },
                .controller_busy = accepted.controller_busy,
                .initial_metadata = accepted.initial_metadata.take(),
            } };
        },
    };
}

/// Strict one-field response-envelope classification shared by attach/status/takeover consumers.
/// `null` means an exact `result` envelope; unknown error names and extra fields are protocol
/// malformed instead of silently collapsing into a retryable class.
pub fn decodeWireError(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) DecodeError!?protocol.ErrorCode {
    var parsed = try parseObject(allocator, bytes);
    defer parsed.deinit();
    const root = parsed.value.object;
    if (root.count() != 1) return error.Malformed;
    if (root.get("result") != null) return null;
    const value = root.get("error") orelse return error.Malformed;
    const name = switch (value) {
        .string => |text| text,
        else => return error.Malformed,
    };
    const code = protocol.ErrorCode.fromWireName(name) orelse return error.Malformed;
    return switch (code) {
        .invalid_generation,
        .resource_exhausted,
        .unauthorized,
        .runtime_not_found,
        .invalid_request,
        .internal,
        => code,
        else => error.Malformed,
    };
}

test "remote attachment error envelope is exact and closed" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(
        protocol.ErrorCode.invalid_generation,
        (try decodeWireError(allocator, "{\"error\":\"invalid_generation\"}")).?,
    );
    try std.testing.expect((try decodeWireError(allocator, "{\"result\":{}}")) == null);
    try std.testing.expectError(
        error.Malformed,
        decodeWireError(allocator, "{\"error\":\"unknown\"}"),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeWireError(allocator, "{\"error\":\"host_shutting_down\"}"),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeWireError(allocator, "{\"error\":\"unauthorized\",\"extra\":1}"),
    );
}

pub fn attachParams(
    allocator: std.mem.Allocator,
    runtime_id: u128,
    mode: Mode,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const runtime_text = runtimeIdText(runtime_id);
    out.writer.print(
        "{{\"runtime_id\":\"{s}\",\"mode\":\"{s}\"}}",
        .{ &runtime_text, @tagName(mode) },
    ) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

pub fn statusParams(
    allocator: std.mem.Allocator,
    stream_id: u64,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    json.write(.{ .stream_id = stream_id }) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

pub fn takeoverParams(
    allocator: std.mem.Allocator,
    stream_id: u64,
    expected_controller_generation: u64,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    json.write(.{
        .stream_id = stream_id,
        .expected_controller_generation = expected_controller_generation,
    }) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

fn runtimeIdText(runtime_id: u128) [32]u8 {
    var text: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{x:0>32}", .{runtime_id}) catch unreachable;
    return text;
}

pub fn decodeStatus(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    state: *State,
) DecodeError!Status {
    var parsed = try parseObject(allocator, bytes);
    defer parsed.deinit();
    const root = parsed.value.object;
    if (root.count() != 1) return error.Malformed;
    const result = objectField(root, "result") orelse return error.Malformed;
    if (result.count() != 3) return error.Malformed;
    const status = Status{
        .stream_id = u64Field(result, "stream_id") orelse return error.Malformed,
        .controller_generation = u64Field(result, "controller_generation") orelse
            return error.Malformed,
        .controller = boolField(result, "controller") orelse return error.Malformed,
    };
    if (status.stream_id != state.stream_id or
        status.controller_generation < state.controller_generation or
        status.controller != (state.role == .controller))
        return error.Malformed;
    state.controller_generation = status.controller_generation;
    return status;
}

pub fn decodeTakeover(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    state: *State,
    expected_generation: u64,
) DecodeError!void {
    if (state.role != .observer or expected_generation != state.controller_generation)
        return error.Malformed;
    var parsed = try parseObject(allocator, bytes);
    defer parsed.deinit();
    const root = parsed.value.object;
    if (root.count() != 1) return error.Malformed;
    const result = objectField(root, "result") orelse return error.Malformed;
    if (result.count() != 5) return error.Malformed;
    const runtime_id = runtimeIdField(result, "runtime_id") orelse return error.Malformed;
    const stream_id = u64Field(result, "stream_id") orelse return error.Malformed;
    const generation = u64Field(result, "controller_generation") orelse return error.Malformed;
    const reason = stringField(result, "reason") orelse return error.Malformed;
    const granted = objectField(result, "granted") orelse return error.Malformed;
    const successor = std.math.add(u64, expected_generation, 1) catch return error.Malformed;
    if (runtime_id != state.runtime_id or stream_id != state.stream_id or
        generation != successor or !std.mem.eql(u8, reason, "takeover") or
        granted.count() != 3 or boolField(granted, "observe") != true or
        boolField(granted, "input") != true or boolField(granted, "resize") != true)
        return error.Malformed;
    state.role = .controller;
    state.controller_generation = generation;
}

const ParsedObject = std.json.Parsed(std.json.Value);

fn parseObject(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!ParsedObject {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        // Dynamic Value's default integer is i64. Wire generations are u64, so preserve the
        // lexical number and parse it below instead of rejecting the valid upper half.
        .parse_numbers = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Malformed,
    };
    if (parsed.value != .object) {
        var owned = parsed;
        owned.deinit();
        return error.Malformed;
    }
    return parsed;
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .object => |result| result,
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn u64Field(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .number_string => |text| parseCanonicalU64(text),
        else => null,
    };
}

fn parseCanonicalU64(text: []const u8) ?u64 {
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn runtimeIdField(object: std.json.ObjectMap, name: []const u8) ?u128 {
    const text = stringField(object, name) orelse return null;
    if (text.len != 32) return null;
    for (text) |byte|
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
    const value = std.fmt.parseInt(u128, text, 16) catch return null;
    return if (value == 0) null else value;
}

const observer_attach =
    "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true,\"metadata_revision\":0,\"metadata\":null}}";

fn decodeAcceptedAttachForTest(
    bytes: []const u8,
    runtime_id: u128,
    requested: Mode,
    profile: AttachDecodeProfile,
) AttachDecodeError!AttachResult {
    var decoded = try decodeAttachResponse(
        std.testing.allocator,
        bytes,
        runtime_id,
        requested,
        profile,
    );
    defer decoded.deinit();
    return switch (decoded) {
        .wire_error => error.Malformed,
        .accepted => |*accepted| .{
            .state = accepted.state,
            .controller_busy = accepted.controller_busy,
            .initial_metadata = accepted.initial_metadata.take(),
        },
    };
}

fn decodeCurrentAttachForTest(
    bytes: []const u8,
    runtime_id: u128,
    requested: Mode,
) AttachDecodeError!AttachResult {
    return decodeAcceptedAttachForTest(bytes, runtime_id, requested, .{
        .generation_schema = .granted_with_generation,
        .metadata_support = .supported,
    });
}

test "remote attachment strictly decodes controller grant and busy demotion" {
    var controller = try decodeCurrentAttachForTest(
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        0xaa,
        .controller,
    );
    defer controller.deinit();
    try std.testing.expectEqual(Role.controller, controller.state.role);
    var observer = try decodeCurrentAttachForTest(observer_attach, 0xaa, .controller);
    defer observer.deinit();
    try std.testing.expectEqual(Role.observer, observer.state.role);
    try std.testing.expect(observer.controller_busy);
    try std.testing.expectError(
        error.Malformed,
        decodeCurrentAttachForTest(observer_attach, 0xaa, .observer),
    );
    var no_controller = try decodeCurrentAttachForTest(
        "{\"result\":{\"stream_id\":8,\"controller_generation\":0,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        0xaa,
        .observer,
    );
    defer no_controller.deinit();
    try std.testing.expectEqual(@as(u64, 0), no_controller.state.controller_generation);
}

test "remote attachment accepts exact pre-transfer same-major attach without inventing generation" {
    const legacy =
        "{\"result\":{\"stream_id\":7,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}";
    var accepted = try decodeAcceptedAttachForTest(
        legacy,
        0xaa,
        .observer,
        .{
            .generation_schema = .granted_without_generation,
            .metadata_support = .supported,
        },
    );
    defer accepted.deinit();
    try std.testing.expectEqual(Role.observer, accepted.state.role);
    try std.testing.expectEqual(@as(u64, 0), accepted.state.controller_generation);
    try std.testing.expectError(
        error.Malformed,
        decodeCurrentAttachForTest(legacy, 0xaa, .observer),
    );
}

test "remote attachment frozen v1 controller schema is isolated from current schema" {
    var accepted = try decodeAcceptedAttachForTest(
        "{\"stream_id\":9}",
        0xaa,
        .controller,
        .{
            .generation_schema = .frozen_controller_only,
            .metadata_support = .unsupported,
        },
    );
    defer accepted.deinit();
    try std.testing.expectEqual(Role.controller, accepted.state.role);
    try std.testing.expectEqual(@as(u64, 9), accepted.state.stream_id);
    try std.testing.expectError(
        error.Malformed,
        decodeAcceptedAttachForTest(
            "{\"stream_id\":9,\"granted\":{}}",
            0xaa,
            .controller,
            .{
                .generation_schema = .frozen_controller_only,
                .metadata_support = .unsupported,
            },
        ),
    );
}

test "remote attachment request builders are canonical and bounded" {
    const attach = try attachParams(std.testing.allocator, 0xaa, .observer);
    defer std.testing.allocator.free(attach);
    try std.testing.expectEqualStrings(
        "{\"runtime_id\":\"000000000000000000000000000000aa\",\"mode\":\"observer\"}",
        attach,
    );
    const status = try statusParams(std.testing.allocator, 7);
    defer std.testing.allocator.free(status);
    try std.testing.expectEqualStrings("{\"stream_id\":7}", status);
    const takeover = try takeoverParams(std.testing.allocator, 7, 3);
    defer std.testing.allocator.free(takeover);
    try std.testing.expectEqualStrings(
        "{\"stream_id\":7,\"expected_controller_generation\":3}",
        takeover,
    );
}

test "remote attachment rejects malformed or authority-inconsistent grants" {
    const invalid = [_][]const u8{
        "{\"result\":{\"stream_id\":0,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":0,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true,\"metadata_revision\":0,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":false},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true,\"extra\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null,\"extra\":1}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":\"wrong\"}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":1,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":{}}}",
    };
    for (invalid) |bytes| try std.testing.expectError(
        error.Malformed,
        decodeCurrentAttachForTest(bytes, 0xaa, .controller),
    );
}

test "remote attachment status takeover and revoke are generation fenced" {
    var accepted = try decodeCurrentAttachForTest(observer_attach, 0xaa, .controller);
    defer accepted.deinit();
    var state = accepted.state;
    const status = try decodeStatus(
        std.testing.allocator,
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"controller\":false}}",
        &state,
    );
    try std.testing.expectEqual(@as(u64, 3), status.controller_generation);
    try decodeTakeover(
        std.testing.allocator,
        "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
        &state,
        3,
    );
    try std.testing.expectEqual(Role.controller, state.role);
    try std.testing.expectEqual(@as(u64, 4), state.controller_generation);
    var attachment = RemoteAttachment.init(std.testing.allocator, state);
    try attachment.applyValidatedRevoked(5);
    try std.testing.expectEqual(@as(u64, 5), attachment.state.controller_generation);
    try std.testing.expectEqual(Role.observer, attachment.state.role);
}

test "remote attachment rejects foreign and stale status transitions without mutation" {
    var state = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 3,
    };
    try std.testing.expectError(
        error.Malformed,
        decodeStatus(
            std.testing.allocator,
            "{\"result\":{\"stream_id\":8,\"controller_generation\":3,\"controller\":false}}",
            &state,
        ),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeTakeover(
            std.testing.allocator,
            "{\"result\":{\"runtime_id\":\"000000000000000000000000000000bb\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
            &state,
            3,
        ),
    );
    try std.testing.expectEqual(Role.observer, state.role);
    try std.testing.expectEqual(@as(u64, 3), state.controller_generation);
}

test "remote attachment status advances the CAS token before takeover" {
    var state = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 3,
    };
    _ = try decodeStatus(
        std.testing.allocator,
        "{\"result\":{\"stream_id\":7,\"controller_generation\":4,\"controller\":false}}",
        &state,
    );
    try std.testing.expectEqual(@as(u64, 4), state.controller_generation);
    try decodeTakeover(
        std.testing.allocator,
        "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":5,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
        &state,
        4,
    );
    try std.testing.expectEqual(Role.controller, state.role);
    try std.testing.expectEqual(@as(u64, 5), state.controller_generation);
}

test "remote attachment preserves the full u64 controller generation domain" {
    var state = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = std.math.maxInt(i64),
    };
    _ = try decodeStatus(
        std.testing.allocator,
        "{\"result\":{\"stream_id\":7,\"controller_generation\":18446744073709551614,\"controller\":false}}",
        &state,
    );
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, state.controller_generation);
    try decodeTakeover(
        std.testing.allocator,
        "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":18446744073709551615,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
        &state,
        std.math.maxInt(u64) - 1,
    );
    try std.testing.expectEqual(std.math.maxInt(u64), state.controller_generation);
    var exhausted = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = std.math.maxInt(u64),
    };
    try std.testing.expectError(
        error.Malformed,
        decodeTakeover(
            std.testing.allocator,
            "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":18446744073709551615,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
            &exhausted,
            std.math.maxInt(u64),
        ),
    );
}

test "remote attachment rejects generation gaps for takeover and revoke" {
    var observer = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 3,
    };
    try std.testing.expectError(
        error.Malformed,
        decodeTakeover(
            std.testing.allocator,
            "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":5,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
            &observer,
            3,
        ),
    );
    const controller = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    };
    var controller_attachment = RemoteAttachment.init(std.testing.allocator, controller);
    try std.testing.expectError(
        error.InvalidAuthority,
        controller_attachment.applyValidatedRevoked(5),
    );
}

test "remote attachment authority rejects mutation after busy demotion or revoke" {
    var busy_result = try decodeCurrentAttachForTest(
        observer_attach,
        0xaa,
        .controller,
    );
    defer busy_result.deinit();
    var busy = RemoteAttachment.init(std.testing.allocator, busy_result.state);
    try std.testing.expect(!busy.allowsMutation());

    var controller_result = try decodeCurrentAttachForTest(
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        0xaa,
        .controller,
    );
    defer controller_result.deinit();
    var controller = RemoteAttachment.init(std.testing.allocator, controller_result.state);
    try std.testing.expect(controller.allowsMutation());
    try controller.applyValidatedRevoked(4);
    try std.testing.expect(!controller.allowsMutation());
}

const TestTransport = struct {
    batch: ?AttachmentBatchLease,
    fail_closed_calls: usize = 0,
    drop_calls: usize = 0,

    fn read(
        context: *anyopaque,
        _: u64,
    ) client_mod.ClientError!?AttachmentBatchLease {
        const self: *TestTransport = @ptrCast(@alignCast(context));
        const batch = self.batch;
        self.batch = null;
        return batch;
    }

    fn drop(context: *anyopaque, _: u64) void {
        const self: *TestTransport = @ptrCast(@alignCast(context));
        self.drop_calls += 1;
    }

    fn failClosed(context: *anyopaque) void {
        const self: *TestTransport = @ptrCast(@alignCast(context));
        self.fail_closed_calls += 1;
    }

    fn interface(self: *TestTransport) AttachmentTransport {
        return .{
            .context = self,
            .read_batch = read,
            .drop_stream = drop,
            .fail_closed = failClosed,
        };
    }
};

const ChargedTestTransport = struct {
    ledger: *external_inbox_ledger.ExternalInboxLedger,
    batch: ?AttachmentBatchLease,
    release_fails: bool = false,
    drop_observed_zero: bool = false,
    fail_closed_calls: usize = 0,
    drop_calls: usize = 0,
    release_calls: usize = 0,

    fn read(
        context: *anyopaque,
        _: u64,
    ) client_mod.ClientError!?AttachmentBatchLease {
        const self: *ChargedTestTransport = @ptrCast(@alignCast(context));
        const batch = self.batch;
        self.batch = null;
        return batch;
    }

    fn borrow(
        context: *anyopaque,
        token: external_inbox_ledger.Token,
    ) external_inbox_ledger.InvariantError!external_inbox_ledger.BatchView {
        const self: *ChargedTestTransport = @ptrCast(@alignCast(context));
        return self.ledger.borrowLease(token);
    }

    fn release(
        context: *anyopaque,
        token: external_inbox_ledger.Token,
    ) external_inbox_ledger.InvariantError!void {
        const self: *ChargedTestTransport = @ptrCast(@alignCast(context));
        self.release_calls += 1;
        if (self.release_fails) return error.InvariantFailure;
        return self.ledger.releaseLease(token);
    }

    fn drop(context: *anyopaque, _: u64) void {
        const self: *ChargedTestTransport = @ptrCast(@alignCast(context));
        self.drop_observed_zero =
            self.ledger.charged_bytes == 0 and self.ledger.charged_items == 0;
        self.drop_calls += 1;
    }

    fn failClosed(context: *anyopaque) void {
        const self: *ChargedTestTransport = @ptrCast(@alignCast(context));
        self.fail_closed_calls += 1;
    }

    fn interface(self: *ChargedTestTransport) AttachmentTransport {
        return .{
            .context = self,
            .read_batch = read,
            .borrow_charged = borrow,
            .release_charged = release,
            .drop_stream = drop,
            .fail_closed = failClosed,
        };
    }
};

fn reserveChargedBatch(
    ledger: *external_inbox_ledger.ExternalInboxLedger,
    allocator: std.mem.Allocator,
    is_snapshot: bool,
    stream_id: u64,
    bytes: []u8,
) !external_inbox_ledger.Token {
    var owned_bytes = bytes;
    var payload = external_inbox_ledger.OwnedPayload.takeOwned(allocator, &owned_bytes);
    errdefer payload.deinit();
    return ledger.reserveLease(.{
        .stream_id = stream_id,
        .is_snapshot = is_snapshot,
    }, &payload);
}

fn testSnapshot(allocator: std.mem.Allocator) ![]u8 {
    const screen_stream = @import("screen_stream.zig");
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1 },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&bytes, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = " ", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&bytes, allocator, row);
    return bytes.toOwnedSlice(allocator);
}

test "remote attachment fail-closes when a consumed batch has no screen owner" {
    var transport = TestTransport{
        .batch = .{ .untracked = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = try std.testing.allocator.dupe(u8, "consumed"),
            .allocator = std.testing.allocator,
        } },
    };
    var attachment = RemoteAttachment.init(std.testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(
        error.ProtocolError,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.drop_calls);
}

test "remote attachment fail-closes when consumed batch queue admission runs out of memory" {
    var transport = TestTransport{
        // Queue admission is the only allocation in this path. A zero-length payload keeps the
        // matching cleanup in the same failing allocator domain without adding setup allocation.
        .batch = .{ .untracked = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = @constCast(&[_]u8{}),
            .allocator = std.testing.allocator,
        } },
    };
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var attachment = RemoteAttachment.init(failing.allocator(), .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(
        error.OutOfMemory,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.drop_calls);
}

test "remote attachment fail-closes malformed consumed screen bytes" {
    var transport = TestTransport{
        .batch = .{ .untracked = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = try std.testing.allocator.dupe(u8, "not-a-screen-frame"),
            .allocator = std.testing.allocator,
        } },
    };
    var attachment = RemoteAttachment.init(std.testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(2);
    defer attachment.deinit();
    try std.testing.expectError(
        error.Truncated,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
}

test "remote attachment releases a charged batch after apply failure" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const token = try reserveChargedBatch(
        &ledger,
        allocator,
        true,
        7,
        try allocator.dupe(u8, "not-a-screen-frame"),
    );
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(2);
    try std.testing.expectError(error.Truncated, attachment.pumpScreen(std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_bytes);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 1), transport.drop_calls);
    try ledger.finish();
}

test "remote attachment applies and releases a charged snapshot with an empty queue" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const snapshot = try testSnapshot(allocator);
    const token = try reserveChargedBatch(&ledger, allocator, true, 7, snapshot);
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try attachment.initScreen(2);
    try std.testing.expect(try attachment.pumpScreen(std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 0), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
    attachment.deinit();
    try ledger.finish();
}

test "remote attachment reports ledger invariant when failure cleanup cannot release" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const token = try reserveChargedBatch(
        &ledger,
        allocator,
        true,
        7,
        try allocator.alloc(u8, 0),
    );
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
        .release_fails = true,
    };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var attachment = RemoteAttachment.init(failing.allocator(), .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(
        error.LedgerInvariant,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    transport.release_fails = false;
    attachment.deinit();
    try ledger.finish();
}

test "remote attachment rejects a charged batch demuxed to a sibling stream" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const token = try reserveChargedBatch(
        &ledger,
        allocator,
        true,
        8,
        try allocator.alloc(u8, 0),
    );
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(
        error.LedgerInvariant,
        attachment.pumpScreen(std.testing.io),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), attachment.pending_batches.items.len);
    attachment.deinit();
    try ledger.finish();
}

test "remote attachment charged queue admission OOM releases through stable ledger" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const token = try reserveChargedBatch(
        &ledger,
        allocator,
        true,
        7,
        try allocator.alloc(u8, 0),
    );
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
    };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var attachment = RemoteAttachment.init(failing.allocator(), .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(error.OutOfMemory, attachment.pumpScreen(std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    attachment.deinit();
    try ledger.finish();
}

test "remote attachment stale charged lease latches invariant without double release" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    const token = try reserveChargedBatch(
        &ledger,
        allocator,
        true,
        7,
        try allocator.alloc(u8, 0),
    );
    try ledger.releaseLease(token);
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = .{ .charged = token },
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    try std.testing.expectError(error.LedgerInvariant, attachment.pumpScreen(std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), transport.fail_closed_calls);
    try std.testing.expectEqual(@as(usize, 0), ledger.charged_items);
    attachment.deinit();
    try std.testing.expectError(error.InvariantFailure, ledger.finish());
}

test "remote attachment deinit releases every queued charged lease before dropping stream" {
    const allocator = std.testing.allocator;
    var ledger: external_inbox_ledger.ExternalInboxLedger = .{};
    var transport = ChargedTestTransport{
        .ledger = &ledger,
        .batch = null,
    };
    var attachment = RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 0,
    });
    try attachment.bindTransport(transport.interface());
    for (0..3) |i| {
        const bytes = try std.fmt.allocPrint(allocator, "batch-{d}", .{i});
        const token = try reserveChargedBatch(&ledger, allocator, i == 0, 7, bytes);
        try attachment.pending_batches.append(allocator, .{ .charged = token });
    }
    attachment.deinit();
    try std.testing.expectEqual(@as(usize, 3), transport.release_calls);
    try std.testing.expectEqual(@as(usize, 1), transport.drop_calls);
    try std.testing.expect(transport.drop_observed_zero);
    try std.testing.expectEqual(@as(usize, 0), transport.fail_closed_calls);
    try ledger.finish();
}
