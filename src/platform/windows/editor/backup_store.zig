//! Private Windows storage for the common editor recovery record. The host owns
//! scheduling and UI; this adapter never writes the document's original file.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const editor = maru.session.editor;
const backup = editor.backup;
const w = std.os.windows;
const abi = maru.win32_abi;
extern "advapi32" fn OpenProcessToken(w.HANDLE, u32, *w.HANDLE) callconv(abi.winapi) w.BOOL;
extern "advapi32" fn GetTokenInformation(w.HANDLE, u32, *anyopaque, u32, *u32) callconv(abi.winapi) w.BOOL;
extern "advapi32" fn GetLengthSid(*const anyopaque) callconv(abi.winapi) u32;
extern "ntdll" fn NtQuerySecurityObject(w.HANDLE, u32, *anyopaque, u32, *u32) callconv(abi.winapi) w.NTSTATUS;
extern "ntdll" fn RtlValidRelativeSecurityDescriptor(*const anyopaque, u32, u32) callconv(abi.winapi) w.BOOLEAN;

// A protected, single-user ACL is the Windows equivalent of private 0700/0600
// backup storage. It is supplied AT creation, not repaired after exposing bytes.
// https://learn.microsoft.com/en-us/windows/win32/secauthz/security-descriptors
// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation
const Policy = struct {
    sid: [68]u8,
    sid_len: usize,
    descriptor: [176]u8 align(4),

    fn current() !Policy {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var token: w.HANDLE = undefined;
        if (!OpenProcessToken(w.GetCurrentProcess(), 8, &token).toBool()) return error.UserUnavailable;
        defer _ = w.ntdll.NtClose(token);
        var buffer: [256]u8 align(@alignOf(usize)) = undefined;
        var length: u32 = 0;
        if (!GetTokenInformation(token, 1, &buffer, buffer.len, &length).toBool() or length < @sizeOf(usize) or length > buffer.len) return error.UserUnavailable;
        const sid_ptr: *const anyopaque = @ptrFromInt(std.mem.readInt(usize, buffer[0..@sizeOf(usize)], .little));
        const n = GetLengthSid(sid_ptr);
        if (n < 8 or n > 68) return error.UserUnavailable;
        var result: Policy = .{ .sid = undefined, .sid_len = n, .descriptor = @splat(0) };
        @memcpy(result.sid[0..n], @as([*]const u8, @ptrCast(sid_ptr))[0..n]);
        const dacl: usize = 20 + n;
        result.descriptor[0] = 1;
        std.mem.writeInt(u16, result.descriptor[2..4], 0x9004, .little); // SELF_RELATIVE, DACL_PROTECTED, DACL_PRESENT
        std.mem.writeInt(u32, result.descriptor[4..8], 20, .little);
        std.mem.writeInt(u32, result.descriptor[16..20], @intCast(dacl), .little);
        @memcpy(result.descriptor[20..][0..n], result.sid[0..n]);
        result.descriptor[dacl] = 2; // ACL_REVISION
        std.mem.writeInt(u16, result.descriptor[dacl + 2 ..][0..2], @intCast(16 + n), .little);
        std.mem.writeInt(u16, result.descriptor[dacl + 4 ..][0..2], 1, .little);
        std.mem.writeInt(u16, result.descriptor[dacl + 10 ..][0..2], @intCast(8 + n), .little);
        std.mem.writeInt(u32, result.descriptor[dacl + 12 ..][0..4], 0x001f01ff, .little); // FILE_ALL_ACCESS, no other trustee
        @memcpy(result.descriptor[dacl + 16 ..][0..n], result.sid[0..n]);
        return result;
    }

    fn check(self: *const Policy, handle: w.HANDLE) !void {
        var bytes: [1024]u8 align(4) = undefined;
        var n: u32 = 0;
        if (NtQuerySecurityObject(handle, 5, &bytes, bytes.len, &n) != .SUCCESS or n < 20 or n > bytes.len) return error.PrivatePermissions;
        if (!RtlValidRelativeSecurityDescriptor(&bytes, n, 5).toBool()) return error.PrivatePermissions;
        const control = std.mem.readInt(u16, bytes[2..4], .little);
        if (control & 0x9004 != 0x9004) return error.PrivatePermissions;
        const owner = std.mem.readInt(u32, bytes[4..8], .little);
        const dacl = std.mem.readInt(u32, bytes[16..20], .little);
        if (owner < 20 or owner > n or self.sid_len > n - owner or !std.mem.eql(u8, bytes[owner..][0..self.sid_len], self.sid[0..self.sid_len])) return error.PrivatePermissions;
        if (dacl < 20 or dacl > n or 16 + self.sid_len > n - dacl) return error.PrivatePermissions;
        if (bytes[dacl] != 2 or std.mem.readInt(u16, bytes[dacl + 2 ..][0..2], .little) != 16 + self.sid_len or std.mem.readInt(u16, bytes[dacl + 4 ..][0..2], .little) != 1) return error.PrivatePermissions;
        if (bytes[dacl + 8] != 0 or bytes[dacl + 9] != 0 or std.mem.readInt(u16, bytes[dacl + 10 ..][0..2], .little) != 8 + self.sid_len or std.mem.readInt(u32, bytes[dacl + 12 ..][0..4], .little) != 0x001f01ff or !std.mem.eql(u8, bytes[dacl + 16 ..][0..self.sid_len], self.sid[0..self.sid_len])) return error.PrivatePermissions;
    }
};

