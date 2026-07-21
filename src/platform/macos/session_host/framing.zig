//! MRSH frame 조립 — partial I/O를 견디는 incremental parser와 frame 직렬화 helper(§10).
//!
//! 왜 incremental인가: session-host socket은 non-blocking이라 header/payload가 여러 read에 쪼개져 온다("header/payload
//! partial read/write는 정상 입력", §10). socket read loop(P3-d server)는 받은 바이트를 그대로 `FrameParser.push`에
//! 넣고 `next()`로 완성된 frame을 하나씩 꺼낸다. 이 parser는 순수 버퍼 state machine이라 socket·OS를 모르고
//! non-macOS에서 그대로 테스트된다(platform import 0). cap 적용·unknown frame 정책도 여기서 판정한다:
//!   - payload가 kind별 cap을 넘으면 `PayloadTooLarge`(payload를 읽어 버퍼를 채우기 **전에** 거부 — 메모리 폭주 방지).
//!   - 모르는 required kind/flag는 `UnknownRequiredFrame`(§10: connection만 닫고 runtime은 유지 — 상위가 처리).
//!   - 모르는 kind/flag라도 `optional` flag면 payload 길이만큼 안전하게 skip한다.

const std = @import("std");
const protocol = @import("protocol.zig");

/// 완성된 한 frame. `payload`는 caller 소유다(parser 버퍼에서 복사) — 다음 `next()` 호출과 독립적으로 유효하다.
pub const Frame = struct {
    header: protocol.Header,
    payload: []u8,

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

pub const ParseError = error{
    /// 첫 4바이트가 "MRSH"가 아니다 — 이 connection은 MRSH가 아니다(다른 socket과 혼선). connection을 닫는다.
    BadMagic,
    /// payload_len이 이 kind의 cap을 넘었다. payload를 버퍼에 쌓기 전에 거부한다.
    PayloadTooLarge,
    /// 모르는 kind이거나 v1 미정의 flag 비트인데 optional이 아니다 — 안전하게 무시할 수 없어 connection을 닫는다.
    UnknownRequiredFrame,
    OutOfMemory,
};

/// 받은 바이트를 누적하다 완성된 frame을 하나씩 꺼내는 state machine. 소유는 caller(push/next/deinit).
pub const FrameParser = struct {
    allocator: std.mem.Allocator,
    /// 아직 완성 frame으로 소비되지 않은 바이트. header+payload 경계로 `next()`가 잘라 낸다.
    buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) FrameParser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FrameParser) void {
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    /// socket에서 읽은 바이트를 누적한다. 여러 frame이 한 번에 와도 되고, 한 frame이 여러 push에 쪼개져도 된다.
    pub fn push(self: *FrameParser, bytes: []const u8) ParseError!void {
        self.buf.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
    }

    /// 완성된 다음 frame을 꺼낸다(버퍼에서 제거). 부족하면 null(더 push하라). optional unknown frame은 조용히
    /// skip하고 그 다음 처리 대상 frame을 찾는다. cap 초과·bad magic·unknown required는 error(connection 닫기).
    pub fn next(self: *FrameParser) ParseError!?Frame {
        while (true) {
            if (self.buf.items.len < protocol.header_size) return null; // header 미완성

            const header_bytes: *const [protocol.header_size]u8 = @ptrCast(self.buf.items.ptr);
            const header = protocol.Header.decode(header_bytes) catch |err| switch (err) {
                error.BadMagic => return error.BadMagic,
            };

            // cap을 payload 적재 전에 검사한다 — oversize 선언만으로 메모리를 못 늘리게.
            const cap = protocol.maxPayloadForKind(header.kind);
            if (header.payload_len > cap) return error.PayloadTooLarge;

            const total = protocol.header_size + @as(usize, header.payload_len);
            if (self.buf.items.len < total) return null; // payload 미완성

            const understood = header.kind.isKnown() and !protocol.Flags.hasUnknownBits(header.flags);
            if (!understood) {
                if (!protocol.Flags.isOptional(header.flags)) return error.UnknownRequiredFrame;
                // optional이라 안전하게 skip: 이 frame 전체를 소비하고 다음 frame을 시도한다.
                self.consume(total);
                continue;
            }

            const payload = self.allocator.dupe(u8, self.buf.items[protocol.header_size..total]) catch return error.OutOfMemory;
            self.consume(total);
            return Frame{ .header = header, .payload = payload };
        }
    }

    /// 버퍼 앞에서 `count`바이트를 제거하고 나머지를 앞으로 당긴다(capacity는 유지 — 다음 frame 재사용).
    fn consume(self: *FrameParser, count: usize) void {
        const remaining = self.buf.items.len - count;
        std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[count..]);
        self.buf.shrinkRetainingCapacity(remaining);
    }
};

/// 한 frame(header + payload)을 하나의 연속 버퍼로 직렬화한다(caller 소유). socket write loop가 이 버퍼를 partial write로
/// 흘려 보낸다. payload가 kind cap을 넘으면 `PayloadTooLarge`(보내는 쪽에서도 계약 위반을 조기에 잡는다).
pub fn encodeFrame(
    allocator: std.mem.Allocator,
    header_in: protocol.Header,
    payload: []const u8,
) ParseError![]u8 {
    if (payload.len > protocol.maxPayloadForKind(header_in.kind)) return error.PayloadTooLarge;
    var header = header_in;
    header.payload_len = @intCast(payload.len);
    var out = allocator.alloc(u8, protocol.header_size + payload.len) catch return error.OutOfMemory;
    @memcpy(out[0..protocol.header_size], &header.encode());
    @memcpy(out[protocol.header_size..], payload);
    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): non-blocking session-host socket은 frame을 임의 경계로
