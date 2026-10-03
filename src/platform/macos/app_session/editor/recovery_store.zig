//! 로컬 문서의 백업 쓰기 권한. ID는 L2 값이고 fd/잠금/atomic publication은 이 플랫폼 경계가 소유한다.
//! clean open은 메모리 소유자만 준비한다. 예약 파일은 첫 백업 또는 기록된 ID의 복원에서만 연다.
const std = @import("std");
const maru = @import("maru");
const OwnerLease = @import("../../session_host/owner_lease.zig").OwnerLease;
const backup = maru.session.editor.backup;
pub const Id = maru.session.editor.recovery_id.Id;
const c = std.c;
const posix = std.posix;

fn statFd(fd: c.fd_t) !posix.Stat {
    var result: posix.Stat = undefined;
    if (c.fstat(fd, &result) != 0) return error.StatFailed;
    return result;
}
fn statAt(dir: std.Io.Dir, name: [:0]const u8) !posix.Stat {
    var result: posix.Stat = undefined;
    if (c.fstatat(dir.handle, name.ptr, &result, posix.AT.SYMLINK_NOFOLLOW) != 0)
        return if (posix.errno(-1) == .NOENT) error.FileNotFound else error.StatFailed;
    return result;
}
fn same(a: posix.Stat, b: posix.Stat) bool {
    return a.dev == b.dev and a.ino == b.ino;
}
fn privateRoot(stat: posix.Stat) bool {
    return posix.S.ISDIR(stat.mode) and stat.uid == c.getuid() and stat.mode & 0o077 == 0;
}

pub const Record = struct {
    bytes: []u8,
    parsed: backup.RecoveryRecord,
    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        self.parsed.deinit(allocator);
        allocator.free(self.bytes);
    }
};

/// 하나의 정본을 보여 주는 prepared/live view가 함께 보유한다. 순수 read/request lease에는
/// 플랫폼 쓰기 권한을 주지 않는다. 마지막 뷰를 놓아도 미저장 record는 디스크에 남는다.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    id: Id,
    refs: usize = 1,
    reservation: ?Reservation = null,
    restore: bool = false,
    consume_on_publish: bool = false,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, restored: ?Id) !*Owner {
        const id = restored orelse blk: {
            var bytes: [16]u8 = undefined;
            try io.randomSecure(&bytes);
            break :blk try Id.fromBytes(bytes);
        };
        if (!id.valid()) return error.InvalidIdentity;
        const result = try allocator.create(Owner);
        result.* = .{ .allocator = allocator, .io = io, .id = id, .restore = restored != null };
        return result;
    }
    pub fn retain(self: *Owner) *Owner {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *Owner) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.reservation) |*reservation| {
            // 실패한 첫 쓰기가 남긴 빈 예약만 정리한다. 기존 기록과 알 수 없는 파일은 보존한다.
            if (reservation.fresh or reservation.retire_when_empty) reservation.retire() catch {};
            reservation.deinit();
        }
        self.allocator.destroy(self);
    }
    pub fn read(self: *Owner, root: []const u8, path: []const u8) !?Record {
        if (self.reservation == null) {
            self.reservation = Reservation.init(self.allocator, self.io, root, self.id, path, false) catch |err| {
                if (err == error.FileNotFound) return null;
                return err;
            };
        }
        if (!std.mem.eql(u8, self.reservation.?.root_path, root) or !std.mem.eql(u8, self.reservation.?.path, path))
            return error.ForeignRecord;
        return self.reservation.?.read();
    }
    pub fn write(self: *Owner, root: []const u8, path: []const u8, disk_hash: ?u64, content: []const u8) !void {
        if (self.reservation == null) {
            if (self.restore) {
                self.reservation = Reservation.init(self.allocator, self.io, root, self.id, path, false) catch |err| blk: {
                    if (err != error.FileNotFound) return err;
                    break :blk try Reservation.init(self.allocator, self.io, root, self.id, path, true);
                };
            } else self.reservation = try Reservation.init(self.allocator, self.io, root, self.id, path, true);
        }
        if (!std.mem.eql(u8, self.reservation.?.root_path, root)) return error.Replaced;
        try self.reservation.?.write(path, disk_hash, content);
        self.consume_on_publish = false;
    }
    pub fn selectDrop(self: *Owner) !void {
        if (self.reservation) |*reservation| try reservation.selectDrop();
    }
    pub fn dropSelected(self: *Owner) !void {
        if (self.reservation) |*reservation| try reservation.dropSelected();
        self.consume_on_publish = false;
    }
    pub fn drop(self: *Owner) !void {
        try self.selectDrop();
        try self.dropSelected();
    }
};

