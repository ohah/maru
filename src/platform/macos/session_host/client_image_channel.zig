//! 앱 쪽 이미지 채널 수립 — connect 함수가 주 연결 hello 뒤에 두 번째 연결을 열어 host 에 묶는다.
//!
//! 단일 출처는 [Session host 이미지 채널](../../../../docs/session-host-image-channel.md) §3.1·§3.2 다.
//!
//! - 앱은 hello 에 `image_shm` 을 실을 때만 채널을 연다(`Request.advertise`). 광고는 `client_kind` 가 아니라 호출 자리가 정한다 —
//!   이미지 채널 리더·세그먼트 표·resolver 를 설치하는 GUI 제품 호출자만 넘긴다(IC6). 그 전에는 판정자만 넘긴다.
//! - hello_ack 에 `image_shm` 이 없으면 host 가 이미지 채널을 모른다(또는 제공하지 않는다) — 미협상, 형식은 `image_blob`.
//! - `image_shm` 은 있는데 token 이 없으면 「자리 없음」 — 협상은 됐고 채널은 없다(`unavailable`).
//! - token 이 있으면 채널을 열어 채널 hello 를 보내고 **기다리지 않는다**(`start` — 상태 `binding`). `bind_ack` 는 연결의 채널
//!   펌프가 남은 바이트만큼 읽는다(`advanceBind`). 펌프는 먼저 읽고 그다음 마감(`bind_wait_ns`)을 본다. 실패는 **연결 실패로
//!   올라가지 않는다** — 주 연결은 `unavailable` 로 간다. 연결 실패로 올리면 앱 시작 경로가 「이 host 에 못 붙는다」로 읽고 host 를
//!   하나 더 띄운다.
//!   - 연결 단계 실패(`ConnectFailed`): listen backlog 가 차면 커널이 곧바로 ECONNREFUSED 를 준다(실측) — host owner 가 밀려 있을
//!     수 있다.
//!   - hello 송신 실패·채널 EOF·`bind_ack` 형식 오류: 거부.
//!   - 마감까지 `bind_ack` 가 없음: 시간 초과 — 채널 소켓만 닫는다.
//!   어느 쪽도 abandon 을 보내지 않는다 — token 은 늦게 처리된 채널 hello 의 EOF 나 host 의 만료(10 초)로 풀린다. 기다리지 않으니
//!   abandon 응답과 첫 RPC 가 섞일 일도, 메인 스레드·재접속 예산이 `bind_ack` 를 기다릴 일도 없다.
//!
//! 채널 소켓은 `client_deadline.connectUnixUntil` 로 만든다 — CLOEXEC·NONBLOCK·SO_NOSIGPIPE 가 켜진다. 앱은 SIGPIPE 를 전역으로
//! 잡지 않으므로 SO_NOSIGPIPE 가 없으면 host 가 닫은 채널에 release 를 쓰는 순간 프로세스가 signal 13 으로 죽는다. 판정자는 소켓
//! 옵션을 직접 잰다 — 테스트 러너는 SIGPIPE 를 무시하도록 처리기를 걸어 두어 EPIPE 만으로는 옵션이 빠진 것을 못 본다.
//! 소켓은 논블로킹으로 남긴다 — IC3b 의 채널 리더와 release 송신은 논블로킹이다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const framing = @import("framing.zig");
const client_deadline = @import("client_deadline.zig");
const image_channel_wire = @import("image_channel_wire.zig");
const image_channel_tokens = @import("image_channel_tokens.zig");
const client_image_segments = @import("client_image_segments.zig");

/// connect 함수에 넘기는 광고 여부. `client_kind` 로 정하지 않는다 — `.gui` 로 붙지만 resolver 없이 조립기를 쓰는 소비자가 있다.
pub const Request = enum { off, advertise };

pub const State = enum(u8) {
    /// 광고하지 않았거나 host 가 제공하지 않았다 — 형식은 `image_blob`(이미지 채널 §2).
    not_negotiated,
    /// 협상했고 채널이 묶였다.
    bound,
    /// 협상했지만 채널이 없다(자리 없음·수립 실패·채널 상실) — host 는 placement 를 빼고 보낸다(§3.2).
    unavailable,
    /// 협상했고 채널 hello 를 보냈다 — `bind_ack` 를 기다린다(§3.1). host 는 입양 전에는 이 연결의 이미지를 미루고, 묶는 순간
    /// 미룬 stream 을 다시 투영한다. 끝에 붙인다 — canonical 골든의 tag 가 밀리지 않게.
    binding,
};

