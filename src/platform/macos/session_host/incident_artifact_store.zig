//! CR0b 연결 장애 기록의 보안 파일 시스템 저장 경계.
//!
//! 캐시 경로 해석과 디렉터리 생성은 프로세스 부트스트랩이 맡고, 이 모듈은 이미 검증된 0700 디렉터리 FD만
//! 소유한다. 기록기는 포인터 없는 인계 값 하나만 넘기므로 Client나 서비스 mutex를 파일 시스템 호출 동안 잡지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const incident = @import("connection_incident");

const c = std.c;
const posix = std.posix;

pub const Error = error{
    InvalidAuthority,
    InvalidDirectory,
    InvalidRecord,
    Collision,
    OpenFailed,
    WriteFailed,
    SyncFailed,
};

pub const PersistResult = enum(u8) { created = 1, already_present = 2 };
pub const max_file_bytes: usize = 64 * 1024;
pub const max_total_bytes: usize = 1024 * 1024;
pub const max_files: usize = 128;
pub const retention_ns: i128 = 7 * 24 * 60 * 60 * std.time.ns_per_s;

const Candidate = struct {
    name: [160]u8 = [_]u8{0} ** 160,
    name_len: u8 = 0,
    size: u64 = 0,
    mtime_ns: i128 = 0,
    device: u64 = 0,
    inode: u64 = 0,

    fn view(self: *const Candidate) []const u8 {
        return self.name[0..self.name_len];
    }
};

fn candidateOlder(a: Candidate, b: Candidate) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns < b.mtime_ns;
    return std.mem.lessThan(u8, a.view(), b.view());
}

