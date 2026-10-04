//! App-owned native save grants outlive individual editor views. The shared
//! registry owns text; this host owns Windows handles and terminal save replies.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const editor = maru.session.editor;
const grants = @import("document_grant.zig");
const saving = @import("save_controller.zig");
const transactions = @import("transaction.zig");
const identity = @import("identity.zig");
const reading = @import("file_read_worker.zig");
const w = std.os.windows;
extern "kernel32" fn GetVolumeInformationByHandleW(w.HANDLE, ?[*]u16, u32, ?*u32, ?*u32, ?*u32, ?[*]u16, u32) callconv(maru.win32_abi.winapi) w.BOOL;
extern "kernel32" fn SetFileAttributesW([*:0]const u16, u32) callconv(maru.win32_abi.winapi) w.BOOL;

fn acceptsVolume(flags: u32, filesystem: []const u16) bool {
    // The SDK flags describe the selected handle's volume, never a drive-letter
    // assumption. Network/other filesystems must not acquire an NTFS save grant.
    // https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getvolumeinformationbyhandlew
    return flags & 0x00200000 != 0 and flags & 0x00080000 == 0 and std.mem.eql(u16, filesystem, std.unicode.utf8ToUtf16LeStringLiteral("NTFS"));
}

pub fn saveKey(resolver: maru.config.keybinding.KeyBindingResolver, event: maru.terminal.KeyEvent) bool {
    const original = resolver.resolveEditor(event, false);
    switch (original) {
        .consumed => return false,
        .app_action => |action| return action == .editor_save,
        .editor => {},
    }
    // Plain Ctrl+S belongs to the shell outside a file. Only this editor-local
    // fallback maps it to the configured primary chord; explicit Ctrl rebind,
    // unbind and terminal macros already won above.
    if (!event.modifiers.control or event.modifiers.command or event.modifiers.shift or event.modifiers.option) return false;
    if (event.key != .char or (event.key.char != 's' and event.key.char != 'S')) return false;
    var primary = event;
    primary.modifiers.control = false;
    primary.modifiers.command = true;
    const result = resolver.resolveEditor(primary, false);
    return result == .app_action and result.app_action == .editor_save;
}

test "Windows editor host save chord honors configured unbind and release without affecting shell modifiers" {
    const defaults: maru.config.keybinding.KeyBindingResolver = .{};
    const ctrl_s: maru.terminal.KeyEvent = .{ .key = .{ .char = 's' }, .modifiers = .{ .control = true } };
    try std.testing.expect(saveKey(defaults, ctrl_s));
    try std.testing.expect(!saveKey(defaults, .{ .key = ctrl_s.key, .modifiers = ctrl_s.modifiers, .event_type = .release }));
    const unbinds = [_]maru.config.keybinding.KeyChord{.{ .key = .{ .char = 'S' }, .modifiers = .{ .command = true } }};
    try std.testing.expect(!saveKey(.{ .unbinds = &unbinds }, ctrl_s));
    const ctrl_unbinds = [_]maru.config.keybinding.KeyChord{.{ .key = .{ .char = 'S' }, .modifiers = .{ .control = true } }};
    try std.testing.expect(!saveKey(.{ .unbinds = &ctrl_unbinds }, ctrl_s));
    try std.testing.expect(ctrl_s.modifiers.control and !ctrl_s.modifiers.command);
}

fn probe(grant: *const grants.Grant, io: std.Io, limit: usize) !void {
    var flags: u32 = 0;
    var filesystem: [16]u16 = @splat(0);
    if (!GetVolumeInformationByHandleW(grant.original.handle, null, 0, null, null, &flags, &filesystem, filesystem.len).toBool()) return error.SaveCapabilityUnavailable;
    const end = std.mem.indexOfScalar(u16, &filesystem, 0) orelse return error.SaveCapabilityUnavailable;
    if (!acceptsVolume(flags, filesystem[0..end])) return error.SaveCapabilityUnavailable;
    var pinned = try maru.win32_relative_file.open(grant.allocator, grant.root, grant.relative_path);
    defer pinned.deinit(io);
    if (!grant.identity.eql(try identity.Identity.capture(pinned.original.handle))) return error.IdentityChanged;
    const state = grant.registry.get(grant.lease).?;
    var tx = try transactions.Transaction.beginExperimental(grant.allocator, io, &pinned, state.opened.?.disk_hash.?, limit);
    // This probe never writes or commits. Even a cleanup failure is reported as
    // unsupported, rather than enabling edits with an unproved native permit.
    defer if (tx.phase != .closed) tx.close(io) catch {};
    try tx.rollback();
    if (try tx.queryOutcome() != .aborted) return error.SaveCapabilityUnavailable;
    try tx.close(io);
}

