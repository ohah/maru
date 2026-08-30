//! Host별 짧은 Unix socket namespace.
//!
//! Cache path 길이와 무관하게 macOS `sun_path` 상한을 만족하고, host ID가 routing identity에 포함되게 한다.
//! `/tmp` 자체의 플랫폼 symlink는 계약 밖이며, 우리가 소유하는 per-UID directory와 `sh` leaf만 no-follow,
//! same-UID, exact 0700으로 검증한다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
// namespace 검증도 Linux에서는 `statx`, macOS에서는 libc stat을 사용해 같은 의미로 투영한다.
const StatInfo = struct { mode: c.mode_t, uid: c.uid_t };

pub const Error = error{
    InvalidHostId,
    InvalidDirectory,
    PathTooLong,
};

pub fn userRootPathIn(buf: []u8, uid: posix.uid_t) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/maru-{d}", .{uid});
}

/// registry 를 다른 자리로 돌리는 **테스트 격리 전용** 변수. 제품에서는 아무도 안 쓴다.
///
/// **왜 전용 이름인가.** 예전에는 테스트가 `XDG_CACHE_HOME` 으로 이 격리를 했는데(host spawn·
/// attach 게이트 전부), 제품 앱은 그것을 안 보고 `/tmp/maru-<uid>` 를 썼다 — 그래서 **게이트는
/// 초록인데 제품에서는 CLI 가 앱이 띄운 host 를 한 번도 못 찾았다**. `XDG_CACHE_HOME` 을 그대로
/// override 로 인정하면 그 변수를 실제로 설정해 둔 사용자에게서 같은 사고가 조건부로 되살아난다.
/// 캐시는 캐시고, registry 는 registry다.
pub const root_override_env = "MARU_SESSION_HOST_ROOT";
pub const legacy_shared_fixture_env = "MARU_SESSION_HOST_EMPTY_SHARED_FIXTURE";
pub const legacy_shared_fixture_value = "ephemeral-runner-v1";

pub const LegacyFixtureError = error{ Disabled, SharedUserNamespace, InvalidDirectory, PathTooLong };

/// Override를 모르는 frozen N-1 실행 전용이다. 공용 root가 이미 있으면 그것이 실제 앱 소유인지
/// 구분하려 하지 않고 거부한다. 성공한 mkdir만 이 테스트가 소유하므로 release 때 전체 삭제할 수 있다.
pub fn claimEmptySharedLegacyFixture() LegacyFixtureError!void {
    if (!builtin.is_test) return error.Disabled;
    const marker = std.c.getenv(legacy_shared_fixture_env) orelse return error.Disabled;
    if (!std.mem.eql(u8, std.mem.span(marker), legacy_shared_fixture_value)) return error.Disabled;
    var root_buf: [64]u8 = undefined;
    const root = userRootPathIn(&root_buf, std.c.getuid()) catch return error.PathTooLong;
    if (std.c.mkdir(root.ptr, 0o700) != 0) return error.SharedUserNamespace;
    var dir_buf: [80]u8 = undefined;
    const dir = socketDirPathIn(&dir_buf, std.c.getuid()) catch return error.PathTooLong;
    if (std.c.mkdir(dir.ptr, 0o700) != 0) {
        _ = std.c.rmdir(root.ptr);
        return error.InvalidDirectory;
    }
}

pub fn releaseEmptySharedLegacyFixture() void {
    var dir_buf: [80]u8 = undefined;
    if (socketDirPathIn(&dir_buf, std.c.getuid())) |dir| _ = std.c.rmdir(dir.ptr) else |_| {}
    var root_buf: [64]u8 = undefined;
    if (userRootPathIn(&root_buf, std.c.getuid())) |root| _ = std.c.rmdir(root.ptr) else |_| {}
}

pub fn sharedLegacyRootPathIn(buf: []u8) error{NoSpaceLeft}![:0]u8 {
    return userRootPathIn(buf, std.c.getuid());
}

