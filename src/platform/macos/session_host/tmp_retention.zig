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
/// 매니페스트를 **어떻게** 찍을지. `?*Published` 하나로는 두 사실이 접힌다 — 「핸들이 없다」와
/// 「건드리면 안 된다」. 그 둘을 같은 `null` 로 두었다가, 승계 루프가 남이 쥔 매니페스트를 경로로
/// 찍어 그 publication 을 못 거두게 만들었다(2026-09-27 회귀).
///
/// **왜 경로 갱신이 위험한가.** `utimensat` 은 `ctime` 을 바꾸는데, `Published.FileIdentity` 는
/// `dev`·`ino` 와 **`ctime_ns`** 다. 그래서 경로로 한 번 찍으면 소유자의 identity 와 어긋나고,
/// `withdrawExact` 가 그것을 「다른 세대」로 읽어 **삭제를 거부한다**(`.replaced`). 설계대로다 —
/// 모르는 세대를 지우지 않는 것이 그 함수의 계약이다. 그 결과가 영영 안 지워지는 `host.v1.json` 이다.
pub const ManifestTouch = union(enum) {
    /// 핸들을 쥔 쪽. `touchExact` 가 찍은 **직후 identity 를 다시 읽어 갱신**하므로 안전하다.
    published: *host_manifest.Published,
    /// 아무도 안 쥐고 있을 때만 안전하다.
    by_path,
    /// **남이 쥐고 있을 수 있다.** 찍지 않는다 — 찍으면 그쪽의 `withdraw` 가 막힌다.
    skip,
};

pub fn touchAll(
    subject: Subject,
    manifest: ManifestTouch,
) void {
    // null times = 현재 시각으로 설정(POSIX). AT_SYMLINK_NOFOLLOW 를 주지 않아 경로를 그대로 따른다.
    _ = c.utimensat(c.AT.FDCWD, subject.socket_path.ptr, null, 0);
    _ = c.utimensat(c.AT.FDCWD, subject.session_dir.ptr, null, 0);
    _ = c.utimensat(c.AT.FDCWD, subject.owner_path.ptr, null, 0);
    switch (manifest) {
        .published => |published| _ = published.touchExact() catch {},
        .by_path => {
            var manifest_buf: [512]u8 = undefined;
            if (host_manifest.manifestPathIn(&manifest_buf, subject.session_dir, subject.host_id)) |path| {
                _ = c.utimensat(c.AT.FDCWD, path.ptr, null, 0);
            } else |_| {}
        },
        .skip => {},
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

test "매니페스트 경로 갱신은 ctime 을 바꿔 소유자의 withdraw 를 막는다 — .skip 은 안 바꾼다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    // 이 판정자는 **효과**를 잰다. 「`.skip` 갈래가 있다」가 아니라 「그 갈래를 타면 ctime 이 안 변한다」다.
    // 글자만 고정하면 `.skip` 이 `.by_path` 와 같은 일을 해도 통과한다.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var dir_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = try std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{dir});

    // `validateOwnerDir` 는 group/other 비트가 **하나도** 없어야 통과한다(0700). `testing.tmpDir` 은
    // umask 를 따라 0755 로 만들므로, 이걸 안 맞추면 아래가 전부 `SkipZigTest` 로 빠져 **조용히
    // 아무것도 안 재는 판정자**가 된다(실제로 처음 판이 그랬다).
    if (c.chmod(dir_z.ptr, 0o700) != 0) return error.TestUnexpectedResult;

    const host_id: u128 = 0xabcd;
    // **`catch SkipZigTest` 를 쓰지 않는다** — 환경 탓이 아니라 계약이 깨진 것이면 그대로 드러나야 한다.
    try host_manifest.prepareHostDirectory(dir_z, host_id);
    var manifest_buf: [640]u8 = undefined;
    const manifest = try host_manifest.manifestPathIn(&manifest_buf, dir_z, host_id);
    const fd = c.open(manifest.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.TestUnexpectedResult;
    _ = c.close(fd);

    var socket_buf: [640]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&socket_buf, "{s}/sock", .{dir});
    var lock_buf: [640]u8 = undefined;
    const lock_path = try std.fmt.bufPrintZ(&lock_buf, "{s}/owner.lock", .{dir});
    const subject: Subject = .{
        .session_dir = dir_z,
        .socket_path = socket_path,
        .owner_path = lock_path,
        .host_id = host_id,
    };

    // `.skip` 의 계약은 「매니페스트 **만** 건너뛴다」다. 그 「만」을 재지 않으면, `.skip` 이 갱신을
    // 통째로 건너뛰어도 통과한다 — 그러면 승계한 host 가 tmp 정리에 자기 자리를 잃는 원래 결함이
    // 조용히 되살아나고, **3 일이 지나야 드러난다**(적대적 검증 2회차 F1 이 초록으로 살아남았다).
    // 그래서 옆 항목 둘의 시각을 옛날로 돌려 두고, `.skip` 이 그것들은 **갱신하는지** 함께 잰다.
    const sock_fd = c.open(socket_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (sock_fd < 0) return error.TestUnexpectedResult;
    _ = c.close(sock_fd);
    const lock_fd = c.open(lock_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (lock_fd < 0) return error.TestUnexpectedResult;
    _ = c.close(lock_fd);
    const ancient: c.timespec = .{ .sec = 1, .nsec = 0 };
    const past: [2]c.timespec = .{ ancient, ancient };
    if (c.utimensat(c.AT.FDCWD, socket_path.ptr, &past, 0) != 0) return error.TestUnexpectedResult;
    if (c.utimensat(c.AT.FDCWD, lock_path.ptr, &past, 0) != 0) return error.TestUnexpectedResult;
    const sock_before = mtimeNs(socket_path) orelse return error.TestUnexpectedResult;
    const lock_before = mtimeNs(lock_path) orelse return error.TestUnexpectedResult;

    const before = ctimeNs(manifest) orelse return error.TestUnexpectedResult;
    touchAll(subject, .skip);
    const after_skip = ctimeNs(manifest) orelse return error.TestUnexpectedResult;
    // `.skip` 은 매니페스트에 손대지 않는다 — 소유자의 identity 가 살아 있어야 withdraw 가 돈다.
    try testing.expectEqual(before, after_skip);
    // 그러나 **나머지는 찍는다.** 이 둘이 없으면 위 단언은 「아무것도 안 한다」로도 만족된다.
    try testing.expect((mtimeNs(socket_path) orelse return error.TestUnexpectedResult) > sock_before);
    try testing.expect((mtimeNs(lock_path) orelse return error.TestUnexpectedResult) > lock_before);

    touchAll(subject, .by_path);
    const after_path = ctimeNs(manifest) orelse return error.TestUnexpectedResult;
    // 대비: 경로 갱신은 **실제로** ctime 을 바꾼다. 이 줄이 없으면 위 단언이 「갱신이 원래 안 된다」로도 통과한다.
    try testing.expect(after_path != before);
}

fn ctimeNs(path: [:0]const u8) ?i128 {
    var stat: std.c.Stat = undefined;
    if (c.fstatat(c.AT.FDCWD, path.ptr, &stat, c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return @as(i128, stat.ctime().sec) * std.time.ns_per_s + stat.ctime().nsec;
}

fn mtimeNs(path: [:0]const u8) ?i128 {
    var stat: std.c.Stat = undefined;
    if (c.fstatat(c.AT.FDCWD, path.ptr, &stat, c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return @as(i128, stat.mtime().sec) * std.time.ns_per_s + stat.mtime().nsec;
}
