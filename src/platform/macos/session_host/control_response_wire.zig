//! Dependency-neutral strict wire contract for runtime resize/resync controls.
//!
//! Request encoding and response decoding live together so blocking and external clients cannot
//! silently acquire different JSON vocabularies. Recovery control authority is local-only;
//! they are deliberately never serialized.

const std = @import("std");
const recovery = @import("external_recovery_types.zig");
const host_protocol = @import("maru").session.host_protocol;

pub const ResizeRequest = struct {
    stream_id: u64,
    cols: u16,
    rows: u16,
    client_sequence: u64,
};

pub const ResyncRequest = struct {
    stream_id: u64,
    recovery_authority: recovery.ControlAuthority,
};

pub const DetachRequest = struct { stream_id: u64 };

/// observer 가 **자기가 그릴 수 있는 격자** 를 알린다(S11-6). 리사이즈를 «부르는» 것이 아니다 —
/// 무엇을 할지는 host 가 정한다. 그래서 `lifecycle` 도, controller 자격도 필요하지 않다.
///
/// 둘 다 0 이면 **선언을 거둔다**(붙어 있되 크기에 영향을 안 준다). 한쪽만 0 인 것은 뜻이 없어
/// 정규형이 아니다 — client 쪽 프레임 디코더가 이미 버리므로 여기까지 오지 않는다.
pub const DeclareViewportRequest = struct {
    stream_id: u64,
    cols: u16,
    rows: u16,
};

pub const WireRequest = union(enum) {
    resize: ResizeRequest,
    resync: struct { stream_id: u64 },
    detach: DetachRequest,
    declare_viewport: DeclareViewportRequest,

    pub fn isCanonical(self: WireRequest) bool {
        return switch (self) {
            .resize => |value| value.stream_id != 0 and value.cols >= 2 and
                value.rows >= 1 and value.client_sequence != 0,
            .resync => |value| value.stream_id != 0,
            .detach => |value| value.stream_id != 0,
            .declare_viewport => |value| value.stream_id != 0 and
                (value.cols == 0) == (value.rows == 0),
        };
    }
};

pub const ControlRequest = union(enum) {
    resize: ResizeRequest,
    resync: ResyncRequest,
    detach: DetachRequest,
    declare_viewport: DeclareViewportRequest,

    pub fn isCanonical(self: ControlRequest) bool {
        return switch (self) {
            .resize => |value| value.stream_id != 0 and value.cols >= 2 and
                value.rows >= 1 and value.client_sequence != 0,
            .resync => |value| value.stream_id != 0 and value.recovery_authority.isCanonical(),
            .detach => |value| value.stream_id != 0,
            .declare_viewport => |value| value.stream_id != 0 and
                (value.cols == 0) == (value.rows == 0),
        };
    }
};

pub const ControlExpectation = union(enum) {
    resize: struct { client_sequence: u64 },
    resync: recovery.ControlAuthority,
    detach,
    declare_viewport,

    pub fn isCanonical(self: ControlExpectation) bool {
        return switch (self) {
            .resize => |value| value.client_sequence != 0,
            .resync => |key| key.isCanonical(),
            .detach => true,
            .declare_viewport => true,
        };
    }
};

