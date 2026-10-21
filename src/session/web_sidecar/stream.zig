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
    const url = @as([wire.max_url_bytes]u8, @splat(url_byte));
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
        const zeros = @as([prefix_len]u8, @splat(0));
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

// ── W9d② 적대 검증 11 회차(v20b): 본문 frame 의 관 위 모양 ─────────────────────────────────────────────────────────
// 증명하는 것: 본문 조각·끝을 아무 크기로 쪼개 읽어도 같은 차례로 풀린다(대조). 거꾸로 온 본문 frame(maru 가 net_record 를 받음·sidecar 가
// net_body_data 를 받음)은 WrongDirection 으로 채널을 잠근다. 본문 frame 을 어디서 잘라도 무너지지 않고 IncompleteFrame 이다. 조각 길이 칸이
// 16 KiB 를 넘으면 frame 이 그 길이만큼 실제로 실어도 거절한다. 본문 상한 경계(끝 = 1 MiB 는 받고 1 MiB + 1 은 거절 — u32 오프셋 넘침 포함),
// 풀어 낸 크기 i64 경계, 모르는 상태·기록 상태(14·255, 4·255), net_begin 둘째 표시의 쓰지 않는 비트 일곱, 뒤에 붙은 바이트.

test "W9d② v20b 11 회차: 본문 frame — 아무 크기로 쪼개 읽어도 같은 차례, 거꾸로 온 본문 frame 은 잠금, 어디서 잘라도 IncompleteFrame" {
    const net_body_chunk_bytes = message_mod.net_body_chunk_bytes;
    var big: [net_body_chunk_bytes]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    const seq = [_]Message{
        .{ .net_record_state = .{ .browser = 9, .session = 3, .status = .on } },
        .{ .net_body_data = .{ .browser = 9, .session = 3, .request = 77, .offset = 0, .bytes = &big } },
        .{ .net_body_data = .{ .browser = 9, .session = 3, .request = 77, .offset = net_body_chunk_bytes, .bytes = big[0..5] } },
        .{ .net_body_end = .{ .browser = 9, .session = 3, .request = 77, .state = .captured, .size = net_body_chunk_bytes + 5, .decoded = net_body_chunk_bytes + 5 } },
        .{ .net_body_end = .{ .browser = 9, .session = 3, .request = 78, .state = .over_cap, .decoded = 5 << 20 } },
    };
    var stream: [4 * max_frame_bytes]u8 = undefined;
    var n: usize = 0;
    for (seq) |m| n += try encode(m, stream[n..]);
    var prng = std.Random.DefaultPrng.init(0x20b11);
    const r = prng.random();
    for (0..300) |_| {
        var d = StreamingDecoder.init(.to_maru);
        var at: usize = 0;
        var got: usize = 0;
        while (at < n or got < seq.len) {
            if (at < n) {
                const piece = @min(n - at, r.intRangeAtMost(usize, 1, 40_000));
                at += try d.feed(stream[at..][0..piece]);
            }
            while (try d.next()) |m| : (got += 1) {
                try std.testing.expectEqual(std.meta.activeTag(seq[got]), std.meta.activeTag(m));
                switch (m) {
                    .net_body_data => |v| try std.testing.expectEqualSlices(u8, seq[got].net_body_data.bytes, v.bytes),
                    .net_body_end => |v| try std.testing.expectEqual(seq[got].net_body_end.state, v.state),
                    else => {},
                }
            }
        }
        try std.testing.expectEqual(seq.len, got);
        try d.finish();
    }
    // 거꾸로 온 본문 frame.
    var buf: [max_frame_bytes]u8 = undefined;
    var len = try encode(.{ .net_record = .{ .browser = 9, .on = true, .session = 4 } }, &buf);
    var at_maru = StreamingDecoder.init(.to_maru);
    _ = try at_maru.feed(buf[0..len]);
    try std.testing.expectError(error.WrongDirection, at_maru.next());
    for ([_]Message{ seq[0], seq[1], seq[3] }) |m| {
        len = try encode(m, &buf);
        var at_sidecar = StreamingDecoder.init(.to_sidecar);
        _ = try at_sidecar.feed(buf[0..len]);
        try std.testing.expectError(error.WrongDirection, at_sidecar.next());
    }
    // 어디서 잘라도: 앞부분만 오고 관이 닫히면 IncompleteFrame — 풀린 값 없음.
    len = try encode(seq[1], &buf);
    var cut: usize = 1;
    while (cut < len) : (cut += 97) {
        var d = StreamingDecoder.init(.to_maru);
        _ = try d.feed(buf[0..cut]);
        try std.testing.expect((try d.next()) == null);
        try std.testing.expectError(error.IncompleteFrame, d.finish());
    }
    // 같은 frame 의 decodeExact: 하나 모자람·하나 남음.
    try std.testing.expectError(error.IncompleteFrame, decodeExact(buf[0 .. len - 1]));
    var longer: [max_frame_bytes + 1]u8 = undefined;
    @memcpy(longer[0..len], buf[0..len]);
    longer[len] = 0;
    try std.testing.expectError(error.TrailingBytes, decodeExact(longer[0 .. len + 1]));
}

