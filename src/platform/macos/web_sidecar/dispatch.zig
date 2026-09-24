//! maru 가 보낸 명령을 풀어 처리한다(W1b). CEF 를 모른다 — 브라우저 동작은 `Handler` 가 맡고, 이 파일은 frame 순서·
//! 방향·오류 시 닫기 규약만 든다. 그래서 CEF SDK 없이 일반 CI 에서 시험이 돈다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const events = @import("events.zig");
const inbox_mod = @import("inbox.zig");

const Message = protocol.message.Message;

pub const Outcome = enum { keep_running, quit };

/// 브라우저 명령을 실제로 수행하는 쪽(`browsers.zig` — CEF). 시험은 거절하는 처리기를 끼운다.
pub const Handler = struct {
    context: *anyopaque,
    browser_command: *const fn (context: *anyopaque, message: Message, writer: *events.Writer) void,
};

pub const HandshakeError = error{ ChannelClosed, NotHello } || protocol.wire.Error;

pub const Dispatcher = struct {
    decoder: protocol.stream.StreamingDecoder = .init(.to_sidecar),
    writer: *events.Writer,
    handler: Handler,
    /// 읽었지만 decoder 에 아직 못 들어간 바이트. decoder 는 받을 수 있는 만큼만 받으므로(W1a) frame 을 비운 뒤 이것부터
    /// 넣는다 — 조각을 통째로 넣던 판은 반쯤 온 큰 frame 뒤에 조각이 오면 정상 명령에도 채널을 닫았다(적대 검증).
    carry: [16 * 1024]u8 = undefined,
    carry_len: usize = 0,
    /// 한 번 `quit` 을 돌려주면 이후 명령은 처리하지 않는다 — 메시지 루프가 끝나기 전에 올라온 task 가 shutdown 뒤의 명령을
    /// 브라우저 처리기로 넘기던 것(적대 검증 재현: shutdown 직후 create 5 개가 모두 처리됐다).
    stopped: bool = false,

    /// carry 를 decoder 에 넣을 수 있는 만큼 넣는다. 넣은 수를 돌려준다.
    fn feedCarry(self: *Dispatcher) protocol.wire.Error!usize {
        const n = try self.decoder.feed(self.carry[0..self.carry_len]);
        std.mem.copyForwards(u8, self.carry[0 .. self.carry_len - n], self.carry[n..self.carry_len]);
        self.carry_len -= n;
        return n;
    }

    /// 첫 frame 은 `hello` 여야 한다. 막힘 읽기로 기다리고, 같은 읽기에 딸려 온 뒤 명령은 decoder 에 남긴다.
    pub fn readHello(self: *Dispatcher, fd: c_int) HandshakeError!protocol.message.Hello {
        while (true) {
            if (try self.decoder.next()) |message| {
                return switch (message) {
                    .hello => |hello| hello,
                    else => error.NotHello,
                };
            }
            if (self.carry_len == 0) {
                const n = std.c.read(fd, &self.carry, self.carry.len);
                if (n < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
                if (n <= 0) return error.ChannelClosed;
                self.carry_len = @intCast(n);
            }
            _ = try self.feedCarry();
        }
    }

    /// 상자에 쌓인 명령을 모두 처리한다(CEF UI 스레드). `quit` 이면 메시지 루프를 끝낸다.
    pub fn drain(self: *Dispatcher, inbox: *inbox_mod.Inbox) Outcome {
        if (self.stopped) return .quit;
        const outcome = self.drainOnce(inbox);
        if (outcome == .quit) self.stopped = true;
        return outcome;
    }

    fn drainOnce(self: *Dispatcher, inbox: *inbox_mod.Inbox) Outcome {
        while (true) {
            // ① decoder 에 쌓인 frame 을 모두 처리한다.
            while (true) {
                const message = (self.decoder.next() catch |err| return self.violation(@errorName(err))) orelse break;
                if (self.handle(message) == .quit) return .quit;
            }
            // ② 못 넣은 바이트가 있으면 먼저 넣는다. frame 을 다 비웠는데 한 바이트도 못 넣으면 불변식이 깨진 것이다.
            if (self.carry_len > 0) {
                const n = self.feedCarry() catch |err| return self.violation(@errorName(err));
                if (n == 0) return self.violation("decoder made no progress");
                continue;
            }
            // ③ 상자에서 더 꺼낸다.
            const taken = inbox.take(&self.carry);
            if (taken.overflow) return self.violation("command inbox overflow");
            self.carry_len = taken.len;
            if (taken.len == 0) {
                // maru 가 사라졌다 — 알릴 곳이 없으니 조용히 끝낸다. frame 중간에서 끊겼어도 마찬가지다.
                return if (taken.closed) .quit else .keep_running;
            }
        }
    }

    fn handle(self: *Dispatcher, message: Message) Outcome {
        switch (message) {
            .shutdown => return .quit,
            .hello => return self.violation("second hello"),
            .create_browser, .destroy_browser, .resize, .set_hidden, .set_focus, .navigate, .frame_channel => {
                self.handler.browser_command(self.handler.context, message, self.writer);
                return .keep_running;
            },
            // 방향이 다른 tag 는 decoder 가 이미 거절했다.
            .hello_ack, .browser_created, .browser_closed, .title_changed, .load_finished, .renderer_gone, .failure => unreachable,
        }
    }

    /// 프로토콜 위반은 알리고 채널을 닫는다(재동기화하지 않는다 — C2).
    fn violation(self: *Dispatcher, detail: []const u8) Outcome {
        self.writer.send(.{ .failure = .{ .browser = 0, .code = .protocol_violation, .detail = detail } }) catch {};
        return .quit;
    }
};

// ── 시험: 파이프 두 개로 maru 쪽을 흉내 낸다 ───────────────────────────────────────────────

const Pipes = struct {
    to_sidecar: [2]c_int,
    to_maru: [2]c_int,

    fn open() !Pipes {
        var p: Pipes = undefined;
        if (std.c.pipe(&p.to_sidecar) != 0 or std.c.pipe(&p.to_maru) != 0) return error.PipeFailed;
        return p;
    }

    fn close(p: *Pipes) void {
        for ([_]*c_int{ &p.to_sidecar[0], &p.to_sidecar[1], &p.to_maru[0], &p.to_maru[1] }) |fd| closeOne(fd);
    }
};

/// 시험 도중 한쪽 끝을 먼저 닫을 때 쓴다 — 뒤의 `Pipes.close` 가 같은 번호를 다시 닫지 않게 -1 로 둔다.
fn closeOne(fd: *c_int) void {
    if (fd.* >= 0) _ = std.c.close(fd.*);
    fd.* = -1;
}

fn writeFrame(fd: c_int, message: Message) !void {
    var buf: [protocol.wire.max_frame_bytes]u8 = undefined;
    const len = try protocol.codec.encode(message, &buf);
    if (std.c.write(fd, &buf, len) != @as(isize, @intCast(len))) return error.WriteFailed;
}

/// 파이프에 쌓인 알림을 모두 풀어 `out` 에 담는다(글 slice 는 `storage` 를 빌린다).
fn readEvents(fd: c_int, storage: []u8, out: []Message) ![]Message {
    const n = std.c.read(fd, storage.ptr, storage.len);
    if (n < 0) return error.ReadFailed;
    var decoder = protocol.stream.StreamingDecoder.init(.to_maru);
    // 시험 알림은 작다 — 한 번에 다 들어가야 한다.
    if (try decoder.feed(storage[0..@intCast(n)]) != @as(usize, @intCast(n))) return error.TestUnexpectedResult;
    var count: usize = 0;
    while (try decoder.next()) |message| : (count += 1) {
        out[count] = message;
        // decoder 가 돌려준 slice 는 다음 next 전까지만 유효하다 — 시험은 tag 와 고정 필드만 본다.
    }
    return out[0..count];
}

/// 시험용 처리기 — 브라우저가 없는 host 처럼 대상 브라우저를 모른다고 답한다.
fn rejectBrowserCommand(_: *anyopaque, message: Message, writer: *events.Writer) void {
    const browser: protocol.message.BrowserId = switch (message) {
        .create_browser => |value| value.browser,
        .destroy_browser => |browser| browser,
        .resize => |value| value.browser,
        .set_hidden, .set_focus => |value| value.browser,
        .navigate => |value| value.browser,
        else => 0,
    };
    const code: protocol.message.FailureCode = if (message == .create_browser) .browser_create_failed else .unknown_browser;
    writer.send(.{ .failure = .{ .browser = browser, .code = code, .detail = "browsers are not implemented yet (W1c)" } }) catch {};
}

fn testDispatcher(writer: *events.Writer) Dispatcher {
    return .{ .writer = writer, .handler = .{ .context = undefined, .browser_command = &rejectBrowserCommand } };
}

test "hello is read first and commands that arrive with it stay queued" {
    var pipes = try Pipes.open();
    defer pipes.close();
    try writeFrame(pipes.to_sidecar[1], .{ .hello = .{ .instance = 7, .nonce = 99 } });
    try writeFrame(pipes.to_sidecar[1], .shutdown);

    var writer: events.Writer = .{ .fd = pipes.to_maru[1] };
    var dispatcher = testDispatcher(&writer);
    const hello = try dispatcher.readHello(pipes.to_sidecar[0]);
    try std.testing.expectEqual(@as(u64, 99), hello.nonce);

    var inbox: inbox_mod.Inbox = .{ .io = std.testing.io };
    try std.testing.expectEqual(Outcome.quit, dispatcher.drain(&inbox));
}

test "a first frame other than hello is refused" {
    var pipes = try Pipes.open();
    defer pipes.close();
    try writeFrame(pipes.to_sidecar[1], .shutdown);
    var writer: events.Writer = .{ .fd = pipes.to_maru[1] };
    var dispatcher = testDispatcher(&writer);
    try std.testing.expectError(error.NotHello, dispatcher.readHello(pipes.to_sidecar[0]));
}

test "closed command channel before hello is reported, not waited on" {
    var pipes = try Pipes.open();
    defer pipes.close();
    closeOne(&pipes.to_sidecar[1]);
    var writer: events.Writer = .{ .fd = pipes.to_maru[1] };
    var dispatcher = testDispatcher(&writer);
    try std.testing.expectError(error.ChannelClosed, dispatcher.readHello(pipes.to_sidecar[0]));
}

test "browser commands reach the handler, and the loop keeps running" {
    var pipes = try Pipes.open();
    defer pipes.close();
    var writer: events.Writer = .{ .fd = pipes.to_maru[1] };
    var dispatcher = testDispatcher(&writer);

    var frame: [256]u8 = undefined;
    var inbox: inbox_mod.Inbox = .{ .io = std.testing.io };
    var len = try protocol.codec.encode(.{ .create_browser = .{ .browser = 5, .size = .{ .width = 10, .height = 10, .scale = 2 }, .hidden = false, .url = "about:blank" } }, &frame);
    inbox.push(frame[0..len]);
    len = try protocol.codec.encode(.{ .set_hidden = .{ .browser = 6, .value = true } }, &frame);
    inbox.push(frame[0..len]);
    try std.testing.expectEqual(Outcome.keep_running, dispatcher.drain(&inbox));

    var storage: [1024]u8 = undefined;
    var out: [4]Message = undefined;
    const got = try readEvents(pipes.to_maru[0], &storage, &out);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(protocol.message.FailureCode.browser_create_failed, got[0].failure.code);
    try std.testing.expectEqual(@as(u64, 5), got[0].failure.browser);
    try std.testing.expectEqual(protocol.message.FailureCode.unknown_browser, got[1].failure.code);
}

test "garbage, a second hello, and overflow each close the channel with protocol_violation" {
    const cases = [_][]const u8{ "garbage", "hello", "overflow" };
    for (cases) |case| {
        var pipes = try Pipes.open();
        defer pipes.close();
        var writer: events.Writer = .{ .fd = pipes.to_maru[1] };
        var dispatcher = testDispatcher(&writer);
        const inbox = try std.testing.allocator.create(inbox_mod.Inbox);
        defer std.testing.allocator.destroy(inbox);
        inbox.* = .{ .io = std.testing.io };

        var frame: [64]u8 = undefined;
        if (std.mem.eql(u8, case, "garbage")) {
            inbox.push("\x00\x00\x00\x07NOTMWEB");
        } else if (std.mem.eql(u8, case, "hello")) {
            const len = try protocol.codec.encode(.{ .hello = .{ .instance = 1, .nonce = 2 } }, &frame);
            inbox.push(frame[0..len]);
        } else {
            inbox.overflow = true;
        }
        try std.testing.expectEqual(Outcome.quit, dispatcher.drain(inbox));

        var storage: [1024]u8 = undefined;
        var out: [2]Message = undefined;
        const got = try readEvents(pipes.to_maru[0], &storage, &out);
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqual(protocol.message.FailureCode.protocol_violation, got[0].failure.code);
    }
}

test "end of file quits silently, even mid-frame" {
    var pipes = try Pipes.open();
    defer pipes.close();
    var writer: events.Writer = .{ .fd = pipes.to_maru[1] };
    var dispatcher = testDispatcher(&writer);
    var inbox: inbox_mod.Inbox = .{ .io = std.testing.io };
    inbox.push("\x00\x00\x00\x20MWEB"); // 선언한 길이보다 짧게 끊겼다
    inbox.close();
    try std.testing.expectEqual(Outcome.quit, dispatcher.drain(&inbox));
    closeOne(&pipes.to_maru[1]);
    var storage: [64]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), std.c.read(pipes.to_maru[0], &storage, storage.len));
}

