//! Host-owned original-file authority for an experimental local document.
//! The read image and full file ID come from one selected, handle-relative file;
//! later save requests cannot substitute another registry, lifetime or name.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const editor = maru.session.editor;
const registry_mod = editor.document_registry;
const relative = maru.win32_relative_file;
const identity_mod = @import("identity.zig");
const transaction_mod = @import("transaction.zig");
const w = std.os.windows;
const native_open = @import("native_open.zig");

pub const Attempt = struct {
    pinned: relative.Pinned,
    transaction: transaction_mod.Transaction,

    pub fn close(self: *Attempt, io: std.Io) !void {
        if (self.transaction.phase == .closed) return error.InvalidState;
        defer self.pinned.deinit(io);
        try self.transaction.close(io);
    }
};

pub const Opened = struct { grant: Grant, view: registry_mod.Lease };
pub const Grant = struct {
    allocator: std.mem.Allocator,
    registry: *registry_mod.Registry,
    lease: registry_mod.Lease,
    root: std.Io.Dir,
    relative_path: []u8,
    original: std.Io.File,
    identity: identity_mod.Identity,
    path: []u8,
    epoch: u64,

    /// The caller selects the root; counted relative traversal rejects links,
    /// ADS and escapes. This does not enable ordinary GUI saves or claim TxF
    /// capability/crash-recovery support. The returned view is a separate lease.
    pub fn openExperimental(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir, name: []const u8, registry: *registry_mod.Registry, limit: usize) !Opened {
        var snapshot = try native_open.Snapshot.open(a, io, root, name, limit);
        defer snapshot.deinit(io);
        return publishOpen(a, registry, &snapshot);
    }

    /// Only the app owner publishes. Failure leaves the native image and handles
    /// with the caller; success consumes them after every Registry allocation.
    pub fn publishOpen(a: std.mem.Allocator, registry: *registry_mod.Registry, snapshot: *native_open.Snapshot) !Opened {
        try snapshot.validate();
        var state: editor.document_state.State = .{};
        defer state.clear(a);
        const file = try editor.edit_doc.EditableFile.init(a, snapshot.bytes, false);
        state.opened = .{ .file = file, .saved_hash = editor.document_state.contentHash(file.content), .disk_hash = snapshot.raw_hash };
        state.path = try a.dupe(u8, snapshot.path);
        const epoch = state.persistence.epoch;
        const view = try registry.create(&state, a);
        errdefer _ = registry.release(view) catch unreachable;
        const lease = try registry.retain(view, .request);
        const grant: Grant = .{ .allocator = snapshot.allocator, .registry = registry, .lease = lease, .root = snapshot.root, .relative_path = snapshot.relative_path, .original = snapshot.original, .identity = snapshot.identity, .path = snapshot.path, .epoch = epoch };
        // No fallible work follows ownership transfer. Decoded text is app-owned;
        // raw bytes are no longer borrowed after publication.
        snapshot.allocator.free(snapshot.bytes);
        snapshot.owned = false;
        return .{ .view = view, .grant = grant };
    }

    pub fn validate(self: *const Grant, request: *const editor.save_request.Request) !void {
        if (request.registry != self.registry or request.lease.owner != self.lease.owner) return error.WrongGrantRegistry;
        if (!std.meta.eql(request.lease.document, self.lease.document)) return error.WrongGrantDocument;
        if (request.epoch != self.epoch) return error.StaleGrant;
        if (!std.mem.eql(u8, request.path, self.path)) return error.GrantPathChanged;
        if (self.registry.get(self.lease) == null) return error.StaleGrant;
        try request.validateForWrite();
    }

    pub fn beginExperimental(self: *const Grant, io: std.Io, request: *const editor.save_request.Request, limit: usize) !Attempt {
        try self.validate(request);
        var pinned = try relative.open(self.allocator, self.root, self.relative_path);
        errdefer pinned.deinit(io);
        // Re-pin only during the save attempt, then compare with the FIRST read's
        // ID. Capturing a new ID here as the baseline would authorize replacement.
        if (!self.identity.eql(try identity_mod.Identity.capture(pinned.original.handle))) return error.IdentityChanged;
        const transaction = try transaction_mod.Transaction.beginExperimental(self.allocator, io, &pinned, request.expectedSourceHash(), limit);
        return .{ .pinned = pinned, .transaction = transaction };
    }

    /// The final native object must belong to this read grant as well as the
    /// document request; equal bytes in a second file do not authorize its write.
    pub fn commit(self: *const Grant, io: std.Io, attempt: *Attempt, request: *const editor.save_request.Request) !void {
        const tx = &attempt.transaction;
        try self.validate(request);
        if (!self.identity.eql(tx.identity)) return error.WrongGrantFile;
        // A matching file ID alone is not proof of its name inside the selected
        // root. Re-pin the grant-relative name and keep that fence through commit.
        var current = try relative.open(self.allocator, self.root, self.relative_path);
        defer current.deinit(io);
        if (!self.identity.eql(try identity_mod.Identity.capture(current.original.handle))) return error.IdentityChanged;
        try tx.commitDocument(io, request);
    }

    pub fn deinit(self: *Grant, io: std.Io) void {
        self.original.close(io);
        self.root.close(io);
        self.allocator.free(self.relative_path);
        self.allocator.free(self.path);
        _ = self.registry.release(self.lease) catch @panic("document grant lease lost");
        self.* = undefined;
    }
};

