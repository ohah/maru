//! `maru control --stdio` — **폰이 이 PC 의 컨트롤 플레인에 닿는 길**.
//!
//! 폰은 이미 SSH 로 이 기계에 붙는다. 그 **같은 연결에 채널을 하나 더** 열어 여기서 이 프로그램을
//! 돌리면([컨트롤 플레인 §4a](../../docs/control-plane.md)), 그 채널의 stdin/stdout 이 로컬
//! 컨트롤 소켓과 이어진다. 소켓을 네트워크에 여는 것이 아니라 **그 PC 안에서 그 사용자로 도는
//! 로컬 클라이언트**를 하나 더 두는 것이라, §1 의 보안 모델(peer-cred, 0700)이 그대로 성립한다.
//!
//! **이 프로그램이 지켜야 할 것은 두 줄이다.**
//!
//! 1. **stdout 은 오직 wire 다.** 로그·경고·진단은 전부 stderr 로 간다 — 한 줄만 섞여도 폰의
//!    ndjson 파서가 그 프레임을 잃는다. SSH 가 그 둘을 실제로 가르므로(`CHANNEL_EXTENDED_DATA`)
//!    이 규칙은 선 위에서 강제된다.
//! 2. **바이트를 해석하지 않는다.** 프레임 조립·`hello` 판정·버전 대조는 **폰이** 한다. 여기서
//!    줄을 세거나 다시 묶으면 상한(≈1MiB)과 배압 규칙이 두 곳에 생기고, 두 곳이면 갈린다.
//!
//! **왜 셸에 그냥 명령을 치지 않는가**: 터미널 채널은 pty 라 우리가 보낸 것이 에코로 되돌아오고
//! 프롬프트·색 시퀀스가 섞인다(SSH 계약 §3.4.1). 그래서 pty 없는 `exec` 채널을 따로 쓴다.

const std = @import("std");
const builtin = @import("builtin");
const control_client = @import("control_client.zig");

/// 한 번에 옮기는 크기. 컨트롤 프레임 상한(≈1MiB)보다 작아도 된다 — 우리는 **바이트를 흘릴 뿐**
/// 프레임을 모으지 않으므로, 큰 답은 여러 번에 나뉘어 지나간다.
const chunk_bytes = 16 * 1024;

/// 무엇이 끝을 냈나. **끝은 stderr 로만 말한다**(stdout 은 wire 다).
pub const End = enum {
    /// 폰이 채널을 닫았다(stdin EOF).
    stdin_eof,
    /// maru 가 소켓을 닫았다(앱이 꺼졌거나 인스턴스가 사라졌다).
    socket_eof,
    /// 읽기·쓰기가 실패했다.
    io_error,
};

/// 한 걸음의 결과. **순수 판정**이라 테스트가 그대로 잰다.
pub const Step = union(enum) {
    /// 그만큼 옮겼다.
    moved: usize,
    /// 끝났다.
    ended: End,
};

/// `read` 가 돌려준 값 하나를 뜻으로 바꾼다.
///
/// **0 과 음수를 뭉치면 안 된다** — 0 은 상대가 정상으로 닫은 것이고 음수는 실패다. 뭉치면
/// "정상 종료" 와 "선이 끊겼다" 가 같은 말이 되어, 사용자는 왜 목록이 사라졌는지 못 안다.
pub fn classifyRead(n: isize, eof_end: End) Step {
    if (n > 0) return .{ .moved = @intCast(n) };
    if (n == 0) return .{ .ended = eof_end };
    return .{ .ended = .io_error };
}

/// 쓰기 한 번의 결과. **"못 썼다" 를 한 갈래로 두면 안 된다** — 상대가 닫아서 못 쓴 것
/// (`EPIPE`·`ECONNRESET`)은 **정상 종료**이고, 그 밖은 실패다.
pub const WriteEnd = enum { ok, closed, failed };

/// `write` 가 실패했을 때 그 `errno` 를 뜻으로 바꾼다.
pub fn classifyWriteErrno(err: std.c.E) WriteEnd {
    return switch (err) {
        .PIPE, .CONNRESET => .closed,
        else => .failed,
    };
}

/// 끝을 사람 말로. **stderr 로만 나간다.**
pub fn endMessage(end: End) []const u8 {
    return switch (end) {
        .stdin_eof => "maru control: the remote closed the channel",
        .socket_eof => "maru control: maru closed the control socket",
        .io_error => "maru control: the relay failed",
    };
}

