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
/// sockaddr_un.sun_path 바이트 용량(macOS 104). 컴파일타임에 읽어 매직넘버를 피한다.
pub const sun_path_cap: usize = @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len;

/// accept 연결의 peer uid가 서버 uid와 같은가(§11). 파일 권한에만 의존하지 않는 하드 게이트.
pub fn peerUidAllowed(server_uid: posix.uid_t, peer_uid: posix.uid_t) bool {
    return server_uid == peer_uid;
}

pub const PeerCredentialProvider = struct {
    ctx: ?*anyopaque = null,
    get: *const fn (?*anyopaque, c.fd_t, *posix.uid_t, *posix.gid_t) c_int = osGetPeerCredentials,

    fn read(
        self: PeerCredentialProvider,
        fd: c.fd_t,
        euid: *posix.uid_t,
        egid: *posix.gid_t,
    ) c_int {
        return self.get(self.ctx, fd, euid, egid);
    }
};

pub const AcceptResult = union(enum) {
    accepted: c.fd_t,
    would_block,
    fd_exhausted,
    denied,
    failed,
};

pub const AcceptErrorClass = enum {
    interrupted,
    would_block,
    fd_exhausted,
    failed,
};

const AcceptAttempt = union(enum) {
    accepted: c.fd_t,
    failed: posix.E,
};

const AcceptProvider = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (?*anyopaque, c.fd_t) AcceptAttempt = osAccept,
};

fn osAccept(_: ?*anyopaque, listen_fd: c.fd_t) AcceptAttempt {
    const rc = c.accept(listen_fd, null, null);
    return if (rc >= 0) .{ .accepted = rc } else .{ .failed = posix.errno(rc) };
}

pub fn classifyAcceptError(err: posix.E) AcceptErrorClass {
    return switch (err) {
        .INTR => .interrupted,
        .AGAIN => .would_block,
        .MFILE, .NFILE => .fd_exhausted,
        else => .failed,
    };
}

