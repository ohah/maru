//! control_socket — 세션 컨트롤 플레인 L4 unix domain socket 부트스트랩 (Track C slice 1b).
//! 단일 출처: docs/control-plane-protocol.md §4.1(hello)·§4.2(발견·stale·flock)·§8.2(권한·peer-cred)·§11(1b gate)·§16(위치).
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
const sess = maru.cli.sessions; // A2a: client wire(buildRequestBytes/renderResponse) — 왕복 테스트가 실 client 경로를 탄다.

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

/// 컨트롤 디렉터리 경로 `<base>/control`(§4.2 "~/.cache/maru/control/"). base는 caller가 정한다(테스트=격리 tmp,
/// 제품=~/.cache/maru). 이 순수 함수는 base를 모르는 채 조합만 한다(OS 상태 없음). NUL 종단(mkdir/chmod/fstatat용).
pub fn controlDirPath(buf: []u8, base: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/control", .{maru.path_shape.trimTrailingSep(base)});
}

/// 소켓 경로 `<dir>/<key>.sock`(NUL 종단 — bind가 C 문자열을 요구).
pub fn socketPathIn(buf: []u8, dir: []const u8, key: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}.sock", .{ maru.path_shape.trimTrailingSep(dir), key });
}

/// 라이브니스 lock 경로 `<dir>/<key>.lock`(소켓과 별도 regular 파일 — flock 대상).
pub fn lockPathIn(buf: []u8, dir: []const u8, key: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}.lock", .{ maru.path_shape.trimTrailingSep(dir), key });
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
/// A2b accept-loop 스레드가 응답을 소켓에 쓸 때도 재사용한다(락 밖·소켓 스레드, §5) — 그래서 pub.
pub fn writeAll(fd: c.fd_t, bytes: []const u8) error{WriteFailed}!void {
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

/// 보안 취소에서 partial writer를 즉시 깨운다. fd의 close 소유권은 connection thread에 남겨 fd 재사용
/// 경합을 피하고, shutdown 실패는 이미 닫힌 peer와 동형이라 best-effort로 처리한다.
pub fn shutdownBoth(fd: c.fd_t) void {
    _ = c.shutdown(fd, c.SHUT.RDWR);
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

    /// `pollReady` 결과 3상(§5 accept 스레드 수명). `.ready`=대기 연결 있음(다음 `acceptOne`이 안 막힘), `.timeout`=
    /// 대기 없음/일시적 에러(EINTR 등 — 호출자가 closing 확인 후 재-poll), `.broken`=listen fd가 치명적으로 망가짐
    /// (POLLERR/POLLHUP/POLLNVAL sticky). broken은 회복 불가라 호출자가 재-poll(tight-spin)이 아니라 accept 루프를
    /// **종료**해야 한다 — 예전 bool 반환은 broken을 `.timeout`과 못 구분해 즉시 재-poll → 100% CPU 스핀이었다(#5 방어).
    pub const PollResult = enum { ready, timeout, broken };

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

        // ── 1.5. **다른 인스턴스**의 stale 소켓 회수(§4.2 "flock 회수") — crash/force-quit로 deinit(unlink)이 못 돈
        //  인스턴스가 `<key>.sock`+`<key>.lock`을 남기면, 다음 실행이 새 nonce로 새 소켓을 bind해 dir에 `.sock`이 여럿이
        //  되어 CLI `pickSocket`이 `.multiple`로 접힌다(→ `maru sessions list` 영구 "여러 인스턴스" 고장). self_key(우리
        //  것)는 아래 unlink_and_bind가 따로 처리하므로 제외한다(#1). best-effort. ──
        pruneStaleSockets(gpa, dir, key);

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
        setNoSigPipe(cfd); // 5f-3: 서버-발신 이벤트 write가 닫힌 소켓에 SIGPIPE 대신 EPIPE(프로세스 사망 방지). hello write 전에.

        // peer uid 검증(§8.2) — 파일 권한에만 의존하지 않는 하드 게이트. 불일치면 연결 종료.
        var euid: posix.uid_t = undefined;
        var egid: posix.gid_t = undefined;
        if (getpeereid(cfd, &euid, &egid) != 0) return error.PeerCredFailed;
        if (!peerUidAllowed(self.server_uid, euid)) return error.PeerUidMismatch;

        // hello notification(§4.1): 1a serializeHello + 종단 `\n`. 직렬화는 1a L2가 소유(재구현 금지).
        // **2-write(wire, 그다음 `\n`)**: 응답 경로(serveReadOnly·serveConnection)도 2-write라 일관성을 맞춘다. stream
        // 소켓에서 client의 단일 read가 개행 앞에서 끊길 수 있는 건 맞지만, 그건 프레임 경계 재조립을 client의 `Framer`가
        // 담당하기 때문에 결함이 아니다(실 client=main.zig·cli/sessions는 이미 Framer로 skip-hello). single-write로 원자
        // 전달하려 alloc+memcpy하던 건 응답 경로와 불일치할 뿐 이득이 없어 제거한다(#7). 개행은 별도 write.
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

    /// A2b accept-loop 스레드용: listen fd에 대기 연결이 있는지 `poll(POLLIN)`로 확인한다(blocking accept를 poll로
    /// gate). 반환 `PollResult` 3상(위 참조). **왜 poll gate인가**: blocking `accept`만 쓰면 종료 시 accept 스레드를
    /// 깨우기 위해 self-connect 같은 fragile 트릭이 필요하다. poll timeout으로 주기적으로 깨어나 closing을 확인하면
    /// self-connect 없이 결정론적으로 종료할 수 있다(§5 accept 스레드 수명). 단일 acceptor라 poll-then-accept race는 없다.
    pub fn pollReady(self: *const Server, timeout_ms: i32) PollResult {
        var fds = [_]c.pollfd{.{ .fd = self.listen_fd, .events = c.POLL.IN, .revents = 0 }};
        const rc = c.poll(&fds, 1, timeout_ms);
        if (rc < 0) return .timeout; // 에러(EINTR 등) — 치명 아님, 호출자가 closing 확인 후 재-poll.
        if (rc == 0) return .timeout; // timeout — 대기 연결 없음, 재-poll.
        const revents = fds[0].revents;
        if (revents & c.POLL.IN != 0) return .ready;
        // rc>0인데 POLLIN 없음 = 치명 revent(POLLERR|POLLHUP|POLLNVAL sticky) → listen fd 회복 불가. 호출자가 재-poll하면
        // 같은 revent가 매번 즉시 반환돼 tight-spin(100% CPU)이 되므로 broken을 구분해 accept 루프를 종료하게 한다(#5).
        if (revents & (c.POLL.ERR | c.POLL.HUP | c.POLL.NVAL) != 0) return .broken;
        return .timeout; // 그 밖(이론상 도달 불가한 revent) — 안전하게 재-poll로 접는다.
    }
};

/// accepted 연결 fd에 read 타임아웃(SO_RCVTIMEO)을 건다(§5 accept 스레드가 serial serve). **왜 필요한가**: 단일
/// accept 스레드가 연결을 순차 처리하므로, 요청을 안 보내는 stuck client가 있으면 그 스레드가 read에서 영영 막혀
/// (a) 다른 클라이언트 요청과 (b) 종료 시 accept 스레드 join이 무한 대기가 된다. 타임아웃은 "serial serve + 깨끗한
/// join" 계약의 correctness 요건이다(투기적 방어 아님). 실패는 무시(best-effort — 타임아웃 없이도 정상 client는 동작).
pub fn setReadTimeoutMs(fd: c.fd_t, ms: u32) void {
    var tv = posix.timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, &tv, @sizeOf(posix.timeval));
}

