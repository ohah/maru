//! control_socket — 세션 컨트롤 플레인 L4 unix domain socket 부트스트랩 (Track C slice 1b).
//! 단일 출처: docs/control-plane.md §4.1(hello)·§4.2(발견·stale·flock)·§8.2(권한·peer-cred)·§11(1b gate)·§16(위치).
//!
//! **범위(1b = 소켓 부트스트랩 + hello, dispatch 없음):**
//!  - unix domain socket 서버: bind(0700 dir + 0600 socket via chmod(path)), listen, accept, peer uid 검증(§8.2),
//!    accept 시 hello notification 전송(1a `control_plane.serializeHello` + 종단 `\n`, §4.1).
//!  - 소켓 경로 발견/부트스트랩: 결정론적 경로(pid/nonce 키, §4.2), stale 소켓은 flock 살아있음 판별 후
//!    unlink-then-bind(살아있는 소켓 unlink 금지).
//!  - 클라이언트 read 프레이밍 배선: 소켓 read 바이트를 1a `control_plane.Framer.push`로 흘리는 골격.
//!  **범위 밖:** 실제 dispatch·method 처리(1c+), capability/auth·capability fd(1e), collector·surface 상태(1c+),
//!  self-origin/LOCAL_PEERPID(§8.4, 1g). accept-loop 스레드 ↔ 메인 marshal 통합은 1c/§5 — 여기선 per-connection
//!  primitive(`acceptOne`)만 제공한다.
//!
//! **레이어(§11 코드 배치 gate):** 소켓 syscall·peer-cred·bind는 L4(이 파일). **순수 정책**(경로 파생·stale 판정·
//!  peer uid 비교·sun_path 길이 판정)은 이 모듈의 순수 헬퍼로 분리해 OS 상태 없이 단위 테스트한다(task: "L2 또는
//!  그 모듈의 순수 헬퍼"). check-boundaries는 platform 레이어를 제약하지 않으므로 platform→session import는 허용
//!  (이 파일이 1a L2 `control_plane`을 소비).
//!
//! **베이스와 결정(docs/document-basis-and-decision):**
//!  - **syscall 표면 = `std.c.*` extern**: Zig 0.16이 `std.posix.socket/bind/listen/accept/connect` 래퍼를
//!    제거해(신 std.Io 모델로 이동) libc extern을 직접 부른다(maru는 이미 libc를 링크 — build.zig `link_libc`).
//!    pty/macos.zig가 같은 방식(openpty 등 `extern "c"`)이라 선례가 있다.
//!  - **peer-cred = `getpeereid(2)`**: §8.2가 명명한 LOCAL_PEERCRED(macOS·xucred)/SO_PEERCRED(Linux·ucred)의
//!    이식 가능한 libc 래퍼다. 1b는 uid만 필요하므로 xucred 전체를 안 읽는다(pid=LOCAL_PEERPID는 §8.4 self-origin,
//!    1g 소관). spike 실측(scratchpad): getpeereid rc=0, euid==getuid.
//!  - **flock 대상 = 별도 regular lock 파일**(소켓 fd 아님): spike 실측에서 소켓 fd flock은 -1(ENOTSUP), 별도
//!    lock 파일은 첫 홀더 성공·둘째 홀더 EWOULDBLOCK(§4.2 "flock으로 살아있는지 판별")로 동작.
//!  - **권한 = process-global `umask` 미변경 + `chmod(path, 0600)`**: §8.2가 "umask 또는 chmod(path)"를 허용.
//!    멀티스레드 앱에서 umask는 프로세스 전역이라 그 창에 다른 스레드 파일 생성 mode를 오염시키므로 쓰지 않는다.
//!    bind~chmod 사이 창은 부모 dir 0700(다른 uid traverse 차단)이 덮고, same-uid는 신뢰 경계 안이다(§8). **`fchmod(fd)`
//!    금지**(§8.2 spike -1) — 우린 소켓 path에 chmod한다. 심볼릭 링크/소유자 검증은 `fstatat(SYMLINK_NOFOLLOW)`.
//!
//! **빌드 게이팅:** build.zig가 이 테스트를 **macOS에서만** `test` step에 배선한다. 파일 자체는 이식 가능하게
//!  (getpeereid + std.c) 썼지만, 검증이 macOS에서만 되고 후속 slice(1e/1g)가 macOS 전용 xucred/LOCAL_PEERPID를
//!  더하므로 ubuntu CI에 미검증 Linux 경로를 걸지 않는다(un-gate는 Linux 호스트 검증 후 후속).

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const maru = @import("maru");
const cp = maru.session.control_plane;
const cd = maru.session.control_dispatch; // Track C 1d: read-only 바이트→바이트 디스패치 라우터(소켓 왕복 통합 테스트).
const cs = maru.session.control_surface; // 1c Surface DTO/CollectorSnapshot(fake snapshot 주입).
const wm = maru.session.window_membership; // M0b membership DTO + scope.

/// peer 프로세스의 effective uid/gid를 읽는다. §8.2 LOCAL_PEERCRED(macOS·xucred)/SO_PEERCRED(Linux·ucred)를
/// libc가 래핑한 이식 함수(std.c 미노출이라 직접 extern). 1b는 uid만 쓴다(gid는 미사용).
extern "c" fn getpeereid(fd: c.fd_t, euid: *posix.uid_t, egid: *posix.gid_t) c_int;

