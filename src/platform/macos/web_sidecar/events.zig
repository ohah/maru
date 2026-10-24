//! sidecar → maru 알림 쓰기(W1b). UI 스레드 하나만 부른다 — frame 이 섞이지 않게 여러 스레드에서 부르지 않는다.
//!
//! W9d②: CEF 가 뜬 뒤(`startThread`)에는 frame 을 보내는 줄(`out_queue`)에 넣고 쓰는 스레드가 관에 쓴다 — maru 가 잠시 읽지 않아도 UI
//! 스레드가 서지 않게(J7 — 예전의 막히는 쓰기는 48 KiB 뒤에 읽는 쪽이 멈춘 만큼 모든 탭의 UI 일을 세웠다). 본문 frame 은 본문 하나의 자리를
//! 먼저 잡고(`reserveBody` — 없으면 거짓, 부른 쪽은 `busy` 로 끝낸다) 그 안에서만 보낸다. 줄을 켜기 전(handshake·초기화 실패)은 예전처럼 곧장 쓴다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const out_queue = @import("out_queue.zig");

pub const Error = protocol.wire.Error || error{ChannelClosed};

const gpa = std.heap.c_allocator;

pub const Writer = struct {
    fd: c_int,
    buf: [protocol.wire.max_frame_bytes]u8 = undefined,
    queue: ?*out_queue.Queue = null,

    /// 쓰는 스레드를 띄운다(CEF 초기화 뒤 — 그 전의 알림은 곧장 쓴다). 못 띄우면 곧장 쓰는 그대로 둔다.
    pub fn startThread(self: *Writer) void {
        if (self.queue != null) return;
        const q = gpa.create(out_queue.Queue) catch return;
        q.* = .{};
        const t = std.Thread.spawn(.{}, out_queue.Queue.run, .{ q, gpa, self.fd }) catch {
            gpa.destroy(q);
            return;
        };
        // 끝날 때는 `finish` 가 줄을 비우기를 잠시 기다린다 — 스레드는 프로세스와 함께 사라진다(maru 가 읽지 않으면 쓰기에서 멈출 수 있다).
        t.detach();
        self.queue = q;
    }

    pub fn send(self: *Writer, message: protocol.message.Message) Error!void {
        const len = try protocol.codec.encode(message, &self.buf);
        if (self.queue) |q| {
            _ = q.push(gpa, .control, self.buf[0..len]) catch return error.ChannelClosed;
            return;
        }
        return self.writeAll(self.buf[0..len]);
    }

    /// 본문 하나(frame 바이트의 합 `bytes`)의 자리를 잡는다 — 없으면 거짓(기다리지 않는다). 줄을 켜기 전에는 늘 참(곧장 쓴다).
    pub fn reserveBody(self: *Writer, bytes: usize) bool {
        const q = self.queue orelse return true;
        return q.reserveBody(bytes);
    }

    /// 잡은 몫 중 쓰지 않은 것을 돌려준다.
    pub fn releaseBody(self: *Writer, bytes: usize) void {
        if (self.queue) |q| q.releaseBody(bytes);
    }

    /// 잡은 몫 안에서 본문 frame 하나를 보낸다(몫이 모자라면 `ChannelClosed` 와 같이 실패로 — 부른 쪽의 셈이 틀렸다).
    pub fn sendBody(self: *Writer, message: protocol.message.Message) Error!void {
        const len = try protocol.codec.encode(message, &self.buf);
        if (self.queue) |q| {
            const ok = q.push(gpa, .body, self.buf[0..len]) catch return error.ChannelClosed;
            if (!ok) return error.ChannelClosed;
            return;
        }
        return self.writeAll(self.buf[0..len]);
    }

    /// 끝내기 전에 줄이 빌 때까지 잠시 기다린다(마지막 알림 — `failure`·`browser_closed` — 이 maru 에 닿게).
    pub fn finish(self: *Writer) void {
        const q = self.queue orelse return;
        q.drain(2000);
        q.stop();
    }

    fn writeAll(self: *Writer, bytes: []const u8) Error!void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = std.c.write(self.fd, bytes[sent..].ptr, bytes.len - sent);
            if (n > 0) {
                sent += @intCast(n);
            } else if (n < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) {
                continue;
            } else {
                // maru 가 읽는 쪽을 닫았다(EPIPE) — 더 알릴 곳이 없다.
                return error.ChannelClosed;
            }
        }
    }
};

/// 본문 조각 frame 의 머리(조각 바이트 밖)와 끝 frame 의 크기.
pub const body_data_head_bytes: usize = protocol.wire.prefix_len + protocol.wire.common_len + 8 + 4 + 8 + 4 + 2;
pub const body_end_frame_bytes: usize = protocol.wire.prefix_len + protocol.wire.common_len + 8 + 4 + 8 + 1 + 1 + 4 + 8;

/// 본문 하나를 보낼 frame 바이트의 합(조각 frame 들 + 끝 frame) — `reserveBody` 에 쓴다.
pub fn bodyFrameBytes(body_len: usize) usize {
    const chunk = protocol.message.net_body_chunk_bytes;
    const chunks = (body_len + chunk - 1) / chunk;
    return body_len + chunks * body_data_head_bytes + body_end_frame_bytes;
}

test "W9d②: 본문 frame 바이트의 합은 실제로 만드는 frame 들의 합과 같다(자리를 꼭 맞게 잡는다)" {
    var buf: [protocol.wire.max_frame_bytes]u8 = undefined;
    for ([_]usize{ 1, 100, protocol.message.net_body_chunk_bytes, protocol.message.net_body_chunk_bytes + 1, 1024 * 1024 }) |n| {
        var total: usize = 0;
        var off: usize = 0;
        const body = try std.testing.allocator.alloc(u8, n);
        defer std.testing.allocator.free(body);
        @memset(body, 'b');
        while (off < n) {
            const k = @min(protocol.message.net_body_chunk_bytes, n - off);
            total += try protocol.codec.encode(.{ .net_body_data = .{ .browser = 1, .session = 1, .request = 1, .offset = @intCast(off), .bytes = body[off..][0..k] } }, &buf);
            off += k;
        }
        total += try protocol.codec.encode(.{ .net_body_end = .{ .browser = 1, .session = 1, .request = 1, .state = .captured, .size = @intCast(n) } }, &buf);
        try std.testing.expectEqual(total, bodyFrameBytes(n));
    }
}
