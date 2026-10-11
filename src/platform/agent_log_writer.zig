//! Native I/O over an already-authenticated private directory. All cooperating
//! writers and rotators share the stable sibling lock; no pipe I/O occurs here.
const std = @import("std");
const builtin = @import("builtin");
const codec = @import("../session/agent_log_generation.zig");
const command = @import("../session/agent_hook_command.zig");
const event = @import("../session/agent_hook_event.zig");
const Io = std.Io;

fn validateName(name: []const u8) !void {
    if (name.len > command.remote_log_name_max or !command.instance_token_class.accepts(name)) return error.InvalidName;
}

fn privatePermissions() Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

fn secureRegular(file: Io.File, io: Io) !Io.File.Stat {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.UnsafeFile;
    if (builtin.os.tag != .windows and stat.permissions.toMode() & 0o777 != 0o600) return error.UnsafeFile;
    return stat;
}

pub const lock_slot_count = 64;
pub const lock_path_len = ".maru-agent-log-lock-v1-".len + 2;

/// Versioned fixed slots bound persistent inode count even after logs are expired.
/// SHA256's first byte makes the mapping identical across architectures/versions.
pub fn lockPath(buffer: *[lock_path_len]u8, name: []const u8) ![]const u8 {
    try validateName(name);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    return std.fmt.bufPrint(buffer, ".maru-agent-log-lock-v1-{x:0>2}", .{digest[0] & (lock_slot_count - 1)});
}

pub const Lease = struct {
    file: Io.File,
    pub fn release(self: Lease, io: Io) void {
        self.file.close(io);
    }
};

/// Never truncate, unlink, or replace this inode: doing so splits the lock domain.
pub fn acquire(io: Io, dir: Io.Dir, name: []const u8) !Lease {
    var buffer: [lock_path_len]u8 = undefined;
    const path = try lockPath(&buffer, name);
    for (0..3) |_| {
        const file = dir.openFile(io, path, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => dir.createFile(io, path, .{ .read = true, .truncate = false, .exclusive = true, .lock = .exclusive, .lock_nonblocking = true, .permissions = privatePermissions() }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => continue,
                else => return create_err,
            },
            else => return err,
        };
        errdefer file.close(io);
        _ = try secureRegular(file, io);
        return .{ .file = file };
    }
    return error.WouldBlock;
}

fn logName(buffer: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}.ndjson", .{name});
}

const State = struct { generation: codec.Generation, payload_size: u64, file_size: u64 };
fn inspect(file: Io.File, io: Io) !State {
    const stat = try secureRegular(file, io);
    var header: [codec.header_len]u8 = undefined;
    const got = try file.readPositionalAll(io, &header, 0);
    const generation = try codec.decodeHeader(header[0..got]);
    if (stat.size < codec.header_len) return error.IncompleteHeader;
    if (stat.size > codec.header_len) {
        var tail: [1]u8 = undefined;
        if (try file.readPositionalAll(io, &tail, stat.size - 1) != 1 or tail[0] != '\n') return error.IncompleteRecord;
    }
    return .{ .generation = generation, .payload_size = stat.size - codec.header_len, .file_size = stat.size };
}

fn publish(io: Io, dir: Io.Dir, name: []const u8, previous: ?codec.Generation, first_line: []const u8) !codec.Generation {
    var generation: codec.Generation = undefined;
    try io.randomSecure(&generation);
    if (previous) |old| if (std.mem.eql(u8, &old, &generation)) return error.RepeatedGeneration;
    const encoded = codec.encodeGeneration(generation);
    var temporary_buffer: [command.remote_log_name_max + 64]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&temporary_buffer, ".{s}.generation-{s}.tmp", .{ name, encoded });
    const file = try dir.createFile(io, temporary, .{ .exclusive = true, .read = true, .permissions = privatePermissions() });
    var opened = true;
    defer {
        if (opened) file.close(io);
        dir.deleteFile(io, temporary) catch {};
    }
    const header = codec.encodeHeader(generation);
    try file.writePositionalAll(io, &header, 0);
    try file.writePositionalAll(io, first_line, codec.header_len);
    _ = try secureRegular(file, io);
    // Close before rename so the same contract works with Windows sharing rules.
    file.close(io);
    opened = false;
    var log_buffer: [command.remote_log_name_max + ".ndjson".len]u8 = undefined;
    try dir.rename(temporary, dir, try logName(&log_buffer, name), io);
    return generation;
}

