//! 브라우저 프로필 디렉터리(W1c, docs/plans/web-osr-backend.md C7·D6·D7).
//!
//! 쿠키를 푸는 키가 공개값인 자리라(D7 — mock keychain) 소유자만 읽게 0700 으로 만들고, Time Machine 백업에서
//! 뺀다 — 백업에 풀 수 있는 로그인 쿠키가 실리지 않게.

const std = @import("std");

pub const Error = error{ MkdirFailed, NotPrivate };

extern "c" fn setxattr(path: [*:0]const u8, name: [*:0]const u8, value: *const anyopaque, size: usize, position: u32, options: c_int) c_int;

/// Time Machine 이 백업에서 빼는 표시. 값은 문자열 `com.apple.backupd` 의 binary plist 로, `tmutil addexclusion` 이
/// 다는 값과 바이트 단위로 같다(실측 — 이 값을 단 디렉터리를 `tmutil isexcluded` 가 `[Excluded]` 로 본다).
const backup_exclude_name = "com.apple.metadata:com_apple_backup_excludeItem";
const backup_exclude_value = "bplist00_\x10\x11com.apple.backupd\x08" ++ "\x00" ** 6 ++ "\x01\x01" ++ "\x00" ** 7 ++ "\x01" ++ "\x00" ** 15 ++ "\x1c";

/// 없으면 0700 으로 만들고, 있으면 권한이 소유자 전용인지 본다(남이 읽을 수 있는 자리는 쓰지 않는다).
pub fn ensurePrivateDir(path: [:0]const u8) Error!void {
    if (std.c.mkdir(path, 0o700) == 0) return;
    if (std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return error.MkdirFailed;
    // Zig 0.16 의 `std.c.stat` 은 macOS arm64 에서 없는 선언을 가리킨다 — 열어서 `fstat` 으로 본다.
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    if (fd < 0) return error.MkdirFailed;
    defer _ = std.c.close(fd);
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return error.MkdirFailed;
    if (st.mode & 0o077 != 0) return error.NotPrivate;
}

/// 백업 제외 표시를 단다. 실패해도 브라우저는 돈다 — 호출자가 알리기만 한다.
///
/// `NSURLIsExcludedFromBackupKey`(CoreFoundation)는 쓰지 않는다 — 그 경로는 Spotlight 큐에 비동기 작업을 남기고, 그
/// 작업이 CEF 가 올라오는 도중에 돌아 host 가 CHECK 로 죽었다(실측 — 크래시 보고의 스레드
/// `CSBackupSetItemExcluded() Spotlight Queue`, 실행 뒤 18~26ms). 같은 표시를 `setxattr` 한 번으로 동기적으로 단다.
pub fn excludeFromBackup(path: [:0]const u8) bool {
    return setxattr(path, backup_exclude_name, backup_exclude_value.ptr, backup_exclude_value.len, 0, 0) == 0;
}

comptime {
    std.debug.assert(backup_exclude_value.len == 61);
}
