//! 클릭한 디스크 내용과 실제 열린 불변 문서를 SHA-256으로 결속한다. 전체 읽기는 worker에서만 한다.
const std = @import("std");
const maru = @import("maru");
const process = @import("process.zig");
var workers = std.atomic.Value(usize).init(0);
pub fn outstandingWorkers() usize {
    return workers.load(.acquire);
}
const Sha = std.crypto.hash.sha2.Sha256;
pub fn disk(a: std.mem.Allocator, io: std.Io, root_path: []const u8, path: []const u8, control: *process.Control, max_bytes: usize, expected: maru.session.file_tree.Identity) ![32]u8 {
    return readInternal(a, io, root_path, path, control, max_bytes, expected, null);
}
/// 미리보기 전문도 navigation과 같은 root·regular file·변경 검사를 통과한 경우만 반환한다.
pub fn read(a: std.mem.Allocator, io: std.Io, root_path: []const u8, path: []const u8, control: *process.Control, max_bytes: usize, expected: maru.session.file_tree.Identity) !struct { bytes: []u8, hash: [32]u8 } {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    const hash = try readInternal(a, io, root_path, path, control, max_bytes, expected, &output);
    const raw = try output.toOwnedSlice(a);
    defer a.free(raw);
    const text = if (std.mem.startsWith(u8, raw, maru.session.editor.document.utf8_bom)) raw[3..] else raw;
    if (!std.unicode.utf8ValidateSlice(text)) return error.NotUtf8;
    return .{ .bytes = try a.dupe(u8, text), .hash = hash };
}
fn readInternal(a: std.mem.Allocator, io: std.Io, root_path: []const u8, path: []const u8, control: *process.Control, max_bytes: usize, expected: maru.session.file_tree.Identity, output: ?*std.ArrayList(u8)) ![32]u8 {
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
    return sha.finalResult();
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