pub fn expectationDigest(expectation: ControlExpectation) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("MARUCEX1");
    hasher.update(&.{@intFromEnum(std.meta.activeTag(expectation))});
    var word: [8]u8 = undefined;
    switch (expectation) {
        .resize => |value| {
            std.mem.writeInt(u64, &word, value.client_sequence, .little);
            hasher.update(&word);
        },
        .resync => |authority| {
            inline for (.{ authority.owner_incarnation, authority.recovery_epoch }) |value| {
                std.mem.writeInt(u64, &word, value, .little);
                hasher.update(&word);
            }
            hasher.update(&.{@intFromEnum(authority.origin)});
        },
        .detach => {},
        .declare_viewport => {},
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

pub const EncodedRequest = struct {
    payload: []const u8,
    expectation: ControlExpectation,
};
pub const EncodedParams = struct {
    method: []const u8,
    params: []const u8,
};

pub const EncodeError = error{ InvalidRequest, BufferTooSmall };

pub fn encodeParams(buffer: []u8, request: WireRequest) EncodeError!EncodedParams {
    if (!request.isCanonical()) return error.InvalidRequest;
    return switch (request) {
        .resize => |value| .{
            .method = "runtime.resize",
            .params = std.fmt.bufPrint(
                buffer,
                "{{\"stream_id\":{d},\"cols\":{d},\"rows\":{d},\"client_sequence\":{d}}}",
                .{ value.stream_id, value.cols, value.rows, value.client_sequence },
            ) catch return error.BufferTooSmall,
        },
        .resync => |value| .{
            .method = "runtime.resync",
            .params = std.fmt.bufPrint(
                buffer,
                "{{\"stream_id\":{d}}}",
                .{value.stream_id},
            ) catch return error.BufferTooSmall,
        },
        .detach => |value| .{
            .method = "runtime.detach",
            .params = std.fmt.bufPrint(
                buffer,
                "{{\"stream_id\":{d}}}",
                .{value.stream_id},
            ) catch return error.BufferTooSmall,
        },
        .declare_viewport => |value| .{
            .method = "runtime.declare_viewport",
            .params = std.fmt.bufPrint(
                buffer,
                "{{\"stream_id\":{d},\"cols\":{d},\"rows\":{d}}}",
                .{ value.stream_id, value.cols, value.rows },
            ) catch return error.BufferTooSmall,
        },
    };
}

pub fn encodeRequest(buffer: []u8, request: ControlRequest) EncodeError!EncodedRequest {
    if (!request.isCanonical()) return error.InvalidRequest;
    const wire: WireRequest = switch (request) {
        .resize => |value| .{ .resize = value },
        .resync => |value| .{ .resync = .{ .stream_id = value.stream_id } },
        .detach => |value| .{ .detach = value },
        .declare_viewport => |value| .{ .declare_viewport = value },
    };
    const expectation: ControlExpectation = switch (request) {
        .resize => |value| .{ .resize = .{ .client_sequence = value.client_sequence } },
        .resync => |value| .{ .resync = value.recovery_authority },
        .detach => .detach,
        .declare_viewport => .declare_viewport,
    };
    const prefix = switch (wire) {
        .resize => "{\"method\":\"runtime.resize\",\"params\":",
        .resync => "{\"method\":\"runtime.resync\",\"params\":",
        .detach => "{\"method\":\"runtime.detach\",\"params\":",
        .declare_viewport => "{\"method\":\"runtime.declare_viewport\",\"params\":",
    };
    if (buffer.len <= prefix.len) return error.BufferTooSmall;
    @memcpy(buffer[0..prefix.len], prefix);
    const encoded = try encodeParams(buffer[prefix.len .. buffer.len - 1], wire);
    const end = prefix.len + encoded.params.len;
    buffer[end] = '}';
    return .{
        .payload = buffer[0 .. end + 1],
        .expectation = expectation,
    };
}

pub const ResizeReply = union(enum) {
    stale,
    applied: struct {
        cols: u16,
        rows: u16,
        resize_generation: u64,
        changed: bool,
    },
};

pub const ResponseError = error{
    OutOfMemory,
    Malformed,
    RuntimeNotFound,
    ResourceExhausted,
    Rejected,
};

fn parseRoot(allocator: std.mem.Allocator, payload: []const u8) ResponseError!std.json.Parsed(std.json.Value) {
    if (payload.len > host_protocol.max_control_json) return error.Malformed;
    return std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Malformed,
    };
}

fn rejectErrorEnvelope(root: std.json.ObjectMap) ResponseError!void {
    const error_value = root.get("error") orelse return;
    if (root.count() != 1) return error.Malformed;
    const wire_error = switch (error_value) {
        .string => |value| value,
        else => return error.Malformed,
    };
    const code = host_protocol.ErrorCode.fromWireName(wire_error) orelse
        return error.Malformed;
    return switch (code) {
        .runtime_not_found => error.RuntimeNotFound,
        .resource_exhausted => error.ResourceExhausted,
        else => error.Rejected,
    };
}

