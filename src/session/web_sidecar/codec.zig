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
const max_ime_text_bytes = wire.max_ime_text_bytes;
const Message = message_mod.Message;
const Tag = message_mod.Tag;
const ViewSize = message_mod.ViewSize;
const RendererGoneReason = message_mod.RendererGoneReason;
const NavActionKind = message_mod.NavActionKind;
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
const writeService = fields.writeService;
const readService = fields.readService;
const writeModifiers = fields.writeModifiers;
const readModifiers = fields.readModifiers;
const writeExtent = fields.writeExtent;
const readExtent = fields.readExtent;
const writePoint = fields.writePoint;
const readPoint = fields.readPoint;
const writeRange = fields.writeRange;
const readRange = fields.readRange;
const writeImeText = fields.writeImeText;
const readImeText = fields.readImeText;
const writeRect = fields.writeRect;
const readRect = fields.readRect;
const MouseKind = message_mod.MouseKind;
const MouseButton = message_mod.MouseButton;
const KeyKind = message_mod.KeyKind;
const EditCommandKind = message_mod.EditCommandKind;
const WebCursor = message_mod.WebCursor;

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
        .frame_channel => |value| {
            try writeService(&cursor, value.service);
            try cursor.writeBytes(&value.token);
        },
        .nav_action => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.action));
        },
        .mouse => |value| {
            if (!fields.validClickCount(value)) return error.InvalidClickCount;
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.kind));
            try cursor.writeByte(@intFromEnum(value.button));
            try writePoint(&cursor, value.point);
            try writeModifiers(&cursor, value.modifiers);
            try cursor.writeByte(value.click_count);
        },
        .wheel => |value| {
            try writeBrowser(&cursor, value.browser);
            try writePoint(&cursor, value.point);
            try writeExtent(&cursor, value.delta_x);
            try writeExtent(&cursor, value.delta_y);
            try writeModifiers(&cursor, value.modifiers);
        },
        .key => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.kind));
            try writeModifiers(&cursor, value.modifiers);
            try cursor.writeByte(value.windows_key_code);
            try cursor.writeByte(value.native_key_code);
            try cursor.writeU16(value.character);
            try cursor.writeU16(value.unmodified_character);
        },
        .ime_set_composition => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeRange(&cursor, value.selection, .selection);
            try writeRange(&cursor, value.replacement, .replacement);
            try writeImeText(&cursor, value.text);
        },
        .ime_commit_text => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeRange(&cursor, value.replacement, .replacement);
            try writeImeText(&cursor, value.text);
        },
        .ime_finish_composing => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromBool(value.value));
        },
        .ime_cancel_composition, .capture_lost => |browser| try writeBrowser(&cursor, browser),
        .edit_command => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.command));
        },
        .cursor_changed => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.cursor));
        },
        .ime_range => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeRect(&cursor, value.bounds);
        },
        .url_changed => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeUrl(&cursor, value.url);
        },
        .nav_state => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromBool(value.can_go_back));
            try cursor.writeByte(@intFromBool(value.can_go_forward));
            try cursor.writeByte(@intFromBool(value.loading));
        },
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
        .frame_channel => blk: {
            const service = try readService(&cursor);
            var token: [16]u8 = undefined;
            @memcpy(&token, try cursor.readBytes(16));
            break :blk .{ .frame_channel = .{ .service = service, .token = token } };
        },
        .nav_action => .{ .nav_action = .{
            .browser = try readBrowser(&cursor),
            .action = std.enums.fromInt(NavActionKind, try cursor.readByte()) orelse return error.UnknownNavAction,
        } },
        .mouse => blk: {
            const mouse: message_mod.Mouse = .{
                .browser = try readBrowser(&cursor),
                .kind = std.enums.fromInt(MouseKind, try cursor.readByte()) orelse return error.UnknownMouseKind,
                .button = std.enums.fromInt(MouseButton, try cursor.readByte()) orelse return error.UnknownMouseButton,
                .point = try readPoint(&cursor),
                .modifiers = try readModifiers(&cursor),
                .click_count = try cursor.readByte(),
            };
            if (!fields.validClickCount(mouse)) return error.InvalidClickCount;
            break :blk .{ .mouse = mouse };
        },
        .wheel => .{ .wheel = .{
            .browser = try readBrowser(&cursor),
            .point = try readPoint(&cursor),
            .delta_x = try readExtent(&cursor),
            .delta_y = try readExtent(&cursor),
            .modifiers = try readModifiers(&cursor),
        } },
        .key => .{ .key = .{
            .browser = try readBrowser(&cursor),
            .kind = std.enums.fromInt(KeyKind, try cursor.readByte()) orelse return error.UnknownKeyKind,
            .modifiers = try readModifiers(&cursor),
            .windows_key_code = try cursor.readByte(),
            .native_key_code = try cursor.readByte(),
            .character = try cursor.readU16(),
            .unmodified_character = try cursor.readU16(),
        } },
        .ime_set_composition => .{ .ime_set_composition = .{
            .browser = try readBrowser(&cursor),
            .selection = try readRange(&cursor, .selection),
            .replacement = try readRange(&cursor, .replacement),
            .text = try readImeText(&cursor),
        } },
        .ime_commit_text => .{ .ime_commit_text = .{
            .browser = try readBrowser(&cursor),
            .replacement = try readRange(&cursor, .replacement),
            .text = try readImeText(&cursor),
        } },
        .ime_finish_composing => .{ .ime_finish_composing = .{ .browser = try readBrowser(&cursor), .value = try readBool(&cursor) } },
        .ime_cancel_composition => .{ .ime_cancel_composition = try readBrowser(&cursor) },
        .capture_lost => .{ .capture_lost = try readBrowser(&cursor) },
        .edit_command => .{ .edit_command = .{
            .browser = try readBrowser(&cursor),
            .command = std.enums.fromInt(EditCommandKind, try cursor.readByte()) orelse return error.UnknownEditCommand,
        } },
        .cursor_changed => .{ .cursor_changed = .{
            .browser = try readBrowser(&cursor),
            .cursor = std.enums.fromInt(WebCursor, try cursor.readByte()) orelse return error.UnknownCursor,
        } },
        .ime_range => .{ .ime_range = .{ .browser = try readBrowser(&cursor), .bounds = try readRect(&cursor) } },
        .url_changed => .{ .url_changed = .{ .browser = try readBrowser(&cursor), .url = try readUrl(&cursor) } },
        .nav_state => .{ .nav_state = .{
            .browser = try readBrowser(&cursor),
            .can_go_back = try readBool(&cursor),
            .can_go_forward = try readBool(&cursor),
            .loading = try readBool(&cursor),
        } },
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
    try std.testing.expectEqual(NavActionKind.reload, (try roundTrip(.{ .nav_action = .{ .browser = 9, .action = .reload } })).nav_action.action);
    try std.testing.expectEqualStrings("https://a.example/x", (try roundTrip(.{ .url_changed = .{ .browser = 9, .url = "https://a.example/x" } })).url_changed.url);
    const nav = (try roundTrip(.{ .nav_state = .{ .browser = 9, .can_go_back = true, .can_go_forward = false, .loading = true } })).nav_state;
    try std.testing.expect(nav.can_go_back and !nav.can_go_forward and nav.loading);
    try std.testing.expectEqual(FailureCode.gpu_unavailable, (try roundTrip(.{ .failure = .{ .browser = 9, .code = .gpu_unavailable, .detail = "" } })).failure.code);
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

    len = try encode(.{ .nav_action = .{ .browser = 1, .action = .stop } }, &buf);
    buf[body + 8] = 4;
    try std.testing.expectError(error.UnknownNavAction, decodeExact(buf[0..len]));

    len = try encode(.{ .nav_state = .{ .browser = 1, .can_go_back = false, .can_go_forward = false, .loading = false } }, &buf);
    for (0..3) |i| {
        var bad = buf;
        bad[body + 8 + i] = 2;
        try std.testing.expectError(error.InvalidBool, decodeExact(bad[0..len]));
    }

    // 주소 알림도 빈 URL·제어 문자를 거절한다(주소창에 그대로 그린다).
    try std.testing.expectError(error.EmptyUrl, encode(.{ .url_changed = .{ .browser = 1, .url = "" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .url_changed = .{ .browser = 1, .url = "https://x/\x1b[2J" } }, &buf));
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

test "url and text exactly at the cap decode, one byte of invalid UTF-8 or a control character does not" {
    var frame: [max_frame_bytes]u8 = undefined;
    var body: [max_frame_bytes]u8 = undefined;
    std.mem.writeInt(u64, body[0..8], 1, .big);

    std.mem.writeInt(u32, body[8..12], max_url_bytes, .big);
    @memset(body[12..][0..max_url_bytes], 'a');
    try std.testing.expectEqual(@as(usize, max_url_bytes), (try decodeExact(handFrame(&frame, .navigate, body[0 .. 12 + max_url_bytes]))).navigate.url.len);

    std.mem.writeInt(u32, body[8..12], max_text_bytes, .big);
    @memset(body[12..][0..max_text_bytes], 'a');
    try std.testing.expectEqual(@as(usize, max_text_bytes), (try decodeExact(handFrame(&frame, .title_changed, body[0 .. 12 + max_text_bytes]))).title_changed.text.len);

    std.mem.writeInt(u32, body[8..12], 2, .big);
    body[12] = 'a';
    body[13] = 0xFF;
    try std.testing.expectError(error.InvalidUtf8, decodeExact(handFrame(&frame, .navigate, body[0..14])));
    body[13] = 0x1b;
    try std.testing.expectError(error.ControlCharacter, decodeExact(handFrame(&frame, .navigate, body[0..14])));
    try std.testing.expectError(error.ControlCharacter, decodeExact(handFrame(&frame, .title_changed, body[0..14])));
    body[13] = 0x7f;
    try std.testing.expectError(error.ControlCharacter, decodeExact(handFrame(&frame, .title_changed, body[0..14])));
}

test "encode refuses invalid UTF-8 and control characters in url and text" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidUtf8, encode(.{ .navigate = .{ .browser = 1, .url = "a\xFF" } }, &buf));
    try std.testing.expectError(error.InvalidUtf8, encode(.{ .title_changed = .{ .browser = 1, .text = "a\xFF" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .navigate = .{ .browser = 1, .url = "http://x/\n" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .title_changed = .{ .browser = 1, .text = "\x1b]0;pwn\x07" } }, &buf));
}

test "view size edges: width at the cap and scale exactly 0.5 and 8.0 are accepted, just outside is not" {
    var buf: [128]u8 = undefined;
    for ([_]ViewSize{
        .{ .width = max_view_extent, .height = 1, .scale = 1 },
        .{ .width = 1, .height = 1, .scale = 0.5 },
        .{ .width = 1, .height = 1, .scale = 8.0 },
    }) |size| {
        const len = try encode(.{ .resize = .{ .browser = 1, .size = size } }, &buf);
        try std.testing.expectEqual(size, (try decodeExact(buf[0..len])).resize.size);
    }
    for ([_]ViewSize{
        .{ .width = max_view_extent + 1, .height = 1, .scale = 1 },
        .{ .width = 1, .height = 1, .scale = 0.49 },
        .{ .width = 1, .height = 1, .scale = 8.01 },
    }) |size| try std.testing.expectError(error.InvalidViewSize, encode(.{ .resize = .{ .browser = 1, .size = size } }, &buf));
}

test "a frame shorter than the length prefix is incomplete, not an out-of-bounds read" {
    try std.testing.expectError(error.IncompleteFrame, decodeExact(&[_]u8{ 0, 0, 0 }));
    try std.testing.expectError(error.IncompleteFrame, decodeExact(&[_]u8{}));
}

test "frame_channel carries the service name and the 128-bit token, and refuses odd names" {
    const token = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const got = try roundTrip(.{ .frame_channel = .{ .service = "dev.maru.web.123.abcdef", .token = token } });
    try std.testing.expectEqualStrings("dev.maru.web.123.abcdef", got.frame_channel.service);
    try std.testing.expectEqualSlices(u8, &token, &got.frame_channel.token);

    var buf: [256]u8 = undefined;
    const long = [_]u8{'a'} ** 128;
    for ([_][]const u8{ "", "has space", "탭\t", &long }) |bad| {
        try std.testing.expectError(error.InvalidServiceName, encode(.{ .frame_channel = .{ .service = bad, .token = token } }, &buf));
    }
    // 손으로 지은 frame 의 이름에 제어 문자가 섞이면 decode 도 거절한다.
    var frame: [256]u8 = undefined;
    const body = [_]u8{ 3, 'a', 0x01, 'b' } ++ [_]u8{0} ** 16;
    try std.testing.expectError(error.InvalidServiceName, decodeExact(handFrame(&frame, .frame_channel, &body)));
}

// ── 입력(W4) ─────────────────────────────────────────────────────────────────────────────────────────────

comptime {
    // 가장 큰 입력 frame(IME 조합 + IME 글 상한)도 frame 상한 안에 든다.
    std.debug.assert(prefix_len + common_len + 8 + 8 + 8 + 4 + max_ime_text_bytes <= max_frame_bytes);
}

test "input messages round trip" {
    const drag: message_mod.Mouse = .{ .browser = 7, .kind = .move, .point = .{ .x = -40, .y = 900 }, .modifiers = .{ .left_button = true, .shift = true } };
    const moved = (try roundTrip(.{ .mouse = drag })).mouse;
    try std.testing.expectEqual(drag, moved);
    const click: message_mod.Mouse = .{ .browser = 7, .kind = .down, .button = .right, .point = .{ .x = 10, .y = 20 }, .click_count = 2 };
    try std.testing.expectEqual(click, (try roundTrip(.{ .mouse = click })).mouse);

    const wheel: message_mod.Wheel = .{ .browser = 7, .point = .{ .x = 1, .y = 2 }, .delta_x = -3, .delta_y = 120, .modifiers = .{ .precise_scroll = true } };
    try std.testing.expectEqual(wheel, (try roundTrip(.{ .wheel = wheel })).wheel);

    // Ctrl+E: 제어 문자와 원 글자를 함께 싣는다.
    const key: message_mod.Key = .{ .browser = 7, .kind = .raw_down, .modifiers = .{ .control = true }, .windows_key_code = 'E', .native_key_code = 14, .character = 0x05, .unmodified_character = 'e' };
    try std.testing.expectEqual(key, (try roundTrip(.{ .key = key })).key);

    const composing = (try roundTrip(.{ .ime_set_composition = .{ .browser = 7, .text = "안", .selection = .{ .start = 1, .end = 1 } } })).ime_set_composition;
    try std.testing.expectEqualStrings("안", composing.text);
    try std.testing.expectEqual(@as(u32, 1), composing.selection.end);
    try std.testing.expect(composing.replacement.isNone());
    const committed = (try roundTrip(.{ .ime_commit_text = .{ .browser = 7, .text = "", .replacement = .{ .start = 0, .end = 2 } } })).ime_commit_text;
    try std.testing.expectEqualStrings("", committed.text);
    try std.testing.expectEqual(@as(u32, 2), committed.replacement.end);
    try std.testing.expect((try roundTrip(.{ .ime_finish_composing = .{ .browser = 7, .value = true } })).ime_finish_composing.value);
    try std.testing.expectEqual(@as(u64, 7), (try roundTrip(.{ .ime_cancel_composition = 7 })).ime_cancel_composition);
    try std.testing.expectEqual(@as(u64, 7), (try roundTrip(.{ .capture_lost = 7 })).capture_lost);
    try std.testing.expectEqual(EditCommandKind.select_all, (try roundTrip(.{ .edit_command = .{ .browser = 7, .command = .select_all } })).edit_command.command);

    try std.testing.expectEqual(WebCursor.ibeam, (try roundTrip(.{ .cursor_changed = .{ .browser = 7, .cursor = .ibeam } })).cursor_changed.cursor);
    const range: message_mod.ImeRange = .{ .browser = 7, .bounds = .{ .x = -2, .y = 30, .width = 16, .height = 18 } };
    try std.testing.expectEqual(range, (try roundTrip(.{ .ime_range = range })).ime_range);
}

test "input directions: commands go to the sidecar, cursor and ime range come back" {
    inline for (.{ Tag.mouse, Tag.wheel, Tag.key, Tag.ime_set_composition, Tag.ime_commit_text, Tag.ime_finish_composing, Tag.ime_cancel_composition, Tag.edit_command, Tag.capture_lost }) |tag|
        try std.testing.expectEqual(message_mod.Direction.to_sidecar, tag.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.cursor_changed.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.ime_range.direction());
}

test "input closed fields fail closed both ways" {
    var buf: [256]u8 = undefined;
    const body = prefix_len + common_len;
    const extent = message_mod.max_pointer_extent;

    // 정의되지 않은 수식자 비트.
    var bad_modifiers: message_mod.Modifiers = .{};
    bad_modifiers._reserved = 1;
    try std.testing.expectError(error.InvalidModifiers, encode(.{ .wheel = .{ .browser = 1, .point = .{ .x = 0, .y = 0 }, .delta_x = 0, .delta_y = 0, .modifiers = bad_modifiers } }, &buf));
    var len = try encode(.{ .key = .{ .browser = 1, .kind = .up } }, &buf);
    buf[body + 8 + 1] = 0x80; // 수식자 u16 의 높은 바이트 — 예약 비트
    try std.testing.expectError(error.InvalidModifiers, decodeExact(buf[0..len]));

    // 좌표·스크롤 양 상한(절댓값) — 경계는 받고 하나 넘으면 거절.
    _ = try encode(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = -extent, .y = extent } } }, &buf);
    try std.testing.expectError(error.InvalidCoordinate, encode(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = extent + 1, .y = 0 } } }, &buf));
    try std.testing.expectError(error.InvalidCoordinate, encode(.{ .wheel = .{ .browser = 1, .point = .{ .x = 0, .y = 0 }, .delta_x = 0, .delta_y = -extent - 1 } }, &buf));
    len = try encode(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = 0, .y = 0 } } }, &buf);
    std.mem.writeInt(i32, buf[body + 10 ..][0..4], std.math.minInt(i32), .big); // @abs 넘침 없이 거절
    try std.testing.expectError(error.InvalidCoordinate, decodeExact(buf[0..len]));

    // 클릭 수: down·up 은 1 이상(네 번 이상도 — macOS clickCount 그대로), move·leave 는 0.
    try std.testing.expectError(error.InvalidClickCount, encode(.{ .mouse = .{ .browser = 1, .kind = .down, .point = .{ .x = 0, .y = 0 } } }, &buf));
    try std.testing.expectError(error.InvalidClickCount, encode(.{ .mouse = .{ .browser = 1, .kind = .leave, .point = .{ .x = 0, .y = 0 }, .click_count = 1 } }, &buf));
    _ = try encode(.{ .mouse = .{ .browser = 1, .kind = .down, .point = .{ .x = 0, .y = 0 }, .click_count = 4 } }, &buf);
    len = try encode(.{ .mouse = .{ .browser = 1, .kind = .up, .point = .{ .x = 0, .y = 0 }, .click_count = 3 } }, &buf);
    buf[len - 1] = 0;
    try std.testing.expectError(error.InvalidClickCount, decodeExact(buf[0..len]));
    len = try encode(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = 0, .y = 0 } } }, &buf);
    buf[len - 1] = 1;
    try std.testing.expectError(error.InvalidClickCount, decodeExact(buf[0..len]));

    // 닫힌 enum.
    len = try encode(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = 0, .y = 0 } } }, &buf);
    var bad = buf;
    bad[body + 8] = 4;
    try std.testing.expectError(error.UnknownMouseKind, decodeExact(bad[0..len]));
    bad = buf;
    bad[body + 9] = 3;
    try std.testing.expectError(error.UnknownMouseButton, decodeExact(bad[0..len]));
    len = try encode(.{ .key = .{ .browser = 1, .kind = .char } }, &buf);
    buf[body + 8] = 4;
    try std.testing.expectError(error.UnknownKeyKind, decodeExact(buf[0..len]));
    len = try encode(.{ .edit_command = .{ .browser = 1, .command = .undo } }, &buf);
    buf[body + 8] = 8;
    try std.testing.expectError(error.UnknownEditCommand, decodeExact(buf[0..len]));
    len = try encode(.{ .cursor_changed = .{ .browser = 1, .cursor = .arrow } }, &buf);
    buf[body + 8] = 17;
    try std.testing.expectError(error.UnknownCursor, decodeExact(buf[0..len]));

    // 범위: 거꾸로·상한 밖은 거절, 「없음」은 받는다.
    try std.testing.expectError(error.InvalidRange, encode(.{ .ime_commit_text = .{ .browser = 1, .text = "a", .replacement = .{ .start = 2, .end = 1 } } }, &buf));
    try std.testing.expectError(error.InvalidRange, encode(.{ .ime_set_composition = .{ .browser = 1, .text = "a", .selection = .{ .start = 0, .end = max_ime_text_bytes + 1 } } }, &buf));
    // 바꿀 범위는 입력칸 전체 글 안의 위치라 글 상한과 무관하다(5000 자 입력칸 끝) — 반쪽 「없음」은 거절.
    _ = try encode(.{ .ime_commit_text = .{ .browser = 1, .text = "a", .replacement = .{ .start = 5000, .end = 5000 } } }, &buf);
    _ = try encode(.{ .ime_set_composition = .{ .browser = 1, .text = "a", .replacement = .{ .start = 70_000, .end = 70_002 } } }, &buf);
    try std.testing.expectError(error.InvalidRange, encode(.{ .ime_commit_text = .{ .browser = 1, .text = "a", .replacement = .{ .start = 3, .end = std.math.maxInt(u32) } } }, &buf));
    len = try encode(.{ .ime_set_composition = .{ .browser = 1, .text = "a" } }, &buf);
    std.mem.writeInt(u32, buf[body + 8 ..][0..4], 5, .big); // 「없음」의 한쪽만 바꿔 start 5 > end maxInt 아님 → 상한 밖
    try std.testing.expectError(error.InvalidRange, decodeExact(buf[0..len]));

    // IME 글: 탭·줄바꿈(받아쓰기)은 받고 다른 제어 문자는 거절한다. 상한은 제목보다 크다.
    try std.testing.expectError(error.ControlCharacter, encode(.{ .ime_commit_text = .{ .browser = 1, .text = "a\x1b" } }, &buf));
    try std.testing.expectEqualStrings("줄\n바꿈\t탭\r", (try roundTrip(.{ .ime_commit_text = .{ .browser = 1, .text = "줄\n바꿈\t탭\r" } })).ime_commit_text.text);
    const long_ime = [_]u8{'a'} ** (max_ime_text_bytes + 1);
    _ = try roundTrip(.{ .ime_commit_text = .{ .browser = 1, .text = long_ime[0..max_ime_text_bytes] } });
    var big: [max_frame_bytes]u8 = undefined;
    try std.testing.expectError(error.TextTooLarge, encode(.{ .ime_commit_text = .{ .browser = 1, .text = &long_ime } }, &big));

    // 사각형 크기 상한.
    try std.testing.expectError(error.InvalidCoordinate, encode(.{ .ime_range = .{ .browser = 1, .bounds = .{ .x = 0, .y = 0, .width = @as(u32, @intCast(extent)) + 1, .height = 1 } } }, &buf));
}