/// accepted 연결 fd에 `SO_NOSIGPIPE`를 건다(5f-3 서버 SIGPIPE 방어). **왜 필요한가**: 5f-3부터 writer 스레드가 요청 없이도
/// **서버-발신 이벤트**(browser.navigated/loadState/dialog/…)를 push하는데, 구독한 client가 이벤트 수집 후 연결을 닫으면
/// 다음 write(2)가 **SIGPIPE**를 올려 프로세스가 죽는다(응답만 있던 5e까진 client가 항상 응답을 읽고 닫아 write-to-closed가
/// 없었다). SO_NOSIGPIPE면 그 write가 SIGPIPE 대신 EPIPE를 돌려주고 `writeAll`이 `WriteFailed`로 접어 writer가 outbound를
/// close(연결 teardown)한다. best-effort(실패 무시). acceptOne이 accept 직후 건다(hello·응답·이벤트 write 전부 보호).
pub fn setNoSigPipe(fd: c.fd_t) void {
    // SO_NOSIGPIPE는 **Darwin 전용**(Linux는 send()의 MSG_NOSIGNAL로 처리). 이 파일은 macOS 런타임 전용이나 `zig build test`가
    // app_host_abi를 native(Linux) 컴파일하므로, comptime os 가드로 비-macOS서 c.SO.NOSIGPIPE 심볼 미해석(dead branch 미분석).
    if (builtin.os.tag == .macos) {
        var on: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &on, @sizeOf(c_int));
    }
}

/// accepted 연결 fd에 write 타임아웃(SO_SNDTIMEO)을 건다 — read 타임아웃과 **대칭**인 correctness 요건(#2). **왜
/// 필요한가**: accept 스레드가 응답을 `writeAll`할 때, 응답을 안 읽어 커널 송신 버퍼를 채운 same-uid client가 있으면
/// write(2)가 영영 막혀 read 타임아웃과 똑같이 (a) 다른 client와 (b) 종료 시 join이 무한 대기가 된다(제어면 정지 →
/// Cmd+Q 프리즈). 타임아웃 만료 시 write가 EAGAIN을 돌려주고 `writeAll`이 그걸 `WriteFailed`로 접어(부분 write 후에도
/// 결국 EAGAIN) accept 스레드가 그 연결을 abandon한다 — 무한 블록 없음. 실패는 무시(best-effort). serveConnection이
/// read 타임아웃과 함께 accept 직후 건다.
pub fn setWriteTimeoutMs(fd: c.fd_t, ms: u32) void {
    var tv = posix.timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDTIMEO, &tv, @sizeOf(posix.timeval));
}