pub const Book = struct {
    allocator: std.mem.Allocator,
    registry: *editor.document_registry.Registry,
    controllers: std.ArrayList(saving.Controller) = .empty,
    read_scope: u64 = 0,

    pub fn open(self: *Book, io: std.Io, root: std.Io.Dir, name: []const u8, limit: usize) !editor.document_registry.Lease {
        // Allocate the publication slot first. A successfully probed document
        // cannot be stranded by an allocation after native ownership transfers.
        try self.controllers.ensureUnusedCapacity(self.allocator, 1);
        var opened = try grants.Grant.openExperimental(self.allocator, io, root, name, self.registry, limit);
        errdefer opened.grant.deinit(io);
        errdefer _ = self.registry.release(opened.view) catch unreachable;
        try probe(&opened.grant, io, limit);
        self.controllers.appendAssumeCapacity(saving.Controller.take(&opened.grant));
        return opened.view;
    }

    pub fn openPath(self: *Book, io: std.Io, path: []const u8, limit: usize) !editor.document_registry.Lease {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        const parsed = std.fs.path.parsePathWindows(u8, path);
        if (parsed.kind != .drive_absolute and parsed.kind != .unc_absolute) return error.InvalidPath;
        if (parsed.kind == .unc_absolute) {
            var components = std.mem.tokenizeAny(u8, parsed.root, "/\\");
            try maru.win32_relative_file.validateBasename(components.next() orelse return error.InvalidPath);
            try maru.win32_relative_file.validateBasename(components.next() orelse return error.InvalidPath);
        }
        // The native grant walks the full suffix relative to this selected root,
        // rejecting reparse points and escapes instead of reopening its dirname.
        var root = try std.Io.Dir.openDirAbsolute(io, parsed.root, .{ .follow_symlinks = false });
        defer root.close(io);
        return self.open(io, root, path[parsed.root.len..], limit);
    }

    fn index(self: *Book, view: editor.document_registry.Lease) !usize {
        if (view.owner != self.registry or view.kind != .view or self.registry.get(view) == null) return error.StaleDocument;
        for (self.controllers.items, 0..) |controller, i| {
            if (std.meta.eql(controller.grant.lease.document, view.document)) return i;
        }
        return error.NoSaveGrant;
    }

    pub fn readTicket(self: *Book, view: editor.document_registry.Lease) !reading.Ticket {
        const controller = &self.controllers.items[try self.index(view)];
        const state = self.registry.get(view).?;
        if (controller.status() != .idle or state.persistence.uncertain_sequence != null or state.persistence.live_save_images != 0) return error.SaveBusy;
        if (controller.grant.epoch != state.persistence.epoch) return error.StaleGrant;
        if (!std.mem.eql(u8, controller.grant.path, state.path orelse return error.GrantPathChanged)) return error.GrantPathChanged;
        const opened = state.opened orelse return error.MissingDocument;
        if (self.read_scope == 0) self.read_scope = try reading.issueScope();
        return .{ .source_id = self.read_scope, .document = view.document, .epoch = state.persistence.epoch, .revision = opened.file.revision, .disk_hash = opened.disk_hash };
    }

    pub fn submitRead(self: *Book, reader: *reading.Reader, view: editor.document_registry.Lease) !u64 {
        const ticket = try self.readTicket(view);
        const grant = &self.controllers.items[try self.index(view)].grant;
        // Frame-side work only copies the selected handle and counted name.
        // Path traversal, file reads and raw hashing happen on the worker.
        return reader.submit(grant.root, grant.relative_path, grant.identity, ticket, reading.max_bytes);
    }

    pub fn acceptsRead(self: *Book, reader: *const reading.Reader, result: reading.Result, view: editor.document_registry.Lease) !bool {
        const current = try self.readTicket(view);
        if (!reader.accepts(result, current)) return false;
        if (result == .image and !result.image.identity.eql(self.controllers.items[try self.index(view)].grant.identity)) return false;
        return true;
    }

    pub fn save(self: *Book, io: std.Io, view: editor.document_registry.Lease, limit: usize) !?saving.Receipt {
        const controller = &self.controllers.items[try self.index(view)];
        if (controller.status() == .uncertain) {
            const receipt = try controller.reconcile(io);
            if (receipt.acknowledgment_error) |err| return err;
            if (receipt.cleanup_error) |err| std.log.warn("editor save native decision confirmed; cleanup failed({s})", .{@errorName(err)});
        }
        if (controller.status() != .idle) return error.SaveBusy;
        const state = self.registry.get(view).?;
        if (!state.opened.?.isDirty()) return null;
        try controller.prepare(io, view, limit);
        const receipt = try controller.commit(io);
        if (receipt.acknowledgment_error) |err| return err;
        if (receipt.cleanup_error) |err| std.log.warn("editor save committed; cleanup failed({s})", .{@errorName(err)});
        return receipt;
    }

    /// Closing one peer does not revoke the surviving view's save authority.
    /// Last-view discard requires explicit acceptance; pending native ownership
    /// always wins over discard. Backup deletion remains the app's responsibility.
    pub fn requireClose(self: *Book, view: editor.document_registry.Lease, accepted: bool) !void {
        const i = self.index(view) catch |err| {
            if (err == error.NoSaveGrant) return;
            return err;
        };
        if (self.registry.viewCount(view).? > 1) return;
        const controller = &self.controllers.items[i];
        const state = self.registry.get(view).?;
        if (controller.status() != .idle or state.persistence.uncertain_sequence != null or state.persistence.live_save_images != 0) return error.SaveBusy;
        if (!accepted and state.opened.?.isDirty()) return error.DirtyDocument;
    }

    pub fn release(self: *Book, io: std.Io, view: editor.document_registry.Lease, accepted: bool) !void {
        try self.requireClose(view, accepted);
        if (self.registry.viewCount(view).? > 1) return;
        const i = self.index(view) catch |err| {
            if (err == error.NoSaveGrant) return;
            return err;
        };
        try self.controllers.items[i].deinit(io);
        _ = self.controllers.orderedRemove(i);
    }

    pub fn requireIdle(self: *const Book) !void {
        // Refuse before releasing any grant. A blocked teardown must be retryable
        // with every other document still owning its original authority.
        for (self.controllers.items) |controller| {
            const state = self.registry.get(controller.grant.lease).?;
            if (controller.status() != .idle or state.persistence.uncertain_sequence != null or state.persistence.live_save_images != 0) return error.SaveBusy;
        }
    }

    pub fn deinit(self: *Book, io: std.Io) !void {
        try self.requireIdle();
        for (self.controllers.items) |*controller| try controller.deinit(io);
        self.controllers.deinit(self.allocator);
        self.controllers = .empty;
        self.read_scope = 0;
    }
};

