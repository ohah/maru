//! sidecar 쪽 픽셀 링(W2, C3). 브라우저마다 IOSurface 세 장과 제어 블록 페이지를 만들어 maru 에 알리고, CEF 가 그릴
//! 때마다 **콜백 안에서** CEF surface 를 back 장에 복사한 뒤 mailbox 와 맞바꾼다(CEF 풀 버퍼는 콜백 밖에서 잡지 않는다).
//! 크기가 바뀌면 세대를 올려 새 링을 만든다 — maru 는 새 링의 첫 프레임이 올 때까지 옛 프레임을 보인다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const mach = @import("mach.zig");
const iosurface = @import("iosurface.zig");
const ring_message = @import("ring_message.zig");

const mailbox = protocol.mailbox;

/// maru 가 `frame_channel` 로 알려 준 받는 port 와 토큰.
pub const Channel = struct {
    port: mach.Port,
    token: [16]u8,

    pub fn connect(service: []const u8, token: [16]u8) error{LookupFailed}!Channel {
        var name: [128:0]u8 = undefined;
        const z = std.fmt.bufPrintZ(&name, "{s}", .{service}) catch return error.LookupFailed;
        var port: mach.Port = mach.null_port;
        if (mach.bootstrap_look_up(mach.bootstrap_port, z, &port) != 0) return error.LookupFailed;
        return .{ .port = port, .token = token };
    }
};

pub const Ring = struct {
    generation: u32,
    width: u32,
    height: u32,
    surfaces: [ring_message.slot_count]iosurface.Ref,
    page: mach.SharedPage,
    back: mailbox.Slot = mailbox.initial_back,

    fn control(self: *Ring) *mailbox.Control {
        return @ptrFromInt(self.page.address);
    }

    fn destroy(self: *Ring) void {
        for (self.surfaces) |surface| iosurface.release(surface);
        self.page.destroy();
    }
};

pub const Producer = struct {
    browser: u64,
    scale: f32,
    ring: ?Ring = null,
    next_generation: u32 = 1,
    /// 알린 프레임 수(관측점).
    published: u64 = 0,

    /// CEF 가 그린 `source` 를 링에 넣는다. 크기가 링과 다르면 새 세대 링을 먼저 만들어 알린다.
    pub fn paint(self: *Producer, channel: *const Channel, source: iosurface.Ref) error{ RingFailed, SendFailed }!void {
        const w: u32 = @intCast(iosurface.width(source));
        const h: u32 = @intCast(iosurface.height(source));
        if (self.ring == null or self.ring.?.width != w or self.ring.?.height != h) try self.replaceRing(channel, w, h);
        var ring = &self.ring.?;
        iosurface.copy(source, ring.surfaces[ring.back]);
        ring.back = mailbox.publish(ring.control(), ring.generation, ring.back) catch unreachable; // 세대는 이 링의 것이다
        self.published += 1;
    }

    pub fn deinit(self: *Producer) void {
        if (self.ring) |*ring| ring.destroy();
        self.ring = null;
    }

    fn replaceRing(self: *Producer, channel: *const Channel, w: u32, h: u32) error{ RingFailed, SendFailed }!void {
        var surfaces: [ring_message.slot_count]iosurface.Ref = undefined;
        var made: usize = 0;
        errdefer for (surfaces[0..made]) |surface| iosurface.release(surface);
        for (&surfaces) |*surface| {
            surface.* = iosurface.create(w, h) catch return error.RingFailed;
            made += 1;
        }
        const page = mach.SharedPage.create() catch return error.RingFailed;
        errdefer page.destroy();
        const generation = self.next_generation;
        const fresh: Ring = .{ .generation = generation, .width = w, .height = h, .surfaces = surfaces, .page = page };
        var ring = fresh;
        ring.control().reset(generation);
        try announce(channel, self.browser, self.scale, &ring);
        // maru 는 옛 링의 surface 를 제 참조로 쥐고 있다 — 우리 몫은 바로 놓아도 옛 프레임이 사라지지 않는다.
        if (self.ring) |*old| old.destroy();
        self.ring = ring;
        self.next_generation += 1;
    }
};

fn announce(channel: *const Channel, browser: u64, scale: f32, ring: *Ring) error{SendFailed}!void {
    var message: ring_message.Message = std.mem.zeroes(ring_message.Message);
    message.header = .{
        .bits = mach.bits(mach.type_copy_send, 0) | mach.bits_complex,
        .size = @sizeOf(ring_message.Message),
        .remote = channel.port,
        .local = mach.null_port,
        .id = ring_message.message_id,
    };
    message.body = .{ .descriptor_count = ring_message.slot_count + 1 };
    for (0..ring_message.slot_count) |i| {
        message.ports[i] = .{ .name = iosurface.machPort(ring.surfaces[i]), .disposition = mach.type_move_send };
    }
    message.ports[ring_message.slot_count] = .{ .name = ring.page.entry, .disposition = mach.type_copy_send };
    message.payload = .{
        .token = ring_message.tokenWords(channel.token),
        .browser_lo = @truncate(browser),
        .browser_hi = @truncate(browser >> 32),
        .generation = ring.generation,
        .width = ring.width,
        .height = ring.height,
        .scale_bits = @bitCast(scale),
    };
    // maru 의 대기열이 차 있으면(누가 넘치게 넣는 중일 수 있다 — 이름은 비밀이 아니다) 짧게만 기다리고 실패로 본다.
    // CEF UI 스레드를 붙잡지 않으려는 것이다. 링을 못 갈았으니 다음 그리기에서 다시 알린다.
    if (mach.mach_msg(&message, mach.msg_send | mach.msg_send_timeout, @sizeOf(ring_message.Message), 0, mach.null_port, 50, mach.null_port) != 0) {
        for (message.ports[0..ring_message.slot_count]) |descriptor| _ = mach.mach_port_deallocate(mach.task(), descriptor.name);
        return error.SendFailed;
    }
}
