//! 웹 OSR sidecar(`maru-web-host`) 제어 채널의 단일 codec(W1a).
//!
//! maru 는 sidecar 를 spawn 하고 그 stdin 으로 명령을, stdout 으로 알림을 받는다(Mermaid helper 와 같은 틀 —
//! docs/plans/web-osr-backend.md C2). 픽셀은 이 채널을 지나지 않는다(C3 — IOSurface). 양쪽은 이 모듈이
//! encode/decode 한 frame 만 운반해야 endian·상한·닫힌 enum 판단이 한 곳에 남는다.
//!
//! sidecar 는 신뢰할 수 없는 웹을 띄우는 프로세스 트리의 뿌리라, maru 쪽 decoder 는 sidecar 가 보낸 바이트를
//! 공격 입력으로 다룬다 — 고정 저장소, 상한 초과·방향 위반·닫힌 필드 위반은 전부 거절한다.

const std = @import("std");

pub const magic = "MWEB".*;
/// maru 와 sidecar 는 따로 설치될 수 있다(D8 — formula 가 sidecar 만 올릴 수 있다). 그래서 Mermaid 처럼
/// 「항상 같은 버전」을 전제하지 않고, 버전이 다르면 첫 frame(hello)에서 `UnsupportedVersion` 으로 드러난다.
pub const version: u16 = 1;

/// maru 가 보내는 URL 상한. 사용자가 친 주소·링크를 싣는 자리라 이 크기면 넉넉하고, 고정 decoder 저장소를
/// 작게 둔다. 이보다 긴 URL(큰 data: URL 등)은 maru 가 보내지 않는다.
pub const max_url_bytes: usize = 32 * 1024;
/// sidecar 가 보내는 글(제목·실패 설명) 상한. sidecar 는 `clampUtf8` 로 잘라서 보낸다.
pub const max_text_bytes: usize = 4 * 1024;
pub const max_frame_bytes: usize = 34 * 1024;
pub const max_retained_bytes: usize = max_frame_bytes + prefix_len;

/// view 크기 상한(DIP). 5K 화면 전체의 두 배를 넘는 view 는 없다.
pub const max_view_extent: u32 = 16 * 1024;
pub const min_scale: f32 = 0.5;
pub const max_scale: f32 = 8.0;

const prefix_len = 4;
const common_len = magic.len + @sizeOf(u16) + @sizeOf(u8);

/// 0~31 은 maru → sidecar, 32~ 는 sidecar → maru. 받는 쪽은 `StreamingDecoder` 의 방향으로 거꾸로 온
/// frame 을 거절한다.
pub const Tag = enum(u8) {
    hello = 0,
    create_browser = 1,
    destroy_browser = 2,
    resize = 3,
    set_hidden = 4,
    set_focus = 5,
    navigate = 6,
    shutdown = 7,

    hello_ack = 32,
    browser_created = 33,
    browser_closed = 34,
    title_changed = 35,
    load_finished = 36,
    renderer_gone = 37,
    failure = 38,

    pub fn direction(self: Tag) Direction {
        return if (@intFromEnum(self) < 32) .to_sidecar else .to_maru;
    }
};

pub const Direction = enum { to_sidecar, to_maru };

pub const RendererGoneReason = enum(u8) {
    abnormal = 0,
    killed = 1,
    crashed = 2,
    out_of_memory = 3,
    launch_failed = 4,
};

pub const FailureCode = enum(u8) {
    /// 같은 프로필을 다른 프로세스가 쥐고 있다(CEF process singleton — §13.1 exit 24).
    profile_in_use = 0,
    cef_initialize_failed = 1,
    browser_create_failed = 2,
    unknown_browser = 3,
    duplicate_browser = 4,
    /// sidecar 가 maru 의 frame 을 풀지 못했다. 이 뒤 sidecar 는 채널을 닫는다.
    protocol_violation = 5,
};

pub const BrowserId = u64;

pub const Hello = struct {
    instance: u64,
    nonce: u64,
};

