//! **내장 SSH 클라이언트의 실서버 스모크**(계획 S8). 진짜 sshd 와 한 번 왕복한다.
//!
//! **제품 경로가 아니다.** 데스크톱의 `maru ssh` 는 시스템 `ssh` 래퍼로 그대로 두고(계약 §3.4),
//! 내장 클라이언트는 모바일용이다. 여기 있는 것은 그 클라이언트를 **데스크톱에서 검증**하기 위한
//! 소켓 어댑터와 드라이버다. 그래서 `src/` 가 아니라 `tools/` 에 산다.
//!
//! **왜 있어야 하나.** `src/session/ssh/` 는 전부 sans-io 라 스스로는 아무 데도 못 붙는다. 그리고
//! 서버 구현마다 관대함이 달라 상호운용은 명세만으로 안 닫힌다 — 진짜 sshd 와의 왕복이 유일한
//! 판정자다(계획 "위험" 절).
//!
//! **드라이버가 계약대로인지도 여기서 잰다.** 계약 §3.1 의 흐름 제어 두 줄, §3.1.1 의 실서버
//! 순서(초기 윈도 0 · 답보다 먼저 오는 사건 · 채널 아닌 메시지)를 그대로 따라 쓴다 — 문서가
//! 말한 대로 짜서 실제로 붙는지 보는 것이 이 파일의 절반이다.
//!
//! **이 스모크가 못 잡는 것 — 정직하게.**
//!
//!   - **보내는 쪽 윈도 가드**는 원리적으로 못 잡는다. 그 가드는 *버그 있는 드라이버*를 막는
//!     것인데, 여기 드라이버는 `sendableLen()` 으로 잘라 보내므로 애초에 넘길 수가 없다. 실측:
//!     가드를 지워도·`sendableLen` 이 최대 패킷을 무시해도·보낸 뒤 윈도를 안 줄여도 세 회차가 다
//!     초록이다. 그 셋은 단위 테스트가 잡는다(`channel.zig` 의 변이 검사).
//!   - **채우는 시점(절반)이 최적인지**도 안 본다. 바닥에서 채워도 전송은 끝난다 — 느려질 뿐이다.
//!   - 확인한 서버는 **OpenSSH 하나**다. Dropbear·네트워크 장비는 다르게 굴 수 있다.

const std = @import("std");
const posix = std.posix;
const c = std.c;

const ssh = @import("maru").session.ssh;
const version = ssh.version;
const kexinit = ssh.kexinit;
const kex = ssh.kex;
const cipher = ssh.cipher;
const transport = ssh.transport;
const hostkey = ssh.hostkey;
const userauth = ssh.userauth;
const channel = ssh.channel;
const private_key = ssh.private_key;
const wire = ssh.wire;

/// 선이 조용해지면 이만큼 기다렸다 포기한다. 로컬 sshd 라 정상 왕복은 밀리초 단위다.
const read_timeout_s = 20;

/// 소켓 어댑터. **이 struct 가 L4 의 전부다** — 프로토콜은 한 줄도 모른다.
const Socket = struct {
    fd: c.fd_t,

    fn connect(port: u16) !Socket {
        const fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        // **읽기에 시간 제한을 건다.** 흐름 제어가 틀리면 서버가 우리를 기다리며 조용히 멈추는데,
        // 그것을 안 자르면 스모크가 **행**한다 — CI 에서 그것은 실패보다 나쁘다(잡 하나가 러너를
        // 물고 늘어지고, 로그만 봐서는 무엇을 기다리는지도 모른다). 실측으로 겪었다: 우리 윈도를
        // 안 줄이는 변이를 넣었더니 스모크가 10 분 넘게 안 끝났다.
        const tv: posix.timeval = .{ .sec = read_timeout_s, .usec = 0 };
        _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(posix.timeval));
        var addr: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7F00_0001), // 127.0.0.1
            .zero = @splat(0),
        };
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) return error.ConnectFailed;
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
            const n = c.write(self.fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    fn close(self: Socket) void {
        _ = c.close(self.fd);
    }
};

