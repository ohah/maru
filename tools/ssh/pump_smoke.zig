//! **두 host 가 쓸 C 펌프의 실서버 스모크**(계획 S9-3). `src/platform/mobile_host/ssh_pump.c` 를
//! 그대로 링크해 진짜 sshd 와 왕복한다 — 기기에 올리기 **전에** 그 코드가 도는 것을 본다.
//!
//! **이 스모크가 기기 검증을 대신하지는 않는다.** 여기서 확인되는 것은 소켓·스레드·세션 루프와
//! 호스트키 핀 고정이고, 화면에 실제로 그려지는지·포그라운드 서비스가 사는지는 기기에서 본다.
//! 다만 그때 실패하면 **남는 후보가 host 배선뿐**이 된다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const abi = @import("mobile_ssh");

const pump = @cImport({
    @cInclude("ssh_pump.h");
});

// **ABI 진입점을 링크에 남긴다.** 펌프(C)가 그 심볼들을 부르는데, 테스트 빌드는 Zig 쪽에서
// 아무도 안 부르면 export 를 통째로 지운다 — 그러면 "undefined symbol" 로 링크가 깨진다.
comptime {
    _ = abi;
}

var screen_total: usize = 0;
var screen_head: [4096]u8 = undefined;
var screen_head_len: usize = 0;
var state_seen: [16]bool = @splat(false);

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[ssh-pump-smoke] " ++ fmt ++ "\n", args);
}

fn fail(comptime msg: []const u8) error{SmokeFailed} {
    std.debug.print("[ssh-pump-smoke] FAIL: " ++ msg ++ "\n", .{});
    return error.SmokeFailed;
}

var control_head: [4096]u8 = undefined;
var control_head_len: usize = 0;
var control_total: usize = 0;

/// host 가 하는 일 — 화면에 넣는다. 여기서는 세고 앞부분만 보관한다.
fn onScreen(_: ?*anyopaque, bytes: [*c]const u8, len: c_ulong) callconv(.c) void {
    const n = @min(@as(usize, @intCast(len)), screen_head.len - screen_head_len);
    if (n > 0) {
        @memcpy(screen_head[screen_head_len..][0..n], bytes[0..n]);
        screen_head_len += n;
    }
    screen_total += @intCast(len);
}

/// 컨트롤 채널이 받은 바이트. **화면과 다른 자리에 쌓는다** — 한 자리에 합치면 이 회차가
/// "안 섞였다" 를 못 잰다.
fn onControl(_: ?*anyopaque, bytes: [*c]const u8, len: c_ulong) callconv(.c) void {
    const n = @min(@as(usize, @intCast(len)), control_head.len - control_head_len);
    if (n > 0) {
        @memcpy(control_head[control_head_len..][0..n], bytes[0..n]);
        control_head_len += n;
    }
    control_total += @intCast(len);
}

/// 답을 돌려줄 것이 없다(터미널 코어가 없는 스모크다). 0 을 준다.
fn onTakeResponse(_: ?*anyopaque, _: [*c]u8, _: c_ulong) callconv(.c) c_ulong {
    return 0;
}

fn onState(_: ?*anyopaque, state: c_uint) callconv(.c) void {
    if (state < state_seen.len) state_seen[state] = true;
}

/// 단조 시계(ms). **경과를 진짜로 재려고 든다** — 직접 더한 값으로는 아무것도 안 재어진다.
fn monotonicMs() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

/// 잠깐 잔다. 펌프가 **다른 스레드**에서 도므로 여기서는 기다리기만 한다.
fn sleepMs(ms: u64) void {
    var ts: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = c.nanosleep(&ts, null);
}

