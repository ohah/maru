//! 앱 쪽 이미지 채널 수립 — connect 함수가 주 연결 hello 뒤에 두 번째 연결을 열어 host 에 묶는다.
//!
//! 단일 출처는 [Session host 이미지 채널](../../../../docs/session-host-image-channel.md) §3.1·§3.2 다.
//!
//! - 앱은 hello 에 `image_shm` 을 실을 때만 채널을 연다(`Request.advertise`). 광고는 `client_kind` 가 아니라 호출 자리가 정한다 —
//!   이미지 채널 리더·세그먼트 표·resolver 를 설치하는 GUI 제품 호출자만 넘긴다(IC6). 그 전에는 판정자만 넘긴다.
//! - hello_ack 에 `image_shm` 이 없으면 host 가 이미지 채널을 모른다(또는 제공하지 않는다) — 미협상, 형식은 `image_blob`.
//! - `image_shm` 은 있는데 token 이 없으면 「자리 없음」 — 협상은 됐고 채널은 없다(`unavailable`).
//! - token 이 있으면 채널을 열어 `bind_ack` 를 기다린다. 실패는 **연결 실패로 올라가지 않는다** — 주 연결을 `unavailable` 로
//!   돌려준다. 연결 실패로 올리면 앱 시작 경로가 「이 host 에 못 붙는다」로 읽고 host 를 하나 더 띄운다.
//!   - 거부(`ImageChannelUnavailable` — 채널 hello 를 보낸 뒤의 EOF·`bind_ack` 형식 오류): host 가 응답하고 있다는 뜻이라
//!     abandon 을 응답까지 읽어 token 을 바로 돌려준다.
//!   - 시간 초과·연결 단계 실패(`ImageChannelTimedOut`): host owner 가 밀려 있을 수 있다 — listen backlog 가 차면 커널이 곧바로
//!     ECONNREFUSED 를 준다(실측). 같은 owner 가 abandon 에도 늦게 답해 그 왕복이 연결을 실패시킬 수 있으므로 abandon 없이 채널
//!     소켓만 닫는다. token 은 host 의 만료로, 늦게 묶인 채널은 EOF 로 풀린다.
//!
//! 채널 소켓은 `client_deadline.connectUnixUntil` 로 만든다 — CLOEXEC·NONBLOCK·SO_NOSIGPIPE 가 켜진다. 앱은 SIGPIPE 를 전역으로
//! 잡지 않으므로 SO_NOSIGPIPE 가 없으면 host 가 닫은 채널에 release 를 쓰는 순간 프로세스가 signal 13 으로 죽는다. 판정자는 소켓
//! 옵션을 직접 잰다 — 테스트 러너는 SIGPIPE 를 무시하도록 처리기를 걸어 두어 EPIPE 만으로는 옵션이 빠진 것을 못 본다.
//! 소켓은 논블로킹으로 남긴다 — IC3 의 채널 리더와 release 송신은 논블로킹이다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const framing = @import("framing.zig");
const client_deadline = @import("client_deadline.zig");
const image_channel_wire = @import("image_channel_wire.zig");

/// connect 함수에 넘기는 광고 여부. `client_kind` 로 정하지 않는다 — `.gui` 로 붙지만 resolver 없이 조립기를 쓰는 소비자가 있다.
pub const Request = enum { off, advertise };

pub const State = enum(u8) {
    /// 광고하지 않았거나 host 가 제공하지 않았다 — 형식은 `image_blob`(이미지 채널 §2).
    not_negotiated,
    /// 협상했고 채널이 묶였다.
    bound,
    /// 협상했지만 채널이 없다(자리 없음·수립 실패·채널 상실) — host 는 placement 를 빼고 보낸다(§3.2).
    unavailable,
};

