//! MRSH session-host wire protocol — 32-byte 고정 header codec + kind/flag/error 어휘.
//!
//! 단일 출처는 [영속 터미널 세션 호스트](../../../../docs/persistent-session-host.md) §10이다. 이 파일은 그
//! §10 framing 계약의 **순수 codec**만 담는다 — OS·socket·프로세스를 모른다(platform import 0). partial I/O와
//! cap 적용은 `framing.zig`, connection state machine은 상위(server/client)가 소유한다. 이렇게 나눠야 codec을
//! 나중에 이식하거나 CLI(P5)와 host가 같은 wire를 공유할 수 있다(project-structure.md session_host/ 주석).
//!
//! 왜 새 wire인가: control-plane(`maru.control.v1`)은 실행 중 GUI surface 조회용 NDJSON JSON-RPC다. session-host
//! transport는 PTY 수명과 고처리량 binary screen stream을 나르므로, 임의 terminal bytes를 JSON 문자열로 바꾸지
//! 않도록 **binary payload를 그대로 length-framing**하는 별도 wire를 쓴다(§10). 두 wire는 ID·socket을 공유하지 않는다.
//!
//! 바이트 순서: 모든 정수는 network byte order(big-endian). header는 정확히 32바이트다:
//!   magic[4]="MRSH" | major:u16 | kind:u16 | flags:u32 | request_id:u64 | stream_id:u64 | payload_len:u32
//!   = 4 + 2 + 2 + 4 + 8 + 8 + 4 = 32.

const std = @import("std");
const client_queue_limits = @import("client_queue_limits.zig");
const catchup_barrier_wire = @import("catchup_barrier_wire.zig");
pub const screen_frontier_barrier_payload_size = catchup_barrier_wire.payload_size;

/// wire 식별 magic. 첫 4바이트가 이것이 아니면 이 connection은 MRSH가 아니다(control-plane socket 혼선 방지).
pub const magic = [4]u8{ 'M', 'R', 'S', 'H' };

/// 고정 header 크기(바이트). partial read가 이 경계로 header/payload를 가른다.
pub const header_size = 32;

/// protocol major. hello에서 client/host가 겹치는 major를 못 찾으면 `incompatible_version`. v2는 원격 화면 색/이미지
/// wire의 비호환 변경이다. 확장 spawn 계약을 요구하는 새 GUI는 새 command `runtime.spawn_full`을 써서 구 v2 host가
/// unknown method로 거부하게 한다. major를 올리면 이미 살아 있는 v2 host/runtime에도 attach할 수 없고 host 교체 CLI가
/// 아직 없으므로, 화면 wire가 같은 동안은 strict method 이름으로 spawn 의미론만 fail-closed한다.
pub const version_major: u16 = 2;
/// runtime.inventory_v1 complete snapshot의 host-side hard cap. page는 더 작지만 total이 이를 넘으면 partial prefix 대신
/// resource_exhausted로 fail-close한다.
/// Wire-only 모듈은 platform-import-0을 유지한다. `runtime_manager`의 compile-time boundary gate가 이 값을
/// `session.workspace.max_runtime_bindings`와 같게 고정해 partial restore cap drift를 막는다.
pub const max_inventory_runtimes: usize = @import("maru").session.host_protocol.max_inventory_runtimes;
/// title wire 상한(§8). 단일 출처는 `host_protocol` 이다 — server 와 CLI 가 같은 값을 본다.
pub const max_title_bytes: usize = @import("maru").session.host_protocol.max_title_bytes;
pub const max_inventory_page_runtimes: usize = 256;
pub const max_inventory_pages: usize =
    (max_inventory_runtimes + max_inventory_page_runtimes - 1) / max_inventory_page_runtimes;

/// payload cap(§10). control은 strict UTF-8 JSON, binary는 그대로. 이 상한들은 kind별로 framing이 적용한다.
/// 한 viewport snapshot(16 MiB)은 여러 `snapshot_chunk`(각 1 MiB)로 나뉘므로 **단일 frame** payload 상한은 binary 1 MiB다.
pub const max_control_json: usize = @import("maru").session.host_protocol.max_control_json;
pub const max_binary_chunk: usize = 1024 * 1024;
pub const max_viewport_snapshot: usize = 16 * 1024 * 1024;
pub const max_screen_batch_chunks: usize = max_viewport_snapshot / max_binary_chunk;
pub const max_scrollback_page: usize = 1024 * 1024;
pub const max_client_queue: usize = 8 * 1024 * 1024;
/// Complete screen inbox across demux/pending RPC paths; mirrors one server connection slot.
pub const max_client_screen_inbox: usize = 18 * 1024 * 1024;
pub const max_client_screen_items: usize = client_queue_limits.max_screen_items;
pub const max_client_pending_events: usize = client_queue_limits.max_pending_events;