// ══ 순수 정책(OS 상태 없음 — 단위 테스트 대상) ══════════════════════════════════════════════════════════════

/// sockaddr_un.sun_path의 바이트 용량(macOS 104). 컴파일타임에 struct에서 읽어 매직넘버를 피한다.
pub const sun_path_cap: usize = @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len;

/// 소켓 path가 sun_path에 (NUL 포함) 들어가는가. len == cap이면 NUL 자리가 없어 거부(len < cap만 허용).
pub fn socketPathFits(len: usize) bool {
    return len < sun_path_cap;
}

/// accept한 연결의 peer uid가 서버와 같은 uid인가(§8.2 "불일치 시 종료"). 파일 권한에만 의존하지 않는 하드 게이트.
pub fn peerUidAllowed(server_uid: posix.uid_t, peer_uid: posix.uid_t) bool {
    return server_uid == peer_uid;
}

/// bind 전 stale 소켓 처리 결정(§4.2). flock 취득 성공 = 옛 소유자 죽음/부재 → unlink 후 bind 안전.
/// 취득 실패(EWOULDBLOCK) = 살아있는 인스턴스가 홀드 → **소켓 unlink 금지**, 중단.
pub const StaleAction = enum { unlink_and_bind, abort_live };
pub fn staleAction(lock_acquired: bool) StaleAction {
    return if (lock_acquired) .unlink_and_bind else .abort_live;
}

/// 인스턴스 키 = pid + 부팅 nonce(§4.2 "소켓 경로 키 = 인스턴스(pid/부팅 nonce)"). 결정론적 파일명 컴포넌트.
/// 값 자체에 라우팅 의미는 없다 — 인스턴스별 충돌 없는 유일 파일명일 뿐.
pub fn formatInstanceKey(buf: []u8, pid: i32, nonce: u64) error{NoSpaceLeft}![]u8 {
    return std.fmt.bufPrint(buf, "{d}-{x}", .{ pid, nonce });
}

/// base 뒤 trailing '/' 하나를 제거(경로 조합 시 이중 슬래시 방지). "/" 단독은 그대로 둔다(빈 base 방지).
fn trimTrailingSlash(base: []const u8) []const u8 {
    if (base.len > 1 and base[base.len - 1] == '/') return base[0 .. base.len - 1];
    return base;
}

/// 컨트롤 디렉터리 경로 `<base>/control`(§4.2 "~/.cache/maru/control/"). base는 caller가 정한다(테스트=격리 tmp,
/// 제품=~/.cache/maru). 이 순수 함수는 base를 모르는 채 조합만 한다(OS 상태 없음). NUL 종단(mkdir/chmod/fstatat용).
pub fn controlDirPath(buf: []u8, base: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/control", .{trimTrailingSlash(base)});
}

/// 소켓 경로 `<dir>/<key>.sock`(NUL 종단 — bind가 C 문자열을 요구).
pub fn socketPathIn(buf: []u8, dir: []const u8, key: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}.sock", .{ trimTrailingSlash(dir), key });
}

/// 라이브니스 lock 경로 `<dir>/<key>.lock`(소켓과 별도 regular 파일 — flock 대상).
pub fn lockPathIn(buf: []u8, dir: []const u8, key: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}.lock", .{ trimTrailingSlash(dir), key });
}

// ══ L4 소켓 서버 ═══════════════════════════════════════════════════════════════════════════════════════════

pub const BindError = error{
    /// 조합된 소켓 경로가 sun_path 용량 초과(§8.2 경로 길이). syscall 전에 순수 판정으로 거부.
    SocketPathTooLong,
    /// 같은 키의 살아있는 인스턴스가 flock을 홀드 중(§4.2). 소켓을 unlink하지 않고 중단.
    AddressInUse,
    ControlDirFailed,
    LockOpenFailed,
    SocketCreateFailed,
    BindFailed,
    ChmodFailed,
    ListenFailed,
    /// bind 후 소유자/모드/타입(fstatat) 검증 실패 — 심볼릭 링크·소유권 위장 방어(§8.2).
    OwnershipCheckFailed,
    OutOfMemory,
    NoSpaceLeft,
};

pub const AcceptError = error{
    AcceptFailed,
    PeerCredFailed,
    /// peer uid ≠ 서버 uid(§8.2). 연결을 닫고 이 오류를 돌려준다.
    PeerUidMismatch,
    WriteFailed,
    OutOfMemory,
};

/// accept된 한 연결. 프레이밍 배선(read → Framer.push)까지가 1b 범위. dispatch는 후속.
pub const Connection = struct {
    fd: c.fd_t,

    /// 소켓에서 한 번 read해 그 바이트를 1a `Framer`에 흘린다(§4.3 프레이밍 배선 골격). 반환=읽은 바이트 수,
    /// 0이면 EOF(peer 종료). 프레임 추출은 caller가 `framer.next()`로 한다 — dispatch는 없음(1c+).
    pub fn readInto(self: Connection, gpa: std.mem.Allocator, framer: *cp.Framer) error{ ReadFailed, OutOfMemory }!usize {
        var buf: [4096]u8 = undefined;
        const n = while (true) {
            const rc = c.read(self.fd, &buf, buf.len);
            if (rc < 0) {
                if (posix.errno(rc) == .INTR) continue; // 시그널 인터럽트는 재시도(acceptOne·writeAll과 동일, 적대적 리뷰 반영)
                return error.ReadFailed;
            }
            break rc;
        };
        if (n == 0) return 0;
        try framer.push(gpa, buf[0..@intCast(n)]);
        return @intCast(n);
    }

    pub fn deinit(self: Connection) void {
        _ = c.close(self.fd);
    }
};

