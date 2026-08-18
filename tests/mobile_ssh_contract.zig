//! 모바일 SSH ABI 계약 테스트(`src/platform/mobile/mobile_ssh.zig` ↔ `mobile_host_abi.h`).
//!
//! **헤더가 숫자의 단일 출처다.** 한쪽만 고치면 링크는 되고 뜻만 어긋난다 — host 는 상태를
//! 오해하고(예: `ready` 를 `closed` 로) 화면은 멀쩡한 채 아무 일도 안 난다. 그래서 헤더를
//! **그대로 읽어** 브리지 값과 대조한다(모바일 브리지 계약 테스트가 쓰는 방식과 같다).

const std = @import("std");
const ssh = @import("mobile_ssh");
const testing = std.testing;

const header = @embedFile("mobile_ssh_abi_for_test");

/// **헤더를 C 로 읽어 그대로 부른다.** 이름과 개수는 `tools/mobile-harness/abi_types.py` 가
/// 보지만 그것은 정규식이라 **인자 타입**까지는 못 본다 — `unsigned int` 자리에 `u64` 를 두면
/// C 는 컴파일되고 값만 조용히 깨진다. 여기서 부르면 컴파일·링크가 그것을 대신 잡는다.
const c = @cImport(@cInclude("mobile_host_abi.h"));

/// `#define NAME VALUE` 를 찾는다. 값은 `(-1)` 처럼 괄호가 붙거나 `0xFFFFFFFFu` 처럼 접미사가
/// 붙는다 — 헤더의 표기를 그대로 읽는 것이 요점이라 여기서 벗겨 낸다.
fn headerValue(name: []const u8) ?i64 {
    var it = std.mem.tokenizeScalar(u8, header, '\n');
    while (it.next()) |line| {
        const marker = "#define ";
        if (!std.mem.startsWith(u8, line, marker)) continue;
        var parts = std.mem.tokenizeAny(u8, line[marker.len..], " \t");
        const got = parts.next() orelse continue;
        if (!std.mem.eql(u8, got, name)) continue;
        var raw = parts.next() orelse return null;
        if (raw.len > 0 and raw[0] == '(') raw = raw[1..];
        if (raw.len > 0 and raw[raw.len - 1] == ')') raw = raw[0 .. raw.len - 1];
        if (raw.len > 0 and (raw[raw.len - 1] == 'u' or raw[raw.len - 1] == 'U')) raw = raw[0 .. raw.len - 1];
        if (std.mem.startsWith(u8, raw, "0x") or std.mem.startsWith(u8, raw, "0X")) {
            return std.fmt.parseInt(i64, raw[2..], 16) catch null;
        }
        return std.fmt.parseInt(i64, raw, 10) catch null;
    }
    return null;
}

fn expectHeader(name: []const u8, value: i64) !void {
    const got = headerValue(name) orelse {
        std.debug.print("헤더에 {s} 가 없다\n", .{name});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(value, got);
}

test "헤더 상수와 브리지 상수가 같다" {
    try expectHeader("MARU_SSH_MAX_SESSIONS", ssh.max_sessions);
    try expectHeader("MARU_SSH_SECRET_KEY_BYTES", ssh.secret_key_bytes);
    try expectHeader("MARU_SSH_ENTROPY_BYTES", ssh.entropy_bytes);
    try expectHeader("MARU_SSH_MAX_USER", ssh.max_user);
    try expectHeader("MARU_SSH_MAX_TERM", ssh.max_term);
    try expectHeader("MARU_SSH_OUT_BYTES", ssh.out_bytes);
    try expectHeader("MARU_SSH_SCREEN_BYTES", ssh.screen_bytes);
}

test "헤더 결과 코드와 브리지 결과 코드가 같다" {
    // **host 가 분기하는 값이다.** 어긋나면 인증 실패를 호스트키 문제로 보여 주고, 사용자는
    // 엉뚱한 것을 고치려 든다.
    try expectHeader("MARU_SSH_OK", ssh.ok);
    try expectHeader("MARU_SSH_ERR_BAD_HANDLE", ssh.err_bad_handle);
    try expectHeader("MARU_SSH_ERR_NO_SLOT", ssh.err_no_slot);
    try expectHeader("MARU_SSH_ERR_BAD_ARG", ssh.err_bad_arg);
    try expectHeader("MARU_SSH_ERR_HOST_KEY", ssh.err_host_key);
    try expectHeader("MARU_SSH_ERR_AUTH", ssh.err_auth);
    try expectHeader("MARU_SSH_ERR_PROTOCOL", ssh.err_protocol);
    try expectHeader("MARU_SSH_ERR_NOT_READY", ssh.err_not_ready);
    try expectHeader("MARU_SSH_ERR_BUFFER", ssh.err_buffer);
}

test "상태 숫자는 헤더가 정한다" {
    // 코어 enum 순서가 바뀌어도 host 가 읽는 값은 안 움직여야 한다. `@intFromEnum` 으로 재면
    // **그 성질을 안 재고** 순서만 재게 된다 — 그래서 헤더 값과 직접 맞댄다.
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(3);
    var h: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open(
        "u",
        1,
        &key,
        &seed,
        "xterm-256color",
        14,
        80,
        24,
        0,
        1,
        &h,
    ));
    defer _ = ssh.maru_mobile_ssh_close(h);
    // 갓 연 세션은 서버 버전 줄을 기다린다.
    try expectHeader("MARU_SSH_STATE_VERSION_EXCHANGE", ssh.maru_mobile_ssh_state(h));
    try expectHeader("MARU_SSH_STATE_INVALID", @as(i64, ssh.maru_mobile_ssh_state(h ^ 0x1000)));
}