const test_allocator = std.testing.allocator;
fn requestFor(registry: *registry_mod.Registry, lease: registry_mod.Lease) !editor.save_request.Request {
    return editor.save_request.Request.begin(test_allocator, registry, lease, 128);
}
fn expectBeginError(expected: anyerror, grant: *const Grant, request: *const editor.save_request.Request) !void {
    if (grant.beginExperimental(std.testing.io, request, 128)) |value| {
        var tx = value;
        defer tx.close(std.testing.io) catch unreachable;
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(expected, err);
}

test "Windows document grant reads the saved object and retains document after view close" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "\xef\xbb\xbfbase\r\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = original });
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    var opened = try Grant.openExperimental(test_allocator, io, tmp.dir, "file.txt", &registry, 128);
    defer opened.grant.deinit(io);
    var view_owned = true;
    defer if (view_owned) {
        _ = registry.release(opened.view) catch unreachable;
    };
    const state = registry.get(opened.view).?;
    try std.testing.expectEqualStrings("base\r\n", state.opened.?.file.content);
    try std.testing.expectEqual(@as(?u64, editor.document_state.contentHash(original)), state.opened.?.disk_hash);
    var view: editor.view_navigation.View = .{};
    defer view.deinit(test_allocator);
    const participants = [_]editor.edit_commands.Participant{.{ .view = &view, .id = opened.view.id }};
    _ = try editor.edit_commands.run(test_allocator, state, &participants, 0, .{ .insert = "X" }, .{ .now_ms = 100 });
    var request = try requestFor(&registry, opened.view);
    defer request.deinit();
    try std.testing.expect(!try registry.release(opened.view));
    view_owned = false;
    try std.testing.expectEqual(@as(usize, 0), registry.viewCount(opened.grant.lease).?);
    var tx = try opened.grant.beginExperimental(io, &request, 128);
    defer tx.close(io) catch unreachable;
    try tx.transaction.writeDocument(io, &request);
    try opened.grant.commit(io, &tx, &request);
    try tx.transaction.acknowledgeDocument(&request);
    try std.testing.expect(!state.opened.?.isDirty());
    const bytes = try tmp.dir.readFileAlloc(io, "file.txt", test_allocator, .limited(128));
    defer test_allocator.free(bytes);
    try std.testing.expectEqualStrings("\xef\xbb\xbfXbase\r\n", bytes);
    try std.testing.expect(opened.grant.identity.eql(tx.transaction.identity));
}

test "Windows document grant refuses equal-byte replacement of its original name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base" });
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    var opened = try Grant.openExperimental(test_allocator, io, tmp.dir, "file.txt", &registry, 128);
    defer opened.grant.deinit(io);
    defer _ = registry.release(opened.view) catch unreachable;
    var request = try requestFor(&registry, opened.view);
    defer request.deinit();
    try tmp.dir.rename("file.txt", tmp.dir, "moved.txt", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base" });
    try expectBeginError(error.IdentityChanged, &opened.grant, &request);
    const bytes = try tmp.dir.readFileAlloc(io, "file.txt", test_allocator, .limited(128));
    defer test_allocator.free(bytes);
    try std.testing.expectEqualStrings("base", bytes);
}

