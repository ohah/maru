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
    backup_failed,
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

/// Restore-incomplete 실행의 final Quit 전용 경로. 기존 완전본이 있으면 같은 secure parent descriptor 안에서
/// create-once `.bak`을 만든 뒤에만 canonical leaf를 교체한다. 기존 `.bak`은 검증 후 그대로 보존한다.
pub fn publishFinal(parent_path: [:0]const u8, snapshot: []const u8, preserve_previous: bool) Result {
    if (snapshot.len == 0) return .invalid_snapshot;
    if (preserve_previous and ensureBackup(parent_path) != .committed) return .backup_failed;
    // **덮기 직전의 내용을 타임스탬프 사본으로 남긴다.** create-once `.bak` 은 「가장 완전한 첫 사본」을
    // 지키는 장치라 두 번째 final-quit 부터는 갱신되지 않는다 — 의도된 설계지만, 그래서 **오늘 덮이는
    // 내용에 대한 안전망은 없다.**
    //
    // 2026-09-11 실측: 원격 runtime detach 13 개가 `ConnectionClosed` 로 실패해 restore-incomplete 로
    // 종료했고, final-quit 저장이 사용자의 레이아웃을 **343 바이트**로 덮었다. `.bak` 은 7 주 전
    // 사본이라 아무 도움이 되지 않았고, 그 뒤 재실행마다 한 겹씩 더 깎였다(1514 → 1190 B). 안내 문구는
    // 「이전 체크포인트를 .bak 으로 남기고 저장합니다」라고 약속하는데, 실제로는 남기지 않는다.
    //
    // 실패해도 저장을 막지 않는다. 이건 **안전망**이지 전제 조건이 아니다 — 여기서 fail-close 하면
    // 2026-08-27 의 「권한 한 비트가 종료를 막는다」를 다시 만든다.
    if (preserve_previous) _ = snapshotAside(parent_path);
    return publish(parent_path, snapshot);
}

const aside_prefix: []const u8 = "workspace.v1.prequit-";