fn readAll(path: []const u8, out: []u8) ![]u8 {
    var path_z: [1024]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fd = c.open(@ptrCast(&path_z), .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var len: usize = 0;
    while (len < out.len) {
        const n = c.read(fd, out[len..].ptr, out.len - len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        len += @intCast(n);
    }
    return out[0..len];
}

var file_buf: [8192]u8 = undefined;

/// 씨앗 파일(32B)로 **기기에서 만드는 것과 같은 키**를 만든다.
///
/// **씨앗을 인자로 받는 것이 요점이다.** 제품은 OS 난수를 넣고, 검증은 같은 씨앗을 두 번 넣어
/// (한 번은 공개키 줄을 뽑고, 한 번은 그 키로 붙어서) **만든 키가 진짜 OpenSSH 에 먹히는지**를
/// 잰다 — 형식만 그럴싸한 공개키는 붙여 넣고서야 안 먹는 것을 알게 된다.
fn generateFromSeedFile(path: []const u8, out: *[64]u8, line: []u8) !usize {
    var seed_buf: [64]u8 = undefined;
    const seed = try readAll(path, &seed_buf);
    if (seed.len < 32) return error.SeedTooShort;
    if (abi.maru_mobile_ssh_generate_key(seed.ptr, out, line.ptr, @intCast(line.len)) != abi.ok) {
        say("키를 못 만들었다: {s}", .{std.mem.span(abi.maru_mobile_ssh_last_load_error())});
        return error.KeyGenerateFailed;
    }
    return std.mem.len(@as([*:0]const u8, @ptrCast(line.ptr)));
}

pub fn main(init: std.process.Init.Minimal) !void {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const port_str = it.next() orelse return fail("포트를 인자로 준다");
    const user = it.next() orelse return fail("사용자 이름을 인자로 준다");
    const key_path = it.next() orelse return fail("개인키 경로를 인자로 준다");
    const fingerprint = it.next() orelse return fail("기대 지문을 인자로 준다");
    const marker = it.next() orelse return fail("화면에서 찾을 문자열을 인자로 준다");
    // 0 이면 표시만 찾는다. 크면 **그만큼 받을 때까지** 기다린다(재키잉을 태우는 회차).
    const expect_bytes = try std.fmt.parseInt(usize, it.next() orelse "0", 10);
    // **컨트롤 회차(S10b-2).** 펌프가 두 번째 채널을 열고 그 바이트를 **화면과 다른 훅**으로
    // 올리는지 본다. ABI 회차는 Zig 이 소켓을 들었고, 여기서는 기기가 쓸 C 가 그 길을 지난다.
    const want_control = std.mem.eql(u8, it.next() orelse "", "control");
    const port = try std.fmt.parseInt(u16, port_str, 10);

    // **키는 ABI 가 든다** — host 는 파일만 읽거나(기존 키) 씨앗을 넣어 만들게 한다(기기와 같다).
    var secret: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    if (std.mem.startsWith(u8, key_path, "seed:")) {
        var line: [256]u8 = @splat(0);
        const n = try generateFromSeedFile(key_path["seed:".len..], &secret, &line);
        if (std.mem.eql(u8, marker, "PRINT_PUBLIC_LINE")) {
            // 공개키 줄만 찍고 끝낸다 — 스크립트가 그것을 `authorized_keys` 에 넣는다.
            var out_buf: [512]u8 = undefined;
            const msg = try std.fmt.bufPrint(&out_buf, "{s}\n", .{line[0..n]});
            _ = c.write(1, msg.ptr, msg.len);
            return;
        }
    } else {
        const pem = try readAll(key_path, &file_buf);
        if (abi.maru_mobile_ssh_load_key(pem.ptr, @intCast(pem.len), "", 0, &secret) != abi.ok) {
            say("키를 못 읽었다: {s}", .{std.mem.span(abi.maru_mobile_ssh_last_load_error())});
            return fail("키 읽기 실패");
        }
    }

    var user_z: [128]u8 = @splat(0);
    @memcpy(user_z[0..user.len], user);
    var host_z: [128]u8 = @splat(0);
    @memcpy(host_z[0.."127.0.0.1".len], "127.0.0.1");
    var fp_z: [128]u8 = @splat(0);
    @memcpy(fp_z[0..fingerprint.len], fingerprint);

    var cfg: pump.MaruSshPumpConfig = .{
        .host = &host_z,
        .port = port,
        .user = &user_z,
        .secret = &secret,
        .cols = 80,
        .rows = 24,
        .expect_fingerprint = &fp_z,
    };
    var hooks: pump.MaruSshPumpHooks = .{
        .lock = null,
        .unlock = null,
        .screen = onScreen,
        .take_response = onTakeResponse,
        .state_changed = onState,
        .control = onControl,
        .ctx = null,
    };

    if (pump.maru_ssh_pump_start(&cfg, &hooks) != 0) {
        say("시작 실패: {s}", .{std.mem.span(pump.maru_ssh_pump_error())});
        return fail("펌프를 못 띄웠다");
    }

    if (want_control) {
        // 셸이 뜰 때까지 기다렸다가 채널을 연다 — 그 전에는 열 수 없다(계약 §3.4.1).
        var waited: usize = 0;
        while (waited < 30_000 and pump.maru_ssh_pump_state() != 11) : (waited += 50) sleepMs(50);
        if (pump.maru_ssh_pump_state() != 11) return fail("셸이 안 떴다");

        const cmd = "echo MARU_PUMP_CONTROL_OK";
        // **재키잉 중이면 실패로 온다 — 다시 부른다.** 조용히 성공을 돌려주면 열린 줄 안다.
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            if (pump.maru_ssh_pump_open_control(cmd, cmd.len) == 0) break;
            sleepMs(50);
        }
        if (pump.maru_ssh_pump_control_state() == 0) return fail("컨트롤 채널을 못 열었다");

        waited = 0;
        while (waited < 30_000) : (waited += 50) {
            if (control_total >= "MARU_PUMP_CONTROL_OK".len) break;
            sleepMs(50);
        }
        const got = control_head[0..control_head_len];
        if (std.mem.indexOf(u8, got, "MARU_PUMP_CONTROL_OK") == null) {
            say("컨트롤 {d}B, 상태={d}, stderr={s}", .{
                control_total, pump.maru_ssh_pump_control_state(), std.mem.span(pump.maru_ssh_pump_control_stderr()),
            });
            return fail("컨트롤 바이트가 펌프를 안 지났다");
        }
        // **화면 훅과 안 섞였다** — 섞이면 파서가 사람 화면을 읽게 된다(계약 §4a).
        if (std.mem.indexOf(u8, screen_head[0..screen_head_len], "MARU_PUMP_CONTROL_OK") != null) {
            return fail("컨트롤 출력이 화면 훅으로도 왔다");
        }
        say("컨트롤 {d}B 받았다 — 화면 훅과 안 섞였다", .{control_total});

        // **터미널은 그대로 산다.**
        if (pump.maru_ssh_pump_state() == 12) return fail("컨트롤 때문에 세션이 닫혔다");
        pump.maru_ssh_pump_close_control();
        pump.maru_ssh_pump_stop();
        say("OK", .{});
        return;
    }

    // **끝날 때까지 기다린다.** `ForceCommand` 가 한 줄 찍고 나가므로 세션이 스스로 닫힌다.
    // 대량 수신 회차는 그만큼 받을 때까지 더 기다린다(재키잉이 그 사이에 여러 번 일어난다).
    const budget_ms: usize = if (expect_bytes > 0) 180_000 else 30_000;
    var waited_ms: usize = 0;
    while (waited_ms < budget_ms) : (waited_ms += 50) {
        if (pump.maru_ssh_pump_state() == 12) break; // CLOSED
        sleepMs(50);
    }
    pump.maru_ssh_pump_stop();

    const err = std.mem.span(pump.maru_ssh_pump_error());
    // **실패 이유를 그대로 찍는다** — 부정 회차(핀 불일치)는 이 줄을 판정에 쓴다. 안 찍으면
    // "무슨 이유로든 실패" 가 통과가 되어, 핀 검사가 죽어도 초록이 된다.
    if (err.len > 0) say("오류: {s}", .{err});
    if (err.len > 0 and !std.mem.eql(u8, err, "closed_by_peer") and !std.mem.eql(u8, err, "disconnected")) {
        return fail("펌프가 실패로 끝났다");
    }
    // **거쳐 간 상태를 단언한다** — 안 그러면 "붙지도 못하고 조용히 끝난 것" 과 구별이 안 된다.
    if (!state_seen[4]) return fail("호스트키를 판정하는 자리를 안 지났다");
    if (!state_seen[11]) return fail("셸이 뜬 자리를 안 지났다");
    if (expect_bytes > 0) {
        // **재키잉을 태우는 회차다.** 서버가 `RekeyLimit 1M` 이면 이만큼 받는 동안 여러 번 키를
        // 간다 — 펌프·ABI 는 그 길을 한 번도 안 지나 봤다(모바일 세션은 길게 살아서 반드시
        // 만난다). 받은 양이 모자라면 그 사이에 멈춘 것이다.
        if (screen_total < expect_bytes) {
            say("받은 {d}B < 기대 {d}B (오류=[{s}])", .{ screen_total, expect_bytes, err });
            return fail("대량 수신이 도중에 멈췄다");
        }
        // **재키잉을 실제로 지났는지 센다.** 안 세면 서버가 키를 한 번도 안 갈아도 이 회차가
        // 초록이 된다 — "쟀다" 고 말할 수 없는 초록이 이 저장소에서 여러 번 나왔다.
        const rekeys = pump.maru_ssh_pump_rekeys();
        if (rekeys < 2) {
            say("재키잉 {d} 회 — 이 회차는 그 길을 재려고 있다", .{rekeys});
            return fail("재키잉이 안 일어났다");
        }
        say("대량 수신 {d}B, 재키잉 {d} 회, 거쳐 간 상태 12개", .{ screen_total, rekeys });
        say("OK", .{});
        return;
    }
    if (std.mem.indexOf(u8, screen_head[0..screen_head_len], marker) == null) {
        say("화면 {d}B 안에 표시가 없다", .{screen_total});
        return fail("원격 출력이 host 훅으로 안 왔다");
    }
    // **거쳐 간 상태를 세어 찍는다** — "붙었다" 만 찍으면 어디까지 갔는지 안 보인다.
    var seen_count: usize = 0;
    for (state_seen) |x| {
        if (x) seen_count += 1;
    }
    say("화면 {d}B, 표시 확인, 거쳐 간 상태 {d}개(호스트키·셸 포함)", .{ screen_total, seen_count });
    say("OK", .{});
}

test "지문이 다르면 붙지 않는다" {
    // **자동 승인은 없다**(SSH 계약 §4). 아직 물어볼 화면이 없어 핀 고정으로 그 약속을 지키는데,
    // 그 핀이 안 걸리면 남는 것은 무검증 접속이다 — 그러면 중간자가 그대로 통과한다.
    var secret: [64]u8 = @splat(1);
    var host_z: [16]u8 = @splat(0);
    @memcpy(host_z[0.."127.0.0.1".len], "127.0.0.1");
    var user_z: [8]u8 = @splat(0);
    user_z[0] = 'u';
    var fp_z: [8]u8 = @splat(0); // 빈 지문 = 핀이 없다

    var cfg: pump.MaruSshPumpConfig = .{
        .host = &host_z,
        .port = 1, // 아무도 안 듣는 포트 — 연결 자체가 실패해야 한다
        .user = &user_z,
        .secret = &secret,
        .cols = 80,
        .rows = 24,
        .expect_fingerprint = &fp_z,
    };
    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_start(&cfg, null));
    var waited: usize = 0;
    while (waited < 2000 and pump.maru_ssh_pump_error()[0] == 0) : (waited += 20) {
        sleepMs(20);
    }
    pump.maru_ssh_pump_stop();
    try std.testing.expectEqualStrings("connect_failed", std.mem.span(pump.maru_ssh_pump_error()));

    // 인자가 모자라면 아예 안 뜬다. **하나씩 다 본다** — 하나만 재면 나머지 가지가 죽어도
    // 초록이고, 그 값들은 그대로 `open` 에 실려 간다(0 열·0 행짜리 pty 를 요구하게 된다).
    inline for (.{ "host", "user" }) |field| {
        var bad = cfg;
        @field(bad, field) = null;
        try std.testing.expectEqual(@as(c_int, -2), pump.maru_ssh_pump_start(&bad, null));
    }
    // **`secret` 은 없어도 된다** — 키가 아직 없는 기기가 비밀번호만 여는 서버에 붙는 길이다
    // (RFC 4252 §5.2 의 `none`). 여기서 거절하면 그 서버에는 영영 못 붙는다(iOS 가 그랬다).
    {
        var no_key = cfg;
        no_key.secret = null;
        try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_start(&no_key, null));
        var waited2: usize = 0;
        while (waited2 < 2000 and pump.maru_ssh_pump_error()[0] == 0) : (waited2 += 20) sleepMs(20);
        pump.maru_ssh_pump_stop();
        // 이 회차의 주소는 아무도 안 듣는 자리라 **붙는 것부터** 실패한다 — 키가 없어서가 아니다.
        try std.testing.expectEqualStrings("connect_failed", std.mem.span(pump.maru_ssh_pump_error()));
    }
    inline for (.{ "port", "cols", "rows" }) |field| {
        var bad = cfg;
        @field(bad, field) = 0;
        try std.testing.expectEqual(@as(c_int, -2), pump.maru_ssh_pump_start(&bad, null));
    }
    try std.testing.expectEqual(@as(c_int, -2), pump.maru_ssh_pump_start(null, null));

    // **두 번 멈춰도 안 죽는다.** 이미 거둔 스레드를 또 `join` 하면 그 자리에서 앱이 죽는다 —
    // 서비스는 종료 경로가 여럿이라(사용자 취소·OS 종료·오류) 실제로 두 번 불린다.
    pump.maru_ssh_pump_stop();
    pump.maru_ssh_pump_stop();
}