pub fn sharedLegacySocketPathIn(buf: []u8, host_id: u128) error{ NoSpaceLeft, InvalidHostId }![:0]u8 {
    return socketPathIn(buf, std.c.getuid(), host_id);
}

/// 이 사용자의 **런타임 base**. manifest·lock·socket 이 함께 사는 자리이고, **캐시가 아니다**
/// (계약 §10 — 캐시는 언제든 지워지는 데이터인데 manifest 는 지우는 순간 살아 있는 세션을 전부
/// 잃게 만든다). 앱(host 를 띄우는 쪽)과 CLI(`runtime`·`attach`)가 **같은 이 함수**를 봐야
/// 한다 — 갈리면 CLI 가 앱이 띄운 host 를 못 찾는다(실제로 그랬다).
///
/// **override 는 registry 와 socket 을 함께 옮긴다.** 예전에는 registry 만 옮기고 socket 은 uid 로
/// 고정이라 둘이 갈렸고, §10 의 "열쇠(manifest)와 자물쇠(socket)를 한 디렉터리에" 불변식이 이
/// 경로에서만 깨져 있었다. 당시 주석은 "소비자(테스트)가 socket 경로를 따로 주입하므로 문제가
/// 없다"고 적었지만 **사실이 아니었다** — 2026-08-27 에 `test-session-host` 와
/// `test-macos-app-host-abi` 가 사용자의 공용 자리에 살아 있는 host 를 남겨 앱이 복구 세션을
/// adopt 하지 못했다.
///
/// 다만 **무엇이 앱을 깨뜨렸는지는 정확히 적는다**: `ambiguous`(`too_many_hosts`)는
/// `recovery_discovery` 가 **registry 의 host entry** 를 셀 때 나오고, socket 디렉터리를 열거하는
/// 제품 코드는 없다. 그러니 흘린 socket 파일 자체가 status 를 흔든 것이 아니다. socket 까지 옮기는
/// 이유는 따로 있다 — daemon 은 자기가 **실제로 쓰는** 뿌리를 touch 해 tmp 정리로부터 지키는데,
/// 뿌리가 갈리면 남의 자리를 지키면서 정작 자기 socket 을 잃는다. 격리는 양쪽을 다 옮겨야 격리다.
pub fn currentUserRootPathIn(buf: []u8) error{NoSpaceLeft}![:0]u8 {
    if (overrideRoot(if (std.c.getenv(root_override_env)) |v| std.mem.span(v) else null)) |root|
        return std.fmt.bufPrintZ(buf, "{s}", .{root});
    // **테스트 빌드는 공용 자리를 절대 쓰지 않는다.** override 를 걸지 않은 테스트가 하나라도 있으면
    // 그 하나가 사용자의 `/tmp/maru-<uid>/sh` 에 가짜 host 를 남기고, 그 가짜가 `host status` 를
    // ambiguous 로 만들어 **실행 중인 앱을 죽인다**(2026-08-27 에 두 번). 주입을 build 쪽 규율에
    // 맡기면 새 run 스텝이 생길 때마다 같은 구멍이 다시 열리므로, 기본값 자체를 프로세스별로 가른다.
    // pid 를 쓰므로 병렬 실행도 서로 밟지 않는다. 길이도 uid 형태보다 길지 않아 `sun_path` 여유가 그대로다.
    if (builtin.is_test) return std.fmt.bufPrintZ(buf, "/tmp/maru-t{d}", .{std.c.getpid()});
    return userRootPathIn(buf, std.c.getuid());
}

/// override 값의 해석. **빈 값은 미설정과 같다**(셸 `${VAR:-}` 관례) — 빈 경로로 registry 를
/// 열면 `/session-host` 가 되어 무엇이든 될 수 있다. 순수 함수라 그 분기를 실제로 잰다.
pub fn overrideRoot(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    return if (raw.len > 0) raw else null;
}