/// 부분 write를 처리하는 blocking write-all(소켓 stream). 짧은 hello/`\n`이지만 부분 write·EINTR를 방어한다.
fn writeAll(fd: c.fd_t, bytes: []const u8) error{WriteFailed}!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed; // 진전 없음
        off += @intCast(n);
    }
}

/// hello notification에 실을 서버측 값(§4.1). 순수 스키마·직렬화는 1a `control_plane`가 소유.
pub const HelloConfig = struct {
    server_version: []const u8,
    capabilities: []const []const u8,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    listen_fd: c.fd_t,
    lock_fd: c.fd_t,
    server_uid: posix.uid_t,
    socket_path: [:0]u8,
    lock_path: [:0]u8,

    pub const backlog: c_uint = 16;

    /// `<base>/control/<key>.sock`에 unix domain socket 서버를 세운다(§4.2·§8.2). 순서:
    ///  1. 컨트롤 dir 0700 보장(mkdir + chmod, 소유자 검증).
    ///  2. lock 파일 flock(EX|NB) — 실패(EWOULDBLOCK)=살아있는 인스턴스 → `AddressInUse`(소켓 unlink 금지).
    ///  3. lock 취득 성공 → 경로의 stale 소켓 unlink(우리가 lock을 쥐어 살아있는 소유자 없음).
    ///  4. sun_path 길이 판정 → bind → chmod(path,0600) → listen.
    ///  5. 소켓 path fstatat(SYMLINK_NOFOLLOW): S_IFSOCK·소유자==우리·mode 0600 검증.
    pub fn bind(gpa: std.mem.Allocator, base_dir: []const u8, key: []const u8) BindError!Server {
        const server_uid = c.getuid();

        // ── 경로 조합 + sun_path 길이 판정(syscall 전 순수 게이트) ──
        var dir_buf: [512]u8 = undefined;
        const dir = try controlDirPath(&dir_buf, base_dir);
        var sp_buf: [512]u8 = undefined;
        const sp = try socketPathIn(&sp_buf, dir, key);
        if (!socketPathFits(sp.len)) return error.SocketPathTooLong; // 어떤 syscall도 하기 전에 거부(§8.2)
        var lp_buf: [512]u8 = undefined;
        const lp = try lockPathIn(&lp_buf, dir, key);

        // 소유 복사본(Server 수명). 이후 실패는 errdefer로 해제.
        const socket_path = try gpa.dupeZ(u8, sp);
        errdefer gpa.free(socket_path);
        const lock_path = try gpa.dupeZ(u8, lp);
        errdefer gpa.free(lock_path);

        // ── 1. 컨트롤 dir 0700 보장 + 소유자/타입 검증(§8.2) ──
        const mrc = c.mkdir(dir.ptr, 0o700);
        if (mrc != 0 and posix.errno(mrc) != .EXIST) return error.ControlDirFailed;
        if (c.chmod(dir.ptr, 0o700) != 0) return error.ControlDirFailed; // umask 무관하게 0700 강제
        var dst: posix.Stat = undefined;
        if (c.fstatat(posix.AT.FDCWD, dir.ptr, &dst, posix.AT.SYMLINK_NOFOLLOW) != 0) return error.ControlDirFailed;
        if (!posix.S.ISDIR(dst.mode) or dst.uid != server_uid) return error.OwnershipCheckFailed;

        // ── 2. 라이브니스 lock 파일 flock(EX|NB) — §4.2 stale 판별의 단일 지점 ──
        const lock_fd = c.open(lock_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(c.mode_t, 0o600));
        if (lock_fd < 0) return error.LockOpenFailed;
        errdefer _ = c.close(lock_fd);
        _ = c.chmod(lock_path.ptr, 0o600);
        const lock_acquired = c.flock(lock_fd, posix.LOCK.EX | posix.LOCK.NB) == 0;
        switch (staleAction(lock_acquired)) {
            // 살아있는 인스턴스가 홀드 → 소켓을 절대 unlink하지 않고 중단(§4.2).
            .abort_live => return error.AddressInUse,
            // lock 취득 = 옛 소유자 부재 → 경로의 stale 소켓/잔해를 unlink 후 bind 안전.
            .unlink_and_bind => _ = c.unlink(socket_path.ptr),
        }
        // 이 지점 도달 = lock 취득(unlink_and_bind; abort_live는 위에서 return). 우리가 lock을 소유하므로 이후 단계
        // (bind/chmod/listen/검증) 실패 시 우리 `<key>.lock`도 정리한다 — 빈 lock 잔해 누적 방지(적대적 리뷰 반영).
        // abort_live 경로는 여기 못 오므로 살아있는 인스턴스의 lock을 지우지 않는다.
        errdefer _ = c.unlink(lock_path.ptr);

        // ── 3. socket → bind → chmod(0600) → listen ──
        const lfd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (lfd < 0) return error.SocketCreateFailed;
        errdefer _ = c.close(lfd);
        var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);
        if (c.bind(lfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return error.BindFailed;
        errdefer _ = c.unlink(socket_path.ptr); // bind 성공 후 이후 단계 실패 시 소켓 파일 정리
        // 소유자 전용 0600(§8.2). process-global umask는 건드리지 않는다(멀티스레드 오염 방지) — chmod(path).
        if (c.chmod(socket_path.ptr, 0o600) != 0) return error.ChmodFailed;
        if (c.listen(lfd, backlog) != 0) return error.ListenFailed;

        // ── 4. bind 결과 소유자/모드/타입 검증(심볼릭 링크·위장 방어, §8.2 O_NOFOLLOW/lstat) ──
        var st: posix.Stat = undefined;
        if (c.fstatat(posix.AT.FDCWD, socket_path.ptr, &st, posix.AT.SYMLINK_NOFOLLOW) != 0) return error.OwnershipCheckFailed;
        if (!posix.S.ISSOCK(st.mode) or st.uid != server_uid or (st.mode & 0o777) != 0o600) return error.OwnershipCheckFailed;

        return .{
            .gpa = gpa,
            .listen_fd = lfd,
            .lock_fd = lock_fd,
            .server_uid = server_uid,
            .socket_path = socket_path,
            .lock_path = lock_path,
        };
    }

    /// 한 연결을 blocking accept한다. peer uid 검증(§8.2) 후 hello notification(§4.1)을 보낸다. dispatch 없음.
    pub fn acceptOne(self: *Server, gpa: std.mem.Allocator, hello: HelloConfig) AcceptError!Connection {
        const cfd = while (true) {
            const rc = c.accept(self.listen_fd, null, null);
            if (rc < 0) {
                if (posix.errno(rc) == .INTR) continue; // 시그널 인터럽트는 재시도
                return error.AcceptFailed;
            }
            break rc;
        };
        errdefer _ = c.close(cfd); // reject/실패 시 연결을 닫는다

        // peer uid 검증(§8.2) — 파일 권한에만 의존하지 않는 하드 게이트. 불일치면 연결 종료.
        var euid: posix.uid_t = undefined;
        var egid: posix.gid_t = undefined;
        if (getpeereid(cfd, &euid, &egid) != 0) return error.PeerCredFailed;
        if (!peerUidAllowed(self.server_uid, euid)) return error.PeerUidMismatch;

        // hello notification(§4.1): 1a serializeHello + 종단 `\n`. 직렬화는 1a L2가 소유(재구현 금지).
        const wire = cp.serializeHello(gpa, .{
            .server_version = hello.server_version,
            .capabilities = hello.capabilities,
        }) catch return error.OutOfMemory;
        defer gpa.free(wire);
        try writeAll(cfd, wire);
        try writeAll(cfd, "\n");

        return .{ .fd = cfd };
    }

    pub fn deinit(self: *Server) void {
        _ = c.close(self.listen_fd);
        _ = c.unlink(self.socket_path.ptr);
        _ = c.close(self.lock_fd); // flock 해제
        _ = c.unlink(self.lock_path.ptr);
        self.gpa.free(self.socket_path);
        self.gpa.free(self.lock_path);
    }

    pub fn socketPath(self: *const Server) [:0]const u8 {
        return self.socket_path;
    }
};

// ══ 테스트 ═════════════════════════════════════════════════════════════════════════════════════════════════
const testing = std.testing;

// ── 순수 정책 단위 테스트 ──

test "policy: socketPathFits는 sun_path 용량 미만만 허용(경계 포함)" {
    try testing.expect(socketPathFits(0));
    try testing.expect(socketPathFits(sun_path_cap - 1)); // NUL 자리 1 남음
    try testing.expect(!socketPathFits(sun_path_cap)); // NUL 자리 없음
    try testing.expect(!socketPathFits(sun_path_cap + 1));
    try testing.expect(!socketPathFits(200));
}

test "policy: peerUidAllowed는 같은 uid만 허용(cross-uid 거부)" {
    try testing.expect(peerUidAllowed(501, 501));
    try testing.expect(!peerUidAllowed(501, 0)); // root peer 거부
    try testing.expect(!peerUidAllowed(0, 501));
    try testing.expect(!peerUidAllowed(501, 502));
    try testing.expect(peerUidAllowed(0, 0));
}

test "policy: staleAction — lock 취득=unlink_and_bind, 미취득=abort_live" {
    try testing.expectEqual(StaleAction.unlink_and_bind, staleAction(true));
    try testing.expectEqual(StaleAction.abort_live, staleAction(false));
}

test "policy: formatInstanceKey는 pid·nonce에 결정론적, 서로 다르면 다른 키" {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const k1 = try formatInstanceKey(&b1, 1234, 0xABCD);
    try testing.expectEqualStrings("1234-abcd", k1);
    // 같은 입력 → 같은 키(결정론).
    const k1b = try formatInstanceKey(&b2, 1234, 0xABCD);
    try testing.expectEqualStrings(k1, k1b);
    // pid 다르면 다름.
    const k2 = try formatInstanceKey(&b2, 1235, 0xABCD);
    try testing.expect(!std.mem.eql(u8, k1, k2));
    // nonce 다르면 다름.
    const k3 = try formatInstanceKey(&b2, 1234, 0x1);
    try testing.expect(!std.mem.eql(u8, k1, k3));
}

test "policy: formatInstanceKey는 버퍼 부족 시 NoSpaceLeft" {
    var tiny: [3]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, formatInstanceKey(&tiny, 999999, 0xFFFF));
}