fn osGetPeerCredentials(
    _: ?*anyopaque,
    fd: c.fd_t,
    euid: *posix.uid_t,
    egid: *posix.gid_t,
) c_int {
    return getpeereid(fd, euid, egid);
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
    /// Optional daemon-global PTY-output self-pipe. The poll owner alone drains it and then invokes
    /// `owner_tick`; reader threads never enter socket/server state.
    owner_wake_fd: c.fd_t = -1,
    owner_wake_ctx: ?*anyopaque = null,
    owner_wake_drain: ?*const fn (ctx: *anyopaque) bool = null,
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
        // 이 adapter의 실제 bind 경로는 macOS 전용이다. Linux CI는 위의 syscall-free path preflight와
        // protocol/boundary 테스트를 위해 모듈을 컴파일하지만 Zig 0.16의 std.c.fstatat은 Linux에서
        // 의도적으로 노출되지 않는다. 비-macOS에서는 syscall을 분석하거나 실행하지 않고 typed 실패로 닫는다.
        if (comptime builtin.os.tag != .macos) return error.SocketCreateFailed;
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
        setNonBlocking(lfd) catch return error.SocketCreateFailed;
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

    /// Poll readiness 뒤 한 연결만 nonblocking accept한다. readiness가 다른 owner에 의해 소비됐거나 연결이
    /// 취소된 `EAGAIN`은 정상 yield다. peer uid가 서버와 다르면 연결을 닫고 `null`(§11).
    pub fn acceptOne(self: *SocketServer) ?c.fd_t {
        return switch (self.acceptOneResult()) {
            .accepted => |fd| fd,
            else => null,
        };
    }

    pub fn acceptOneResult(self: *SocketServer) AcceptResult {
        return self.acceptOneResultWithCredentials(.{});
    }

    fn acceptOneResultWithCredentials(
        self: *SocketServer,
        peer_credentials: PeerCredentialProvider,
    ) AcceptResult {
        return self.acceptOneResultWithProviders(peer_credentials, .{});
    }

    fn acceptOneResultWithProviders(
        self: *SocketServer,
        peer_credentials: PeerCredentialProvider,
        accept_provider: AcceptProvider,
    ) AcceptResult {
        const raw = acceptRaw(self.listen_fd, accept_provider);
        const cfd = switch (raw) {
            .accepted => |fd| fd,
            else => return raw,
        };
        var owned = true;
        defer {
            if (owned) _ = c.close(cfd);
        }
        setNonBlocking(cfd) catch return .failed;
        // 닫힌 소켓으로의 write가 SIGPIPE로 프로세스를 죽이지 않게(EPIPE로).
        setNoSigPipe(cfd);
        setCloseOnExec(cfd) catch return .failed;
        var euid: posix.uid_t = undefined;
        var egid: posix.gid_t = undefined;
        if (peer_credentials.read(cfd, &euid, &egid) != 0 or !peerUidAllowed(self.server_uid, euid))
            return .denied;
        owned = false;
        return .{ .accepted = cfd };
    }

    fn acceptRaw(listen_fd: c.fd_t, provider: AcceptProvider) AcceptResult {
        var interrupted: u8 = 0;
        while (interrupted < max_accept_interrupt_retries) : (interrupted += 1) {
            switch (provider.call(provider.ctx, listen_fd)) {
                .accepted => |fd| return .{ .accepted = fd },
                .failed => |err| switch (classifyAcceptError(err)) {
                    .interrupted => continue,
                    .would_block => return .would_block,
                    .fd_exhausted => return .fd_exhausted,
                    .failed => return .failed,
                },
            }
        }
        return .failed;
    }

    /// Delta producer cadence used by the sole readiness owner.
    pub const delta_tick_ms: i32 = 20;

    pub fn tickOwner(self: *SocketServer) void {
        if (self.owner_tick) |tick| tick(self.owner_tick_ctx.?);
    }

    /// 선언이 바뀐 runtime 들을 **이 tick 에 한 번씩** 조정한다(S11-6).
    ///
    /// tick 에 두는 것이 「폭풍을 합친다」다 — 회전 애니메이션처럼 선언이 연달아 와도 리사이즈는
    /// tick 당 한 번이고, 값이 그대로면 `applyViewportCols` 가 `changed=false` 로 접는다.
    ///
    /// **PTY 를 먼저 바꾸고 나서 registry 에 적는다.** 반대로 하면 PTY 가 실패했을 때 registry 만
    /// 줄어 둘이 갈린다. 실패하면 아무것도 안 적고 넘어간다 — dirty 는 이미 내려갔으므로 다음
    /// 선언이나 detach 가 다시 세운다.
    pub fn sampleMetadataSources(self: *SocketServer, now_ns: u64) void {
        const ops = self.runtime_ops orelse return;
        if (ops.sample_metadata_sources) |sample| sample(ops.ctx, now_ns);
    }

    pub fn drainOwnerWake(self: *SocketServer) bool {
        const drain = self.owner_wake_drain orelse return false;
        return drain(self.owner_wake_ctx.?);
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

pub const max_accept_interrupt_retries: u8 = 4;

/// The listener belongs to a poll owner, so accept must never block after a stale readiness edge.
pub fn setNonBlocking(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (flags < 0) return error.FcntlFailed;
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking) < 0) return error.FcntlFailed;
}

pub fn setBlocking(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (flags < 0) return error.FcntlFailed;
    if (c.fcntl(fd, c.F.SETFL, flags & ~nonblocking) < 0) return error.FcntlFailed;
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
    const status_flags = c.fcntl(accepted, c.F.GETFL, @as(c_int, 0));
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try testing.expect(flags >= 0 and flags & c.FD_CLOEXEC != 0);
    try testing.expect(status_flags >= 0 and status_flags & nonblocking != 0);
}