/// 컨트롤 dir(`dir_path`)에서 **다른 인스턴스**의 stale 소켓을 회수한다(§4.2 "flock 회수", #1). 메커니즘은 bind의 stale
/// 판별(§8.2)과 동일하다: 각 `<key>.sock`(단, `self_key`는 제외 — 그건 bind의 `unlink_and_bind`가 처리)에 대응하는
/// `<key>.lock`을 O_CREAT 없이 열어 non-blocking `flock(EX|NB)`을 시도한다 —
///  - 취득 성공 = 소유 인스턴스 부재(프로세스 종료로 그 fd가 닫혀 flock이 자동 해제됨) → 그 `.sock`+`.lock`을 unlink,
///  - 취득 실패(EWOULDBLOCK) = 살아있는 인스턴스가 홀드 중 → **보존**(우린 소켓을 절대 지우지 않는다).
///  - `.lock` 파일이 없음(ENOENT) = liveness 증거 부재(우리 bind는 소켓보다 lock을 먼저 만든다) → 고아 `.sock` unlink.
/// unlink 직후 fd를 닫아 우리가 잡았던 transient flock을 해제한다. readdir 중 unlink는 POSIX상 미정의라 key를 먼저 모은
/// 뒤(pass 1) 처리한다(pass 2). best-effort — dir 열기·readdir·open 실패는 조용히 스킵(prune 없이도 앱은 동작; 최악은
/// CLI가 여전히 `.multiple`로 접힘). L4(readdir·flock·unlink syscall).
pub fn pruneStaleSockets(gpa: std.mem.Allocator, dir_path: [:0]const u8, self_key: []const u8) void {
    const dir = c.opendir(dir_path.ptr) orelse return;
    defer _ = c.closedir(dir);

    // pass 1: `.sock` 엔트리의 key를 모은다(readdir 중 unlink는 미정의 — POSIX).
    var keys: std.ArrayList([]u8) = .empty;
    defer {
        for (keys.items) |k| gpa.free(k);
        keys.deinit(gpa);
    }
    while (c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(ent.name[0..], 0);
        if (!std.mem.endsWith(u8, name, ".sock")) continue; // `.lock`·`.`/`..`·그 밖 파일 무시.
        const key = name[0 .. name.len - ".sock".len];
        if (key.len == 0 or std.mem.eql(u8, key, self_key)) continue; // 우리 소켓은 bind가 따로 처리.
        keys.append(gpa, gpa.dupe(u8, key) catch continue) catch continue; // OOM이면 이 항목만 스킵(best-effort).
    }

    // pass 2: 각 key의 lock을 flock으로 liveness 판별해 stale이면 소켓+lock 회수.
    for (keys.items) |key| {
        var lp_buf: [512]u8 = undefined;
        const lp = lockPathIn(&lp_buf, dir_path, key) catch continue;
        var sp_buf: [512]u8 = undefined;
        const sp = socketPathIn(&sp_buf, dir_path, key) catch continue;
        const lfd = c.open(lp.ptr, .{ .ACCMODE = .RDWR }, @as(c.mode_t, 0)); // O_CREAT 없음 — 고아 lock 생성 방지.
        if (lfd < 0) {
            _ = c.unlink(sp.ptr); // lock 부재 = 살아있는 소유자 없음(bind는 lock을 소켓보다 먼저 만든다) → 고아 회수.
            continue;
        }
        defer _ = c.close(lfd); // 취득 여부와 무관하게 fd를 닫아 우리 transient flock 해제.
        if (c.flock(lfd, posix.LOCK.EX | posix.LOCK.NB) == 0) {
            // 취득 = 소유 인스턴스 부재 → stale. 소켓+lock 둘 다 회수(살아있으면 여기 도달 안 함).
            _ = c.unlink(sp.ptr);
            _ = c.unlink(lp.ptr);
        }
    }
}

// ══ per-connection read-only serve(Track C A2a) ══════════════════════════════════════════════════════════════
// 한 연결의 요청 1개를 **동기** 처리하는 재사용 단위: `readInto`로 요청 프레임(1a `Framer`)을 조립 → 1d
// `dispatchReadOnly` → 응답 바이트 + 종단 `\n`을 conn에 write. **A2b의 accept-loop 스레드**가 `acceptOne`(hello)
// 뒤에 연결마다 이 함수를 부른다(그 스레드·메인 marshal(§5)은 A2a 범위 밖). `snapshot`·`caller_surface_id`·`scope`는
// **주입**이다 — A2b가 실 collector(A1 `collectSessionInto`)·capability auth(1e)·self-origin(1g)이 발급한 값으로
// 채운다(여긴 판정하지 않는다). read-only 조회는 요청 1개 = 응답 1개라 완결 프레임 하나만 처리하고 반환한다
// (EOF면 처리 없이 반환). 프레이밍/에러 모델은 1a, 라우팅/scope는 1d가 단일 출처 — 여기서 재구현하지 않는다.

pub const ServeError = error{ ReadFailed, WriteFailed, OutOfMemory };