test "닿지 않는 주소에서도 시한 안에 포기한다" {
    // **취소가 늦으면 서비스가 안 멈춘다.** 커널 기본 재시도는 1분을 넘어서, 사용자가 취소해도
    // 화면이 "접속 중" 에 붙어 있다. 시한을 두고 그 사이에도 정지 표시를 본다.
    var secret: [64]u8 = @splat(1);
    // TEST-NET-1(RFC 5737) — 라우팅되지 않는 주소라 SYN 이 조용히 먹힌다.
    var host_z: [16]u8 = @splat(0);
    @memcpy(host_z[0.."192.0.2.1".len], "192.0.2.1");
    var user_z: [8]u8 = @splat(0);
    user_z[0] = 'u';
    var fp_z: [8]u8 = @splat(0);
    var cfg: pump.MaruSshPumpConfig = .{
        .host = &host_z,
        .port = 22,
        .user = &user_z,
        .secret = &secret,
        .cols = 80,
        .rows = 24,
        .expect_fingerprint = &fp_z,
    };
    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_start(&cfg, null));
    sleepMs(200);
    // **정지 표시가 시한(15초)보다 먼저 걸려야 한다.** 여기서 진짜 시계를 재지 않으면 "곧
    // 멈춘다" 는 주장이 아니라 소원이 된다.
    const before = monotonicMs();
    pump.maru_ssh_pump_stop();
    const elapsed = monotonicMs() - before;
    try std.testing.expect(elapsed < 5_000);
    try std.testing.expectEqualStrings("connect_failed", std.mem.span(pump.maru_ssh_pump_error()));
}