fn node(a: std.mem.Allocator, parent: std.Io.Dir, name: []const u8, policy: *Policy, directory: bool, create: bool, access: u32, share_delete: bool) !std.Io.File {
    try maru.win32_relative_file.validateBasename(name);
    const wide = try std.unicode.utf8ToUtf16LeAlloc(a, name);
    defer a.free(wide);
    if (wide.len > std.math.maxInt(u16) / 2) return error.InvalidPath;
    var unicode: w.UNICODE_STRING = .{ .Length = @intCast(wide.len * 2), .MaximumLength = @intCast(wide.len * 2), .Buffer = wide.ptr };
    const attrs: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = parent.handle, .ObjectName = &unicode, .SecurityDescriptor = if (create) &policy.descriptor else null };
    var status: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    const result = w.ntdll.NtCreateFile(&handle, @bitCast(access), &attrs, &status, null, .{}, .{ .READ = true, .WRITE = directory, .DELETE = share_delete }, if (create) (if (directory) .OPEN_IF else .CREATE) else .OPEN, .{ .DIRECTORY_FILE = directory, .NON_DIRECTORY_FILE = !directory, .OPEN_REPARSE_POINT = true, .IO = .SYNCHRONOUS_NONALERT }, null, 0);
    if (result == .OBJECT_NAME_NOT_FOUND or result == .OBJECT_PATH_NOT_FOUND) return error.NotFound;
    if (result == .OBJECT_NAME_COLLISION) return error.NameCollision;
    if (result != .SUCCESS) return error.BackupOpenFailed;
    errdefer _ = w.ntdll.NtClose(handle);
    var tag: w.FILE.ATTRIBUTE_TAG_INFO = undefined;
    if (w.ntdll.NtQueryInformationFile(handle, &status, &tag, @sizeOf(@TypeOf(tag)), .AttributeTag) != .SUCCESS) return error.BackupQueryFailed;
    if (tag.FileAttributes & 0x400 != 0) return error.ReparsePoint;
    var info: w.FILE.STANDARD_INFORMATION = undefined;
    if (w.ntdll.NtQueryInformationFile(handle, &status, &info, @sizeOf(@TypeOf(info)), .Standard) != .SUCCESS) return error.BackupQueryFailed;
    if (info.Directory.toBool() != directory or info.DeletePending.toBool()) return error.UnsupportedBackup;
    if (!directory and info.NumberOfLinks != 1) return error.HardLinked;
    try policy.check(handle);
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

fn removeOwned(file: std.Io.File) !void {
    var status: w.IO_STATUS_BLOCK = undefined;
    var disposition: w.FILE.DISPOSITION.INFORMATION = .{ .DeleteFile = .TRUE };
    if (w.ntdll.NtSetInformationFile(file.handle, &status, &disposition, @sizeOf(@TypeOf(disposition)), .Disposition) != .SUCCESS) return error.BackupDeleteFailed;
}

fn sameIdentity(left: backup.Doc, right: backup.Doc) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .path => |p| std.mem.eql(u8, p.path, right.path.path),
        .untitled => |number| number == right.untitled,
        .remote => |r| std.mem.eql(u8, r.dest, right.remote.dest) and std.mem.eql(u8, r.path, right.remote.path),
    };
}

fn validDoc(doc: backup.Doc) !void {
    switch (doc) {
        .path => |p| if (!std.fs.path.isAbsoluteWindows(p.path) or std.mem.indexOfScalar(u8, p.path, 0) != null) return error.InvalidBackupIdentity,
        .untitled => |number| if (number == 0) return error.InvalidBackupIdentity,
        .remote => |r| if (r.dest.len == 0 or !std.fs.path.isAbsolutePosix(r.path) or std.mem.indexOfScalar(u8, r.dest, 0) != null or std.mem.indexOfScalar(u8, r.path, 0) != null) return error.InvalidBackupIdentity,
    }
}

fn validBody(body: []const u8, limit: usize) !void {
    if (body.len > @min(limit, backup.pause_bytes)) return error.BackupTooLarge;
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidBackupUtf8;
}

