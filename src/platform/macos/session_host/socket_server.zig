//! session-host **실 unix domain socket adapter**(§10·§11) — P3-d2a.
//!
//! P3-d1의 순수 `Connection` dispatch state machine을 실제 socket 위에서 구동한다: unix socket을 bind(owner-only
//! 0700 dir + 0600 socket, symlink 위장 방어)하고, accept한 연결의 peer uid를 same-UID로 하드 게이트한 뒤(§11 파일
//! 권한에만 의존하지 않는다), read한 바이트를 `FrameParser`로 조립해 `Connection.handleFrame`을 돌리고 응답을 write한다.
//!
//! **self-contained**: control-plane socket(`control_socket.zig`)과 코드를 공유하지 않는다 — 그건 `maru`(control_plane
//! wire)를 import해 session_host codec의 platform-import-0 순수성을 깨고 경로가 "control" dir에 묶여 있다(§10은 별도
//! "session-host" dir). 그래서 socket syscall 패턴은 참고하되(clean-room), 이 파일은 session_host 자체 codec + `std.c`/
//! `std.posix`만 쓴다. socket path는 caller 주입이다(테스트는 임시 dir, 실 배포 경로/detached launch는 P3-d2b).
//!
//! v1 보안(§11): socket 0600 + dir 0700 + peer-cred same-UID. flock 기반 stale 회수와 socket 발견/on-demand launch는
//! 여러 인스턴스 수명이 걸린 P3-d2b(launch)에서 붙인다. cross-UID·network listener는 v1 비범위다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const reg = @import("registry.zig");
const server_mod = @import("server.zig");
const upgrade = @import("upgrade_coordinator.zig");
const subscription_identity = @import("subscription_identity.zig");

/// peer 프로세스의 effective uid/gid(§11 LOCAL_PEERCRED(macOS·xucred)/SO_PEERCRED(Linux)를 libc가 래핑). std.c
/// 미노출이라 직접 extern. session-host는 uid만 쓴다(same-UID 게이트).
extern "c" fn getpeereid(fd: c.fd_t, euid: *posix.uid_t, egid: *posix.gid_t) c_int;
/// accept-fail backoff용(std.c 미노출). fd 고갈 시 tight-spin을 막는 짧은 sleep.
extern "c" fn usleep(usec: c_uint) c_int;

/// sockaddr_un.sun_path 바이트 용량(macOS 104). 컴파일타임에 읽어 매직넘버를 피한다.
pub const sun_path_cap: usize = @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len;

/// accept 연결의 peer uid가 서버 uid와 같은가(§11). 파일 권한에만 의존하지 않는 하드 게이트.
pub fn peerUidAllowed(server_uid: posix.uid_t, peer_uid: posix.uid_t) bool {
    return server_uid == peer_uid;
}

/// socket path가 sun_path에 종단 NUL 포함해 들어가는가. 어떤 syscall 전에도 순수하게 판정(§11).
pub fn socketPathFits(len: usize) bool {
    return len + 1 <= sun_path_cap;
}

pub const BindError = error{
    SocketPathTooLong,
    ControlDirFailed,
    OwnershipCheckFailed,
    SocketCreateFailed,
    BindFailed,
    ChmodFailed,
    ListenFailed,
};

pub const ServeError = error{WriteFailed};