test "Windows editor host volume policy refuses missing transaction readonly and foreign filesystem flags" {
    const ntfs = std.unicode.utf8ToUtf16LeStringLiteral("NTFS");
    try std.testing.expect(acceptsVolume(0x00200000, ntfs));
    try std.testing.expect(!acceptsVolume(0, ntfs));
    try std.testing.expect(!acceptsVolume(0x00280000, ntfs));
    try std.testing.expect(!acceptsVolume(0x00200000, std.unicode.utf8ToUtf16LeStringLiteral("ReFS")));
}

fn change(registry: *editor.document_registry.Registry, view: editor.document_registry.Lease, text: []const u8) !void {
    var nav: editor.view_navigation.View = .{};
    defer nav.deinit(std.testing.allocator);
    const peers = [_]editor.edit_commands.Participant{.{ .view = &nav, .id = view.id }};
    _ = try editor.edit_commands.run(std.testing.allocator, registry.get(view).?, &peers, 0, .{ .insert = text }, .{ .now_ms = 10 });
}

test "Windows editor host probes without changing original and saves through surviving peer view" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "\xef\xbb\xbfbase\r\n" });
    var registry: editor.document_registry.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var book: Book = .{ .allocator = a, .registry = &registry };
    defer book.deinit(io) catch unreachable;
    const first = try book.open(io, tmp.dir, "file.txt", 128);
    var first_owned = true;
    defer if (first_owned) {
        _ = registry.release(first) catch unreachable;
    };
    try std.testing.expectEqual(@as(u64, 0), registry.get(first).?.persistence.issued);
    const original = try tmp.dir.readFileAlloc(io, "file.txt", a, .limited(128));
    defer a.free(original);
    try std.testing.expectEqualStrings("\xef\xbb\xbfbase\r\n", original);
    const peer = try registry.retain(first, .view);
    defer _ = registry.release(peer) catch unreachable;
    try book.release(io, first, false);
    _ = try registry.release(first);
    first_owned = false;
    try std.testing.expectEqual(@as(usize, 1), book.controllers.items.len);
    try change(&registry, peer, "X");
    try std.testing.expectError(error.DirtyDocument, book.release(io, peer, false));
    const receipt = (try book.save(io, peer, 128)).?;
    try std.testing.expectEqual(saving.Decision.committed, receipt.decision);
    try std.testing.expect(!registry.get(peer).?.opened.?.isDirty());
    const disk = try tmp.dir.readFileAlloc(io, "file.txt", a, .limited(128));
    defer a.free(disk);
    try std.testing.expectEqualStrings("\xef\xbb\xbfXbase\r\n", disk);
    try book.release(io, peer, false);
    try std.testing.expectEqual(@as(usize, 0), book.controllers.items.len);
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    registry: editor.document_registry.Registry,
    book: Book,
    views: [2]?editor.document_registry.Lease = .{ null, null },

    fn init() !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        errdefer std.testing.allocator.destroy(self);
        self.* = .{ .tmp = std.testing.tmpDir(.{}), .registry = .{ .allocator = std.testing.allocator }, .book = undefined };
        errdefer self.tmp.cleanup();
        self.book = .{ .allocator = std.testing.allocator, .registry = &self.registry };
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "\xef\xbb\xbfbase\r\n" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.txt", .data = "other" });
        return self;
    }
    fn open(self: *Fixture, slot: usize) !editor.document_registry.Lease {
        const view = try self.book.open(std.testing.io, self.tmp.dir, if (slot == 0) "file.txt" else "other.txt", 128);
        self.views[slot] = view;
        return view;
    }
    fn deinit(self: *Fixture) void {
        for (self.book.controllers.items) |*controller| if (controller.pending != null) {
            _ = controller.abort(std.testing.io) catch @panic("unresolved fixture transaction");
        };
        self.book.deinit(std.testing.io) catch unreachable;
        for (self.views) |view| if (view) |lease| {
            _ = self.registry.release(lease) catch unreachable;
        };
        self.registry.deinit() catch unreachable;
        self.tmp.cleanup();
        std.testing.allocator.destroy(self);
    }
};

