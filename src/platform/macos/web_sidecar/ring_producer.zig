//! sidecar 쪽 픽셀 링(W2, C3). 브라우저마다 IOSurface 세 장과 제어 블록 페이지를 만들어 maru 에 알리고, CEF 가 그릴
//! 때마다 **콜백 안에서** CEF surface 를 back 장에 복사한 뒤 mailbox 와 맞바꾼다(CEF 풀 버퍼는 콜백 밖에서 잡지 않는다).
//! 크기(또는 scale)가 바뀌면 세대를 올려 새 링을 만든다 — maru 는 새 링의 첫 프레임이 올 때까지 옛 프레임을 보인다.
//!
//! **못 알린 링은 쥔다(`pending`)**: 받는 port 가 아직 없거나 maru 의 대기열이 차 있으면(이름은 비밀이 아니다 — 누가
//! 넘치게 넣을 수 있다) 새 링을 버리지 않고 그리기를 계속 그 링에 넣으며, `retry_interval_ms` 마다 **알림만** 다시 보낸다.
//! 그리기마다 링을 새로 만들던 판은 대기열이 찬 동안 surface 할당 폭풍이었고, 그리기가 멈춘 정적 페이지는 새 링이 영영
//! 안 왔다(적대 검증). 재시도는 그리기가 없어도 호출자(`browsers.zig`)가 task 로 부른다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const mach = @import("mach.zig");
const iosurface = @import("iosurface.zig");
const ring_message = @import("ring_message.zig");

const mailbox = protocol.mailbox;

/// 알림을 다시 보내는 간격. 알림은 기다리지 않고 보내므로(대기열이 차면 바로 실패) CEF UI 스레드를 붙잡지 않는다.
pub const retry_interval_ms: u64 = 50;

/// maru 가 `frame_channel` 로 알려 준 받는 port 와 토큰.
pub const Channel = struct {
    port: mach.Port,
    token: [16]u8,

    pub fn connect(service: []const u8, token: [16]u8) error{LookupFailed}!Channel {
        var name: [128:0]u8 = undefined;
        const z = std.fmt.bufPrintZ(&name, "{s}", .{service}) catch return error.LookupFailed;
        var port: mach.Port = mach.null_port;
        if (mach.bootstrap_look_up(mach.bootstrap_port, z, &port) != 0 or port == mach.null_port) return error.LookupFailed;
        return .{ .port = port, .token = token };
    }

    pub fn close(self: Channel) void {
        _ = mach.mach_port_deallocate(mach.task(), self.port);
    }
};

pub const Ring = struct {
    generation: u32,
    width: u32,
    height: u32,
    scale: f32,
    surfaces: [ring_message.slot_count]iosurface.Ref,
    page: mach.SharedPage,
    back: mailbox.Slot = mailbox.initial_back,

    fn control(self: *Ring) *mailbox.Control {
        return @ptrFromInt(self.page.address);
    }

    fn fits(self: *const Ring, w: u32, h: u32, scale: f32) bool {
        return self.width == w and self.height == h and self.scale == scale;
    }

    fn destroy(self: *Ring) void {
        for (self.surfaces) |surface| iosurface.release(surface);
        self.page.destroy();
    }
};

pub const Painted = enum {
    /// maru 가 받은 링에 넣었다.
    delivered,
    /// 아직 못 알린 링에 넣었다 — 호출자는 `retryAt()` 에 `flush` 가 불리게 한다.
    pending,
};