/// 현재 완전본을 `workspace.v1.prequit-<unix>` 로 복사한다. 이름이 매번 달라 **연속된 나쁜 저장이
/// 서로를 덮지 않는다** — `.bak` 을 매번 갱신하는 쪽으로 고치면 바로 그 성질을 잃는다.
fn snapshotAside(parent_path: [:0]const u8) Result {
    const parent_fd = c.open(parent_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (parent_fd < 0) return .backup_failed;
    defer _ = c.close(parent_fd);

    const source_fd = c.openat(parent_fd, final_leaf.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (source_fd < 0) return if (posix.errno(-1) == .NOENT) .committed else .backup_failed;
    defer _ = c.close(source_fd);
    var source_stat: posix.Stat = undefined;
    if (c.fstat(source_fd, &source_stat) != 0 or !posix.S.ISREG(source_stat.mode) or
        source_stat.uid != c.getuid()) return .backup_failed;
    // 빈 파일을 남겨 봐야 복구에 쓸 수 없고, 이름만 늘어난다.
    if (source_stat.size == 0) return .committed;

    var leaf_buf: [64]u8 = undefined;
    // **덮이는 파일 자신의 mtime 으로 이름 짓는다.** 사본 이름이 「어느 시점의 레이아웃인지」를 그대로
    // 가리키고, 별도 시계 의존도 없다. 같은 초에 두 번 덮이면 `O_EXCL` 이 두 번째를 거절하는데, 그때
    // 남아 있는 것이 **더 이른 쪽**(더 온전한 쪽)이라 그대로 옳다.
    const leaf = std.fmt.bufPrintZ(&leaf_buf, "{s}{d}", .{ aside_prefix, source_stat.mtimespec.sec }) catch
        return .backup_failed;
    const aside_fd = c.openat(parent_fd, leaf.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (aside_fd < 0) return .backup_failed;
    var keep = false;
    defer {
        _ = c.close(aside_fd);
        if (!keep) _ = c.unlinkat(parent_fd, leaf.ptr, 0);
    }
    if (c.fchmod(aside_fd, 0o600) != 0) return .backup_failed;
    var buffer: [16 * 1024]u8 = undefined;
    var copied: i64 = 0;
    while (true) {
        const read_count = c.read(source_fd, &buffer, buffer.len);
        if (read_count < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return .backup_failed;
        }
        if (read_count == 0) break;
        var offset: usize = 0;
        const count: usize = @intCast(read_count);
        while (offset < count) {
            const written = c.write(aside_fd, buffer[offset..count].ptr, count - offset);
            if (written < 0) {
                if (posix.errno(-1) == .INTR) continue;
                return .backup_failed;
            }
            if (written == 0) return .backup_failed;
            offset += @intCast(written);
        }
        copied += read_count;
    }
    // **잘린 사본은 없는 것보다 나쁘다** — 있다고 믿게 만든다.
    if (copied != source_stat.size) return .backup_failed;
    keep = true;
    return .committed;
}

const backup_leaf: [:0]const u8 = "workspace.v1.bak";

fn ensureBackup(parent_path: [:0]const u8) Result {
    const parent_fd = c.open(parent_path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (parent_fd < 0) return .backup_failed;
    defer _ = c.close(parent_fd);
    var parent_stat: posix.Stat = undefined;
    if (c.fstat(parent_fd, &parent_stat) != 0 or !posix.S.ISDIR(parent_stat.mode) or parent_stat.uid != c.getuid())
        return .backup_failed;

    const source_fd = c.openat(parent_fd, final_leaf.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (source_fd < 0) return if (posix.errno(-1) == .NOENT) .committed else .backup_failed;
    defer _ = c.close(source_fd);
    var source_stat: posix.Stat = undefined;
    if (c.fstat(source_fd, &source_stat) != 0 or !posix.S.ISREG(source_stat.mode) or source_stat.uid != c.getuid())
        return .backup_failed;

    var backup_fd = c.openat(parent_fd, backup_leaf.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (backup_fd < 0) {
        if (posix.errno(-1) != .EXIST) return .backup_failed;
        const existing_fd = c.openat(parent_fd, backup_leaf.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
        if (existing_fd < 0) return .backup_failed;
        defer _ = c.close(existing_fd);
        var existing_stat: posix.Stat = undefined;
        if (c.fstat(existing_fd, &existing_stat) != 0 or !posix.S.ISREG(existing_stat.mode) or
            existing_stat.uid != c.getuid()) return .backup_failed;
        // 권한이 느슨하면 **거절하지 않고 조인다.** 우리가 소유한 정규 파일이고(위 두 검사), 새로 만드는
        // 경로도 바로 아래에서 `fchmod(0o600)` 으로 같은 값을 강제한다 — 기존 파일만 거절할 이유가 없다.
        //
        // 거절하면 어떻게 되는지 실측했다(2026-08-27): `.bak` 이 `0644` 로 남아 있어 `ensureBackup` 이
        // `.backup_failed` 를 냈고, `publishFinal` 이 그걸 **쓰기 전체의 실패**로 옮겨 checkpoint 가
        // `notice=2`(write failed)로 끝났다. keep-alive 종료는 저장 실패를 허용하지 않으므로 **앱이 닫히지
        // 않았다** — 파일 권한 한 비트가 사용자를 종료할 수 없는 상태에 가둔 셈이다. `chmod 600` 을 준 즉시
        // 저장이 성공했고(3211→4719 bytes) 종료도 통과했다.
        //
        // 범위는 정확히 여기까지다. `ensureBackup` 은 `publishFinal` 에서만 불리므로 **평상시 저장(`publish`)은
        // 이 권한과 무관하다**. 같은 기간 workspace.v1 이 갱신되지 않은 것은 `restore_incomplete` 동안 평상시
        // 저장을 건너뛰는 **설계된 동작** 탓이고, 이 비트가 막은 것은 final-quit 저장 하나다. 두 원인을 뭉치면
        // 다음 사람이 엉뚱한 곳을 판다.
        //
        // `0644` 가 애초에 어떻게 생겼는지는 아직 모른다 — 아래 생성 경로는 항상 `fchmod(0o600)` 을 준다.
        if (existing_stat.mode & 0o777 != 0o600 and c.fchmod(existing_fd, 0o600) != 0) return .backup_failed;
        return .committed;
    }
    var keep_backup = false;
    defer {
        if (backup_fd >= 0) _ = c.close(backup_fd);
        if (!keep_backup) _ = c.unlinkat(parent_fd, backup_leaf.ptr, 0);
    }
    if (c.fchmod(backup_fd, 0o600) != 0) return .backup_failed;
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const read_count = c.read(source_fd, &buffer, buffer.len);
        if (read_count < 0) {
            if (posix.errno(-1) == .INTR) continue;
            return .backup_failed;
        }
        if (read_count == 0) break;
        var offset: usize = 0;
        const count: usize = @intCast(read_count);
        while (offset < count) {
            const written = c.write(backup_fd, buffer[offset..count].ptr, count - offset);
            if (written < 0) {
                if (posix.errno(-1) == .INTR) continue;
                return .backup_failed;
            }
            if (written == 0) return .backup_failed;
            offset += @intCast(written);
        }
    }
    var backup_stat: posix.Stat = undefined;
    if (c.fstat(backup_fd, &backup_stat) != 0 or !posix.S.ISREG(backup_stat.mode) or
        backup_stat.uid != c.getuid() or backup_stat.mode & 0o777 != 0o600) return .backup_failed;
    const closing_fd = backup_fd;
    backup_fd = -1;
    if (c.close(closing_fd) != 0) return .backup_failed;
    keep_backup = true;
    return .committed;
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