/// 선에서 읽은 바이트를 모아 두는 자리. **프로토콜 층은 이 버퍼를 모른다** — `feed` 가 먹은 만큼
/// 우리가 민다(계약 §4.5).
var in_buf: [1 << 20]u8 = undefined;
var in_len: usize = 0;

var t: transport.Transport = .{};
var sock: Socket = undefined;
var out_wire: [1 << 18]u8 = undefined;
var prng = std.Random.DefaultPrng.init(0x5388);

fn fill() !void {
    if (in_len == in_buf.len) return error.InputBufferFull;
    in_len += try sock.read(in_buf[in_len..]);
}

fn consume(n: usize) void {
    std.mem.copyForwards(u8, in_buf[0 .. in_len - n], in_buf[n..in_len]);
    in_len -= n;
}

fn send(payload: []const u8) !void {
    const n = try t.send(&out_wire, payload, prng.random());
    try sock.writeAll(out_wire[0..n]);
}

/// 패킷 하나를 받는다. **버린 추측 패킷은 여기서 흡수한다** — 드라이버가 그것을 진짜로 처리하는
/// 것이 코드리뷰가 잡은 결함이었고, union 이라 이제 실수할 수 없다.
fn recv(out: []u8) ![]const u8 {
    while (true) {
        if (in_len > 0) {
            if (try t.feed(out, in_buf[0..in_len])) |received| switch (received) {
                .discarded => |d| {
                    consume(d.consumed);
                    continue;
                },
                .packet => |p| {
                    consume(p.consumed);
                    return p.payload;
                },
            };
        }
        try fill();
    }
}

/// 채널 메시지만 골라 받는다.
///
/// **실서버는 채널 아닌 것을 섞어 보낸다**(계약 §3.1.1 — 인증 직후 `GLOBAL_REQUEST
/// hostkeys-00@openssh.com` 과 `SSH_MSG_DEBUG` 가 왔다). 분류는 S7c 몫이고 여기서는 넘긴다.
fn recvChannel(out: []u8) ![]const u8 {
    while (true) {
        const p = try recv(out);
        if (p[0] >= 90 and p[0] <= 100) return p;
    }
}

var pkt: [1 << 18]u8 = undefined;
var scratch: [8192]u8 = undefined;

// **두 루프가 같은 카운터를 센다.** 처음에는 받는 루프에만 뒀는데, 보내는 동안에도 데이터가
// 오므로(우리가 `cat` 에 보낸 것이 그대로 돌아온다) 그만큼이 통째로 안 세어졌다 — 4MiB 를
// 보내고 2.77MiB 만 받았다고 나왔다. 드라이버가 틀린 것이지 제품이 아니었다.
var got: usize = 0;
var stderr_bytes: usize = 0;
var adjusts: usize = 0;
var exit_code: ?u32 = null;
var peer_closed = false;