/// Bound listener/configuration state. `poll_owner.Owner` is the sole authority for accepted
/// connection slots, readiness, subscriptions, and typed upgrade completion.
pub const SocketServer = struct {
    listen_fd: c.fd_t,
    server_uid: posix.uid_t,
    socket_path: [:0]u8,
    socket_dev: posix.dev_t = 0,
    socket_ino: posix.ino_t = 0,
    allocator: std.mem.Allocator,
    host_id: u128,
    registry: *reg.TerminalRuntimeRegistry,
    host_status: server_mod.HostStatus = .{},
    /// host가 실 runtime 소유(spawn/terminate)를 위임하는 vtable(§4). null이면 read-only host(조회만) — daemon이
    /// bind 후 `runtime_manager.runtimeOps()`로 채운다. connection마다 이 값을 그대로 넘겨 spawn/terminate를 라우팅한다.
    runtime_ops: ?server_mod.RuntimeOps = null,
    upgrade_ops: ?@import("upgrade_wire.zig").Ops = null,
    /// U2 host-global admission barrier. 각 complete frame dispatch가 lease 하나를 잡는다.
    admission_gate: ?*upgrade.AdmissionGate = null,
    /// GUI가 연결되지 않았거나 한 connection이 오래 살아 있어도 PTY exit/read-error lifecycle을 전진시키는 owner tick.
    owner_tick_ctx: ?*anyopaque = null,
    owner_tick: ?*const fn (ctx: *anyopaque) void = null,
    subscriptions: subscription_identity.Table,

    pub const backlog: c_uint = 16;

    /// `dir_path`(owner-only 0700)에 `socket_path`(0600)로 unix socket을 bind·listen한다. 경로는 caller 주입.
    /// 순서: dir 0700 보장 + 소유자/타입 검증 → 기존 socket unlink → socket/bind/chmod(0600)/listen →
    /// fstatat(SYMLINK_NOFOLLOW)로 socket이 우리 소유의 0600 socket인지 검증(위장 방어, §11).
    pub fn bind(
        allocator: std.mem.Allocator,
        dir_path: [:0]const u8,
        socket_path: [:0]const u8,
        host_id: u128,
        registry: *reg.TerminalRuntimeRegistry,
    ) BindError!SocketServer {
        if (!socketPathFits(socket_path.len)) return error.SocketPathTooLong;
        const server_uid = c.getuid();

        // dir 0700 + 소유자/타입 검증(다른 uid traverse 차단).
        const mrc = c.mkdir(dir_path.ptr, 0o700);
        if (mrc != 0 and posix.errno(mrc) != .EXIST) return error.ControlDirFailed;
        if (c.chmod(dir_path.ptr, 0o700) != 0) return error.ControlDirFailed;
        var dst: posix.Stat = undefined;
        if (c.fstatat(posix.AT.FDCWD, dir_path.ptr, &dst, posix.AT.SYMLINK_NOFOLLOW) != 0) return error.ControlDirFailed;
        if (!posix.S.ISDIR(dst.mode) or dst.uid != server_uid) return error.OwnershipCheckFailed;

        const owned_path = allocator.dupeZ(u8, socket_path) catch return error.SocketCreateFailed;
        errdefer allocator.free(owned_path);

        // 기존 socket 잔해 unlink(우리 uid dir이라 안전). bind → chmod 0600 → listen.
        _ = c.unlink(owned_path.ptr);
        const lfd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (lfd < 0) return error.SocketCreateFailed;
        errdefer _ = c.close(lfd);
        setCloseOnExec(lfd) catch return error.SocketCreateFailed;
        var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..owned_path.len], owned_path);
        if (c.bind(lfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return error.BindFailed;
        errdefer _ = c.unlink(owned_path.ptr);
        if (c.chmod(owned_path.ptr, 0o600) != 0) return error.ChmodFailed;
        if (c.listen(lfd, backlog) != 0) return error.ListenFailed;

        // 위장 방어: 우리가 만든 0600 socket이 맞는지(symlink/타 uid 위장 차단).
        var st: posix.Stat = undefined;
        if (c.fstatat(posix.AT.FDCWD, owned_path.ptr, &st, posix.AT.SYMLINK_NOFOLLOW) != 0) return error.OwnershipCheckFailed;
        if (!posix.S.ISSOCK(st.mode) or st.uid != server_uid or (st.mode & 0o777) != 0o600) return error.OwnershipCheckFailed;

        return .{
            .listen_fd = lfd,
            .server_uid = server_uid,
            .socket_path = owned_path,
            .socket_dev = st.dev,
            .socket_ino = st.ino,
            .allocator = allocator,
            .host_id = host_id,
            .registry = registry,
            .subscriptions = subscription_identity.Table.init(allocator),
        };
    }

    pub fn deinit(self: *SocketServer) void {
        self.subscriptions.deinit();
        _ = c.close(self.listen_fd);
        _ = c.unlink(self.socket_path.ptr);
        self.allocator.free(self.socket_path);
        self.* = undefined;
    }

    pub fn socketPathZ(self: *const SocketServer) [:0]const u8 {
        return self.socket_path;
    }

    /// Restore activation의 마지막 fallible frontier에서 bound pathname이
    /// 이 listener generation 그대로인지 확인한다.
    pub fn revalidateBoundIdentity(self: *const SocketServer) bool {
        var st: posix.Stat = undefined;
        return c.fstatat(
            posix.AT.FDCWD,
            self.socket_path.ptr,
            &st,
            posix.AT.SYMLINK_NOFOLLOW,
        ) == 0 and
            posix.S.ISSOCK(st.mode) and st.uid == self.server_uid and
            (st.mode & 0o777) == 0o600 and
            st.dev == self.socket_dev and st.ino == self.socket_ino;
    }

    /// 한 연결을 blocking accept한다. peer uid가 서버와 다르면 연결을 닫고 `null`(§11). 성공하면 그 연결의 fd.
    pub fn acceptOne(self: *SocketServer) ?c.fd_t {
        const cfd = while (true) {
            const rc = c.accept(self.listen_fd, null, null);
            if (rc < 0) {
                if (posix.errno(rc) == .INTR) continue;
                // EMFILE/ENFILE 등 fd 고갈: pending 연결이 listen fd를 계속 readable로 둬(pollReady가 즉시 .ready) accept
                // 루프가 100% CPU tight-spin이 된다. 짧게 backoff해 fd가 풀릴 때까지 CPU를 태우지 않는다.
                _ = usleep(10_000);
                return null;
            }
            break rc;
        };
        // 닫힌 소켓으로의 write가 SIGPIPE로 프로세스를 죽이지 않게(EPIPE로).
        setNoSigPipe(cfd);
        setCloseOnExec(cfd) catch {
            _ = c.close(cfd);
            return null;
        };
        var euid: posix.uid_t = undefined;
        var egid: posix.gid_t = undefined;
        if (getpeereid(cfd, &euid, &egid) != 0 or !peerUidAllowed(self.server_uid, euid)) {
            _ = c.close(cfd);
            return null;
        }
        return cfd;
    }

    /// Delta producer cadence used by the sole readiness owner.
    pub const delta_tick_ms: i32 = 20;

    pub fn tickOwner(self: *SocketServer) void {
        if (self.owner_tick) |tick| tick(self.owner_tick_ctx.?);
    }
};