pub fn serveReadOnly(
    conn: Connection,
    gpa: std.mem.Allocator,
    snapshot: cs.CollectorSnapshot,
    caller_surface_id: u64,
    scope: wm.MetadataScope,
) ServeError!void {
    var framer: cp.Framer = .{};
    defer framer.deinit(gpa);
    while (true) {
        const maybe_line = framer.next() catch {
            // §4.3: frame이 max를 초과하면 payload-too-large 응답 후 반환한다(연결 종료는 caller/accept-loop 몫).
            return writeErrorResponse(conn.fd, gpa, .payload_too_large);
        };
        if (maybe_line) |line| {
            // 주입 snapshot/caller/scope로 1d 라우터에 위임(바이트→바이트). OOM만 전파, 나머지는 라우터가 에러 응답으로 접는다.
            const response = cd.dispatchReadOnly(gpa, line, snapshot, caller_surface_id, scope) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            defer gpa.free(response);
            try writeAll(conn.fd, response);
            try writeAll(conn.fd, "\n");
            return;
        }
        const n = conn.readInto(gpa, &framer) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
        };
        if (n == 0) return; // EOF — peer가 완결 요청 없이 닫음(처리할 것 없음).
    }
}

/// 코드의 default message로 에러 응답 한 줄(+종단 `\n`)을 conn에 쓴다(1a `serializeErrorDefault` 재사용 — id 파싱 전
/// 거부 응답의 단일 출처, 19차 [5]). serveReadOnly의 payload-too-large 경로 편의. A2b `control_server.readFrame`은 소켓
/// 직접 write가 아니라 **outbound 큐에 push**하므로 이 함수가 아니라 같은 `cp.serializeErrorDefault`를 직접 호출한다(단일
/// 출처는 바이트 직렬화 헬퍼이지 이 write 래퍼가 아님 — writer 스레드와의 단일 writer 불변 때문).
pub fn writeErrorResponse(fd: c.fd_t, gpa: std.mem.Allocator, code: cp.ErrorCode) ServeError!void {
    const bytes = cp.serializeErrorDefault(gpa, code) catch return error.OutOfMemory;
    defer gpa.free(bytes);
    try writeAll(fd, bytes);
    try writeAll(fd, "\n");
}

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

/// 테스트 헬퍼: fd에서 완결 프레임 한 줄이 조립될 때까지 read 루프(1a `Framer`). hello가 2-write(wire, `\n`)라 단일
/// read가 개행 앞에서 끊길 수 있으므로(실 client는 이미 Framer로 재조립), 프레임 경계는 이 헬퍼로 재조립한다(#7).
/// owned 반환(caller free). 완결 프레임 없이 EOF면 error.NoFrame.
fn readOneFrame(gpa: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    var framer: cp.Framer = .{};
    defer framer.deinit(gpa);
    var guard: usize = 0;
    while (guard < 200) : (guard += 1) {
        if (try framer.next()) |line| return gpa.dupe(u8, line);
        var rb: [1024]u8 = undefined;
        const n = c.read(fd, &rb, rb.len);
        if (n <= 0) break;
        try framer.push(gpa, rb[0..@intCast(n)]);
    }
    return error.NoFrame;
}

test "socket: bind→connect→hello 왕복 — accept가 hello notification을 보내고 client가 Framer로 파싱" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
            // hello는 2-write(wire, `\n`)라 완결 프레임까지 개행이 보일 때까지 누적 read(부분 read 대비, #7).
            while (self.got_len < self.got.len) {
                const n = c.read(fd, self.got[self.got_len..].ptr, self.got.len - self.got_len);
                if (n < 0) {
                    self.err = error.ClientRead;
                    return;
                }
                if (n == 0) break;
                self.got_len += @intCast(n);
                if (std.mem.indexOfScalar(u8, self.got[0..self.got_len], '\n') != null) break;
            }
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
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
            // hello 2-write(wire, `\n`)를 완결 프레임까지 누적 read(#7) — "정확히 한 줄" 검증이 부분 read에 흔들리지 않게.
            while (self.got_len < self.got.len) {
                const n = c.read(fd, self.got[self.got_len..].ptr, self.got.len - self.got_len);
                if (n <= 0) break;
                self.got_len += @intCast(n);
                if (std.mem.indexOfScalar(u8, self.got[0..self.got_len], '\n') != null) break;
            }
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
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
            // acceptOne deliberately emits hello and its delimiter as two writes. Do not close
            // after the first readable fragment: that races the server's newline write and turns
            // a healthy listener into a spurious EPIPE/WriteFailed.
            while (true) {
                const n = c.read(fd, &rb, rb.len);
                if (n <= 0) return;
                if (std.mem.indexOfScalar(u8, rb[0..@intCast(n)], '\n') != null) {
                    self.ok = true;
                    return;
                }
            }
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
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // 아주 긴 base로 sun_path(104)를 확실히 넘긴다. 실제 mkdir/bind는 시도하지 않아야(순수 판정이 먼저 거부).
    var bb: [512]u8 = undefined;
    var long: [300]u8 = undefined;
    @memset(&long, 'x');
    const base = std.fmt.bufPrint(&bb, "/tmp/{s}", .{long[0..250]}) catch unreachable;
    try testing.expectError(error.SocketPathTooLong, Server.bind(testing.allocator, base, "k1"));
}

