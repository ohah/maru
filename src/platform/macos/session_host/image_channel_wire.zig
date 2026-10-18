//! 이미지 채널 메시지 — 주 MRSH 소켓과 따로 여는 보조 연결의 고정 길이 메시지 셋.
//!
//! 단일 출처는 [Session host 이미지 채널](../../../../docs/session-host-image-channel.md) §3.1·§3.3 이다. 채널에는 MRSH
//! 프레임이 다니지 않는다 — 수립(hello{role:"image_channel"})만 MRSH 로 하고, 그 뒤로는 이 파일의 메시지뿐이다.
//!
//! | 방향 | 메시지 | 붙는 fd |
//! |---|---|---|
//! | host → 앱 | `bind_ack` | 없음 |
//! | host → 앱 | `segment{segment_id, stream_id, image_id, generation, byte_len}` | 정확히 1 개 |
//! | 앱 → host | `release{segment_id}` 묶음 | 없음(붙어 오면 프로토콜 오류) |
//!
//! 메시지마다 길이가 정해져 있어 읽는 쪽은 종류만 보고 몇 바이트를 더 읽을지 안다. 모든 메시지는 같은 8 B 머리
//! (`magic` 4 B + 종류 1 B + 0 으로 채운 3 B)로 시작한다 — 머리가 어긋나면 그 채널은 더 해석하지 않는다.
//!
//! token 은 hello_ack 의 `image_channel_token`, 채널 hello 의 `token` 에 32 자 소문자 hex 로 실린다(128-bit, 0 은 쓰지
//! 않는다). OS 를 모르는 std-only leaf 라 형식 규칙을 PR CI(check-boundaries)에서 잰다.

const std = @import("std");

pub const magic = [4]u8{ 'M', 'R', 'I', 'C' };

pub const Kind = enum(u8) {
    bind_ack = 1,
    segment = 2,
    release = 3,
    _,
};

pub const header_len: usize = 8;
pub const bind_ack_len: usize = header_len;
/// 머리 + segment_id u64 + stream_id u64 + image_id u32 + byte_len u32 + generation u64.
pub const segment_len: usize = header_len + 8 + 8 + 4 + 4 + 8;
/// 머리 + segment_id u64.
pub const release_len: usize = header_len + 8;

/// 채널 hello 의 `role` 값.
pub const role = "image_channel";
/// 주 hello 의 기능 문자열(앱 → host)이자 hello_ack 의 기능 문자열(host → 앱).
pub const capability = "image_shm";
pub const token_hex_len: usize = 32;

/// host 가 이미지 채널을 **제공**하는가 — hello_ack 의 `image_shm` 광고와 token 발급. producer 가 협상한 연결에
/// `image_ref` 를 내고(IC5a·b) 미룬 이미지를 용량 사건이 다시 투영하는(IC5c) host 만 켠다(계획 IC5d). 그보다 이른 host 가
/// 켜면 IC6 앱이 채널을 묶고도 `image_blob` 을 받는다 — 원래 문제(8 MiB 배치 거부)가 그 host 에서 그대로 남는다.
pub const host_offers_image_channel = true;

pub const DecodeError = error{Malformed};

pub const Segment = struct {
    segment_id: u64,
    stream_id: u64,
    image_id: u32,
    generation: u64,
    byte_len: u32,
};

fn writeHeader(out: []u8, kind: Kind) void {
    @memcpy(out[0..4], &magic);
    out[4] = @backingInt(kind);
    @memset(out[5..header_len], 0);
}

/// 머리를 읽어 종류를 돌려준다. magic·채움 바이트가 어긋나거나 모르는 종류면 `Malformed`.
pub fn decodeHeader(bytes: []const u8) DecodeError!Kind {
    if (bytes.len < header_len) return error.Malformed;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.Malformed;
    for (bytes[5..header_len]) |b| if (b != 0) return error.Malformed;
    const kind: Kind = @fromBackingInt(@intCast(bytes[4]));
    return switch (kind) {
        .bind_ack, .segment, .release => kind,
        _ => error.Malformed,
    };
}

/// 종류에 맞는 전체 메시지 길이. 모르는 종류는 null — 읽는 쪽이 `decodeHeader` 를 거치지 않은 값을 넘겨도 미정의 동작이 아니다.
pub fn messageLen(kind: Kind) ?usize {
    return switch (kind) {
        .bind_ack => bind_ack_len,
        .segment => segment_len,
        .release => release_len,
        _ => null,
    };
}