fn awaitRead(reader: *reading.Reader) !reading.Result {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.awake.now(io).nanoseconds < deadline) {
        if (try reader.takeResult()) |result| return result;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.ReadDidNotComplete;
}

test "Windows editor host worker read uses the app grant and refuses content changed after submission" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const f = try Fixture.init();
    defer f.deinit();
    const view = try f.open(0);
    const old_hash = f.registry.get(view).?.opened.?.disk_hash;
    var other_registry: editor.document_registry.Registry = .{ .allocator = std.testing.allocator };
    defer other_registry.deinit() catch unreachable;
    var other_book: Book = .{ .allocator = std.testing.allocator, .registry = &other_registry };
    defer other_book.deinit(io) catch unreachable;
    const other_view = try other_book.open(io, f.tmp.dir, "file.txt", 128);
    defer _ = other_registry.release(other_view) catch unreachable;
    // External bytes change in the same object; reading must not acknowledge
    // them as a save or mutate the app's shared document behind its views.
    const external = "\xef\xbb\xbfdisk\r\n";
    try f.tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = external });
    var reader: reading.Reader = .{ .allocator = std.testing.allocator };
    defer reader.deinit(io) catch unreachable;
    _ = try f.book.submitRead(&reader, view);
    var result = try awaitRead(&reader);
    defer result.deinit();
    try std.testing.expect(result == .image);
    try std.testing.expectEqualStrings(external, result.image.bytes);
    try std.testing.expect(try f.book.acceptsRead(&reader, result, view));
    try std.testing.expect(!try other_book.acceptsRead(&reader, result, other_view));
    try std.testing.expectEqual(old_hash, f.registry.get(view).?.opened.?.disk_hash);
    try std.testing.expectEqualStrings("base\r\n", f.registry.get(view).?.opened.?.file.content);
    try change(&f.registry, view, "X");
    try std.testing.expect(!try f.book.acceptsRead(&reader, result, view));
}

