//! 웹 OSR sidecar 제어 채널의 frame 조립·해체(W1a). 방향 확인은 받는 쪽 `stream.zig` 가 한다.

const std = @import("std");
const wire = @import("wire.zig");
const message_mod = @import("message.zig");
const fields = @import("fields.zig");

const Cursor = wire.Cursor;
const ReadCursor = wire.ReadCursor;
const Error = wire.Error;
const magic = wire.magic;
const version = wire.version;
const prefix_len = wire.prefix_len;
const common_len = wire.common_len;
const max_frame_bytes = wire.max_frame_bytes;
const max_url_bytes = wire.max_url_bytes;
const max_text_bytes = wire.max_text_bytes;
const Message = message_mod.Message;
const Tag = message_mod.Tag;
const ViewSize = message_mod.ViewSize;
const RendererGoneReason = message_mod.RendererGoneReason;
const FailureCode = message_mod.FailureCode;
const max_view_extent = fields.max_view_extent;
const writeBrowser = fields.writeBrowser;
const readBrowser = fields.readBrowser;
const writeSize = fields.writeSize;
const readSize = fields.readSize;
const readBool = fields.readBool;
const readHello = fields.readHello;
const writeUrl = fields.writeUrl;
const readUrl = fields.readUrl;
const writeText = fields.writeText;
const readText = fields.readText;

/// Caller-owned output 에 frame 을 만든다. 성공 반환값만큼만 pipe 에 써야 한다.
pub fn encode(message: Message, out: []u8) Error!usize {
    var cursor = Cursor.init(out);
    try cursor.skip(prefix_len);
    try cursor.writeBytes(&magic);
    try cursor.writeU16(version);
    try cursor.writeByte(@intFromEnum(message));

    switch (message) {
        .hello, .hello_ack => |value| {
            try cursor.writeU64(value.instance);
            try cursor.writeU64(value.nonce);
        },
        .create_browser => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeSize(&cursor, value.size);
            try cursor.writeByte(@intFromBool(value.hidden));
            try writeUrl(&cursor, value.url);
        },
        .destroy_browser, .browser_created, .browser_closed => |browser| try writeBrowser(&cursor, browser),
        .resize => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeSize(&cursor, value.size);
        },
        .set_hidden, .set_focus => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromBool(value.value));
        },
        .navigate => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeUrl(&cursor, value.url);
        },
        .shutdown => {},
        .title_changed => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeText(&cursor, value.text);
        },
        .load_finished => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(@bitCast(value.http_status));
        },
        .renderer_gone => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.reason));
        },
        .failure => |value| {
            // 브라우저에 묶이지 않은 실패는 0 을 싣는다 — 여기만 0 을 허용한다.
            try cursor.writeU64(value.browser);
            try cursor.writeByte(@intFromEnum(value.code));
            try writeText(&cursor, value.detail);
        },
    }

    const frame_len = cursor.pos;
    if (frame_len > max_frame_bytes) return error.FrameTooLarge;
    std.mem.writeInt(u32, out[0..prefix_len], @intCast(frame_len - prefix_len), .big);
    return frame_len;
}

/// 완성된 frame 하나를 decode 한다. 반환 slice 는 입력 frame 을 빌리며 별도 allocation 이 없다.
/// 방향은 보지 않는다 — 받는 쪽은 `StreamingDecoder` 로 방향까지 확인한다.
pub fn decodeExact(frame: []const u8) Error!Message {
    if (frame.len < prefix_len) return error.IncompleteFrame;
    const payload_len = std.mem.readInt(u32, frame[0..prefix_len], .big);
    const total_len = std.math.add(usize, prefix_len, payload_len) catch return error.FrameTooLarge;
    if (total_len > max_frame_bytes) return error.FrameTooLarge;
    if (frame.len < total_len) return error.IncompleteFrame;
    if (frame.len != total_len) return error.TrailingBytes;

    var cursor = ReadCursor.init(frame[prefix_len..]);
    if (!std.mem.eql(u8, try cursor.readBytes(magic.len), &magic)) return error.InvalidMagic;
    if (try cursor.readU16() != version) return error.UnsupportedVersion;
    const tag = std.enums.fromInt(Tag, try cursor.readByte()) orelse return error.UnknownTag;

    const message: Message = switch (tag) {
        .hello => .{ .hello = try readHello(&cursor) },
        .hello_ack => .{ .hello_ack = try readHello(&cursor) },
        .create_browser => .{ .create_browser = .{
            .browser = try readBrowser(&cursor),
            .size = try readSize(&cursor),
            .hidden = try readBool(&cursor),
            .url = try readUrl(&cursor),
        } },
        .destroy_browser => .{ .destroy_browser = try readBrowser(&cursor) },
        .browser_created => .{ .browser_created = try readBrowser(&cursor) },
        .browser_closed => .{ .browser_closed = try readBrowser(&cursor) },
        .resize => .{ .resize = .{ .browser = try readBrowser(&cursor), .size = try readSize(&cursor) } },
        .set_hidden => .{ .set_hidden = .{ .browser = try readBrowser(&cursor), .value = try readBool(&cursor) } },
        .set_focus => .{ .set_focus = .{ .browser = try readBrowser(&cursor), .value = try readBool(&cursor) } },
        .navigate => .{ .navigate = .{ .browser = try readBrowser(&cursor), .url = try readUrl(&cursor) } },
        .shutdown => .shutdown,
        .title_changed => .{ .title_changed = .{ .browser = try readBrowser(&cursor), .text = try readText(&cursor) } },
        .load_finished => .{ .load_finished = .{
            .browser = try readBrowser(&cursor),
            .http_status = @bitCast(try cursor.readU32()),
        } },
        .renderer_gone => .{ .renderer_gone = .{
            .browser = try readBrowser(&cursor),
            .reason = std.enums.fromInt(RendererGoneReason, try cursor.readByte()) orelse return error.UnknownReason,
        } },
        .failure => .{ .failure = .{
            .browser = try cursor.readU64(),
            .code = std.enums.fromInt(FailureCode, try cursor.readByte()) orelse return error.UnknownFailureCode,
            .detail = try readText(&cursor),
        } },
    };
    if (cursor.pos != cursor.bytes.len) return error.TrailingBytes;
    return message;
}

