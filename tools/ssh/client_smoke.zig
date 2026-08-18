//! **내장 SSH 클라이언트의 실서버 스모크**(계획 S8). 진짜 sshd 와 왕복한다.
//!
//! **제품 경로가 아니다.** 데스크톱의 `maru ssh` 는 시스템 `ssh` 래퍼로 그대로 두고(계약 §3.4),
//! 내장 클라이언트는 모바일용이다. 여기 있는 것은 그 클라이언트를 **데스크톱에서 검증**하기 위한
//! 소켓 어댑터다.
//!
//! **세션 로직은 여기 없다.** 예전에는 핸드셰이크·인증·채널·재키잉을 이 파일이 다 들고 있었는데,
//! 모바일도 **같은 순서**가 필요해 `src/session/ssh/client.zig` 로 옮겼다(S9). 두 벌을 두면
//! 갈리고, 갈리면 한쪽에서만 나는 결함이 생긴다. 이제 이 파일은 **소켓과 판정**만 든다 —
//! 그래서 이 스모크가 초록이면 **모바일이 쓸 코드가 실서버에서 도는 것**이 증명된다.
//!
//! **이 스모크가 못 잡는 것 — 정직하게.**
//!   - **드라이버 오용을 막는 가드**는 원리적으로 못 잡는다 — `client.zig` 가 올바르게 굴기
//!     때문이다(§7.1 보내기 제한·"KEX 밖에서 키 못 갈기"). 단위 테스트가 잡는다.
//!   - **채우는 시점(절반)이 최적인지**는 안 본다. 바닥에서 채워도 전송은 끝난다 — 느려질 뿐이다.
//!   - **재키잉의 호스트키 재검증**도 못 잡는다. 정직한 서버는 매번 같은 키를 낸다.
//!   - 확인한 서버는 **OpenSSH 하나**다.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

const ssh = @import("maru").session.ssh;
const client = ssh.client;

/// 선이 조용해지면 이만큼 기다렸다 포기한다. 로컬 sshd 라 정상 왕복은 밀리초 단위다.
///
/// **멈춤을 행이 아니라 실패로 만든다.** 흐름 제어가 틀리면 서버가 우리를 기다리며 조용히
/// 멈추는데, 안 자르면 스모크가 **행**한다 — CI 에서 행은 실패보다 나쁘다(실측: 우리 윈도를
/// 안 줄이는 변이에서 10분 넘게 안 끝났다).
const read_timeout_s = 20;