test "여는 즉시 우리 버전 줄이 나가 있다" {
    // **여는 것과 첫 바이트를 내는 것을 나누면 host 가 한쪽을 잊는다.** 잊으면 서버는 우리
    // 버전 줄을 영영 못 받고, 증상은 "연결은 됐는데 아무 일도 안 난다" 다.
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(5);
    var h: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));
    defer _ = ssh.maru_mobile_ssh_close(h);

    const n = ssh.maru_mobile_ssh_out_len(h);
    try testing.expect(n > 0);
    const bytes = ssh.maru_mobile_ssh_out_ptr(h)[0..n];
    try testing.expect(std.mem.startsWith(u8, bytes, "SSH-2.0-"));
    try testing.expect(std.mem.endsWith(u8, bytes, "\r\n"));
}

test "부분 전송을 잃지 않는다" {
    // 소켓은 달라는 만큼 안 받아 준다. 남은 것을 브리지가 들고 있지 않으면 **버전 줄이 반만
    // 나가고** 서버는 영영 기다린다.
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(7);
    var h: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));
    defer _ = ssh.maru_mobile_ssh_close(h);

    const total = ssh.maru_mobile_ssh_out_len(h);
    var whole: [256]u8 = undefined;
    @memcpy(whole[0..total], ssh.maru_mobile_ssh_out_ptr(h)[0..total]);

    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_out_consume(h, 4));
    try testing.expectEqual(total - 4, ssh.maru_mobile_ssh_out_len(h));
    try testing.expectEqualStrings(whole[4..total], ssh.maru_mobile_ssh_out_ptr(h)[0 .. total - 4]);

    // 있는 것보다 많이 가져갔다고 하면 거절한다 — 그대로 빼면 길이가 감싸 돌아 남의 메모리를 읽는다.
    try testing.expectEqual(ssh.err_bad_arg, ssh.maru_mobile_ssh_out_consume(h, total));
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_out_consume(h, total - 4));
    try testing.expectEqual(@as(u32, 0), ssh.maru_mobile_ssh_out_len(h));
}

test "닫은 뒤의 옛 핸들은 새 세션을 못 건드린다" {
    // **이 부류가 조용하다.** 번호만 보면 재사용된 자리를 옛 핸들이 건드려, 끝난 세션의 키 입력이
    // 새 세션으로 나간다 — 증상이 원인과 아주 멀다.
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(11);
    var first: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &first));
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_close(first));

    var second: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &second));
    defer _ = ssh.maru_mobile_ssh_close(second);
    try testing.expect(first != second); // 같은 자리라도 세대가 다르다

    try testing.expectEqual(ssh.err_bad_handle, ssh.maru_mobile_ssh_close(first));
    try testing.expectEqual(ssh.state_invalid, ssh.maru_mobile_ssh_state(first));
    var sent: u32 = 0;
    try testing.expectEqual(ssh.err_bad_handle, ssh.maru_mobile_ssh_write(first, "x", 1, &sent));
    try testing.expectEqual(@as(u32, 0), ssh.maru_mobile_ssh_out_len(first));
}

