//! **두 host 가 쓸 C 펌프의 실서버 스모크**(계획 S9-3). `src/platform/mobile_host/ssh_pump.c` 를
//! 그대로 링크해 진짜 sshd 와 왕복한다 — 기기에 올리기 **전에** 그 코드가 도는 것을 본다.
//!
//! **이 스모크가 기기 검증을 대신하지는 않는다.** 여기서 확인되는 것은 소켓·스레드·세션 루프와
//! 호스트키 핀 고정이고, 화면에 실제로 그려지는지·포그라운드 서비스가 사는지는 기기에서 본다.
//! 다만 그때 실패하면 **남는 후보가 host 배선뿐**이 된다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
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

/// host 가 하는 일 — 화면에 넣는다. 여기서는 세고 앞부분만 보관한다.
fn onScreen(_: ?*anyopaque, bytes: [*c]const u8, len: c_ulong) callconv(.c) void {
    const n = @min(@as(usize, @intCast(len)), screen_head.len - screen_head_len);
    if (n > 0) {
        @memcpy(screen_head[screen_head_len..][0..n], bytes[0..n]);
        screen_head_len += n;
    }
    screen_total += @intCast(len);
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

pub fn main(init: std.process.Init.Minimal) !void {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    const port_str = it.next() orelse return fail("포트를 인자로 준다");
    const user = it.next() orelse return fail("사용자 이름을 인자로 준다");
    const key_path = it.next() orelse return fail("개인키 경로를 인자로 준다");
    const fingerprint = it.next() orelse return fail("기대 지문을 인자로 준다");
    const marker = it.next() orelse return fail("화면에서 찾을 문자열을 인자로 준다");
    const port = try std.fmt.parseInt(u16, port_str, 10);

    // **키는 ABI 가 푼다** — host 는 파일만 읽는다(기기에서도 같다).
    var secret: [64]u8 = undefined;
    const pem = try readAll(key_path, &file_buf);
    if (abi.maru_mobile_ssh_load_key(pem.ptr, @intCast(pem.len), "", 0, &secret) != abi.ok) {
        say("키를 못 읽었다: {s}", .{std.mem.span(abi.maru_mobile_ssh_last_load_error())});
        return fail("키 읽기 실패");
    }
    defer std.crypto.secureZero(u8, &secret);

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
        .ctx = null,
    };

    if (pump.maru_ssh_pump_start(&cfg, &hooks) != 0) {
        say("시작 실패: {s}", .{std.mem.span(pump.maru_ssh_pump_error())});
        return fail("펌프를 못 띄웠다");
    }

    // **끝날 때까지 기다린다.** `ForceCommand` 가 한 줄 찍고 나가므로 세션이 스스로 닫힌다.
    var waited_ms: usize = 0;
    while (waited_ms < 30_000) : (waited_ms += 50) {
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
    inline for (.{ "host", "user", "secret" }) |field| {
        var bad = cfg;
        @field(bad, field) = null;
        try std.testing.expectEqual(@as(c_int, -2), pump.maru_ssh_pump_start(&bad, null));
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
