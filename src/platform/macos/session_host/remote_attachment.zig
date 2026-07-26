//! GUI `RemoteRuntime`과 public attach가 공유할 stream role/authority wire boundary.
//! Connection transport와 GUI Surface를 소유하지 않으며 strict host result/event를 attachment-local state로 접는다.

const std = @import("std");
const client_mod = @import("client.zig");
const remote_screen = @import("remote_screen.zig");
const screen_assembler = @import("screen_assembler.zig");

pub const AttachmentTransport = struct {
    context: *anyopaque,
    read_batch: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        stream_id: u64,
    ) client_mod.ClientError!?client_mod.StreamBatch,
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
    pending_batches: std.ArrayListUnmanaged(client_mod.StreamBatch) = .empty,

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
        if (self.transport) |transport| transport.drop_stream(transport.context, self.state.stream_id);
        for (self.pending_batches.items) |batch| self.allocator.free(batch.bytes);
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
    ) (client_mod.ClientError || screen_assembler.ApplyError)!bool {
        const transport = self.transport orelse return error.ConnectionClosed;
        if (try transport.read_batch(transport.context, self.allocator, self.state.stream_id)) |batch| {
            self.pending_batches.append(self.allocator, batch) catch {
                self.allocator.free(batch.bytes);
                transport.fail_closed(transport.context);
                return error.OutOfMemory;
            };
        }
        if (self.pending_batches.items.len == 0) return false;
        const batch = self.pending_batches.orderedRemove(0);
        defer self.allocator.free(batch.bytes);
        const screen = &(self.screen orelse {
            transport.fail_closed(transport.context);
            return error.ProtocolError;
        });
        if (batch.is_snapshot)
            screen.applySnapshot(batch.bytes, io) catch |err| {
                transport.fail_closed(transport.context);
                return err;
            }
        else
            screen.applyDelta(batch.bytes, io) catch |err| {
                transport.fail_closed(transport.context);
                return err;
            };
        return true;
    }

    pub fn applyRevoked(
        self: *RemoteAttachment,
        bytes: []const u8,
    ) DecodeError!Revoked {
        return decodeRevoked(self.allocator, bytes, &self.state);
    }
};

pub const AttachResult = struct {
    state: State,
    controller_busy: bool,
};

pub const Status = struct {
    stream_id: u64,
    controller_generation: u64,
    controller: bool,
};

pub const Revoked = struct {
    runtime_id: u128,
    stream_id: u64,
    controller_generation: u64,
};

pub const DecodeError = error{ OutOfMemory, Malformed };

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

pub fn decodeAttach(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    runtime_id: u128,
    requested: Mode,
) DecodeError!AttachResult {
    return decodeAttachForCapabilities(allocator, bytes, runtime_id, requested, true);
}

pub fn decodeAttachForCapabilities(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    runtime_id: u128,
    requested: Mode,
    peer_attach_generation: bool,
) DecodeError!AttachResult {
    var parsed = try parseObject(allocator, bytes);
    defer parsed.deinit();
    const root = parsed.value.object;
    if (root.count() != 1) return error.Malformed;
    const result = objectField(root, "result") orelse return error.Malformed;
    const expected_fields: usize = if (peer_attach_generation) 6 else 5;
    if (result.count() != expected_fields) return error.Malformed;
    const stream_id = u64Field(result, "stream_id") orelse return error.Malformed;
    const generation = if (peer_attach_generation)
        u64Field(result, "controller_generation") orelse return error.Malformed
    else
        0;
    const busy = boolField(result, "controller_busy") orelse return error.Malformed;
    const metadata_revision = u64Field(result, "metadata_revision") orelse
        return error.Malformed;
    const metadata = result.get("metadata") orelse return error.Malformed;
    switch (metadata) {
        .null => if (metadata_revision != 0) return error.Malformed,
        .object => if (metadata_revision == 0) return error.Malformed,
        else => return error.Malformed,
    }
    if (stream_id == 0) return error.Malformed;
    const granted = objectField(result, "granted") orelse return error.Malformed;
    if (granted.count() != 3 or boolField(granted, "observe") != true)
        return error.Malformed;
    const input = boolField(granted, "input") orelse return error.Malformed;
    const resize = boolField(granted, "resize") orelse return error.Malformed;
    if (input != resize) return error.Malformed;
    const role: Role = if (input) .controller else .observer;
    // Generation zero is valid only for a pure observer on a runtime that has never had a
    // controller. Controller acquisition and busy demotion both prove a controller transition.
    if (peer_attach_generation and generation == 0 and (role == .controller or busy))
        return error.Malformed;
    switch (requested) {
        .observer => if (role != .observer or busy) return error.Malformed,
        .controller => switch (role) {
            .controller => if (busy) return error.Malformed,
            .observer => if (!busy) return error.Malformed,
        },
    }
    return .{
        .state = .{
            .runtime_id = runtime_id,
            .stream_id = stream_id,
            .role = role,
            .controller_generation = generation,
        },
        .controller_busy = busy,
    };
}