test "닫으면 비밀이 남지 않는다" {
    // 슬롯은 재사용된다 — 지우지 않으면 **다음 세션의 메모리에 앞 사람의 개인키가 있다.**
    var key: [64]u8 = @splat(0xAB);
    var seed: [32]u8 = @splat(13);
    var h: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));

    const index = (h & 0xFFFF) - 1;
    try testing.expect(std.mem.indexOfScalar(u8, &ssh.slots[index].cl.opts.secret_key, 0xAB) != null);
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_close(h));
    for (ssh.slots[index].cl.opts.secret_key) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "예측 가능한 씨앗은 안 받는다" {
    // **이 층은 OS 를 못 부른다** — 난수는 host 가 준다. 0 을 그대로 받으면 임시키·cookie 가
    // 예측 가능해져 그 세션의 비밀이 통째로 깨지고, 화면은 멀쩡해서 아무도 모른다.
    var key: [64]u8 = @splat(0);
    var zero: [32]u8 = @splat(0);
    var h: u32 = 0xDEAD;
    try testing.expectEqual(ssh.err_bad_arg, ssh.maru_mobile_ssh_open("u", 1, &key, &zero, "xterm", 5, 80, 24, 0, 1, &h));
    try testing.expectEqual(@as(u32, 0), h); // 실패하면 핸들도 안 준다
}

test "인자가 이상하면 자리를 안 쓴다" {
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(17);
    var h: u32 = 0;
    const long_user: [ssh.max_user + 1]u8 = @splat('u');
    try testing.expectEqual(ssh.err_bad_arg, ssh.maru_mobile_ssh_open(&long_user, long_user.len, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));
    try testing.expectEqual(ssh.err_bad_arg, ssh.maru_mobile_ssh_open("u", 0, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));
    try testing.expectEqual(ssh.err_bad_arg, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 0, 24, 0, 1, &h));
    try testing.expectEqual(ssh.err_bad_arg, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 0, 0, 1, &h));

    // 전부 실패했으니 자리는 그대로 비어 있어야 한다.
    var handles: [ssh.max_sessions]u32 = @splat(0);
    for (&handles) |*slot| {
        try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, slot));
    }
    defer for (handles) |x| {
        _ = ssh.maru_mobile_ssh_close(x);
    };
    var extra: u32 = 0;
    try testing.expectEqual(ssh.err_no_slot, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &extra));
}

test "셸이 뜨기 전에는 못 쓴다" {
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(19);
    var h: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));
    defer _ = ssh.maru_mobile_ssh_close(h);

    var sent: u32 = 0;
    try testing.expectEqual(ssh.err_not_ready, ssh.maru_mobile_ssh_write(h, "ls\n", 3, &sent));
    try testing.expectEqual(@as(u32, 0), sent);
    // 실패는 이름으로 남고 **읽은 쪽이 비운다**(§5).
    try testing.expectEqualStrings("NotReady", std.mem.span(ssh.maru_mobile_ssh_last_error(h)));
    ssh.maru_mobile_ssh_clear_error(h);
    try testing.expectEqualStrings("", std.mem.span(ssh.maru_mobile_ssh_last_error(h)));

    var code: u32 = 0;
    try testing.expectEqual(ssh.err_not_ready, ssh.maru_mobile_ssh_exit_status(h, &code));
}

test "덜 온 바이트는 먹지 않는다" {
    // TCP 는 잘라서 준다. 덜 온 것을 먹었다고 하면 그 바이트가 사라져 세션이 조용히 깨진다.
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(23);
    var h: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));
    defer _ = ssh.maru_mobile_ssh_close(h);
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_out_consume(h, ssh.maru_mobile_ssh_out_len(h)));

    var consumed: u32 = 0xFFFF;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_feed(h, "SSH-2.0-Op", 10, &consumed));
    try testing.expectEqual(@as(u32, 0), consumed); // 줄이 안 끝났다

    // 줄이 끝나면 먹고, 우리 KEXINIT 이 나간다.
    const rest = "enSSH_10.2\r\n";
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_feed(h, "SSH-2.0-OpenSSH_10.2\r\n", 22, &consumed));
    _ = rest;
    try testing.expectEqual(@as(u32, 22), consumed);
    try testing.expect(ssh.maru_mobile_ssh_out_len(h) > 0);
    try expectHeader("MARU_SSH_STATE_NEGOTIATING", ssh.maru_mobile_ssh_state(h));
}

