//! sidecar → maru 알림 쓰기(W1b). UI 스레드 하나만 쓴다 — frame 이 섞이지 않게 여러 스레드에서 부르지 않는다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

pub const Error = protocol.wire.Error || error{ChannelClosed};

pub const Writer = struct {
    fd: c_int,
    buf: [protocol.wire.max_frame_bytes]u8 = undefined,

    pub fn send(self: *Writer, message: protocol.message.Message) Error!void {
        const len = try protocol.codec.encode(message, &self.buf);
        var sent: usize = 0;
        while (sent < len) {
            const n = std.c.write(self.fd, self.buf[sent..len].ptr, len - sent);
            if (n > 0) {
                sent += @intCast(n);
            } else if (n < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) {
                continue;
            } else {
                // maru 가 읽는 쪽을 닫았다(EPIPE) — 더 알릴 곳이 없다.
                return error.ChannelClosed;
            }
        }
    }
};
