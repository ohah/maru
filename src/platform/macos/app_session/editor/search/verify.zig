//! 클릭한 디스크 내용과 실제 열린 불변 문서를 SHA-256으로 결속한다. 전체 읽기는 worker에서만 한다.
const std = @import("std");
const maru = @import("maru");
const process = @import("process.zig");
var workers = std.atomic.Value(usize).init(0);
pub fn outstandingWorkers() usize {
    return workers.load(.acquire);
}
const Sha = std.crypto.hash.sha2.Sha256;
/// 본문 hash는 기존 검색과 같이 BOM을 제외한다. 물리 신원과 raw hash는 파일 교체·BOM 변경을 구분한다.
pub const Proof = struct {
    identity: maru.session.file_tree.Identity,
    hash: [32]u8,
    raw_hash: [32]u8,
    stamp: ?Stamp = null,
    pub const Stamp = struct {
        size: i64,
        mtime: @TypeOf(@as(std.posix.Stat, undefined).mtime()),
        ctime: @TypeOf(@as(std.posix.Stat, undefined).ctime()),
    };
    /// actor는 전문 재읽기 없이 준비 뒤의 관측 가능한 in-place 수정을 거절한다. bytes 해시 검증을 대체하지 않는다.
    pub fn matchesStat(self: Proof, current: std.posix.Stat) bool {
        const stamp = self.stamp orelse return false;
        return current.mode & std.posix.S.IFMT == std.posix.S.IFREG and self.identity.eql(fileIdentity(current)) and stamp.size == current.size and
            std.meta.eql(stamp.mtime, current.mtime()) and std.meta.eql(stamp.ctime, current.ctime());
    }
    pub fn sameFile(self: Proof, other: Proof) bool {
        return self.identity.eql(other.identity);
    }
    pub fn validate(self: Proof, current: Proof) !void {
        if (!self.sameFile(current) or !std.mem.eql(u8, &self.raw_hash, &current.raw_hash)) return error.FileChanged;
    }
};
pub const Read = struct { bytes: []u8, hash: [32]u8, proof: Proof, has_bom: bool = false };
fn fileIdentity(stat: std.posix.Stat) maru.session.file_tree.Identity {
    const device: std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(stat.dev))) = @bitCast(stat.dev);
    return .{ .device = device, .inode = stat.ino, .kind = 1 };
}
pub fn disk(a: std.mem.Allocator, io: std.Io, root_path: []const u8, path: []const u8, control: *process.Control, max_bytes: usize, expected: maru.session.file_tree.Identity) ![32]u8 {
    return (try readInternal(a, io, root_path, path, control, max_bytes, expected, null)).hash;
}
/// 미리보기 전문도 navigation과 같은 root·regular file·변경 검사를 통과한 경우만 반환한다.
pub fn read(a: std.mem.Allocator, io: std.Io, root_path: []const u8, path: []const u8, control: *process.Control, max_bytes: usize, expected: maru.session.file_tree.Identity) !Read {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    const proof = try readInternal(a, io, root_path, path, control, max_bytes, expected, &output);
    const raw = try output.toOwnedSlice(a);
    defer a.free(raw);
    const text = if (std.mem.startsWith(u8, raw, maru.session.editor.document.utf8_bom)) raw[3..] else raw;
    if (!std.unicode.utf8ValidateSlice(text)) return error.NotUtf8;
    return .{ .bytes = try a.dupe(u8, text), .hash = proof.hash, .proof = proof, .has_bom = text.len != raw.len };
}
fn readInternal(a: std.mem.Allocator, io: std.Io, root_path: []const u8, path: []const u8, control: *process.Control, max_bytes: usize, expected: maru.session.file_tree.Identity, output: ?*std.ArrayList(u8)) !Proof {
    var root = try process.openRoot(a, io, root_path);
    defer root.deinit(a, io);
    const device: std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(root.device))) = @bitCast(root.device);
    if (@as(u64, device) != expected.device or root.stat.inode != expected.inode or expected.kind != 2) return error.RootChanged;
    const name = try a.dupeZ(u8, try maru.session.editor.search.request.relativePath(path));
    defer a.free(name);
    const fd = std.c.openat(root.directory.handle, name, std.c.O{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true });
    if (fd < 0) return error.Unopenable;
    defer _ = std.c.close(fd);
    var before: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &before) != 0) return error.StatFailed;
    if (before.mode & std.posix.S.IFMT != std.posix.S.IFREG) return error.UnsupportedFile;
    if (before.size < 0 or @as(u64, @intCast(before.size)) > max_bytes) return error.TooLarge;
    var sha = Sha.init(.{});
    var raw_sha = Sha.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var size: usize = 0;
    var prefix: [3]u8 = undefined;
    var prefix_len: usize = 0;
    var prefix_hashed = false;
    while (true) {
        if (control.cancelled.load(.acquire)) return error.Cancelled;
        const n = std.c.read(fd, &buffer, buffer.len);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        const count: usize = @intCast(n);
        raw_sha.update(buffer[0..count]);
        if (count > max_bytes -| size) return error.TooLarge;
        if (output) |bytes| try bytes.appendSlice(a, buffer[0..count]);
        var consumed: usize = 0;
        if (!prefix_hashed) {
            const take = @min(prefix.len - prefix_len, count);
            @memcpy(prefix[prefix_len..][0..take], buffer[0..take]);
            prefix_len += take;
            consumed = take;
            if (prefix_len == prefix.len) {
                if (!std.mem.eql(u8, &prefix, maru.session.editor.document.utf8_bom)) sha.update(&prefix);
                prefix_hashed = true;
            }
        }
        sha.update(buffer[consumed..count]);
        size += count;
    }
    if (!prefix_hashed) sha.update(prefix[0..prefix_len]);
    var after: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &after) != 0 or !std.meta.eql(before.mtime(), after.mtime()) or !std.meta.eql(before.ctime(), after.ctime()) or before.size != after.size or size != @as(u64, @intCast(after.size))) return error.FileChanged;
    try process.validateRoot(io, &root);
    // 옛 fd를 읽는 동안 경로가 다른 inode로 교체되었으면 같은 bytes여도 거절한다.
    const current_fd = std.c.openat(root.directory.handle, name, std.c.O{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true });
    if (current_fd < 0) return error.FileChanged;
    defer _ = std.c.close(current_fd);
    var current: std.posix.Stat = undefined;
    if (std.c.fstat(current_fd, &current) != 0 or !fileIdentity(before).eql(fileIdentity(current))) return error.FileChanged;
    if (control.cancelled.load(.acquire)) return error.Cancelled;
    return .{ .identity = fileIdentity(before), .hash = sha.finalResult(), .raw_hash = raw_sha.finalResult(), .stamp = .{ .size = before.size, .mtime = before.mtime(), .ctime = before.ctime() } };
}
pub const Loaded = struct {
    a: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    snapshot: maru.session.editor.buffer.Snapshot,
    hash: ?[32]u8 = null,
    failure: ?anyerror = null,
    pub fn start(a: std.mem.Allocator, file: *const maru.session.editor.edit_doc.EditableFile) !*Loaded {
        const job = try a.create(Loaded);
        errdefer a.destroy(job);
        job.* = .{ .a = a, .snapshot = file.snapshot() };
        errdefer job.snapshot.deinit();
        _ = workers.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, execute, .{job}) catch |err| {
            _ = workers.fetchSub(1, .acq_rel);
            return err;
        };
        thread.detach();
        return job;
    }
    pub fn release(self: *Loaded) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.a.destroy(self);
    }
    pub fn deinit(self: *Loaded) void {
        self.cancel.store(true, .release);
        self.release();
    }
    fn execute(self: *Loaded) void {
        defer _ = workers.fetchSub(1, .acq_rel);
        defer self.release();
        defer self.done.store(true, .release);
        defer self.snapshot.deinit();
        var sha = Sha.init(.{});
        var offset: usize = 0;
        while (offset < self.snapshot.byteLen()) {
            if (self.cancel.load(.acquire)) return;
            const end = @min(offset + 16 * 1024, self.snapshot.byteLen());
            const bytes = self.snapshot.copyRange(self.a, offset, end) catch |err| {
                self.failure = err;
                return;
            };
            sha.update(bytes);
            self.a.free(bytes);
            offset = end;
        }
        self.hash = sha.finalResult();
    }
};