pub fn decodeResizeResponse(
    allocator: std.mem.Allocator,
    payload: []const u8,
    expectation: ControlExpectation,
) ResponseError!ResizeReply {
    const expected_sequence = switch (expectation) {
        .resize => |value| value.client_sequence,
        .resync, .detach, .declare_viewport => return error.Malformed,
    };
    if (expected_sequence == 0) return error.Malformed;
    var parsed = try parseRoot(allocator, payload);
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.Malformed,
    };
    try rejectErrorEnvelope(root);
    if (root.count() != 1) return error.Malformed;
    const result = switch (root.get("result") orelse return error.Malformed) {
        .object => |object| object,
        else => return error.Malformed,
    };
    if (result.get("stale")) |stale_value| {
        if (result.count() != 1 or stale_value != .bool or !stale_value.bool)
            return error.Malformed;
        return .stale;
    }
    if (result.count() != 5) return error.Malformed;
    const cols = unsigned(u16, result.get("cols") orelse return error.Malformed) orelse
        return error.Malformed;
    const rows = unsigned(u16, result.get("rows") orelse return error.Malformed) orelse
        return error.Malformed;
    const sequence = unsigned(u64, result.get("client_sequence") orelse return error.Malformed) orelse
        return error.Malformed;
    const generation = unsigned(u64, result.get("resize_generation") orelse return error.Malformed) orelse
        return error.Malformed;
    const changed = switch (result.get("changed") orelse return error.Malformed) {
        .bool => |value| value,
        else => return error.Malformed,
    };
    if (sequence != expected_sequence) return error.Malformed;
    if (cols < 2 or rows < 1) return error.Malformed;
    return .{ .applied = .{
        .cols = cols,
        .rows = rows,
        .resize_generation = generation,
        .changed = changed,
    } };
}

pub fn decodeResyncEnvelope(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ResponseError!void {
    var parsed = try parseRoot(allocator, payload);
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.Malformed,
    };
    try rejectErrorEnvelope(root);
    if (root.count() != 1) return error.Malformed;
    const result = switch (root.get("result") orelse return error.Malformed) {
        .object => |object| object,
        else => return error.Malformed,
    };
    if (result.count() != 1) return error.Malformed;
    const value = result.get("resync") orelse return error.Malformed;
    if (value != .bool or !value.bool) return error.Malformed;
}

/// host 가 그 선언을 어떻게 다뤘는가. **버림과 무변화를 가른다** — 「한쪽만 0 이라 버렸다」를
/// 「같은 값이라 아무것도 안 했다」로 접으면 client 는 자기 선언이 통했는지 모른다.
pub const DeclareViewportOutcome = enum {
    declared,
    withdrawn,
    unchanged,
    invalid,

    pub fn wireName(self: DeclareViewportOutcome) []const u8 {
        return switch (self) {
            .declared => "declared",
            .withdrawn => "withdrawn",
            .unchanged => "unchanged",
            .invalid => "invalid",
        };
    }

    pub fn fromWireName(text: []const u8) ?DeclareViewportOutcome {
        inline for (std.enums.values(DeclareViewportOutcome)) |value|
            if (std.mem.eql(u8, text, value.wireName())) return value;
        return null;
    }
};

pub fn decodeDeclareViewportResponse(
    allocator: std.mem.Allocator,
    payload: []const u8,
    expectation: ControlExpectation,
) ResponseError!DeclareViewportOutcome {
    switch (expectation) {
        .resize, .detach, .resync => return error.Malformed,
        .declare_viewport => {},
    }
    var parsed = try parseRoot(allocator, payload);
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.Malformed,
    };
    try rejectErrorEnvelope(root);
    if (root.count() != 1) return error.Malformed;
    const result = switch (root.get("result") orelse return error.Malformed) {
        .object => |object| object,
        else => return error.Malformed,
    };
    if (result.count() != 1) return error.Malformed;
    const value = result.get("declared") orelse return error.Malformed;
    if (value != .string) return error.Malformed;
    return DeclareViewportOutcome.fromWireName(value.string) orelse error.Malformed;
}

pub fn decodeResyncResponse(
    allocator: std.mem.Allocator,
    payload: []const u8,
    expectation: ControlExpectation,
) ResponseError!void {
    switch (expectation) {
        .resize, .detach, .declare_viewport => return error.Malformed,
        .resync => |authority| if (!authority.isCanonical()) return error.Malformed,
    }
    return decodeResyncEnvelope(allocator, payload);
}