pub const Record = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    parsed: backup.Parsed,
    pub fn deinit(self: *Record) void {
        self.parsed.deinit(self.allocator);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    policy: Policy,
    limit: usize,

    /// The host selects the parent. Existing broad permissions are refused,
    /// never silently changed; the selected root stays pinned against rename.
    pub fn open(a: std.mem.Allocator, parent: std.Io.Dir, name: []const u8, limit: usize) !Store {
        var policy = try Policy.current();
        // A DELETE-access parent plus non-delete sharing prevents Windows'
        // internal rename target open (actual STATUS_SHARING_VIOLATION). Keep
        // the rename fence through sharing, without requesting parent DELETE.
        const file = try node(a, parent, name, &policy, true, true, 0x001601bf, false);
        return .{ .allocator = a, .dir = .{ .handle = file.handle }, .policy = policy, .limit = @min(limit, backup.pause_bytes) };
    }
    pub fn deinit(self: *Store, io: std.Io) void {
        self.dir.close(io);
        self.* = undefined;
    }
    fn validateRoot(self: *Store) !void {
        // A held handle pins rename, but an owner can still change its reparse
        // metadata. Recheck the selected object's tag before each operation.
        var status: w.IO_STATUS_BLOCK = undefined;
        var tag: w.FILE.ATTRIBUTE_TAG_INFO = undefined;
        if (w.ntdll.NtQueryInformationFile(self.dir.handle, &status, &tag, @sizeOf(@TypeOf(tag)), .AttributeTag) != .SUCCESS) return error.BackupQueryFailed;
        if (tag.FileAttributes & 0x400 != 0) return error.ReparsePoint;
        try self.policy.check(self.dir.handle);
    }

    pub fn write(self: *Store, io: std.Io, doc: backup.Doc, body: []const u8) !void {
        try self.writeWith(io, doc, body, NativeWrite);
    }
    fn writeWith(self: *Store, io: std.Io, doc: backup.Doc, body: []const u8, comptime Driver: type) !void {
        try validDoc(doc);
        try validBody(body, self.limit);
        try self.validateRoot();
        const bytes = try backup.encode(self.allocator, doc, body);
        defer self.allocator.free(bytes);
        var name_buffer: [backup.max_file_name_len]u8 = undefined;
        const name = backup.fileName(&name_buffer, doc);
        // Validate an existing target without repairing its ACL or following a
        // link. Hold its non-delete-sharing handle only through validation.
        if (node(self.allocator, self.dir, name, &self.policy, false, false, 0x00120089, false)) |existing| {
            existing.close(io);
        } else |err| if (err != error.NotFound) return err;
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        var temp_buffer: [64]u8 = undefined;
        const temp = try std.fmt.bufPrint(&temp_buffer, ".backup-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
        const file = try node(self.allocator, self.dir, temp, &self.policy, false, true, 0x001f01ff, false);
        defer file.close(io);
        self.publishWith(io, file, bytes, name, Driver) catch |failure| {
            removeOwned(file) catch return error.BackupCleanupFailed;
            return failure;
        };
    }
    fn publishWith(self: *Store, io: std.Io, file: std.Io.File, bytes: []const u8, name: []const u8, comptime Driver: type) !void {
        try Driver.write(file, io, bytes);
        try self.validateRoot();
        try self.policy.check(file.handle);
        const wide = try std.unicode.utf8ToUtf16LeAlloc(self.allocator, name);
        defer self.allocator.free(wide);
        var rename = w.FILE.RENAME_INFORMATION.init(.{ .Flags = .{ .REPLACE_IF_EXISTS = true }, .RootDirectory = self.dir.handle, .FileName = wide });
        const rename_buffer = rename.toBuffer();
        // The owned stage and pinned root are native authority. No absolute
        // pathname re-open is used for publication or failure cleanup.
        // https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information
        var status: w.IO_STATUS_BLOCK = undefined;
        const result = w.ntdll.NtSetInformationFile(file.handle, &status, rename_buffer.ptr, @intCast(rename_buffer.len), .Rename);
        if (result != .SUCCESS) {
            if (builtin.is_test) std.debug.print("backup rename status=0x{X}\n", .{@intFromEnum(result)});
            return error.BackupPublishFailed;
        }
    }

    pub fn read(self: *Store, io: std.Io, doc: backup.Doc) !?Record {
        try validDoc(doc);
        try self.validateRoot();
        var name_buffer: [backup.max_file_name_len]u8 = undefined;
        const name = backup.fileName(&name_buffer, doc);
        const file = node(self.allocator, self.dir, name, &self.policy, false, false, 0x00120089, false) catch |err| {
            if (err == error.NotFound) return null;
            return err;
        };
        defer file.close(io);
        const size = (try file.stat(io)).size;
        if (size > backup.max_record_bytes) return error.BackupTooLarge;
        const bytes = try self.allocator.alloc(u8, @intCast(size));
        errdefer self.allocator.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != size) return error.BackupChanged;
        var parsed = try backup.parse(self.allocator, bytes);
        errdefer parsed.deinit(self.allocator);
        if (!sameIdentity(doc, parsed.doc)) return error.WrongBackupIdentity;
        try validDoc(parsed.doc);
        try validBody(parsed.content, self.limit);
        return .{ .allocator = self.allocator, .bytes = bytes, .parsed = parsed };
    }

    /// Only the host's accepted-close or confirmed clean-save policy calls drop.
    /// Revoke or app teardown must not silently discard unsaved recovery data.
    pub fn drop(self: *Store, io: std.Io, doc: backup.Doc) !void {
        try validDoc(doc);
        try self.validateRoot();
        var name_buffer: [backup.max_file_name_len]u8 = undefined;
        const file = node(self.allocator, self.dir, backup.fileName(&name_buffer, doc), &self.policy, false, false, 0x00130089, false) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer file.close(io);
        try removeOwned(file);
    }
};

const NativeWrite = struct {
    fn write(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
        try file.writePositionalAll(io, bytes, 0);
        try file.setLength(io, bytes.len);
        try file.sync(io);
    }
};

fn testState() !editor.document_state.State {
    var state: editor.document_state.State = .{};
    errdefer state.clear(a_test);
    const file = try editor.edit_doc.EditableFile.init(a_test, "disk", false);
    state.opened = .{ .file = file, .saved_hash = editor.document_state.contentHash(file.content), .disk_hash = 99 };
    state.path = try a_test.dupe(u8, doc_test.path.path);
    return state;
}