test "socket: 부분 read 프레이밍 — 두 write로 쪼갠 프레임이 Framer로 한 줄로 조립(dispatch 없음)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
                // hello 2-write(wire, `\n`)를 완결 프레임(종단 `\n`)까지 누적 read(#7).
                while (self.got_len < self.got.len) {
                    const n = c.read(fd, self.got[self.got_len..].ptr, self.got.len - self.got_len);
                    if (n <= 0) break;
                    self.got_len += @intCast(n);
                    if (std.mem.indexOfScalar(u8, self.got[0..self.got_len], '\n') != null) break;
                }
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
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
            // hello 완결 프레임을 통째로 소비(2-write라 개행이 다음 read로 넘어가면 응답 프레임에 빈 줄이 섞인다, #7).
            const hello = readOneFrame(std.testing.allocator, fd) catch |e| {
                self.err = e;
                return;
            };
            std.testing.allocator.free(hello);
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

    // server: accept(hello 전송) → serveReadOnly(요청 프레임 조립 → 1d 디스패치 → 응답 + 개행 write)로 A2a
    // serve 함수를 dogfood한다. 주입: caller_surface_id=10, scope=all(auth가 발급할 값을 테스트가 주입 — 1d 순수 경계).
    var conn = try srv.acceptOne(testing.allocator, test_hello);
    defer conn.deinit();
    try serveReadOnly(conn, testing.allocator, rt_snapshot, 10, .all);

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

// ── A2a: 실 socket 왕복(client 연결 + serveReadOnly), tmpDir만·~/.cache 미접촉 ───────────────────────────────
//
// 1d 통합(위)이 raw 요청 바이트를 직접 write했다면, A2a는 **실 client wire**(1d `buildRequestBytes`) 전송 →
// `serveReadOnly`(A2a serve 함수) 처리 → 실 client 렌더(1d `renderResponse`) 사람이 읽는 출력까지 왕복한다.
// 이 시퀀스(connect → 요청+`\n` → hello notification skip → 응답 프레임 → render)는 `main.zig runSessionCli`의
// client 경로와 **동형**이다(같은 프레이밍·skip-hello·재사용 함수) — main은 여기에 소켓 발견(discovery)만 얹는다.
// snapshot·caller·scope는 auth(1e)·collector(A1/A2b)가 발급할 값을 테스트가 주입한다(A2a 순수 경계).

/// 왕복 테스트용 client: base/key 소켓에 connect → `request_bytes`+`\n` 전송 → hello notification skip → 응답
/// 프레임 한 줄을 owned로 돌려준다(caller free). main.zig client 시퀀스와 동형. hello는 서버가 accept 시 먼저
/// 보내므로 첫 non-notification 프레임이 응답이다(parse로 판별 — 순서에 의존하지 않음).
fn clientRoundTrip(gpa: std.mem.Allocator, base: []const u8, key: []const u8, request_bytes: []const u8) ![]u8 {
    const fd = try connectClient(base, key);
    defer _ = c.close(fd);
    try writeAll(fd, request_bytes);
    try writeAll(fd, "\n");
    var framer: cp.Framer = .{};
    defer framer.deinit(gpa);
    while (true) {
        // 완결 프레임을 소비: hello(notification)는 skip, 그 밖(응답/에러)이면 반환한다.
        while (try framer.next()) |line| {
            var pm = cp.parseMessage(gpa, line) catch return gpa.dupe(u8, line); // 파싱 실패도 그대로 반환(renderResponse가 접는다)
            const is_notif = pm.message == .notification;
            pm.deinit();
            if (!is_notif) return gpa.dupe(u8, line);
        }
        var rb: [1024]u8 = undefined;
        const n = c.read(fd, &rb, rb.len);
        if (n <= 0) break;
        try framer.push(gpa, rb[0..@intCast(n)]);
    }
    return error.NoResponse;
}

/// 왕복 테스트 공통 스캐폴드: base/key에 Server를 세우고, client 스레드가 `req_bytes`를 보내 응답을 렌더한 뒤,
/// 메인 스레드가 `acceptOne`(hello) + `serveReadOnly`(caller/scope 주입)로 처리한다. 렌더된 출력을 `out`에 담는다.
const RoundTripHarness = struct {
    fn run(base: []const u8, req_bytes: []const u8, kind: sess.ResponseKind, snapshot: cs.CollectorSnapshot, caller: u64, scope: wm.MetadataScope, out: *std.ArrayList(u8)) !void {
        const gpa = testing.allocator;
        var srv = try Server.bind(gpa, base, "k1");
        defer srv.deinit();

        const ClientT = struct {
            base: []const u8,
            req: []const u8,
            kind: sess.ResponseKind,
            rendered: std.ArrayList(u8) = .empty,
            err: ?anyerror = null,
            fn go(self: *@This()) void {
                self.render() catch |e| {
                    self.err = e;
                };
            }
            fn render(self: *@This()) !void {
                const a = testing.allocator;
                const resp = try clientRoundTrip(a, self.base, "k1", self.req);
                defer a.free(resp);
                var aw: std.Io.Writer.Allocating = .init(a);
                defer aw.deinit();
                try sess.renderResponse(a, resp, self.kind, &aw.writer);
                try self.rendered.appendSlice(a, aw.written());
            }
        };
        var ct = ClientT{ .base = base, .req = req_bytes, .kind = kind };
        defer ct.rendered.deinit(gpa);
        const th = try std.Thread.spawn(.{}, ClientT.go, .{&ct});
        var conn = try srv.acceptOne(gpa, test_hello);
        defer conn.deinit();
        try serveReadOnly(conn, gpa, snapshot, caller, scope);
        th.join();
        if (ct.err) |e| return e;
        try out.appendSlice(gpa, ct.rendered.items);
    }
};

