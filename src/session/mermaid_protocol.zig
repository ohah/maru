//! Mermaid helper wire protocol의 단일 codec.
//!
//! parent와 helper는 이 모듈이 encode/decode한 opaque frame만 운반한다. 두 Swift 프로세스에
//! wire enum이나 byte layout을 다시 쓰지 않아야 endian, cap, closed enum 판단이 한 곳에 남는다.

const std = @import("std");

pub const magic = "MRU1".*;
pub const version: u16 = 1;
pub const max_source_bytes: usize = 32 * 1024;
pub const max_svg_bytes: usize = 512 * 1024;
pub const max_request_frame_bytes: usize = 40 * 1024;
pub const max_result_frame_bytes: usize = 513 * 1024;
pub const max_retained_bytes: usize = max_result_frame_bytes + 4;

const prefix_len = 4;
const common_len = magic.len + @sizeOf(u16) + @sizeOf(u8);
const identity_len = 8 * @sizeOf(u64) + 32;

pub const Tag = enum(u8) {
    hello = 0,
    hello_ack = 1,
    request = 2,
    result = 3,
};

pub const ResultStatus = enum(u8) {
    ok = 0,
    render_error = 1,
};

pub const RendererCapability = struct {
    document_revision: u64,
    projection_generation: u64,
    widget_id: u64,
    widget_generation: u64,
    renderer_instance: u64,
};

pub const JobCapability = struct {
    helper_instance: u64,
    job_id: u64,
    renderer: RendererCapability,
    fence_id: u64,
    source_hash: [32]u8,
};

pub const Hello = struct {
    helper_instance: u64,
    nonce: u64,
};

pub const Request = struct {
    capability: JobCapability,
    source: []const u8,
};

pub const Result = struct {
    capability: JobCapability,
    status: ResultStatus,
    body: []const u8,
};

pub const Message = union(Tag) {
    hello: Hello,
    hello_ack: Hello,
    request: Request,
    result: Result,
};

pub const Error = error{
    OutputTooSmall,
    FrameTooLarge,
    SourceTooLarge,
    SvgTooLarge,
    InvalidUtf8,
    InvalidMagic,
    UnsupportedVersion,
    UnknownTag,
    UnknownStatus,
    InvalidLength,
    InvalidRenderErrorBody,
    TrailingBytes,
    RetainedInputOverflow,
    IncompleteFrame,
};

/// Caller-owned output에 frame을 만든다. 성공 반환값만큼만 pipe에 써야 한다.
pub fn encode(message: Message, out: []u8) Error!usize {
    var cursor = Cursor.init(out);
    try cursor.skip(prefix_len);
    try cursor.writeBytes(&magic);
    try cursor.writeU16(version);
    try cursor.writeByte(@intFromEnum(message));

    switch (message) {
        .hello => |value| try writeHello(&cursor, value),
        .hello_ack => |value| try writeHello(&cursor, value),
        .request => |value| {
            if (value.source.len > max_source_bytes) return error.SourceTooLarge;
            if (!std.unicode.utf8ValidateSlice(value.source)) return error.InvalidUtf8;
            if (!std.mem.eql(u8, &value.capability.source_hash, &sourceHash(value.source))) return error.InvalidLength;
            try writeCapability(&cursor, value.capability);
            try cursor.writeU32(@intCast(value.source.len));
            try cursor.writeBytes(value.source);
        },
        .result => |value| {
            if (value.status == .render_error and value.body.len != 0) return error.InvalidRenderErrorBody;
            if (value.status == .ok and value.body.len > max_svg_bytes) return error.SvgTooLarge;
            if (!std.unicode.utf8ValidateSlice(value.body)) return error.InvalidUtf8;
            try writeCapability(&cursor, value.capability);
            try cursor.writeByte(@intFromEnum(value.status));
            try cursor.writeU32(@intCast(value.body.len));
            try cursor.writeBytes(value.body);
        },
    }

    const frame_len = cursor.pos;
    const frame_cap = switch (message) {
        .result => max_result_frame_bytes,
        else => max_request_frame_bytes,
    };
    if (frame_len > frame_cap) return error.FrameTooLarge;
    writeU32At(out[0..prefix_len], @intCast(frame_len - prefix_len));
    return frame_len;
}