pub fn append(io: Io, dir: Io.Dir, name: []const u8, line: []const u8) !codec.Position {
    // A caller cannot inject another record or accidentally leave a partial tail.
    if (line.len == 0 or line.len > event.max_line_bytes + 1 or line[line.len - 1] != '\n' or
        std.mem.indexOfScalar(u8, line[0 .. line.len - 1], '\n') != null) return error.InvalidRecord;
    const sep = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidRecord;
    if (!event.looksLikeProvider(line[0..sep])) return error.InvalidRecord;
    const lease = try acquire(io, dir, name);
    defer lease.release(io);
    var buffer: [command.remote_log_name_max + ".ndjson".len]u8 = undefined;
    const path = try logName(&buffer, name);
    const file = dir.openFile(io, path, .{ .mode = .read_write, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .generation = try publish(io, dir, name, null, line), .offset = line.len },
        else => return err,
    };
    defer file.close(io);
    const state = try inspect(file, io);
    const end = try std.math.add(u64, state.file_size, line.len);
    file.writePositionalAll(io, line, state.file_size) catch |err| {
        file.setLength(io, state.file_size) catch return error.RollbackFailed;
        return err;
    };
    return .{ .generation = state.generation, .offset = end - codec.header_len };
}

pub const Snapshot = struct { start: codec.Position, payload_size: u64, bytes: []const u8 };
pub fn readSnapshot(io: Io, dir: Io.Dir, name: []const u8, cursor: ?codec.Cursor, buffer: []u8) !Snapshot {
    const lease = try acquire(io, dir, name);
    defer lease.release(io);
    var name_buffer: [command.remote_log_name_max + ".ndjson".len]u8 = undefined;
    const file = try dir.openFile(io, try logName(&name_buffer, name), .{ .mode = .read_write, .follow_symlinks = false });
    defer file.close(io);
    const state = try inspect(file, io);
    const start = codec.reconcile(cursor, state.generation, state.payload_size);
    const want: usize = @intCast(@min(buffer.len, state.payload_size - start.offset));
    const got = try file.readPositionalAll(io, buffer[0..want], try codec.fileOffset(start.offset));
    if (got != want) return error.SnapshotChanged;
    return .{ .start = start, .payload_size = state.payload_size, .bytes = buffer[0..got] };
}

/// Caller must have flushed the consumed snapshot before requesting rotation.
pub fn rotate(io: Io, dir: Io.Dir, name: []const u8, consumed: codec.Position, snapshot_size: u64) !?codec.Position {
    const lease = try acquire(io, dir, name);
    defer lease.release(io);
    var buffer: [command.remote_log_name_max + ".ndjson".len]u8 = undefined;
    const file = try dir.openFile(io, try logName(&buffer, name), .{ .mode = .read_write, .follow_symlinks = false });
    const state = inspect(file, io) catch |err| {
        file.close(io);
        return err;
    };
    file.close(io);
    if (!codec.canRotate(consumed, snapshot_size, state.generation, state.payload_size)) return null;
    return .{ .generation = try publish(io, dir, name, state.generation, ""), .offset = 0 };
}

const testing = std.testing;
const one = "claude\t{\"tag\":\"one\"}\n";
const two = "codex\t{\"tag\":\"two\"}\n";
fn readAll(dir: Io.Dir, buffer: []u8) ![]const u8 {
    const file = try dir.openFile(testing.io, "a.ndjson", .{});
    defer file.close(testing.io);
    const size = (try file.stat(testing.io)).size;
    if (size > buffer.len) return error.NoSpaceLeft;
    const count = try file.readPositionalAll(testing.io, buffer[0..@intCast(size)], 0);
    return buffer[0..count];
}

test "writer creates one generation, appends and snapshots without holding its lock" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const first = try append(testing.io, temp.dir, "a", one);
    const next = try append(testing.io, temp.dir, "a", two);
    try testing.expectEqualDeep(first.generation, next.generation);
    try testing.expectEqual(@as(u64, one.len + two.len), next.offset);
    var bytes: [1024]u8 = undefined;
    const snapshot = try readSnapshot(testing.io, temp.dir, "a", .{ .generation = first.generation, .offset = one.len }, &bytes);
    try testing.expectEqualStrings(two, snapshot.bytes);
    const lease = try acquire(testing.io, temp.dir, "a");
    lease.release(testing.io);
    const replaced = try rotate(testing.io, temp.dir, "a", next, next.offset);
    try testing.expect(replaced != null);
    try testing.expect(!std.mem.eql(u8, &first.generation, &replaced.?.generation));
    _ = try append(testing.io, temp.dir, "a", one);
}