test "override 는 값이 있을 때만 base 를 바꾼다 — 빈 값은 미설정과 같다" {
    try std.testing.expect(overrideRoot(null) == null);
    try std.testing.expect(overrideRoot("") == null);
    try std.testing.expectEqualStrings("/tmp/iso", overrideRoot("/tmp/iso").?);
}

pub fn socketDirPathIn(buf: []u8, uid: posix.uid_t) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/maru-{d}/sh", .{uid});
}

pub fn socketPathIn(buf: []u8, uid: posix.uid_t, host_id: u128) error{ NoSpaceLeft, InvalidHostId }![:0]u8 {
    if (host_id == 0) return error.InvalidHostId;
    return std.fmt.bufPrintZ(buf, "/tmp/maru-{d}/sh/{x:0>32}.sock", .{ uid, host_id });
}

/// 임의의 runtime base 아래 socket 디렉터리. `userRootPathIn` 과 짝이며, override 가 걸린
/// 자리에서도 registry 와 같은 뿌리를 쓰게 하는 단일 출처다.
pub fn socketDirPathUnder(buf: []u8, root: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/sh", .{root});
}

pub fn socketPathUnder(buf: []u8, root: []const u8, host_id: u128) error{ NoSpaceLeft, InvalidHostId }![:0]u8 {
    if (host_id == 0) return error.InvalidHostId;
    return std.fmt.bufPrintZ(buf, "{s}/sh/{x:0>32}.sock", .{ root, host_id });
}

/// 이 프로세스가 실제로 쓸 socket 디렉터리. **registry 와 같은 뿌리**를 본다.
pub fn currentSocketDirPathIn(buf: []u8) error{NoSpaceLeft}![:0]u8 {
    var root_buf: [256]u8 = undefined;
    const root = try currentUserRootPathIn(&root_buf);
    return socketDirPathUnder(buf, root);
}

pub fn currentSocketPathIn(buf: []u8, host_id: u128) error{ NoSpaceLeft, InvalidHostId }![:0]u8 {
    var root_buf: [256]u8 = undefined;
    const root = currentUserRootPathIn(&root_buf) catch return error.NoSpaceLeft;
    return socketPathUnder(buf, root, host_id);
}

pub fn validateCurrentSocketPath(path: []const u8, host_id: u128) Error!void {
    var expected_buf: [128]u8 = undefined;
    const expected = currentSocketPathIn(&expected_buf, host_id) catch return error.PathTooLong;
    if (!std.mem.eql(u8, expected, path)) return error.PathTooLong;
}

/// Product launch 전에 호출한다. 기존 directory의 mode를 고쳐 신뢰하는 대신 exact 계약이 아니면 거부한다.
pub fn prepareCurrentUserNamespace() Error!void {
    // **override 를 반드시 통과시킨다.** 예전에는 여기서 `userRootPathIn(uid)`·`socketDirPathIn(uid)` 를
    // 직접 불러 공용 `/tmp/maru-<uid>` 를 만들었다. 그래서 registry 만 격리한 테스트가 socket 은 사용자의
    // 공용 자리에 남겼고, 가짜 host 가 `host status` 를 ambiguous 로 만들어 실행 중인 앱을 깨뜨렸다.
    var root_buf: [256]u8 = undefined;
    const root = currentUserRootPathIn(&root_buf) catch return error.PathTooLong;
    try ensureExactOwnerDir(root);
    var dir_buf: [272]u8 = undefined;
    const dir = currentSocketDirPathIn(&dir_buf) catch return error.PathTooLong;
    try ensureExactOwnerDir(dir);
}

fn ensureExactOwnerDir(path: [:0]const u8) Error!void {
    const rc = c.mkdir(path.ptr, 0o700);
    if (rc != 0 and posix.errno(rc) != .EXIST) return error.InvalidDirectory;
    var stat: StatInfo = undefined;
    if (statAtNoFollow(path, &stat) != .SUCCESS or
        !posix.S.ISDIR(stat.mode) or stat.uid != c.getuid() or (stat.mode & 0o777) != 0o700)
        return error.InvalidDirectory;
}