// 가장 큰 frame(create_browser + URL 상한)이 frame 상한 안에 든다 — 상수를 바꿔 이 둘이 어긋나면 컴파일이 멈춘다.
comptime {
    const largest = prefix_len + common_len + 8 + 12 + 1 + 4 + max_url_bytes;
    std.debug.assert(largest <= max_frame_bytes);
    std.debug.assert(prefix_len + common_len + 8 + 1 + 4 + max_text_bytes <= max_frame_bytes);
}

const test_size: ViewSize = .{ .width = 760, .height = 486, .scale = 2.0 };

fn roundTrip(message: Message) !Message {
    const State = struct {
        var buf: [max_frame_bytes]u8 = undefined;
    };
    const len = try encode(message, &State.buf);
    return decodeExact(State.buf[0..len]);
}

test "hello byte golden is big endian and round trips" {
    var encoded: [64]u8 = undefined;
    const len = try encode(.{ .hello = .{ .instance = 0x0102030405060708, .nonce = 0x1112131415161718 } }, &encoded);
    try std.testing.expectEqualSlices(u8, &.{
        0,  0,  0,  23, 'M', 'W', 'E', 'B', 0,  1,  0, // v1, tag hello
        1,  2,  3,  4,  5,   6,   7,   8,   17, 18, 19,
        20, 21, 22, 23, 24,
    }, encoded[0..len]);
    const decoded = try decodeExact(encoded[0..len]);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), decoded.hello.instance);
    try std.testing.expectEqual(@as(u64, 0x1112131415161718), decoded.hello.nonce);
}

test "create_browser byte golden lays out id, size, hidden and url in order" {
    var encoded: [128]u8 = undefined;
    const len = try encode(.{ .create_browser = .{ .browser = 7, .size = test_size, .hidden = true, .url = "about:blank" } }, &encoded);
    const body = encoded[prefix_len + common_len .. len];
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, body[0..8], .big));
    try std.testing.expectEqual(@as(u32, 760), std.mem.readInt(u32, body[8..12], .big));
    try std.testing.expectEqual(@as(u32, 486), std.mem.readInt(u32, body[12..16], .big));
    try std.testing.expectEqual(@as(u32, 0x40000000), std.mem.readInt(u32, body[16..20], .big)); // 2.0f
    try std.testing.expectEqual(@as(u8, 1), body[20]);
    try std.testing.expectEqual(@as(u32, 11), std.mem.readInt(u32, body[21..25], .big));
    try std.testing.expectEqualStrings("about:blank", body[25..]);
}