pub const ViewSize = struct {
    width: u32,
    height: u32,
    scale: f32,
};

pub const CreateBrowser = struct {
    browser: BrowserId,
    size: ViewSize,
    hidden: bool,
    url: []const u8,
};

pub const Resize = struct {
    browser: BrowserId,
    size: ViewSize,
};

pub const BrowserFlag = struct {
    browser: BrowserId,
    value: bool,
};

pub const Navigate = struct {
    browser: BrowserId,
    url: []const u8,
};

pub const BrowserText = struct {
    browser: BrowserId,
    text: []const u8,
};

pub const LoadFinished = struct {
    browser: BrowserId,
    http_status: i32,
};

pub const RendererGone = struct {
    browser: BrowserId,
    reason: RendererGoneReason,
};

/// `browser` 가 0 이면 브라우저에 묶이지 않은 실패(초기화·프로필)다.
pub const Failure = struct {
    browser: BrowserId,
    code: FailureCode,
    detail: []const u8,
};

pub const Message = union(Tag) {
    hello: Hello,
    create_browser: CreateBrowser,
    destroy_browser: BrowserId,
    resize: Resize,
    set_hidden: BrowserFlag,
    set_focus: BrowserFlag,
    navigate: Navigate,
    shutdown: void,

    hello_ack: Hello,
    browser_created: BrowserId,
    browser_closed: BrowserId,
    title_changed: BrowserText,
    load_finished: LoadFinished,
    renderer_gone: RendererGone,
    failure: Failure,
};

pub const Error = error{
    OutputTooSmall,
    FrameTooLarge,
    UrlTooLarge,
    EmptyUrl,
    TextTooLarge,
    InvalidUtf8,
    InvalidMagic,
    UnsupportedVersion,
    UnknownTag,
    WrongDirection,
    UnknownReason,
    UnknownFailureCode,
    InvalidBool,
    InvalidBrowserId,
    InvalidViewSize,
    InvalidLength,
    TrailingBytes,
    RetainedInputOverflow,
    IncompleteFrame,
};

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