/// `Client` 가 쥐는 이미지 채널의 끝(fd)과 상태. 받은 세그먼트 fd 는 IC3 의 세그먼트 표(따로 둔 Client 필드)가 쥔다(§6). `Client` 이동은 구조체째 옮기고 남은
/// 자리를 기본값으로 다시 만들므로 fd 가 두 주인을 갖지 않는다.
pub const Channel = struct {
    fd: c.fd_t = -1,
    state: State = .not_negotiated,

    pub fn deinit(self: *Channel) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

/// `bind_ack` 대기에서 abandon 왕복 몫으로 남겨 두는 예산(§3.2). 응답 한 frame 이라 짧다.
pub const abandon_reserve_ns: i128 = 500 * std.time.ns_per_ms;
/// deadline 이 없는 블로킹 connect 경로가 채널 수립에 쓰는 예산 — 그 경로의 read timeout(5 초)과 같다.
pub const blocking_budget_ns: i128 = 5 * std.time.ns_per_s;

pub const OpenError = error{ ImageChannelUnavailable, ImageChannelTimedOut };

pub const OfferError = error{ OutOfMemory, MalformedHelloAck };

/// hello_ack 이 말하는 제공 상태.
pub const Offer = struct {
    /// host 가 이미지 채널을 제공한다(hello_ack 기능 목록의 `image_shm`).
    offered: bool,
    /// 이 연결에 확보된 자리. 제공하지만 null 이면 「자리 없음」.
    token: ?u128,
};

/// 해석하지 못한 hello_ack 은 「미제공」으로 삼키지 않는다 — 앱이 미협상으로 읽는 사이 host 는 협상한 것으로 보고 `image_ref`
/// 를 낸다. `finishHello` 는 부분문자열로만 읽으므로 JSON 으로 못 읽는 payload 가 여기까지 올 수 있다.
pub fn parseOffer(allocator: std.mem.Allocator, payload: []const u8) OfferError!Offer {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedHelloAck,
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedHelloAck,
    };
    const offered = offered: {
        const caps = obj.get("capabilities") orelse break :offered false;
        const items = switch (caps) {
            .array => |array| array.items,
            else => break :offered false,
        };
        for (items) |item| switch (item) {
            .string => |name| if (std.mem.eql(u8, name, image_channel_wire.capability)) break :offered true,
            else => {},
        };
        break :offered false;
    };
    // 제공하지 않는 host 의 token 은 믿지 않는다 — 형식 선택은 기능 목록이 정한다.
    if (!offered) return .{ .offered = false, .token = null };
    // 망가진 token 을 「자리 없음」으로 넘기면 host 가 잡아 둔 자리가 만료(10 초)까지 묶인다 — 해석 실패로 올린다.
    const token = switch (obj.get("image_channel_token") orelse return .{ .offered = true, .token = null }) {
        .string => |text| image_channel_wire.parseToken(text) orelse return error.MalformedHelloAck,
        else => return error.MalformedHelloAck,
    };
    return .{ .offered = true, .token = token };
}

/// `bind_ack` 대기 예산 — 바깥 deadline 에서 abandon 몫을 뺀 것. 남는 것이 없으면 null(채널을 열지 않는다).
pub fn bindDeadline(outer: client_deadline.AbsoluteDeadline) ?client_deadline.AbsoluteDeadline {
    const expires = std.math.sub(i128, outer.expires_at_ns, abandon_reserve_ns) catch return null;
    var inner = outer;
    inner.expires_at_ns = expires;
    return if (inner.remainingNs() > 0) inner else null;
}

/// 채널 hello payload — `role` 을 맨 앞에 둔다(host 는 다른 필드보다 먼저 본다).
pub fn helloPayload(buf: []u8, token: u128, wire_major: u16) error{NoSpaceLeft}![]u8 {
    const text = image_channel_wire.formatToken(token);
    return std.fmt.bufPrint(
        buf,
        "{{\"role\":\"{s}\",\"token\":\"{s}\",\"protocol_min\":{d},\"protocol_max\":{d}}}",
        .{ image_channel_wire.role, &text, wire_major, wire_major },
    );
}

/// 두 번째 연결을 열어 채널 hello 를 보내고 `bind_ack` 를 받는다. 성공하면 논블로킹 채널 fd 를 돌려준다(호출자 소유).
pub fn open(
    allocator: std.mem.Allocator,
    ops: client_deadline.Ops,
    socket_path: [:0]const u8,
    token: u128,
    wire_major: u16,
    deadline: client_deadline.AbsoluteDeadline,
) OpenError!c.fd_t {
    // 연결 단계의 실패는 host 의 응답이 아니다(backlog 가 차면 커널이 곧바로 거부한다) — abandon 하지 않는 쪽으로 분류한다.
    const connected = client_deadline.connectUnixUntil(ops, socket_path, deadline) catch
        return error.ImageChannelTimedOut;
    errdefer ops.close(ops.context, connected.fd);
    var payload_buf: [160]u8 = undefined;
    const payload = helloPayload(&payload_buf, token, wire_major) catch return error.ImageChannelUnavailable;
    const frame = framing.encodeFrame(
        allocator,
        .{ .kind = .hello, .request_id = 0, .major = wire_major },
        payload,
    ) catch return error.ImageChannelUnavailable;
    defer allocator.free(frame);
    client_deadline.writeAllUntil(ops, connected.fd, frame, deadline) catch |err| return classify(err);
    var ack: [image_channel_wire.bind_ack_len]u8 = undefined;
    var got: usize = 0;
    while (got < ack.len) {
        // 정확히 `bind_ack` 만큼만 읽는다 — 그 뒤의 세그먼트 메시지(fd 붙음)는 IC3 리더가 recvmsg 로 받아야 한다.
        got += client_deadline.readSomeUntil(ops, connected.fd, ack[got..], deadline) catch |err|
            return classify(err);
    }
    image_channel_wire.decodeBindAck(&ack) catch return error.ImageChannelUnavailable;
    return connected.fd;
}

fn classify(err: client_deadline.Error) OpenError {
    return if (err == error.Timeout) error.ImageChannelTimedOut else error.ImageChannelUnavailable;
}