pub fn main(init: std.process.Init.Minimal) !void {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const port_str = it.next() orelse return fail("포트를 인자로 준다");
    const user = it.next() orelse return fail("사용자 이름을 인자로 준다");
    const key_path = it.next() orelse return fail("개인키 경로를 인자로 준다");
    const expect_bytes_str = it.next() orelse return fail("기대 stdout 바이트 수를 인자로 준다");
    const expect_stderr_str = it.next() orelse return fail("기대 stderr 바이트 수를 인자로 준다");
    // **pty 를 요청하면 stderr 가 따로 안 온다** — 서버가 그것을 pty 로 합쳐 `CHANNEL_DATA` 로
    // 보낸다(실측). 즉 `pty-req` 와 확장 데이터는 **한 연결에서 둘 다 볼 수 없다**. 그래서 모드를
    // 인자로 받아 스모크가 두 번 돈다.
    const mode = it.next() orelse "pty";
    const want_pty = std.mem.eql(u8, mode, "pty");
    // **보내는 쪽을 태우는 회차.** 나머지 회차는 받기만 해서, 보내는 쪽 흐름 제어(윈도·최대 패킷을
    // 넘겨 보내지 않는다)가 선 위에서 한 번도 안 돈다 — 그 검사를 지워도 스모크가 초록이었다(실측).
    // 이 회차는 서버가 `cat` 이라 우리가 보낸 것이 그대로 돌아온다.
    const want_echo = std.mem.eql(u8, mode, "echo");
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const expect_bytes = try std.fmt.parseInt(usize, expect_bytes_str, 10);
    const expect_stderr = try std.fmt.parseInt(usize, expect_stderr_str, 10);

    const key_pem = try readFile(key_path);

    sock = try Socket.connect(port);
    defer sock.close();

    // ---- 버전 교환 ----
    const v_c = version.clientLine("0.1");
    try sock.writeAll(v_c);
    try sock.writeAll("\r\n");
    var v_s_buf: [512]u8 = undefined;
    const v_s = blk: while (true) {
        if (in_len > 0) {
            if (version.parse(in_buf[0..in_len])) |p| {
                @memcpy(v_s_buf[0..p.line.len], p.line);
                consume(p.consumed);
                break :blk v_s_buf[0..p.line.len];
            } else |_| {}
        }
        try fill();
    };
    say("V_S = {s}", .{v_s});

    // ---- KEXINIT ----
    var i_c_buf: [4096]u8 = undefined;
    const i_c = try kexinit.write(&i_c_buf, prng.random());
    try send(i_c);

    var i_s_buf: [4096]u8 = undefined;
    const i_s = blk: {
        // **원문을 복사해 둔다** — `payload` 는 다음 `feed` 까지만 산다(계약 §4.5).
        const p = try recv(&pkt);
        @memcpy(i_s_buf[0..p.len], p);
        break :blk i_s_buf[0..p.len];
    };
    const peer = try kexinit.parse(i_s);
    const neg = try kexinit.negotiate(peer, .initial);
    say("협상 kex={s} hostkey={s} cipher={s} strict={}", .{ neg.kex, neg.host_key, neg.cipher_c2s, neg.strict_kex });
    // **한 번에 반영한다** — 반쪽만 반영되는 상태가 안 생긴다.
    try t.applyNegotiation(.{ .strict_kex = neg.strict_kex, .discard_guess = neg.discard_guess });

    // ---- ECDH ----
    var seed: [32]u8 = undefined;
    prng.random().bytes(&seed);
    var eph = try kex.Ephemeral.fromSeed(seed);
    defer eph.clear();
    var init_buf: [128]u8 = undefined;
    try send(try kex.writeInit(&init_buf, eph.public));

    const reply = try kex.parseReply(try recv(&pkt));
    var k = try eph.sharedSecret(reply.q_s);
    defer std.crypto.secureZero(u8, &k);
    const h = try kex.exchangeHash(.{
        .v_c = v_c,
        .v_s = v_s,
        .i_c = i_c,
        .i_s = i_s,
        .k_s = reply.host_key,
        .q_c = &eph.public,
        .q_s = reply.q_s,
        .k = k,
    });
    // **여기가 이 스모크의 존재 이유다.** 서버가 자기 `H` 에 서명했고 그것이 우리 `H` 로 검증되면
    // 우리 해석이 서버와 바이트 단위로 같다는 뜻이다(계약 §4.4.4.1).
    try hostkey.verifyExchangeHash(reply.host_key, reply.signature, &h);
    var fp_buf: [128]u8 = undefined;
    say("호스트키 검증 OK — {s}", .{try hostkey.fingerprint(&fp_buf, reply.host_key)});

    // ---- NEWKEYS ----
    try send(&[_]u8{msg_newkeys});
    if ((try recv(&pkt))[0] != msg_newkeys) return fail("NEWKEYS 가 아니다");

    var key_c2s: [64]u8 = undefined;
    var key_s2c: [64]u8 = undefined;
    try kex.deriveKey(&key_c2s, k, h, .enc_c2s, &h);
    try kex.deriveKey(&key_s2c, k, h, .enc_s2c, &h);
    var c_send = cipher.Cipher.initMove(&key_c2s);
    var c_recv = cipher.Cipher.initMove(&key_s2c);
    t.enableSendKeys(&c_send);
    t.enableRecvKeys(&c_recv);
    if (t.phase != .established) return fail("암호 전환이 안 끝났다");
    say("암호 켜짐", .{});

    // ---- 인증 ----
    var sr_buf: [64]u8 = undefined;
    try send(try userauth.writeServiceRequest(&sr_buf));
    try userauth.parseServiceAccept(try recv(&pkt));

    var parsed = try private_key.parse(key_pem, "", &scratch, .{});
    defer parsed.clear();
    defer std.crypto.secureZero(u8, &scratch);
    var kb_buf: [128]u8 = undefined;
    const key_blob = try userauth.publicKeyBlob(&kb_buf, parsed.secret);
    var sd_buf: [512]u8 = undefined;
    const sd = try userauth.signedData(&sd_buf, &h, user, key_blob);
    var sig_buf: [128]u8 = undefined;
    const sig = try userauth.signBlob(&sig_buf, parsed.secret, sd);
    var req_buf: [1024]u8 = undefined;
    try send(try userauth.writePublicKeyRequest(&req_buf, user, key_blob, sig));

    while (true) switch (try userauth.parseResponse(try recv(&pkt), .publickey)) {
        .success => break,
        .banner => continue,
        .failure => return fail("인증 실패"),
        else => return fail("예상 밖 인증 응답"),
    };
    say("인증 성공", .{});

    // ---- 채널 ----
    var ch: channel.Channel = .{};
    var ch_buf: [1024]u8 = undefined;
    try send(try ch.writeOpen(&ch_buf, 0));
    switch (try ch.receive(try recvChannel(&pkt))) {
        .opened => {},
        .open_failed => return fail("채널 거절"),
        else => return fail("예상 밖 채널 사건"),
    }
    // **계약 §3.1.1: 초기 윈도가 0 일 수 있다.** 그것을 여기서 값으로 남긴다.
    say("채널 열림 — 초기 윈도 {d}, 최대 패킷 {d}", .{ ch.remote_window, ch.remote_max_packet });

    if (want_pty) {
        try send(try ch.writePtyReq(&ch_buf, "xterm-256color", .{ .cols = 80, .rows = 24 }, ""));
        try awaitReply(&ch, "pty-req");
    }
    try send(try ch.writeShell(&ch_buf));
    try awaitReply(&ch, "shell");
    if (want_pty) try send(try ch.writeWindowChange(&ch_buf, .{ .cols = 120, .rows = 40 }));

    if (want_echo) {
        // **초기 윈도가 0 이면 기다려야 한다**(계약 §3.1.1). "채널이 열렸으니 보낸다" 로 짜면
        // 첫 바이트부터 §5.2 를 어기고, 서버는 그것을 흘려도 되므로 **조용히 사라진다**.
        var waited: usize = 0;
        while (ch.sendableLen() == 0) {
            if (waited > 100) return fail("윈도가 끝내 안 열렸다");
            waited += 1;
            try handle(&ch, try recvChannel(&pkt));
        }
        say("보낼 수 있게 되기까지 사건 {d} 개를 기다렸다 (윈도 {d})", .{ waited, ch.remote_window });

        // 상대가 허락한 만큼만 잘라 보낸다 — `sendableLen` 이 그 한도다.
        var sent: usize = 0;
        // **데이터 버퍼는 청크보다 커야 한다** — 머리(메시지 번호·채널 번호·길이)가 붙는다.
        var data_buf: [8192]u8 = undefined;
        var chunk: [4096]u8 = undefined;
        @memset(&chunk, 'Z');
        while (sent < expect_bytes) {
            const room = ch.sendableLen();
            if (room == 0) {
                try handle(&ch, try recvChannel(&pkt));
                continue;
            }
            const n = @min(@min(@as(usize, room), chunk.len), expect_bytes - sent);
            try send(try ch.writeData(&data_buf, chunk[0..n]));
            sent += n;
        }
        try send(try ch.writeEof(&ch_buf)); // `cat` 은 EOF 를 봐야 끝난다
        say("보낸 바이트 {d}", .{sent});
    }

    // ---- 대량 전송 (S7b 판정자) ----
    //
    // **짧은 출력으로는 흐름 제어가 안 탄다.** 초기 윈도 안에서 끝나면 우리가 채워 주는 경로가
    // 한 번도 안 돌아, 계약 §3.1 이 말한 "대량 출력이 도중에 멈춘다" 를 재현도 반증도 못 한다.
    // 그래서 스모크는 **윈도보다 큰 출력**을 요구한다.
    while (true) {
        const payload = recvChannel(&pkt) catch break;
        try handle(&ch, payload);
        if (peer_closed) break;
    }

    say("{s}: 받은 바이트 {d} (stderr {d}), 보충 {d} 회, exit-status {?d}", .{ if (want_pty) "pty" else "no-pty", got, stderr_bytes, adjusts, exit_code });

    if (got < expect_bytes) return fail("출력이 모자란다 — 흐름 제어가 멈췄을 수 있다");
    // **stderr 도 본다.** 확장 데이터는 같은 윈도를 먹는데(§5.2), pty 를 요청하면 서버가 그것을
    // pty 로 합쳐 보내 그 경로가 아예 안 돈다 — 그래서 `no-pty` 회차가 따로 있다.
    if (stderr_bytes < expect_stderr) return fail("stderr 가 모자란다 — 확장 데이터 경로가 안 돌았다");
    if (adjusts == 0) return fail("보충이 한 번도 안 돌았다 — 이 스모크가 S7b 를 안 재고 있다");
    if (exit_code != 0) return fail("exit-status 가 0 이 아니다");
    say("OK", .{});
}