/// Main-thread recovery applies one normal edit, retaining the record's ORIGINAL
/// disk fingerprint. An external disk change therefore fails the first save CAS.
/// The caller passes all live views so their selections move with this edit.
pub fn restorePath(a: std.mem.Allocator, state: *editor.document_state.State, record: *const Record, views: []const editor.edit_commands.Participant, actor: usize, limit: usize) !void {
    const path = state.path orelse return error.WrongBackupIdentity;
    if (record.parsed.doc != .path or !std.mem.eql(u8, path, record.parsed.doc.path.path)) return error.WrongBackupIdentity;
    try validBody(record.parsed.content, limit);
    const opened = if (state.opened) |*value| value else return error.MissingDocument;
    if (opened.file.read_only) return error.ReadOnly;
    // Prepare the full selection without changing a live view on failure.
    if (actor >= views.len) return error.InvalidActor;
    for (views, 0..) |left, index| for (views[index + 1 ..]) |right| {
        if (left.id == right.id or left.view == right.view) return error.DuplicateView;
    };
    var replacement: editor.view_navigation.View = .{};
    defer replacement.deinit(a);
    try replacement.move(a, &opened.file, .select_all, false);
    const participants = try a.dupe(editor.edit_commands.Participant, views);
    defer a.free(participants);
    const target = participants[actor].view;
    participants[actor].view = &replacement;
    _ = try editor.edit_commands.run(a, state, participants, actor, .{ .insert = record.parsed.content }, .{ .now_ms = 0, .isolate = true });
    target.deinit(a);
    target.* = replacement;
    replacement = .{};
    state.opened.?.disk_hash = record.parsed.doc.path.disk_hash;
    state.notifications.backup_on_disk = true;
}

/// Identity belongs to the document, never to a view's cached path. Remote
/// identity takes precedence over a local staging path, matching the L2 record.
pub fn identity(state: *const editor.document_state.State) ?backup.Doc {
    const opened = state.opened orelse return null;
    if (state.remote) |remote| return .{ .remote = .{ .dest = remote.dest, .path = remote.path } };
    if (state.path) |path| return .{ .path = .{ .path = path, .disk_hash = opened.disk_hash } };
    if (state.untitled) |name| return .{ .untitled = name.n };
    return null;
}

/// Call only after a successful body revision change. The host supplies its
/// monotonic clock; selection changes and repeated view paints do not rearm it.
pub fn noteEdit(state: *editor.document_state.State, now_ns: i128) void {
    if (identity(state) == null or state.opened.?.file.read_only) return;
    state.notifications.backup_dirty = true;
    state.notifications.backup_due_ns = now_ns +| backup.debounce_ns;
}

pub const Maintenance = struct {
    attempted: usize = 0,
    failed: usize = 0,
    first_error: ?anyerror = null,
};

/// Per-frame maintenance attempts at most one due document, including failure.
/// Shutdown attempts every distinct document without waiting for debounce.
/// Failures remain observable and pending; they never claim bytes are on disk.
pub fn maintain(store: *Store, io: std.Io, states: []const *editor.document_state.State, now_ns: i128, shutdown: bool) Maintenance {
    var report: Maintenance = .{};
    for (states, 0..) |state, index| {
        var duplicate = false;
        for (states[0..index]) |previous| if (previous == state) {
            duplicate = true;
            break;
        };
        if (duplicate or !state.notifications.backup_dirty) continue;
        if (!shutdown and now_ns < state.notifications.backup_due_ns) continue;
        report.attempted += 1;
        settle(store, io, state) catch |err| {
            // A transient native write/delete failure must not disable recovery.
            state.notifications.backup_dirty = true;
            state.notifications.backup_due_ns = now_ns +| backup.debounce_ns;
            report.failed += 1;
            if (report.first_error == null) report.first_error = err;
        };
        if (!shutdown) break;
    }
    return report;
}

fn settle(store: *Store, io: std.Io, state: *editor.document_state.State) !void {
    const doc = identity(state) orelse return error.MissingDocument;
    const opened = &state.opened.?;
    if (!opened.isDirty()) {
        if (state.notifications.backup_on_disk) try store.drop(io, doc);
        state.notifications.backup_on_disk = false;
        state.notifications.backup_paused = false;
    } else if (opened.file.content.len > store.limit) {
        // Retain the last recovery record and expose degraded protection. A new
        // edit rearms maintenance so shrinking below the cap resumes storage.
        state.notifications.backup_paused = true;
    } else {
        try store.write(io, doc, opened.file.content);
        state.notifications.backup_on_disk = true;
        state.notifications.backup_paused = false;
    }
    state.notifications.backup_dirty = false;
}

const a_test = std.testing.allocator;
const io_test = std.testing.io;
const doc_test: backup.Doc = .{ .path = .{ .path = "D:\\fixture\\file.zig", .disk_hash = 17 } };
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW([*:0]const u16, u32, *?*anyopaque, ?*u32) callconv(abi.winapi) w.BOOL;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(abi.winapi) ?*anyopaque;
extern "kernel32" fn CreateHardLinkW([*:0]const u16, [*:0]const u16, ?*anyopaque) callconv(abi.winapi) w.BOOL;
extern "ntdll" fn NtSetSecurityObject(w.HANDLE, u32, *const anyopaque) callconv(abi.winapi) w.NTSTATUS;
extern "kernel32" fn DeviceIoControl(w.HANDLE, u32, ?*const anyopaque, u32, ?*anyopaque, u32, *u32, ?*anyopaque) callconv(abi.winapi) w.BOOL;

fn broadPermissions(handle: w.HANDLE) !void {
    var descriptor: ?*anyopaque = null;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;FA;;;WD)"), 1, &descriptor, null).toBool()) return error.FixtureSecurityFailed;
    defer _ = LocalFree(descriptor);
    if (NtSetSecurityObject(handle, 0x80000004, descriptor.?) != .SUCCESS) return error.FixtureSecurityFailed;
}
fn rawWrite(store: *Store, doc: backup.Doc, bytes: []const u8) !void {
    var name: [backup.max_file_name_len]u8 = undefined;
    const file = try node(a_test, store.dir, backup.fileName(&name, doc), &store.policy, false, false, 0x001f01ff, false);
    defer file.close(io_test);
    try NativeWrite.write(file, io_test, bytes);
}
fn recordCount(store: *Store) !usize {
    var iterator = store.dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io_test)) |_| count += 1;
    return count;
}