/// 닫힌 소켓 write에 SIGPIPE 대신 EPIPE(프로세스 사망 방지). accept 직후 설정. `SO_NOSIGPIPE`는 macOS/BSD 전용이라
/// comptime으로 gate한다(Linux std.posix.SO엔 없어 참조만으로 컴파일이 깨진다 — dead branch는 분석되지 않는다).
pub fn setNoSigPipe(fd: c.fd_t) void {
    if (builtin.os.tag == .macos) {
        const one: c_int = 1;
        _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, @ptrCast(&one), @sizeOf(c_int));
    }
}

/// Host exec에서 listener/client가 우발적으로 target image에 상속되지 않게 모든 socket은 생성 즉시 CLOEXEC다.
pub fn setCloseOnExec(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    if (c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0) return error.FcntlFailed;
}

/// 짧은 write를 이어 붙여 전량 전송(부분 write는 정상). EINTR 재시도, EPIPE/오류는 `WriteFailed`.
pub fn writeAll(fd: c.fd_t, bytes: []const u8) ServeError!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

const testing = std.testing;

test "socket server: accepted client fd is CLOEXEC before protocol dispatch" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-cloexec-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch return error.SkipZigTest;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var srv = try SocketServer.bind(allocator, dir_path, socket_path, 1, &registry);
    defer {
        srv.deinit();
        _ = c.rmdir(dir_path.ptr);
    }
    const client_fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (client_fd < 0) return error.SkipZigTest;
    defer _ = c.close(client_fd);
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);
    try testing.expect(c.connect(client_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) == 0);
    const accepted = srv.acceptOne() orelse return error.TestUnexpectedResult;
    defer _ = c.close(accepted);
    const flags = c.fcntl(accepted, c.F.GETFD, @as(c_int, 0));
    try testing.expect(flags >= 0 and flags & c.FD_CLOEXEC != 0);
}

test "socket server: bind rejects an over-long socket path before any syscall" {
    const allocator = testing.allocator;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var long_buf: [200]u8 = undefined;
    @memset(&long_buf, 'a');
    long_buf[199] = 0;
    const too_long: [:0]const u8 = long_buf[0..199 :0];
    try testing.expectError(error.SocketPathTooLong, SocketServer.bind(allocator, "/tmp", too_long, 1, &registry));
}

test "socket server: peerUidAllowed / socketPathFits pure gates" {
    try testing.expect(peerUidAllowed(501, 501));
    try testing.expect(!peerUidAllowed(501, 0));
    try testing.expect(socketPathFits(10));
    try testing.expect(!socketPathFits(sun_path_cap)); // 종단 NUL 자리 없음
}