pub const Producer = struct {
    browser: u64,
    scale: f32,
    /// maru 가 받은 링.
    ring: ?Ring = null,
    /// 만들었지만 아직 못 알린 링. 그리기는 여기로 가고, 알리면 `ring` 이 된다.
    pending: ?Ring = null,
    next_generation: u32 = 1,
    /// 이 시각(ms) 전에는 알림을 다시 보내지 않는다.
    retry_after_ms: u64 = 0,
    /// 알린 프레임 수(관측점).
    published: u64 = 0,
    /// 알림 실패 수(관측점).
    send_failures: u64 = 0,

    /// CEF 가 그린 `source` 를 링에 넣는다. 크기·scale 이 링과 다르면 새 세대 링을 먼저 만든다. `channel` 이 없으면(아직
    /// `frame_channel` 전) 링에 넣기만 하고 알림은 받는 port 가 생긴 뒤에 간다.
    pub fn paint(self: *Producer, channel: ?*const Channel, source: iosurface.Ref, now_ms: u64) error{RingFailed}!Painted {
        const w: u32 = @intCast(iosurface.width(source));
        const h: u32 = @intCast(iosurface.height(source));
        const ring = try self.ringFor(w, h);
        iosurface.copy(source, ring.surfaces[ring.back]);
        ring.back = mailbox.publish(ring.control(), ring.generation, ring.back) catch |err| switch (err) {
            // maru 가 워드를 망가뜨렸다 — 이 링은 버리고 다음 그리기에서 새로 만든다.
            error.StaleGeneration, error.Corrupt => {
                self.discard(ring);
                return error.RingFailed;
            },
            error.Contended => return error.RingFailed,
        };
        self.published += 1;
        return self.flush(channel, now_ms);
    }

    /// 쥔 링이 있으면 알린다(재시도 간격이 찼을 때만). 그리기 없이도 부를 수 있다.
    pub fn flush(self: *Producer, channel: ?*const Channel, now_ms: u64) Painted {
        const fresh = if (self.pending) |*fresh| fresh else return .delivered;
        const to = channel orelse return .pending;
        if (now_ms < self.retry_after_ms) return .pending;
        announce(to, self.browser, fresh) catch {
            // 한 링의 첫 실패만 알린다 — 대기열을 채우는 공격 동안 재시도마다 찍지 않게.
            if (self.retry_after_ms == 0) std.debug.print("maru-web-host: ring for browser {d} (generation {d}) is waiting — the frame channel did not take it, retrying every {d} ms\n", .{ self.browser, fresh.generation, retry_interval_ms });
            self.send_failures += 1;
            self.retry_after_ms = now_ms + retry_interval_ms;
            return .pending;
        };
        // maru 는 옛 링의 surface 를 제 참조로 쥐고 있다 — 우리 몫은 바로 놓아도 옛 프레임이 사라지지 않는다.
        if (self.ring) |*old| old.destroy();
        self.ring = fresh.*;
        self.pending = null;
        return .delivered;
    }

    /// 쥔 링을 다시 알릴 수 있는 시각. 쥔 링이 없으면 null.
    pub fn retryAt(self: *const Producer) ?u64 {
        if (self.pending == null) return null;
        return self.retry_after_ms;
    }

    /// 받는 쪽이 바뀌었다(두 번째 `frame_channel`) — 지금 링을 새 받는 쪽에 알려야 한다.
    pub fn reannounce(self: *Producer) void {
        self.retry_after_ms = 0;
        if (self.pending != null) {
            if (self.ring) |*old| old.destroy();
            self.ring = null;
            return;
        }
        self.pending = self.ring;
        self.ring = null;
    }

    pub fn deinit(self: *Producer) void {
        if (self.ring) |*ring| ring.destroy();
        if (self.pending) |*ring| ring.destroy();
        self.ring = null;
        self.pending = null;
    }

    /// 이 크기·scale 로 그릴 링. 쥔 링이 맞으면 그것, 없으면 받은 링, 둘 다 안 맞으면 새 세대를 쥔다.
    fn ringFor(self: *Producer, w: u32, h: u32) error{RingFailed}!*Ring {
        if (self.pending) |*fresh| {
            if (fresh.fits(w, h, self.scale)) return fresh;
            fresh.destroy();
            self.pending = null;
        }
        if (self.ring) |*ring| {
            if (ring.fits(w, h, self.scale)) return ring;
        }
        self.pending = try makeRing(self.next_generation, w, h, self.scale);
        self.next_generation += 1;
        self.retry_after_ms = 0;
        return &self.pending.?;
    }

    fn discard(self: *Producer, ring: *Ring) void {
        ring.destroy();
        if (self.pending) |*fresh| {
            if (fresh == ring) self.pending = null;
        }
        if (self.ring) |*shown| {
            if (shown == ring) self.ring = null;
        }
    }
};

fn makeRing(generation: u32, w: u32, h: u32, scale: f32) error{RingFailed}!Ring {
    var surfaces: [ring_message.slot_count]iosurface.Ref = undefined;
    var made: usize = 0;
    errdefer for (surfaces[0..made]) |surface| iosurface.release(surface);
    for (&surfaces) |*surface| {
        surface.* = iosurface.create(w, h) catch return error.RingFailed;
        made += 1;
    }
    const page = mach.SharedPage.create() catch return error.RingFailed;
    var ring: Ring = .{ .generation = generation, .width = w, .height = h, .scale = scale, .surfaces = surfaces, .page = page };
    ring.control().reset(generation);
    return ring;
}