/// 완성된 frame 하나를 decode한다. 반환 slice는 입력 frame을 빌리며 별도 allocation이 없다.
pub fn decodeExact(frame: []const u8) Error!Message {
    if (frame.len < prefix_len) return error.IncompleteFrame;
    const payload_len = readU32At(frame[0..prefix_len]);
    const total_len = std.math.add(usize, prefix_len, payload_len) catch return error.FrameTooLarge;
    if (total_len > max_result_frame_bytes) return error.FrameTooLarge;
    if (frame.len < total_len) return error.IncompleteFrame;
    if (frame.len != total_len) return error.TrailingBytes;

    var cursor = ReadCursor.init(frame[prefix_len..]);
    const actual_magic = try cursor.readBytes(magic.len);
    if (!std.mem.eql(u8, actual_magic, &magic)) return error.InvalidMagic;
    if (try cursor.readU16() != version) return error.UnsupportedVersion;
    const tag = std.enums.fromInt(Tag, try cursor.readByte()) orelse return error.UnknownTag;

    const message: Message = switch (tag) {
        .hello => .{ .hello = try readHello(&cursor) },
        .hello_ack => .{ .hello_ack = try readHello(&cursor) },
        .request => blk: {
            const capability = try readCapability(&cursor);
            const source_len = try cursor.readU32();
            if (source_len > max_source_bytes) return error.SourceTooLarge;
            const source = try cursor.readBytes(source_len);
            if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
            if (!std.mem.eql(u8, &capability.source_hash, &sourceHash(source))) return error.InvalidLength;
            break :blk .{ .request = .{ .capability = capability, .source = source } };
        },
        .result => blk: {
            const capability = try readCapability(&cursor);
            const status = std.enums.fromInt(ResultStatus, try cursor.readByte()) orelse return error.UnknownStatus;
            const body_len = try cursor.readU32();
            if (status == .render_error and body_len != 0) return error.InvalidRenderErrorBody;
            if (status == .ok and body_len > max_svg_bytes) return error.SvgTooLarge;
            const body = try cursor.readBytes(body_len);
            if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
            break :blk .{ .result = .{ .capability = capability, .status = status, .body = body } };
        },
    };
    if (cursor.pos != cursor.bytes.len) return error.TrailingBytes;

    const tag_cap = if (tag == .result) max_result_frame_bytes else max_request_frame_bytes;
    if (frame.len > tag_cap) return error.FrameTooLarge;
    return message;
}