/// pipe 의 partial/concatenated read 를 받아 frame 경계를 복원하고, `direction` 이 아닌 frame 을 거절한다.
/// `next` 가 반환한 slice 는 다음 `feed`/`next` 전까지만 유효하다. 고정 저장소라 공격 입력에도 allocation 이 없다.
/// 오류가 한 번 나면 frame 경계를 믿을 수 없으므로 받는 쪽은 **채널을 닫는다**(재동기화하지 않는다).
pub const StreamingDecoder = struct {
    direction: Direction,
    retained: [max_retained_bytes]u8 = undefined,
    len: usize = 0,
    delivered_len: usize = 0,

    pub fn init(direction: Direction) StreamingDecoder {
        return .{ .direction = direction };
    }

    pub fn feed(self: *StreamingDecoder, bytes: []const u8) Error!void {
        self.compactDelivered();
        if (bytes.len > self.retained.len - self.len) return error.RetainedInputOverflow;
        @memcpy(self.retained[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn next(self: *StreamingDecoder) Error!?Message {
        self.compactDelivered();
        if (self.len < prefix_len) return null;
        const payload_len = std.mem.readInt(u32, self.retained[0..prefix_len], .big);
        const total_len = std.math.add(usize, prefix_len, payload_len) catch return error.FrameTooLarge;
        if (total_len > max_frame_bytes) return error.FrameTooLarge;
        if (self.len < total_len) return null;
        const message = try decodeExact(self.retained[0..total_len]);
        if (std.meta.activeTag(message).direction() != self.direction) return error.WrongDirection;
        self.delivered_len = total_len;
        return message;
    }

    /// 채널이 닫혔을 때 부른다. frame 중간에서 끊겼으면 `IncompleteFrame`.
    pub fn finish(self: *StreamingDecoder) Error!void {
        self.compactDelivered();
        if (self.len != 0) return error.IncompleteFrame;
    }

    fn compactDelivered(self: *StreamingDecoder) void {
        if (self.delivered_len == 0) return;
        const remaining = self.len - self.delivered_len;
        std.mem.copyForwards(u8, self.retained[0..remaining], self.retained[self.delivered_len..self.len]);
        self.len = remaining;
        self.delivered_len = 0;
    }
};

/// `text` 를 `max` 바이트 안의 가장 긴 UTF-8 접두로 자른다(글자 중간에서 자르지 않는다). sidecar 가 페이지
/// 제목처럼 길이를 통제할 수 없는 글을 `max_text_bytes` 로 줄일 때 쓴다. `text` 는 유효한 UTF-8 이어야 한다.
pub fn clampUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    // 이어지는 바이트(10xxxxxx) 위에서 끝나지 않게, 글자의 첫 바이트까지 물러난다.
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

fn writeBrowser(cursor: *Cursor, browser: BrowserId) Error!void {
    if (browser == 0) return error.InvalidBrowserId;
    try cursor.writeU64(browser);
}

fn readBrowser(cursor: *ReadCursor) Error!BrowserId {
    const browser = try cursor.readU64();
    if (browser == 0) return error.InvalidBrowserId;
    return browser;
}

fn validSize(size: ViewSize) bool {
    if (size.width == 0 or size.width > max_view_extent) return false;
    if (size.height == 0 or size.height > max_view_extent) return false;
    // NaN 은 두 비교가 모두 거짓이라 여기서 걸린다.
    return size.scale >= min_scale and size.scale <= max_scale;
}

fn writeSize(cursor: *Cursor, size: ViewSize) Error!void {
    if (!validSize(size)) return error.InvalidViewSize;
    try cursor.writeU32(size.width);
    try cursor.writeU32(size.height);
    try cursor.writeU32(@bitCast(size.scale));
}

fn readSize(cursor: *ReadCursor) Error!ViewSize {
    const size: ViewSize = .{
        .width = try cursor.readU32(),
        .height = try cursor.readU32(),
        .scale = @bitCast(try cursor.readU32()),
    };
    if (!validSize(size)) return error.InvalidViewSize;
    return size;
}

fn readBool(cursor: *ReadCursor) Error!bool {
    return switch (try cursor.readByte()) {
        0 => false,
        1 => true,
        else => error.InvalidBool,
    };
}

fn readHello(cursor: *ReadCursor) Error!Hello {
    return .{ .instance = try cursor.readU64(), .nonce = try cursor.readU64() };
}

fn writeUrl(cursor: *Cursor, url: []const u8) Error!void {
    if (url.len == 0) return error.EmptyUrl;
    if (url.len > max_url_bytes) return error.UrlTooLarge;
    if (!std.unicode.utf8ValidateSlice(url)) return error.InvalidUtf8;
    try cursor.writeU32(@intCast(url.len));
    try cursor.writeBytes(url);
}

fn readUrl(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readU32();
    if (len == 0) return error.EmptyUrl;
    if (len > max_url_bytes) return error.UrlTooLarge;
    const url = try cursor.readBytes(len);
    if (!std.unicode.utf8ValidateSlice(url)) return error.InvalidUtf8;
    return url;
}

fn writeText(cursor: *Cursor, text: []const u8) Error!void {
    if (text.len > max_text_bytes) return error.TextTooLarge;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    try cursor.writeU32(@intCast(text.len));
    try cursor.writeBytes(text);
}

fn readText(cursor: *ReadCursor) Error![]const u8 {
    const len = try cursor.readU32();
    if (len > max_text_bytes) return error.TextTooLarge;
    const text = try cursor.readBytes(len);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return text;
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
        (try self.reserve(1))[0] = value;
    }

    fn writeU16(self: *Cursor, value: u16) Error!void {
        std.mem.writeInt(u16, (try self.reserve(2))[0..2], value, .big);
    }

    fn writeU32(self: *Cursor, value: u32) Error!void {
        std.mem.writeInt(u32, (try self.reserve(4))[0..4], value, .big);
    }

    fn writeU64(self: *Cursor, value: u64) Error!void {
        std.mem.writeInt(u64, (try self.reserve(8))[0..8], value, .big);
    }

    fn writeBytes(self: *Cursor, value: []const u8) Error!void {
        @memcpy(try self.reserve(value.len), value);
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

test "tags split by direction at 32" {
    inline for (std.meta.fields(Tag)) |field| {
        const tag: Tag = @enumFromInt(field.value);
        const expected: Direction = if (field.value < 32) .to_sidecar else .to_maru;
        try std.testing.expectEqual(expected, tag.direction());
    }
}

test "streaming decoder accepts one-byte reads and concatenated frames" {
    var first: [64]u8 = undefined;
    var second: [64]u8 = undefined;
    const first_len = try encode(.{ .browser_created = 5 }, &first);
    const second_len = try encode(.{ .title_changed = .{ .browser = 5, .text = "제목" } }, &second);

    var decoder = StreamingDecoder.init(.to_maru);
    for (first[0..first_len], 0..) |byte, i| {
        try decoder.feed(&.{byte});
        const maybe = try decoder.next();
        if (i + 1 < first_len) try std.testing.expect(maybe == null) else try std.testing.expectEqual(@as(u64, 5), maybe.?.browser_created);
    }
    var combined: [128]u8 = undefined;
    @memcpy(combined[0..second_len], second[0..second_len]);
    @memcpy(combined[second_len..][0..first_len], first[0..first_len]);
    try decoder.feed(combined[0 .. second_len + first_len]);
    try std.testing.expectEqualStrings("제목", (try decoder.next()).?.title_changed.text);
    try std.testing.expectEqual(@as(u64, 5), (try decoder.next()).?.browser_created);
    try std.testing.expect((try decoder.next()) == null);
    try decoder.finish();
}

test "streaming decoder rejects frames travelling the wrong way" {
    var encoded: [64]u8 = undefined;
    // sidecar 가 maru 에게 명령을 보내는 척하면 maru 쪽 decoder 가 거절한다 — 그 반대도.
    const command_len = try encode(.{ .destroy_browser = 1 }, &encoded);
    var at_maru = StreamingDecoder.init(.to_maru);
    try at_maru.feed(encoded[0..command_len]);
    try std.testing.expectError(error.WrongDirection, at_maru.next());

    const event_len = try encode(.{ .browser_closed = 1 }, &encoded);
    var at_sidecar = StreamingDecoder.init(.to_sidecar);
    try at_sidecar.feed(encoded[0..event_len]);
    try std.testing.expectError(error.WrongDirection, at_sidecar.next());
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

test "streaming decoder rejects oversized declaration and EOF mid-frame" {
    var decoder = StreamingDecoder.init(.to_sidecar);
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, max_frame_bytes, .big);
    try decoder.feed(&prefix);
    try std.testing.expectError(error.FrameTooLarge, decoder.next());

    decoder = StreamingDecoder.init(.to_sidecar);
    var encoded: [64]u8 = undefined;
    const len = try encode(.{ .destroy_browser = 1 }, &encoded);
    try decoder.feed(encoded[0 .. len - 1]);
    try std.testing.expect((try decoder.next()) == null);
    try std.testing.expectError(error.IncompleteFrame, decoder.finish());
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

test "clampUtf8 never splits a character" {
    try std.testing.expectEqualStrings("abc", clampUtf8("abc", 8));
    try std.testing.expectEqualStrings("가", clampUtf8("가나", 5)); // 한글은 3바이트 — 5 에서 자르면 둘째 글자 중간
    try std.testing.expectEqualStrings("가나", clampUtf8("가나", 6));
    try std.testing.expectEqualStrings("", clampUtf8("가", 2));
    const long = "제목" ** 1000;
    const clamped = clampUtf8(long, max_text_bytes);
    try std.testing.expect(clamped.len <= max_text_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clamped));
}