pub fn encodeBindAck() [bind_ack_len]u8 {
    var out: [bind_ack_len]u8 = undefined;
    writeHeader(&out, .bind_ack);
    return out;
}

pub fn decodeBindAck(bytes: []const u8) DecodeError!void {
    if (bytes.len != bind_ack_len or try decodeHeader(bytes) != .bind_ack) return error.Malformed;
}

pub fn encodeSegment(segment: Segment) DecodeError![segment_len]u8 {
    // segment_id 0 은 「세그먼트 없음」(image_ref 의 0/비0 짝 규칙)이고, 0 B 세그먼트는 만들지 않는다(§4.1).
    if (segment.segment_id == 0 or segment.byte_len == 0) return error.Malformed;
    var out: [segment_len]u8 = undefined;
    writeHeader(&out, .segment);
    std.mem.writeInt(u64, out[8..16], segment.segment_id, .little);
    std.mem.writeInt(u64, out[16..24], segment.stream_id, .little);
    std.mem.writeInt(u32, out[24..28], segment.image_id, .little);
    std.mem.writeInt(u32, out[28..32], segment.byte_len, .little);
    std.mem.writeInt(u64, out[32..40], segment.generation, .little);
    return out;
}

pub fn decodeSegment(bytes: []const u8) DecodeError!Segment {
    if (bytes.len != segment_len or try decodeHeader(bytes) != .segment) return error.Malformed;
    const segment: Segment = .{
        .segment_id = std.mem.readInt(u64, bytes[8..16], .little),
        .stream_id = std.mem.readInt(u64, bytes[16..24], .little),
        .image_id = std.mem.readInt(u32, bytes[24..28], .little),
        .byte_len = std.mem.readInt(u32, bytes[28..32], .little),
        .generation = std.mem.readInt(u64, bytes[32..40], .little),
    };
    if (segment.segment_id == 0 or segment.byte_len == 0) return error.Malformed;
    return segment;
}

pub fn encodeRelease(segment_id: u64) DecodeError![release_len]u8 {
    if (segment_id == 0) return error.Malformed;
    var out: [release_len]u8 = undefined;
    writeHeader(&out, .release);
    std.mem.writeInt(u64, out[8..16], segment_id, .little);
    return out;
}

pub fn decodeRelease(bytes: []const u8) DecodeError!u64 {
    if (bytes.len != release_len or try decodeHeader(bytes) != .release) return error.Malformed;
    const segment_id = std.mem.readInt(u64, bytes[8..16], .little);
    if (segment_id == 0) return error.Malformed;
    return segment_id;
}

/// 앱 → host 바이트 묶음을 release 단위로 쪼갠다. 소켓은 메시지 경계를 지키지 않으므로 끝에 남은 반쪽은 `rest` 로
/// 돌려주고 호출자가 다음 읽기 앞에 붙인다. release 가 아닌 메시지가 섞이면 `Malformed` — 앱 → host 방향에는
/// release 만 다닌다.
pub const ReleaseSplit = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn next(self: *ReleaseSplit) DecodeError!?u64 {
        if (self.bytes.len - self.offset < release_len) return null;
        const id = try decodeRelease(self.bytes[self.offset..][0..release_len]);
        self.offset += release_len;
        return id;
    }

    pub fn rest(self: *const ReleaseSplit) []const u8 {
        return self.bytes[self.offset..];
    }
};

/// 32 자 소문자 hex token 을 읽는다. 길이·문자가 어긋나거나 0 이면 null.
pub fn parseToken(text: []const u8) ?u128 {
    if (text.len != token_hex_len) return null;
    var value: u128 = 0;
    for (text) |ch| {
        const digit: u128 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            else => return null,
        };
        value = (value << 4) | digit;
    }
    return if (value == 0) null else value;
}

pub fn formatToken(token: u128) [token_hex_len]u8 {
    std.debug.assert(token != 0);
    var out: [token_hex_len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>32}", .{token}) catch unreachable;
    return out;
}

const testing = std.testing;