/// pipe의 partial/concatenated read를 받아 frame 경계만 복원한다. `next`가 반환한 slice는 다음
/// `feed`/`next` 전까지만 유효하다. 고정 저장소라 공격 입력에도 allocation과 성장 재시도가 없다.
pub const StreamingDecoder = struct {
    retained: [max_retained_bytes]u8 = undefined,
    len: usize = 0,
    delivered_len: usize = 0,

    pub fn feed(self: *StreamingDecoder, bytes: []const u8) Error!void {
        self.compactDelivered();
        if (bytes.len > self.retained.len - self.len) return error.RetainedInputOverflow;
        @memcpy(self.retained[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn next(self: *StreamingDecoder) Error!?Message {
        self.compactDelivered();
        if (self.len < prefix_len) return null;
        const payload_len = readU32At(self.retained[0..prefix_len]);
        const total_len = std.math.add(usize, prefix_len, payload_len) catch return error.FrameTooLarge;
        if (total_len > max_result_frame_bytes) return error.FrameTooLarge;
        if (self.len < total_len) return null;
        const message = try decodeExact(self.retained[0..total_len]);
        self.delivered_len = total_len;
        return message;
    }

    pub fn finish(self: *StreamingDecoder) Error!void {
        self.compactDelivered();
        if (self.len != 0) return error.IncompleteFrame;
    }

    pub fn reset(self: *StreamingDecoder) void {
        self.len = 0;
        self.delivered_len = 0;
    }

    fn compactDelivered(self: *StreamingDecoder) void {
        if (self.delivered_len == 0) return;
        const remaining = self.len - self.delivered_len;
        std.mem.copyForwards(u8, self.retained[0..remaining], self.retained[self.delivered_len..self.len]);
        self.len = remaining;
        self.delivered_len = 0;
    }
};

pub fn sourceHash(source: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return digest;
}

fn writeHello(cursor: *Cursor, value: Hello) Error!void {
    try cursor.writeU64(value.helper_instance);
    try cursor.writeU64(value.nonce);
}

fn readHello(cursor: *ReadCursor) Error!Hello {
    return .{ .helper_instance = try cursor.readU64(), .nonce = try cursor.readU64() };
}

fn writeCapability(cursor: *Cursor, value: JobCapability) Error!void {
    try cursor.writeU64(value.helper_instance);
    try cursor.writeU64(value.job_id);
    try cursor.writeU64(value.renderer.document_revision);
    try cursor.writeU64(value.renderer.projection_generation);
    try cursor.writeU64(value.renderer.widget_id);
    try cursor.writeU64(value.renderer.widget_generation);
    try cursor.writeU64(value.renderer.renderer_instance);
    try cursor.writeU64(value.fence_id);
    try cursor.writeBytes(&value.source_hash);
}

fn readCapability(cursor: *ReadCursor) Error!JobCapability {
    var value: JobCapability = undefined;
    value.helper_instance = try cursor.readU64();
    value.job_id = try cursor.readU64();
    value.renderer.document_revision = try cursor.readU64();
    value.renderer.projection_generation = try cursor.readU64();
    value.renderer.widget_id = try cursor.readU64();
    value.renderer.widget_generation = try cursor.readU64();
    value.renderer.renderer_instance = try cursor.readU64();
    value.fence_id = try cursor.readU64();
    @memcpy(&value.source_hash, try cursor.readBytes(value.source_hash.len));
    return value;
}

const Cursor = struct {
    bytes: []u8,
    pos: usize = 0,

    fn init(bytes: []u8) Cursor {
        return .{ .bytes = bytes };
    }

    fn skip(self: *Cursor, len: usize) Error!void {
        _ = try self.reserve(len);
    }

    fn writeByte(self: *Cursor, value: u8) Error!void {
        const dest = try self.reserve(1);
        dest[0] = value;
    }

    fn writeU16(self: *Cursor, value: u16) Error!void {
        const dest = try self.reserve(2);
        std.mem.writeInt(u16, dest[0..2], value, .big);
    }

    fn writeU32(self: *Cursor, value: u32) Error!void {
        const dest = try self.reserve(4);
        std.mem.writeInt(u32, dest[0..4], value, .big);
    }

    fn writeU64(self: *Cursor, value: u64) Error!void {
        const dest = try self.reserve(8);
        std.mem.writeInt(u64, dest[0..8], value, .big);
    }

    fn writeBytes(self: *Cursor, value: []const u8) Error!void {
        const dest = try self.reserve(value.len);
        @memcpy(dest, value);
    }

    fn reserve(self: *Cursor, len: usize) Error![]u8 {
        if (len > self.bytes.len -| self.pos) return error.OutputTooSmall;
        const start = self.pos;
        self.pos += len;
        return self.bytes[start..self.pos];
    }
};

const ReadCursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn init(bytes: []const u8) ReadCursor {
        return .{ .bytes = bytes };
    }

    fn readByte(self: *ReadCursor) Error!u8 {
        return (try self.readBytes(1))[0];
    }

    fn readU16(self: *ReadCursor) Error!u16 {
        return std.mem.readInt(u16, (try self.readBytes(2))[0..2], .big);
    }

    fn readU32(self: *ReadCursor) Error!u32 {
        return std.mem.readInt(u32, (try self.readBytes(4))[0..4], .big);
    }

    fn readU64(self: *ReadCursor) Error!u64 {
        return std.mem.readInt(u64, (try self.readBytes(8))[0..8], .big);
    }

    fn readBytes(self: *ReadCursor, len: usize) Error![]const u8 {
        if (len > self.bytes.len -| self.pos) return error.InvalidLength;
        const start = self.pos;
        self.pos += len;
        return self.bytes[start..self.pos];
    }
};

fn writeU32At(dest: []u8, value: u32) void {
    std.mem.writeInt(u32, dest[0..4], value, .big);
}

fn readU32At(source: []const u8) u32 {
    return std.mem.readInt(u32, source[0..4], .big);
}

fn testCapability() JobCapability {
    return .{
        .helper_instance = 1,
        .job_id = 2,
        .renderer = .{
            .document_revision = 3,
            .projection_generation = 4,
            .widget_id = 5,
            .widget_generation = 6,
            .renderer_instance = 7,
        },
        .fence_id = 8,
        .source_hash = [_]u8{0xab} ** 32,
    };
}

test "hello byte golden is big endian and round trips" {
    var encoded: [64]u8 = undefined;
    const len = try encode(.{ .hello = .{ .helper_instance = 0x0102030405060708, .nonce = 0x1112131415161718 } }, &encoded);
    try std.testing.expectEqualSlices(u8, &.{
        0,  0,  0,  23, 'M', 'R', 'U', '1', 0,  1,  0,
        1,  2,  3,  4,  5,   6,   7,   8,   17, 18, 19,
        20, 21, 22, 23, 24,
    }, encoded[0..len]);
    const decoded = try decodeExact(encoded[0..len]);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), decoded.hello.helper_instance);
    try std.testing.expectEqual(@as(u64, 0x1112131415161718), decoded.hello.nonce);
}