/// `maru control` 의 인자 판정. **`--stdio` 말고는 아직 없다.**
///
/// 모르는 인자를 조용히 무시하면 오타가 "왜인지 아무 일도 안 일어난다" 로 나타난다.
pub const Mode = union(enum) {
    stdio,
    usage: []const u8,
};

pub fn parseArgs(args: []const []const u8) Mode {
    if (args.len == 0) return .{ .usage = "usage: maru control --stdio" };
    if (args.len > 1) return .{ .usage = "maru control: too many arguments" };
    if (std.mem.eql(u8, args[0], "--stdio")) return .stdio;
    return .{ .usage = "maru control: unknown argument (only --stdio)" };
}

// ---- 여기부터 OS 를 부른다(L4) ------------------------------------------------

/// 소켓과 stdin/stdout 사이를 양방향으로 흘린다. **돌아오면 끝난 것이다.**
pub fn relay(io: std.Io, allocator: std.mem.Allocator, stderr: *std.Io.Writer) !void {
    if (control_client.gate) |reason| return control_client.noInstance(stderr, reason);

    const fd = try control_client.connectStream(io, allocator, stderr);
    defer _ = std.c.close(fd);
    const end = relayFds(0, 1, fd);
    try finish(stderr, end);
}

/// **Windows 에는 이 transport 가 없다**(계약 §8 — 컨트롤 소켓 자체가 아직 없다).
/// `control_client.gate` 와 같은 판정을 쓰고, 아래 POSIX 본문은 comptime 으로 **의미 분석조차
/// 되지 않게** 둔다 — `poll`·`socketpair` 는 그 타깃의 `std.c` 에 없어서, 안 그러면 **쓰지도
/// 않는 코드가 빌드를 깬다**(CI 의 `check-targets` 가 그것을 잡았다).
const posix_relay = control_client.gate == null;

/// 중계 루프 그 자체. **fd 를 인자로 받는다** — 그래야 테스트가 파이프와 소켓쌍으로 **진짜
/// 왕복**을 잴 수 있다. `relay` 가 소켓을 찾아 주고 이 함수가 바이트를 옮긴다.
///
/// 오류를 안 내고 `End` 를 돌려준다: 끝나는 것은 실패가 아니라 **정상 경로**이고, 왜 끝났는지는
/// 세 갈래로 갈라야 한다(끝을 하나로 뭉치면 진단이 "무언가 끝났다" 밖에 못 된다).
pub fn relayFds(in_fd: std.c.fd_t, out_fd: std.c.fd_t, sock_fd: std.c.fd_t) End {
    if (!posix_relay) return .io_error;
    const c = std.c;

    // **`SIGPIPE` 를 막는다.** 폰이 컨트롤 채널을 닫으면 sshd 가 우리 stdout 을 닫고, 그때 마침
    // 쓰고 있으면 이 프로세스는 **끝 메시지도 없이 즉사한다** — "끝은 세 갈래로 가른다" 는
    // 규칙이 그 자리에서 통째로 무의미해지고, 소켓도 안 닫힌 채 남는다. 목록 화면을 나갈 때마다
    // 닿는 자리다(적대적 검증이 잡았다). 무시로 두면 `write` 가 `EPIPE` 를 돌려주고 우리가
    // **정상 종료로** 다룰 수 있다. 앱 쪽 서버는 같은 이유로 `SO_NOSIGPIPE` 를 쓴다.
    const ignore = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);
    var buf: [chunk_bytes]u8 = undefined;
    var fds = [_]std.c.pollfd{
        .{ .fd = in_fd, .events = std.c.POLL.IN, .revents = 0 },
        .{ .fd = sock_fd, .events = std.c.POLL.IN, .revents = 0 },
    };

    while (true) {
        // **막지 않고 둘을 함께 본다.** 한쪽만 읽으면 다른 쪽이 굶는다 — 폰이 요청을 보내는
        // 동안 알림이 오면 그 알림은 요청이 끝날 때까지 못 지나간다.
        const ready = c.poll(&fds, fds.len, -1);
        if (ready < 0) {
            // 신호로 깬 것은 실패가 아니다 — 다시 본다.
            if (c._errno().* == @intFromEnum(c.E.INTR)) continue;
            return .io_error;
        }

        if (fds[0].revents != 0) {
            const n = c.read(in_fd, &buf, buf.len);
            switch (classifyRead(n, .stdin_eof)) {
                // **stdin 이 끝난 것은 "더 보낼 게 없다" 이지 "받을 게 없다" 가 아니다.**
                // 폰이 쓰기 쪽만 닫고 마지막 답을 기다릴 수 있는데, 여기서 곧장 끝내면 그 답을
                // **잃는다**. 그 fd 만 폴링에서 빼고(음수 fd 는 `poll` 이 무시한다) 소켓은 계속
                // 읽는다 — 진짜 끝은 소켓이 닫힐 때다(적대적 검증이 잡았다).
                //
                // **그러려면 소켓에 "나는 다 보냈다" 를 알려야 한다**(`shutdown(SHUT_WR)`).
                // 안 알리면 서버는 더 올 요청을 기다리고 우리는 그 답을 기다려 **둘 다 영영
                // 멈춘다** — 처음 고칠 때 그 자리를 빠뜨려 테스트가 두 시간을 매달려 있었다.
                .ended => |e| switch (e) {
                    .stdin_eof => {
                        fds[0].fd = -1;
                        _ = c.shutdown(sock_fd, std.posix.SHUT.WR);
                    },
                    else => return e,
                },
                // 소켓에 못 쓴다 = maru 가 닫았다(그쪽이 상대다).
                .moved => |len| switch (writeAll(sock_fd, buf[0..len])) {
                    .ok => {},
                    .closed => return .socket_eof,
                    .failed => return .io_error,
                },
            }
        }

        if (fds[1].revents != 0) {
            const n = c.read(sock_fd, &buf, buf.len);
            switch (classifyRead(n, .socket_eof)) {
                .ended => |e| return e,
                // **stdout 으로 그대로 나간다** — 여기서 해석하지 않는다.
                // stdout 에 못 쓴다 = 폰이 채널을 닫았다.
                .moved => |len| switch (writeAll(out_fd, buf[0..len])) {
                    .ok => {},
                    .closed => return .stdin_eof,
                    .failed => return .io_error,
                },
            }
        }
    }
}