/// frame 종류(§10 표). `enum(u16)`에 `_`를 둬 **open enum**으로 만든다 — 모르는 값도 decode되어 상위가
/// required/optional flag로 처리를 가른다(모르는 required는 protocol error, optional은 skip). 값은 wire 약속이라 고정.
pub const Kind = enum(u16) {
    hello = 1,
    hello_ack = 2,
    request = 3,
    response = 4,
    event = 5,
    snapshot_chunk = 6,
    delta_chunk = 7,
    input_bytes = 8,
    stream_ack = 9,
    ping = 10,
    pong = 11,
    /// controller가 host viewport를 live bottom으로 되돌리는 응답 없는 stream command.
    /// AppKit IME callback이 request/response RPC를 기다리지 않도록 별도 kind로 둔다.
    scroll_to_bottom = 12,
    /// controller의 bounded host-core 명령. focus/config/prompt hot path가 response RPC를 기다리지 않되,
    /// 같은 connection의 input frame과 wire 순서를 공유하도록 fire-and-forget stream frame으로 둔다.
    core_command = 13,
    /// Read-only fresh metadata barrier. The fixed payload is a nonzero big-endian action nonce;
    /// peers that did not negotiate its capability must never receive this frame.
    observation_probe = 15,
    /// Negotiated CR4 reconnect catch-up cut. Fixed binary payload; it is the final frame of the
    /// same atomically admitted subscription batch as its preceding snapshot/delta chunks.
    screen_frontier_barrier = catchup_barrier_wire.kind_raw,
    _,

    /// v1이 아는 kind인가. open enum이라 unknown 값(미래 wire)은 false다 — 상위가 optional flag로 skip 여부를 정한다.
    pub fn isKnown(self: Kind) bool {
        return switch (self) {
            .hello, .hello_ack, .request, .response, .event, .snapshot_chunk, .delta_chunk, .input_bytes, .stream_ack, .ping, .pong, .scroll_to_bottom, .core_command, .observation_probe, .screen_frontier_barrier => true,
            _ => false,
        };
    }

    /// 이 kind payload가 control JSON인지(strict UTF-8 검증 대상). binary(chunk/input)는 false.
    pub fn isControlJson(self: Kind) bool {
        return switch (self) {
            .hello, .hello_ack, .request, .response, .event, .stream_ack, .core_command => true,
            else => false,
        };
    }
};

/// v1 flag 비트(§10). 그 외 비트가 켜져 있으면 알 수 없는 required 확장이므로 protocol error다(`hasUnknownBits`).
pub const Flags = struct {
    pub const end_stream: u32 = 1;
    pub const optional: u32 = 2;
    pub const known_mask: u32 = end_stream | optional;

    pub fn hasEndStream(flags: u32) bool {
        return flags & end_stream != 0;
    }
    pub fn isOptional(flags: u32) bool {
        return flags & optional != 0;
    }
    /// v1이 정의하지 않은 flag 비트가 켜져 있는가. required frame에서 이러면 connection을 닫는다(§10).
    pub fn hasUnknownBits(flags: u32) bool {
        return flags & ~known_mask != 0;
    }
};

/// §10 공통 typed error. CLI exit code·사용자 문구는 이 enum을 **한 곳에서** 매핑하고 server의 임의 문자열을 그대로
/// 쓰지 않는다. `wireName`은 JSON 응답(`{error:"<name>"}`)과 fixture의 안정 식별자다(코드 이름과 1:1, snake_case).
pub const ErrorCode = @import("maru").session.host_protocol.ErrorCode;

/// header decode가 낼 수 있는 구조 오류. cap 초과·unknown kind 정책은 여기서 판정하지 않고 framing/dispatch가 맡는다
/// (codec은 구조만 본다 — payload_len은 그대로 반환한다).
pub const DecodeError = error{BadMagic};

