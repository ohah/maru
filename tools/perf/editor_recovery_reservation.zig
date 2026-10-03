//! 격리 저장소 후보 실험. 제품 backup caller나 workspace restore에 연결하지 않는다.
//! 실제 OwnerLease와 제품 backup이 쓰는 std.Io.File.Atomic을 함께 실행한다.
const std = @import("std");
const session = @import("session");
const OwnerLease = @import("owner_lease").OwnerLease;
const backup = session.editor.backup;
const Id = session.editor.recovery_id.Id;
const c = std.c;
const posix = std.posix;
const allocator = std.heap.page_allocator;
const Candidate = enum { claim, directory };
const Mode = enum { fresh, reopen };
const document_path = "/fixture/document.txt";

fn statAt(dir: std.Io.Dir, name: [:0]const u8) !posix.Stat {
    var stat: posix.Stat = undefined;
    if (c.fstatat(dir.handle, name.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0)
        return if (posix.errno(-1) == .NOENT) error.Missing else error.StatFailed;
    return stat;
}

fn statFd(fd: c.fd_t) !posix.Stat {
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0) return error.StatFailed;
    return stat;
}

fn sameObject(a: posix.Stat, b: posix.Stat) bool {
    return a.dev == b.dev and a.ino == b.ino;
}

fn privateDirectory(stat: posix.Stat) bool {
    // 0500 주입은 실제 create/rename 실패를 검사하므로 owner write bit는 여기서 요구하지 않는다.
    return posix.S.ISDIR(stat.mode) and stat.uid == c.getuid() and stat.mode & 0o077 == 0;
}

