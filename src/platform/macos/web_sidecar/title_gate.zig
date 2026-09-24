//! 브라우저 하나의 제목 알림 조절(W1c). 페이지는 `document.title` 을 제한 없이 바꿀 수 있어 — 적대 검증에서 3 초에
//! 제목 알림 약 16 만 건 — 알림 채널과 maru 의 UI 스레드를 범람시켰다. 그래서 같은 제목은 다시 보내지 않고,
//! `min_interval_ms` 안에 온 제목은 마지막 것 하나만 쥐었다가 간격이 차면 보낸다(마지막 제목은 버리지 않는다).
//! CEF 를 모른다 — 시각은 호출자가 준다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

/// 브라우저당 제목 알림 간격의 하한. 초당 20 번이면 제목으로 진행률·알림 수를 보이는 페이지도 따라간다.
pub const min_interval_ms: u64 = 50;

pub const Offer = enum {
    /// 지금 보낸다 — `pending()` 이 아니라 넘긴 글을 보낸다.
    send,
    /// 쥐었다 — 호출자는 `flushAt()` 에 `flush` 가 불리게 한다.
    held,
    /// 마지막으로 보낸 제목과 같다.
    duplicate,
};

pub const TitleGate = struct {
    sent_hash: ?u64 = null,
    sent_at_ms: u64 = 0,
    held: [protocol.wire.max_text_bytes]u8 = undefined,
    held_len: ?usize = null,

    pub fn offer(self: *TitleGate, text: []const u8, now_ms: u64) Offer {
        const hash = std.hash.Wyhash.hash(0, text);
        if (self.sent_hash == hash) {
            // 쥐고 있던 다른 제목이 이 제목으로 되돌아왔다 — 보낼 것이 없다.
            self.held_len = null;
            return .duplicate;
        }
        if (self.sent_hash == null or now_ms -| self.sent_at_ms >= min_interval_ms) {
            // 새 제목이 나가면 쥐었던 것은 낡았다.
            self.held_len = null;
            self.markSent(hash, now_ms);
            return .send;
        }
        const len = @min(text.len, self.held.len);
        @memcpy(self.held[0..len], text[0..len]);
        self.held_len = len;
        return .held;
    }

    /// 쥔 제목이 있으면 보낼 수 있는 시각.
    pub fn flushAt(self: *const TitleGate) ?u64 {
        if (self.held_len == null) return null;
        return self.sent_at_ms + min_interval_ms;
    }

    /// 간격이 찼으면 쥔 제목을 내준다(보낸 것으로 친다). 아직이면 null — 호출자는 `flushAt()` 에 다시 부른다.
    pub fn flush(self: *TitleGate, now_ms: u64) ?[]const u8 {
        const len = self.held_len orelse return null;
        if (now_ms -| self.sent_at_ms < min_interval_ms) return null;
        self.held_len = null;
        self.markSent(std.hash.Wyhash.hash(0, self.held[0..len]), now_ms);
        return self.held[0..len];
    }

    fn markSent(self: *TitleGate, hash: u64, now_ms: u64) void {
        self.sent_hash = hash;
        self.sent_at_ms = now_ms;
    }
};

test "the first title goes out, a repeat is dropped, a burst keeps only its last title" {
    var gate: TitleGate = .{};
    try std.testing.expectEqual(Offer.send, gate.offer("a", 1000));
    try std.testing.expectEqual(Offer.duplicate, gate.offer("a", 2000));
    try std.testing.expectEqual(Offer.send, gate.offer("b", 2000));
    // 간격 안의 연속 변경 — 모두 쥐고 마지막 것만 남는다.
    try std.testing.expectEqual(Offer.held, gate.offer("c", 2001));
    try std.testing.expectEqual(Offer.held, gate.offer("d", 2049));
    try std.testing.expectEqual(@as(?u64, 2050), gate.flushAt());
    try std.testing.expect(gate.flush(2049) == null);
    try std.testing.expectEqualStrings("d", gate.flush(2050).?);
    try std.testing.expect(gate.flush(3000) == null);
    try std.testing.expect(gate.flushAt() == null);
    // 막 보낸 제목과 같은 제목은 간격과 상관없이 다시 안 보낸다.
    try std.testing.expectEqual(Offer.duplicate, gate.offer("d", 2051));
}

test "a held title that changes back to the sent one is dropped, and the interval boundary is inclusive" {
    var gate: TitleGate = .{};
    try std.testing.expectEqual(Offer.send, gate.offer("x", 0));
    try std.testing.expectEqual(Offer.held, gate.offer("y", 10));
    try std.testing.expectEqual(Offer.duplicate, gate.offer("x", 20));
    try std.testing.expect(gate.flushAt() == null);
    try std.testing.expect(gate.flush(1000) == null);
    try std.testing.expectEqual(Offer.held, gate.offer("z", min_interval_ms - 1));
    try std.testing.expectEqual(Offer.send, gate.offer("w", min_interval_ms));
    // 간격이 차서 새 제목을 바로 보냈으면 쥐었던 것은 낡았다 — 내주지 않는다.
    try std.testing.expect(gate.flush(min_interval_ms * 3) == null);
}