pub const IncidentArtifactStore = struct {
    self_addr: usize = 0,
    pid: u64 = 0,
    process_nonce: u64 = 0,
    service_addr: usize = 0,
    app_instance_nonce: u128 = 0,
    dir_fd: c.fd_t = -1,
    lifecycle_raw: u8 = 0,

    pub fn initInPlace(
        out: *IncidentArtifactStore,
        pid: u64,
        process_nonce: u64,
        service_addr: usize,
        app_instance_nonce: u128,
        dir_fd: c.fd_t,
    ) Error!void {
        if (pid == 0 or process_nonce == 0 or service_addr == 0 or app_instance_nonce == 0 or dir_fd < 0)
            return error.InvalidAuthority;
        var stat: posix.Stat = undefined;
        if (c.fstat(dir_fd, &stat) != 0 or !posix.S.ISDIR(stat.mode) or
            stat.uid != c.getuid() or stat.mode & 0o777 != 0o700)
            return error.InvalidDirectory;
        const flags = c.fcntl(dir_fd, c.F.GETFD, @as(c_int, 0));
        if (flags < 0 or flags & c.FD_CLOEXEC == 0) return error.InvalidDirectory;
        out.* = .{
            .self_addr = @intFromPtr(out),
            .pid = pid,
            .process_nonce = process_nonce,
            .service_addr = service_addr,
            .app_instance_nonce = app_instance_nonce,
            .dir_fd = dir_fd,
            .lifecycle_raw = 1,
        };
    }

    pub fn persist(
        self: *IncidentArtifactStore,
        current_pid: u64,
        handoff: incident.IncidentWriterHandoff,
    ) Error!PersistResult {
        if (!self.valid(current_pid) or handoff.receipt.pid != current_pid or
            handoff.receipt.process_nonce != self.process_nonce or handoff.receipt.service_addr != self.service_addr or
            handoff.receipt.app_instance_nonce != self.app_instance_nonce or !incident.validWriterHandoff(handoff))
            return error.InvalidAuthority;
        var name_buf: [160]u8 = undefined;
        const name = filename(&name_buf, handoff.receipt) catch return error.InvalidRecord;
        const fd = c.openat(
            self.dir_fd,
            name.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
            @as(c.mode_t, 0o600),
        );
        if (fd < 0) {
            if (posix.errno(-1) == .EXIST) return self.validateExisting(name, handoff.record);
            return error.OpenFailed;
        }
        var keep = false;
        var created_stat = std.mem.zeroes(posix.Stat);
        defer {
            _ = c.close(fd);
            if (!keep) self.removeCreatedIfSame(name, created_stat);
        }
        if (c.fstat(fd, &created_stat) != 0 or !posix.S.ISREG(created_stat.mode) or created_stat.uid != c.getuid())
            return error.OpenFailed;
        if (c.fchmod(fd, 0o600) != 0) return error.OpenFailed;
        if (c.fstat(fd, &created_stat) != 0 or !posix.S.ISREG(created_stat.mode) or created_stat.uid != c.getuid() or
            created_stat.mode & 0o777 != 0o600) return error.OpenFailed;
        try writeFull(fd, &handoff.record);
        try syncFd(fd);
        try syncFd(self.dir_fd);
        keep = true;
        return .created;
    }

    pub fn prune(self: *IncidentArtifactStore, current_pid: u64, now_ns: i128) Error!void {
        if (!self.valid(current_pid) or now_ns < 0) return error.InvalidAuthority;
        var removed = false;
        while (true) {
            const scan = try self.scanOldest();
            const oldest = scan.oldest orelse {
                if (removed) try syncFd(self.dir_fd);
                return;
            };
            const expired = oldest.mtime_ns < now_ns -| retention_ns;
            if (!expired and scan.count <= max_files and scan.total_bytes <= max_total_bytes) {
                if (removed) try syncFd(self.dir_fd);
                return;
            }
            var name_z_buf: [160]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_z_buf, "{s}", .{oldest.view()}) catch return error.InvalidDirectory;
            var current: posix.Stat = undefined;
            if (c.fstatat(self.dir_fd, name_z.ptr, &current, posix.AT.SYMLINK_NOFOLLOW) != 0)
                return error.InvalidDirectory;
            if (!posix.S.ISREG(current.mode) or current.uid != c.getuid() or current.mode & 0o777 != 0o600 or
                current.size < incident.envelope_size or current.size > max_file_bytes or
                @as(u64, @intCast(current.dev)) != oldest.device or @as(u64, @intCast(current.ino)) != oldest.inode)
                return error.InvalidDirectory;
            if (!self.storedArtifactMatches(name_z, current)) return error.InvalidDirectory;
            if (c.unlinkat(self.dir_fd, name_z.ptr, 0) != 0) return error.InvalidDirectory;
            removed = true;
        }
    }

    const Scan = struct {
        count: usize = 0,
        total_bytes: u64 = 0,
        oldest: ?Candidate = null,
    };

    fn scanOldest(self: *IncidentArtifactStore) Error!Scan {
        const scan_fd = c.dup(self.dir_fd);
        if (scan_fd < 0) return error.OpenFailed;
        const directory = c.fdopendir(scan_fd) orelse {
            _ = c.close(scan_fd);
            return error.OpenFailed;
        };
        defer _ = c.closedir(directory);
        var result: Scan = .{};
        while (c.readdir(directory)) |entry| {
            const name = std.mem.sliceTo(entry.name[0..], 0);
            if (!validFilename(name) or name.len >= @sizeOf(@FieldType(Candidate, "name"))) continue;
            var name_z_buf: [160]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_z_buf, "{s}", .{name}) catch continue;
            var stat: posix.Stat = undefined;
            if (c.fstatat(self.dir_fd, name_z.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0 or
                !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or stat.mode & 0o777 != 0o600 or
                stat.size < incident.envelope_size or stat.size > max_file_bytes) continue;
            if (!self.storedArtifactMatches(name_z, stat)) continue;
            var candidate: Candidate = .{
                .name_len = @intCast(name.len),
                .size = @intCast(stat.size),
                .mtime_ns = @as(i128, stat.mtimespec.sec) * std.time.ns_per_s + stat.mtimespec.nsec,
                .device = @intCast(stat.dev),
                .inode = @intCast(stat.ino),
            };
            @memcpy(candidate.name[0..name.len], name);
            result.total_bytes = std.math.add(u64, result.total_bytes, @intCast(stat.size)) catch return error.InvalidDirectory;
            result.count = std.math.add(usize, result.count, 1) catch return error.InvalidDirectory;
            if (result.oldest == null or candidateOlder(candidate, result.oldest.?)) result.oldest = candidate;
        }
        return result;
    }

    fn storedArtifactMatches(self: *IncidentArtifactStore, name: [:0]const u8, expected: posix.Stat) bool {
        const file_fd = c.openat(
            self.dir_fd,
            name.ptr,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
            @as(c.mode_t, 0),
        );
        if (file_fd < 0) return false;
        defer _ = c.close(file_fd);
        var opened: posix.Stat = undefined;
        var envelope: [incident.envelope_size]u8 = undefined;
        return c.fstat(file_fd, &opened) == 0 and opened.dev == expected.dev and opened.ino == expected.ino and
            opened.uid == expected.uid and opened.mode == expected.mode and opened.size == expected.size and
            readFull(file_fd, &envelope) and validStoredArtifact(name, self.app_instance_nonce, envelope);
    }

    pub fn deinit(self: *IncidentArtifactStore) void {
        if (self.lifecycle_raw == 1 and self.self_addr == @intFromPtr(self) and self.dir_fd >= 0)
            _ = c.close(self.dir_fd);
        self.* = .{};
    }

    fn valid(self: *const IncidentArtifactStore, current_pid: u64) bool {
        return self.lifecycle_raw == 1 and self.self_addr == @intFromPtr(self) and self.pid == current_pid and
            current_pid != 0 and self.dir_fd >= 0;
    }

    fn validateExisting(
        self: *IncidentArtifactStore,
        name: [:0]const u8,
        expected: [incident.envelope_size]u8,
    ) Error!PersistResult {
        const fd = c.openat(
            self.dir_fd,
            name.ptr,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
            @as(c.mode_t, 0),
        );
        if (fd < 0) return error.Collision;
        defer _ = c.close(fd);
        var stat: posix.Stat = undefined;
        if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
            stat.mode & 0o777 != 0o600 or stat.size != incident.envelope_size) return error.Collision;
        var actual: [incident.envelope_size]u8 = undefined;
        if (!readFull(fd, &actual) or !std.mem.eql(u8, &actual, &expected)) return error.Collision;
        var extra: [1]u8 = undefined;
        if (c.read(fd, &extra, 1) != 0) return error.Collision;
        return .already_present;
    }

    fn removeCreatedIfSame(self: *IncidentArtifactStore, name: [:0]const u8, created: posix.Stat) void {
        var current: posix.Stat = undefined;
        if (created.ino == 0 or c.fstatat(self.dir_fd, name.ptr, &current, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !posix.S.ISREG(current.mode) or current.dev != created.dev or current.ino != created.ino) return;
        _ = c.unlinkat(self.dir_fd, name.ptr, 0);
    }
};