test "쓰레기를 먹여도 안 죽고 오류로 끝난다" {
    // 선 위의 바이트는 아무거나 올 수 있다. 여기서 패닉하면 **앱이 죽는다**.
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(29);
    var h: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));
    defer _ = ssh.maru_mobile_ssh_close(h);
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_out_consume(h, ssh.maru_mobile_ssh_out_len(h)));

    // **버전 줄 앞의 아무 줄이나는 배너다**(RFC 4253 §4.2 — 계약 §3.2.2). 제어문자가 있어도
    // 배너 줄에는 그 검사를 안 씌운다. 즉 이건 실패가 아니라 정상이고, 여기서 오류를 기대하면
    // 계약이 아니라 내 짐작을 재게 된다.
    var consumed: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_feed(h, "\x00\x01\x02\x03\r\n", 6, &consumed));
    try testing.expectEqualStrings("", std.mem.span(ssh.maru_mobile_ssh_last_error(h)));

    // **버전 줄 자체가 이상하면 실패다** — 그 줄은 교환 해시에 들어가고 사용자에게도 보인다.
    const status = ssh.maru_mobile_ssh_feed(h, "SSH-2.0-\x1b]0;x\x07\r\n", 17, &consumed);
    try testing.expect(status < 0);
    try testing.expectEqualStrings("MalformedVersion", std.mem.span(ssh.maru_mobile_ssh_last_error(h)));
}

test "핸들이 틀리면 문자열도 빈 것을 준다" {
    // host 는 이 값을 그대로 문자열로 읽는다 — null 을 주면 그 자리에서 죽는다.
    const bad: u32 = 0x7FFF_0001;
    try testing.expectEqualStrings("", std.mem.span(ssh.maru_mobile_ssh_last_error(bad)));
    try testing.expectEqualStrings("", std.mem.span(ssh.maru_mobile_ssh_banner(bad)));
    try testing.expectEqualStrings("", std.mem.span(ssh.maru_mobile_ssh_disconnect_description(bad)));
    try testing.expectEqualStrings("", std.mem.span(ssh.maru_mobile_ssh_exit_signal(bad)));
    try testing.expectEqualStrings("", std.mem.span(ssh.maru_mobile_ssh_host_key_fingerprint(bad)));
    try testing.expectEqual(@as(u32, 0), ssh.maru_mobile_ssh_disconnect_reason(bad));
    try testing.expectEqual(@as(u32, 0), ssh.maru_mobile_ssh_screen_len(bad));
    ssh.maru_mobile_ssh_clear_error(bad); // 안 죽는다
}

/// 셸이 뜬 세션을 손으로 세운다. 실서버 없이 **보내는 쪽**을 재려면 이 자리가 필요하다
/// (실서버 왕복은 `tools/ssh/abi_smoke.zig` 가 따로 한다).
fn openReady() !u32 {
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(31);
    var h: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));
    const s = &ssh.slots[(h & 0xFFFF) - 1];
    s.cl.state = .ready;
    s.cl.shell_ready = true;
    s.cl.t.phase = .established;
    s.cl.t.kex_send_done = true;
    s.cl.t.kex_recv_done = true;
    s.cl.ch.state = .open;
    s.cl.ch.local_id = 0;
    s.cl.ch.remote_id = 0;
    s.cl.ch.remote_window = 1 << 20;
    s.cl.ch.remote_max_packet = 32768;
    return h;
}