/// `Client` 가 쥐는 이미지 채널의 끝(fd)과 상태. 받은 세그먼트 fd 는 IC3b 의 세그먼트 표(따로 둔 Client 필드)가 쥔다(§6). `Client` 이동은 구조체째 옮기고 남은
/// 자리를 기본값으로 다시 만들므로 fd 가 두 주인을 갖지 않는다.
pub const Channel = struct {
    fd: c.fd_t = -1,
    state: State = .not_negotiated,
    /// 수립 중에 받은 `bind_ack` 바이트 수와 그 바이트 — 펌프마다 남은 만큼만 읽는다.
    bind_ack_got: u8 = 0,
    bind_ack: [image_channel_wire.bind_ack_len]u8 = @splat(0),
    /// 수립 마감(단조 시계 ns). `binding` 에서만 뜻이 있다.
    bind_expires_ns: i64 = 0,

    pub fn deinit(self: *Channel) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

/// 협상했는데 채널 없이 끝난 이유(§3.2). app.log 한 줄에 싣는다 — 「이미지 채널 없음」이 실제로 어느 원인에서 얼마나 나는지가
/// 회복 경로를 만들지 정하는 근거다.
pub const UnavailableReason = enum {
    /// hello_ack 에 token 이 없다 — host 의 연결·host 자리가 찼다.
    no_seat,
    /// 채널 connect 가 실패했다(listen backlog 가 찼거나 경로가 없다).
    connect_failed,
    /// 세그먼트 표를 잡지 못했다(할당 실패).
    no_table,
    /// host 가 채널을 거부했다(hello 송신 실패·채널 hello 뒤 EOF·`bind_ack` 형식 오류).
    refused,
    /// 마감(`bind_wait_ns`)까지 `bind_ack` 가 없었거나 채널 hello 송신이 시간을 넘겼다 — host owner 가 밀려 있을 수 있다. owner 가
    /// token 만료(10 초)를 넘겨 밀리면 늦게 처리된 채널 hello 는 모르는 token 으로 닫혀 `refused` 로 보인다.
    timed_out,
    /// 묶인 채널을 펌프가 잃었다.
    lost,
};

/// 판정자 전용 — 마지막으로 남긴 이유. 제품 빌드에서는 칸이 없다(void).
pub var last_unavailable_reason: if (builtin.is_test) ?UnavailableReason else void = if (builtin.is_test) null else {};

/// 연결이 「이미지 채널 없음」이 된 순간에 한 번 부른다 — 연결이 실패한 출구(오류 반환)에서는 부르지 않는다. 그 연결의 이미지는
/// placement 째 빠진다(§3.2).
pub fn noteUnavailable(host_id: u128, reason: UnavailableReason) void {
    if (builtin.is_test) {
        last_unavailable_reason = reason;
        return;
    }
    std.log.warn("session host image channel unavailable: host={x:0>32} reason={s} — images are omitted on this connection until reconnect", .{ host_id, @tagName(reason) });
}

/// deadline 이 없는 블로킹 connect 경로가 채널 connect·hello 송신에 쓰는 예산 — 그 경로의 read timeout(5 초)과 같다.
pub const blocking_budget_ns: i128 = 5 * std.time.ns_per_s;
/// `bind_ack` 를 기다리는 마감. 기다림이 펌프 몫이라 넉넉히 준다 — host 의 token 만료(10 초)를 넘기면 늦게 처리된 채널 hello 는
/// 모르는 token 으로 닫히므로(거부) 그보다 조금 길면 충분하다.
pub const bind_wait_ns: i64 = @as(i64, @intCast(image_channel_tokens.token_ttl_ns)) + 2 * std.time.ns_per_s;

pub const StartError = error{
    /// 채널 connect 가 실패했다 — host 의 응답이 아니다.
    ConnectFailed,
    /// 채널 hello 를 보내지 못했다(EPIPE 등 — host 가 닫았다).
    HelloFailed,
    /// 채널 hello 송신이 deadline 안에 끝나지 않았다 — host owner 가 밀려 있다.
    HelloTimedOut,
};

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

/// 채널 hello payload — `role` 을 맨 앞에 둔다(host 는 다른 필드보다 먼저 본다).
pub fn helloPayload(buf: []u8, token: u128, wire_major: u16) error{NoSpaceLeft}![]u8 {
    const text = image_channel_wire.formatToken(token);
    return std.fmt.bufPrint(
        buf,
        "{{\"role\":\"{s}\",\"token\":\"{s}\",\"protocol_min\":{d},\"protocol_max\":{d}}}",
        .{ image_channel_wire.role, &text, wire_major, wire_major },
    );
}

/// 두 번째 연결을 열어 채널 hello 를 보낸다 — `bind_ack` 는 기다리지 않는다(펌프가 `advanceBind` 로 읽는다). 성공하면 논블로킹
/// 채널 fd 를 돌려준다(호출자 소유). `deadline` 은 connect 와 hello 송신에만 쓴다.
pub fn start(
    allocator: std.mem.Allocator,
    ops: client_deadline.Ops,
    socket_path: [:0]const u8,
    token: u128,
    wire_major: u16,
    deadline: client_deadline.AbsoluteDeadline,
) StartError!c.fd_t {
    const connected = client_deadline.connectUnixUntil(ops, socket_path, deadline) catch return error.ConnectFailed;
    errdefer ops.close(ops.context, connected.fd);
    var payload_buf: [160]u8 = undefined;
    const payload = helloPayload(&payload_buf, token, wire_major) catch return error.HelloFailed;
    const frame = framing.encodeFrame(
        allocator,
        .{ .kind = .hello, .request_id = 0, .major = wire_major },
        payload,
    ) catch return error.HelloFailed;
    defer allocator.free(frame);
    client_deadline.writeAllUntil(ops, connected.fd, frame, deadline) catch |err|
        return if (err == error.Timeout) error.HelloTimedOut else error.HelloFailed;
    return connected.fd;
}

/// 수립 중인 채널 상태로 만든다 — 마감은 지금부터 `bind_wait_ns`.
pub fn bindingChannel(fd: c.fd_t) Channel {
    return .{ .fd = fd, .state = .binding, .bind_expires_ns = @intCast(monotonicNowNs(@ptrFromInt(1)) + bind_wait_ns) };
}

pub const BindProgress = enum { pending, bound, refused };

/// 수립 중인 채널에서 `bind_ack` 의 남은 바이트를 읽는다(§3.1). 다 받아 형식이 맞으면 `bound` 로 바꾼다. 호출자는 fork 울타리의
/// 수신 잠금을 든다(§7). 채널 EOF·오류·형식 오류·fd 가 붙은 `bind_ack` 는 거부다. 마감은 호출자가 읽은 **뒤에** 본다
/// (`bindExpired`) — 이미 와 있는 `bind_ack` 를 마감 때문에 버리지 않게.
pub fn advanceBind(channel: *Channel) BindProgress {
    const got = client_image_segments.readBindAck(channel.fd, channel.bind_ack[channel.bind_ack_got..]) catch return .refused;
    channel.bind_ack_got += @intCast(got);
    if (channel.bind_ack_got < channel.bind_ack.len) return .pending;
    image_channel_wire.decodeBindAck(&channel.bind_ack) catch return .refused;
    channel.state = .bound;
    return .bound;
}

/// 수립 마감이 지났는가.
pub fn bindExpired(channel: Channel) bool {
    return monotonicNowNs(@ptrFromInt(1)) >= channel.bind_expires_ns;
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

test "client image channel: 수립 중 채널은 bind_ack 를 나눠 와도 남은 만큼만 읽어 묶고, 형식 오류·EOF·fd 붙은 ack 는 거부한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // 마감은 token 만료보다 길다 — 짧으면 host 가 아직 받아 줄 채널을 앱이 먼저 버린다.
    try testing.expect(bind_wait_ns > image_channel_tokens.token_ttl_ns);
    const Pair = struct {
        fds: [2]c.fd_t,
        fn init() !@This() {
            var fds: [2]c.fd_t = undefined;
            if (c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.TestUnexpectedResult;
            _ = c.fcntl(fds[0], c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
            return .{ .fds = fds };
        }
        fn deinit(self: @This()) void {
            for (self.fds) |fd| if (fd >= 0) {
                _ = c.close(fd);
            };
        }
    };
    const ack = image_channel_wire.encodeBindAck();

    // 나눠 온 ack — 남은 바이트만 읽고, 뒤따르는 세그먼트 바이트는 건드리지 않는다(drain 이 fd 와 함께 받는다).
    {
        const pair = try Pair.init();
        defer pair.deinit();
        var channel = bindingChannel(pair.fds[0]);
        try testing.expect(!bindExpired(channel));
        try testing.expectEqual(BindProgress.pending, advanceBind(&channel));
        _ = c.write(pair.fds[1], &ack, 3);
        try testing.expectEqual(BindProgress.pending, advanceBind(&channel));
        try testing.expectEqual(State.binding, channel.state);
        const tail = @as([4]u8, @splat(0xEE));
        _ = c.write(pair.fds[1], ack[3..].ptr, ack.len - 3);
        _ = c.write(pair.fds[1], &tail, tail.len);
        try testing.expectEqual(BindProgress.bound, advanceBind(&channel));
        try testing.expectEqual(State.bound, channel.state);
        var rest: [8]u8 = undefined;
        try testing.expectEqual(@as(isize, tail.len), c.read(pair.fds[0], &rest, rest.len));
    }
    // 형식 오류·EOF 는 거부다.
    {
        const pair = try Pair.init();
        defer pair.deinit();
        var channel = bindingChannel(pair.fds[0]);
        var wrong = ack;
        wrong[4] = @backingInt(image_channel_wire.Kind.release);
        _ = c.write(pair.fds[1], &wrong, wrong.len);
        try testing.expectEqual(BindProgress.refused, advanceBind(&channel));
    }
    {
        var pair = try Pair.init();
        defer pair.deinit();
        var channel = bindingChannel(pair.fds[0]);
        _ = c.close(pair.fds[1]);
        pair.fds[1] = -1;
        try testing.expectEqual(BindProgress.refused, advanceBind(&channel));
    }
    // fd 가 붙은 ack 는 거부하고 받은 fd 를 닫는다 — 수신 fd 를 쥔 채 두면 새고, 묶으면 그 fd 가 다음 세그먼트 몫으로 잘못 세인다.
    {
        const pair = try Pair.init();
        defer pair.deinit();
        var extra: [2]c.fd_t = undefined;
        if (c.pipe(&extra) != 0) return error.TestUnexpectedResult;
        defer _ = c.close(extra[1]);
        var control: [32]u8 align(@alignOf(c.cmsghdr)) = @splat(0);
        const header: c.cmsghdr = .{ .len = @intCast(@sizeOf(c.cmsghdr) + @sizeOf(c.fd_t)), .level = c.SOL.SOCKET, .type = c.SCM.RIGHTS };
        @memcpy(control[0..@sizeOf(c.cmsghdr)], std.mem.asBytes(&header));
        @memcpy(control[@sizeOf(c.cmsghdr)..][0..@sizeOf(c.fd_t)], std.mem.asBytes(&extra[0]));
        var iov = [_]posix.iovec_const{.{ .base = &ack, .len = ack.len }};
        const msg: c.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = @intCast(std.mem.alignForward(usize, @sizeOf(c.cmsghdr) + @sizeOf(c.fd_t), @sizeOf(u32))),
            .flags = 0,
        };
        if (c.sendmsg(pair.fds[1], &msg, 0) != ack.len) return error.TestUnexpectedResult;
        _ = c.close(extra[0]);
        var channel = bindingChannel(pair.fds[0]);
        try testing.expectEqual(BindProgress.refused, advanceBind(&channel));
        // 받은 사본이 닫혔으면 쓰는 쪽이 EPIPE 다(읽는 끝이 하나도 안 남았다 — 테스트 러너는 SIGPIPE 를 무시한다).
        var pipe_byte = [_]u8{1};
        _ = c.fcntl(extra[1], c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
        const wrote = c.write(extra[1], &pipe_byte, 1);
        try testing.expect(wrote < 0 and posix.errno(wrote) == .PIPE);
    }
    // 마감은 상태 칸 하나다 — 지난 마감은 지났다고 답한다.
    var expired = bindingChannel(-1);
    expired.bind_expires_ns = 0;
    try testing.expect(bindExpired(expired));
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