/// 다 쓸 때까지 쓴다. **부분 쓰기를 잃지 않고**, 왜 못 썼는지를 갈라 준다.
fn writeAll(fd: std.c.fd_t, bytes: []const u8) WriteEnd {
    const c = std.c;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            const err = std.posix.errno(n);
            if (err == .INTR) continue;
            return classifyWriteErrno(err);
        }
        // 0 바이트를 썼다는 것은 진행이 없다는 뜻이다 — 무한 루프 대신 실패로 끝낸다.
        if (n == 0) return .failed;
        off += @intCast(n);
    }
    return .ok;
}

fn finish(stderr: *std.Io.Writer, end: End) !void {
    try stderr.print("{s}\n", .{endMessage(end)});
    try stderr.flush();
}

const testing = std.testing;

test "인자는 --stdio 하나뿐이다" {
    // 모르는 인자를 조용히 무시하면 오타가 "왜인지 아무 일도 안 일어난다" 로 나타난다.
    try testing.expect(parseArgs(&.{"--stdio"}) == .stdio);
    try testing.expect(parseArgs(&.{}) == .usage);
    try testing.expect(parseArgs(&.{"--stdout"}) == .usage);
    try testing.expect(parseArgs(&.{ "--stdio", "extra" }) == .usage);
}

test "0 과 음수는 다른 끝이다" {
    // 뭉치면 "정상 종료" 와 "선이 끊겼다" 가 같은 말이 되어, 사용자는 왜 목록이 사라졌는지 못 안다.
    try testing.expectEqual(Step{ .moved = 5 }, classifyRead(5, .stdin_eof));
    try testing.expectEqual(Step{ .ended = .stdin_eof }, classifyRead(0, .stdin_eof));
    try testing.expectEqual(Step{ .ended = .socket_eof }, classifyRead(0, .socket_eof));
    try testing.expectEqual(Step{ .ended = .io_error }, classifyRead(-1, .stdin_eof));
}

test "끝 메시지는 세 갈래가 서로 다르다" {
    // 같은 문구를 쓰면 진단이 "무언가 끝났다" 밖에 못 된다.
    const a = endMessage(.stdin_eof);
    const b = endMessage(.socket_eof);
    const c = endMessage(.io_error);
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(!std.mem.eql(u8, b, c));
    try testing.expect(!std.mem.eql(u8, a, c));
}

/// 테스트용 파이프 한 쌍. `[0]`=읽기, `[1]`=쓰기.
///
/// **POSIX 에서만 쓴다.** 아래 왕복 테스트들은 `pipe`·`socketpair` 를 부르는데 Windows 타깃에는
/// 그 심벌이 없다 — 테스트도 제품과 같은 게이트 뒤에 둔다.
fn testPipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