/// 소켓 어댑터. **이 struct 가 L4 의 전부다** — 프로토콜은 한 줄도 모른다.
const Socket = struct {
    fd: c.fd_t,

    fn connect(port: u16) !Socket {
        const fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        var addr: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7F00_0001), // 127.0.0.1
            .zero = @splat(0),
        };
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) return error.ConnectFailed;
        const tv: posix.timeval = .{ .sec = read_timeout_s, .usec = 0 };
        _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(posix.timeval));
        // **`SIGPIPE` 로 죽지 않는다.** 상대가 먼저 끊은 뒤 쓰면 기본 동작이 프로세스 종료라,
        // 이름 있는 오류가 아니라 **신호로 죽는다**(실측: exit 141). 소켓을 드는 층이면 어디서나
        // 같은 함정이고, 모바일에서 그것은 앱이 죽는 것이다.
        if (builtin.os.tag == .macos) {
            var on: c_int = 1;
            _ = c.setsockopt(fd, posix.SOL.SOCKET, c.SO.NOSIGPIPE, @ptrCast(&on), @sizeOf(c_int));
        }
        return .{ .fd = fd };
    }

    fn read(self: Socket, buf: []u8) !usize {
        const n = c.read(self.fd, buf.ptr, buf.len);
        // `EAGAIN` 은 위 `SO_RCVTIMEO` 가 만든 것이다 — 상대가 우리를 기다리며 멈춘 자리다.
        if (n < 0) return if (c._errno().* == @intFromEnum(c.E.AGAIN)) error.Stalled else error.ReadFailed;
        if (n == 0) return error.Closed;
        return @intCast(n);
    }

    fn writeAll(self: Socket, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            // Linux 는 `SO_NOSIGPIPE` 가 없어 `send(MSG_NOSIGNAL)` 로 같은 것을 얻는다.
            const n = if (builtin.os.tag == .linux)
                c.send(self.fd, bytes.ptr + off, bytes.len - off, posix.MSG.NOSIGNAL)
            else
                c.write(self.fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    fn close(self: Socket) void {
        _ = c.close(self.fd);
    }
};

var sock: Socket = undefined;
/// 선에서 읽은 바이트를 모아 두는 자리. **층이 요구하는 최악 버퍼**(계약 §3.3).
var in_buf: [1 << 20]u8 = undefined;
var in_len: usize = 0;
var wire_out: [1 << 19]u8 = undefined;
var screen_out: [1 << 19]u8 = undefined;

var cl: client.Client = undefined;
var prng = std.Random.DefaultPrng.init(0x5390);
var got: usize = 0;
var banners: usize = 0;
var banner_seen: [256]u8 = undefined;
var banner_len: usize = 0;

fn fill() !void {
    if (in_len == in_buf.len) return error.InputBufferFull;
    in_len += try sock.read(in_buf[in_len..]);
}

fn consume(n: usize) void {
    std.mem.copyForwards(u8, in_buf[0 .. in_len - n], in_buf[n..in_len]);
    in_len -= n;
}

/// 한 번 먹이고 나온 것을 선에 보낸다. 화면 바이트는 세기만 한다.
var made_progress = false;

/// 한 번 먹이고 나온 것을 선에 보낸다. 화면 바이트는 세기만 한다.
fn pump() !client.State {
    const step = try cl.feed(in_buf[0..in_len], &wire_out, &screen_out);
    made_progress = step.consumed > 0 or step.screen.len > 0 or step.wire.len > 0;
    if (step.consumed > 0) consume(step.consumed);
    if (step.wire.len > 0) try sock.writeAll(step.wire);
    got += step.screen.len;
    // **배너를 받았는지 센다.** 서버가 배너를 켰는데 0 이면 그 경로가 안 돌았다는 뜻이다 —
    // `sanitizeBanner` 는 이 자리 말고는 소비자가 없어서, 안 세면 아무도 그것을 안 쓴다.
    if (step.banner) |b| {
        banners += 1;
        if (banner_len == 0) {
            const n = @min(b.len, banner_seen.len);
            @memcpy(banner_seen[0..n], b[0..n]);
            banner_len = n;
        }
    }
    // **서버가 끊었으면 이유를 남긴다.** 상태만 보면 "닫혔다" 까지만 알고 왜인지는 모른다 —
    // 그 "왜" 가 실서버 붙일 때 유일하게 쓸모 있는 정보다(인증 실패·호스트 거부 등).
    if (step.disconnect) |d| {
        disconnect_reason = d.reason;
        const n = @min(d.description.len, disconnect_seen.len);
        @memcpy(disconnect_seen[0..n], d.description[0..n]);
        disconnect_len = n;
    }
    return step.state;
}

var disconnect_reason: ?client.DisconnectReason = null;
var disconnect_seen: [256]u8 = undefined;
var disconnect_len: usize = 0;

/// 서버가 끊었으면 그 이유를 찍는다. 안 끊었으면 아무것도 안 한다.
fn printDisconnect() void {
    if (disconnect_reason) |r| {
        std.debug.print("[ssh-client-smoke]   서버가 끊었다: reason={d} {s}\n", .{
            @intFromEnum(r), disconnect_seen[0..disconnect_len],
        });
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const port_str = it.next() orelse return fail("포트를 인자로 준다");
    const user = it.next() orelse return fail("사용자 이름을 인자로 준다");
    const key_path = it.next() orelse return fail("개인키 경로를 인자로 준다");
    const expect_bytes_str = it.next() orelse return fail("기대 stdout 바이트 수를 인자로 준다");
    const expect_stderr_str = it.next() orelse return fail("기대 stderr 바이트 수를 인자로 준다");
    const mode = it.next() orelse "pty";
    const window_arg = it.next() orelse "0";

    const port = try std.fmt.parseInt(u16, port_str, 10);
    const expect_bytes = try std.fmt.parseInt(usize, expect_bytes_str, 10);
    const expect_stderr = try std.fmt.parseInt(usize, expect_stderr_str, 10);
    const want_window = try std.fmt.parseInt(u32, window_arg, 10);
    const want_pty = std.mem.eql(u8, mode, "pty");
    // 이 회차의 서버가 배너를 켰나(스크립트가 정한다).
    const expect_banner = std.mem.eql(u8, mode, "banner");
    const want_echo = std.mem.eql(u8, mode, "echo") or std.mem.eql(u8, mode, "rekey-echo") or
        std.mem.eql(u8, mode, "self-rekey");
    // **서버가 끊기를 기대하는 회차**(`MaxAuthTries 0`). `Step.disconnect` 는 이 자리 말고
    // 소비자가 없어서, 이 회차가 없으면 사유·설명 경로를 실서버로는 아무도 안 밟는다.
    const expect_disconnect = std.mem.eql(u8, mode, "disconnect");

    var parsed = try loadKey(key_path);
    defer parsed.clear();

    sock = try Socket.connect(port);
    defer sock.close();

    cl = client.Client.init(.{
        .user = user,
        .secret_key = parsed.secret,
        .size = .{ .cols = 80, .rows = 24 },
        .window = want_window,
        .pty = want_pty,
    }, prng.random());
    defer cl.clear();

    try sock.writeAll(try cl.start(&wire_out));

    // **셸이 뜰 때까지 민다.** 중간에 호스트키를 물으면 승인한다 — 스모크는 방금 만든 일회용
    // 서버라 TOFU 가 그대로 맞다(제품에서는 사용자가 답한다, 계약 §4).
    var rounds: usize = 0;
    while (rounds < 100_000) : (rounds += 1) {
        const st = try pump();
        if (st == .host_key_decision) {
            var fp: [128]u8 = undefined;
            say("호스트키 {s}", .{try cl.hostKeyFingerprint(&fp)});
            cl.acceptHostKey();
            continue;
        }
        if (st == .ready) break;
        if (st == .closed) {
            printDisconnect();
            if (!expect_disconnect) return fail("셸이 뜨기 전에 닫혔다");
            const r = disconnect_reason orelse return fail("끊겼는데 이유가 없다");
            // 실측(OpenSSH 10.2): `MaxAuthTries 0` 이면 사유 2(`protocol error`)에
            // "Too many authentication failures" 가 실려 온다.
            if (@intFromEnum(r) != 2) return fail("끊긴 사유가 2 가 아니다");
            if (disconnect_len == 0) return fail("끊긴 설명이 비었다");
            say("{s}: 서버가 끊었다 — 사유 {d}, 설명 {d}B", .{ mode, @intFromEnum(r), disconnect_len });
            say("OK", .{});
            return;
        }
        try fill();
    }
    if (expect_disconnect) return fail("서버가 끊기를 기대했는데 안 끊었다");
    if (cl.state != .ready) return fail("셸이 안 떴다");
    say("셸 준비됨 ({s})", .{mode});

    // 보내는 회차: **상대가 허락한 만큼만** 나간다(계약 §3.1). 못 보내면 받아서 윈도를 연다.
    var sent: usize = 0;
    if (want_echo) {
        var chunk: [4096]u8 = undefined;
        @memset(&chunk, 'Z');
        while (sent < expect_bytes) {
            const r = try cl.write(chunk[0..@min(chunk.len, expect_bytes - sent)], &wire_out);
            if (r.sent == 0) {
                // **더 읽는 판정은 "버퍼가 비었나" 가 아니라 "진행했나" 다.** 남은 바이트가
                // 불완전 패킷이면 `feed` 가 아무것도 못 하는데, 버퍼가 안 비었다고 안 읽으면
                // **영원히 맴돈다**(실측: `in_len=1088` 에서 무한 spin).
                _ = try pump();
                if (!made_progress) try fill();
                continue;
            }
            try sock.writeAll(r.wire);
            sent += r.sent;
        }
        // **EOF 를 보내야 `cat` 이 끝난다**(§5.3). 안 보내면 서버가 stdin 을 계속 기다린다.
        try sock.writeAll(try cl.eof(&wire_out));
        // **EOF 를 보내야 `cat` 이 끝난다**(§5.3). 안 보내면 서버가 stdin 을 계속 기다린다.
        try sock.writeAll(try cl.eof(&wire_out));
        // **EOF 를 보내야 `cat` 이 끝난다**(§5.3). 안 보내면 서버가 stdin 을 계속 기다린다.
        try sock.writeAll(try cl.eof(&wire_out));
        say("보낸 바이트 {d}", .{sent});
    }

    while (true) {
        const st = try pump();
        if (st == .closed) break;
        if (got >= expect_bytes + expect_stderr and cl.exit_status != null) break;
        // **비울 것이 남았으면 더 안 읽는다** — `feed` 가 버퍼가 차서 멈춘 것일 수 있다.
        if (made_progress and in_len > 0) continue;
        fill() catch |e| switch (e) {
            error.Closed, error.Stalled => break,
            else => return e,
        };
    }

    say("{s}: 화면 {d}B, 보낸 {d}B, 재키잉 {d} 회, 배너 {d} 개, exit-status {?d}", .{ mode, got, sent, cl.rekeys, banners, cl.exit_status });
    if (banners > 0) say("  배너: {s}", .{std.mem.trim(u8, banner_seen[0..banner_len], "\n")});
    // **배너를 기대했는데 0 이면 그 경로가 안 돈 것이다.** 서버가 켰는지는 호출자가 안다.
    if (expect_banner and banners == 0) return fail("배너를 못 받았다 — 그 경로가 안 돌았다");
    if (got < expect_bytes + expect_stderr) return fail("출력이 모자란다 — 흐름 제어가 멈췄을 수 있다");
    say("OK", .{});
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[ssh-client-smoke] " ++ fmt ++ "\n", args);
}

fn fail(comptime msg: []const u8) error{SmokeFailed} {
    std.debug.print("[ssh-client-smoke] FAIL: " ++ msg ++ "\n", .{});
    return error.SmokeFailed;
}

var scratch: [8192]u8 = undefined;
var file_buf: [8192]u8 = undefined;

/// 개인키 파일을 읽어 base64 몸통을 디코딩하고 파싱한다. **PEM 껍데기는 이 층 밖이다.**
fn loadKey(path: []const u8) !ssh.private_key.Parsed {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd = c.open(@ptrCast(&path_z), .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    var raw: [8192]u8 = undefined;
    var len: usize = 0;
    while (len < raw.len) {
        const n = c.read(fd, raw[len..].ptr, raw.len - len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        len += @intCast(n);
    }

    var b64: [8192]u8 = undefined;
    var b64_len: usize = 0;
    var lines = std.mem.splitScalar(u8, raw[0..len], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "-----")) continue;
        @memcpy(b64[b64_len..][0..trimmed.len], trimmed);
        b64_len += trimmed.len;
    }
    const decoder = std.base64.standard.Decoder;
    const out_len = try decoder.calcSizeForSlice(b64[0..b64_len]);
    try decoder.decode(file_buf[0..out_len], b64[0..b64_len]);
    return ssh.private_key.parse(file_buf[0..out_len], "", &scratch, .{});
}