test "자리가 좁으면 들어갈 만큼만 보낸다" {
    // **코어는 우리 버퍼 크기를 모른다** — 창과 데이터 길이로만 자른다. 그대로 넘기면 자리가
    // 모자랄 때 `NoSpace` 로 **한 바이트도 못 보내고**, host 는 자기 버퍼 사정을 짐작해 스스로
    // 잘라야 한다. 버퍼를 아는 쪽이 자르는 것이 맞다.
    const h = try openReady();
    defer _ = ssh.maru_mobile_ssh_close(h);

    // 선 버퍼를 채워 딱 한 걸음치(4KiB)만 남긴다.
    const s = &ssh.slots[(h & 0xFFFF) - 1];
    s.out_len = ssh.out_bytes - 4096;

    var big: [32768]u8 = @splat('x');
    var sent: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_write(h, &big, big.len, &sent));
    try testing.expect(sent > 0); // 들어갈 만큼은 갔다
    try testing.expect(sent < big.len); // 다는 못 갔다
    try testing.expect(ssh.maru_mobile_ssh_out_len(h) <= ssh.out_bytes); // 넘치지 않았다

    // 나머지는 비운 뒤에 간다 — 호출자가 다시 주면 된다.
    s.out_len = 0;
    var sent2: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_write(h, big[sent..].ptr, @intCast(big.len - sent), &sent2));
    try testing.expect(sent2 > 0);
}

test "닫자마자 같은 핸들로는 아무것도 못 한다" {
    // 세대는 **다시 열 때** 오른다 — 닫고 다시 안 열면 세대가 그대로다. 즉 이 자리를 지키는
    // 것은 "쓰는 중인가" 표시뿐이고, 그것을 빠뜨리면 **닫은 세션에 계속 쓸 수 있다**.
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(37);
    var h: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_close(h));

    try testing.expectEqual(ssh.state_invalid, ssh.maru_mobile_ssh_state(h));
    try testing.expectEqual(ssh.err_bad_handle, ssh.maru_mobile_ssh_close(h));
    try testing.expectEqual(ssh.err_bad_handle, ssh.maru_mobile_ssh_accept_host_key(h));
    try testing.expectEqual(ssh.err_bad_handle, ssh.maru_mobile_ssh_eof(h));
    try testing.expectEqual(ssh.err_bad_handle, ssh.maru_mobile_ssh_resize(h, 100, 40));
    var consumed: u32 = 0;
    try testing.expectEqual(ssh.err_bad_handle, ssh.maru_mobile_ssh_feed(h, "x", 1, &consumed));
    try testing.expectEqual(@as(u32, 0), ssh.maru_mobile_ssh_out_len(h));
}

test "상태 열두 개가 전부 헤더 값으로 나온다" {
    // 하나만 재면 나머지 열한 개가 밀려도 초록이다 — **전수로** 돈다. 이름은 헤더의 상수 이름을
    // 코어 enum 이름에서 만든다(둘이 갈리면 여기서 걸린다).
    const h = try openReady();
    defer _ = ssh.maru_mobile_ssh_close(h);
    const s = &ssh.slots[(h & 0xFFFF) - 1];

    const State = @TypeOf(s.cl.state);
    var checked: usize = 0;
    inline for (@typeInfo(State).@"enum".fields) |f| {
        s.cl.state = @field(State, f.name);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "MARU_SSH_STATE_{s}", .{f.name});
        for (name["MARU_SSH_STATE_".len..]) |*ch| ch.* = std.ascii.toUpper(ch.*);
        try expectHeader(name, ssh.maru_mobile_ssh_state(h));
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 13), checked); // 상태가 늘면 헤더도 늘어야 한다
}

test "가져가지 않으면 멈춘다 — 잃지 않는다" {
    // **배압이 없으면 넘치고, 넘치면 잃는다.** 화면·선 버퍼가 찼는데 먹으면 그 바이트는 갈 곳이
    // 없다 — 세션이 조용히 깨지는 대신 "비우고 다시 부르라" 고 답한다.
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(41);
    var h: u32 = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h));
    defer _ = ssh.maru_mobile_ssh_close(h);
    const s = &ssh.slots[(h & 0xFFFF) - 1];

    var consumed: u32 = 0xFFFF;
    s.screen_len = ssh.screen_bytes; // 화면을 안 가져갔다
    try testing.expectEqual(ssh.err_buffer, ssh.maru_mobile_ssh_feed(h, "SSH-2.0-x\r\n", 11, &consumed));
    try testing.expectEqual(@as(u32, 0), consumed); // 한 바이트도 안 먹었다

    s.screen_len = 0;
    s.out_len = ssh.out_bytes; // 선을 안 보냈다
    try testing.expectEqual(ssh.err_buffer, ssh.maru_mobile_ssh_feed(h, "SSH-2.0-x\r\n", 11, &consumed));
    try testing.expectEqual(@as(u32, 0), consumed);

    // 비우면 다시 돈다.
    s.out_len = 0;
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_feed(h, "SSH-2.0-x\r\n", 11, &consumed));
    try testing.expectEqual(@as(u32, 11), consumed);
}