test "socket server: listener is CLOEXEC and nonblocking; empty accept yields" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-listener-flags-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch
        return error.SkipZigTest;
    var registry = reg.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var srv = try SocketServer.bind(allocator, dir_path, socket_path, 1, &registry);
    defer {
        srv.deinit();
        _ = c.rmdir(dir_path.ptr);
    }

    const descriptor_flags = c.fcntl(srv.listen_fd, c.F.GETFD, @as(c_int, 0));
    const status_flags = c.fcntl(srv.listen_fd, c.F.GETFL, @as(c_int, 0));
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    try testing.expect(descriptor_flags >= 0 and descriptor_flags & c.FD_CLOEXEC != 0);
    try testing.expect(status_flags >= 0 and status_flags & nonblocking != 0);
    try testing.expectEqual(@as(?c.fd_t, null), srv.acceptOne());
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
    try testing.expectEqual(AcceptErrorClass.interrupted, classifyAcceptError(.INTR));
    try testing.expectEqual(AcceptErrorClass.would_block, classifyAcceptError(.AGAIN));
    try testing.expectEqual(AcceptErrorClass.fd_exhausted, classifyAcceptError(.MFILE));
    try testing.expectEqual(AcceptErrorClass.fd_exhausted, classifyAcceptError(.NFILE));
    try testing.expectEqual(AcceptErrorClass.failed, classifyAcceptError(.BADF));
}

test "socket server: accept EINTR retries are exact and fd pressure stays typed" {
    const Interrupts = struct {
        count: usize = 0,

        fn call(ctx: ?*anyopaque, _: c.fd_t) AcceptAttempt {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.count += 1;
            return .{ .failed = .INTR };
        }
    };
    var interrupts: Interrupts = .{};
    try testing.expectEqual(
        AcceptResult.failed,
        SocketServer.acceptRaw(-1, .{ .ctx = &interrupts, .call = Interrupts.call }),
    );
    try testing.expectEqual(@as(usize, max_accept_interrupt_retries), interrupts.count);

    const InterruptedThenAccepted = struct {
        count: usize = 0,

        fn call(ctx: ?*anyopaque, _: c.fd_t) AcceptAttempt {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.count += 1;
            return if (self.count < 3) .{ .failed = .INTR } else .{ .accepted = 42 };
        }
    };
    var eventual: InterruptedThenAccepted = .{};
    const accepted = SocketServer.acceptRaw(
        -1,
        .{ .ctx = &eventual, .call = InterruptedThenAccepted.call },
    );
    try testing.expectEqual(@as(c.fd_t, 42), accepted.accepted);
    try testing.expectEqual(@as(usize, 3), eventual.count);

    const Exhausted = struct {
        fn call(_: ?*anyopaque, _: c.fd_t) AcceptAttempt {
            return .{ .failed = .MFILE };
        }
    };
    try testing.expectEqual(
        AcceptResult.fd_exhausted,
        SocketServer.acceptRaw(-1, .{ .call = Exhausted.call }),
    );
}

test "socket server: injected other UID is rejected before fd admission" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const OtherUid = struct {
        fn get(
            _: ?*anyopaque,
            _: c.fd_t,
            euid: *posix.uid_t,
            egid: *posix.gid_t,
        ) c_int {
            euid.* = c.getuid() +% 1;
            egid.* = 0;
            return 0;
        }
    };

    const allocator = testing.allocator;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-sh-other-uid-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    var sp_buf: [320]u8 = undefined;
    const socket_path = std.fmt.bufPrintZ(&sp_buf, "{s}/control.sock", .{dir_path}) catch
        return error.SkipZigTest;
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
    try testing.expectEqual(
        AcceptResult.denied,
        srv.acceptOneResultWithCredentials(.{ .get = OtherUid.get }),
    );
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), c.read(client_fd, &byte, byte.len));
}

/// 조정 한 건의 결과. caller 가 이것을 받아 구독자에게 `runtime.resized` 를 알린다.
pub const ViewportReconciled = struct {
    runtime_id: u128,
    cols: u16,
    rows: u16,
    resize_generation: u64,
};