test "policy: path 파생 — controlDir/socketPath/lockPath + trailing slash 정규화" {
    var b: [256]u8 = undefined;
    try testing.expectEqualStrings("/base/control", try controlDirPath(&b, "/base"));
    // trailing slash 정규화(이중 슬래시 방지).
    try testing.expectEqualStrings("/base/control", try controlDirPath(&b, "/base/"));
    var b2: [256]u8 = undefined;
    const sp = try socketPathIn(&b2, "/base/control", "1234-ab");
    try testing.expectEqualStrings("/base/control/1234-ab.sock", sp);
    try testing.expectEqual(@as(u8, 0), sp.ptr[sp.len]); // NUL 종단
    var b3: [256]u8 = undefined;
    const lp = try lockPathIn(&b3, "/base/control/", "1234-ab");
    try testing.expectEqualStrings("/base/control/1234-ab.lock", lp);
}

// ── 소켓 통합 테스트(실제 bind/connect, 격리 tmp 경로 — ~/.cache 미접촉) ──
//
// 격리 원칙: base_dir을 `/tmp/maru-ct-<pid>-<tag>-<nanos>`로 명시 주입해 제품 경로(~/.cache/maru)를 절대
// 건드리지 않는다(task 요구). /tmp는 짧은 절대경로라 sun_path(104) 여유도 확보한다.