test "셸이 뜬 뒤 자리가 없으면 보내는 쪽도 멈춘다" {
    // 위 테스트는 셸이 뜨기 전이라 `eof`·`resize` 는 **자리가 아니라 상태** 때문에 막힌다 —
    // 그 둘을 한 자리에서 재면 무엇이 막았는지 못 가른다(실제로 그렇게 잘못 재고 있었다).
    const h = try openReady();
    defer _ = ssh.maru_mobile_ssh_close(h);
    const s = &ssh.slots[(h & 0xFFFF) - 1];

    s.out_len = ssh.out_bytes;
    try testing.expectEqual(ssh.err_buffer, ssh.maru_mobile_ssh_eof(h));
    try testing.expectEqual(ssh.err_buffer, ssh.maru_mobile_ssh_resize(h, 100, 40));
    var sent: u32 = 0;
    try testing.expectEqual(ssh.err_buffer, ssh.maru_mobile_ssh_write(h, "x", 1, &sent));
    // **왜 막혔는지 이름이 남는다**(§5).
    try testing.expect(ssh.maru_mobile_ssh_last_error(h)[0] != 0);

    s.out_len = 0;
    ssh.maru_mobile_ssh_clear_error(h);
    try testing.expectEqual(ssh.ok, ssh.maru_mobile_ssh_resize(h, 100, 40));
    try testing.expect(ssh.maru_mobile_ssh_out_len(h) > 0);
}

test "오류는 하나도 빠짐없이 실패 코드로 내려온다" {
    // **성공으로 접히는 오류가 하나라도 있으면** host 는 실패를 못 보고 그대로 진행한다.
    // 코어에 오류가 늘면 `statusOf` 의 switch 가 컴파일에서 걸리지만, 그때 **아무 코드나** 골라도
    // 컴파일은 되므로 값 자체는 여기서 잰다.
    const Error = @TypeOf(ssh.statusOf);
    _ = Error;
    var seen: usize = 0;
    inline for (@typeInfo(@typeInfo(@TypeOf(ssh.statusOf)).@"fn".params[0].type.?).error_set.?) |e| {
        const status = ssh.statusOf(@field(anyerror, e.name));
        try testing.expect(status < 0);
        try testing.expect(status >= ssh.err_buffer and status <= ssh.err_bad_handle);
        seen += 1;
    }
    try testing.expect(seen >= 40); // 48개 언저리 — 줄어들면 무엇이 사라졌는지 봐야 한다
}

test "host 가 분기하는 세 갈래가 제 코드로 온다" {
    // 이 셋은 **화면이 다르다**: 지문을 보이고 묻는다 / 키가 안 먹혔다고 말한다 / 그 밖의 실패.
    try testing.expectEqual(ssh.err_host_key, ssh.statusOf(error.HostKeyNotAccepted));
    try testing.expectEqual(ssh.err_host_key, ssh.statusOf(error.HostKeyRejected));
    // **서명이 안 맞는 것도 호스트키 문제다** — 중간자일 수 있고, 사용자에게 물어야 하는 자리다.
    try testing.expectEqual(ssh.err_host_key, ssh.statusOf(error.BadSignature));
    try testing.expectEqual(ssh.err_auth, ssh.statusOf(error.AuthFailed));
    try testing.expectEqual(ssh.err_bad_arg, ssh.statusOf(error.BadPrivateKey));
    try testing.expectEqual(ssh.err_not_ready, ssh.statusOf(error.NotReady));
    try testing.expectEqual(ssh.err_buffer, ssh.statusOf(error.ShortBuffer));
    try testing.expectEqual(ssh.err_protocol, ssh.statusOf(error.MalformedPacket));
}