test "A2a 왕복: buildRequestBytes(sessions.list) → serveReadOnly → renderResponse 사람이 읽는 출력(all scope=10,20)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "a2a-list");
    defer rmTmpBase(base);

    const req = try sess.buildRequestBytes(testing.allocator, .{ .list = .{} }, .{ .number = 1 });
    defer testing.allocator.free(req);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try RoundTripHarness.run(base, req, .list, rt_snapshot, 10, .all, &out);

    const s = out.items;
    // 두 surface가 사람이 읽는 줄로 렌더됐다(10 shell-a, 20 shell-b).
    try testing.expect(std.mem.indexOf(u8, s, "[10]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "shell-a") != null);
    try testing.expect(std.mem.indexOf(u8, s, "cwd=/home/a") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[20]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "shell-b") != null);
    try testing.expect(std.mem.indexOf(u8, s, "*focused*") != null); // 10이 focused
}

test "A2a 왕복: buildRequestBytes(session.get 10) self scope → 단건 Surface 렌더" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "a2a-get");
    defer rmTmpBase(base);

    const req = try sess.buildRequestBytes(testing.allocator, .{ .get = .{ .surface_id = 10 } }, .{ .number = 1 });
    defer testing.allocator.free(req);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try RoundTripHarness.run(base, req, .get, rt_snapshot, 10, .self, &out);

    const s = out.items;
    try testing.expect(std.mem.indexOf(u8, s, "[10]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "shell-a") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[20]") == null); // self scope라 남(20)은 안 보인다
}

test "A2a 왕복 엣지: 미지 method는 serveReadOnly가 에러 응답 → client가 균일 error 줄로 렌더" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "a2a-unknown");
    defer rmTmpBase(base);

    // buildRequestBytes는 list/get만 만들므로 미지 method는 raw 바이트로 보낸다. **라우터가 절대 안 다루는** 미지
    // 메서드를 쓴다(`session.capture`는 1f에서 read-output 요구 메서드로 인식돼 §8.3 unauthorized로 접히므로 더는
    // method_not_found 예시가 아니다 — control_dispatch 1f 변경 반영).
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sessions.nonexistent\"}";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try RoundTripHarness.run(base, req, .get, rt_snapshot, 10, .all, &out);

    const s = out.items;
    try testing.expect(std.mem.indexOf(u8, s, "error:") != null);
    try testing.expect(std.mem.indexOf(u8, s, "-32601") != null); // method_not_found
}

test "A2a 왕복 엣지: 빈 세션 목록 → renderResponse '(no sessions)'" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "a2a-empty");
    defer rmTmpBase(base);

    const empty_s = [_]cs.SurfaceDto{};
    const empty_w = [_]wm.WindowMembershipSnapshot{};
    const empty_snap: cs.CollectorSnapshot = .{ .surfaces = &empty_s, .windows = &empty_w };

    const req = try sess.buildRequestBytes(testing.allocator, .{ .list = .{} }, .{ .number = 1 });
    defer testing.allocator.free(req);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try RoundTripHarness.run(base, req, .list, empty_snap, 10, .all, &out);

    try testing.expect(std.mem.indexOf(u8, out.items, "(no sessions)") != null);
}