test "writer rotation protects append and same-size new generations" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const first = try append(testing.io, temp.dir, "a", one);
    const next = try append(testing.io, temp.dir, "a", two);
    try testing.expect(try rotate(testing.io, temp.dir, "a", first, first.offset) == null);
    const reset = (try rotate(testing.io, temp.dir, "a", next, next.offset)).?;
    const current = try append(testing.io, temp.dir, "a", one);
    try testing.expectEqualDeep(reset.generation, current.generation);
    try testing.expect(try rotate(testing.io, temp.dir, "a", first, first.offset) == null);
    var bytes: [1024]u8 = undefined;
    const snapshot = try readSnapshot(testing.io, temp.dir, "a", .{ .generation = first.generation, .offset = first.offset }, &bytes);
    try testing.expectEqual(@as(u64, 0), snapshot.start.offset);
    try testing.expectEqualStrings(one, snapshot.bytes);
}

test "writer refuses legacy, incomplete and unframed records without changing bytes" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const file = try temp.dir.createFile(testing.io, "a.ndjson", .{ .permissions = privatePermissions() });
    try file.writePositionalAll(testing.io, one, 0);
    file.close(testing.io);
    try testing.expectError(error.NotGenerationLog, append(testing.io, temp.dir, "a", two));
    var bytes: [1024]u8 = undefined;
    try testing.expectEqualStrings(one, try readAll(temp.dir, &bytes));
    for ([_][]const u8{ "", "claude\t{}", "claude\t{}\n\n", "BAD!\t{}\n" }) |invalid|
        try testing.expectError(error.InvalidRecord, append(testing.io, temp.dir, "a", invalid));
    try testing.expectError(error.InvalidName, append(testing.io, temp.dir, "../a", one));
    try temp.dir.deleteFile(testing.io, "a.ndjson");
    _ = try append(testing.io, temp.dir, "a", one);
    const corrupt = try temp.dir.openFile(testing.io, "a.ndjson", .{ .mode = .read_write });
    const length = (try corrupt.stat(testing.io)).size;
    try corrupt.setLength(testing.io, length - 1);
    corrupt.close(testing.io);
    const before = try testing.allocator.dupe(u8, try readAll(temp.dir, &bytes));
    defer testing.allocator.free(before);
    try testing.expectError(error.IncompleteRecord, append(testing.io, temp.dir, "a", two));
    try testing.expectEqualStrings(before, try readAll(temp.dir, &bytes));
}

test "writer nonblocking lease excludes another opener and is reusable after release" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const lease = try acquire(testing.io, temp.dir, "a");
    try testing.expectError(error.WouldBlock, append(testing.io, temp.dir, "a", one));
    lease.release(testing.io);
    _ = try append(testing.io, temp.dir, "a", one);
}

const Faults = struct {
    fn zeros(_: ?*anyopaque, bytes: []u8) Io.RandomSecureError!void {
        @memset(bytes, 0);
    }
    fn linked(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
        var stat = try testing.io.vtable.fileStat(userdata, file);
        stat.nlink = 2;
        return stat;
    }
    fn entropy(_: ?*anyopaque, _: []u8) Io.RandomSecureError!void {
        return error.EntropyUnavailable;
    }
    fn rename(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir, _: []const u8) Io.Dir.RenameError!void {
        return error.AccessDenied;
    }
    fn partial(userdata: ?*anyopaque, file: Io.File, _: []const u8, data: []const []const u8, _: usize, offset: u64) Io.File.WritePositionalError!usize {
        _ = try testing.io.vtable.fileWritePositional(userdata, file, "", &.{data[0][0..1]}, 1, offset);
        return error.DiskQuota;
    }
    fn rollback(_: ?*anyopaque, _: Io.File, _: u64) Io.File.SetLengthError!void {
        return error.AccessDenied;
    }
};