test "먼저 난 실패가 남는다" {
    // 뒤에 난 것으로 덮으면 **원인이 결과에 가린다** — 첫 실패가 나머지를 부르는 경우가 흔하다.
    const h = try openReady();
    defer _ = ssh.maru_mobile_ssh_close(h);
    const s = &ssh.slots[(h & 0xFFFF) - 1];

    s.out_len = ssh.out_bytes;
    var sent: u32 = 0;
    try testing.expectEqual(ssh.err_buffer, ssh.maru_mobile_ssh_write(h, "x", 1, &sent));
    try testing.expectEqualStrings("ssh_out_full", std.mem.span(ssh.maru_mobile_ssh_last_error(h)));

    // 다른 실패를 하나 더 낸다 — 이름은 안 바뀐다.
    s.out_len = 0;
    s.cl.shell_ready = false;
    try testing.expectEqual(ssh.err_not_ready, ssh.maru_mobile_ssh_write(h, "x", 1, &sent));
    try testing.expectEqualStrings("ssh_out_full", std.mem.span(ssh.maru_mobile_ssh_last_error(h)));

    // 읽은 쪽이 비우면 다음 실패가 보인다.
    ssh.maru_mobile_ssh_clear_error(h);
    try testing.expectEqual(ssh.err_not_ready, ssh.maru_mobile_ssh_write(h, "x", 1, &sent));
    try testing.expectEqualStrings("NotReady", std.mem.span(ssh.maru_mobile_ssh_last_error(h)));
}

test "지문은 한 번 만들면 그대로 남는다" {
    // **사용자가 승인한 값이다.** 물어보는 화면이 지나간 뒤에도(세션 정보·로그) 같은 값이 보여야
    // 한다. 세션 도중 키가 바뀌는 일은 코어가 막는다(`HostKeyChanged`) — 그래서 캐시해도 된다.
    const h = try openReady();
    defer _ = ssh.maru_mobile_ssh_close(h);
    const s = &ssh.slots[(h & 0xFFFF) - 1];

    // `ssh-ed25519` blob 한 개(길이+이름, 길이+32바이트).
    var blob: [64]u8 = undefined;
    var n: usize = 0;
    const alg = "ssh-ed25519";
    std.mem.writeInt(u32, blob[n..][0..4], @intCast(alg.len), .big);
    n += 4;
    @memcpy(blob[n..][0..alg.len], alg);
    n += alg.len;
    std.mem.writeInt(u32, blob[n..][0..4], 32, .big);
    n += 4;
    @memset(blob[n..][0..32], 7);
    n += 32;
    @memcpy(s.cl.host_key_buf[0..n], blob[0..n]);
    s.cl.host_key_len = n;
    s.cl.state = .host_key_decision;

    const first = std.mem.span(ssh.maru_mobile_ssh_host_key_fingerprint(h));
    try testing.expect(std.mem.startsWith(u8, first, "SHA256:"));
    try testing.expectEqual(@as(usize, "SHA256:".len + 43), first.len); // base64 44자에서 패딩 하나

    // 상태가 지나가도 같은 값이다.
    s.cl.state = .ready;
    try testing.expectEqualStrings(first, std.mem.span(ssh.maru_mobile_ssh_host_key_fingerprint(h)));
}

test "C 선언 그대로 불러도 같은 것이 나온다" {
    // Zig 쪽 export 를 부르는 위 테스트들과 **같은 함수**여야 한다. 링크가 그것을 보증하고,
    // 인자·반환 타입은 컴파일이 보증한다.
    var key: [64]u8 = @splat(0);
    var seed: [32]u8 = @splat(43);
    var h: c_uint = 0;
    const status = c.maru_mobile_ssh_open("u", 1, &key, &seed, "xterm", 5, 80, 24, 0, 1, &h);
    try testing.expectEqual(@as(c_int, c.MARU_SSH_OK), status);
    defer _ = c.maru_mobile_ssh_close(h);

    try testing.expectEqual(@as(c_uint, c.MARU_SSH_STATE_VERSION_EXCHANGE), c.maru_mobile_ssh_state(h));
    try testing.expect(c.maru_mobile_ssh_out_len(h) > 0);

    // 헤더 상수와 Zig 상수가 같은 값이라는 것도 여기서 한 번 더 잰다(다른 경로로).
    try testing.expectEqual(@as(c_uint, ssh.max_sessions), @as(c_uint, c.MARU_SSH_MAX_SESSIONS));
    try testing.expectEqual(@as(c_int, ssh.err_host_key), @as(c_int, c.MARU_SSH_ERR_HOST_KEY));
    try testing.expectEqual(@as(c_uint, ssh.state_invalid), @as(c_uint, c.MARU_SSH_STATE_INVALID));

    // 원격 출력 sink(`term_write`)와 답 경로(`take_response`)는 브리지 쪽 심볼이라 그 계약
    // 테스트가 같은 방식으로 부른다.
}