/// Frozen MRSH v1 adapter의 attach body는 result/granted 없이 exact `{"stream_id":N}`이다. v1은 controller-only
/// profile이고 compatibility fingerprint로 body 의미를 이미 pin했을 때만 caller가 이 decoder를 선택한다.
pub fn decodeFrozenV1ControllerAttach(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    runtime_id: u128,
) DecodeError!AttachResult {
    var parsed = try parseObject(allocator, bytes);
    defer parsed.deinit();
    const root = parsed.value.object;
    if (root.count() != 1) return error.Malformed;
    const stream_id = u64Field(root, "stream_id") orelse return error.Malformed;
    if (stream_id == 0) return error.Malformed;
    return .{
        .state = .{
            .runtime_id = runtime_id,
            .stream_id = stream_id,
            .role = .controller,
            .controller_generation = 0,
        },
        .controller_busy = false,
    };
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

pub fn decodeRevoked(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    state: *State,
) DecodeError!Revoked {
    if (state.role != .controller) return error.Malformed;
    var parsed = try parseObject(allocator, bytes);
    defer parsed.deinit();
    const root = parsed.value.object;
    if (root.count() != 2) return error.Malformed;
    const event = stringField(root, "event") orelse return error.Malformed;
    if (!std.mem.eql(u8, event, "controller.revoked")) return error.Malformed;
    const data = objectField(root, "data") orelse return error.Malformed;
    if (data.count() != 4) return error.Malformed;
    const runtime_id = runtimeIdField(data, "runtime_id") orelse return error.Malformed;
    const stream_id = u64Field(data, "stream_id") orelse return error.Malformed;
    const generation = u64Field(data, "controller_generation") orelse return error.Malformed;
    const reason = stringField(data, "reason") orelse return error.Malformed;
    const successor = std.math.add(u64, state.controller_generation, 1) catch
        return error.Malformed;
    if (runtime_id != state.runtime_id or stream_id != state.stream_id or
        generation != successor or !std.mem.eql(u8, reason, "takeover"))
        return error.Malformed;
    state.role = .observer;
    state.controller_generation = generation;
    return .{
        .runtime_id = runtime_id,
        .stream_id = stream_id,
        .controller_generation = generation,
    };
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

test "remote attachment strictly decodes controller grant and busy demotion" {
    const controller = try decodeAttach(
        std.testing.allocator,
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        0xaa,
        .controller,
    );
    try std.testing.expectEqual(Role.controller, controller.state.role);
    const observer = try decodeAttach(std.testing.allocator, observer_attach, 0xaa, .controller);
    try std.testing.expectEqual(Role.observer, observer.state.role);
    try std.testing.expect(observer.controller_busy);
    try std.testing.expectError(
        error.Malformed,
        decodeAttach(std.testing.allocator, observer_attach, 0xaa, .observer),
    );
    const no_controller = try decodeAttach(
        std.testing.allocator,
        "{\"result\":{\"stream_id\":8,\"controller_generation\":0,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        0xaa,
        .observer,
    );
    try std.testing.expectEqual(@as(u64, 0), no_controller.state.controller_generation);
}

test "remote attachment accepts exact pre-transfer same-major attach without inventing generation" {
    const legacy =
        "{\"result\":{\"stream_id\":7,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}";
    const accepted = try decodeAttachForCapabilities(
        std.testing.allocator,
        legacy,
        0xaa,
        .observer,
        false,
    );
    try std.testing.expectEqual(Role.observer, accepted.state.role);
    try std.testing.expectEqual(@as(u64, 0), accepted.state.controller_generation);
    try std.testing.expectError(
        error.Malformed,
        decodeAttach(std.testing.allocator, legacy, 0xaa, .observer),
    );
}

test "remote attachment frozen v1 controller schema is isolated from current schema" {
    const accepted = try decodeFrozenV1ControllerAttach(
        std.testing.allocator,
        "{\"stream_id\":9}",
        0xaa,
    );
    try std.testing.expectEqual(Role.controller, accepted.state.role);
    try std.testing.expectEqual(@as(u64, 9), accepted.state.stream_id);
    try std.testing.expectError(
        error.Malformed,
        decodeFrozenV1ControllerAttach(
            std.testing.allocator,
            "{\"stream_id\":9,\"granted\":{}}",
            0xaa,
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
        decodeAttach(std.testing.allocator, bytes, 0xaa, .controller),
    );
}

test "remote attachment status takeover and revoke are generation fenced" {
    var state = (try decodeAttach(std.testing.allocator, observer_attach, 0xaa, .controller)).state;
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
    const revoked = try decodeRevoked(
        std.testing.allocator,
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":5,\"reason\":\"takeover\"}}",
        &state,
    );
    try std.testing.expectEqual(@as(u64, 5), revoked.controller_generation);
    try std.testing.expectEqual(Role.observer, state.role);
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
    var controller = State{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 3,
    };
    try std.testing.expectError(
        error.Malformed,
        decodeRevoked(
            std.testing.allocator,
            "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":5,\"reason\":\"takeover\"}}",
            &controller,
        ),
    );
}

test "remote attachment authority rejects mutation after busy demotion or revoke" {
    var busy = RemoteAttachment.init(std.testing.allocator, (try decodeAttach(
        std.testing.allocator,
        observer_attach,
        0xaa,
        .controller,
    )).state);
    try std.testing.expect(!busy.allowsMutation());

    var controller = RemoteAttachment.init(std.testing.allocator, (try decodeAttach(
        std.testing.allocator,
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
        0xaa,
        .controller,
    )).state);
    try std.testing.expect(controller.allowsMutation());
    _ = try controller.applyRevoked(
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
    );
    try std.testing.expect(!controller.allowsMutation());
}

const TestTransport = struct {
    batch: ?client_mod.StreamBatch,
    fail_closed_calls: usize = 0,
    drop_calls: usize = 0,

    fn read(
        context: *anyopaque,
        _: std.mem.Allocator,
        _: u64,
    ) client_mod.ClientError!?client_mod.StreamBatch {
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

test "remote attachment fail-closes when a consumed batch has no screen owner" {
    var transport = TestTransport{
        .batch = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = try std.testing.allocator.dupe(u8, "consumed"),
        },
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
        .batch = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = @constCast(&[_]u8{}),
        },
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
        .batch = .{
            .is_snapshot = true,
            .stream_id = 7,
            .bytes = try std.testing.allocator.dupe(u8, "not-a-screen-frame"),
        },
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