test "image channel wire: 세 메시지가 왕복하고 머리가 어긋나면 거부한다" {
    try decodeBindAck(&encodeBindAck());
    const segment: Segment = .{ .segment_id = 7, .stream_id = 3, .image_id = 0xfeed, .generation = 9, .byte_len = 4096 };
    const encoded = try encodeSegment(segment);
    try testing.expectEqual(segment, try decodeSegment(&encoded));
    try testing.expectEqual(@as(u64, 42), try decodeRelease(&(try encodeRelease(42))));

    // 길이는 종류마다 정확해야 한다 — 한 바이트 길거나 짧으면 다음 메시지 경계가 어긋난다.
    try testing.expectError(error.Malformed, decodeSegment(encoded[0 .. segment_len - 1]));
    try testing.expectError(error.Malformed, decodeBindAck(&encoded));
    var bad_magic = encoded;
    bad_magic[0] = 'X';
    try testing.expectError(error.Malformed, decodeSegment(&bad_magic));
    var bad_pad = encoded;
    bad_pad[6] = 1;
    try testing.expectError(error.Malformed, decodeSegment(&bad_pad));
    var bad_kind = encoded;
    bad_kind[4] = 9;
    try testing.expectError(error.Malformed, decodeHeader(&bad_kind));
    try testing.expectEqual(@as(?usize, segment_len), messageLen(try decodeHeader(&encoded)));
    try testing.expectEqual(@as(?usize, null), messageLen(@fromBackingInt(@intCast(9))));
}

test "image channel wire: segment_id 0 과 0 B 세그먼트는 어느 방향으로도 실리지 않는다" {
    try testing.expectError(error.Malformed, encodeSegment(.{ .segment_id = 0, .stream_id = 1, .image_id = 1, .generation = 0, .byte_len = 4 }));
    try testing.expectError(error.Malformed, encodeSegment(.{ .segment_id = 1, .stream_id = 1, .image_id = 1, .generation = 0, .byte_len = 0 }));
    try testing.expectError(error.Malformed, encodeRelease(0));
    var zero_release = try encodeRelease(5);
    @memset(zero_release[8..16], 0);
    try testing.expectError(error.Malformed, decodeRelease(&zero_release));
    var zero_len = try encodeSegment(.{ .segment_id = 1, .stream_id = 1, .image_id = 1, .generation = 0, .byte_len = 4 });
    @memset(zero_len[28..32], 0);
    try testing.expectError(error.Malformed, decodeSegment(&zero_len));
}

test "image channel wire: release 묶음은 반쪽을 남기고 release 아닌 메시지를 거부한다" {
    var bytes: [release_len * 2 + 5]u8 = undefined;
    @memcpy(bytes[0..release_len], &(try encodeRelease(1)));
    @memcpy(bytes[release_len .. release_len * 2], &(try encodeRelease(2)));
    @memcpy(bytes[release_len * 2 ..], (try encodeRelease(3))[0..5]);
    var split: ReleaseSplit = .{ .bytes = &bytes };
    try testing.expectEqual(@as(?u64, 1), try split.next());
    try testing.expectEqual(@as(?u64, 2), try split.next());
    try testing.expectEqual(@as(?u64, null), try split.next());
    try testing.expectEqual(@as(usize, 5), split.rest().len);

    var mixed: [release_len]u8 = undefined;
    @memcpy(mixed[0..bind_ack_len], &encodeBindAck());
    @memset(mixed[bind_ack_len..], 0);
    var bad: ReleaseSplit = .{ .bytes = &mixed };
    try testing.expectError(error.Malformed, bad.next());
}

test "image channel wire: token 은 32 자 소문자 hex 이고 0 이 아니다" {
    const token: u128 = 0x0123456789abcdef_fedcba9876543210;
    const text = formatToken(token);
    try testing.expectEqualStrings("0123456789abcdeffedcba9876543210", &text);
    try testing.expectEqual(@as(?u128, token), parseToken(&text));
    try testing.expectEqual(@as(?u128, null), parseToken(text[0..31]));
    try testing.expectEqual(@as(?u128, null), parseToken("0123456789ABCDEFfedcba9876543210"));
    try testing.expectEqual(@as(?u128, null), parseToken("00000000000000000000000000000000"));
    try testing.expectEqual(@as(?u128, null), parseToken("0123456789abcdeffedcba98765432100"));
}