fn editFixture(state: *editor.document_state.State, body: []const u8) !void {
    var view: editor.view_navigation.View = .{};
    defer view.deinit(a_test);
    try view.move(a_test, &state.opened.?.file, .select_all, false);
    const participants = [_]editor.edit_commands.Participant{.{ .view = &view, .id = 1 }};
    _ = try editor.edit_commands.run(a_test, state, &participants, 0, .{ .insert = body }, .{ .now_ms = 0, .isolate = true });
}

fn restorePermissions(store: *Store) void {
    std.debug.assert(NtSetSecurityObject(store.dir.handle, 0x80000004, &store.policy.descriptor) == .SUCCESS);
}

test "Windows editor backup maintenance rearms debounce only after edits and persists at its deadline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    var state = try testState();
    defer state.clear(a_test);
    try editFixture(&state, "changed");
    noteEdit(&state, 0);
    noteEdit(&state, 10);
    const states = [_]*editor.document_state.State{&state};
    try std.testing.expectEqual(@as(usize, 0), maintain(&store, io_test, &states, backup.debounce_ns, false).attempted);
    try std.testing.expectEqual(@as(usize, 0), try recordCount(&store));
    const report = maintain(&store, io_test, &states, backup.debounce_ns + 10, false);
    try std.testing.expectEqual(@as(usize, 1), report.attempted);
    try std.testing.expectEqual(@as(usize, 0), report.failed);
    try std.testing.expect(!state.notifications.backup_dirty and state.notifications.backup_on_disk);
    try expectBody(&store, identity(&state).?, "changed");
    try std.testing.expectEqual(@as(usize, 0), maintain(&store, io_test, &states, backup.debounce_ns + 20, false).attempted);
}

test "Windows editor backup maintenance limits frames and flushes all distinct documents before debounce" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    var first = try testState();
    defer first.clear(a_test);
    var second = try testState();
    defer second.clear(a_test);
    second.clearPath(a_test);
    second.path = try a_test.dupe(u8, "D:\\fixture\\other.zig");
    try editFixture(&first, "first");
    try editFixture(&second, "second");
    noteEdit(&first, 0);
    noteEdit(&second, 0);
    const states = [_]*editor.document_state.State{ &first, &first, &second };
    try std.testing.expectEqual(@as(usize, 1), maintain(&store, io_test, &states, backup.debounce_ns, false).attempted);
    try std.testing.expectEqual(@as(usize, 1), try recordCount(&store));
    try std.testing.expect(second.notifications.backup_dirty);
    noteEdit(&first, 20);
    noteEdit(&second, 20);
    const report = maintain(&store, io_test, &states, 21, true);
    try std.testing.expectEqual(@as(usize, 2), report.attempted);
    try std.testing.expectEqual(@as(usize, 0), report.failed);
    try expectBody(&store, identity(&first).?, "first");
    try expectBody(&store, identity(&second).?, "second");
}

test "Windows editor backup maintenance retains failed writes and does not repeat shared views in shutdown" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    var state = try testState();
    defer state.clear(a_test);
    try editFixture(&state, "unsaved");
    noteEdit(&state, 0);
    try broadPermissions(store.dir.handle);
    defer restorePermissions(&store);
    const states = [_]*editor.document_state.State{ &state, &state };
    const report = maintain(&store, io_test, &states, 10, true);
    try std.testing.expectEqual(@as(usize, 1), report.attempted);
    try std.testing.expectEqual(@as(usize, 1), report.failed);
    try std.testing.expectEqual(error.PrivatePermissions, report.first_error.?);
    try std.testing.expect(state.notifications.backup_dirty and !state.notifications.backup_on_disk);
    try std.testing.expectEqual(@as(i128, backup.debounce_ns + 10), state.notifications.backup_due_ns);
    restorePermissions(&store);
    try std.testing.expectEqual(@as(usize, 0), maintain(&store, io_test, &states, 11, false).attempted);
    try std.testing.expectEqual(@as(usize, 0), maintain(&store, io_test, &states, backup.debounce_ns + 10, false).failed);
    try expectBody(&store, identity(&state).?, "unsaved");
}

test "Windows editor backup maintenance deletes clean undo records only after native deletion succeeds" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    var state = try testState();
    defer state.clear(a_test);
    try store.write(io_test, identity(&state).?, "older dirty");
    state.notifications.backup_on_disk = true;
    noteEdit(&state, 0);
    try broadPermissions(store.dir.handle);
    defer restorePermissions(&store);
    const states = [_]*editor.document_state.State{&state};
    try std.testing.expectEqual(@as(usize, 1), maintain(&store, io_test, &states, 1, true).failed);
    try std.testing.expect(state.notifications.backup_dirty and state.notifications.backup_on_disk);
    restorePermissions(&store);
    try expectBody(&store, identity(&state).?, "older dirty");
    try std.testing.expectEqual(@as(usize, 0), maintain(&store, io_test, &states, 2, true).failed);
    try std.testing.expect(!state.notifications.backup_dirty and !state.notifications.backup_on_disk);
    try std.testing.expect(try store.read(io_test, identity(&state).?) == null);
}

