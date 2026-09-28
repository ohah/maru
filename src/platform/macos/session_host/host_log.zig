//! host 프로세스 전용 진단 출력 — **`std.log` 를 쓰지 않는다.**
//!
//! host 는 detached spawn 이라 이 프로세스에는 `environ` 이 준비돼 있지 않다. 그런데 Zig 의
//! `std.log` 기본 구현은 stderr 를 잠그면서 환경을 훑고(`Io.Threaded.scanEnviron`), 거기서 null 을
//! 역참조해 **SIGSEGV 로 프로세스를 죽인다**. 로그를 남기려는 호출이 로그를 남길 대상을 죽이는 셈이다.
//!
//! 2026-08-30~31 실측으로 세 번 확인했다. 전부 같은 스택이다 —
//! `log.defaultLog → debug.lockStderr → Io.Threaded.scanEnviron → EXC_BAD_ACCESS at 0x0`:
//!
//! - `daemon.logHostStartup` (`std.log.info`) — host 가 뜨자마자 죽어 `launch_failed` 로 보였다.
//! - `upgrade_product_coordinator.noteUpgradeStage` (`std.log.warn`) — exec 업그레이드 중 죽어
//!   앱에는 handshake 가 끊긴 것으로 보였다.
//! - `upgrade_product_coordinator.logUpgradeRollback` (`std.log.err`, 2026-08-27 추가) — 같은 함정.
//!   그 함수의 주석은 「이 파일에는 `std.log` 가 한 줄도 없어서 `host-<id>.log` 가 전부 0 바이트였다」고
//!   적으며 진단을 넣었는데, **넣은 진단이 host 를 죽여 로그는 여전히 0 바이트였다.**
//!
//! 즉 「host 로그가 비어 있다」는 관측은 「진단이 없다」가 아니라 **「진단이 host 를 죽였다」** 였을 수
//! 있다. 그래서 이 모듈 하나로 통일한다. `redirectStderrToHostLog` 가 fd 2 를 로그 파일로 돌려 두므로
//! `write(2, …)` 한 번이면 파일에 그대로 남고, allocator·환경·lock 을 건드리지 않아 어느 시점에서도
//! 안전하다(`process_seal_service.fatalIntegrity` 가 같은 이유로 같은 방식을 쓴다).

const std = @import("std");
const builtin = @import("builtin");

/// 한 줄(개행 포함)의 상한. 넘치면 `line` 은 그 줄을 **통째로** 버린다 — 길이가 가변인 진단은
/// 이 값을 보고 스스로 줄여야 한다(`collect_failure.line_capacity`).
pub const max_line_bytes = 256;

/// 진단 한 줄을 host 로그(fd 2)에 남긴다. 실패해도 조용히 넘어간다 — 진단이 제품 경로를 바꾸지 않는다.
///
/// **본문 네 문장은 `collect_failure_site_boundary` 가 그대로 잰다.** 길이 상한에 기대는 진단
/// (`collect_failure.render`)이 `formatLine` 으로 그 상한을 재므로, 여기서 접두어를 붙이거나 조기 반환을
/// 더하면 그 측정이 제품과 갈린다 — 바꾸려면 그쪽 상한도 함께 본다.
pub fn line(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    var buf: [max_line_bytes]u8 = undefined;
    const text = formatLine(&buf, fmt, args) orelse return;
    _ = std.c.write(2, text.ptr, text.len);
}

/// `line` 이 실제로 쓰는 바이트. 순수 함수로 떼어 둔 이유는 하나다 — `line` 은 테스트에서 아무것도 안
/// 하므로, **길이 상한에 기대는 진단**(`collect_failure.render`)이 그 상한을 실제 모양으로 잴 길이
/// 이것뿐이다. 넘치면 `null` — 잘라 쓰지 않고 줄을 통째로 버린다.
pub fn formatLine(buf: *[max_line_bytes]u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.fmt.bufPrint(buf, fmt ++ "\n", args) catch null;
}

test "host log formats within the fixed buffer and stays test-silent" {
    // 테스트에서는 아무것도 쓰지 않는다(빌드 러너의 stderr 를 오염시키지 않기 위해).
    line("session host started: pid={d} diagnostics=v1", .{@as(i32, 12345)});
    // 버퍼를 넘기는 인자도 프로세스를 죽이지 않고 조용히 버려진다.
    line("{s}", .{"x" ** 512});
}

test "한 줄은 개행까지 max_line_bytes 안에 들어야 하고, 넘치면 통째로 버려진다" {
    var buf: [max_line_bytes]u8 = undefined;
    const fits = "x" ** (max_line_bytes - 1);
    const written = formatLine(&buf, "{s}", .{fits}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, max_line_bytes), written.len);
    try std.testing.expect(std.mem.endsWith(u8, written, "x\n"));
    try std.testing.expect(formatLine(&buf, "{s}", .{fits ++ "x"}) == null);
}