test "a partly arrived large command followed by more bytes is queued, not refused" {
    var pipes = try Pipes.open();
    defer pipes.close();
    var writer: events.Writer = .{ .fd = pipes.to_maru[1] };
    var dispatcher = testDispatcher(&writer);
    const inbox = try std.testing.allocator.create(inbox_mod.Inbox);
    defer std.testing.allocator.destroy(inbox);
    inbox.* = .{ .io = std.testing.io };
    // 적대 검증 재현: 10KB·30KB·30KB URL 이동 셋 — 조각을 통째로 넣던 판은 RetainedInputOverflow 로 채널을 닫았다.
    var frame: [protocol.wire.max_frame_bytes]u8 = undefined;
    for ([_]usize{ 10 * 1024, 30 * 1024, 30 * 1024 }) |url_len| {
        var url: [30 * 1024]u8 = undefined;
        @memset(url[0..url_len], 'a');
        const len = try protocol.codec.encode(.{ .navigate = .{ .browser = 1, .url = url[0..url_len] } }, &frame);
        inbox.push(frame[0..len]);
    }
    try std.testing.expectEqual(Outcome.keep_running, dispatcher.drain(inbox));
    var storage: [4096]u8 = undefined;
    var out: [4]Message = undefined;
    const got = try readEvents(pipes.to_maru[0], &storage, &out);
    // 세 이동 모두 처리됐다(브라우저가 없는 시험 처리기라 셋 다 unknown_browser) — protocol_violation 은 없다.
    try std.testing.expectEqual(@as(usize, 3), got.len);
    for (got) |event| try std.testing.expectEqual(protocol.message.FailureCode.unknown_browser, event.failure.code);
}

test "commands that arrive after shutdown are not handed to the browser handler" {
    var pipes = try Pipes.open();
    defer pipes.close();
    var writer: events.Writer = .{ .fd = pipes.to_maru[1] };
    var dispatcher = testDispatcher(&writer);
    var inbox: inbox_mod.Inbox = .{ .io = std.testing.io };
    var frame: [256]u8 = undefined;
    var len = try protocol.codec.encode(.shutdown, &frame);
    inbox.push(frame[0..len]);
    len = try protocol.codec.encode(.{ .destroy_browser = 5 }, &frame);
    inbox.push(frame[0..len]);
    try std.testing.expectEqual(Outcome.quit, dispatcher.drain(&inbox));
    inbox.push(frame[0..len]);
    try std.testing.expectEqual(Outcome.quit, dispatcher.drain(&inbox));
    // 처리기가 불렸다면 unknown_browser 알림이 있었을 것이다.
    closeOne(&pipes.to_maru[1]);
    var storage: [64]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), std.c.read(pipes.to_maru[0], &storage, storage.len));
}