test "A2a 왕복 엣지: 부분 read로 쪼갠 요청도 serveReadOnly가 조립해 응답한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "a2a-split");
    defer rmTmpBase(base);

    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit();

    // client가 hello를 버린 뒤 요청 한 줄을 두 조각(부분 read)으로 보낸다.
    const ClientT = struct {
        base: []const u8,
        resp_len: usize = 0,
        resp: [1024]u8 = undefined,
        err: ?anyerror = null,
        fn go(self: *@This()) void {
            const fd = connectClient(self.base, "k1") catch |e| {
                self.err = e;
                return;
            };
            defer _ = c.close(fd);
            const hello = readOneFrame(testing.allocator, fd) catch |e| { // hello 완결 프레임 통째 소비(#7)
                self.err = e;
                return;
            };
            testing.allocator.free(hello);
            const p1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"met";
            const p2 = "hod\":\"sessions.list\"}\n";
            _ = c.write(fd, p1, p1.len);
            std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
            _ = c.write(fd, p2, p2.len);
            // 응답 완결 프레임(종단 `\n`)까지 누적 read.
            while (self.resp_len < self.resp.len) {
                const n = c.read(fd, self.resp[self.resp_len..].ptr, self.resp.len - self.resp_len);
                if (n <= 0) break;
                self.resp_len += @intCast(n);
                if (std.mem.indexOfScalar(u8, self.resp[0..self.resp_len], '\n') != null) break;
            }
        }
    };
    var ct = ClientT{ .base = base };
    const th = try std.Thread.spawn(.{}, ClientT.go, .{&ct});
    var conn = try srv.acceptOne(testing.allocator, test_hello);
    defer conn.deinit();
    try serveReadOnly(conn, testing.allocator, rt_snapshot, 10, .all); // 조각난 요청을 조립해 응답
    th.join();
    try testing.expect(ct.err == null);
    try testing.expect(ct.resp_len > 0);

    // 응답이 sessions.list 결과(10,20)인지 확인.
    var framer: cp.Framer = .{};
    defer framer.deinit(testing.allocator);
    try framer.push(testing.allocator, ct.resp[0..ct.resp_len]);
    const line = (try framer.next()).?;
    var pm = try cp.parseMessage(testing.allocator, line);
    defer pm.deinit();
    try testing.expectEqual(@as(usize, 2), pm.message.response.result.?.array.items.len);
}

test "A2a 왕복 엣지: 여러 연결을 순차로 각각 serveReadOnly가 처리(accept-loop 골격)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "a2a-multi");
    defer rmTmpBase(base);

    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const ClientT = struct {
            base: []const u8,
            ok: bool = false,
            fn go(self: *@This()) void {
                const a = testing.allocator;
                const req = sess.buildRequestBytes(a, .{ .list = .{} }, .{ .number = 1 }) catch return;
                defer a.free(req);
                const resp = clientRoundTrip(a, self.base, "k1", req) catch return;
                defer a.free(resp);
                var pm = cp.parseMessage(a, resp) catch return;
                defer pm.deinit();
                self.ok = pm.message == .response and pm.message.response.result != null;
            }
        };
        var ct = ClientT{ .base = base };
        const th = try std.Thread.spawn(.{}, ClientT.go, .{&ct});
        var conn = try srv.acceptOne(testing.allocator, test_hello);
        try serveReadOnly(conn, testing.allocator, rt_snapshot, 10, .all);
        th.join();
        conn.deinit();
        try testing.expect(ct.ok);
    }
}

test "A2a 엣지: 서버 없는 소켓에 connect하면 client가 깔끔히 실패(graceful 근거 — crash 없음)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "a2a-absent");
    defer rmTmpBase(base);
    // 컨트롤 dir은 있지만 소켓은 없다 → connect가 error로 실패(main은 이를 "인스턴스 없음"으로 접는다).
    var db: [512]u8 = undefined;
    const dir = try controlDirPath(&db, base);
    _ = c.mkdir(dir.ptr, 0o700);
    try testing.expectError(error.ClientConnect, connectClient(base, "nope"));
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
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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
            // hello 2-write(wire, `\n`)를 완결 프레임(종단 `\n`)까지 누적 read(#7).
            var rb: [256]u8 = undefined;
            var got: usize = 0;
            while (got < rb.len) {
                const n = c.read(fd, rb[got..].ptr, rb.len - got);
                if (n <= 0) break;
                got += @intCast(n);
                if (std.mem.indexOfScalar(u8, rb[0..got], '\n') != null) break;
            }
            self.ok = got > 0 and rb[got - 1] == '\n';
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

// ── 적대적 리뷰 반영: #1 stale prune · #2 write timeout · #5 pollReady 3상 ─────────────────────────────────────