fn testSocketPair() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    return fds;
}

test "폰이 보낸 바이트가 소켓으로 그대로 간다" {
    if (!posix_relay) return error.SkipZigTest;
    // **바이트를 해석하지 않는다**(줄을 세거나 다시 묶지 않는다) — 그것을 여기서 잰다.
    // 프레임 조립은 폰 한 곳뿐이고, 두 곳이면 상한과 배압 규칙이 갈린다.
    const in = try testPipe();
    const out = try testPipe();
    const sock = try testSocketPair();
    defer for ([_]std.c.fd_t{ in[0], out[0], out[1], sock[0], sock[1] }) |fd| {
        _ = std.c.close(fd);
    };

    // 줄 경계에 안 맞는 조각을 일부러 섞는다.
    const sent = "{\"id\":1}\n{\"id\"";
    try testing.expect(std.c.write(in[1], sent.ptr, sent.len) == sent.len);
    _ = std.c.close(in[1]); // 폰이 **쓰기 쪽을** 닫았다

    // **상대도 "더 안 보낸다" 를 알려야 끝난다.** 안 그러면 중계는 답을 기다리며 영원히 산다 —
    // 그것이 옳은 동작이다(위 half-close 규칙). `close` 가 아니라 `shutdown(WR)` 인 이유는
    // **우리가 보낸 바이트를 아래에서 읽어야** 하기 때문이다(읽기 방향은 살아 있다).
    _ = std.c.shutdown(sock[1], std.posix.SHUT.WR);

    var got: [64]u8 = undefined;
    const end = relayFds(in[0], out[1], sock[0]);
    // stdin 이 먼저 끝났고, `shutdown` 을 받은 상대가 EOF 를 돌려주므로 끝은 소켓 쪽이다.
    try testing.expectEqual(End.socket_eof, end);
    const n = std.c.read(sock[1], &got, got.len);
    try testing.expectEqualStrings(sent, got[0..@intCast(n)]);
}

test "maru 가 낸 바이트가 stdout 으로 그대로 간다" {
    if (!posix_relay) return error.SkipZigTest;
    const in = try testPipe();
    const out = try testPipe();
    const sock = try testSocketPair();
    defer for ([_]std.c.fd_t{ in[0], in[1], out[0], out[1], sock[0] }) |fd| {
        _ = std.c.close(fd);
    };

    const reply = "{\"jsonrpc\":\"2.0\",\"result\":{}}\n";
    try testing.expect(std.c.write(sock[1], reply.ptr, reply.len) == reply.len);
    _ = std.c.close(sock[1]); // maru 가 소켓을 닫았다

    // stdin 은 열려 있고 조용하다 — 그래도 소켓 쪽이 깨워야 한다(한쪽만 보면 굶는다).
    try testing.expectEqual(End.socket_eof, relayFds(in[0], out[1], sock[0]));

    var got: [64]u8 = undefined;
    const n = std.c.read(out[0], &got, got.len);
    try testing.expectEqualStrings(reply, got[0..@intCast(n)]);
}

test "끝을 두 갈래로 가른다 — 누가 닫았는지" {
    if (!posix_relay) return error.SkipZigTest;
    // 같은 끝으로 뭉치면 "폰이 나갔다" 와 "maru 가 꺼졌다" 가 구별이 안 된다. 화면이 사용자에게
    // 할 말이 달라지는 자리다.
    const in = try testPipe();
    const out = try testPipe();
    const sock = try testSocketPair();
    defer for ([_]std.c.fd_t{ in[0], out[0], out[1], sock[0] }) |fd| {
        _ = std.c.close(fd);
    };
    _ = std.c.close(in[1]);
    _ = std.c.close(sock[1]);
    // 둘 다 닫혔을 때도 **하나를 골라** 돌려준다(무한 루프가 아니다).
    const end = relayFds(in[0], out[1], sock[0]);
    try testing.expect(end == .stdin_eof or end == .socket_eof);
}