fn unsigned(comptime T: type, value: std.json.Value) ?T {
    return switch (value) {
        .integer => |number| if (number < 0) null else std.math.cast(T, number),
        .number_string => |number| std.fmt.parseInt(T, number, 10) catch null,
        else => null,
    };
}

const canonical_authority = recovery.ControlAuthority{
    .owner_incarnation = 3,
    .origin = .client,
    .recovery_epoch = 5,
};

test "f3c0 control wire encodes typed requests and keeps recovery authority local" {
    var buffer: [160]u8 = undefined;
    const resize = try encodeRequest(&buffer, .{ .resize = .{
        .stream_id = 7,
        .cols = 80,
        .rows = 24,
        .client_sequence = 11,
    } });
    try std.testing.expectEqualStrings(
        "{\"method\":\"runtime.resize\",\"params\":{\"stream_id\":7,\"cols\":80,\"rows\":24,\"client_sequence\":11}}",
        resize.payload,
    );
    try std.testing.expectEqual(@as(u64, 11), resize.expectation.resize.client_sequence);
    const resize_digest = expectationDigest(resize.expectation);
    const changed_digest = expectationDigest(.{ .resize = .{ .client_sequence = 12 } });
    try std.testing.expect(!std.mem.eql(u8, &resize_digest, &changed_digest));

    const resync = try encodeRequest(&buffer, .{ .resync = .{
        .stream_id = 7,
        .recovery_authority = canonical_authority,
    } });
    try std.testing.expectEqualStrings(
        "{\"method\":\"runtime.resync\",\"params\":{\"stream_id\":7}}",
        resync.payload,
    );
    try std.testing.expect(std.meta.eql(canonical_authority, resync.expectation.resync));
    try std.testing.expect(std.mem.indexOf(u8, resync.payload, "recovery") == null);

    var params_buffer: [128]u8 = undefined;
    const resize_params = try encodeParams(&params_buffer, .{ .resize = .{
        .stream_id = 7,
        .cols = 80,
        .rows = 24,
        .client_sequence = 11,
    } });
    try std.testing.expectEqualStrings("runtime.resize", resize_params.method);
    try std.testing.expectEqualStrings(
        "{\"stream_id\":7,\"cols\":80,\"rows\":24,\"client_sequence\":11}",
        resize_params.params,
    );
}

fn expectExactRequestBoundary(request: ControlRequest) !void {
    var large: [192]u8 = undefined;
    const expected = (try encodeRequest(&large, request)).payload.len;
    var exact: [192]u8 = undefined;
    _ = try encodeRequest(exact[0..expected], request);
    try std.testing.expectError(
        error.BufferTooSmall,
        encodeRequest(exact[0 .. expected - 1], request),
    );
}

fn expectExactParamsBoundary(request: WireRequest) !void {
    var large: [128]u8 = undefined;
    const expected = (try encodeParams(&large, request)).params.len;
    var exact: [128]u8 = undefined;
    _ = try encodeParams(exact[0..expected], request);
    try std.testing.expectError(
        error.BufferTooSmall,
        encodeParams(exact[0 .. expected - 1], request),
    );
}

test "f3c0 control wire request encoding is exact-bound and rejects noncanonical input" {
    const resize: ControlRequest = .{ .resize = .{
        .stream_id = 7,
        .cols = 80,
        .rows = 24,
        .client_sequence = 11,
    } };
    const resync: ControlRequest = .{ .resync = .{
        .stream_id = 7,
        .recovery_authority = canonical_authority,
    } };
    try expectExactRequestBoundary(resize);
    try expectExactRequestBoundary(resync);
    try expectExactParamsBoundary(.{ .resize = resize.resize });
    try expectExactParamsBoundary(.{ .resync = .{ .stream_id = 7 } });

    var large: [192]u8 = undefined;
    try std.testing.expectError(error.InvalidRequest, encodeRequest(&large, .{ .resize = .{
        .stream_id = 0,
        .cols = 1,
        .rows = 0,
        .client_sequence = 0,
    } }));
    try std.testing.expectError(error.InvalidRequest, encodeRequest(&large, .{ .resync = .{
        .stream_id = 7,
        .recovery_authority = .{
            .owner_incarnation = 0,
            .origin = .client,
            .recovery_epoch = 1,
        },
    } }));
}