fn wrongDocument(foreign_registry: bool) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base" });
    var first: registry_mod.Registry = .{ .allocator = test_allocator };
    defer first.deinit() catch unreachable;
    var second: registry_mod.Registry = .{ .allocator = test_allocator };
    defer second.deinit() catch unreachable;
    var one = try Grant.openExperimental(test_allocator, io, tmp.dir, "file.txt", &first, 128);
    defer one.grant.deinit(io);
    defer _ = first.release(one.view) catch unreachable;
    const registry = if (foreign_registry) &second else &first;
    var two = try Grant.openExperimental(test_allocator, io, tmp.dir, "file.txt", registry, 128);
    defer two.grant.deinit(io);
    defer _ = registry.release(two.view) catch unreachable;
    var request = try requestFor(registry, two.view);
    defer request.deinit();
    try expectBeginError(if (foreign_registry) error.WrongGrantRegistry else error.WrongGrantDocument, &one.grant, &request);
}
test "Windows document grant rejects another document with identical path and bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try wrongDocument(false);
}
test "Windows document grant rejects another registry with matching slot and generation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try wrongDocument(true);
}

fn changedLifetime(reload: bool) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base" });
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    var opened = try Grant.openExperimental(test_allocator, io, tmp.dir, "file.txt", &registry, 128);
    defer opened.grant.deinit(io);
    defer _ = registry.release(opened.view) catch unreachable;
    const state = registry.get(opened.view).?;
    if (reload) {
        state.clearOpened(test_allocator);
        const file = try editor.edit_doc.EditableFile.init(test_allocator, "base", false);
        state.opened = .{ .file = file, .saved_hash = editor.document_state.contentHash(file.content), .disk_hash = editor.document_state.contentHash("base") };
    } else {
        const path = try test_allocator.dupe(u8, "different.txt");
        test_allocator.free(state.path.?);
        state.path = path;
    }
    var request = try requestFor(&registry, opened.view);
    defer request.deinit();
    try expectBeginError(if (reload) error.StaleGrant else error.GrantPathChanged, &opened.grant, &request);
}
test "Windows document grant rejects a reloaded lifetime even with identical path and bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try changedLifetime(true);
}
test "Windows document grant rejects a new request after the document changes path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try changedLifetime(false);
}

test "Windows document grant refuses commit of a second equal-byte native file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.txt", .data = "base" });
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    var opened = try Grant.openExperimental(test_allocator, io, tmp.dir, "file.txt", &registry, 128);
    defer opened.grant.deinit(io);
    defer _ = registry.release(opened.view) catch unreachable;
    const state = registry.get(opened.view).?;
    var view: editor.view_navigation.View = .{};
    defer view.deinit(test_allocator);
    const participants = [_]editor.edit_commands.Participant{.{ .view = &view, .id = opened.view.id }};
    _ = try editor.edit_commands.run(test_allocator, state, &participants, 0, .{ .insert = "X" }, .{ .now_ms = 100 });
    var request = try requestFor(&registry, opened.view);
    defer request.deinit();
    var other = try relative.open(test_allocator, tmp.dir, "other.txt");
    var transferred = false;
    defer if (!transferred) other.deinit(io);
    var tx: Attempt = .{ .pinned = other, .transaction = try transaction_mod.Transaction.beginExperimental(test_allocator, io, &other, request.expected_disk_hash, 128) };
    transferred = true;
    defer tx.close(io) catch unreachable;
    try tx.transaction.writeDocument(io, &request);
    try std.testing.expectError(error.WrongGrantFile, opened.grant.commit(io, &tx, &request));
    try std.testing.expectEqual(transaction_mod.Phase.prepared, tx.transaction.phase);
    try std.testing.expect(tx.transaction.file_open);
    try std.testing.expect(state.opened.?.isDirty());
    try tx.transaction.rollback();
    const bytes = try tmp.dir.readFileAlloc(io, "other.txt", test_allocator, .limited(128));
    defer test_allocator.free(bytes);
    try std.testing.expectEqualStrings("base", bytes);
}

fn allocationPrefix(allocator: std.mem.Allocator, root: std.Io.Dir) !void {
    var registry: registry_mod.Registry = .{ .allocator = allocator };
    defer registry.deinit() catch unreachable;
    const opened = Grant.openExperimental(allocator, std.testing.io, root, "a/file.txt", &registry, 128) catch |err| {
        if (err == error.OutOfMemory) {
            // A leaked parent handle would keep this actual rename fenced even
            // after heap accounting passed. Check each failed allocation prefix.
            try root.rename("a", root, "moved", std.testing.io);
            try root.rename("moved", root, "a", std.testing.io);
        }
        return err;
    };
    var grant = opened.grant;
    defer grant.deinit(std.testing.io);
    defer _ = registry.release(opened.view) catch unreachable;
}
test "Windows document grant allocation failures release document and native parent pins" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "a", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a/file.txt", .data = "base" });
    try std.testing.checkAllAllocationFailures(test_allocator, allocationPrefix, .{tmp.dir});
}