test "닫힌 쪽에 쓰다 죽지 않는다 — 끝 메시지가 남는다" {
    if (!posix_relay) return error.SkipZigTest;
    // **이 테스트는 `SIGPIPE` 무시를 재지 못한다 — 그 사실을 조용히 두지 않는다.**
    //
    // 실측(2026-08-21): Zig 로 빌드한 **보통 실행 파일**은 닫힌 파이프에 쓰면 `SIGPIPE` 로 죽는다
    // (`exit 141`). 즉 제품 경로(`maru control --stdio` 로 exec 된 프로세스)에서 그 신호는 진짜이고,
    // 위 `sigaction` 이 없으면 중계는 **끝 메시지도 없이 사라진다**. 그런데 **테스트 러너는 그
    // 신호를 이미 가로채 둔다** — 그래서 여기서는 무시를 빼도 안 죽고, 변이 검사가 살아남는다.
    //
    // 그러니 기본 동작일 때만 이 테스트가 뜻이 있다. 아니면 **건너뛴다**(초록으로 위장하지 않는다).
    {
        var current: std.posix.Sigaction = undefined;
        std.posix.sigaction(std.posix.SIG.PIPE, null, &current);
        if (current.handler.handler != std.posix.SIG.DFL) return error.SkipZigTest;
    }
    const in = try testPipe();
    const out = try testPipe();
    const sock = try testSocketPair();
    defer for ([_]std.c.fd_t{ in[0], in[1], out[1], sock[0] }) |fd| {
        _ = std.c.close(fd);
    };

    _ = std.c.close(out[0]); // 폰이 채널을 닫았다 — 우리 stdout 의 상대가 사라졌다
    const reply = "{\"jsonrpc\":\"2.0\"}\n";
    try testing.expect(std.c.write(sock[1], reply.ptr, reply.len) == reply.len);
    _ = std.c.close(sock[1]);

    // 죽지 않고, **폰이 닫았다** 로 끝난다(소켓이 닫힌 것과 구별한다).
    try testing.expectEqual(End.stdin_eof, relayFds(in[0], out[1], sock[0]));
}

test "못 쓴 이유를 가른다 — 상대가 닫은 것과 진짜 실패" {
    // 한 갈래로 두면 "폰이 나갔다" 가 "중계가 깨졌다" 로 보고되고, 화면은 없는 문제를 말한다.
    try testing.expectEqual(WriteEnd.closed, classifyWriteErrno(.PIPE));
    try testing.expectEqual(WriteEnd.closed, classifyWriteErrno(.CONNRESET));
    try testing.expectEqual(WriteEnd.failed, classifyWriteErrno(.BADF));
    try testing.expectEqual(WriteEnd.failed, classifyWriteErrno(.IO));
}

test "폰이 쓰기 쪽만 닫아도 마지막 답을 흘린다" {
    if (!posix_relay) return error.SkipZigTest;
    // **stdin EOF 는 "더 보낼 게 없다" 이지 "받을 게 없다" 가 아니다.** 여기서 곧장 끝내면
    // 요청을 보내고 답을 기다리던 폰이 **그 답을 못 받는다** — 그리고 그 실패는 "가끔 목록이
    // 안 뜬다" 로만 보인다.
    const in = try testPipe();
    const out = try testPipe();
    const sock = try testSocketPair();
    defer for ([_]std.c.fd_t{ in[0], out[0], out[1], sock[0] }) |fd| {
        _ = std.c.close(fd);
    };

    const req = "{\"id\":1}\n";
    try testing.expect(std.c.write(in[1], req.ptr, req.len) == req.len);
    _ = std.c.close(in[1]); // 폰이 **쓰기 쪽만** 닫았다

    const reply = "{\"id\":1,\"result\":{}}\n";
    try testing.expect(std.c.write(sock[1], reply.ptr, reply.len) == reply.len);
    // **`close` 가 아니라 `shutdown(WR)` 이다.** 닫아 버리면 중계가 요청을 밀어 넣을 때 `EPIPE`
    // 로 **즉시** 끝나고, 답은 stdout 으로 흐르지 않는다 — 그러면 이 테스트는 재려던 것을
    // 못 재고 `read` 에서 매달린다(실제로 그렇게 두 시간을 매달렸다). 답을 다 준 서버가
    // 쓰기만 닫은 모양이 우리가 재려는 상황이다.
    _ = std.c.shutdown(sock[1], std.posix.SHUT.WR);

    // 끝은 **소켓** 쪽이다 — stdin 이 먼저 끝났다고 거기서 멈추지 않았다.
    try testing.expectEqual(End.socket_eof, relayFds(in[0], out[1], sock[0]));

    var got: [64]u8 = undefined;
    const n = std.c.read(out[0], &got, got.len);
    try testing.expectEqualStrings(reply, got[0..@intCast(n)]);
}