test "f3c0 control wire strictly decodes resize and resync responses" {
    const expectation: ControlExpectation = .{ .resize = .{ .client_sequence = 11 } };
    try std.testing.expectEqual(ResizeReply.stale, try decodeResizeResponse(
        std.testing.allocator,
        "{\"result\":{\"stale\":true}}",
        expectation,
    ));
    const applied = (try decodeResizeResponse(
        std.testing.allocator,
        "{\"result\":{\"cols\":80,\"rows\":24,\"client_sequence\":11,\"resize_generation\":9,\"changed\":true}}",
        expectation,
    )).applied;
    try std.testing.expectEqual(@as(u16, 80), applied.cols);
    try std.testing.expectEqual(@as(u64, 9), applied.resize_generation);
    const maximum = (try decodeResizeResponse(
        std.testing.allocator,
        "{\"result\":{\"cols\":80,\"rows\":24,\"client_sequence\":18446744073709551615,\"resize_generation\":18446744073709551615,\"changed\":false}}",
        .{ .resize = .{ .client_sequence = std.math.maxInt(u64) } },
    )).applied;
    try std.testing.expectEqual(std.math.maxInt(u64), maximum.resize_generation);
    try std.testing.expectError(error.Malformed, decodeResizeResponse(
        std.testing.allocator,
        "{\"result\":{\"stale\":true,\"foreign\":1}}",
        expectation,
    ));
    try std.testing.expectError(error.Malformed, decodeResizeResponse(
        std.testing.allocator,
        "{\"result\":{\"stale\":true},\"result\":{\"stale\":true}}",
        expectation,
    ));
    try std.testing.expectError(error.Malformed, decodeResizeResponse(
        std.testing.allocator,
        "{\"result\":{\"stale\":true}} trailing",
        expectation,
    ));
    try std.testing.expectError(error.ResourceExhausted, decodeResizeResponse(
        std.testing.allocator,
        "{\"error\":\"resource_exhausted\"}",
        expectation,
    ));
    try decodeResyncResponse(
        std.testing.allocator,
        "{\"result\":{\"resync\":true}}",
        .{ .resync = canonical_authority },
    );
    try std.testing.expectError(error.Malformed, decodeResyncResponse(
        std.testing.allocator,
        "{\"result\":{\"resync\":false}}",
        .{ .resync = canonical_authority },
    ));
    try std.testing.expectError(error.Malformed, decodeResyncResponse(
        std.testing.allocator,
        "{\"result\":{\"resync\":true,\"foreign\":false}}",
        .{ .resync = canonical_authority },
    ));
    try std.testing.expectError(error.Malformed, decodeResyncResponse(
        std.testing.allocator,
        "{\"result\":{\"resync\":true}}",
        expectation,
    ));
    try std.testing.expectError(error.Malformed, decodeResizeResponse(
        std.testing.allocator,
        "{\"error\":\"future_error\"}",
        expectation,
    ));
    var oversized: [host_protocol.max_control_json + 1]u8 = undefined;
    @memset(&oversized, ' ');
    try std.testing.expectError(error.Malformed, decodeResizeResponse(
        std.testing.allocator,
        &oversized,
        expectation,
    ));
}

fn checkResizeResponseAllocationFailure(allocator: std.mem.Allocator) !void {
    _ = decodeResizeResponse(
        allocator,
        "{\"result\":{\"stale\":true}}",
        .{ .resize = .{ .client_sequence = 1 } },
    ) catch |err| return err;
}

fn checkAppliedResponseAllocationFailure(allocator: std.mem.Allocator) !void {
    _ = decodeResizeResponse(
        allocator,
        "{\"result\":{\"cols\":80,\"rows\":24,\"client_sequence\":1,\"resize_generation\":9,\"changed\":true}}",
        .{ .resize = .{ .client_sequence = 1 } },
    ) catch |err| return err;
}

fn checkResyncResponseAllocationFailure(allocator: std.mem.Allocator) !void {
    decodeResyncEnvelope(
        allocator,
        "{\"result\":{\"resync\":true}}",
    ) catch |err| return err;
}

test "f3c0 control wire response decoder survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResizeResponseAllocationFailure,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAppliedResponseAllocationFailure,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResyncResponseAllocationFailure,
        .{},
    );
}
