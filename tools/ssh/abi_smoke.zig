//! **모바일 SSH ABI 의 실서버 스모크**(계획 S9-2). `maru_mobile_ssh_*` **만** 써서 진짜 sshd 에
//! 붙는다 — 코어(`client.zig`)를 직접 부르지 않는다.
//!
//! **왜 따로 있나.** S8 스모크는 코어가 실서버에서 돈다는 것을 증명하지만, 그 사이에 낀 ABI 는
//! 한 줄도 안 지난다. 그런데 모바일에서 "안 된다" 가 났을 때 가장 비싼 물음이 **프로토콜 탓인가
//! 배선 탓인가**이고, 그것을 가르는 유일한 방법은 이 층만으로 한 번 붙여 보는 것이다(계획이
//! S8 을 S9 앞에 둔 이유와 같다). 이 스모크가 초록이면 이후 기기에서의 실패는 **host 쪽**으로
//! 좁혀진다.
//!
//! **이것도 제품 경로가 아니다.** host 가 할 일(소켓·키 읽기·난수)을 여기서 흉내 낼 뿐이다.
//! 다만 난수는 **진짜**로 쓴다 — `std.crypto.random` 이 host 의 `SecRandomCopyBytes`·
//! `SecureRandom` 자리다(계약: 브리지는 OS 를 못 부른다).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

const abi = @import("mobile_ssh");
const ssh = @import("maru").session.ssh;

const read_timeout_s = 20;

/// 소켓 어댑터. **host 가 하는 일이 이것뿐이다** — 읽어서 먹이고, 쌓인 것을 보낸다.
const Socket = struct {
    fd: c.fd_t,

    fn connect(port: u16) !Socket {
        const fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        var addr: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7F00_0001),
            .zero = @splat(0),
        };
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) return error.ConnectFailed;
        const tv: posix.timeval = .{ .sec = read_timeout_s, .usec = 0 };
        _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(posix.timeval));
        if (builtin.os.tag == .macos) {
            var on: c_int = 1;
            _ = c.setsockopt(fd, posix.SOL.SOCKET, c.SO.NOSIGPIPE, @ptrCast(&on), @sizeOf(c_int));
        }
        return .{ .fd = fd };
    }

    fn read(self: Socket, buf: []u8) !usize {
        const n = c.read(self.fd, buf.ptr, buf.len);
        if (n < 0) return if (c._errno().* == @intFromEnum(c.E.AGAIN)) error.Stalled else error.ReadFailed;
        if (n == 0) return error.Closed;
        return @intCast(n);
    }

    fn writeSome(self: Socket, bytes: []const u8) !usize {
        const n = if (builtin.os.tag == .linux)
            c.send(self.fd, bytes.ptr, bytes.len, posix.MSG.NOSIGNAL)
        else
            c.write(self.fd, bytes.ptr, bytes.len);
        if (n <= 0) return error.WriteFailed;
        return @intCast(n);
    }

    fn close(self: Socket) void {
        _ = c.close(self.fd);
    }
};

var sock: Socket = undefined;
var in_buf: [64 * 1024]u8 = undefined;
var in_len: usize = 0;
var scratch: [8192]u8 = undefined;
var file_buf: [8192]u8 = undefined;
var screen_head: [4096]u8 = undefined;
var screen_head_len: usize = 0;
var screen_len: usize = 0;

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[ssh-abi-smoke] " ++ fmt ++ "\n", args);
}

fn fail(comptime msg: []const u8) error{SmokeFailed} {
    std.debug.print("[ssh-abi-smoke] FAIL: " ++ msg ++ "\n", .{});
    return error.SmokeFailed;
}

/// OS 난수. **브리지가 못 하는 일을 host 가 대신 하는 자리다**(계약: `platform/mobile` 에 OS 호출 0).
fn secureEntropy(dst: []u8) !void {
    switch (builtin.os.tag) {
        .macos => c.arc4random_buf(dst.ptr, dst.len),
        .linux => {
            var off: usize = 0;
            while (off < dst.len) {
                const rc = c.getrandom(dst[off..].ptr, dst.len - off, 0);
                if (rc < 0) {
                    if (posix.errno(rc) == .INTR) continue;
                    return error.EntropyUnavailable;
                }
                if (rc == 0) return error.EntropyUnavailable;
                off += @intCast(rc);
            }
        },
        else => return error.EntropyUnavailable,
    }
}

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

