//! P4 C2 workspace checkpoint file publication.
//!
//! Capture와 semantic validation은 상위 계층의 책임이다. 이 leaf는 caller가 건넨 전체 snapshot 하나를
//! 같은 directory의 고정 temp에 끝까지 쓴 뒤 rename하는 일만 소유한다. 경로를 다시 조립하지 않도록 parent
//! descriptor에 final/temp leaf를 결속하며, 전원 손실 durability를 주장하지 않으므로 sync syscall은 의도적으로 없다.

const std = @import("std");
const c = std.c;
const posix = std.posix;

const final_leaf: [:0]const u8 = "workspace.v1";
const temp_leaf: [:0]const u8 = ".workspace.v1.tmp";

pub const Result = enum(u8) {
    committed,
    invalid_snapshot,
    open_parent_failed,
    remove_stale_failed,
    create_temp_failed,
    chmod_failed,
    write_failed,
    close_failed,
    replace_failed,
};

const PublishPhase = enum(u8) { temp_closed, replaced };

/// Publication 관측은 상태를 바꾸지 않는다. 기본 제품 경로는 callback 0이고 process fixture만 commit point 양쪽에서
/// child를 정지시켜 SIGKILL crash 결과를 확인한다.
const PublishObserver = struct {
    context: ?*anyopaque = null,
    callback: ?*const fn (?*anyopaque, PublishPhase) void = null,

    fn notify(self: PublishObserver, phase: PublishPhase) void {
        if (self.callback) |callback| callback(self.context, phase);
    }
};

/// Filesystem sequencing의 단일 출처. Product backend와 deterministic failure backend가 같은 순서를 타므로
/// fail-index fixture가 mock-only algorithm을 검증하지 않는다.
fn publishUsing(backend: anytype, snapshot: []const u8) Result {
    if (snapshot.len == 0) return .invalid_snapshot;
    backend.openParent() catch return .open_parent_failed;
    defer backend.closeParent();
    backend.removeStale() catch return .remove_stale_failed;
    backend.createTemp() catch return .create_temp_failed;
    var committed = false;
    defer if (!committed) backend.cleanupTemp();
    backend.chmodTemp() catch return .chmod_failed;

    var offset: usize = 0;
    while (offset < snapshot.len) {
        const count = backend.writeTemp(snapshot[offset..]) catch return .write_failed;
        if (count == 0 or count > snapshot.len - offset) return .write_failed;
        offset += count;
    }
    backend.closeTemp() catch return .close_failed;
    backend.replace() catch return .replace_failed;
    committed = true;
    return .committed;
}

/// `parent_path`는 C3가 canonical workspace URL의 parent에서 만든 NUL-terminated path다. File leaf는 caller가
/// 고를 수 없고 위 고정 두 이름만 쓴다.
pub fn publish(parent_path: [:0]const u8, snapshot: []const u8) Result {
    return publishObserved(parent_path, snapshot, .{});
}

fn publishObserved(parent_path: [:0]const u8, snapshot: []const u8, observer: PublishObserver) Result {
    var backend: PosixBackend = .{ .parent_path = parent_path, .observer = observer };
    return publishUsing(&backend, snapshot);
}

/// 실패 주입과 crash point observer는 제품 권위가 아니다. `zig test`에서만 이 namespace에 나타나므로
/// 제품 caller는 POSIX 검증을 우회하거나 rename 직전 상태를 callback으로 바꿀 수 없다.
pub const testing = if (@import("builtin").is_test) struct {
    pub const Phase = PublishPhase;
    pub const Observer = PublishObserver;

    pub fn publishUsingForTest(backend: anytype, snapshot: []const u8) Result {
        return publishUsing(backend, snapshot);
    }

    pub fn publishObservedForTest(parent_path: [:0]const u8, snapshot: []const u8, observer: Observer) Result {
        return publishObserved(parent_path, snapshot, observer);
    }
} else struct {};

const PosixBackend = struct {
    parent_path: [:0]const u8,
    observer: PublishObserver,
    parent_fd: c.fd_t = -1,
    temp_fd: c.fd_t = -1,

    fn openParent(self: *PosixBackend) !void {
        const fd = c.open(
            self.parent_path.ptr,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true },
            @as(c.mode_t, 0),
        );
        if (fd < 0) return error.OpenParentFailed;
        errdefer _ = c.close(fd);
        var stat: posix.Stat = undefined;
        if (c.fstat(fd, &stat) != 0 or !posix.S.ISDIR(stat.mode) or stat.uid != c.getuid())
            return error.OpenParentFailed;
        self.parent_fd = fd;
    }

    fn removeStale(self: *PosixBackend) !void {
        if (c.unlinkat(self.parent_fd, temp_leaf.ptr, 0) == 0) return;
        if (posix.errno(-1) != .NOENT) return error.RemoveStaleFailed;
    }

    fn createTemp(self: *PosixBackend) !void {
        const fd = c.openat(
            self.parent_fd,
            temp_leaf.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
            @as(c.mode_t, 0o600),
        );
        if (fd < 0) return error.CreateTempFailed;
        self.temp_fd = fd;
    }

    fn chmodTemp(self: *PosixBackend) !void {
        if (c.fchmod(self.temp_fd, 0o600) != 0) return error.ChmodFailed;
        var stat: posix.Stat = undefined;
        if (c.fstat(self.temp_fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
            stat.mode & 0o777 != 0o600) return error.ChmodFailed;
    }

    fn writeTemp(self: *PosixBackend, bytes: []const u8) !usize {
        while (true) {
            const count = c.write(self.temp_fd, bytes.ptr, bytes.len);
            if (count >= 0) return @intCast(count);
            if (posix.errno(-1) != .INTR) return error.WriteFailed;
        }
    }

    fn closeTemp(self: *PosixBackend) !void {
        const fd = self.temp_fd;
        self.temp_fd = -1;
        if (c.close(fd) != 0) return error.CloseFailed;
        self.observer.notify(.temp_closed);
    }

    fn replace(self: *PosixBackend) !void {
        if (c.renameat(self.parent_fd, temp_leaf.ptr, self.parent_fd, final_leaf.ptr) != 0)
            return error.ReplaceFailed;
        self.observer.notify(.replaced);
    }

    fn cleanupTemp(self: *PosixBackend) void {
        if (self.temp_fd >= 0) {
            _ = c.close(self.temp_fd);
            self.temp_fd = -1;
        }
        if (self.parent_fd >= 0) _ = c.unlinkat(self.parent_fd, temp_leaf.ptr, 0);
    }

    fn closeParent(self: *PosixBackend) void {
        if (self.temp_fd >= 0) {
            _ = c.close(self.temp_fd);
            self.temp_fd = -1;
        }
        if (self.parent_fd >= 0) {
            _ = c.close(self.parent_fd);
            self.parent_fd = -1;
        }
    }
};