/// 격리 tmp base dir을 만들어 NUL 종단 경로를 buf에 담아 돌려준다. 짧은 /tmp 경로(sun_path 여유).
/// 유일성: pid + tag(테스트별) + 단조 카운터. (Zig 0.16이 std.time.nanoTimestamp를 제거해 카운터로 대체.)
var tmp_counter: std.atomic.Value(u64) = .init(0);
fn makeTmpBase(buf: []u8, tag: []const u8) [:0]u8 {
    const n = tmp_counter.fetchAdd(1, .monotonic);
    const p = std.fmt.bufPrintZ(buf, "/tmp/maru-ct-{d}-{s}-{d}", .{ c.getpid(), tag, n }) catch unreachable;
    _ = c.mkdir(p.ptr, 0o700);
    return p;
}

/// base dir 트리 정리(best-effort): control/*.sock·*.lock는 Server.deinit이 지웠다고 보고 dir만 치운다.
fn rmTmpBase(base: [:0]const u8) void {
    var b: [512]u8 = undefined;
    const ctl = controlDirPath(&b, base) catch return;
    _ = c.rmdir(ctl.ptr); // 비어 있으면 제거
    _ = c.rmdir(base.ptr);
}

/// 테스트용 클라이언트: base/key의 소켓에 connect해 fd를 돌려준다.
fn connectClient(base: []const u8, key: []const u8) !c.fd_t {
    var db: [512]u8 = undefined;
    const dir = try controlDirPath(&db, base);
    var sb: [512]u8 = undefined;
    const sp = try socketPathIn(&sb, dir, key);
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return error.ClientSocket;
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..sp.len], sp);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) {
        _ = c.close(fd);
        return error.ClientConnect;
    }
    return fd;
}

const test_caps = [_][]const u8{ "sessions.list", "session.get", "session.capture" };
const test_hello = HelloConfig{ .server_version = "0.1.0-test", .capabilities = &test_caps };

test "socket: bind→connect→hello 왕복 — accept가 hello notification을 보내고 client가 Framer로 파싱" {
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "roundtrip");
    defer rmTmpBase(base);

    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit();

    // 클라이언트를 별도 스레드에서 connect(accept 전에 도착 가능 — accept가 backlog에서 뽑는다).
    const ClientT = struct {
        base: []const u8,
        got: [512]u8 = undefined,
        got_len: usize = 0,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            const fd = connectClient(self.base, "k1") catch |e| {
                self.err = e;
                return;
            };
            defer _ = c.close(fd);
            const n = c.read(fd, &self.got, self.got.len);
            if (n < 0) {
                self.err = error.ClientRead;
                return;
            }
            self.got_len = @intCast(n);
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});

    var conn = try srv.acceptOne(testing.allocator, test_hello);
    defer conn.deinit();
    th.join();
    try testing.expect(ct.err == null);

    // client가 받은 바이트를 1a Framer로 프레이밍 → hello notification 파싱.
    var framer: cp.Framer = .{};
    defer framer.deinit(testing.allocator);
    try framer.push(testing.allocator, ct.got[0..ct.got_len]);
    const line = (try framer.next()).?;
    var pm = try cp.parseMessage(testing.allocator, line);
    defer pm.deinit();
    try testing.expect(pm.message == .notification);
    const notif = pm.message.notification;
    try testing.expectEqualStrings(cp.hello_method, notif.method);
    const params = notif.params.?.object;
    try testing.expectEqualStrings(cp.protocol_id, params.get("protocol").?.string);
    try testing.expectEqualStrings("0.1.0-test", params.get("server_version").?.string);
    try testing.expectEqual(@as(usize, 3), params.get("capabilities").?.array.items.len);
}