test "request and result round trip exact identity and UTF-8" {
    var encoded: [max_request_frame_bytes]u8 = undefined;
    const source = "graph TD\n  A --> B\n한글";
    var capability = testCapability();
    capability.source_hash = sourceHash(source);
    const request_len = try encode(.{ .request = .{ .capability = capability, .source = source } }, &encoded);
    const request = (try decodeExact(encoded[0..request_len])).request;
    try std.testing.expectEqualDeep(capability, request.capability);
    try std.testing.expectEqualStrings(source, request.source);

    var result_buf: [max_result_frame_bytes]u8 = undefined;
    const svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>";
    const result_len = try encode(.{ .result = .{ .capability = capability, .status = .ok, .body = svg } }, &result_buf);
    const result = (try decodeExact(result_buf[0..result_len])).result;
    try std.testing.expectEqualDeep(capability, result.capability);
    try std.testing.expectEqual(.ok, result.status);
    try std.testing.expectEqualStrings(svg, result.body);
}

test "streaming decoder accepts one-byte reads and concatenated frames" {
    var first: [64]u8 = undefined;
    var second: [64]u8 = undefined;
    const first_len = try encode(.{ .hello = .{ .helper_instance = 11, .nonce = 12 } }, &first);
    const second_len = try encode(.{ .hello_ack = .{ .helper_instance = 11, .nonce = 12 } }, &second);

    var decoder: StreamingDecoder = .{};
    for (first[0..first_len]) |byte| {
        try decoder.feed(&.{byte});
        const maybe = try decoder.next();
        if (decoder.len < first_len) try std.testing.expect(maybe == null) else try std.testing.expectEqual(@as(u64, 11), maybe.?.hello.helper_instance);
    }
    try decoder.feed(second[0..second_len]);
    try std.testing.expectEqual(@as(u64, 11), (try decoder.next()).?.hello_ack.helper_instance);
    try decoder.finish();
}