/// 쌓인 선 바이트를 보낸다. **부분 전송을 그대로 흉내 낸다** — 소켓이 받은 만큼만 `consume`
/// 하는 것이 host 의 규약이고, 그 자리를 안 밟으면 ABI 의 절반이 안 검증된다.
fn flush(h: u32) !void {
    while (abi.maru_mobile_ssh_out_len(h) > 0) {
        const len = abi.maru_mobile_ssh_out_len(h);
        const ptr = abi.maru_mobile_ssh_out_ptr(h);
        const n = try sock.writeSome(ptr[0..len]);
        if (abi.maru_mobile_ssh_out_consume(h, @intCast(n)) != abi.ok) return error.ConsumeFailed;
    }
}

/// 화면 바이트를 가져간다. **가져가야 다음 걸음이 돈다**(배압) — 안 비우면 `feed` 가 멈춘다.
fn drainScreen(h: u32) void {
    const len = abi.maru_mobile_ssh_screen_len(h);
    if (len == 0) return;
    const ptr = abi.maru_mobile_ssh_screen_ptr(h);
    // **앞부분만 보관하고 양은 다 센다.** 에코 회차는 화면이 MiB 단위라 다 들고 있을 이유가 없다.
    const room = @min(len, screen_head.len - @min(screen_head_len, screen_head.len));
    if (room > 0) {
        @memcpy(screen_head[screen_head_len..][0..room], ptr[0..room]);
        screen_head_len += room;
    }
    screen_len += len;
    _ = abi.maru_mobile_ssh_screen_consume(h, len);
}