fn announce(channel: *const Channel, browser: u64, ring: *Ring) error{SendFailed}!void {
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
        const port = iosurface.machPort(ring.surfaces[i]);
        if (port == mach.null_port) {
            // 빈 권리를 보내면 maru 는 거절하는데 우리는 성공으로 안다 — 보내지 않고 다음에 다시 만든다.
            for (message.ports[0..i]) |made| _ = mach.mach_port_deallocate(mach.task(), made.name);
            return error.SendFailed;
        }
        message.ports[i] = .{ .name = port, .disposition = mach.type_move_send };
    }
    message.ports[ring_message.slot_count] = .{ .name = ring.page.entry, .disposition = mach.type_copy_send };
    message.payload = .{
        .token = ring_message.tokenWords(channel.token),
        .browser_lo = @truncate(browser),
        .browser_hi = @truncate(browser >> 32),
        .generation = ring.generation,
        .width = ring.width,
        .height = ring.height,
        .scale_bits = @bitCast(ring.scale),
    };
    // 기다리지 않는다 — 대기열이 차 있으면 바로 실패하고 `retry_interval_ms` 뒤 다시 보낸다(CEF UI 스레드를 안 붙잡는다).
    const rc = mach.mach_msg(&message, mach.msg_send | mach.msg_send_timeout, @sizeOf(ring_message.Message), 0, mach.null_port, 0, mach.null_port);
    if (rc == 0) return;
    if (rc == mach.send_timed_out or rc == mach.send_interrupted) {
        // 커널이 메시지를 되돌려 받았다(pseudo-receive) — 옮긴 surface 권리가 돌아왔고, **복사한** 페이지 엔트리와 목적지
        // 권리도 하나씩 더 붙었다(실측 — 풀지 않으면 실패마다 엔트리 이름과 16KB VM 객체가 샜다). 모두 푼다.
        for (message.ports[0..ring_message.slot_count]) |descriptor| _ = mach.mach_port_deallocate(mach.task(), descriptor.name);
        _ = mach.mach_port_deallocate(mach.task(), message.ports[ring_message.slot_count].name);
        _ = mach.mach_port_deallocate(mach.task(), channel.port);
    } else {
        // 권리를 옮기기 전에 실패했다 — 만든 surface 권리만 우리 것이다.
        for (message.ports[0..ring_message.slot_count]) |descriptor| _ = mach.mach_port_deallocate(mach.task(), descriptor.name);
    }
    return error.SendFailed;
}

// ── 시험: 대기열이 찬 port 로 알릴 때 권리가 새지 않는다(실제 mach·IOSurface) ─────────────────────────────

fn sendRefs(name: mach.Port) u32 {
    var refs: u32 = 0;
    if (mach.mach_port_get_refs(mach.task(), name, mach.right_send, &refs) != 0) return std.math.maxInt(u32);
    return refs;
}

test "a failed announce to a full queue hands back every right — no port name or send reference leaks" {
    var port: mach.Port = mach.null_port;
    try std.testing.expectEqual(@as(i32, 0), mach.mach_port_allocate(mach.task(), mach.right_receive, &port));
    defer _ = mach.mach_port_mod_refs(mach.task(), port, mach.right_receive, -1);
    try std.testing.expectEqual(@as(i32, 0), mach.mach_port_insert_right(mach.task(), port, port, mach.type_make_send));
    defer _ = mach.mach_port_deallocate(mach.task(), port);
    const limit: i32 = 1;
    _ = mach.mach_port_set_attributes(mach.task(), port, mach.port_limits_info, &limit, 1);
    // 한 통 넣어 대기열을 채운다.
    var fill: mach.Header = .{ .bits = mach.bits(mach.type_copy_send, 0), .size = @sizeOf(mach.Header), .remote = port, .local = mach.null_port, .id = 1 };
    try std.testing.expectEqual(@as(i32, 0), mach.mach_msg(&fill, mach.msg_send | mach.msg_send_timeout, @sizeOf(mach.Header), 0, mach.null_port, 0, mach.null_port));

    const channel: Channel = .{ .port = port, .token = [_]u8{3} ** 16 };
    var producer: Producer = .{ .browser = 1, .scale = 2 };
    const source = try iosurface.create(32, 16);
    defer iosurface.release(source);
    // 첫 그리기가 링을 만든다 — 그 뒤를 기준으로 잰다.
    try std.testing.expectEqual(Painted.pending, try producer.paint(&channel, source, 0));
    const names_before = mach.portNameCount();
    const entry = producer.pending.?.page.entry;
    for (1..20) |i| {
        try std.testing.expectEqual(Painted.pending, producer.flush(&channel, i * retry_interval_ms));
    }
    try std.testing.expectEqual(@as(u64, 20), producer.send_failures);
    try std.testing.expectEqual(names_before, mach.portNameCount());
    try std.testing.expectEqual(@as(u32, 1), sendRefs(port));
    try std.testing.expectEqual(@as(u32, 1), sendRefs(entry));
    // 실패한 동안 링을 새로 만들지 않았다 — 세대는 그대로 1.
    try std.testing.expectEqual(@as(u32, 1), producer.pending.?.generation);
    producer.deinit();
}

test "a pending ring is retried only after the interval, and a scale-only change makes a new generation" {
    var producer: Producer = .{ .browser = 1, .scale = 1 };
    defer producer.deinit();
    const source = try iosurface.create(8, 8);
    defer iosurface.release(source);
    // 받는 port 가 아직 없다 — 쥐기만 한다.
    try std.testing.expectEqual(Painted.pending, try producer.paint(null, source, 10));
    try std.testing.expectEqual(@as(?u64, 0), producer.retryAt());
    const first = producer.pending.?.generation;
    // 같은 크기의 다음 그리기는 같은 링에 들어간다.
    _ = try producer.paint(null, source, 20);
    try std.testing.expectEqual(first, producer.pending.?.generation);
    // 픽셀 크기가 같아도 scale 이 바뀌면 새 세대다(maru 가 쥔 scale 이 낡지 않게).
    producer.scale = 2;
    _ = try producer.paint(null, source, 30);
    try std.testing.expectEqual(first + 1, producer.pending.?.generation);
}