test "socket: accept가 peer uid(getpeereid)를 읽어 같은 uid면 accept — hello가 정확히 한 줄(\\n 종단)" {
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "peeruid");
    defer rmTmpBase(base);

    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit();

    const ClientT = struct {
        base: []const u8,
        got: [512]u8 = undefined,
        got_len: usize = 0,
        fn run(self: *@This()) void {
            const fd = connectClient(self.base, "k1") catch return;
            defer _ = c.close(fd);
            const n = c.read(fd, &self.got, self.got.len);
            if (n > 0) self.got_len = @intCast(n);
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});
    var conn = try srv.acceptOne(testing.allocator, test_hello); // 같은 uid라 통과
    defer conn.deinit();
    th.join();

    // hello 프레임은 정확히 한 줄: raw 개행이 마지막 1개뿐이어야(종단 \n), 중간엔 없어야.
    const bytes = ct.got[0..ct.got_len];
    try testing.expect(bytes.len > 0);
    try testing.expectEqual(@as(u8, '\n'), bytes[bytes.len - 1]);
    try testing.expect(std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], '\n') == null);
}

test "socket: 권한 — 소켓 path 0600, 컨트롤 dir 0700, 소유자==우리(fstatat SYMLINK_NOFOLLOW)" {
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "perms");
    defer rmTmpBase(base);

    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit();

    // 소켓 path 검사.
    var st: posix.Stat = undefined;
    try testing.expectEqual(@as(c_int, 0), c.fstatat(posix.AT.FDCWD, srv.socket_path.ptr, &st, posix.AT.SYMLINK_NOFOLLOW));
    try testing.expect(posix.S.ISSOCK(st.mode));
    try testing.expectEqual(@as(posix.mode_t, 0o600), st.mode & 0o777);
    try testing.expectEqual(c.getuid(), st.uid);

    // 컨트롤 dir 검사.
    var db: [512]u8 = undefined;
    const dir = try controlDirPath(&db, base);
    var dst: posix.Stat = undefined;
    try testing.expectEqual(@as(c_int, 0), c.fstatat(posix.AT.FDCWD, dir.ptr, &dst, posix.AT.SYMLINK_NOFOLLOW));
    try testing.expect(posix.S.ISDIR(dst.mode));
    try testing.expectEqual(@as(posix.mode_t, 0o700), dst.mode & 0o777);
    try testing.expectEqual(c.getuid(), dst.uid);
}

test "socket: stale 소켓(살아있는 소유자 없음)은 unlink-then-bind로 회수" {
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "stale");
    defer rmTmpBase(base);

    // 컨트롤 dir을 미리 만들고 소켓 경로에 죽은 소켓 대신 plain 파일을 남긴다(stale 잔해 흉내).
    var db: [512]u8 = undefined;
    const dir = try controlDirPath(&db, base);
    _ = c.mkdir(dir.ptr, 0o700);
    var sb: [512]u8 = undefined;
    const sp = try socketPathIn(&sb, dir, "k1");
    const junk = c.open(sp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c.mode_t, 0o600));
    try testing.expect(junk >= 0);
    _ = c.close(junk);

    // lock 홀더가 없으므로 bind는 stale을 unlink하고 성공해야 한다.
    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit();
    // 이제 진짜 소켓이라 connect 가능.
    const fd = try connectClient(base, "k1");
    _ = c.close(fd);
}

test "socket: 살아있는 소켓은 unlink 금지 — 같은 키 재bind는 AddressInUse, 원본 소켓 생존" {
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "live");
    defer rmTmpBase(base);

    var srv1 = try Server.bind(testing.allocator, base, "k1");
    defer srv1.deinit();

    // 같은 base/key로 두 번째 bind → 첫 인스턴스가 flock을 홀드 → AddressInUse(소켓 unlink 안 함).
    try testing.expectError(error.AddressInUse, Server.bind(testing.allocator, base, "k1"));

    // 원본 소켓은 여전히 살아 있어 connect 가능해야 한다(unlink되지 않았다는 증거).
    const ClientT = struct {
        base: []const u8,
        ok: bool = false,
        fn run(self: *@This()) void {
            const fd = connectClient(self.base, "k1") catch return;
            defer _ = c.close(fd);
            var rb: [128]u8 = undefined;
            const n = c.read(fd, &rb, rb.len);
            self.ok = n > 0;
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});
    var conn = try srv1.acceptOne(testing.allocator, test_hello);
    defer conn.deinit();
    th.join();
    try testing.expect(ct.ok);
}

test "socket: sun_path 초과 경로는 syscall 전에 SocketPathTooLong으로 거부" {
    // 아주 긴 base로 sun_path(104)를 확실히 넘긴다. 실제 mkdir/bind는 시도하지 않아야(순수 판정이 먼저 거부).
    var bb: [512]u8 = undefined;
    var long: [300]u8 = undefined;
    @memset(&long, 'x');
    const base = std.fmt.bufPrint(&bb, "/tmp/{s}", .{long[0..250]}) catch unreachable;
    try testing.expectError(error.SocketPathTooLong, Server.bind(testing.allocator, base, "k1"));
}