fn filename(buffer: *[160]u8, receipt: incident.IncidentWriterReceipt) Error![:0]const u8 {
    if (receipt.app_instance_nonce == 0 or receipt.record_generation == 0 or
        receipt.slot_index >= incident.incident_slot_count + incident.aggregate_slot_count)
        return error.InvalidRecord;
    if (receipt.slot_index < incident.incident_slot_count) {
        if (receipt.incident_sequence == 0) return error.InvalidRecord;
        return std.fmt.bufPrintZ(
            buffer,
            "i-{x:0>32}-{x:0>16}.incident",
            .{ receipt.app_instance_nonce, receipt.incident_sequence },
        ) catch error.InvalidRecord;
    }
    return std.fmt.bufPrintZ(
        buffer,
        "a-{x:0>32}-{x:0>16}-{s}.incident",
        .{ receipt.app_instance_nonce, receipt.record_generation, std.fmt.bytesToHex(receipt.digest, .lower) },
    ) catch error.InvalidRecord;
}

fn validFilename(name: []const u8) bool {
    if (name.len == 60 and std.mem.startsWith(u8, name, "i-") and std.mem.eql(u8, name[51..], ".incident")) {
        if (name[34] != '-') return false;
        return lowercaseHex(name[2..34]) and lowercaseHex(name[35..51]);
    }
    if (name.len == 125 and std.mem.startsWith(u8, name, "a-") and std.mem.eql(u8, name[116..], ".incident")) {
        if (name[34] != '-' or name[51] != '-') return false;
        return lowercaseHex(name[2..34]) and lowercaseHex(name[35..51]) and lowercaseHex(name[52..116]);
    }
    return false;
}