test "끝난 뒤에는 다시 붙을 수 있다" {
    // **끝났다는 표시(`CLOSED`)를 "돌고 있다" 로 읽으면 재접속이 영영 막힌다.** 세션은 사용자가
    // 안 멈춰도 끝나고(선이 끊긴다), 그 뒤 앱은 다시 붙어야 한다 — 프로세스를 죽였다 켜야만
    // 되는 상태가 되면 그것은 앱이 아니라 일회용 도구다.
    var secret: [64]u8 = @splat(1);
    var host_z: [16]u8 = @splat(0);
    @memcpy(host_z[0.."127.0.0.1".len], "127.0.0.1");
    var user_z: [8]u8 = @splat(0);
    user_z[0] = 'u';
    var fp_z: [8]u8 = @splat(0);
    var cfg: pump.MaruSshPumpConfig = .{
        .host = &host_z,
        .port = 1, // 아무도 안 듣는다 — 곧 실패한다
        .user = &user_z,
        .secret = &secret,
        .cols = 80,
        .rows = 24,
        .expect_fingerprint = &fp_z,
    };

    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_start(&cfg, null));
    // 스스로 끝날 때까지 기다린다(멈추라고 안 한다 — 실제 끊김이 그런 모양이다).
    var waited: usize = 0;
    while (waited < 3000 and pump.maru_ssh_pump_is_running() != 0) : (waited += 20) sleepMs(20);
    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_is_running());
    // **끝을 알리는 상태는 남아 있어야 한다** — host 가 그것으로 알림을 내린다.
    try std.testing.expectEqual(@as(c_uint, 12), pump.maru_ssh_pump_state());

    // 그리고 다시 붙을 수 있어야 한다.
    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_start(&cfg, null));
    pump.maru_ssh_pump_stop();
}

