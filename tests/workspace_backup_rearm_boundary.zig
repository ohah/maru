//! 복원이 **완전히 성공한** 실행이 `.bak` 을 해제해 백업 불변식을 다시 무장하는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 복원이 실패한 실행의 종료 저장은 「덮어쓰기 직전에 마지막 완전본을 `workspace.v1.bak` 으로 한 번
//! 남긴다」였다. 그 「한 번」은 `ensureBackup` 의 `O_EXCL` 이고, **의도된 설계**다 — 연속된 불완전
//! 실행이 「가장 완전한 첫 사본」을 밀어내지 않게 한다.
//!
//! **빠져 있던 것은 그 불변식을 다시 무장하는 단계다.** 복원이 성공하면 `workspace.v1` 자체가 신뢰할
//! 수 있으므로 옛 `.bak` 은 더 이상 「마지막 완전본」이 아니다. 그런데 그것을 지우는 경로가 없어 첫
//! 사본이 영구히 눌러앉았다.
//!
//! 2026-09-13 실측: `.bak` 이 **7 월 25 일 4614 B** 에서 7 주째 멈춰 있었다. 그 상태에서 복원이 실패한
//! 종료 저장이 원본을 **7421 B → 341 B** 로 덮었고 **되돌릴 사본이 없었다.** 하루에 다섯 번.
//!
//! ## 이 판정자가 재는 것
//!
//! 해제가 **복원 성공 쪽에만** 걸리는지, 그리고 `ensureBackup` 과 **같은 안전 계약**(현재 UID 의
//! regular file, `NOFOLLOW`)으로 지우는지를 잰다. 남의 것이나 symlink 를 지우는 편이 낡은 `.bak` 을
//! 남기는 것보다 훨씬 나쁘다.

const std = @import("std");

const file_path = "src/platform/macos/workspace_checkpoint_file.zig";
const host_path = "src/platform/macos/MaruAppHost.swift";
const abi_path = "src/platform/macos/app_host_abi.zig";
const max_source_bytes = 16 * 1024 * 1024;

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_source_bytes));
}

test "복원이 성공하면 .bak 을 해제한다 — 안전 계약을 지키면서" {
    const a = std.testing.allocator;
    const impl = try read(a, file_path);
    defer a.free(impl);
    const host = try read(a, host_path);
    defer a.free(host);
    const abi = try read(a, abi_path);
    defer a.free(abi);

    // ① 해제 구현이 있다.
    const fn_at = std.mem.indexOf(u8, impl, "pub fn releaseBackup(") orelse {
        std.debug.print("`.bak` 해제 경로가 없다 — 첫 사본이 영구히 눌러앉는다\n", .{});
        return error.NoBackupRelease;
    };
    const fn_end = std.mem.indexOfPos(u8, impl, fn_at, "\nfn ") orelse impl.len;
    const body = impl[fn_at..fn_end];

    // ② **`ensureBackup` 과 같은 안전 계약.** symlink·남의 파일을 지우면 낡은 `.bak` 보다 나쁘다.
    if (std.mem.indexOf(u8, body, "NOFOLLOW = true") == null) {
        std.debug.print("해제가 symlink 를 따라갈 수 있다 — ensureBackup 과 같은 계약이어야 한다\n", .{});
        return error.ReleaseFollowsSymlink;
    }
    if (std.mem.indexOf(u8, body, "getuid()") == null or std.mem.indexOf(u8, body, "ISREG") == null) {
        std.debug.print("해제가 소유자·regular 여부를 확인하지 않는다\n", .{});
        return error.ReleaseSkipsOwnerCheck;
    }

    // ③ **없으면 성공이다.** 지울 것이 없다는 것이 곧 무장된 상태다 — 실패로 다루면 매 복원이 경고를 낸다.
    if (std.mem.indexOf(u8, body, "NOENT") == null) {
        std.debug.print("`.bak` 이 없을 때를 실패로 다룬다 — 그것이 정상 상태다\n", .{});
        return error.MissingBackupTreatedAsFailure;
    }

    // ④ ABI 로 노출된다(Swift 가 부른다).
    try std.testing.expect(
        std.mem.indexOf(u8, abi, "maru_macos_workspace_checkpoint_release_backup") != null,
    );

    // ⑤ **복원이 «성공» 한 쪽에서만 부른다.** 실패 쪽에서 부르면 지켜야 할 사본을 지운다.
    const call_at = std.mem.indexOf(u8, host, "maru_macos_workspace_checkpoint_release_backup(") orelse {
        std.debug.print("Swift 가 해제를 부르지 않는다 — 구현만 있고 배선이 없다\n", .{});
        return error.ReleaseNeverCalled;
    };
    const guard_at = std.mem.lastIndexOf(u8, host[0..call_at], "if !workspaceRestoreIncomplete") orelse {
        std.debug.print("해제가 «복원 성공» 가드 아래 있지 않다 — 실패한 실행이 사본을 지울 수 있다\n", .{});
        return error.ReleaseNotGuardedBySuccess;
    };
    // 가드와 호출 사이에 그 블록을 닫는 줄이 없어야 한다(같은 블록 안이어야 한다).
    if (std.mem.indexOf(u8, host[guard_at..call_at], "\n        }\n") != null) {
        std.debug.print("해제 호출이 성공 가드 블록 «밖» 이다\n", .{});
        return error.ReleaseOutsideGuard;
    }

    // ⑥ **「복원할 것이 실제로 있었다」를 지난 뒤에만 해제한다.**
    //    `restoreWorkspace` 는 파일 없음·파싱 실패(`count < 0`)·빈 workspace(`count == 0`)에서 **조기
    //    반환**한다. 그 앞에서 해제하면 **저장 파일이 깨졌는데 유일한 사본을 지우는** 일이 된다.
    //    지금은 호출 위치 덕에 안전하지만, 누가 위로 옮기면 조용히 깨진다.
    const count_guard = std.mem.indexOf(u8, host, "guard count > 0 else { return true }") orelse
        return error.CountGuardMissing;
    if (call_at < count_guard) {
        std.debug.print("`.bak` 해제가 «복원할 것이 있는가» 판정보다 앞이다 — 깨진 파일에서 유일한 사본을 지운다\n", .{});
        return error.ReleaseBeforeCountGuard;
    }

    // ⑦ **`ensureBackup` 을 지운 게 아니다.** 보존 경로는 그대로 있어야 한다 — 해제는 그 짝이지 대체가 아니다.
    //    `EXCL` 은 그 함수 **본문 안**에서 찾는다. 파일 전체에서 찾으면 다른 자리가 대신 만족시켜
    //    보존이 사라져도 초록이다(적대적 검증 M6 가 그렇게 살아남았다).
    const ensure_at = std.mem.indexOf(u8, impl, "fn ensureBackup(") orelse {
        std.debug.print("보존 경로(`ensureBackup`)가 사라졌다 — 해제는 그 짝이지 대체가 아니다\n", .{});
        return error.EnsureBackupRemoved;
    };
    const ensure_end = std.mem.indexOfPos(u8, impl, ensure_at, "\nfn ") orelse impl.len;
    const ensure_body = impl[ensure_at..ensure_end];
    if (std.mem.indexOf(u8, ensure_body, "EXCL = true") == null) {
        std.debug.print("보존이 create-once 가 아니다 — 연속 실패가 첫 사본을 밀어낸다\n", .{});
        return error.BackupNotCreateOnce;
    }
}