/// 한 번 먹인다. 남은 입력은 앞으로 당긴다.
fn pump(h: u32) !u32 {
    var consumed: u32 = 0;
    const status = abi.maru_mobile_ssh_feed(h, &in_buf, @intCast(in_len), &consumed);
    if (status != abi.ok) {
        say("feed status={d} error={s}", .{ status, std.mem.span(abi.maru_mobile_ssh_last_error(h)) });
        return error.FeedFailed;
    }
    if (consumed > 0) {
        std.mem.copyForwards(u8, in_buf[0 .. in_len - consumed], in_buf[consumed..in_len]);
        in_len -= consumed;
    }
    try flush(h);
    drainScreen(h);
    return abi.maru_mobile_ssh_state(h);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const port_str = it.next() orelse return fail("포트를 인자로 준다");
    const user = it.next() orelse return fail("사용자 이름을 인자로 준다");
    const key_path = it.next() orelse return fail("개인키 경로를 인자로 준다");
    const marker = it.next() orelse return fail("화면에서 찾을 문자열을 인자로 준다");
    // 0 이면 받기만 한다. 크면 그만큼 **보내고** 그대로 돌아오는지 본다(서버가 `cat` 인 회차).
    const send_bytes = try std.fmt.parseInt(usize, it.next() orelse "0", 10);
    const port = try std.fmt.parseInt(u16, port_str, 10);

    // **에코 회차는 pty 를 안 쓴다.** pty 를 붙이면 라인 디시플린이 canonical 모드라 개행 없는
    // 바이트가 `cat` 에 안 닿는다 — 실측으로 1MiB 를 보내고 256KiB 만 돌아온 뒤 선이 멈췄다.
    // (같은 이유로 코어 스모크의 에코 회차도 pty 를 끈다.)
    const want_pty: u32 = if (send_bytes > 0) 0 else 1;

    var parsed = try loadKey(key_path);
    defer parsed.clear();

    // **난수는 host 가 준다.** 기기에서는 `SecRandomCopyBytes`(iOS)·`SecureRandom`(Android)이
    // 이 자리이고, 데스크톱에서는 OS 난수를 그대로 쓴다 — 여기가 L4 라 OS 를 부를 수 있다.
    var entropy: [abi.entropy_bytes]u8 = undefined;
    try secureEntropy(&entropy);

    sock = try Socket.connect(port);
    defer sock.close();

    var h: u32 = 0;
    const opened = abi.maru_mobile_ssh_open(
        user.ptr,
        @intCast(user.len),
        &parsed.secret,
        &entropy,
        "xterm-256color",
        14,
        80,
        24,
        0,
        want_pty,
        &h,
    );
    std.crypto.secureZero(u8, &entropy);
    if (opened != abi.ok) {
        say("open status={d}", .{opened});
        return fail("세션을 못 열었다");
    }
    defer _ = abi.maru_mobile_ssh_close(h);
    try flush(h); // 버전 줄

    var rounds: usize = 0;
    var ready = false;
    while (rounds < 100_000) : (rounds += 1) {
        const st = try pump(h);
        if (st == 4) { // HOST_KEY_DECISION
            const fp = std.mem.span(abi.maru_mobile_ssh_host_key_fingerprint(h));
            if (fp.len == 0) return fail("지문이 비었다");
            if (!std.mem.startsWith(u8, fp, "SHA256:")) return fail("지문 형식이 다르다");
            say("호스트키 {s}", .{fp});
            if (abi.maru_mobile_ssh_accept_host_key(h) != abi.ok) return fail("승인이 안 먹혔다");
            continue;
        }
        if (st == 11) { // READY
            ready = true;
            break;
        }
        if (st == 12) { // CLOSED
            const reason = abi.maru_mobile_ssh_disconnect_reason(h);
            say("끊김 사유={d} 설명={s}", .{ reason, std.mem.span(abi.maru_mobile_ssh_disconnect_description(h)) });
            return fail("셸이 뜨기 전에 닫혔다");
        }
        const n = sock.read(in_buf[in_len..]) catch |e| switch (e) {
            error.Closed, error.Stalled => return fail("선이 멈췄다"),
            else => return e,
        };
        in_len += n;
    }
    if (!ready) return fail("셸이 안 떴다");
    say("셸 준비됨 (ABI 만으로)", .{});

    if (send_bytes > 0) {
        // **보내는 쪽도 ABI 를 지난다.** 상대가 허락한 만큼만 나가므로(흐름 제어) 못 보낸 만큼은
        // 받아서 창을 연 뒤 다시 준다 — 이 되먹임이 없으면 큰 전송에서 그냥 멈춘다.
        var payload: [4096]u8 = @splat('z');
        var sent_total: usize = 0;
        var idle: usize = 0;
        while (sent_total < send_bytes or screen_len < send_bytes) {
            if (sent_total < send_bytes) {
                const want: u32 = @intCast(@min(payload.len, send_bytes - sent_total));
                var sent: u32 = 0;
                const st = abi.maru_mobile_ssh_write(h, &payload, want, &sent);
                if (st != abi.ok and st != abi.err_buffer) {
                    say("write status={d} error={s}", .{ st, std.mem.span(abi.maru_mobile_ssh_last_error(h)) });
                    return fail("보내기가 실패했다");
                }
                sent_total += sent;
                try flush(h);
                if (sent > 0) idle = 0;
            }
            const before = screen_len;
            const n = sock.read(in_buf[in_len..]) catch |e| switch (e) {
                error.Closed => break,
                error.Stalled => {
                    say("멈춤: 보낸 {d}B, 화면 {d}B, in_len={d}, out_len={d}, state={d}", .{
                        sent_total, screen_len, in_len, abi.maru_mobile_ssh_out_len(h), abi.maru_mobile_ssh_state(h),
                    });
                    return fail("에코 회차에서 선이 멈췄다");
                },
                else => return e,
            };
            in_len += n;
            _ = try pump(h);
            if (screen_len == before) {
                idle += 1;
                // **멈춘 것을 멈췄다고 한다.** 흐름 제어가 틀리면 여기서 조용히 맴돈다.
                if (idle > 10_000) return fail("에코가 안 돌아온다");
            } else idle = 0;
        }
        if (sent_total != send_bytes) return fail("보낸 양이 요청과 다르다");
        if (screen_len < send_bytes) return fail("돌아온 양이 모자란다");
        say("에코: 보낸 {d}B, 화면 {d}B", .{ sent_total, screen_len });
        say("OK", .{});
        return;
    }

    // 서버가 `ForceCommand` 로 낸 표시를 화면에서 찾고, 끝나면 `exit-status` 를 본다.
    var code: u32 = 0;
    while (rounds < 200_000) : (rounds += 1) {
        if (abi.maru_mobile_ssh_exit_status(h, &code) == abi.ok) break;
        if (abi.maru_mobile_ssh_state(h) == 12) break;
        const n = sock.read(in_buf[in_len..]) catch |e| switch (e) {
            error.Closed => break,
            error.Stalled => return fail("셸 뒤에 선이 멈췄다"),
            else => return e,
        };
        in_len += n;
        _ = try pump(h);
    }
    if (abi.maru_mobile_ssh_exit_status(h, &code) != abi.ok) return fail("exit-status 가 안 왔다");
    if (code != 0) return fail("원격 명령이 실패했다");
    if (std.mem.indexOf(u8, screen_head[0..screen_head_len], marker) == null) {
        say("화면 {d}B 안에 표시가 없다", .{screen_len});
        return fail("화면 바이트가 ABI 를 안 지났다");
    }
    say("화면 {d}B, exit-status {d}, 표시 확인", .{ screen_len, code });
    say("OK", .{});
}