test "short endpoint is host-id keyed, bounded, and under the current UID namespace" {
    var path_buf: [128]u8 = undefined;
    const path = try currentSocketPathIn(&path_buf, 0xAABB);
    var expected_buf: [128]u8 = undefined;
    // 기대값을 uid 로 직접 짜지 않고 **registry 와 같은 뿌리**에서 유도한다. 그래야 override 가 걸린
    // 실행에서도 이 테스트가 "열쇠와 자물쇠가 한 뿌리" 를 실제로 검사한다(하드코딩하면 격리를 켜는 순간
    // 계약이 아니라 테스트가 깨진다).
    var root_buf: [256]u8 = undefined;
    const root = try currentUserRootPathIn(&root_buf);
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/sh/0000000000000000000000000000aabb.sock", .{root});
    try std.testing.expectEqualStrings(expected, path);
    try std.testing.expect(path.len + 1 <= @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len);
    try validateCurrentSocketPath(path, 0xAABB);
    try std.testing.expectError(error.PathTooLong, validateCurrentSocketPath("/tmp/maru-0/sh/other.sock", 0xAABB));
}

// 회귀: override 가 registry 만 옮기고 socket 은 uid 로 고정이라, 격리했다고 믿은 테스트가 사용자의 공용
// `/tmp/maru-<uid>/sh` 에 가짜 socket 을 남겼다. 그 가짜가 `host status` 를 ambiguous 로 만들어 실행 중인
// 앱이 복구 세션을 adopt 하지 못했고, 세션이 ended 로 접히며 앱이 크래시 로그도 없이 종료됐다.
// 격리는 **양쪽을 다 옮겨야** 격리다 — 이 계약을 환경변수 없이 순수 함수로 고정한다.
test "격리 root 아래에서 registry 와 socket 은 같은 뿌리를 쓴다" {
    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/maru-iso-test", .{});

    var dir_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/maru-iso-test/sh", try socketDirPathUnder(&dir_buf, root));

    var path_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/tmp/maru-iso-test/sh/0000000000000000000000000000aabb.sock",
        try socketPathUnder(&path_buf, root, 0xAABB),
    );

    // host_id 0 은 여전히 거부한다 — 뿌리를 옮겨도 키 계약은 그대로다.
    try std.testing.expectError(error.InvalidHostId, socketPathUnder(&path_buf, root, 0));

    // socket 경로는 sockaddr_un 한계 안이어야 한다. 뿌리가 길어지면 여기서 먼저 걸린다.
    const path = try socketPathUnder(&path_buf, root, 0xAABB);
    try std.testing.expect(path.len + 1 <= @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len);
}

test "short endpoint namespace is owner-only" {
    try prepareCurrentUserNamespace();
    var dir_buf: [272]u8 = undefined;
    const dir = try currentSocketDirPathIn(&dir_buf);
    var stat: StatInfo = undefined;
    try std.testing.expectEqual(
        posix.E.SUCCESS,
        statAtNoFollow(dir, &stat),
    );
    try std.testing.expect(posix.S.ISDIR(stat.mode));
    try std.testing.expectEqual(c.getuid(), stat.uid);
    try std.testing.expectEqual(@as(c.mode_t, 0o700), stat.mode & 0o777);
}

fn statAtNoFollow(path: [:0]const u8, out: *StatInfo) posix.E {
    if (builtin.os.tag == .linux) {
        var stat: std.os.linux.Statx = undefined;
        const rc = c.statx(posix.AT.FDCWD, path.ptr, posix.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &stat);
        const err = posix.errno(rc);
        if (err != .SUCCESS) return err;
        out.* = .{ .mode = @intCast(stat.mode), .uid = stat.uid };
        return .SUCCESS;
    }
    var stat: posix.Stat = undefined;
    const err = posix.errno(c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW));
    if (err != .SUCCESS) return err;
    out.* = .{ .mode = stat.mode, .uid = stat.uid };
    return .SUCCESS;
}