test "Windows editor backup maintenance exposes cap pause retains old bytes and resumes after shrink" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 4);
    defer store.deinit(io_test);
    var state = try testState();
    defer state.clear(a_test);
    try store.write(io_test, identity(&state).?, "old");
    state.notifications.backup_on_disk = true;
    try editFixture(&state, "large");
    noteEdit(&state, 0);
    const states = [_]*editor.document_state.State{&state};
    const report = maintain(&store, io_test, &states, 1, true);
    try std.testing.expectEqual(@as(usize, 0), report.failed);
    try std.testing.expect(state.notifications.backup_paused and !state.notifications.backup_dirty and state.notifications.backup_on_disk);
    try expectBody(&store, identity(&state).?, "old");
    try editFixture(&state, "new");
    noteEdit(&state, 2);
    try std.testing.expectEqual(@as(usize, 0), maintain(&store, io_test, &states, 3, true).failed);
    try std.testing.expect(!state.notifications.backup_paused and state.notifications.backup_on_disk);
    try expectBody(&store, identity(&state).?, "new");
}
fn expectBody(store: *Store, doc: backup.Doc, body: []const u8) !void {
    var record = (try store.read(io_test, doc)) orelse return error.MissingFixtureRecord;
    defer record.deinit();
    try std.testing.expectEqualStrings(body, record.parsed.content);
}

test "Windows editor backup creates owner-only native storage and roundtrips the original disk hash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try store.policy.check(store.dir.handle);
    try store.write(io_test, doc_test, "미저장\r\n");
    var changed = doc_test;
    changed.path.disk_hash = 99;
    var record = (try store.read(io_test, changed)).?;
    defer record.deinit();
    try std.testing.expectEqualStrings("미저장\r\n", record.parsed.content);
    try std.testing.expectEqual(@as(?u64, 17), record.parsed.doc.path.disk_hash);
    try std.testing.expectEqual(@as(usize, 1), try recordCount(&store));
}

test "Windows editor backup path policy selects durable native data without a macOS fallback" {
    const path = (try maru.user_paths.editorBackupPathFor(a_test, .windows, "/Users/mac", "C:\\Local\\")).?;
    defer a_test.free(path);
    try std.testing.expectEqualStrings("C:/Local/maru/editor-backups", path);
    try std.testing.expect(try maru.user_paths.editorBackupPathFor(a_test, .windows, "C:\\Home", null) == null);
    try std.testing.expect(try maru.user_paths.editorBackupPathFor(a_test, .windows, "C:\\Home", "relative") == null);
    const mac = (try maru.user_paths.editorBackupPathFor(a_test, .macos, "/Users/mac/", null)).?;
    defer a_test.free(mac);
    try std.testing.expectEqualStrings("/Users/mac/Library/Application Support/maru/editor-backups", mac);
}

test "Windows editor backup retains all identity kinds across close and only drops the requested record" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    const untitled: backup.Doc = .{ .untitled = 3 };
    const remote: backup.Doc = .{ .remote = .{ .dest = "host", .path = "/work/file.zig" } };
    try store.write(io_test, doc_test, "path");
    try store.write(io_test, untitled, "untitled");
    try store.write(io_test, remote, "remote");
    store.deinit(io_test);
    store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try expectBody(&store, doc_test, "path");
    try expectBody(&store, untitled, "untitled");
    try expectBody(&store, remote, "remote");
    try store.drop(io_test, untitled);
    try std.testing.expect(try store.read(io_test, untitled) == null);
    try expectBody(&store, remote, "remote");
    try store.drop(io_test, untitled);
}

test "Windows editor backup refuses an existing broad directory without repairing it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try Store.open(a_test, tmp.dir, "broad", 128);
    try broadPermissions(directory.dir.handle);
    directory.deinit(io_test);
    try std.testing.expectError(error.PrivatePermissions, Store.open(a_test, tmp.dir, "broad", 128));
}

test "Windows editor backup revalidates directory privacy before write read and drop" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try store.write(io_test, doc_test, "old");
    try broadPermissions(store.dir.handle);
    try std.testing.expectError(error.PrivatePermissions, store.write(io_test, doc_test, "new"));
    try std.testing.expectError(error.PrivatePermissions, store.read(io_test, doc_test));
    try std.testing.expectError(error.PrivatePermissions, store.drop(io_test, doc_test));
    if (NtSetSecurityObject(store.dir.handle, 0x80000004, &store.policy.descriptor) != .SUCCESS) return error.FixtureSecurityFailed;
    try expectBody(&store, doc_test, "old");
}

test "Windows editor backup rejects malformed and mismatched records while preserving their disk bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try store.write(io_test, doc_test, "old");
    try rawWrite(&store, doc_test, "broken");
    try std.testing.expectError(error.BadHeader, store.read(io_test, doc_test));
    try std.testing.expectEqual(@as(usize, 1), try recordCount(&store));
    const wrong = try backup.encode(a_test, .{ .path = .{ .path = "D:\\other.zig" } }, "wrong document");
    defer a_test.free(wrong);
    try rawWrite(&store, doc_test, wrong);
    try std.testing.expectError(error.WrongBackupIdentity, store.read(io_test, doc_test));
    try std.testing.expectEqual(@as(usize, 1), try recordCount(&store));
}

test "Windows editor backup enforces body limits and UTF8 on writing and hostile stored records" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 4);
    defer store.deinit(io_test);
    try store.write(io_test, doc_test, "old");
    try std.testing.expectError(error.BackupTooLarge, store.write(io_test, doc_test, "large"));
    try std.testing.expectError(error.InvalidBackupUtf8, store.write(io_test, doc_test, "\xff"));
    try expectBody(&store, doc_test, "old");
    const corrupt = try backup.encode(a_test, doc_test, "\xff");
    defer a_test.free(corrupt);
    try rawWrite(&store, doc_test, corrupt);
    try std.testing.expectError(error.InvalidBackupUtf8, store.read(io_test, doc_test));
    const oversized = try backup.encode(a_test, doc_test, "large");
    defer a_test.free(oversized);
    try rawWrite(&store, doc_test, oversized);
    try std.testing.expectError(error.BackupTooLarge, store.read(io_test, doc_test));
}