test "Windows editor host worker admission rejects foreign view stale lifetime path drift and prepared save" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const f = try Fixture.init();
    defer f.deinit();
    const view = try f.open(0);
    var reader: reading.Reader = .{ .allocator = std.testing.allocator };
    defer reader.deinit(io) catch unreachable;
    var foreign: editor.document_registry.Registry = .{ .allocator = std.testing.allocator };
    defer foreign.deinit() catch unreachable;
    var wrong = view;
    wrong.owner = &foreign;
    try std.testing.expectError(error.StaleDocument, f.book.submitRead(&reader, wrong));
    wrong = view;
    wrong.kind = .read;
    try std.testing.expectError(error.StaleDocument, f.book.submitRead(&reader, wrong));
    const state = f.registry.get(view).?;
    {
        const epoch = state.persistence.epoch;
        defer state.persistence.epoch = epoch;
        state.persistence.epoch += 1;
        try std.testing.expectError(error.StaleGrant, f.book.submitRead(&reader, view));
    }
    {
        const path = state.path;
        defer state.path = path;
        state.path = null;
        try std.testing.expectError(error.GrantPathChanged, f.book.submitRead(&reader, view));
    }
    try f.book.controllers.items[0].prepare(io, view, 128);
    try std.testing.expectError(error.SaveBusy, f.book.submitRead(&reader, view));
    try std.testing.expect(reader.job == null and reader.issued == 0);
    _ = try f.book.controllers.items[0].abort(io);
}

test "Windows editor host worker completion refuses changed identity released view and recreated ownership" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const f = try Fixture.init();
    defer f.deinit();
    const view = try f.open(0);
    var reader: reading.Reader = .{ .allocator = std.testing.allocator };
    defer reader.deinit(io) catch unreachable;
    _ = try f.book.submitRead(&reader, view);
    var result = try awaitRead(&reader);
    defer result.deinit();
    try std.testing.expect(result == .image);
    result.image.identity.file[15] ^= 1;
    try std.testing.expect(!try f.book.acceptsRead(&reader, result, view));
    result.image.identity.file[15] ^= 1;
    try std.testing.expect(try f.book.acceptsRead(&reader, result, view));
    try f.book.release(io, view, true);
    _ = try f.registry.release(view);
    f.views[0] = null;
    try std.testing.expectError(error.StaleDocument, f.book.acceptsRead(&reader, result, view));
    try f.book.deinit(io);
    try std.testing.expectEqual(@as(u64, 0), f.book.read_scope);
    try f.registry.deinit();
    f.registry = .{ .allocator = std.testing.allocator };
    f.book = .{ .allocator = std.testing.allocator, .registry = &f.registry };
    const fresh = try f.open(0);
    const current = try f.book.readTicket(fresh);
    // Everything except the source incarnation is deliberately equal, including
    // the Registry address. Comparing slots, bytes or pointers alone is unsafe.
    try std.testing.expect(std.meta.eql(result.image.ticket.document, current.document));
    try std.testing.expectEqual(result.image.ticket.epoch, current.epoch);
    try std.testing.expectEqual(result.image.ticket.revision, current.revision);
    try std.testing.expectEqual(result.image.ticket.disk_hash, current.disk_hash);
    try std.testing.expect(result.image.ticket.source_id != current.source_id);
    try std.testing.expect(!try f.book.acceptsRead(&reader, result, fresh));
}

test "Windows editor host refuses uncertain last close and teardown before releasing any other grant" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const f = try Fixture.init();
    defer f.deinit();
    const idle = try f.open(0);
    const pending = try f.open(1);
    try change(&f.registry, pending, "X");
    const controller = &f.book.controllers.items[1];
    try controller.prepare(io, pending, 128);
    controller.pending.?.attempt.transaction.file.close(io);
    controller.pending.?.attempt.transaction.file_open = false;
    controller.pending.?.attempt.transaction.phase = .uncertain;
    try std.testing.expectError(error.SaveNotCommitted, controller.pending.?.request.complete(.uncertain));
    try std.testing.expectError(error.SaveUncertain, f.book.save(io, pending, 128));
    try std.testing.expectError(error.SaveBusy, f.book.release(io, pending, true));
    try std.testing.expectError(error.SaveBusy, f.book.deinit(io));
    try std.testing.expectEqual(@as(usize, 2), f.book.controllers.items.len);
    try std.testing.expect(!f.book.controllers.items[0].closed);
    try change(&f.registry, idle, "Y");
    _ = try f.book.save(io, idle, 128);
    try std.testing.expectEqual(saving.Status.uncertain, controller.status());
    const receipt = try controller.abort(io);
    try std.testing.expectEqual(saving.Decision.aborted, receipt.decision);
}