fn validStoredArtifact(name: []const u8, app_instance_nonce: u128, envelope: [incident.envelope_size]u8) bool {
    if (!validFilename(name) or app_instance_nonce == 0 or envelope[3] != 1 or
        std.mem.readInt(u16, envelope[0..2], .little) != incident.encoding_version or
        std.mem.readInt(u16, envelope[4..6], .little) != incident.payload_size or
        std.mem.readInt(u16, envelope[6..8], .little) != 0) return false;
    var canonical = envelope;
    canonical[3] = 0;
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(canonical[0..224], &digest, .{});
    if (!std.mem.eql(u8, &digest, envelope[224..256])) return false;
    const nonce = std.fmt.parseInt(u128, name[2..34], 16) catch return false;
    if (nonce != app_instance_nonce) return false;
    const generation = std.mem.readInt(u64, envelope[8..16], .little);
    if (name[0] == 'i') {
        const sequence = std.fmt.parseInt(u64, name[35..51], 16) catch return false;
        return envelope[2] == 1 and sequence != 0 and
            std.mem.readInt(u128, envelope[20..36], .little) == nonce and
            std.mem.readInt(u64, envelope[36..44], .little) == sequence;
    }
    const named_generation = std.fmt.parseInt(u64, name[35..51], 16) catch return false;
    var named_digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&named_digest, name[52..116]) catch return false;
    return envelope[2] == 2 and named_generation == generation and std.mem.eql(u8, &named_digest, &digest);
}

fn lowercaseHex(bytes: []const u8) bool {
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

fn writeFull(fd: c.fd_t, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0 and posix.errno(-1) == .INTR) continue;
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
}

fn readFull(fd: c.fd_t, bytes: []u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0 and posix.errno(-1) == .INTR) continue;
        if (count <= 0) return false;
        offset += @intCast(count);
    }
    return true;
}

fn syncFd(fd: c.fd_t) Error!void {
    while (true) {
        if (c.fsync(fd) == 0) return;
        if (posix.errno(-1) != .INTR) return error.SyncFailed;
    }
}

test "CR0b 저장소 상세 파일 이름은 고정 길이 소문자 식별자만 사용한다" {
    const handoff = try fixtureHandoff();
    var buffer: [160]u8 = undefined;
    const name = try filename(&buffer, handoff.receipt);
    try std.testing.expectEqualStrings("i-00000000000000000000000000001234-0000000000000001.incident", name);
}