test "socket: 부분 read 프레이밍 — 두 write로 쪼갠 프레임이 Framer로 한 줄로 조립(dispatch 없음)" {
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "framing");
    defer rmTmpBase(base);

    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit();

    // 클라이언트가 hello를 읽은 뒤 요청 한 줄을 두 조각으로 나눠 보낸다(부분 read 유발).
    const ClientT = struct {
        base: []const u8,
        fn run(self: *@This()) void {
            const fd = connectClient(self.base, "k1") catch return;
            defer _ = c.close(fd);
            var rb: [512]u8 = undefined;
            _ = c.read(fd, &rb, rb.len); // hello 버린다
            const part1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"met";
            const part2 = "hod\":\"sessions.list\"}\n";
            _ = c.write(fd, part1, part1.len);
            // 짧은 갭으로 부분 read를 실제 유발(Zig 0.16: Thread.sleep 제거 → Io.sleep).
            std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
            _ = c.write(fd, part2, part2.len);
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});

    var conn = try srv.acceptOne(testing.allocator, test_hello);
    defer conn.deinit();

    var framer: cp.Framer = .{};
    defer framer.deinit(testing.allocator);
    // 완결 프레임이 조립될 때까지 read 루프(부분 read 누적).
    var line: ?[]const u8 = null;
    var guard: usize = 0;
    while (line == null and guard < 100) : (guard += 1) {
        const n = try conn.readInto(testing.allocator, &framer);
        if (n == 0) break; // EOF
        line = try framer.next();
    }
    th.join();
    try testing.expect(line != null);
    var pm = try cp.parseMessage(testing.allocator, line.?);
    defer pm.deinit();
    try testing.expect(pm.message == .request);
    try testing.expectEqualStrings("sessions.list", pm.message.request.method);
}

test "socket: 순차 다중 연결 — 각 연결이 hello를 받는다(accept-loop 골격)" {
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "multi");
    defer rmTmpBase(base);

    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const ClientT = struct {
            base: []const u8,
            got_len: usize = 0,
            got: [512]u8 = undefined,
            fn run(self: *@This()) void {
                const fd = connectClient(self.base, "k1") catch return;
                defer _ = c.close(fd);
                const n = c.read(fd, &self.got, self.got.len);
                if (n > 0) self.got_len = @intCast(n);
            }
        };
        var ct = ClientT{ .base = base };
        const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});
        var conn = try srv.acceptOne(testing.allocator, test_hello);
        th.join();
        conn.deinit();
        try testing.expect(ct.got_len > 0);
        try testing.expectEqual(@as(u8, '\n'), ct.got[ct.got_len - 1]);
    }
}

// ── 1d 통합: 실제 소켓 왕복 + read-only 디스패치(fake collector snapshot 주입, tmpDir만·~/.cache 미접촉) ──
//
// 1b(hello 왕복)에 1d 디스패치를 얹어 client가 요청을 보내고 server가 fake snapshot으로 응답하는 전체 경로를
// **최소 동기**로 검증한다(accept-loop 스레드·메인 marshal(§5)·capability auth(1e)·live collector는 범위 밖 —
// 여긴 acceptOne 한 번 + per-connection read→dispatch→write만). caller_surface_id/scope는 auth가 발급할 값을
// 테스트가 주입한다(1d 순수 경계). dispatch 자체의 라우팅/에러/scope는 control_dispatch.zig 단위 테스트가 커버.

// fake collector snapshot: 창 A(win1)={10 terminal}, 창 B(win2)={20 terminal}. caller=10.
const rt_surfaces = [_]cs.SurfaceDto{
    .{ .surface_id = 10, .title = "shell-a", .window = 1, .focused = true, .detail = .{ .terminal = .{ .cwd = "/home/a", .at_prompt = .not_at_prompt } } },
    .{ .surface_id = 20, .title = "shell-b", .window = 2, .detail = .{ .terminal = .{ .at_prompt = .at_prompt } } },
};
const rt_a = [_]u64{10};
const rt_b = [_]u64{20};
const rt_windows = [_]wm.WindowMembershipSnapshot{
    .{ .window_id = 1, .window_kind = .normal, .surface_ids = &rt_a },
    .{ .window_id = 2, .window_kind = .normal, .surface_ids = &rt_b },
};
const rt_snapshot: cs.CollectorSnapshot = .{ .surfaces = &rt_surfaces, .windows = &rt_windows };