/// 선언이 바뀐 runtime 을 **하나** 조정한다(S11-6). 더 없으면 `null`.
///
/// `SocketServer` 를 안 걸쳐 판정자가 registry 와 ops 만으로 잰다. **알리는 일은 여기서 안 한다** —
/// 구독자에게 프레임을 넣으려면 client 표가 필요하고 그것은 poll owner 가 든다.
pub fn reconcileOneViewport(
    registry: *reg.TerminalRuntimeRegistry,
    ops: server_mod.RuntimeOps,
) ?ViewportReconciled {
    while (registry.takeDirtyViewport()) |id| {
        const plan = registry.planViewport(id) catch continue;
        const cols = switch (plan) {
            .unchanged => continue,
            .resize_cols => |value| value,
        };
        const entry = registry.get(id) orelse continue;
        // **적용할 수 있는지 먼저 본다.** PTY 를 바꾼 뒤에 커밋이 실패하면 둘이 갈린다 — 「PTY
        // 먼저」 규율이 지키려던 것을 정확히 뒤집는다(적대적 검증 4회차).
        registry.viewportColsApplicable(id, cols) catch continue;
        // **PTY 를 먼저 바꾸고 나서 registry 에 적는다.** 반대로 하면 PTY 가 실패했을 때 registry 만
        // 줄어 둘이 갈린다.
        ops.resize(ops.ctx, id, cols, entry.rows) catch continue;
        const applied = registry.applyViewportCols(id, cols) catch continue;
        if (!applied.changed) continue;
        return .{
            .runtime_id = id,
            .cols = applied.cols,
            .rows = applied.rows,
            .resize_generation = applied.resize_generation,
        };
    }
    return null;
}

/// 판정자용 편의 — 알림 없이 끝까지 조정한다.
pub fn reconcileViewportsWith(
    registry: *reg.TerminalRuntimeRegistry,
    ops: server_mod.RuntimeOps,
) void {
    while (reconcileOneViewport(registry, ops) != null) {}
}

test "S11-6 tick 이 선언을 실제 크기로 옮기고, 폰이 떠나면 되돌린다" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    const entry = try registry.register(1, 80, 24);
    var fake: server_mod.FakeRuntimeOps = .{};
    const ops = fake.ops();

    // 선언이 없으면 tick 은 아무 일도 안 한다 — 이 기능이 없던 때와 같다.
    reconcileViewportsWith(&registry, ops);
    try testing.expectEqual(@as(u16, 0), fake.resized_cols);
    try testing.expectEqual(@as(u16, 80), entry.cols);

    _ = try registry.attachSubscription(1, .{ .value = 7 }, .observer);
    _ = try registry.declareViewportSubscription(1, .{ .value = 7 }, 50, 37);
    reconcileViewportsWith(&registry, ops);
    // **PTY 가 줄었고 registry 도 같은 값이다.**
    try testing.expectEqual(@as(u16, 50), fake.resized_cols);
    try testing.expectEqual(@as(u16, 24), fake.resized_rows); // 행은 안 건드린다.
    try testing.expectEqual(@as(u16, 50), entry.cols);

    // 같은 tick 을 또 돌려도 다시 안 부른다.
    fake.resized_cols = 0;
    reconcileViewportsWith(&registry, ops);
    try testing.expectEqual(@as(u16, 0), fake.resized_cols);

    // 폰이 떠나면 기준으로 돌아온다.
    _ = try registry.detachSubscription(1, .{ .value = 7 });
    reconcileViewportsWith(&registry, ops);
    try testing.expectEqual(@as(u16, 80), fake.resized_cols);
    try testing.expectEqual(@as(u16, 80), entry.cols);
}

test "S11-6 tick: 폭풍이 와도 리사이즈는 한 번, 마지막 값으로" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    const entry = try registry.register(1, 80, 24);
    var fake: server_mod.FakeRuntimeOps = .{};
    const ops = fake.ops();
    _ = try registry.attachSubscription(1, .{ .value = 7 }, .observer);

    // 회전 애니메이션처럼 한 tick 안에 선언이 연달아 온다.
    _ = try registry.declareViewportSubscription(1, .{ .value = 7 }, 60, 40);
    _ = try registry.declareViewportSubscription(1, .{ .value = 7 }, 50, 37);
    _ = try registry.declareViewportSubscription(1, .{ .value = 7 }, 44, 30);
    reconcileViewportsWith(&registry, ops);
    // **마지막 값 하나로 한 번만** — 중간 값들이 PTY 에 닿지 않는다.
    try testing.expectEqual(@as(u16, 44), fake.resized_cols);
    try testing.expectEqual(@as(u16, 44), entry.cols);
    try testing.expectEqual(@as(u64, 1), entry.resize_generation);
}