test "W9d② v20b 11 회차: 본문 칸의 경계 — 조각 길이 16 KiB+1 을 실제로 실은 frame, 본문 상한 1 MiB 의 끝(u32 넘침), 풀어 낸 크기 i64, 모르는 상태 값, 둘째 표시의 쓰지 않는 비트" {
    const body = wire.prefix_len + wire.common_len;
    var buf: [max_frame_bytes]u8 = undefined;
    // 조각 길이 칸 16 385 이고 frame 이 그만큼 싣는다(길이가 맞아도 상한).
    {
        var len = try encode(.{ .net_body_data = .{ .browser = 1, .session = 1, .request = 2, .offset = 0, .bytes = "ab" } }, &buf);
        const over = message_mod.net_body_chunk_bytes + 1;
        std.mem.writeInt(u16, buf[body + 24 ..][0..2], over, .big);
        @memset(buf[body + 26 ..][0..over], 'x');
        len = body + 26 + over;
        std.mem.writeInt(u32, buf[0..4], @intCast(len - 4), .big);
        try std.testing.expectError(error.InvalidNetwork, decodeExact(buf[0..len]));
        // 대조: 16 384 는 받는다.
        std.mem.writeInt(u16, buf[body + 24 ..][0..2], over - 1, .big);
        std.mem.writeInt(u32, buf[0..4], @intCast(len - 5), .big);
        _ = try decodeExact(buf[0 .. len - 1]);
    }
    // 본문 상한: 끝 = 1 MiB 는 받고, 1 MiB + 1 · u32 끝의 오프셋은 거절(u32 덧셈이 넘쳐 0 근처로 돌아가지 않는다).
    const max = message_mod.max_net_body_bytes;
    _ = try encode(.{ .net_body_data = .{ .browser = 1, .session = 1, .request = 2, .offset = max - 1, .bytes = "z" } }, &buf);
    try std.testing.expectError(error.InvalidNetwork, encode(.{ .net_body_data = .{ .browser = 1, .session = 1, .request = 2, .offset = max, .bytes = "z" } }, &buf));
    {
        const len = try encode(.{ .net_body_data = .{ .browser = 1, .session = 1, .request = 2, .offset = 0, .bytes = "zz" } }, &buf);
        for ([_]u32{ max - 1, std.math.maxInt(u32), std.math.maxInt(u32) - 1 }) |off| {
            std.mem.writeInt(u32, buf[body + 20 ..][0..4], off, .big);
            try std.testing.expectError(error.InvalidNetwork, decodeExact(buf[0..len]));
        }
    }
    // 풀어 낸 크기: maxInt(i64) 는 받고 그 위는 거절, 잡은 크기 1 MiB 는 받고 그 위는 거절.
    {
        const len = try encode(.{ .net_body_end = .{ .browser = 1, .session = 1, .request = 2, .state = .over_cap, .decoded = std.math.maxInt(i64) } }, &buf);
        _ = try decodeExact(buf[0..len]);
        std.mem.writeInt(u64, buf[body + 26 ..][0..8], @as(u64, std.math.maxInt(i64)) + 1, .big);
        try std.testing.expectError(error.InvalidNetwork, decodeExact(buf[0..len]));
        std.mem.writeInt(u64, buf[body + 26 ..][0..8], std.math.maxInt(u64), .big);
        try std.testing.expectError(error.InvalidNetwork, decodeExact(buf[0..len]));
        const l2 = try encode(.{ .net_body_end = .{ .browser = 1, .session = 1, .request = 2, .state = .captured, .size = max } }, &buf);
        _ = try decodeExact(buf[0..l2]);
        std.mem.writeInt(u32, buf[body + 22 ..][0..4], max + 1, .big);
        try std.testing.expectError(error.InvalidNetwork, decodeExact(buf[0..l2]));
    }
    // 모르는 상태 값(14·200·255)과 마지막 아는 값(13 restarted).
    {
        const len = try encode(.{ .net_body_end = .{ .browser = 1, .session = 1, .request = 2, .state = .restarted } }, &buf);
        _ = try decodeExact(buf[0..len]);
        for ([_]u8{ 14, 200, 255 }) |st| {
            buf[body + 20] = st;
            try std.testing.expectError(error.InvalidNetwork, decodeExact(buf[0..len]));
        }
        const l2 = try encode(.{ .net_record_state = .{ .browser = 1, .session = 1, .status = .failed } }, &buf);
        for ([_]u8{ 4, 255 }) |st| {
            buf[body + 12] = st;
            try std.testing.expectError(error.InvalidNetwork, decodeExact(buf[0..l2]));
        }
        // 꺼짐은 세션이 있어도 받는다(끄기 전 세션의 알림 — maru 는 지금 세션과 견준다).
        const l3 = try encode(.{ .net_record_state = .{ .browser = 1, .session = 7, .status = .off } }, &buf);
        _ = try decodeExact(buf[0..l3]);
    }
    // net_begin 둘째 표시의 쓰지 않는 비트 일곱.
    {
        const len = try encode(.{ .net_begin = .{ .browser = 3, .request = 8, .flags2 = .{ .body_expected = true }, .url = "https://a.test/x", .host = "a.test" } }, &buf);
        const at = body + 8 + 8 + 1;
        try std.testing.expectEqual(@as(u8, 1), buf[at]);
        for (1..8) |bit| {
            var b = buf;
            b[at] = 1 | (@as(u8, 1) << @intCast(bit));
            try std.testing.expectError(error.InvalidNetwork, decodeExact(b[0..len]));
        }
    }
}