test "CR0b 저장소 집계 파일 이름은 세대와 봉투 digest를 결속한다" {
    var service: incident.ConnectionIncidentService = .{};
    const pid: u64 = @intCast(c.getpid());
    try service.initInPlace(pid, 9, 0x1234);
    const input = try fixtureInput();
    _ = try service.publish(pid, 9, input);
    var detail: incident.IncidentWriterHandoff = .{};
    _ = try service.takePendingForWriter(pid, 9, &detail);
    var aggregate: incident.IncidentWriterHandoff = .{};
    _ = try service.takePendingForWriter(pid, 9, &aggregate);
    var buffer: [160]u8 = undefined;
    const name = try filename(&buffer, aggregate.receipt);
    var expected: [160]u8 = undefined;
    const expected_name = try std.fmt.bufPrint(
        &expected,
        "a-00000000000000000000000000001234-0000000000000001-{s}.incident",
        .{std.fmt.bytesToHex(aggregate.receipt.digest, .lower)},
    );
    try std.testing.expectEqualStrings(expected_name, name);
}

test "CR0b 저장소는 현재 사용자의 0700 디렉터리와 최종 주소만 허용한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    if (c.fchmod(tmp.dir.handle, 0o700) != 0) return error.SkipZigTest;
    const fd = c.dup(tmp.dir.handle);
    if (fd < 0) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)));
    const handoff = try fixtureHandoff();
    var store: IncidentArtifactStore = .{};
    try store.initInPlace(@intCast(c.getpid()), 9, handoff.receipt.service_addr, handoff.receipt.app_instance_nonce, fd);
    var copied = store;
    try std.testing.expectError(error.InvalidAuthority, copied.persist(@intCast(c.getpid()), handoff));
    store.deinit();
}

test "CR0b 저장소는 정확한 인계만 0600 일반 파일로 멱등 저장한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    if (c.fchmod(tmp.dir.handle, 0o700) != 0) return error.SkipZigTest;
    const fd = c.dup(tmp.dir.handle);
    if (fd < 0) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)));
    const handoff = try fixtureHandoff();
    var store: IncidentArtifactStore = .{};
    try store.initInPlace(@intCast(c.getpid()), 9, handoff.receipt.service_addr, handoff.receipt.app_instance_nonce, fd);
    defer store.deinit();
    try std.testing.expectEqual(PersistResult.created, try store.persist(@intCast(c.getpid()), handoff));
    try std.testing.expectEqual(PersistResult.already_present, try store.persist(@intCast(c.getpid()), handoff));
    var drifted = handoff;
    drifted.receipt.slot_index = incident.incident_slot_count + 1;
    try std.testing.expectError(error.InvalidAuthority, store.persist(@intCast(c.getpid()), drifted));
}

test "CR0b 저장소는 기존 내용 변조를 덮어쓰거나 지우지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    if (c.fchmod(tmp.dir.handle, 0o700) != 0) return error.SkipZigTest;
    const fd = c.dup(tmp.dir.handle);
    if (fd < 0) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)));
    const handoff = try fixtureHandoff();
    var store: IncidentArtifactStore = .{};
    try store.initInPlace(@intCast(c.getpid()), 9, handoff.receipt.service_addr, handoff.receipt.app_instance_nonce, fd);
    defer store.deinit();
    _ = try store.persist(@intCast(c.getpid()), handoff);
    var name_buf: [160]u8 = undefined;
    const name = try filename(&name_buf, handoff.receipt);
    const corrupt_fd = c.openat(store.dir_fd, name.ptr, .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (corrupt_fd < 0) return error.SkipZigTest;
    defer _ = c.close(corrupt_fd);
    const corrupt = [_]u8{0xff};
    if (c.pwrite(corrupt_fd, &corrupt, corrupt.len, 0) != corrupt.len) return error.SkipZigTest;
    try std.testing.expectError(error.Collision, store.persist(@intCast(c.getpid()), handoff));
    var stat: posix.Stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(store.dir_fd, name.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW));
}

