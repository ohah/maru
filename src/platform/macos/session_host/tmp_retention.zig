//! `/tmp` 정리에 맞서 **우리 레지스트리 파일의 시각을 젊게 유지한다** — 갱신 목록의 단일 출처.
//!
//! macOS 는 `/tmp` 를 주기적으로 거둔다. 살아 있는 동안 시각을 갱신하지 않으면 3 일 넘게 조용한 host 가
//! 자기 파일을 잃고, **프로세스는 멀쩡한데 아무도 찾지 못하는** 상태가 된다.
//!
//! **왜 모듈로 뺐나.** 이 목록이 두 곳에 살았기 때문에 사고가 났다. 첫 실행 경로(`daemon`)만 갱신을 했고
//! **exec 로 승계한 뒤의 경로(`restore_activation.serveLoop`)는 아무것도 갱신하지 않았다.** 그래서 한 번이라도
//! 업그레이드한 host 는 그 시점부터 보호를 통째로 잃었다. 2026-09-27 실측: `upgrade_epoch=3` 인 8 일 된 host 의
//! 디렉터리에 `host.v1.json` 하나만 남고 `owner.lock` 은 사라져 있었고, 그 host 는 승계 대상에서 영구히 빠져
//! 옛 빌드에 고정됐다.
//!
//! 목록에 **`owner.lock` 이 빠져 있던 것**도 같은 사고의 절반이다. 락은 fd 가 쥐므로 이름이 사라져도 host 는
//! 멀쩡히 돌지만, 바깥에서 `owner_lease.observe` 는 「주인 없음」으로 읽는다.

const std = @import("std");
const c = std.c;
const host_manifest = @import("host_manifest.zig");
const short_endpoint = @import("short_endpoint.zig");

/// 갱신 주기. tmp 정리의 3 일 한계보다 충분히 짧아야 한다.
pub const touch_interval_ms: u64 = 60 * 60 * 1000;

/// `owner.lock` **이름** 감사 주기. 갱신보다 촘촘하다 — 이름이 사라진 채로 승계가 걸리면 후계자가 arm
/// 단계에서 죽으므로(`owner_lease.validateInheritedExact`), 그 창을 짧게 잡는 값이 싸다(2 syscall).
pub const audit_interval_ms: u64 = 60 * 1000;

/// 한 host 가 젊게 유지해야 하는 자리들.
pub const Subject = struct {
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    owner_path: [:0]const u8,
    host_id: u128,
};

pub fn awakeMs(io: std.Io) u64 {
    const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (now_ns <= 0) 0 else @intCast(@divFloor(now_ns, std.time.ns_per_ms));
}

pub fn shouldTouch(now_ms: u64, last_touch_ms: ?u64) bool {
    const last = last_touch_ms orelse return true;
    return now_ms -| last >= touch_interval_ms;
}

/// 우리가 **실제로 쓰는** 자리를 찍는다. uid 로 다시 계산하면 격리된 실행에서 남의 자리를 건드리면서
/// 정작 자기 endpoint 는 안 찍어, 살아 있는 host 가 tmp 정리에 지워지는 원래 실패로 되돌아간다.
pub fn touchAll(
    subject: Subject,
    published_manifest: ?*host_manifest.Published,
) void {
    // null times = 현재 시각으로 설정(POSIX). AT_SYMLINK_NOFOLLOW 를 주지 않아 경로를 그대로 따른다.
    _ = c.utimensat(c.AT.FDCWD, subject.socket_path.ptr, null, 0);
    _ = c.utimensat(c.AT.FDCWD, subject.session_dir.ptr, null, 0);
    _ = c.utimensat(c.AT.FDCWD, subject.owner_path.ptr, null, 0);
    if (published_manifest) |published| {
        _ = published.touchExact() catch {};
    } else {
        var manifest_buf: [512]u8 = undefined;
        if (host_manifest.manifestPathIn(&manifest_buf, subject.session_dir, subject.host_id)) |path| {
            _ = c.utimensat(c.AT.FDCWD, path.ptr, null, 0);
        } else |_| {}
    }
    // 소켓과 manifest 의 부모(`/tmp/maru-<uid>`, `.../sh`)도 함께 찍는다. 자식이 남아 있으면 `-empty` 조건에
    // 걸리지 않지만, 자식이 먼저 지워진 뒤 빈 디렉터리로 남는 창을 없앤다.
    var root_buf: [256]u8 = undefined;
    if (short_endpoint.currentUserRootPathIn(&root_buf)) |root| {
        _ = c.utimensat(c.AT.FDCWD, root.ptr, null, 0);
    } else |_| {}
    var sock_dir_buf: [272]u8 = undefined;
    if (short_endpoint.currentSocketDirPathIn(&sock_dir_buf)) |sock_dir| {
        _ = c.utimensat(c.AT.FDCWD, sock_dir.ptr, null, 0);
    } else |_| {}
}