test "writer entropy and rename failure preserve the old generation and remove temporary files" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const consumed = try append(testing.io, temp.dir, "a", one);
    var bytes: [1024]u8 = undefined;
    const before = try testing.allocator.dupe(u8, try readAll(temp.dir, &bytes));
    defer testing.allocator.free(before);
    var table = testing.io.vtable.*;
    table.randomSecure = Faults.entropy;
    var io = testing.io;
    io.vtable = &table;
    try testing.expectError(error.EntropyUnavailable, rotate(io, temp.dir, "a", consumed, consumed.offset));
    table.randomSecure = testing.io.vtable.randomSecure;
    table.dirRename = Faults.rename;
    try testing.expectError(error.AccessDenied, rotate(io, temp.dir, "a", consumed, consumed.offset));
    try testing.expectEqualStrings(before, try readAll(temp.dir, &bytes));
    var it = temp.dir.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count); // Only the stable lock and old log.
}

test "writer partial append rolls back and reports rollback failure explicitly" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    _ = try append(testing.io, temp.dir, "a", one);
    var bytes: [1024]u8 = undefined;
    const before = try testing.allocator.dupe(u8, try readAll(temp.dir, &bytes));
    defer testing.allocator.free(before);
    var table = testing.io.vtable.*;
    table.fileWritePositional = Faults.partial;
    var io = testing.io;
    io.vtable = &table;
    try testing.expectError(error.DiskQuota, append(io, temp.dir, "a", two));
    try testing.expectEqualStrings(before, try readAll(temp.dir, &bytes));
    table.fileSetLength = Faults.rollback;
    try testing.expectError(error.RollbackFailed, append(io, temp.dir, "a", two));
}

test "writer refuses repeated generation and new-file partial publication" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var table = testing.io.vtable.*;
    table.randomSecure = Faults.zeros;
    var io = testing.io;
    io.vtable = &table;
    const consumed = try append(io, temp.dir, "a", one);
    try testing.expectError(error.RepeatedGeneration, rotate(io, temp.dir, "a", consumed, consumed.offset));
    var bytes: [1024]u8 = undefined;
    try testing.expectEqualStrings(one, (try readAll(temp.dir, &bytes))[codec.header_len..]);
    table.fileWritePositional = Faults.partial;
    try testing.expectError(error.DiskQuota, append(io, temp.dir, "b", one));
    var it = temp.dir.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 3), count); // a log plus a/b stable locks, no b/temp log.
}

test "writer rejects linked lock metadata and closes its lease on rejection" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var table = testing.io.vtable.*;
    table.fileStat = Faults.linked;
    var io = testing.io;
    io.vtable = &table;
    try testing.expectError(error.UnsafeFile, append(io, temp.dir, "a", one));
    _ = try append(testing.io, temp.dir, "a", one);
}

test "writer fixed lock domain bounds inode count and uses stable golden slot names" {
    var path_buffer: [lock_path_len]u8 = undefined;
    try testing.expectEqualStrings(".maru-agent-log-lock-v1-0a", try lockPath(&path_buffer, "a"));
    try testing.expectEqualStrings(".maru-agent-log-lock-v1-3e", try lockPath(&path_buffer, "b"));
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    for (0..256) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "n{d}", .{index});
        const lease = try acquire(testing.io, temp.dir, name);
        lease.release(testing.io);
    }
    var it = temp.dir.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expect(count <= lock_slot_count and count > 1);
}

test "writer colliding lock slots serialize without mixing file contents" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var a_path: [lock_path_len]u8 = undefined;
    var b_path: [lock_path_len]u8 = undefined;
    try testing.expectEqualStrings(try lockPath(&a_path, "a"), try lockPath(&b_path, "n5"));
    const lease = try acquire(testing.io, temp.dir, "a");
    try testing.expectError(error.WouldBlock, append(testing.io, temp.dir, "n5", two));
    lease.release(testing.io);
    _ = try append(testing.io, temp.dir, "a", one);
    _ = try append(testing.io, temp.dir, "n5", two);
    var bytes: [1024]u8 = undefined;
    try testing.expectEqualStrings(one, (try readSnapshot(testing.io, temp.dir, "a", null, &bytes)).bytes);
    try testing.expectEqualStrings(two, (try readSnapshot(testing.io, temp.dir, "n5", null, &bytes)).bytes);
}
