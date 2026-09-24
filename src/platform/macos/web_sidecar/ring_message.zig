//! 링 알림(W2, C3) — sidecar 가 브라우저의 픽셀 링(IOSurface 세 장 + 제어 블록 페이지)을 maru 의 받는 port 로 보내는
//! mach 메시지 한 통의 배치. sidecar(`ring_producer.zig`)와 maru(`ring_receiver.zig`)가 같은 정의를 쓴다.
//!
//! 링을 새로 만들 때(첫 그리기·크기 변경)만 보낸다 — 프레임마다가 아니다. 프레임은 제어 블록의 mailbox 워드로만 오간다.

const std = @import("std");
const mach = @import("mach.zig");

pub const message_id: i32 = 0x4D57_4252; // 'MWBR'
pub const slot_count = 3;

/// 본문 인라인 값. C 헤더의 4 바이트 정렬(pack(4))에 맞춰 전부 u32 다.
pub const Payload = extern struct {
    token: [4]u32,
    browser_lo: u32,
    browser_hi: u32,
    generation: u32,
    /// 픽셀 크기(DIP × scale).
    width: u32,
    height: u32,
    scale_bits: u32,

    pub fn browser(self: Payload) u64 {
        return @as(u64, self.browser_hi) << 32 | self.browser_lo;
    }
};

pub const Message = extern struct {
    header: mach.Header,
    body: mach.Body,
    /// 0~2: 링의 IOSurface, 3: 제어 블록 페이지의 메모리 엔트리.
    ports: [slot_count + 1]mach.PortDescriptor,
    payload: Payload,
};

pub const Received = extern struct {
    message: Message,
    trailer: mach.AuditTrailer,
};

comptime {
    std.debug.assert(@sizeOf(Message) == 24 + 4 + 4 * 12 + 40);
}

pub fn tokenWords(token: [16]u8) [4]u32 {
    var words: [4]u32 = undefined;
    for (0..4) |i| words[i] = std.mem.readInt(u32, token[i * 4 ..][0..4], .little);
    return words;
}