const Reservation = struct {
    io: std.Io,
    id: Id,
    candidate: Candidate,
    mode: Mode,
    root_path: [:0]const u8,
    root: std.Io.Dir,
    data: std.Io.Dir,
    root_identity: posix.Stat,
    data_identity: posix.Stat,
    lock: OwnerLease,
    lock_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    lock_path_len: usize = 0,
    leaf: [48:0]u8 = @splat(0),
    leaf_len: usize = 0,
    record: [48:0]u8 = @splat(0),
    record_len: usize = 0,
    pending: ?std.Io.File.Atomic = null,
    pending_base: ?c.fd_t = null,
    published: bool = false,
    drop_fd: ?c.fd_t = null,
    retired: bool = false,

    fn init(io: std.Io, root_path: [:0]const u8, id: Id, candidate: Candidate, mode: Mode) !Reservation {
        if (!std.fs.path.isAbsolute(root_path)) return error.InvalidRoot;
        const root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true, .follow_symlinks = false });
        errdefer root.close(io);
        const root_identity = try statFd(root.handle);
        if (!privateDirectory(root_identity)) return error.UnsafeRoot;
        var result: Reservation = .{
            .io = io,
            .id = id,
            .candidate = candidate,
            .mode = mode,
            .root_path = root_path,
            .root = root,
            .data = root,
            .root_identity = root_identity,
            .data_identity = root_identity,
            .lock = undefined,
        };
        const leaf = try std.fmt.bufPrintZ(&result.leaf, "d-{s}{s}", .{ id.hex(), if (candidate == .claim) ".claim" else "" });
        result.leaf_len = leaf.len;
        const record = try session.editor.recovery_id.fileName(id);
        @memcpy(result.record[0..record.len], &record);
        result.record_len = record.len;
        if (candidate == .directory) {
            if (mode == .fresh) {
                if (c.mkdirat(root.handle, leaf.ptr, 0o700) != 0)
                    return if (posix.errno(-1) == .EXIST) error.Reserved else error.CreateFailed;
                // mkdir의 mode도 umask를 탄다. 우리가 방금 만든 디렉터리만 보정한다.
                try root.setFilePermissions(io, leaf, @enumFromInt(0o700), .{ .follow_symlinks = false });
            }
            result.data = try root.openDir(io, leaf, .{ .iterate = true, .follow_symlinks = false });
            result.data_identity = statFd(result.data.handle) catch |err| {
                result.data.close(io);
                return err;
            };
            if (!privateDirectory(result.data_identity)) {
                result.data.close(io);
                return error.UnsafeDirectory;
            }
        } else if (mode == .fresh) {
            if (statAt(root, result.recordName())) |_| return error.Reserved else |err| if (err != error.Missing) return err;
            const fd = c.openat(root.handle, leaf.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
            if (fd < 0) return if (posix.errno(fd) == .EXIST) error.Reserved else error.CreateFailed;
            defer _ = c.close(fd);
            if (c.fchmod(fd, 0o600) != 0) return error.CreateFailed;
        }
        errdefer if (candidate == .directory) result.data.close(io);
        const lock_path = try std.fmt.bufPrintZ(&result.lock_path, "{s}/{s}{s}", .{ root_path, leaf, if (candidate == .directory) "/owner.lock" else "" });
        result.lock_path_len = lock_path.len;
        // Resume는 기존 객체만 재획득한다. 없어졌다가 생긴 새 inode를 같은 owner로 받아들이지 않는다.
        const before = if (mode == .reopen) try statAt(result.data, if (candidate == .claim) leaf else "owner.lock") else null;
        result.lock = try OwnerLease.acquire(lock_path);
        errdefer result.lock.deinit();
        if (before) |identity| if (!sameObject(identity, try statFd(result.lock.descriptor()))) return error.Replaced;
        try result.validate();
        return result;
    }

    fn lockPath(self: *const Reservation) [:0]const u8 {
        return self.lock_path[0..self.lock_path_len :0];
    }
    fn leafName(self: *const Reservation) [:0]const u8 {
        return self.leaf[0..self.leaf_len :0];
    }
    fn recordName(self: *const Reservation) [:0]const u8 {
        return self.record[0..self.record_len :0];
    }

    fn deinit(self: *Reservation) void {
        self.abort();
        if (self.drop_fd) |fd| _ = c.close(fd);
        self.lock.deinit();
        if (self.candidate == .directory) self.data.close(self.io);
        self.root.close(self.io);
    }

    fn validate(self: *const Reservation) !void {
        if (self.retired) return error.Retired;
        const named_root = try statAt(std.Io.Dir.cwd(), self.root_path);
        if (!privateDirectory(named_root) or !sameObject(named_root, self.root_identity)) return error.Replaced;
        if (self.candidate == .directory) {
            const named_data = try statAt(self.root, self.leafName());
            if (!privateDirectory(named_data) or !sameObject(named_data, self.data_identity)) return error.Replaced;
        }
        try self.lock.revalidatePath(self.lockPath());
    }

    fn prepare(self: *Reservation, body: []const u8) !void {
        if (self.pending != null) return error.AlreadyPrepared;
        try self.validate();
        const base = try self.openRecord();
        errdefer {
            if (base) |fd| _ = c.close(fd);
        }
        if (base != null and self.mode == .fresh and !self.published) return error.RecordCollision;
        const bytes = try backup.encodeRecovery(allocator, self.id, .{ .path = document_path, .disk_hash = 1 }, body);
        defer allocator.free(bytes);
        var af = try self.data.createFileAtomic(self.io, self.recordName(), .{ .replace = true, .permissions = @enumFromInt(0o600) });
        errdefer af.deinit(self.io);
        // .permissions만 넘기면 umask 0777에서 mode 000이 게시됨을 실제 파일로 재현했다.
        try af.file.setPermissions(self.io, @enumFromInt(0o600));
        var buffer: [4096]u8 = undefined;
        var writer = af.file.writer(self.io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
        self.pending = af;
        self.pending_base = base;
    }

    fn publish(self: *Reservation) !void {
        try self.validate();
        const pending = if (self.pending) |*af| af else return error.NotPrepared;
        // 잠금 신원과 레코드 신원은 다른 검사다. 준비 뒤 나타난/교체된 레코드도 보존한다.
        const current = try self.openRecord();
        defer {
            if (current) |fd| _ = c.close(fd);
        }
        if (self.pending_base) |base| {
            const fd = current orelse return error.RecordChanged;
            if (!sameObject(try statFd(base), try statFd(fd))) return error.RecordChanged;
            try pending.replace(self.io);
        } else {
            if (current != null) return error.RecordChanged;
            // 첫 게시는 check→rename 사이에 이름이 생겨도 교체하지 않는 원자 API를 쓴다.
            try pending.link(self.io);
        }
        pending.deinit(self.io);
        self.pending = null;
        if (self.pending_base) |fd| _ = c.close(fd);
        self.pending_base = null;
        self.published = true;
    }

    fn abort(self: *Reservation) void {
        if (self.pending) |*af| af.deinit(self.io);
        self.pending = null;
        if (self.pending_base) |fd| _ = c.close(fd);
        self.pending_base = null;
    }

    fn markDrop(self: *Reservation) !void {
        try self.validate();
        if (self.drop_fd != null) return error.AlreadySelected;
        // 열린 fd가 선택한 이전 inode의 재사용을 막는다. 경로와 fd의 비교 뒤 공격적 교체까지 보장하지 않는다.
        self.drop_fd = (try self.openRecord()) orelse return error.Missing;
    }

    fn openRecord(self: *const Reservation) !?c.fd_t {
        const fd = c.openat(self.data.handle, self.recordName().ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c.mode_t, 0));
        if (fd < 0) return if (posix.errno(fd) == .NOENT) null else error.OpenFailed;
        errdefer _ = c.close(fd);
        const stat = try statFd(fd);
        if (!posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or stat.nlink != 1 or stat.mode & 0o777 != 0o600) return error.UnsafeRecord;
        // 고정된 짧은 실험 본문만 읽는다. 제품 백업 크기 한도를 정의하는 버퍼가 아니다.
        var bytes: [4096]u8 = undefined;
        var len: usize = 0;
        while (len < bytes.len) {
            const n = c.read(fd, bytes[len..].ptr, bytes.len - len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            len += @intCast(n);
        }
        if (len == bytes.len) return error.RecordTooLarge;
        var parsed = try backup.parseRecovery(allocator, bytes[0..len]);
        defer parsed.deinit(allocator);
        if (!parsed.matches(self.recordName(), self.id, document_path)) return error.ForeignRecord;
        return fd;
    }

    fn drop(self: *Reservation) !void {
        try self.validate();
        const fd = self.drop_fd orelse return error.NotSelected;
        if (!sameObject(try statFd(fd), try statAt(self.data, self.recordName()))) return error.StaleDrop;
        try self.data.deleteFile(self.io, self.recordName());
        _ = c.close(fd);
        self.drop_fd = null;
    }

    fn retire(self: *Reservation, rollback: bool) !void {
        try self.validate();
        if (self.pending != null or self.drop_fd != null) return error.Busy;
        if (rollback and self.mode != .fresh) return error.RestoredReservation;
        if (statAt(self.data, self.recordName())) |_| return error.RecordPresent else |err| if (err != error.Missing) return err;
        if (self.candidate == .directory) {
            var it = self.data.iterate();
            while (try it.next(self.io)) |entry| if (!std.mem.eql(u8, entry.name, "owner.lock")) return error.NotEmpty;
        }
        if (try self.lock.unlinkOwnedWhileLocked(self.lockPath()) != .removed) return error.Replaced;
        // 삭제가 시작된 뒤에는 이 owner로 다시 쓰지 않는다. 실패한 rmdir도 재사용 성공으로 숨기지 않는다.
        self.retired = true;
        if (self.candidate == .directory and c.unlinkat(self.root.handle, self.leafName().ptr, posix.AT.REMOVEDIR) != 0) return error.CleanupFailed;
    }
};