test "every single-byte corruption of input frames decodes to valid fields or errors" {
    // 입력 tag 모두(방향 둘) — 새 tag 를 더하면 여기에도 넣는다.
    const samples = [_]Message{
        .{ .mouse = .{ .browser = 3, .kind = .down, .button = .middle, .point = .{ .x = 5, .y = -6 }, .modifiers = .{ .command = true }, .click_count = 1 } },
        .{ .wheel = .{ .browser = 3, .point = .{ .x = 5, .y = 6 }, .delta_x = 7, .delta_y = -8 } },
        .{ .key = .{ .browser = 3, .kind = .char, .character = 'a', .unmodified_character = 'a' } },
        .{ .ime_set_composition = .{ .browser = 3, .text = "아", .selection = .{ .start = 0, .end = 1 } } },
        .{ .ime_commit_text = .{ .browser = 3, .text = "안\n", .replacement = .{ .start = 2, .end = 4 } } },
        .{ .ime_finish_composing = .{ .browser = 3, .value = true } },
        .{ .ime_cancel_composition = 3 },
        .{ .edit_command = .{ .browser = 3, .command = .paste } },
        .{ .capture_lost = 3 },
        .{ .cursor_changed = .{ .browser = 3, .cursor = .none } },
        .{ .ime_range = .{ .browser = 3, .bounds = .{ .x = 1, .y = 2, .width = 3, .height = 4 } } },
    };
    var encoded: [256]u8 = undefined;
    var corrupted: [256]u8 = undefined;
    for (samples) |sample| {
        const len = try encode(sample, &encoded);
        for (0..len) |i| for ([_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFF }) |value| {
            @memcpy(corrupted[0..len], encoded[0..len]);
            corrupted[i] = value;
            const message = decodeExact(corrupted[0..len]) catch continue;
            // 풀렸다면 다시 만들 수 있어야 한다 — encode 와 decode 가 같은 규칙을 지난다.
            var again: [256]u8 = undefined;
            _ = try encode(message, &again);
        };
    }
}