test "socket 1d: client가 sessions.list 요청 → server가 fake snapshot으로 디스패치 → 응답 왕복(scope=all)" {
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "dispatch");
    defer rmTmpBase(base);

    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit();

    // 클라이언트: connect → hello 버림 → sessions.list 요청 전송 → 응답 한 줄 수신.
    const ClientT = struct {
        base: []const u8,
        resp: [2048]u8 = undefined,
        resp_len: usize = 0,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            const fd = connectClient(self.base, "k1") catch |e| {
                self.err = e;
                return;
            };
            defer _ = c.close(fd);
            // hello 한 줄을 읽어 버린다.
            var hb: [512]u8 = undefined;
            _ = c.read(fd, &hb, hb.len);
            // 요청 전송(client wire 대신 raw 한 줄 — client wire는 cli/sessions.zig 단위 테스트가 커버).
            const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.list\"}\n";
            _ = c.write(fd, req, req.len);
            // 응답을 프레임이 완결될 때까지 읽는다(개행 종단).
            var framer: cp.Framer = .{};
            defer framer.deinit(std.testing.allocator);
            var guard: usize = 0;
            while (guard < 100) : (guard += 1) {
                var rb: [512]u8 = undefined;
                const n = c.read(fd, &rb, rb.len);
                if (n <= 0) break;
                framer.push(std.testing.allocator, rb[0..@intCast(n)]) catch |e| {
                    self.err = e;
                    return;
                };
                if (framer.next() catch null) |line| {
                    @memcpy(self.resp[0..line.len], line);
                    self.resp_len = line.len;
                    return;
                }
            }
            self.err = error.NoResponse;
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.run, .{&ct});

    // server: accept(hello 전송) → 요청 프레임 조립 → 1d 디스패치 → 응답 + 개행 write.
    var conn = try srv.acceptOne(testing.allocator, test_hello);
    defer conn.deinit();

    var framer: cp.Framer = .{};
    defer framer.deinit(testing.allocator);
    var line: ?[]const u8 = null;
    var guard: usize = 0;
    while (line == null and guard < 100) : (guard += 1) {
        const n = try conn.readInto(testing.allocator, &framer);
        if (n == 0) break;
        line = try framer.next();
    }
    try testing.expect(line != null);

    // 주입: caller_surface_id=10, scope=all(auth가 발급할 값을 테스트가 주입 — 1d 순수 경계).
    const response = try cd.dispatchReadOnly(testing.allocator, line.?, rt_snapshot, 10, .all);
    defer testing.allocator.free(response);
    try writeAll(conn.fd, response);
    try writeAll(conn.fd, "\n");

    th.join();
    try testing.expect(ct.err == null);
    try testing.expect(ct.resp_len > 0);

    // client가 받은 응답을 파싱해 sessions.list 결과(전체 = 10,20)를 확인한다.
    var pm = try cp.parseMessage(testing.allocator, ct.resp[0..ct.resp_len]);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    try testing.expect(cp.idEql(pm.message.response.id, .{ .number = 1 }));
    const arr = pm.message.response.result.?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    try testing.expectEqual(@as(i64, 10), arr.items[0].object.get("id").?.object.get("surface_id").?.integer);
    try testing.expectEqual(@as(i64, 20), arr.items[1].object.get("id").?.object.get("surface_id").?.integer);
}

// ── 커버리지 보강(test/foundation-coverage-gaps) ──────────────────────────────────────────────────────────

// 순수 path 파생 함수들의 문서화된 error{NoSpaceLeft}: 기존 테스트는 formatInstanceKey만 버퍼 부족을 밟았다.
// controlDirPath/socketPathIn/lockPathIn도 같은 bufPrintZ 계약이라 작은 버퍼에서 NoSpaceLeft를 내야 한다.
test "policy: controlDirPath/socketPathIn/lockPathIn은 버퍼 부족 시 NoSpaceLeft" {
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, controlDirPath(&tiny, "/base"));
    try testing.expectError(error.NoSpaceLeft, socketPathIn(&tiny, "/base/control", "1234-ab"));
    try testing.expectError(error.NoSpaceLeft, lockPathIn(&tiny, "/base/control", "1234-ab"));
}

// 인스턴스 키 격리(§4.2 "소켓 경로 키 = 인스턴스"): 같은 base에서 **서로 다른 키**는 독립 lock/소켓이라 둘 다
// bind되고 각자 connect된다. 같은 키 재bind가 AddressInUse인 것("live" 테스트)과 대조되는 반대 방향 — 여러 maru
// 인스턴스 공존이라는 키 설계의 목적을 못박는다.
test "socket: 서로 다른 인스턴스 키는 같은 base에서 공존한다(각자 bind·connect)" {
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "twokeys");
    defer rmTmpBase(base);

    var srv_a = try Server.bind(testing.allocator, base, "kA");
    defer srv_a.deinit();
    var srv_b = try Server.bind(testing.allocator, base, "kB"); // 다른 키 → 독립 lock, 성공해야
    defer srv_b.deinit();

    // 두 소켓 경로가 다르다.
    try testing.expect(!std.mem.eql(u8, srv_a.socket_path, srv_b.socket_path));

    // 각 키로 별도 클라이언트가 connect → 각자 accept가 hello를 보낸다.
    const ClientT = struct {
        base: []const u8,
        key: []const u8,
        ok: bool = false,
        fn run(self: *@This()) void {
            const fd = connectClient(self.base, self.key) catch return;
            defer _ = c.close(fd);
            var rb: [256]u8 = undefined;
            const n = c.read(fd, &rb, rb.len);
            self.ok = n > 0 and rb[@intCast(n - 1)] == '\n';
        }
    };
    var ca = ClientT{ .base = base, .key = "kA" };
    var cb = ClientT{ .base = base, .key = "kB" };
    const ta = try std.Thread.spawn(.{}, ClientT.run, .{&ca});
    var conn_a = try srv_a.acceptOne(testing.allocator, test_hello);
    ta.join();
    conn_a.deinit();
    const tb = try std.Thread.spawn(.{}, ClientT.run, .{&cb});
    var conn_b = try srv_b.acceptOne(testing.allocator, test_hello);
    tb.join();
    conn_b.deinit();

    try testing.expect(ca.ok);
    try testing.expect(cb.ok);
}

test {
    testing.refAllDecls(@This());
}
