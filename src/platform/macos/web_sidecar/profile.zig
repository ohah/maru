//! 브라우저 프로필 디렉터리(W1c, docs/plans/web-osr-backend.md C7·D6·D7).
//!
//! 쿠키를 푸는 키가 공개값인 자리라(D7 — mock keychain) 소유자만 읽게 0700 으로 만들고, Time Machine 백업에서
//! 뺀다 — 백업에 풀 수 있는 로그인 쿠키가 실리지 않게.

const std = @import("std");

pub const Error = error{ MkdirFailed, NotPrivate };

/// 그 폴더 안의 파일(폴더가 아닌 것)을 지운다 — 들어가지 않는다. W10b: 결정 전 다운로드를 받아 둔 곳(`download-staging`)에 지난번
/// sidecar 가 남긴 것을 프로필을 잡은 뒤 비운다(죽거나 끝날 때 남은 Chromium 의 중간 파일 — 적대 리뷰 1 회차). 지운 수.
pub fn clearFiles(path: [:0]const u8) usize {
    // 순회하며 지우면 항목을 건너뛸 수 있다(APFS·HFS+) — 지운 것이 있으면 몇 번 더 돈다(9 회차).
    var total: usize = 0;
    var pass: u8 = 0;
    while (pass < 4) : (pass += 1) {
        const removed = clearFilesOnce(path);
        total += removed;
        if (removed == 0) break;
    }
    return total;
}

fn clearFilesOnce(path: [:0]const u8) usize {
    // 표준 라이브러리의 것을 쓴다 — x86_64 macOS 의 맨 `readdir` 는 옛 32 비트 inode 배치라 `readdir$INODE64` 여야 한다(적대 리뷰 2 회차).
    const dir = std.c.opendir(path) orelse return 0;
    defer _ = std.c.closedir(dir);
    var removed: usize = 0;
    while (std.c.readdir(dir)) |entry| {
        const name = entry.name[0..@min(entry.namlen, entry.name.len)];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (entry.type == 4) continue; // DT_DIR
        var buf: [2048]u8 = undefined;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ path, name }) catch continue;
        if (std.c.unlink(full) == 0) removed += 1;
    }
    return removed;
}

extern "c" fn setxattr(path: [*:0]const u8, name: [*:0]const u8, value: *const anyopaque, size: usize, position: u32, options: c_int) c_int;

/// Time Machine 이 백업에서 빼는 표시. 값은 문자열 `com.apple.backupd` 의 binary plist 로, `tmutil addexclusion` 이
/// 다는 값과 바이트 단위로 같다(실측 — 이 값을 단 디렉터리를 `tmutil isexcluded` 가 `[Excluded]` 로 본다).
const backup_exclude_name = "com.apple.metadata:com_apple_backup_excludeItem";
const backup_exclude_value = "bplist00_\x10\x11com.apple.backupd\x08" ++ "\x00" ** 6 ++ "\x01\x01" ++ "\x00" ** 7 ++ "\x01" ++ "\x00" ** 15 ++ "\x1c";

/// 없으면 0700 으로 만들고, 있든 없든 **남이 못 읽는 자리인지** 본다 — 마지막 경로 요소가 심볼릭 링크가 아니고,
/// 소유자가 나이며, 권한이 소유자 전용이고, ACL 에 허용 항목이 없어야 한다(0700 이어도 ACL 이 남에게 읽기를 줄 수 있다).
/// 방금 만든 디렉터리도 본다 — 만들고 여는 사이에 남이 바꿔 둘 수 있다.
pub fn ensurePrivateDir(path: [:0]const u8) Error!void {
    if (std.c.mkdir(path, 0o700) != 0 and std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return error.MkdirFailed;
    // Zig 0.16 의 `std.c.stat` 은 macOS arm64 에서 없는 선언을 가리킨다 — 열어서 `fstat` 으로 본다. NOFOLLOW 라 링크면
    // 열기가 실패한다.
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true });
    if (fd < 0) return if (std.c._errno().* == @intFromEnum(std.c.E.LOOP)) error.NotPrivate else error.MkdirFailed;
    defer _ = std.c.close(fd);
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return error.MkdirFailed;
    if (st.uid != std.c.geteuid()) return error.NotPrivate;
    if (st.mode & 0o077 != 0) return error.NotPrivate;
    if (grantsByAcl(fd)) return error.NotPrivate;
}

const acl_type_extended: c_int = 0x100;
const acl_first_entry: c_int = 0;
const acl_next_entry: c_int = -1;
const acl_extended_allow: c_int = 1;
extern "c" fn acl_get_fd_np(fd: c_int, kind: c_int) ?*anyopaque;
extern "c" fn acl_get_entry(acl: *anyopaque, entry_id: c_int, entry: *?*anyopaque) c_int;
extern "c" fn acl_get_tag_type(entry: *anyopaque, tag: *c_int) c_int;
extern "c" fn acl_free(obj: *anyopaque) c_int;

/// ACL 에 허용 항목이 하나라도 있는가. 거부 항목(홈의 `everyone deny delete` 같은)은 읽기를 넓히지 않아 괜찮다.
/// ACL 을 못 읽으면(없으면 ENOENT) 허용이 없는 것이다.
fn grantsByAcl(fd: c_int) bool {
    const acl = acl_get_fd_np(fd, acl_type_extended) orelse return false;
    defer _ = acl_free(acl);
    var entry: ?*anyopaque = null;
    var which = acl_first_entry;
    while (acl_get_entry(acl, which, &entry) == 0) : (which = acl_next_entry) {
        var tag: c_int = 0;
        if (acl_get_tag_type(entry.?, &tag) == 0 and tag == acl_extended_allow) return true;
    }
    return false;
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