test "CR0b 저장소 정리는 엄격한 이름의 파일만 오래된 순서로 1 MiB 아래에 둔다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    if (c.fchmod(tmp.dir.handle, 0o700) != 0) return error.SkipZigTest;
    const fd = c.dup(tmp.dir.handle);
    if (fd < 0) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)));
    var service: incident.ConnectionIncidentService = .{};
    const pid: u64 = @intCast(c.getpid());
    try service.initInPlace(pid, 9, 0x1234);
    var store: IncidentArtifactStore = .{};
    try store.initInPlace(pid, 9, @intFromPtr(&service), 0x1234, fd);
    defer store.deinit();
    var block = [_]u8{0} ** max_file_bytes;
    for (1..18) |sequence| {
        const input = try fixtureInput();
        _ = try service.publish(pid, 9, input);
        var handoff: incident.IncidentWriterHandoff = .{};
        _ = try service.takePendingForWriter(pid, 9, &handoff);
        try std.testing.expectEqual(@as(u64, @intCast(sequence)), handoff.receipt.incident_sequence);
        @memcpy(block[0..incident.envelope_size], &handoff.record);
        var name_buf: [160]u8 = undefined;
        const name = try filename(&name_buf, handoff.receipt);
        const file_fd = c.openat(store.dir_fd, name.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
        if (file_fd < 0) return error.SkipZigTest;
        if (c.fchmod(file_fd, 0o600) != 0 or c.write(file_fd, &block, block.len) != block.len) {
            _ = c.close(file_fd);
            return error.SkipZigTest;
        }
        _ = c.close(file_fd);
    }
    var foreign_name_buf: [160]u8 = undefined;
    const foreign_name = std.fmt.bufPrintZ(
        &foreign_name_buf,
        "i-00000000000000000000000000001234-{x:0>16}.incident",
        .{99},
    ) catch unreachable;
    const foreign_fd = c.openat(
        store.dir_fd,
        foreign_name.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (foreign_fd < 0) return error.SkipZigTest;
    if (c.fchmod(foreign_fd, 0o600) != 0 or c.write(foreign_fd, &([_]u8{0} ** max_file_bytes), max_file_bytes) != max_file_bytes) {
        _ = c.close(foreign_fd);
        return error.SkipZigTest;
    }
    _ = c.close(foreign_fd);
    try store.prune(@intCast(c.getpid()), std.time.ns_per_s);
    var first_buf: [160]u8 = undefined;
    const first = std.fmt.bufPrintZ(&first_buf, "i-00000000000000000000000000001234-{x:0>16}.incident", .{1}) catch unreachable;
    var stat: posix.Stat = undefined;
    try std.testing.expect(c.fstatat(store.dir_fd, first.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0);
    var last_buf: [160]u8 = undefined;
    const last = std.fmt.bufPrintZ(&last_buf, "i-00000000000000000000000000001234-{x:0>16}.incident", .{17}) catch unreachable;
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(store.dir_fd, last.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW));
    try std.testing.expectEqual(@as(c_int, 0), c.fstatat(store.dir_fd, foreign_name.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW));
}

fn fixtureHandoff() !incident.IncidentWriterHandoff {
    var service: incident.ConnectionIncidentService = .{};
    const pid: u64 = @intCast(c.getpid());
    try service.initInPlace(pid, 9, 0x1234);
    const input = try fixtureInput();
    _ = try service.publish(pid, 9, input);
    var handoff: incident.IncidentWriterHandoff = .{};
    _ = try service.takePendingForWriter(pid, 9, &handoff);
    return handoff;
}

fn fixtureInput() !incident.ConnectionIncident {
    var input = std.mem.zeroes(incident.ConnectionIncident);
    input.version = 1;
    input.record_kind = 1;
    input.flags = 1;
    input.timestamp_ns = 1;
    input.reason_raw = 0;
    input.scope_raw = 1;
    input.disposition_raw = 1;
    input.source_site_raw = 1;
    input.host_class_raw = 1;
    input.parser_phase_raw = 1;
    input.outbound_phase_raw = 1;
    input.occurrence_count = 1;
    input.first_timestamp_ns = 1;
    input.last_timestamp_ns = 1;
    return input;
}