const msg_newkeys: u8 = 21;

/// 사건 하나를 처리하고 흐름 제어를 돌린다. **보내는 루프와 받는 루프가 같은 것을 쓴다.**
fn handle(ch: *channel.Channel, payload: []const u8) !void {
    var buf: [1024]u8 = undefined;
    switch (try ch.receive(payload)) {
        .data => |d| got += d.len,
        .extended_data => |x| stderr_bytes += x.data.len,
        .exit_status => |code| exit_code = code,
        .exit_signal => return error.RemoteKilledBySignal,
        .unknown_request => |u| if (u.want_reply) try send(try ch.writeChannelFailure(&buf)),
        .closed => {
            peer_closed = true;
            if (ch.state != .closed) try send(try ch.writeClose(&buf));
        },
        else => {},
    }
    // **계약 §3.1 의 두 줄.** 이것을 빼면 대량 출력이 도중에 멈춘다.
    if (ch.pendingWindowAdjust() != 0) {
        try send(try ch.writeWindowAdjust(&buf));
        adjusts += 1;
    }
}

/// 채널 요청의 답을 기다린다. **답 앞에 다른 사건이 끼어든다**(계약 §3.1.1).
fn awaitReply(ch: *channel.Channel, what: []const u8) !void {
    var buf: [1024]u8 = undefined;
    while (true) switch (try ch.receive(try recvChannel(&pkt))) {
        .request_success => return say("{s} 수락", .{what}),
        .request_failure => return fail("채널 요청 거절"),
        .window_adjusted => {
            if (ch.pendingWindowAdjust() != 0) try send(try ch.writeWindowAdjust(&buf));
        },
        .data, .extended_data => {},
        else => return fail("답을 기다리는 중 예상 밖 사건"),
    };
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[ssh-client-smoke] " ++ fmt ++ "\n", args);
}

fn fail(comptime msg: []const u8) error{SmokeFailed} {
    std.debug.print("[ssh-client-smoke] FAIL: " ++ msg ++ "\n", .{});
    return error.SmokeFailed;
}

var file_buf: [8192]u8 = undefined;

/// 개인키 파일을 읽어 base64 몸통을 디코딩한다. **PEM 껍데기는 이 층 밖이다**(계약 §4.4.3 —
/// `openssh-key-v1` 파서는 디코딩된 blob 을 받는다).
fn readFile(path: []const u8) ![]const u8 {
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

    // `-----BEGIN/END-----` 줄을 빼고 이어 붙인다.
    var b64_len: usize = 0;
    var b64: [8192]u8 = undefined;
    var it = std.mem.splitScalar(u8, raw[0..len], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "-----")) continue;
        @memcpy(b64[b64_len..][0..trimmed.len], trimmed);
        b64_len += trimmed.len;
    }
    const decoder = std.base64.standard.Decoder;
    const out_len = try decoder.calcSizeForSlice(b64[0..b64_len]);
    try decoder.decode(file_buf[0..out_len], b64[0..b64_len]);
    return file_buf[0..out_len];
}