fn reply(text: []const u8) !void {
    var remaining = text;
    while (remaining.len != 0) {
        const n = c.write(1, remaining.ptr, remaining.len);
        if (n <= 0) return error.ReplyFailed;
        remaining = remaining[@intCast(n)..];
    }
    if (c.write(1, "\n", 1) != 1) return error.ReplyFailed;
}

fn command(buffer: []u8) !?[]const u8 {
    var len: usize = 0;
    while (len < buffer.len) {
        const n = c.read(0, buffer[len..].ptr, 1);
        if (n == 0) return if (len == 0) null else error.TruncatedCommand;
        if (n < 0) return error.ReadFailed;
        if (buffer[len] == '\n') return buffer[0..len];
        len += 1;
    }
    return error.CommandTooLong;
}

fn execute(r: *Reservation, text: []const u8) !void {
    if (std.mem.eql(u8, text, "prepare-old")) return r.prepare("old-complete");
    if (std.mem.eql(u8, text, "prepare-new")) return r.prepare("new-complete");
    if (std.mem.eql(u8, text, "prepare-empty")) return r.prepare("");
    if (std.mem.eql(u8, text, "publish")) return r.publish();
    if (std.mem.eql(u8, text, "abort")) {
        r.abort();
        return;
    }
    if (std.mem.eql(u8, text, "check")) return r.validate();
    if (std.mem.eql(u8, text, "mark-drop")) return r.markDrop();
    if (std.mem.eql(u8, text, "drop")) return r.drop();
    if (std.mem.eql(u8, text, "rollback")) return r.retire(true);
    if (std.mem.eql(u8, text, "retire")) return r.retire(false);
    if (std.mem.eql(u8, text, "encode-oom")) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        if (backup.encodeRecovery(failing.allocator(), r.id, .{ .path = document_path }, "new")) |bytes| {
            failing.allocator().free(bytes);
            return error.ExpectedOutOfMemory;
        } else |err| if (err != error.OutOfMemory or !failing.has_induced_failure) return error.ExpectedOutOfMemory;
        return;
    }
    return error.UnknownCommand;
}