const Reservation = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    id: Id,
    root_path: [:0]u8,
    path: []u8,
    root: std.Io.Dir,
    root_identity: posix.Stat,
    lock: OwnerLease,
    lock_path: [:0]u8,
    name: [38:0]u8,
    fresh: bool,
    published: bool = false,
    retire_when_empty: bool = false,
    drop_fd: ?c.fd_t = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, id: Id, path: []const u8, fresh: bool) !Reservation {
        if (!std.fs.path.isAbsolute(root_path) or std.mem.indexOfScalar(u8, root_path, 0) != null) return error.InvalidRoot;
        const root_z = try allocator.dupeZ(u8, root_path);
        errdefer allocator.free(root_z);
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        const lock_path = try std.fmt.allocPrintSentinel(allocator, "{s}/d-{s}.claim", .{ root_path, id.hex() }, 0);
        errdefer allocator.free(lock_path);
        if (fresh) {
            const parent = std.fs.path.dirname(root_path) orelse return error.InvalidRoot;
            try std.Io.Dir.cwd().createDirPath(io, parent);
            if (c.mkdir(root_z.ptr, 0o700) == 0) {
                // mkdir도 umask를 따른다. 방금 생성한 루트만 보정한다.
                try std.Io.Dir.cwd().setFilePermissions(io, root_path, @enumFromInt(0o700), .{ .follow_symlinks = false });
            } else if (posix.errno(-1) != .EXIST) return error.CreateFailed;
        }
        const root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .follow_symlinks = false });
        errdefer root.close(io);
        const root_identity = try statFd(root.handle);
        if (!privateRoot(root_identity)) return error.UnsafeRoot;
        const record = try maru.session.editor.recovery_id.fileName(id);
        var name: [38:0]u8 = undefined;
        @memcpy(&name, &record);
        name[38] = 0;
        const claim = lock_path[root_path.len + 1 .. :0];
        var created: ?posix.Stat = null;
        if (fresh) {
            if (statAt(root, &name)) |_| return error.Reserved else |err| if (err != error.FileNotFound) return err;
            const fd = c.openat(root.handle, claim.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
            if (fd < 0) return if (posix.errno(fd) == .EXIST) error.Reserved else error.CreateFailed;
            defer _ = c.close(fd);
            if (c.fchmod(fd, 0o600) != 0) return error.CreateFailed;
            created = try statFd(fd);
        }
        // reopen는 claim이 없는데 record만 남은 상태를 '백업 없음'으로 바꾸지 않는다.
        const before = statAt(root, claim) catch |err| {
            if (err == error.FileNotFound) {
                if (statAt(root, &name)) |_| return error.UnownedRecord else |record_err| if (record_err != error.FileNotFound) return record_err;
            }
            return err;
        };
        var lock = try OwnerLease.acquire(lock_path);
        errdefer lock.deinit();
        if (!same(before, try statFd(lock.descriptor()))) return error.Replaced;
        if (created) |identity| if (!same(identity, before)) return error.Replaced;
        var result: Reservation = .{ .allocator = allocator, .io = io, .id = id, .root_path = root_z, .path = path_copy, .root = root, .root_identity = root_identity, .lock = lock, .lock_path = lock_path, .name = name, .fresh = fresh };
        try result.validate();
        return result;
    }
    fn deinit(self: *Reservation) void {
        if (self.drop_fd) |fd| _ = c.close(fd);
        self.lock.deinit();
        self.root.close(self.io);
        self.allocator.free(self.root_path);
        self.allocator.free(self.lock_path);
        self.allocator.free(self.path);
    }
    fn validate(self: *Reservation) !void {
        const named = try statAt(std.Io.Dir.cwd(), self.root_path);
        if (!privateRoot(named) or !same(named, self.root_identity)) return error.Replaced;
        try self.lock.revalidatePath(self.lock_path);
    }
    fn openRecord(self: *Reservation) !?c.fd_t {
        try self.validate();
        const fd = c.openat(self.root.handle, &self.name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c.mode_t, 0));
        if (fd < 0) return if (posix.errno(fd) == .NOENT) null else error.OpenFailed;
        errdefer _ = c.close(fd);
        const stat = try statFd(fd);
        if (!posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or stat.nlink != 1 or stat.mode & 0o777 != 0o600) return error.UnsafeRecord;
        return fd;
    }
    fn readFd(self: *Reservation, fd: c.fd_t) !Record {
        const before = try statFd(fd);
        if (before.size < 0 or before.size > backup.max_record_bytes) return error.RecordTooLarge;
        const bytes = try self.allocator.alloc(u8, @as(usize, @intCast(before.size)) + 1);
        errdefer self.allocator.free(bytes);
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        const n = try file.readPositionalAll(self.io, bytes, 0);
        if (n != before.size) return error.RecordChanged;
        var parsed = try backup.parseRecovery(self.allocator, bytes[0..n]);
        errdefer parsed.deinit(self.allocator);
        if (!parsed.matches(&self.name, self.id, self.path)) return error.ForeignRecord;
        return .{ .bytes = bytes, .parsed = parsed };
    }
    fn read(self: *Reservation) !?Record {
        const fd = (try self.openRecord()) orelse return null;
        defer _ = c.close(fd);
        return try self.readFd(fd);
    }
    fn write(self: *Reservation, path: []const u8, disk_hash: ?u64, content: []const u8) !void {
        const base = try self.openRecord();
        defer {
            if (base) |fd| _ = c.close(fd);
        }
        if (base) |fd| {
            if (self.fresh and !self.published) return error.RecordCollision;
            var previous = try self.readFd(fd);
            previous.deinit(self.allocator);
        }
        const next_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(next_path);
        const bytes = try backup.encodeRecovery(self.allocator, self.id, .{ .path = path, .disk_hash = disk_hash }, content);
        defer self.allocator.free(bytes);
        var atomic = try self.root.createFileAtomic(self.io, &self.name, .{ .replace = true, .permissions = @enumFromInt(0o600) });
        defer atomic.deinit(self.io);
        try atomic.file.setPermissions(self.io, @enumFromInt(0o600));
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
        try self.validate();
        const current = try self.openRecord();
        defer {
            if (current) |fd| _ = c.close(fd);
        }
        if (base) |old| {
            const now = current orelse return error.RecordChanged;
            if (!same(try statFd(old), try statFd(now))) return error.RecordChanged;
            try atomic.replace(self.io);
        } else {
            if (current != null) return error.RecordChanged;
            try atomic.link(self.io);
        }
        self.allocator.free(self.path);
        self.path = next_path;
        self.published = true;
    }
    fn selectDrop(self: *Reservation) !void {
        if (self.drop_fd) |fd| _ = c.close(fd);
        self.drop_fd = null;
        const fd = (try self.openRecord()) orelse return;
        errdefer _ = c.close(fd);
        var record = try self.readFd(fd);
        record.deinit(self.allocator);
        self.drop_fd = fd;
    }
    fn dropSelected(self: *Reservation) !void {
        const fd = self.drop_fd orelse return;
        defer {
            _ = c.close(fd);
            self.drop_fd = null;
        }
        try self.validate();
        const named = statAt(self.root, &self.name) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        if (!same(try statFd(fd), named)) return error.StaleDrop;
        try self.root.deleteFile(self.io, &self.name);
        self.retire_when_empty = true;
    }
    fn retire(self: *Reservation) !void {
        try self.validate();
        if (statAt(self.root, &self.name)) |_| return error.RecordPresent else |err| if (err != error.FileNotFound) return err;
        if (try self.lock.unlinkOwnedWhileLocked(self.lock_path) != .removed) return error.Replaced;
    }
};