test "Windows editor backup rejects hardlinked records before read overwrite or deletion" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try store.write(io_test, doc_test, "old");
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try store.dir.realPath(io_test, &root);
    var name: [backup.max_file_name_len]u8 = undefined;
    const original = try std.fs.path.join(a_test, &.{ root[0..n], backup.fileName(&name, doc_test) });
    defer a_test.free(original);
    const alias = try std.fs.path.join(a_test, &.{ root[0..n], "alias" });
    defer a_test.free(alias);
    const original_wide = try std.unicode.utf8ToUtf16LeAllocZ(a_test, original);
    defer a_test.free(original_wide);
    const alias_wide = try std.unicode.utf8ToUtf16LeAllocZ(a_test, alias);
    defer a_test.free(alias_wide);
    if (!CreateHardLinkW(alias_wide, original_wide, null).toBool()) return error.FixtureLinkFailed;
    try std.testing.expectError(error.HardLinked, store.read(io_test, doc_test));
    try std.testing.expectError(error.HardLinked, store.write(io_test, doc_test, "new"));
    try std.testing.expectError(error.HardLinked, store.drop(io_test, doc_test));
    try store.dir.deleteFile(io_test, "alias");
    try expectBody(&store, doc_test, "old");
}

test "Windows editor backup failed partial write preserves previous backup and removes its owned stage" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Partial = struct {
        fn write(file: std.Io.File, io: std.Io, _: []const u8) !void {
            try NativeWrite.write(file, io, "partial");
            return error.DiskFull;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try store.write(io_test, doc_test, "old");
    try std.testing.expectError(error.DiskFull, store.writeWith(io_test, doc_test, "new", Partial));
    try expectBody(&store, doc_test, "old");
    try std.testing.expectEqual(@as(usize, 1), try recordCount(&store));
}

test "Windows editor backup write allocation prefixes preserve previous data and release every stage" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try store.write(io_test, doc_test, "old");
    for (0..128) |index| {
        var failing: std.testing.FailingAllocator = .init(a_test, .{ .fail_index = index });
        store.allocator = failing.allocator();
        const result = store.write(io_test, doc_test, "new");
        store.allocator = a_test;
        if (result) |_| {
            try expectBody(&store, doc_test, "new");
            try std.testing.expectEqual(@as(usize, 1), try recordCount(&store));
            return;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try expectBody(&store, doc_test, "old");
            try std.testing.expectEqual(@as(usize, 1), try recordCount(&store));
        }
    }
    return error.AllocationPrefixesNotExhausted;
}

test "Windows editor backup read allocation prefixes preserve record and release native handles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try store.write(io_test, doc_test, "old");
    for (0..128) |index| {
        var failing: std.testing.FailingAllocator = .init(a_test, .{ .fail_index = index });
        store.allocator = failing.allocator();
        const result = store.read(io_test, doc_test);
        store.allocator = a_test;
        if (result) |value| {
            var record = value.?;
            record.deinit();
            return;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        // A leaked read handle would block this actual atomic replacement.
        try store.write(io_test, doc_test, "old");
    }
    return error.AllocationPrefixesNotExhausted;
}

test "Windows editor backup recovery retains old fingerprint and rejects actual external disk overwrite" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_test, .{ .sub_path = "source.zig", .data = "\xef\xbb\xbfexternal\r\n" });
    var registry: editor.document_registry.Registry = .{ .allocator = a_test };
    defer registry.deinit() catch unreachable;
    var opened = try @import("document_grant.zig").Grant.openExperimental(a_test, io_test, tmp.dir, "source.zig", &registry, 128);
    defer opened.grant.deinit(io_test);
    defer _ = registry.release(opened.view) catch unreachable;
    const doc: backup.Doc = .{ .path = .{ .path = opened.grant.path, .disk_hash = editor.document_state.contentHash("\xef\xbb\xbfbase\r\n") } };
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try store.write(io_test, doc, "recovered\r\n");
    var record = (try store.read(io_test, doc)).?;
    defer record.deinit();
    const state = registry.get(opened.view).?;
    var left: editor.view_navigation.View = .{};
    defer left.deinit(a_test);
    var right: editor.view_navigation.View = .{};
    defer right.deinit(a_test);
    const views = [_]editor.edit_commands.Participant{ .{ .view = &left, .id = 1 }, .{ .view = &right, .id = 2 } };
    try restorePath(a_test, state, &record, &views, 0, 128);
    try std.testing.expectEqualStrings("recovered\r\n", state.opened.?.file.content);
    try std.testing.expect(state.opened.?.isDirty());
    try std.testing.expectEqual(doc.path.disk_hash, state.opened.?.disk_hash);
    var request = try editor.save_request.Request.begin(a_test, &registry, opened.view, 128);
    defer request.deinit();
    if (opened.grant.beginExperimental(io_test, &request, 128)) |value| {
        var unexpected = value;
        try unexpected.close(io_test);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.SourceChanged, err);
    _ = try editor.edit_commands.run(a_test, state, &views, 1, .undo, .{ .now_ms = 1 });
    try std.testing.expectEqualStrings("external\r\n", state.opened.?.file.content);
    try std.testing.expect(!state.opened.?.isDirty());
    const disk = try tmp.dir.readFileAlloc(io_test, "source.zig", a_test, .limited(128));
    defer a_test.free(disk);
    try std.testing.expectEqualStrings("\xef\xbb\xbfexternal\r\n", disk);
    try expectBody(&store, doc, "recovered\r\n");
}