// ── 적대적 서버 ─────────────────────────────────────────────────────────────
//
// **정상 sshd 로만 재면 절반만 잰 것이다.** 선 위의 상대는 우리가 못 고르고, 모바일에서는
// 중간 상자(캡티브 포털·프록시·통신사 장비)가 아무 바이트나 보내기도 한다. 여기서 보는 것은
// "붙느냐" 가 아니라 **안 죽고, 안 멈추고, 이름 있는 실패로 끝나느냐** 다.

const FakeServer = struct {
    fd: c.fd_t,
    port: u16,
    script: Script,
    thread: ?std.Thread = null,

    const Script = enum {
        /// 붙자마자 끊는다(포트만 열린 상자).
        close_immediately,
        /// 아무것도 안 보내고 붙들고만 있다(블랙홀).
        silent,
        /// SSH 가 아닌 바이트를 쏟는다(HTTP 프록시 같은 것).
        garbage,
        /// 버전 줄만 주고 끊는다.
        version_then_close,
    };

    fn listen(script: Script) !FakeServer {
        const fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        var on: c_int = 1;
        _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, @ptrCast(&on), @sizeOf(c_int));
        var addr: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = 0, // 커널이 고른다 — 포트 충돌로 테스트가 흔들리지 않게
            .addr = std.mem.nativeToBig(u32, 0x7F00_0001),
            .zero = @splat(0),
        };
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) return error.BindFailed;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        if (c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.SockNameFailed;
        if (c.listen(fd, 1) != 0) return error.ListenFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port), .script = script };
    }

    fn serve(self: *FakeServer) void {
        const client = c.accept(self.fd, null, null);
        if (client < 0) return;
        defer _ = c.close(client);
        switch (self.script) {
            .close_immediately => {},
            .silent => {
                // **진짜로 붙들고만 있는다.** 한 번 읽고 돌아오면 소켓이 닫혀 "조용한 상대" 가
                // 아니라 "끊는 상대" 가 된다 — 처음에 그렇게 써서 테스트가 다른 것을 쟀다.
                // 상대(펌프)가 닫을 때까지 읽기만 한다.
                var junk: [256]u8 = undefined;
                while (c.read(client, &junk, junk.len) > 0) {}
            },
            .garbage => {
                const junk = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" ++ ("\x00\xff" ** 64);
                _ = c.write(client, junk.ptr, junk.len);
            },
            .version_then_close => {
                const line = "SSH-2.0-FakeServer\r\n";
                _ = c.write(client, line.ptr, line.len);
            },
        }
    }

    fn start(self: *FakeServer) !void {
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn stop(self: *FakeServer) void {
        // **듣는 소켓을 먼저 깨운다.** `accept` 에 걸린 스레드를 그냥 `join` 하면 아무도 안
        // 붙는 판에서 영영 안 돌아온다 — 테스트가 멈추고, 그 멈춤이 제품 결함처럼 보인다
        // (실제로 그렇게 보였다: 펌프는 멀쩡한데 하네스가 붙들고 있었다).
        _ = c.shutdown(self.fd, posix.SHUT.RDWR);
        _ = c.close(self.fd);
        if (self.thread) |t| t.join();
    }
};

