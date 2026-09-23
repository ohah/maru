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