test "prune(#1): 다른 인스턴스의 stale 소켓/lock은 회수, 살아있는(flock 보유) 건 보존, self_key는 제외" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "prune");
    defer rmTmpBase(base);
    var db: [512]u8 = undefined;
    const dir = try controlDirPath(&db, base);
    _ = c.mkdir(dir.ptr, 0o700);

    // 파일 잔해를 만들고 존재를 확인하는 로컬 헬퍼(플레인 파일 = stale 소켓/lock 흉내).
    const H = struct {
        fn touch(d: [:0]const u8, key: []const u8, comptime is_sock: bool) void {
            var buf: [512]u8 = undefined;
            const p = (if (is_sock) socketPathIn(&buf, d, key) else lockPathIn(&buf, d, key)) catch return;
            const fd = c.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c.mode_t, 0o600));
            if (fd >= 0) _ = c.close(fd);
        }
        fn exists(d: [:0]const u8, key: []const u8, comptime is_sock: bool) bool {
            var buf: [512]u8 = undefined;
            const p = (if (is_sock) socketPathIn(&buf, d, key) else lockPathIn(&buf, d, key)) catch return false;
            return c.access(p.ptr, @intCast(posix.F_OK)) == 0;
        }
        fn rm(d: [:0]const u8, key: []const u8, comptime is_sock: bool) void {
            var buf: [512]u8 = undefined;
            const p = (if (is_sock) socketPathIn(&buf, d, key) else lockPathIn(&buf, d, key)) catch return;
            _ = c.unlink(p.ptr);
        }
    };

    // stale: 소켓+lock, 아무도 flock 안 잡음 → prune이 둘 다 회수해야.
    H.touch(dir, "stale", true);
    H.touch(dir, "stale", false);
    // self: 소켓+lock — self_key라 prune 대상 밖(bind의 unlink_and_bind가 처리).
    H.touch(dir, "self", true);
    H.touch(dir, "self", false);
    // live: 소켓 + lock에 실제 flock 보유(살아있는 인스턴스 흉내) → 보존해야.
    H.touch(dir, "live", true);
    var lp_buf: [512]u8 = undefined;
    const live_lp = try lockPathIn(&lp_buf, dir, "live");
    const live_fd = c.open(live_lp.ptr, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(c.mode_t, 0o600));
    try testing.expect(live_fd >= 0);
    try testing.expectEqual(@as(c_int, 0), c.flock(live_fd, posix.LOCK.EX | posix.LOCK.NB));

    pruneStaleSockets(testing.allocator, dir, "self");

    try testing.expect(!H.exists(dir, "stale", true)); // stale 소켓 회수
    try testing.expect(!H.exists(dir, "stale", false)); // stale lock 회수
    try testing.expect(H.exists(dir, "self", true)); // self는 제외 → 보존
    try testing.expect(H.exists(dir, "self", false));
    try testing.expect(H.exists(dir, "live", true)); // live는 flock 보유 → 보존
    try testing.expect(H.exists(dir, "live", false));

    _ = c.close(live_fd); // flock 해제
    // 뒤처리(rmTmpBase는 빈 dir만 지운다) — 남은 self/live 잔해 unlink.
    H.rm(dir, "self", true);
    H.rm(dir, "self", false);
    H.rm(dir, "live", true);
    H.rm(dir, "live", false);
}

test "prune(#1): lock 없는 고아 소켓도 회수(liveness 증거 부재)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "prune-orphan");
    defer rmTmpBase(base);
    var db: [512]u8 = undefined;
    const dir = try controlDirPath(&db, base);
    _ = c.mkdir(dir.ptr, 0o700);
    var sb: [512]u8 = undefined;
    const sp = try socketPathIn(&sb, dir, "orphan");
    const fd = c.open(sp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c.mode_t, 0o600)); // 소켓만, lock 없음
    try testing.expect(fd >= 0);
    _ = c.close(fd);
    pruneStaleSockets(testing.allocator, dir, "self");
    try testing.expect(c.access(sp.ptr, @intCast(posix.F_OK)) != 0); // 고아 소켓 회수됨(access 실패)
}

test "timeouts(#2): setReadTimeoutMs/setWriteTimeoutMs가 SO_RCVTIMEO/SO_SNDTIMEO를 실제로 건다(getsockopt 왕복)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    try testing.expect(fd >= 0);
    defer _ = c.close(fd);
    setReadTimeoutMs(fd, 1500);
    setWriteTimeoutMs(fd, 2500);
    var rtv: posix.timeval = undefined;
    var rlen: c.socklen_t = @sizeOf(posix.timeval);
    try testing.expectEqual(@as(c_int, 0), c.getsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, &rtv, &rlen));
    try testing.expectEqual(@as(i64, 1), @as(i64, @intCast(rtv.sec)));
    try testing.expectEqual(@as(i64, 500_000), @as(i64, @intCast(rtv.usec)));
    var wtv: posix.timeval = undefined;
    var wlen: c.socklen_t = @sizeOf(posix.timeval);
    try testing.expectEqual(@as(c_int, 0), c.getsockopt(fd, c.SOL.SOCKET, c.SO.SNDTIMEO, &wtv, &wlen));
    try testing.expectEqual(@as(i64, 2), @as(i64, @intCast(wtv.sec)));
    try testing.expectEqual(@as(i64, 500_000), @as(i64, @intCast(wtv.usec)));
}

test "pollReady(#5) 분기: 대기 연결 없음=timeout, 도착=ready" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "pollready");
    defer rmTmpBase(base);
    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit();
    try testing.expectEqual(Server.PollResult.timeout, srv.pollReady(10)); // 대기 연결 없음
    const fd = try connectClient(base, "k1");
    defer _ = c.close(fd);
    var ready = false;
    var i: usize = 0;
    while (i < 50 and !ready) : (i += 1) {
        if (srv.pollReady(20) == .ready) ready = true;
    }
    try testing.expect(ready); // 연결이 backlog에 들어와 POLLIN
}

test "pollReady(#5): 닫힌 listen fd는 broken(POLLNVAL — 재-poll tight-spin 대신 루프 종료)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var bb: [256]u8 = undefined;
    const base = makeTmpBase(&bb, "pollbroken");
    defer rmTmpBase(base);
    var srv = try Server.bind(testing.allocator, base, "k1");
    defer srv.deinit(); // deinit의 listen_fd 재close는 EBADF 무시
    _ = c.close(srv.listen_fd); // fd를 밖에서 닫아 POLLNVAL 유발
    try testing.expectEqual(Server.PollResult.broken, srv.pollReady(10));
}

test {
    testing.refAllDecls(@This());
}