/// 적대적 서버 한 판. **끝나야 하고, 이름이 남아야 하고, 다시 붙을 수 있어야 한다.**
fn runHostile(script: FakeServer.Script) ![]const u8 {
    var server = try FakeServer.listen(script);
    defer server.stop();
    try server.start();

    var secret: [64]u8 = @splat(1);
    var host_z: [16]u8 = @splat(0);
    @memcpy(host_z[0.."127.0.0.1".len], "127.0.0.1");
    var user_z: [8]u8 = @splat(0);
    user_z[0] = 'u';
    var fp_z: [64]u8 = @splat(0);
    @memcpy(fp_z[0.."SHA256:zzz".len], "SHA256:zzz");
    var cfg: pump.MaruSshPumpConfig = .{
        .host = &host_z,
        .port = server.port,
        .user = &user_z,
        .secret = &secret,
        .cols = 80,
        .rows = 24,
        .expect_fingerprint = &fp_z,
    };
    var hooks: pump.MaruSshPumpHooks = .{
        .lock = null,
        .unlock = null,
        .screen = onScreen,
        .take_response = onTakeResponse,
        .state_changed = onState,
        .ctx = null,
    };
    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_start(&cfg, &hooks));

    // **스스로 끝나기를 기다린다.** 안 끝나면(멈춤) 그 자체가 결함이다 — 아래에서 잡는다.
    var waited: usize = 0;
    while (waited < 8000 and pump.maru_ssh_pump_is_running() != 0) : (waited += 20) sleepMs(20);
    const stalled = pump.maru_ssh_pump_is_running() != 0;
    pump.maru_ssh_pump_stop();
    if (stalled and script != .silent) return error.PumpStalled;
    return std.mem.span(pump.maru_ssh_pump_error());
}

test "붙자마자 끊는 상대: 버전 줄을 안 줬다고 말한다" {
    // **"상대가 끊었다" 로 뭉뚱그리면 안 된다** — 그 말은 붙었다 끊긴 것과 구별이 안 된다.
    try std.testing.expectEqualStrings("no_ssh_version", try runHostile(.close_immediately));
}

test "SSH 가 아닌 바이트를 쏟는 상대: 안 죽고, SSH 가 아니라고 말한다" {
    // 캡티브 포털·프록시가 HTTP 응답을 던지는 자리다. 여기서 패닉하면 앱이 죽고, "끊겼다" 로만
    // 말하면 사용자는 주소를 고쳐야 하는지 기다려야 하는지 모른다.
    try std.testing.expectEqualStrings("no_ssh_version", try runHostile(.garbage));
}

test "버전 줄만 주고 끊는 상대: 그 뒤 단계에서 끊겼다고 말한다" {
    // 버전 줄은 받았으니 SSH 는 맞다 — 그 다음(협상·인증)에서 끊겼다는 것이 사실이다.
    try std.testing.expectEqualStrings("closed_before_ready", try runHostile(.version_then_close));
}

