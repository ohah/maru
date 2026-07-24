//! Session-host 제품 프로세스로 진입하는 hidden CLI command의 OS-중립 단일 출처.
//!
//! launcher와 `main.zig` dispatch가 같은 값을 import해야 `maru <socket>`처럼 command가 빠지거나 양쪽 문자열이
//! 서로 달라지는 회귀를 만들지 않는다.

const std = @import("std");
const c = std.c;

pub const subcommand = "__session-host";
pub const upgrade_preflight_flag = "--upgrade-preflight";
pub const upgrade_restore_flag = "--upgrade-restore";
pub const target_role = "target";
pub const rollback_role = "rollback";
pub const preflight_fd_arg = "3";
pub const preflight_fd: c.fd_t = std.fmt.parseInt(c.fd_t, preflight_fd_arg, 10) catch
    @compileError("session-host preflight fd literal must stay a valid descriptor");