test "every message round trips" {
    const created = try roundTrip(.{ .create_browser = .{ .browser = 9, .size = test_size, .hidden = false, .url = "https://example.com/한글" } });
    try std.testing.expectEqual(@as(u64, 9), created.create_browser.browser);
    try std.testing.expectEqual(test_size, created.create_browser.size);
    try std.testing.expect(!created.create_browser.hidden);
    try std.testing.expectEqualStrings("https://example.com/한글", created.create_browser.url);

    try std.testing.expectEqual(@as(u64, 9), (try roundTrip(.{ .destroy_browser = 9 })).destroy_browser);
    const resized = try roundTrip(.{ .resize = .{ .browser = 9, .size = .{ .width = 1, .height = max_view_extent, .scale = 1.0 } } });
    try std.testing.expectEqual(max_view_extent, resized.resize.size.height);
    try std.testing.expect((try roundTrip(.{ .set_hidden = .{ .browser = 9, .value = true } })).set_hidden.value);
    try std.testing.expect(!(try roundTrip(.{ .set_focus = .{ .browser = 9, .value = false } })).set_focus.value);
    try std.testing.expectEqualStrings("file:///tmp/a.html", (try roundTrip(.{ .navigate = .{ .browser = 9, .url = "file:///tmp/a.html" } })).navigate.url);
    try std.testing.expectEqual(Tag.shutdown, std.meta.activeTag(try roundTrip(.shutdown)));

    try std.testing.expectEqual(@as(u64, 3), (try roundTrip(.{ .hello_ack = .{ .instance = 3, .nonce = 4 } })).hello_ack.instance);
    try std.testing.expectEqual(@as(u64, 9), (try roundTrip(.{ .browser_created = 9 })).browser_created);
    try std.testing.expectEqual(@as(u64, 9), (try roundTrip(.{ .browser_closed = 9 })).browser_closed);
    try std.testing.expectEqualStrings("", (try roundTrip(.{ .title_changed = .{ .browser = 9, .text = "" } })).title_changed.text);
    try std.testing.expectEqual(@as(i32, -1), (try roundTrip(.{ .load_finished = .{ .browser = 9, .http_status = -1 } })).load_finished.http_status);
    try std.testing.expectEqual(RendererGoneReason.out_of_memory, (try roundTrip(.{ .renderer_gone = .{ .browser = 9, .reason = .out_of_memory } })).renderer_gone.reason);
    const failure = try roundTrip(.{ .failure = .{ .browser = 0, .code = .profile_in_use, .detail = "프로필 사용 중" } });
    try std.testing.expectEqual(@as(u64, 0), failure.failure.browser);
    try std.testing.expectEqual(FailureCode.profile_in_use, failure.failure.code);
    try std.testing.expectEqualStrings("프로필 사용 중", failure.failure.detail);
}

test "decoder rejects malformed header, trailing bytes and truncation" {
    var encoded: [64]u8 = undefined;
    const len = try encode(.{ .hello = .{ .instance = 1, .nonce = 2 } }, &encoded);

    var bad = encoded;
    bad[4] = 'X';
    try std.testing.expectError(error.InvalidMagic, decodeExact(bad[0..len]));
    bad = encoded;
    bad[9] = 2;
    try std.testing.expectError(error.UnsupportedVersion, decodeExact(bad[0..len]));
    bad = encoded;
    bad[10] = 31; // 방향 범위 안이지만 정의되지 않은 tag
    try std.testing.expectError(error.UnknownTag, decodeExact(bad[0..len]));
    try std.testing.expectError(error.IncompleteFrame, decodeExact(encoded[0 .. len - 1]));
    encoded[len] = 0;
    try std.testing.expectError(error.TrailingBytes, decodeExact(encoded[0 .. len + 1]));
}

test "closed fields fail closed on decode" {
    var buf: [128]u8 = undefined;
    const body = prefix_len + common_len;

    var len = try encode(.{ .set_hidden = .{ .browser = 1, .value = true } }, &buf);
    buf[body + 8] = 2;
    try std.testing.expectError(error.InvalidBool, decodeExact(buf[0..len]));

    len = try encode(.{ .destroy_browser = 1 }, &buf);
    std.mem.writeInt(u64, buf[body..][0..8], 0, .big);
    try std.testing.expectError(error.InvalidBrowserId, decodeExact(buf[0..len]));

    len = try encode(.{ .renderer_gone = .{ .browser = 1, .reason = .crashed } }, &buf);
    buf[body + 8] = 200;
    try std.testing.expectError(error.UnknownReason, decodeExact(buf[0..len]));

    len = try encode(.{ .failure = .{ .browser = 0, .code = .cef_initialize_failed, .detail = "" } }, &buf);
    buf[body + 8] = 200;
    try std.testing.expectError(error.UnknownFailureCode, decodeExact(buf[0..len]));

    len = try encode(.{ .title_changed = .{ .browser = 1, .text = "ab" } }, &buf);
    buf[len - 1] = 0xFF;
    try std.testing.expectError(error.InvalidUtf8, decodeExact(buf[0..len]));
}

test "view size bounds and NaN scale are rejected both ways" {
    var buf: [128]u8 = undefined;
    const bad_sizes = [_]ViewSize{
        .{ .width = 0, .height = 10, .scale = 1 },
        .{ .width = 10, .height = max_view_extent + 1, .scale = 1 },
        .{ .width = 10, .height = 10, .scale = 0.25 },
        .{ .width = 10, .height = 10, .scale = 9 },
        .{ .width = 10, .height = 10, .scale = std.math.nan(f32) },
    };
    for (bad_sizes) |size| {
        try std.testing.expectError(error.InvalidViewSize, encode(.{ .resize = .{ .browser = 1, .size = size } }, &buf));
    }
    const len = try encode(.{ .resize = .{ .browser = 1, .size = test_size } }, &buf);
    std.mem.writeInt(u32, buf[prefix_len + common_len + 16 ..][0..4], @bitCast(std.math.nan(f32)), .big);
    try std.testing.expectError(error.InvalidViewSize, decodeExact(buf[0..len]));
}