test "streaming decoder accepts two complete frames from one read" {
    var first: [64]u8 = undefined;
    var second: [64]u8 = undefined;
    const first_len = try encode(.{ .hello = .{ .helper_instance = 21, .nonce = 22 } }, &first);
    const second_len = try encode(.{ .hello_ack = .{ .helper_instance = 21, .nonce = 22 } }, &second);
    var combined: [128]u8 = undefined;
    @memcpy(combined[0..first_len], first[0..first_len]);
    @memcpy(combined[first_len..][0..second_len], second[0..second_len]);

    var decoder: StreamingDecoder = .{};
    try decoder.feed(combined[0 .. first_len + second_len]);
    try std.testing.expectEqual(@as(u64, 21), (try decoder.next()).?.hello.helper_instance);
    try std.testing.expectEqual(@as(u64, 22), (try decoder.next()).?.hello_ack.nonce);
    try decoder.finish();
}

test "decoder rejects malformed closed fields lengths and trailing bytes" {
    var encoded: [128]u8 = undefined;
    const len = try encode(.{ .hello = .{ .helper_instance = 1, .nonce = 2 } }, &encoded);

    var bad = encoded;
    bad[4] = 'X';
    try std.testing.expectError(error.InvalidMagic, decodeExact(bad[0..len]));
    bad = encoded;
    bad[9] = 2;
    try std.testing.expectError(error.UnsupportedVersion, decodeExact(bad[0..len]));
    bad = encoded;
    bad[10] = 9;
    try std.testing.expectError(error.UnknownTag, decodeExact(bad[0..len]));
    bad = encoded;
    bad[8] = 1;
    bad[9] = 0;
    try std.testing.expectError(error.UnsupportedVersion, decodeExact(bad[0..len]));
    try std.testing.expectError(error.IncompleteFrame, decodeExact(encoded[0 .. len - 1]));
    encoded[len] = 0;
    try std.testing.expectError(error.TrailingBytes, decodeExact(encoded[0 .. len + 1]));
}

test "request source hash mismatch and result unknown status fail closed" {
    var request_buf: [max_request_frame_bytes]u8 = undefined;
    var capability = testCapability();
    capability.source_hash = sourceHash("source");
    const request_len = try encode(.{ .request = .{ .capability = capability, .source = "source" } }, &request_buf);
    request_buf[11 + identity_len - 1] ^= 1;
    try std.testing.expectError(error.InvalidLength, decodeExact(request_buf[0..request_len]));

    var result_buf: [max_result_frame_bytes]u8 = undefined;
    const result_len = try encode(.{ .result = .{ .capability = capability, .status = .render_error, .body = "" } }, &result_buf);
    result_buf[prefix_len + common_len + identity_len] = 9;
    try std.testing.expectError(error.UnknownStatus, decodeExact(result_buf[0..result_len]));
}

test "source and SVG caps reject cap plus one before encoding" {
    var request_buf: [max_request_frame_bytes]u8 = undefined;
    var result_buf: [max_result_frame_bytes]u8 = undefined;
    const source = [_]u8{'a'} ** (max_source_bytes + 1);
    const svg = [_]u8{'a'} ** (max_svg_bytes + 1);
    try std.testing.expectError(error.SourceTooLarge, encode(.{ .request = .{ .capability = testCapability(), .source = &source } }, &request_buf));
    try std.testing.expectError(error.SvgTooLarge, encode(.{ .result = .{ .capability = testCapability(), .status = .ok, .body = &svg } }, &result_buf));
    try std.testing.expectError(error.InvalidRenderErrorBody, encode(.{ .result = .{ .capability = testCapability(), .status = .render_error, .body = "x" } }, &result_buf));
}

test "streaming decoder rejects oversized declaration and middle EOF" {
    var decoder: StreamingDecoder = .{};
    var prefix: [4]u8 = undefined;
    writeU32At(&prefix, max_result_frame_bytes);
    try decoder.feed(&prefix);
    try std.testing.expectError(error.FrameTooLarge, decoder.next());

    decoder.reset();
    var encoded: [64]u8 = undefined;
    const len = try encode(.{ .hello = .{ .helper_instance = 1, .nonce = 2 } }, &encoded);
    try decoder.feed(encoded[0 .. len - 1]);
    try std.testing.expect((try decoder.next()) == null);
    try std.testing.expectError(error.IncompleteFrame, decoder.finish());
}