test "Windows editor backup restoration allocation prefixes preserve body fingerprint history and peer views" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try store.write(io_test, doc_test, "restored");
    var record = (try store.read(io_test, doc_test)).?;
    defer record.deinit();
    for (0..128) |index| {
        var state = try testState();
        defer state.clear(a_test);
        var left: editor.view_navigation.View = .{};
        defer left.deinit(a_test);
        var right: editor.view_navigation.View = .{};
        defer right.deinit(a_test);
        try left.move(a_test, &state.opened.?.file, .right, false);
        try right.move(a_test, &state.opened.?.file, .document_end, false);
        const views = [_]editor.edit_commands.Participant{ .{ .view = &left, .id = 1 }, .{ .view = &right, .id = 2 } };
        var failing: std.testing.FailingAllocator = .init(a_test, .{ .fail_index = index });
        if (restorePath(failing.allocator(), &state, &record, &views, 0, 128)) |_| {
            try std.testing.expectEqualStrings("restored", state.opened.?.file.content);
            try std.testing.expectEqual(@as(?u64, 17), state.opened.?.disk_hash);
            try std.testing.expect(state.notifications.backup_on_disk);
            return;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqualStrings("disk", state.opened.?.file.content);
        try std.testing.expectEqual(@as(u64, 0), state.opened.?.file.revision);
        try std.testing.expectEqual(@as(?u64, 99), state.opened.?.disk_hash);
        try std.testing.expect(!state.notifications.backup_on_disk);
        try std.testing.expectEqual(@as(usize, 1), left.items.items[0].focus);
        try std.testing.expectEqual(@as(usize, 4), right.items.items[0].focus);
        try std.testing.expectEqual(@as(usize, 0), state.history.undo.len);
    }
    return error.AllocationPrefixesNotExhausted;
}

test "Windows editor backup restoration refuses wrong identity readonly state and aliased views" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    try store.write(io_test, doc_test, "restored");
    var record = (try store.read(io_test, doc_test)).?;
    defer record.deinit();
    var state = try testState();
    defer state.clear(a_test);
    var view: editor.view_navigation.View = .{};
    defer view.deinit(a_test);
    const views = [_]editor.edit_commands.Participant{.{ .view = &view, .id = 1 }};
    state.opened.?.file.read_only = true;
    try std.testing.expectError(error.ReadOnly, restorePath(a_test, &state, &record, &views, 0, 128));
    state.opened.?.file.read_only = false;
    const old_path = record.parsed.doc.path.path;
    record.parsed.doc.path.path = "D:\\other.zig";
    defer record.parsed.doc.path.path = old_path;
    try std.testing.expectError(error.WrongBackupIdentity, restorePath(a_test, &state, &record, &views, 0, 128));
    record.parsed.doc.path.path = old_path;
    const aliased = [_]editor.edit_commands.Participant{ .{ .view = &view, .id = 1 }, .{ .view = &view, .id = 2 } };
    try std.testing.expectError(error.DuplicateView, restorePath(a_test, &state, &record, &aliased, 0, 128));
    try std.testing.expectEqualStrings("disk", state.opened.?.file.content);
    try std.testing.expectEqual(@as(?u64, 99), state.opened.?.disk_hash);
}

test "Windows editor backup refuses a selected directory changed into a native junction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io_test, "outside", .default_dir);
    var store = try Store.open(a_test, tmp.dir, "backups", 128);
    defer store.deinit(io_test);
    var target = try tmp.dir.openDir(io_test, "outside", .{ .iterate = true });
    defer target.close(io_test);
    var target_path: [std.fs.max_path_bytes]u8 = undefined;
    const n = try target.realPath(io_test, &target_path);
    const wide = try std.unicode.utf8ToUtf16LeAlloc(a_test, target_path[0..n]);
    defer a_test.free(wide);
    // Same official mount-point fixture layout as relative_file's native gate.
    // https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_reparse_data_buffer
    var data: extern struct {
        tag: u32 = 0xa0000003,
        length: u16 = 0,
        reserved: u16 = 0,
        substitute_offset: u16 = 0,
        substitute_length: u16 = 0,
        print_offset: u16 = 0,
        print_length: u16 = 0,
        path: [4096]u16 = @splat(0),
    } = .{};
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\??\\");
    const count = prefix.len + wide.len;
    if (count + 2 > data.path.len) return error.FixturePathTooLong;
    @memcpy(data.path[0..prefix.len], prefix);
    @memcpy(data.path[prefix.len..count], wide);
    data.substitute_length = @intCast(count * 2);
    data.print_offset = @intCast((count + 1) * 2);
    data.length = @intCast(8 + (count + 2) * 2);
    var returned: u32 = 0;
    if (!DeviceIoControl(store.dir.handle, 0x000900a4, &data, 8 + @as(u32, data.length), null, 0, &returned, null).toBool()) return error.FixtureReparseFailed;
    defer {
        var remove: extern struct { tag: u32 = 0xa0000003, length: u16 = 0, reserved: u16 = 0 } = .{};
        if (!DeviceIoControl(store.dir.handle, 0x000900ac, &remove, @sizeOf(@TypeOf(remove)), null, 0, &returned, null).toBool()) @panic("fixture junction cleanup failed");
    }
    try std.testing.expectError(error.ReparsePoint, store.write(io_test, doc_test, "must not escape"));
    try std.testing.expectError(error.ReparsePoint, store.read(io_test, doc_test));
    try std.testing.expectError(error.ReparsePoint, store.drop(io_test, doc_test));
    var iterator = target.iterate();
    try std.testing.expect(try iterator.next(io_test) == null);
}