/// 32바이트 MRSH header. `payload_len`은 뒤따르는 payload 바이트 수다. codec은 payload 자체를 소유하지 않는다.
pub const Header = struct {
    kind: Kind,
    flags: u32 = 0,
    request_id: u64 = 0,
    stream_id: u64 = 0,
    payload_len: u32 = 0,
    major: u16 = version_major,

    /// header를 정확히 32바이트 big-endian으로 직렬화한다. payload는 호출자가 뒤에 이어 쓴다.
    pub fn encode(self: Header) [header_size]u8 {
        var buf: [header_size]u8 = undefined;
        @memcpy(buf[0..4], &magic);
        std.mem.writeInt(u16, buf[4..6], self.major, .big);
        std.mem.writeInt(u16, buf[6..8], @intFromEnum(self.kind), .big);
        std.mem.writeInt(u32, buf[8..12], self.flags, .big);
        std.mem.writeInt(u64, buf[12..20], self.request_id, .big);
        std.mem.writeInt(u64, buf[20..28], self.stream_id, .big);
        std.mem.writeInt(u32, buf[28..32], self.payload_len, .big);
        return buf;
    }

    /// 32바이트 buffer에서 header를 읽는다. magic 불일치만 구조 오류이고, 나머지 정책(cap·unknown kind)은 상위가 본다.
    pub fn decode(bytes: *const [header_size]u8) DecodeError!Header {
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.BadMagic;
        return .{
            .major = std.mem.readInt(u16, bytes[4..6], .big),
            .kind = @enumFromInt(std.mem.readInt(u16, bytes[6..8], .big)),
            .flags = std.mem.readInt(u32, bytes[8..12], .big),
            .request_id = std.mem.readInt(u64, bytes[12..20], .big),
            .stream_id = std.mem.readInt(u64, bytes[20..28], .big),
            .payload_len = std.mem.readInt(u32, bytes[28..32], .big),
        };
    }
};

/// 이 kind의 단일 frame payload 상한(바이트). framing이 payload를 읽기 **전에** 적용해 oversize를 `payload_too_large`로
/// 거부한다(메모리 폭주 방지). unknown kind는 binary 상한으로 관대하게 두고(optional이면 skip) required면 상위가 닫는다.
pub fn maxPayloadForKind(kind: Kind) usize {
    return switch (kind) {
        .observation_probe => 8,
        .screen_frontier_barrier => screen_frontier_barrier_payload_size,
        .snapshot_chunk, .delta_chunk, .input_bytes => max_binary_chunk,
        .hello, .hello_ack, .request, .response, .event, .stream_ack, .ping, .pong, .scroll_to_bottom, .core_command => max_control_json,
        _ => max_binary_chunk,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): MRSH는 GUI·CLI·host가 PTY 수명과 화면 stream을 나르는
// 유일한 wire다. header 한 바이트라도 어긋나면 재접속이 엉뚱한 runtime에 붙거나 binary screen이 JSON으로 오독된다.
// 32바이트 레이아웃(big-endian, 필드 오프셋), magic 거부, open enum(미래 kind), flag 비트, error 어휘 왕복을
// 고정해 wire 회귀를 컴파일/테스트에서 잡는다. 순수 codec이라 non-macOS에서도 실행된다.
// ─────────────────────────────────────────────────────────────────────────────

test "MRSH header round-trips with exact 32-byte big-endian layout" {
    const h = Header{
        .kind = .request,
        .flags = Flags.end_stream,
        .request_id = 0x0102030405060708,
        .stream_id = 0x1112131415161718,
        .payload_len = 0xAABBCCDD,
        .major = 1,
    };
    const bytes = h.encode();
    // 정확한 오프셋(wire 약속): magic·major·kind·flags·request_id·stream_id·payload_len.
    try std.testing.expectEqualSlices(u8, "MRSH", bytes[0..4]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[4..6], .big));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, bytes[6..8], .big)); // request=3
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[8..12], .big)); // end_stream
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), std.mem.readInt(u64, bytes[12..20], .big));
    try std.testing.expectEqual(@as(u64, 0x1112131415161718), std.mem.readInt(u64, bytes[20..28], .big));
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), std.mem.readInt(u32, bytes[28..32], .big));

    const back = try Header.decode(&bytes);
    try std.testing.expectEqual(h.kind, back.kind);
    try std.testing.expectEqual(h.flags, back.flags);
    try std.testing.expectEqual(h.request_id, back.request_id);
    try std.testing.expectEqual(h.stream_id, back.stream_id);
    try std.testing.expectEqual(h.payload_len, back.payload_len);
    try std.testing.expectEqual(h.major, back.major);
}