test "Windows editor host refuses prepared teardown without implicitly discarding its captured save" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    _ = try f.open(0);
    const view = try f.open(1);
    try change(&f.registry, view, "X");
    try f.book.controllers.items[1].prepare(std.testing.io, view, 128);
    try std.testing.expectError(error.SaveBusy, f.book.deinit(std.testing.io));
    try std.testing.expectEqual(@as(usize, 2), f.book.controllers.items.len);
    try std.testing.expect(!f.book.controllers.items[0].closed);
    try std.testing.expectEqual(saving.Status.prepared, f.book.controllers.items[1].status());
}

test "Windows editor host rejects equal-byte original replacement and retains the unsaved document" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    const view = try f.open(0);
    try f.tmp.dir.rename("file.txt", f.tmp.dir, "original.txt", std.testing.io);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "\xef\xbb\xbfbase\r\n" });
    try change(&f.registry, view, "X");
    try std.testing.expectError(error.IdentityChanged, f.book.save(std.testing.io, view, 128));
    const state = f.registry.get(view).?;
    try std.testing.expect(state.opened.?.isDirty());
    try std.testing.expectEqualStrings("Xbase\r\n", state.opened.?.file.content);
    try std.testing.expectEqual(@as(u64, 0), state.persistence.live_save_images);
    const bytes = try f.tmp.dir.readFileAlloc(std.testing.io, "file.txt", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\xef\xbb\xbfbase\r\n", bytes);
}

test "Windows editor host refuses another registry and a non-view lease even with matching slot identity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    const g = try Fixture.init();
    defer g.deinit();
    const own = try f.open(0);
    const other = try g.open(0);
    try std.testing.expect(std.meta.eql(own.document, other.document));
    try std.testing.expectError(error.StaleDocument, f.book.save(std.testing.io, other, 128));
    try std.testing.expectError(error.StaleDocument, f.book.release(std.testing.io, other, true));
    const request = try f.registry.retain(own, .request);
    defer _ = f.registry.release(request) catch unreachable;
    try std.testing.expectError(error.StaleDocument, f.book.save(std.testing.io, request, 128));
    try std.testing.expectEqual(@as(usize, 1), f.book.controllers.items.len);
}

test "Windows editor host malformed absolute paths never publish an editable document" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ "relative.txt", "C:relative.txt", "\\rooted.txt", "\\\\?\\C:\\file.txt", "C:\\..\\file.txt", "C:\\file.txt:ads", "C:\\file\x00.txt" }) |path| {
        if (f.book.openPath(std.testing.io, path, 128)) |view| {
            _ = f.registry.release(view) catch unreachable;
            return error.TestUnexpectedResult;
        } else |_| {}
        try std.testing.expectEqual(@as(usize, 0), f.book.controllers.items.len);
    }
}

test "Windows editor host readonly original fails capability without publishing a grant" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    const path = try f.tmp.dir.realPathFileAlloc(std.testing.io, "file.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(wide);
    try std.testing.expect(SetFileAttributesW(wide, 1).toBool());
    defer std.debug.assert(SetFileAttributesW(wide, 0x80).toBool());
    if (f.book.open(std.testing.io, f.tmp.dir, "file.txt", 128)) |view| {
        f.views[0] = view;
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 0), f.book.controllers.items.len);
    for (f.registry.slots.items) |slot| try std.testing.expect(slot.document == null);
}

fn allocationPrefixes(a: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "base" });
    var registry: editor.document_registry.Registry = .{ .allocator = std.testing.allocator };
    defer registry.deinit() catch unreachable;
    var book: Book = .{ .allocator = a, .registry = &registry };
    defer book.deinit(std.testing.io) catch unreachable;
    const view = book.open(std.testing.io, tmp.dir, "file.txt", 128) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), book.controllers.items.len);
        for (registry.slots.items) |slot| try std.testing.expect(slot.document == null);
        return err;
    };
    defer _ = registry.release(view) catch unreachable;
    try book.release(std.testing.io, view, false);
}
test "Windows editor host open allocation prefixes never strand native or document ownership" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPrefixes, .{});
}