test "S11-6 tick: PTY 가 실패하면 registry 를 안 바꾼다 — 둘이 갈리면 안 된다" {
    var registry = reg.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    const entry = try registry.register(1, 80, 24);
    var fake: server_mod.FakeRuntimeOps = .{};
    fake.resize_fail_count = 1;
    const ops = fake.ops();
    _ = try registry.attachSubscription(1, .{ .value = 7 }, .observer);
    _ = try registry.declareViewportSubscription(1, .{ .value = 7 }, 50, 37);

    reconcileViewportsWith(&registry, ops);
    // PTY 가 실패했으니 registry 도 그대로여야 한다.
    try testing.expectEqual(@as(u16, 80), entry.cols);
    try testing.expectEqual(@as(u64, 0), entry.resize_generation);

    // 다음 선언이 다시 세우면 그때 적용된다.
    _ = try registry.declareViewportSubscription(1, .{ .value = 7 }, 44, 30);
    reconcileViewportsWith(&registry, ops);
    try testing.expectEqual(@as(u16, 44), entry.cols);
}

test "S11-6 tick: 한 세션의 선언이 다른 세션 크기를 안 건드린다" {
    var registry = reg.TerminalRuntimeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const a = try registry.register(1, 80, 24);
    const b = try registry.register(2, 120, 40);
    var fake: server_mod.FakeRuntimeOps = .{};
    const ops = fake.ops();

    _ = try registry.attachSubscription(1, .{ .value = 7 }, .observer);
    _ = try registry.declareViewportSubscription(1, .{ .value = 7 }, 50, 37);
    reconcileViewportsWith(&registry, ops);

    try std.testing.expectEqual(@as(u16, 50), a.cols);
    // **다른 세션은 그대로다** — 그리고 기준도 안 잡힌다(선언이 없으니).
    try std.testing.expectEqual(@as(u16, 120), b.cols);
    try std.testing.expectEqual(@as(?u16, null), b.viewport_baseline_cols);
    try std.testing.expectEqual(@as(u128, 1), fake.resized_runtime);
}

test "S11-6 tick: 조정을 기다리던 runtime 이 사라져도 회계가 낫는다" {
    var registry = reg.TerminalRuntimeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    _ = try registry.register(1, 80, 24);
    const b = try registry.register(2, 120, 40);
    var fake: server_mod.FakeRuntimeOps = .{};
    const ops = fake.ops();

    _ = try registry.attachSubscription(1, .{ .value = 7 }, .observer);
    _ = try registry.declareViewportSubscription(1, .{ .value = 7 }, 50, 37);
    try std.testing.expect(registry.viewportDirty());

    // tick 이 돌기 전에 그 runtime 이 끝난다.
    registry.unregister(1);
    // **세는 값이 남아도 tick 이 스스로 낫는다** — 안 그러면 매 tick 표를 헛되이 훑는다.
    reconcileViewportsWith(&registry, ops);
    try std.testing.expect(!registry.viewportDirty());
    try std.testing.expectEqual(@as(u16, 0), fake.resized_cols);
    try std.testing.expectEqual(@as(u16, 120), b.cols);
}

test "S11-6 tick: 커밋이 불가능하면 PTY 도 안 건드린다" {
    var registry = reg.TerminalRuntimeRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const entry = try registry.register(1, 80, 24);
    // 이 세션은 resize generation 이 상한이다 — 더 못 올린다.
    entry.resize_generation = reg.resize_wire_max_counter;
    var fake: server_mod.FakeRuntimeOps = .{};
    const ops = fake.ops();
    _ = try registry.attachSubscription(1, .{ .value = 7 }, .observer);
    _ = try registry.declareViewportSubscription(1, .{ .value = 7 }, 50, 37);

    reconcileViewportsWith(&registry, ops);
    // **PTY 를 안 건드렸다** — 건드렸다면 registry(80)와 PTY(50)가 갈린 채 남는다.
    try std.testing.expectEqual(@as(u16, 0), fake.resized_cols);
    try std.testing.expectEqual(@as(u16, 80), entry.cols);
}