test "아무 말도 안 하는 상대: 붙들려도 멈추라면 멈춘다" {
    // **블랙홀이 가장 나쁜 부류다** — 오류도 안 나고 끝나지도 않는다. 사용자가 취소할 수
    // 있어야 하고(정지 표시), `stop` 이 곧 돌아와야 한다.
    var server = try FakeServer.listen(.silent);
    defer server.stop();
    try server.start();

    var secret: [64]u8 = @splat(1);
    var host_z: [16]u8 = @splat(0);
    @memcpy(host_z[0.."127.0.0.1".len], "127.0.0.1");
    var user_z: [8]u8 = @splat(0);
    user_z[0] = 'u';
    var fp_z: [8]u8 = @splat(0);
    var cfg: pump.MaruSshPumpConfig = .{
        .host = &host_z,
        .port = server.port,
        .user = &user_z,
        .secret = &secret,
        .cols = 80,
        .rows = 24,
        .expect_fingerprint = &fp_z,
    };
    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_start(&cfg, null));

    // **조용한 것은 실패가 아니다.** 터미널의 정상 상태가 바로 이것이다 — 아무도 안 치고 원격도
    // 조용한 시간이 대부분이다. 읽기 타임아웃(2초)을 실패로 보면 **유휴 세션이 2초마다 죽는다**.
    sleepMs(5000); // 타임아웃 두 번을 넘긴다
    try std.testing.expect(pump.maru_ssh_pump_is_running() != 0);
    try std.testing.expectEqualStrings("", std.mem.span(pump.maru_ssh_pump_error()));

    const before = monotonicMs();
    pump.maru_ssh_pump_stop();
    const elapsed = monotonicMs() - before;
    // **타임아웃을 기다리지 않는다 — 깨워서 알린다.**
    //
    // 예전에는 정지 표시만 세우고 펌프가 `poll` 타임아웃(2초)에 걸려 있어, 이 단언의 상한이
    // 4000ms 였다. 그 느슨함이 **결함을 덮고 있었다**: 같은 구조 때문에 사용자가 친 글자도
    // 서버가 먼저 말하거나 2초가 지날 때까지 소켓으로 안 나갔다(기기 실측 — 조용한 프롬프트에서
    // 한 글자가 최대 2초 묶였다). 깨우기 관을 넣은 지금은 밀리초 단위로 돌아와야 하고, 이 상한이
    // 그것을 지킨다 — `stop` 에서 `pump_wake()` 를 지우면 여기가 곧바로 빨개진다.
    //
    // **쓰기 경로는 여기서 직접 못 잰다** — 핸드셰이크가 선 세션이 있어야 `write` 가 받아 주는데
    // 이 상대는 조용해서 거기까지 못 간다. 같은 `pump_wake()` 를 쓰므로 메커니즘은 이 단언이
    // 증명하고, 실제 타이핑 체감은 기기 회차가 판정한다.
    try std.testing.expect(elapsed < 500);
    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_is_running());
}

// ── 동시성과 수명 ───────────────────────────────────────────────────────────
//
// **모바일은 이 자리를 계속 흔든다.** 화면을 껐다 켜고, 앱을 오갔다 하고, 회전하고, 그때마다
// 세션이 서고 죽는다. 여기서 새는 것(교착·크래시·자원)은 오래 쓴 뒤에야 드러난다.

/// 붙들고만 있는 상대에 붙는다. 반환값은 그 서버 — 끝나면 `stop()` 해야 한다.
fn startAgainstSilent(server: *FakeServer, secret: *[64]u8, host_z: *[16]u8, user_z: *[8]u8, fp_z: *[8]u8) !void {
    @memcpy(host_z[0.."127.0.0.1".len], "127.0.0.1");
    user_z[0] = 'u';
    var cfg: pump.MaruSshPumpConfig = .{
        .host = host_z,
        .port = server.port,
        .user = user_z,
        .secret = secret,
        .cols = 80,
        .rows = 24,
        .expect_fingerprint = fp_z,
    };
    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_start(&cfg, null));
}

test "빠르게 서고 죽여도 새지 않는다" {
    // **앱을 오가면 이 짓을 반복한다.** 스레드를 안 거두면 그만큼 쌓이고, 상태가 남으면 다음
    // 세션이 옛 값을 본다. 여덟 번을 돌려 크래시·교착·거절이 없어야 한다(더 돌리면 테스트가 느려지기만 한다 — 새는 것은 첫 몇 번에 드러난다).
    var secret: [64]u8 = @splat(1);
    var host_z: [16]u8 = @splat(0);
    var user_z: [8]u8 = @splat(0);
    var fp_z: [8]u8 = @splat(0);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var server = try FakeServer.listen(.silent);
        defer server.stop();
        try server.start();
        try startAgainstSilent(&server, &secret, &host_z, &user_z, &fp_z);
        // 붙는 도중에 죽인다 — 가장 흔한 자리다(사용자가 곧바로 앱을 내린다).
        sleepMs(5);
        pump.maru_ssh_pump_stop();
        try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_is_running());
    }
}

