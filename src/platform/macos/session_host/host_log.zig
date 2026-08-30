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

/// 진단 한 줄을 host 로그(fd 2)에 남긴다. 실패해도 조용히 넘어간다 — 진단이 제품 경로를 바꾸지 않는다.
pub fn line(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(2, text.ptr, text.len);
}

test "host log formats within the fixed buffer and stays test-silent" {
    // 테스트에서는 아무것도 쓰지 않는다(빌드 러너의 stderr 를 오염시키지 않기 위해).
    line("session host started: pid={d} diagnostics=v1", .{@as(i32, 12345)});
    // 버퍼를 넘기는 인자도 프로세스를 죽이지 않고 조용히 버려진다.
    line("{s}", .{"x" ** 512});
}