test "CR4a host barrier frame kind는 fixed binary 96바이트만 허용한다" {
    try std.testing.expectEqual(@as(u16, 14), @intFromEnum(Kind.screen_frontier_barrier));
    try std.testing.expect(Kind.screen_frontier_barrier.isKnown());
    try std.testing.expect(!Kind.screen_frontier_barrier.isControlJson());
    try std.testing.expectEqual(@as(usize, 96), maxPayloadForKind(.screen_frontier_barrier));
    const encoded = (Header{
        .kind = .screen_frontier_barrier,
        .request_id = 0,
        .stream_id = 7,
        .payload_len = 96,
    }).encode();
    const decoded = try Header.decode(&encoded);
    try std.testing.expectEqual(Kind.screen_frontier_barrier, decoded.kind);
    try std.testing.expectEqual(@as(u64, 0), decoded.request_id);
    try std.testing.expectEqual(@as(u64, 7), decoded.stream_id);
    try std.testing.expectEqual(@as(u32, 96), decoded.payload_len);
}

test "MRSH header size is exactly 32 bytes" {
    const h = Header{ .kind = .ping };
    try std.testing.expectEqual(@as(usize, 32), h.encode().len);
    try std.testing.expectEqual(@as(usize, 32), header_size);
}

test "MRSH decode rejects a non-MRSH prefix (control-plane socket 혼선 방지)" {
    var bytes = (Header{ .kind = .hello }).encode();
    bytes[1] = 'X'; // "MXSH"
    try std.testing.expectError(error.BadMagic, Header.decode(&bytes));
}

test "MRSH kind is an open enum: unknown wire kind decodes but reports not-known" {
    var bytes = (Header{ .kind = .hello }).encode();
    std.mem.writeInt(u16, bytes[6..8], 60000, .big); // 미래/미지 kind
    const back = try Header.decode(&bytes);
    try std.testing.expect(!back.kind.isKnown()); // 상위가 optional flag로 skip 여부 판정
    try std.testing.expectEqual(@as(u16, 60000), @intFromEnum(back.kind));
}

test "MRSH known kinds classify control-json vs binary payloads" {
    try std.testing.expect(Kind.hello.isControlJson());
    try std.testing.expect(Kind.request.isControlJson());
    try std.testing.expect(Kind.stream_ack.isControlJson());
    try std.testing.expect(Kind.core_command.isKnown());
    try std.testing.expect(Kind.screen_frontier_barrier.isKnown());
    try std.testing.expect(!Kind.screen_frontier_barrier.isControlJson());
    try std.testing.expect(Kind.core_command.isControlJson());
    try std.testing.expect(!Kind.snapshot_chunk.isControlJson());
    try std.testing.expect(!Kind.input_bytes.isControlJson());
    try std.testing.expect(!Kind.ping.isControlJson()); // ping은 empty/nonce라 JSON 검증 대상 아님
    // payload 상한: control 256 KiB, binary 1 MiB.
    try std.testing.expectEqual(max_control_json, maxPayloadForKind(.response));
    try std.testing.expectEqual(max_control_json, maxPayloadForKind(.core_command));
    try std.testing.expectEqual(max_binary_chunk, maxPayloadForKind(.snapshot_chunk));
    try std.testing.expectEqual(max_binary_chunk, maxPayloadForKind(.input_bytes));
    try std.testing.expectEqual(@as(usize, 96), maxPayloadForKind(.screen_frontier_barrier));
}

test "P4 async observation probe has a dedicated optional-safe fixed payload kind" {
    try std.testing.expectEqual(@as(u16, 15), @intFromEnum(Kind.observation_probe));
    try std.testing.expect(Kind.observation_probe.isKnown());
    try std.testing.expect(!Kind.observation_probe.isControlJson());
    try std.testing.expectEqual(@as(usize, 8), maxPayloadForKind(.observation_probe));
}

test "MRSH flags: end_stream/optional/unknown-bit predicates" {
    try std.testing.expect(Flags.hasEndStream(Flags.end_stream));
    try std.testing.expect(!Flags.hasEndStream(Flags.optional));
    try std.testing.expect(Flags.isOptional(Flags.optional | Flags.end_stream));
    try std.testing.expect(!Flags.hasUnknownBits(Flags.known_mask));
    try std.testing.expect(Flags.hasUnknownBits(0x4)); // v1 미정의 비트 → required면 protocol error
}

test "MRSH error codes round-trip through wire names" {
    inline for (@typeInfo(ErrorCode).@"enum".fields) |f| {
        const code: ErrorCode = @enumFromInt(f.value);
        try std.testing.expectEqual(code, ErrorCode.fromWireName(code.wireName()).?);
    }
    try std.testing.expect(ErrorCode.fromWireName("no_such_code") == null); // 모르는 이름 → 호출자가 internal 폴백
    try std.testing.expectEqualStrings("controller_busy", ErrorCode.controller_busy.wireName());
}