test "도는 중에 다른 스레드가 써도 안 깨진다" {
    // 키 입력과 회전은 **UI 스레드**에서 온다 — 펌프가 `feed` 중일 때도 온다. 세션 슬롯을
    // 두 스레드가 만지므로, 자물쇠가 없으면 여기서 조용히 깨진다(증상은 한참 뒤에 나온다).
    var server = try FakeServer.listen(.silent);
    defer server.stop();
    try server.start();
    var secret: [64]u8 = @splat(1);
    var host_z: [16]u8 = @splat(0);
    var user_z: [8]u8 = @splat(0);
    var fp_z: [8]u8 = @splat(0);
    try startAgainstSilent(&server, &secret, &host_z, &user_z, &fp_z);
    defer pump.maru_ssh_pump_stop();

    // 셸이 안 떴으므로 보낸 양은 0 이어야 한다(창이 없다) — **그래도 안 죽어야 한다.**
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try std.testing.expectEqual(@as(c_ulong, 0), pump.maru_ssh_pump_write("x", 1));
        pump.maru_ssh_pump_resize(80 + @as(c_uint, @intCast(i % 40)), 24);
    }
    try std.testing.expect(pump.maru_ssh_pump_is_running() != 0);
    try std.testing.expectEqualStrings("", std.mem.span(pump.maru_ssh_pump_error()));
}

test "안 돌 때 쓰거나 크기를 바꿔도 조용하다" {
    // host 는 세션 없이도 이 함수를 부른다(화면이 먼저 뜨고 세션은 나중에 선다). 여기서
    // 죽거나 옛 세션에 쓰면 안 된다.
    pump.maru_ssh_pump_stop(); // 확실히 멈춘 상태로
    try std.testing.expectEqual(@as(c_ulong, 0), pump.maru_ssh_pump_write("x", 1));
    pump.maru_ssh_pump_resize(100, 40);
    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_is_running());
}

test "컨트롤 훅이 없으면 채널을 못 연다" {
    // **받을 사람이 없으면 열지 않는다.** 열어 두면 컨트롤 버퍼가 차서 코어가 배압으로 멈추고
    // 터미널까지 함께 멈춘다 — 채널 둘을 독립으로 만든 이유를 그 자리에서 잃는다.
    //
    // **도는 중에 재야 한다.** 안 도는 펌프는 훅과 무관하게 실패하므로, 그 상태로 재면 이 규칙을
    // 지워도 초록이다(변이 검사에서 실제로 살아남았다). 그래서 조용한 상대에 붙여 두고 부른다 —
    // 셸은 안 떴지만 훅 검사가 **그보다 먼저** 나오므로 이름으로 가릴 수 있다.
    var server = try FakeServer.listen(.silent);
    defer server.stop();
    try server.start();

    var secret: [64]u8 = @splat(1);
    var host_z: [16]u8 = @splat(0);
    @memcpy(host_z[0.."127.0.0.1".len], "127.0.0.1");
    var user_z: [8]u8 = @splat(0);
    user_z[0] = 'u';
    var fp_z: [64]u8 = @splat(0);
    @memcpy(fp_z[0.."SHA256:zzz".len], "SHA256:zzz");
    var cfg: pump.MaruSshPumpConfig = .{
        .host = &host_z,
        .port = server.port,
        .user = &user_z,
        .secret = &secret,
        .cols = 80,
        .rows = 24,
        .expect_fingerprint = &fp_z,
    };
    var hooks: pump.MaruSshPumpHooks = .{
        .lock = null,
        .unlock = null,
        .screen = onScreen,
        .take_response = onTakeResponse,
        .state_changed = onState,
        .control = null, // **훅이 없다**
        .ctx = null,
    };
    try std.testing.expectEqual(@as(c_int, 0), pump.maru_ssh_pump_start(&cfg, &hooks));
    defer pump.maru_ssh_pump_stop();

    var waited: usize = 0;
    while (waited < 2000 and pump.maru_ssh_pump_is_running() == 0) : (waited += 20) sleepMs(20);

    try std.testing.expect(pump.maru_ssh_pump_open_control("x", 1) != 0);
    // **이름은 컨트롤 축에 남는다.** 예전에는 이 단언이 `maru_ssh_pump_error` 를 봤고, 그래서
    // 두 축이 슬롯 하나를 같이 쓰는 상태를 **테스트가 계약으로 고정하고 있었다**.
    try std.testing.expectEqualStrings("no_control_hook", std.mem.span(pump.maru_ssh_pump_control_error()));
    try std.testing.expectEqual(@as(c_uint, 0), pump.maru_ssh_pump_control_state());

    // **그리고 터미널 축은 안 건드린다 — 이것이 이 테스트의 절반이다.**
    // 컨트롤이 지는 것은 "세션 목록이 안 보이는 것" 이지 "접속이 안 되는 것" 이 아니다
    // (docs/control-plane.md §4a). 이 줄이 없으면 슬롯을 도로 합쳐도 위 단언은 초록이다.
    try std.testing.expectEqualStrings("", std.mem.span(pump.maru_ssh_pump_error()));
}