fn bench(io: std.Io, root: [:0]const u8, candidate: Candidate) !void {
    for (0..64) |i| {
        var raw: [16]u8 = @splat(0);
        std.mem.writeInt(u64, raw[8..16], i + 1, .big);
        const id = try Id.fromBytes(raw);
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        var r = try Reservation.init(io, root, id, candidate, .fresh);
        defer r.deinit();
        const reserved = std.Io.Clock.awake.now(io).nanoseconds;
        try r.prepare("old-complete");
        try r.publish();
        const published = std.Io.Clock.awake.now(io).nanoseconds;
        try r.markDrop();
        try r.drop();
        try r.retire(false);
        const retired = std.Io.Clock.awake.now(io).nanoseconds;
        var buffer: [256]u8 = undefined;
        try reply(try std.fmt.bufPrint(&buffer, "sample {d} {d} {d}", .{ reserved - start, published - reserved, retired - published }));
    }
}

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .macos) return error.MacOSRequired;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const candidate = std.meta.stringToEnum(Candidate, args.next() orelse return error.Arguments) orelse return error.Arguments;
    const root = args.next() orelse return error.Arguments;
    const action = args.next() orelse return error.Arguments;
    if (std.mem.eql(u8, action, "bench")) {
        if (args.next() != null) return error.Arguments;
        return bench(init.io, root, candidate);
    }
    const mode = std.meta.stringToEnum(Mode, action) orelse return error.Arguments;
    const id = try Id.parse(args.next() orelse return error.Arguments);
    if (args.next() != null) return error.Arguments;
    try reply("waiting");
    var buffer: [128]u8 = undefined;
    const start = (try command(&buffer)) orelse return error.MissingStart;
    if (!std.mem.eql(u8, start, "start")) return error.Arguments;
    var r = Reservation.init(init.io, root, id, candidate, mode) catch |err| {
        try reply(try std.fmt.bufPrint(&buffer, "error:{s}", .{@errorName(err)}));
        return;
    };
    defer r.deinit();
    try reply("owned");
    while (try command(&buffer)) |text| {
        if (std.mem.eql(u8, text, "release")) {
            try reply("released");
            return;
        }
        execute(&r, text) catch |err| {
            try reply(try std.fmt.bufPrint(&buffer, "error:{s}", .{@errorName(err)}));
            continue;
        };
        try reply("ok");
    }
}