const testing = std.testing;
const fixture_id: Id = .{ .bytes = @splat(7) };

test "editor recovery restore 저장소는 빈 본문 재열기와 지연 삭제의 이전 버전을 구분한다" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const parent = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
    const root = try std.fs.path.join(testing.allocator, &.{ parent, "backups" });
    defer testing.allocator.free(root);
    {
        const owner = try Owner.create(testing.allocator, testing.io, fixture_id);
        defer owner.release();
        try owner.write(root, "/document", 17, "");
        var empty = (try owner.read(root, "/document")).?;
        defer empty.deinit(testing.allocator);
        try testing.expectEqualStrings("", empty.parsed.content);
        try owner.selectDrop();
        try owner.write(root, "/document", 17, "newer");
        try testing.expectError(error.StaleDrop, owner.dropSelected());
        var newer = (try owner.read(root, "/document")).?;
        defer newer.deinit(testing.allocator);
        try testing.expectEqualStrings("newer", newer.parsed.content);
        const other = try Owner.create(testing.allocator, testing.io, fixture_id);
        defer other.release();
        if (other.read(root, "/document")) |_| return error.DoubleOwner else |_| {}
    }
    const reopened = try Owner.create(testing.allocator, testing.io, fixture_id);
    defer reopened.release();
    var record = (try reopened.read(root, "/document")).?;
    defer record.deinit(testing.allocator);
    try testing.expectEqualStrings("newer", record.parsed.content);
    try reopened.drop();
    try testing.expect((try reopened.read(root, "/document")) == null);
}