/// deadline 이 없는 블로킹 connect 경로가 쓰는 단조 시계(`AbsoluteDeadline` 은 `std.Io` 나 주입 시계가 필요하다).
pub fn monotonicDeadline(budget_ns: i128) client_deadline.AbsoluteDeadline {
    const source: client_deadline.ClockSource = .{ .context = @ptrFromInt(1), .now_ns = monotonicNowNs };
    return client_deadline.AbsoluteDeadline.fromInjected(source, monotonicNowNs(source.context) +| budget_ns);
}

fn monotonicNowNs(_: *anyopaque) i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.UPTIME_RAW, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

const testing = std.testing;

test "client image channel: hello_ack 이 제공·자리·미제공을 가른다" {
    const a = testing.allocator;
    const offered = try parseOffer(a, "{\"capabilities\":[\"host.info\",\"image_shm\"],\"image_channel_token\":\"0123456789abcdeffedcba9876543210\"}");
    try testing.expect(offered.offered);
    try testing.expectEqual(@as(?u128, 0x0123456789abcdef_fedcba9876543210), offered.token);

    // 제공하지만 token 이 없다 — 자리 없음.
    const no_seat = try parseOffer(a, "{\"capabilities\":[\"image_shm\"]}");
    try testing.expect(no_seat.offered);
    try testing.expectEqual(@as(?u128, null), no_seat.token);

    // 기능 목록에 없으면 token 이 있어도 미제공이다 — 형식은 기능 목록이 정한다.
    const stray = try parseOffer(a, "{\"capabilities\":[\"host.info\"],\"image_channel_token\":\"0123456789abcdeffedcba9876543210\"}");
    try testing.expect(!stray.offered);
    try testing.expectEqual(@as(?u128, null), stray.token);

    // 망가진 token 은 해석 실패다 — 자리 없음으로 넘기면 host 의 자리가 만료까지 묶인다.
    try testing.expectError(error.MalformedHelloAck, parseOffer(a, "{\"capabilities\":[\"image_shm\"],\"image_channel_token\":\"xyz\"}"));
    try testing.expectError(error.MalformedHelloAck, parseOffer(a, "{\"capabilities\":[\"image_shm\"],\"image_channel_token\":7}"));
    try testing.expectError(error.MalformedHelloAck, parseOffer(a, "not json"));
    try testing.expectError(error.MalformedHelloAck, parseOffer(a, "[1]"));
    try testing.expectError(error.OutOfMemory, parseOffer(testing.failing_allocator, "{\"capabilities\":[\"image_shm\"]}"));
}

test "client image channel: bind_ack 예산은 abandon 몫을 남기고 남는 것이 없으면 열지 않는다" {
    const Clock = struct {
        now: i128,
        fn read(ctx: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.now;
        }
    };
    var clock: Clock = .{ .now = 1_000 };
    const source: client_deadline.ClockSource = .{ .context = &clock, .now_ns = Clock.read };
    const outer = client_deadline.AbsoluteDeadline.fromInjected(source, 1_000 + 2 * abandon_reserve_ns);
    const inner = bindDeadline(outer) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(outer.expires_at_ns - abandon_reserve_ns, inner.expires_at_ns);
    // abandon 몫만 남았으면 채널을 열지 않는다 — 열면 abandon 을 읽을 시간이 없다.
    clock.now = 1_000 + abandon_reserve_ns;
    try testing.expectEqual(@as(?client_deadline.AbsoluteDeadline, null), bindDeadline(outer));
}

test "client image channel: 블로킹 경로의 단조 deadline 은 예산만큼 남는다" {
    // 단위가 어긋나면(ns 대신 ms 등) 예산이 사실상 무한이 되어 host 가 bind_ack 를 안 보낼 때 블로킹 connect 가 멈춘다.
    const deadline = monotonicDeadline(blocking_budget_ns);
    const remaining = deadline.remainingNs();
    try testing.expect(remaining > 0 and remaining <= blocking_budget_ns);
    try testing.expect(remaining > blocking_budget_ns - std.time.ns_per_s);
    // 시계와 예산이 같은 단위로 어긋나면 위 계산은 맞아 보인다 — 실제로 20 ms 를 자고 시계가 ns 로 그만큼 움직였는지 본다.
    const before = monotonicNowNs(@ptrFromInt(1));
    const pause: c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
    _ = c.nanosleep(&pause, null);
    const elapsed = monotonicNowNs(@ptrFromInt(1)) - before;
    try testing.expect(elapsed >= 15 * std.time.ns_per_ms and elapsed < 2 * std.time.ns_per_s);
}

test "client image channel: 채널 hello 는 role 을 맨 앞에 싣고 host 의 token 파서와 맞는다" {
    var buf: [160]u8 = undefined;
    const payload = try helloPayload(&buf, 0xabc, 2);
    try testing.expect(std.mem.startsWith(u8, payload, "{\"role\":\"image_channel\""));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const token = parsed.value.object.get("token").?.string;
    try testing.expectEqual(@as(?u128, 0xabc), image_channel_wire.parseToken(token));
}