fn expectOpenError(expected: anyerror, result: anyerror!Opened, io: std.Io, registry: *registry_mod.Registry) !void {
    if (result) |value| {
        var opened = value;
        opened.grant.deinit(io);
        _ = try registry.release(opened.view);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(expected, err);
}

test "Windows document grant refuses an active writer before publishing the read image" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const writer = try tmp.dir.createFile(io, "file.txt", .{ .read = true });
    defer writer.close(io);
    try writer.writePositionalAll(io, "base", 0);
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    try expectOpenError(error.SourceBusy, Grant.openExperimental(test_allocator, io, tmp.dir, "file.txt", &registry, 128), io, &registry);
    try std.testing.expectEqual(@as(u64, 0), registry.last_reference);
}

test "Windows document grant enforces the raw read limit before creating a document" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "\xef\xbb\xbfbase" });
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    try expectOpenError(error.FileTooLarge, Grant.openExperimental(test_allocator, std.testing.io, tmp.dir, "file.txt", &registry, 6), std.testing.io, &registry);
    try std.testing.expectEqual(@as(u64, 0), registry.last_reference);
}

fn deletionProbe(root: std.Io.Dir, name: []const u8) !w.NTSTATUS {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(test_allocator, name);
    defer test_allocator.free(wide);
    var unicode: w.UNICODE_STRING = .{ .Length = @intCast(wide.len * 2), .MaximumLength = @intCast(wide.len * 2), .Buffer = wide.ptr };
    const attrs: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = root.handle, .ObjectName = &unicode };
    var status: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    const result = w.ntdll.NtCreateFile(&handle, .{ .STANDARD = .{ .RIGHTS = .{ .DELETE = true }, .SYNCHRONIZE = true } }, &attrs, &status, null, .{}, .{ .READ = true, .WRITE = true, .DELETE = true }, .OPEN, .{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true }, null, 0);
    if (result == .SUCCESS) _ = w.ntdll.NtClose(handle);
    return result;
}

test "Windows document grant owns its root and permits ordinary parent rename between save attempts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "grant/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "grant/nested/file.txt", .data = "base" });
    var selected = try tmp.dir.openDir(io, "grant", .{});
    var selected_closed = false;
    defer if (!selected_closed) selected.close(io);
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    var opened = try Grant.openExperimental(test_allocator, io, selected, "nested/file.txt", &registry, 128);
    defer opened.grant.deinit(io);
    defer _ = registry.release(opened.view) catch unreachable;
    selected.close(io);
    selected_closed = true;
    var request = try requestFor(&registry, opened.view);
    defer request.deinit();
    // The ID-opened original witness retains object identity while an ordinary
    // rename is allowed. Missing grant-relative names still deny save authority.
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, try deletionProbe(opened.grant.root, "nested"));
    try tmp.dir.rename("grant/nested", tmp.dir, "grant/moved", io);
    try std.testing.expect(opened.grant.identity.eql(try identity_mod.Identity.capture(opened.grant.original.handle)));
    try expectBeginError(error.NotFound, &opened.grant, &request);
    try tmp.dir.rename("grant/moved", tmp.dir, "grant/nested", io);
    var attempt = try opened.grant.beginExperimental(io, &request, 128);
    var closed = false;
    defer if (!closed) attempt.close(io) catch unreachable;
    try std.testing.expectEqual(w.NTSTATUS.SHARING_VIOLATION, try deletionProbe(opened.grant.root, "nested"));
    try attempt.close(io);
    closed = true;
    try std.testing.expectEqual(w.NTSTATUS.SUCCESS, try deletionProbe(opened.grant.root, "nested"));
    try tmp.dir.rename("grant/nested", tmp.dir, "grant/moved", io);
    try tmp.dir.rename("grant/moved", tmp.dir, "grant/nested", io);
}

fn saveAllocationPrefix(allocator: std.mem.Allocator, root: std.Io.Dir) !void {
    const io = std.testing.io;
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    var opened = try Grant.openExperimental(test_allocator, io, root, "a/file.txt", &registry, 128);
    defer opened.grant.deinit(io);
    defer _ = registry.release(opened.view) catch unreachable;
    var request = try requestFor(&registry, opened.view);
    defer request.deinit();
    // Fail only save-time preparation while a live read grant stays available.
    opened.grant.allocator = allocator;
    defer opened.grant.allocator = test_allocator;
    var attempt = opened.grant.beginExperimental(io, &request, 128) catch |err| {
        if (err == error.OutOfMemory) {
            try std.testing.expectEqual(w.NTSTATUS.SUCCESS, try deletionProbe(root, "a"));
        }
        return err;
    };
    defer attempt.close(io) catch unreachable;
}