test "editor recovery restore 예약 경로를 바꾸면 이전 소유자는 쓰기와 삭제를 거절한다" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const parent = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
    const root = try std.fs.path.join(testing.allocator, &.{ parent, "backups" });
    defer testing.allocator.free(root);
    const owner = try Owner.create(testing.allocator, testing.io, fixture_id);
    defer owner.release();
    try owner.write(root, "/document", 1, "original");
    const reservation = &owner.reservation.?;
    try testing.expect(try reservation.lock.unlinkOwnedWhileLocked(reservation.lock_path) == .removed);
    var replacement = try OwnerLease.acquire(reservation.lock_path);
    defer replacement.deinit();
    if (owner.write(root, "/document", 1, "wrong")) |_| return error.WroteWithoutOwner else |_| {}
    if (owner.drop()) |_| return error.DeletedWithoutOwner else |_| {}
    const bytes = try reservation.root.readFileAlloc(testing.io, &reservation.name, testing.allocator, .limited(4096));
    defer testing.allocator.free(bytes);
    var parsed = try backup.parseRecovery(testing.allocator, bytes);
    defer parsed.deinit(testing.allocator);
    try testing.expectEqualStrings("original", parsed.content);
}

test "editor recovery restore 저장소의 모든 할당 실패에서 소유 자원을 반환한다" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const parent = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
            const root = try std.fs.path.join(testing.allocator, &.{ parent, "backups" });
            defer testing.allocator.free(root);
            const owner = try Owner.create(allocator, testing.io, fixture_id);
            defer owner.release();
            try owner.write(root, "/document", 1, "first");
            try owner.write(root, "/renamed", 2, "second");
            var record = (try owner.read(root, "/renamed")).?;
            defer record.deinit(allocator);
            try testing.expectEqualStrings("second", record.parsed.content);
            try owner.drop();
        }
    }.run, .{});
}

test "editor recovery restore 다른 ID나 경로의 레코드를 읽거나 덮거나 지우지 않는다" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const parent = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
    const root = try std.fs.path.join(testing.allocator, &.{ parent, "backups" });
    defer testing.allocator.free(root);
    const owner = try Owner.create(testing.allocator, testing.io, fixture_id);
    defer owner.release();
    try owner.write(root, "/document", 1, "mine");
    for ([_]bool{ false, true }) |wrong_path| {
        const bytes = try backup.encodeRecovery(testing.allocator, if (wrong_path) fixture_id else .{ .bytes = @splat(9) }, .{ .path = if (wrong_path) "/other" else "/document", .disk_hash = 2 }, "foreign");
        defer testing.allocator.free(bytes);
        const reservation = &owner.reservation.?;
        try reservation.root.writeFile(testing.io, .{ .sub_path = &reservation.name, .data = bytes });
        try testing.expectError(error.ForeignRecord, owner.read(root, "/document"));
        try testing.expectError(error.ForeignRecord, owner.write(root, "/document", 1, "overwrite"));
        try testing.expectError(error.ForeignRecord, owner.drop());
        const after = try reservation.root.readFileAlloc(testing.io, &reservation.name, testing.allocator, .limited(4096));
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(bytes, after);
    }
}
