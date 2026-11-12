//! 탐침 고르기(`W9E2A_ONLY`·`W9E2B_ONLY` — 쉼표로 이름 여럿)의 판정 — 판정용이다(제품 코드 아님).
//!
//! 왜: 이름을 틀리게 주면 아무 탐침도 돌지 않고 「PASS 0·FAIL 0·종료 0」 으로 지나갔다(W9e② 적대 검증 20 회차 V-J1 — 고른 판정이 통과한 것처럼
//! 보인다). 그래서 고른 이름 가운데 목록에 없는 것이 있거나 하나도 돌지 않았으면 그 판을 실패로 남긴다(`report(false, …)` — 판정자 종료 1).
//! 판정자 빌드가 실패해 옛 판정자가 도는 일은 `mise run web-sidecar-judge-mode` 가 막는다(빌드가 실패하면 판정하지 않는다).

const std = @import("std");

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

/// 환경 `env` 가 없으면 모두, 있으면 그 목록의 이름만.
pub fn selected(env: [:0]const u8, name: []const u8) bool {
    const v = std.c.getenv(env) orelse return true;
    var it = std.mem.splitScalar(u8, std.mem.span(v), ',');
    while (it.next()) |n| if (std.mem.eql(u8, std.mem.trim(u8, n, " "), name)) return true;
    return false;
}

/// 고른 이름이 모두 목록에 있고 하나라도 돌았는가 — 아니면 실패를 남긴다.
pub fn verify(report: Report, env: [:0]const u8, label: []const u8, names: []const []const u8, ran: usize) void {
    var buf: [600]u8 = undefined;
    if (std.c.getenv(env)) |v| {
        var it = std.mem.splitScalar(u8, std.mem.span(v), ',');
        while (it.next()) |raw| {
            const n = std.mem.trim(u8, raw, " ");
            const known = for (names) |k| {
                if (std.mem.eql(u8, k, n)) break true;
            } else false;
            if (!known) report(false, label, std.fmt.bufPrint(&buf, "{s} 에 없는 탐침 이름 '{s}' — 틀린 이름은 아무것도 돌리지 않는다", .{ env, n }) catch "unknown probe name");
        }
    }
    if (ran == 0) report(false, label, std.fmt.bufPrint(&buf, "탐침을 하나도 돌리지 않았다({s} 를 보라)", .{env}) catch "no probe ran");
}

/// 그 판의 host 로그(`<root>/*.host.log` — `emulation_check.open` 이 탐침마다, `host.log_root` 를 정한 판은 이름 없는 host 마다 남긴다)에 DevTools
/// 관찰자 재진입 검사 실패(「Check failed: !check_reentrancy」)가 몇 줄인가 — 0 이어야 PASS(W9e② 적대 검증 15 회차 V-15: 관찰자 콜백 안에서 곧 낸
/// 명령이 그 줄을 냈고, 늦은 시작 답 안의 `Tracing.end` 는 sidecar 를 죽였다). 판 전체를 한 번에 본다. 로그가 하나도 없으면 FAIL(v20c L2 — 셀 것이
/// 없는데 0 줄이라 통과했다: 경로가 버퍼를 넘어 로그 없이 띄운 판이 늘 PASS 였다).
pub fn noReentrancy(report: Report, root: []const u8, label: []const u8) void {
    var cb: [1600]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&cb, "n=$(/bin/ls '{s}'/*.host.log 2>/dev/null | /usr/bin/wc -l); c=$(/bin/cat '{s}'/*.host.log 2>/dev/null | /usr/bin/grep -c 'check_reentrancy'); echo $n $c", .{ root, root }, 0) catch return report(false, label, "path too long");
    const fp = popen(cmd.ptr, "r") orelse return report(false, label, "could not read host logs");
    var buf: [64]u8 = undefined;
    const got = fread(&buf, 1, buf.len, fp);
    _ = pclose(fp);
    var it = std.mem.tokenizeAny(u8, buf[0..got], " \n\t");
    const logs = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return report(false, label, "could not count host logs");
    const n = std.fmt.parseInt(u64, it.next() orelse "", 10) catch return report(false, label, "could not count host log lines");
    var ob: [240]u8 = undefined;
    if (logs == 0) return report(false, label, "host 로그가 하나도 없다 — 셀 것이 없다(로그 없이 띄운 판)");
    report(n == 0, label, std.fmt.bufPrint(&ob, "host 로그 {d} 개의 「Check failed: !check_reentrancy」 {d} 줄(관찰자 콜백 안에서 곧 낸 DevTools 명령)", .{ logs, n }) catch "");
}

extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(fp: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, fp: *anyopaque) usize;