// 쪼개 전달한다. parser가 partial header/payload를 견디고, 한 read에 여러 frame이 와도 순서대로 꺼내며, oversize
// 선언·bad magic·unknown required를 payload 적재 전에 거부하고, optional unknown은 안전히 skip해야 — 재접속·screen
// stream이 엉키지 않는다. 순수 state machine이라 실제 socket 없이 non-macOS에서 회귀를 고정한다.
// ─────────────────────────────────────────────────────────────────────────────

test "framing: parses a whole frame and returns owned payload" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();

    const wire = try encodeFrame(allocator, .{ .kind = .request, .request_id = 42 }, "hello world");
    defer allocator.free(wire);

    try parser.push(wire);
    const frame = (try parser.next()).?;
    defer frame.deinit(allocator);
    try std.testing.expectEqual(protocol.Kind.request, frame.header.kind);
    try std.testing.expectEqual(@as(u64, 42), frame.header.request_id);
    try std.testing.expectEqualStrings("hello world", frame.payload);
    try std.testing.expect((try parser.next()) == null); // 더 없음
}

test "framing: reassembles a frame split across many pushes (partial I/O)" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();

    const wire = try encodeFrame(allocator, .{ .kind = .input_bytes, .stream_id = 7 }, "abcdef");
    defer allocator.free(wire);

    // 1바이트씩 흘려 넣는다 — 마지막 바이트 전까지는 항상 null(미완성).
    for (wire[0 .. wire.len - 1]) |b| {
        try parser.push(&.{b});
        try std.testing.expect((try parser.next()) == null);
    }
    try parser.push(wire[wire.len - 1 ..]);
    const frame = (try parser.next()).?;
    defer frame.deinit(allocator);
    try std.testing.expectEqual(protocol.Kind.input_bytes, frame.header.kind);
    try std.testing.expectEqualStrings("abcdef", frame.payload);
}

test "framing: yields multiple frames from a single push in order" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();

    const a = try encodeFrame(allocator, .{ .kind = .ping, .request_id = 1 }, "");
    defer allocator.free(a);
    const b = try encodeFrame(allocator, .{ .kind = .request, .request_id = 2 }, "cmd");
    defer allocator.free(b);
    const both = try std.mem.concat(allocator, u8, &.{ a, b });
    defer allocator.free(both);

    try parser.push(both);
    const f1 = (try parser.next()).?;
    defer f1.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), f1.header.request_id);
    const f2 = (try parser.next()).?;
    defer f2.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), f2.header.request_id);
    try std.testing.expectEqualStrings("cmd", f2.payload);
    try std.testing.expect((try parser.next()) == null);
}

test "framing: rejects oversize payload before buffering it" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();

    // request(control)는 256 KiB cap. 그보다 큰 payload_len을 선언한 header만 push해도(payload는 아직 안 보냄) 거부.
    var header = (protocol.Header{ .kind = .request }).encode();
    std.mem.writeInt(u32, header[28..32], protocol.max_control_json + 1, .big);
    try parser.push(&header);
    try std.testing.expectError(error.PayloadTooLarge, parser.next());
}

test "framing: rejects non-MRSH magic" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    var junk = [_]u8{0} ** protocol.header_size;
    @memcpy(junk[0..4], "XXXX");
    try parser.push(&junk);
    try std.testing.expectError(error.BadMagic, parser.next());
}

test "framing: unknown required kind closes; unknown optional kind is skipped" {
    const allocator = std.testing.allocator;

    // (1) unknown required → error.
    {
        var parser = FrameParser.init(allocator);
        defer parser.deinit();
        var h = (protocol.Header{ .kind = .request }).encode();
        std.mem.writeInt(u16, h[6..8], 55000, .big); // 미지 kind, optional flag 없음
        try parser.push(&h);
        try std.testing.expectError(error.UnknownRequiredFrame, parser.next());
    }
    // (2) unknown optional → skip하고 그 다음 known frame을 반환.
    {
        var parser = FrameParser.init(allocator);
        defer parser.deinit();
        const skipped = try encodeFrame(allocator, .{ .kind = @enumFromInt(55001), .flags = protocol.Flags.optional }, "ignore me");
        defer allocator.free(skipped);
        const real = try encodeFrame(allocator, .{ .kind = .response, .request_id = 9 }, "ok");
        defer allocator.free(real);
        const both = try std.mem.concat(allocator, u8, &.{ skipped, real });
        defer allocator.free(both);
        try parser.push(both);
        const frame = (try parser.next()).?;
        defer frame.deinit(allocator);
        try std.testing.expectEqual(@as(u64, 9), frame.header.request_id);
        try std.testing.expectEqualStrings("ok", frame.payload);
    }
}

test "framing: unknown flag bit on a required frame closes the connection" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator);
    defer parser.deinit();
    var h = (protocol.Header{ .kind = .request, .flags = 0x4 }).encode(); // v1 미정의 비트, optional 아님
    try parser.push(&h);
    try std.testing.expectError(error.UnknownRequiredFrame, parser.next());
}