/// C 선언과 Zig export 의 **모양**이 같은가. 이름·개수는 `abi_types.py` 가 보고, 실제 호출은 위
/// 테스트가 하지만, 둘 다 **인자 폭**은 못 본다 — 리터럴을 넘기면 어느 폭에도 맞아 들어가고,
/// 그러면 `unsigned int` 자리에 64비트를 둔 host 가 값이 밀린 채로 돈다.
fn sameShape(comptime CFn: type, comptime ZFn: type) bool {
    const ci = @typeInfo(CFn).@"fn";
    const zi = @typeInfo(ZFn).@"fn";
    if (ci.params.len != zi.params.len) return false;
    if (@sizeOf(ci.return_type.?) != @sizeOf(zi.return_type.?)) return false;
    inline for (ci.params, zi.params) |cp, zp| {
        if (@sizeOf(cp.type.?) != @sizeOf(zp.type.?)) return false;
    }
    return true;
}

test "헤더와 브리지의 인자 폭이 전부 같다" {
    const names = .{
        "maru_mobile_ssh_open",                   "maru_mobile_ssh_close",
        "maru_mobile_ssh_state",                  "maru_mobile_ssh_feed",
        "maru_mobile_ssh_write",                  "maru_mobile_ssh_resize",
        "maru_mobile_ssh_eof",                    "maru_mobile_ssh_out_ptr",
        "maru_mobile_ssh_out_len",                "maru_mobile_ssh_out_consume",
        "maru_mobile_ssh_screen_ptr",             "maru_mobile_ssh_screen_len",
        "maru_mobile_ssh_screen_consume",         "maru_mobile_ssh_host_key_fingerprint",
        "maru_mobile_ssh_accept_host_key",        "maru_mobile_ssh_disconnect_reason",
        "maru_mobile_ssh_disconnect_description", "maru_mobile_ssh_banner",
        "maru_mobile_ssh_exit_status",            "maru_mobile_ssh_exit_signal",
        "maru_mobile_ssh_last_error",             "maru_mobile_ssh_clear_error",
    };
    inline for (names) |name| {
        if (!sameShape(@TypeOf(@field(c, name)), @TypeOf(@field(ssh, name)))) {
            std.debug.print("모양이 다르다: {s}\n", .{name});
            return error.TestUnexpectedResult;
        }
    }

    // **목록이 빠지면 그 함수는 안 재어진다.** 헤더에 선언된 개수와 맞춘다.
    var declared: usize = 0;
    var it = std.mem.tokenizeScalar(u8, header, '\n');
    while (it.next()) |line| {
        // 선언은 **이름과 여는 괄호가 한 줄에** 있다. 주석(`///`)은 세지 않는다 — 산문에도
        // 함수 이름이 나오고, 그것까지 세면 목록이 모자라도 초록이 된다.
        if (std.mem.startsWith(u8, line, "///")) continue;
        const at = std.mem.indexOf(u8, line, "maru_mobile_ssh_") orelse continue;
        if (std.mem.indexOfScalar(u8, line[at..], '(') == null) continue;
        declared += 1;
    }
    try testing.expectEqual(names.len, declared);
}

test "세션 하나가 드는 자리" {
    // **모바일에서 상한은 정책이다.** 이 값이 조용히 자라면(버퍼를 늘리거나 코어에 필드가 붙으면)
    // 세션 네 개가 드는 자리가 같이 자란다 — 그 숫자를 헤더에 적어 두고 여기서 지킨다.
    // 실측(2026-08-18): 슬롯 하나 111,352B → 네 개 445,408B. 상한은 그 위에 여유를 둔 값이다.
    const one = @sizeOf(@TypeOf(ssh.slots[0]));
    try testing.expect(one <= 128 * 1024);
    try testing.expect(one * ssh.max_sessions <= 512 * 1024);
}