test "Windows document grant save allocation failures release transient parent fences" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "a", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a/file.txt", .data = "base" });
    try std.testing.checkAllAllocationFailures(test_allocator, saveAllocationPrefix, .{tmp.dir});
}

test "Windows document grant initial snapshot publishes raw BOM CAS and decoded text independently" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw = "\xef\xbb\xbfbase\r\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = raw });
    var snapshot = try native_open.Snapshot.open(test_allocator, io, tmp.dir, "file.txt", 128);
    defer snapshot.deinit(io);
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), registry.slots.items.len);
    var opened = try Grant.publishOpen(test_allocator, &registry, &snapshot);
    defer opened.grant.deinit(io);
    defer _ = registry.release(opened.view) catch unreachable;
    const state = registry.get(opened.view).?;
    try std.testing.expectEqualStrings("base\r\n", state.opened.?.file.content);
    try std.testing.expectEqual(@as(?u64, editor.document_state.contentHash(raw)), state.opened.?.disk_hash);
    try std.testing.expect(!snapshot.owned);
    try std.testing.expect(opened.grant.identity.eql(try identity_mod.Identity.capture(opened.grant.original.handle)));
}

test "Windows document grant changed initial image cannot publish a document" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base" });
    var snapshot = try native_open.Snapshot.open(test_allocator, io, tmp.dir, "file.txt", 128);
    defer snapshot.deinit(io);
    snapshot.bytes[0] = 'X';
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    const result = Grant.publishOpen(test_allocator, &registry, &snapshot);
    if (result) |value| {
        var opened = value;
        opened.grant.deinit(io);
        _ = try registry.release(opened.view);
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.OpenImageChanged, err);
    try std.testing.expect(snapshot.owned);
    try std.testing.expectEqual(@as(usize, 0), registry.slots.items.len);
}

test "Windows document grant consumed initial snapshot refuses another publication" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base" });
    var snapshot = try native_open.Snapshot.open(test_allocator, io, tmp.dir, "file.txt", 128);
    defer snapshot.deinit(io);
    var registry: registry_mod.Registry = .{ .allocator = test_allocator };
    defer registry.deinit() catch unreachable;
    var opened = try Grant.publishOpen(test_allocator, &registry, &snapshot);
    defer opened.grant.deinit(io);
    defer _ = registry.release(opened.view) catch unreachable;
    // Remove the consumed, freed byte pointer before testing the owner guard.
    // A broken guard must fail without turning negative verification into UAF.
    snapshot.bytes = &.{};
    snapshot.raw_hash = editor.document_state.contentHash(snapshot.bytes);
    try std.testing.expectError(error.OpenSnapshotConsumed, snapshot.validate());
}

fn publishAllocationPrefix(a: std.mem.Allocator, root: std.Io.Dir) !void {
    const io = std.testing.io;
    var snapshot = try native_open.Snapshot.open(test_allocator, io, root, "file.txt", 128);
    defer snapshot.deinit(io);
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var opened = Grant.publishOpen(a, &registry, &snapshot) catch |err| {
        try std.testing.expect(snapshot.owned);
        try std.testing.expect(snapshot.identity.eql(try identity_mod.Identity.capture(snapshot.original.handle)));
        try snapshot.validate();
        return err;
    };
    defer opened.grant.deinit(io);
    defer _ = registry.release(opened.view) catch unreachable;
    try std.testing.expect(!snapshot.owned);
}

test "Windows document grant publication allocation failure keeps initial native ownership" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "base" });
    try std.testing.checkAllAllocationFailures(test_allocator, publishAllocationPrefix, .{tmp.dir});
}

test "Windows document grant initial snapshot owns root beyond caller close" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base" });
    var selected = try tmp.dir.openDir(io, ".", .{});
    var selected_owned = true;
    defer if (selected_owned) selected.close(io);
    var snapshot = try native_open.Snapshot.open(test_allocator, io, selected, "file.txt", 128);
    defer snapshot.deinit(io);
    selected.close(io);
    selected_owned = false;
    var pinned = try relative.open(test_allocator, snapshot.root, snapshot.relative_path);
    defer pinned.deinit(io);
    try std.testing.expect(snapshot.identity.eql(try identity_mod.Identity.capture(pinned.original.handle)));
    try std.testing.expectEqualStrings("base", snapshot.bytes);
}