test "url and text caps reject cap plus one, empty url and zero browser on encode" {
    var buf: [max_frame_bytes + 64]u8 = undefined;
    const long_url = [_]u8{'a'} ** (max_url_bytes + 1);
    const long_text = [_]u8{'a'} ** (max_text_bytes + 1);
    try std.testing.expectError(error.UrlTooLarge, encode(.{ .navigate = .{ .browser = 1, .url = &long_url } }, &buf));
    try std.testing.expectError(error.EmptyUrl, encode(.{ .navigate = .{ .browser = 1, .url = "" } }, &buf));
    try std.testing.expectError(error.TextTooLarge, encode(.{ .title_changed = .{ .browser = 1, .text = &long_text } }, &buf));
    try std.testing.expectError(error.InvalidBrowserId, encode(.{ .browser_created = 0 }, &buf));
    // 상한 그대로는 들어간다.
    _ = try encode(.{ .create_browser = .{ .browser = 1, .size = test_size, .hidden = false, .url = long_url[0..max_url_bytes] } }, &buf);
    _ = try encode(.{ .title_changed = .{ .browser = 1, .text = long_text[0..max_text_bytes] } }, &buf);
}

/// encode 가 거절하는 모양(상한 +1·빈 URL·남는 바이트)은 encode 로 못 만든다 — 공격하는 쪽처럼 손으로 짓는다.
fn handFrame(out: []u8, tag: Tag, body: []const u8) []const u8 {
    std.mem.writeInt(u32, out[0..prefix_len], @intCast(common_len + body.len), .big);
    @memcpy(out[prefix_len..][0..magic.len], &magic);
    std.mem.writeInt(u16, out[prefix_len + magic.len ..][0..2], version, .big);
    out[prefix_len + magic.len + 2] = @intFromEnum(tag);
    @memcpy(out[prefix_len + common_len ..][0..body.len], body);
    return out[0 .. prefix_len + common_len + body.len];
}

test "decode rejects shapes encode refuses to build" {
    var frame: [max_frame_bytes]u8 = undefined;
    var body: [max_frame_bytes]u8 = undefined;
    std.mem.writeInt(u64, body[0..8], 1, .big);

    // 선언 길이 안에 필드보다 한 바이트가 더 있다(frame 바깥이 아니라 payload 안쪽).
    body[8] = 0xAA;
    try std.testing.expectError(error.TrailingBytes, decodeExact(handFrame(&frame, .destroy_browser, body[0..9])));

    // 길이 0 인 URL.
    std.mem.writeInt(u32, body[8..12], 0, .big);
    try std.testing.expectError(error.EmptyUrl, decodeExact(handFrame(&frame, .navigate, body[0..12])));

    // 글 상한 +1 — sidecar 가 `clampUtf8` 을 건너뛰고 보낸 제목.
    std.mem.writeInt(u32, body[8..12], max_text_bytes + 1, .big);
    @memset(body[12..][0 .. max_text_bytes + 1], 'a');
    try std.testing.expectError(error.TextTooLarge, decodeExact(handFrame(&frame, .title_changed, body[0 .. 12 + max_text_bytes + 1])));

    // URL 상한 +1 은 frame 상한 안에 들어가므로 URL 검사에서 걸려야 한다.
    std.mem.writeInt(u32, body[8..12], max_url_bytes + 1, .big);
    @memset(body[12..][0 .. max_url_bytes + 1], 'a');
    try std.testing.expectError(error.UrlTooLarge, decodeExact(handFrame(&frame, .navigate, body[0 .. 12 + max_url_bytes + 1])));
}

test "every single-byte corruption of a valid frame decodes or errors without crashing" {
    var encoded: [256]u8 = undefined;
    const len = try encode(.{ .create_browser = .{ .browser = 42, .size = test_size, .hidden = true, .url = "https://maru.dev/" } }, &encoded);
    var corrupted: [256]u8 = undefined;
    for (0..len) |i| {
        for ([_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFF }) |value| {
            @memcpy(corrupted[0..len], encoded[0..len]);
            corrupted[i] = value;
            if (decodeExact(corrupted[0..len])) |message| {
                // 풀렸다면 닫힌 필드는 여전히 유효해야 한다.
                if (message == .create_browser) try std.testing.expect(message.create_browser.browser != 0);
            } else |_| {}
        }
    }
}
