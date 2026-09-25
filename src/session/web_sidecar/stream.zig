//! 웹 OSR sidecar 제어 채널의 스트리밍 decoder(W1a) — pipe 의 쪼개진·붙은 읽기에서 frame 경계를 복원하고
//! 거꾸로 온 frame 을 거절한다.

const std = @import("std");
const wire = @import("wire.zig");
const message_mod = @import("message.zig");
const codec = @import("codec.zig");

const Error = wire.Error;
const prefix_len = wire.prefix_len;
const max_frame_bytes = wire.max_frame_bytes;
const max_retained_bytes = wire.max_retained_bytes;
const Direction = message_mod.Direction;
const Message = message_mod.Message;
const decodeExact = codec.decodeExact;
const encode = codec.encode;

/// pipe 의 partial/concatenated read 를 받아 frame 경계를 복원하고, `direction` 이 아닌 frame 을 거절한다.
/// `next` 가 반환한 slice 는 다음 `feed`/`next` 전까지만 유효하다. 고정 저장소라 공격 입력에도 allocation 이 없다.
///
/// `feed` 는 **받을 수 있는 만큼만** 받고 그 수를 돌려준다 — 호출자는 `next` 로 frame 을 비운 뒤 나머지를 다시 넣는다.
/// 저장소가 가장 큰 frame 하나가 딱 들어가는 크기라, 가득 찼는데 frame 이 안 끝나는 일은 없다(선언 길이가 상한을 넘으면
/// `next` 가 거절한다). 조각을 통째로만 받던 판은 정상 스트림에서도 넘쳐 채널을 닫았다(적대 검증 — 반쯤 온 큰 frame 뒤에
/// 16KB 조각).
///
/// 오류가 한 번 나면 frame 경계를 믿을 수 없다 — 이후 `feed`·`next`·`finish` 는 모두 **같은 오류**를 돌려준다(잠김).
/// 받는 쪽은 채널을 닫는다(재동기화하지 않는다).
pub const StreamingDecoder = struct {
    direction: Direction,
    retained: [max_retained_bytes]u8 = undefined,
    len: usize = 0,
    delivered_len: usize = 0,
    failed: ?Error = null,

    pub fn init(direction: Direction) StreamingDecoder {
        return .{ .direction = direction };
    }

    /// 받은 바이트 수를 돌려준다(0 이면 먼저 `next` 로 비운다).
    pub fn feed(self: *StreamingDecoder, bytes: []const u8) Error!usize {
        if (self.failed) |err| return err;
        self.compactDelivered();
        const n = @min(bytes.len, self.retained.len - self.len);
        @memcpy(self.retained[self.len..][0..n], bytes[0..n]);
        self.len += n;
        return n;
    }

    pub fn next(self: *StreamingDecoder) Error!?Message {
        if (self.failed) |err| return err;
        return self.decodeNext() catch |err| {
            self.failed = err;
            return err;
        };
    }

    fn decodeNext(self: *StreamingDecoder) Error!?Message {
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
        if (self.failed) |err| return err;
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

test "streaming decoder accepts one-byte reads and concatenated frames" {
    var first: [64]u8 = undefined;
    var second: [64]u8 = undefined;
    const first_len = try encode(.{ .browser_created = 5 }, &first);
    const second_len = try encode(.{ .title_changed = .{ .browser = 5, .text = "제목" } }, &second);

    var decoder = StreamingDecoder.init(.to_maru);
    for (first[0..first_len], 0..) |byte, i| {
        try std.testing.expectEqual(@as(usize, 1), try decoder.feed(&.{byte}));
        const maybe = try decoder.next();
        if (i + 1 < first_len) try std.testing.expect(maybe == null) else try std.testing.expectEqual(@as(u64, 5), maybe.?.browser_created);
    }
    var combined: [128]u8 = undefined;
    @memcpy(combined[0..second_len], second[0..second_len]);
    @memcpy(combined[second_len..][0..first_len], first[0..first_len]);
    _ = try decoder.feed(combined[0 .. second_len + first_len]);
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
    _ = try at_maru.feed(encoded[0..command_len]);
    try std.testing.expectError(error.WrongDirection, at_maru.next());

    const event_len = try encode(.{ .browser_closed = 1 }, &encoded);
    var at_sidecar = StreamingDecoder.init(.to_sidecar);
    _ = try at_sidecar.feed(encoded[0..event_len]);
    try std.testing.expectError(error.WrongDirection, at_sidecar.next());
}

test "streaming decoder rejects oversized declaration and EOF mid-frame" {
    var decoder = StreamingDecoder.init(.to_sidecar);
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, max_frame_bytes, .big);
    _ = try decoder.feed(&prefix);
    try std.testing.expectError(error.FrameTooLarge, decoder.next());

    decoder = StreamingDecoder.init(.to_sidecar);
    var encoded: [64]u8 = undefined;
    const len = try encode(.{ .destroy_browser = 1 }, &encoded);
    _ = try decoder.feed(encoded[0 .. len - 1]);
    try std.testing.expect((try decoder.next()) == null);
    try std.testing.expectError(error.IncompleteFrame, decoder.finish());
}

/// 읽기 루프가 하는 일 — 받은 만큼 넣고, 다 풀고, 나머지를 넣는다. 풀린 메시지 수를 센다.
fn feedAll(decoder: *StreamingDecoder, bytes: []const u8, count: *usize) Error!void {
    var rest = bytes;
    while (true) {
        const n = try decoder.feed(rest);
        rest = rest[n..];
        while (try decoder.next()) |_| count.* += 1;
        if (rest.len == 0) return;
        // frame 을 다 비웠는데도 한 바이트도 못 넣으면 진행이 멈춘 것이다 — 저장소 크기 불변식이 깨졌다.
        if (n == 0) return error.IncompleteFrame;
    }
}

fn maxCreateFrame(buf: []u8, url_byte: u8) ![]const u8 {
    const url = [_]u8{url_byte} ** wire.max_url_bytes;
    const len = try encode(.{ .create_browser = .{ .browser = 1, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false, .url = &url } }, buf);
    return buf[0..len];
}

test "the largest frame is exactly max_frame_bytes and fits the retained store" {
    var buf: [max_frame_bytes]u8 = undefined;
    const frame = try maxCreateFrame(&buf, 'a');
    try std.testing.expectEqual(max_frame_bytes, frame.len);
    var decoder = StreamingDecoder.init(.to_sidecar);
    try std.testing.expectEqual(frame.len, try decoder.feed(frame));
    try std.testing.expectEqual(@as(usize, wire.max_url_bytes), (try decoder.next()).?.create_browser.url.len);
}

test "two largest frames in 4 KiB pieces stream through a full store without overflow" {
    var a: [max_frame_bytes]u8 = undefined;
    var b: [max_frame_bytes]u8 = undefined;
    const first = try maxCreateFrame(&a, 'a');
    const second = try maxCreateFrame(&b, 'b');
    var stream: [2 * max_frame_bytes]u8 = undefined;
    @memcpy(stream[0..first.len], first);
    @memcpy(stream[first.len..][0..second.len], second);
    var decoder = StreamingDecoder.init(.to_sidecar);
    var count: usize = 0;
    var at: usize = 0;
    while (at < stream.len) : (at += 4096) try feedAll(&decoder, stream[at..@min(at + 4096, stream.len)], &count);
    try std.testing.expectEqual(@as(usize, 2), count);
    try decoder.finish();
}

test "64 KiB of small frames in one read is taken in parts, never refused" {
    var frame: [64]u8 = undefined;
    const len = try encode(.{ .browser_created = 9 }, &frame);
    var read: [64 * 1024]u8 = undefined;
    var filled: usize = 0;
    while (filled + len <= read.len) : (filled += len) @memcpy(read[filled..][0..len], frame[0..len]);
    var decoder = StreamingDecoder.init(.to_maru);
    var count: usize = 0;
    try feedAll(&decoder, read[0..filled], &count);
    try std.testing.expectEqual(filled / len, count);
}

test "a short frame followed by a longer one in the same read both decode (overlapping compaction)" {
    var a: [64]u8 = undefined;
    var b: [128]u8 = undefined;
    const a_len = try encode(.{ .browser_created = 3 }, &a);
    const b_len = try encode(.{ .title_changed = .{ .browser = 3, .text = "twenty characters!!!" } }, &b);
    var both: [192]u8 = undefined;
    @memcpy(both[0..a_len], a[0..a_len]);
    @memcpy(both[a_len..][0..b_len], b[0..b_len]);
    var decoder = StreamingDecoder.init(.to_maru);
    _ = try decoder.feed(both[0 .. a_len + b_len]);
    try std.testing.expectEqual(@as(u64, 3), (try decoder.next()).?.browser_created);
    try std.testing.expectEqualStrings("twenty characters!!!", (try decoder.next()).?.title_changed.text);
}

test "a declared length one past the largest frame is refused before any body arrives" {
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(max_frame_bytes - prefix_len + 1), .big);
    var decoder = StreamingDecoder.init(.to_sidecar);
    _ = try decoder.feed(&prefix);
    try std.testing.expectError(error.FrameTooLarge, decoder.next());
}

test "end of stream inside the length prefix is an incomplete frame" {
    for (1..prefix_len) |cut| {
        var decoder = StreamingDecoder.init(.to_maru);
        const zeros = [_]u8{0} ** prefix_len;
        _ = try decoder.feed(zeros[0..cut]);
        try std.testing.expect((try decoder.next()) == null);
        try std.testing.expectError(error.IncompleteFrame, decoder.finish());
    }
}

test "after an error the decoder stays failed — feed, next and finish all repeat it" {
    var encoded: [64]u8 = undefined;
    const len = try encode(.{ .destroy_browser = 1 }, &encoded);
    var decoder = StreamingDecoder.init(.to_maru);
    _ = try decoder.feed(encoded[0..len]);
    try std.testing.expectError(error.WrongDirection, decoder.next());
    try std.testing.expectError(error.WrongDirection, decoder.next());
    try std.testing.expectError(error.WrongDirection, decoder.feed(encoded[0..len]));
    try std.testing.expectError(error.WrongDirection, decoder.finish());
}