test "W9d③ v20b R14e: 막기 frame 의 방향 — maru 쪽은 net_block 을, sidecar 쪽은 net_block_state·net_block_hits 를 받지 않는다(채널을 잠근다), 바른 쪽은 받는다(대조)" {
    var buf: [max_frame_bytes]u8 = undefined;
    var nb: message_mod.NetBlock = .{ .browser = 3, .generation = 1, .count = 1 };
    nb.rules[0] = .{ .id = 1, .site = "a.test", .pattern = "https://a.test/x" };
    var len = try encode(.{ .net_block = nb }, &buf);
    var at_maru = StreamingDecoder.init(.to_maru);
    _ = try at_maru.feed(buf[0..len]);
    try std.testing.expectError(error.WrongDirection, at_maru.next());
    var at_sidecar_ok = StreamingDecoder.init(.to_sidecar);
    _ = try at_sidecar_ok.feed(buf[0..len]);
    try std.testing.expect((try at_sidecar_ok.next()).? == .net_block);
    var hits: message_mod.NetBlockHits = .{ .browser = 3, .count = 1 };
    hits.entries[0] = .{ .rule_id = 1, .hits = 1 };
    for ([_]Message{ .{ .net_block_state = .{ .browser = 3, .generation = 1, .ok = true } }, .{ .net_block_hits = hits }, .{ .error_page = .{ .browser = 3, .error_code = -20, .blocked_rule = 1 } } }) |m| {
        len = try encode(m, &buf);
        var at_sidecar = StreamingDecoder.init(.to_sidecar);
        _ = try at_sidecar.feed(buf[0..len]);
        try std.testing.expectError(error.WrongDirection, at_sidecar.next());
        var at_maru_ok = StreamingDecoder.init(.to_maru);
        _ = try at_maru_ok.feed(buf[0..len]);
        try std.testing.expect((try at_maru_ok.next()) != null);
    }
}

test "W9d③ v20b R14f: 가장 큰 net_block(25 110 바이트)을 모든 길이에서 잘라도 풀기는 IncompleteFrame/오류일 뿐 무너지지 않고, 1 바이트씩 넣어도 한 번에 풀린다" {
    const array_repeat = @import("array_repeat");
    var v: message_mod.NetBlock = .{ .browser = 1, .generation = 7, .count = message_mod.max_net_block_rules };
    const host = array_repeat.repeat("h", message_mod.max_net_host_bytes);
    const pattern = "https://a.test/" ++ array_repeat.repeat("p", message_mod.max_net_block_pattern_bytes - 15);
    v.strict_site = host;
    for (&v.rules, 0..) |*r, i| r.* = .{ .id = @intCast(i + 1), .site = host, .pattern = pattern };
    var buf: [max_frame_bytes]u8 = undefined;
    const len = try encode(.{ .net_block = v }, &buf);
    try std.testing.expectEqual(@as(usize, 11 + 8 + 4 + 1 + 253 + 1 + 32 * (4 + 4 + 1 + 253 + 2 + 512)), len);
    try std.testing.expectEqual(@as(usize, 25_110), len); // 문서의 수(20 회 검증 B N1 — 전에는 25,109 로 적었다)
    var cut_errors: usize = 0;
    var n: usize = 0;
    while (n < len) : (n += 1) {
        if (decodeExact(buf[0..n])) |_| return error.TruncatedDecoded else |_| cut_errors += 1;
    }
    try std.testing.expectEqual(len, cut_errors);
    var d = StreamingDecoder.init(.to_sidecar);
    var got: usize = 0;
    for (buf[0..len]) |b| {
        _ = try d.feed(&.{b});
        while (try d.next()) |m| {
            try std.testing.expectEqual(@as(u8, 32), m.net_block.count);
            got += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), got);
    // 수를 손으로 33 으로 — 규칙 수 칸만 바꾼 frame 은 거절.
    var bad = buf;
    const count_at = wire.prefix_len + wire.common_len + 8 + 4 + 1 + host.len;
    try std.testing.expectEqual(@as(u8, 32), bad[count_at]);
    bad[count_at] = 33;
    try std.testing.expect(std.meta.isError(decodeExact(bad[0..len])));
}
