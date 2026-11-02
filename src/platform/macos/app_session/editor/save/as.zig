//! Save As의 앱 전역 actor. 패널 callback은 요청 ID와 원본 창/문서를 다시 대조한다.
//! 원본 선행 저장은 정산하고 후속 snapshot은 기존 저장 큐의 hold로 보존한다.
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const editor = @import("../mod.zig");
const panel = @import("../../file_panel.zig");
const dispatch = @import("dispatch.zig");
const destination = @import("destination.zig");
const worker = @import("worker.zig");
const registry = maru.session.editor.document_registry;
const reservations = maru.session.editor.save_as_reservation;
const Store = reservations.Store(registry.DocumentIdentity);
const View = struct { session: *host.AppSession, term: *host.Term };
const EntryPath = struct { surface: u64, entry: u64, a: std.mem.Allocator, path: ?[]u8, created: ?*maru.session.dock_panel.Entry = null, window: u64 = 0 };
const Info = struct { canonical: []u8, key: []u8, file: ?reservations.FileIdentity, parent: reservations.FileIdentity, target: destination.Destination };
const CloseIntent = struct { window: u64, surface: u64, target: host.PendingClose };
const Operation = struct {
    token: Store.Token,
    lease: registry.Lease,
    source_path: ?[]u8,
    source: maru.session.editor.save_ops.BindingSource,
    untitled_number: ?u32 = null,
    source_disk_hash: ?u64 = null,
    selected: ?Info = null,
    taken: bool = false,
    writing: bool = false,
    completed: bool = false,
    save_again: bool = false,
    close_after: ?CloseIntent = null,
    prepared: ?destination.Prepared = null,
    paths: std.ArrayList(EntryPath) = .empty,
    prior_saves: std.ArrayList(reservations.Origin) = .empty,
};
var store: ?Store = null;
var operations: std.ArrayList(*Operation) = .empty;
var service: ?worker.Service = null;
var running: ?*Operation = null;
var test_gate: if (builtin.is_test) ?*worker.TestGate else void = if (builtin.is_test) null else {};

fn a() std.mem.Allocator {
    return dispatch.allocator();
}
fn identity(lease: registry.Lease) registry.DocumentIdentity {
    return .{ .owner = @intFromPtr(lease.owner), .slot = lease.document.slot, .generation = lease.document.generation };
}
fn same(term: *host.Term, lease: registry.Lease) bool {
    const live_lease = term.rt.editor_document_lease orelse return false;
    return std.meta.eql(identity(live_lease), identity(lease));
}
fn find(op: *const Operation, original: bool) ?View {
    for (host.editorSaveWindows()) |session| {
        if (original and session.recovered_session_window_generation != op.token.origin.window) continue;
        for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
            if (term.kind != .editor or !same(term, op.lease)) continue;
            if (original and term.surface.id != op.token.origin.surface) continue;
            return .{ .session = session, .term = term };
        };
    }
    return null;
}
fn current(op: *const Operation) bool {
    const state = op.lease.owner.get(op.lease) orelse return false;
    if (state.opened == null or state.remote != null or (state.path == null) != (state.untitled != null)) return false;
    return op.source.matches(.{ .document = @intFromPtr(state), .identity = identity(op.lease), .epoch = state.save_target_epoch, .path = state.path });
}
fn get(id: u64) ?*Operation {
    for (operations.items) |op| if (op.token.id == id) return op;
    return null;
}
fn byTerm(term: *host.Term) ?*Operation {
    for (operations.items) |op| if (!op.completed and same(term, op.lease)) return op;
    return null;
}
pub fn begin(session: *host.AppSession, term: *host.Term) void {
    if (term.kind != .editor or term.rt.editor_diff != null or term.rt.editor_merge != null) return;
    const state = term.rt.editorDocument();
    if (state.remote != null or state.untitled != null or state.path == null or state.opened == null) return;
    if (state.opened.?.file.read_only) {
        session.showNoticeKey(.editor_save_read_only);
        return;
    }
    if (term.file_entry) |entry| if (!entry.native_editor or entry.usesEditorBridge()) return;
    _ = beginFallible(session, term) catch {
        session.showNoticeKey(.app_save_failed);
        return;
    };
}
fn beginFallible(session: *host.AppSession, term: *host.Term) !*Operation {
    const state = term.rt.editorDocument();
    if (state.save_target_epoch == std.math.maxInt(u64)) return error.WriteFailed;
    if (store == null) store = Store.init(a());
    const source = term.rt.editor_document_lease orelse return error.WriteFailed;
    try operations.ensureUnusedCapacity(a(), 1);
    const lease = try @constCast(source.owner).retain(source, .request);
    errdefer _ = @constCast(lease.owner).release(lease) catch unreachable;
    const path = if (state.path) |old| try a().dupe(u8, old) else null;
    errdefer if (path) |old| a().free(old);
    const op = try a().create(Operation);
    errdefer a().destroy(op);
    const token = try store.?.begin(identity(lease), .{ .window = session.recovered_session_window_generation, .surface = term.surface.id });
    op.* = .{ .token = token, .lease = lease, .source_path = path, .source = .{ .document = @intFromPtr(state), .identity = identity(lease), .epoch = state.save_target_epoch, .path = path }, .untitled_number = if (state.untitled) |name| name.n else null };
    operations.appendAssumeCapacity(op);
    return op;
}
/// AppKit이 소유한 버퍼에 복사한 뒤에만 패널 요청을 가져간 것으로 표시한다.
pub fn take(session: *host.AppSession, id: *u64, path: []u8) usize {
    if (session.ime_active) return 0;
    for (operations.items) |op| {
        if (op.source_path == null or op.taken or op.token.origin.window != session.recovered_session_window_generation) continue;
        if (!current(op) or find(op, true) == null) {
            cancel(op);
            return 0;
        }
        if (path.len < op.source_path.?.len) return 0;
        @memcpy(path[0..op.source_path.?.len], op.source_path.?);
        id.* = op.token.id;
        op.taken = true;
        return op.source_path.?.len;
    }
    return 0;
}
fn physical(session: *host.AppSession, file: std.Io.File) !reservations.FileIdentity {
    const value = try panel.openedFileIdentity(session, file);
    return .{ .device = value.device, .inode = value.inode };
}
fn inspect(session: *host.AppSession, path: []const u8) !Info {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.NotFound;
    var parent = try panel.openPinnedFilePanelParent(session.io, path);
    defer parent.dir.close(session.io);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try parent.dir.realPath(session.io, &root_buf)];
    var parent_stat: std.posix.Stat = undefined;
    if (std.c.fstat(parent.dir.handle, &parent_stat) != 0) return error.NotFound;
    const parent_id: reservations.FileIdentity = .{ .device = @intCast(parent_stat.dev), .inode = @intCast(parent_stat.ino) };
    const canonical = try std.fs.path.join(a(), &.{ root, parent.basename });
    errdefer a().free(canonical);
    const key = try std.fmt.allocPrint(a(), "{d}:{d}:{s}", .{ parent_id.device, parent_id.inode, parent.basename });
    errdefer a().free(key);
    const fd = std.posix.openat(parent.dir.handle, parent.basename, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch |err| switch (err) {
        error.FileNotFound => return .{ .canonical = canonical, .key = key, .file = null, .parent = parent_id, .target = .absent },
        else => return error.NotFound,
    };
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(session.io);
    const stat = try file.stat(session.io);
    if (stat.kind != .file) return error.NotFound;
    const hash = try host.AppSession.stableOpenedFileHash(session.io, file, stat.inode);
    return .{ .canonical = canonical, .key = key, .file = try physical(session, file), .parent = parent_id, .target = .{ .existing = hash } };
}
fn releaseInfo(info: Info) void {
    a().free(info.canonical);
    a().free(info.key);
}
fn occupied(view: View, op: *Operation, info: Info) bool {
    for (host.editorSaveWindows()) |session| for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!op.source.protectsOpenTarget(session == view.session) or same(term, op.lease)) continue;
        const path = if (term.kind == .editor) term.rt.editorDocument().path orelse continue else if (term.file_entry) |entry| entry.path else continue;
        if (std.mem.eql(u8, path, info.canonical)) return true;
        if (info.file) |wanted| {
            const file = std.Io.Dir.cwd().openFile(view.session.io, path, .{}) catch continue;
            defer file.close(view.session.io);
            const actual = physical(view.session, file) catch continue;
            if (std.meta.eql(actual, wanted)) return true;
        }
    };
    return false;
}
fn aliasRelation(session: *host.AppSession, path: []const u8, file: std.Io.File, selected: Info) !reservations.NamespaceRelation {
    var source_stat: std.posix.Stat = undefined;
    if (std.c.fstat(file.handle, &source_stat) != 0) return error.ExternalConflict;
    var parent = try panel.openPinnedFilePanelParent(session.io, path);
    defer parent.dir.close(session.io);
    var parent_stat: std.posix.Stat = undefined;
    if (std.c.fstat(parent.dir.handle, &parent_stat) != 0) return error.ExternalConflict;
    const target_name = std.fs.path.basename(selected.canonical);
    var evidence: reservations.NamespaceEvidence = .{
        .same_parent = @as(u64, @intCast(parent_stat.dev)) == selected.parent.device and @as(u64, @intCast(parent_stat.ino)) == selected.parent.inode,
        .same_spelling = std.mem.eql(u8, parent.basename, target_name),
        .link_count = @intCast(source_stat.nlink),
        .ascii_case_alias = std.ascii.eqlIgnoreCase(parent.basename, target_name),
    };
    if (!evidence.same_parent or evidence.same_spelling or evidence.link_count == 1) return reservations.namespaceRelation(evidence);
    // inode 공유 여부만으로는 이름 둘이 같은 항목인지 판정할 수 없다.
    // 실제 이름 둘이 각각 존재하면 대소문자를 구분하는 볼륨의 이름도 다른 항목이다.
    var directory = try parent.dir.openDir(session.io, ".", .{ .iterate = true });
    defer directory.close(session.io);
    var entries = directory.iterate();
    while (try entries.next(session.io)) |entry| {
        evidence.source_entry_exact = evidence.source_entry_exact or std.mem.eql(u8, entry.name, parent.basename);
        evidence.destination_entry_exact = evidence.destination_entry_exact or std.mem.eql(u8, entry.name, target_name);
        if (evidence.source_entry_exact and evidence.destination_entry_exact) break;
    }
    return reservations.namespaceRelation(evidence);
}
pub fn reply(session: *host.AppSession, id: u64, path: []const u8) void {
    defer @import("wake.zig").request();
    const op = get(id) orelse return;
    if (op.completed or !op.taken or op.selected != null or op.token.origin.window != session.recovered_session_window_generation) return;
    const view = find(op, true) orelse {
        cancel(op);
        return;
    };
    if (path.len == 0 or !current(op)) {
        cancel(op);
        return;
    }
    const info = inspect(session, path) catch {
        session.showNoticeKey(.app_save_failed);
        cancel(op);
        return;
    };
    if (std.mem.eql(u8, info.canonical, op.source_path.?)) {
        releaseInfo(info);
        cancel(op);
        @import("../save_actions.zig").saveCommand(session, view.term);
        return;
    }
    if (info.file) |wanted| {
        const source = std.Io.Dir.cwd().openFile(session.io, op.source_path.?, .{}) catch null;
        if (source) |file| {
            defer file.close(session.io);
            const actual = physical(session, file) catch null;
            if (actual != null and std.meta.eql(actual.?, wanted)) {
                const relation = aliasRelation(session, op.source_path.?, file, info) catch .unknown;
                if (relation != .different) {
                    releaseInfo(info);
                    cancel(op);
                    if (relation == .same) @import("../save_actions.zig").saveCommand(session, view.term) else session.showNoticeKey(.app_save_failed);
                    return;
                }
            }
        }
    }
    if (occupied(view, op, info) or reservedPath(session, info.canonical, id)) {
        releaseInfo(info);
        session.showNoticeKey(.editor_untitled_already_open);
        cancel(op);
        return;
    }
    // 패널 확정 전에 시작된 code action/format 저장은 원본 선행 집합에 남긴다.
    for (host.editorSaveWindows()) |window| for (window.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| if (same(term, op.lease)) {
        if ((window.editor_save_actions.active and window.editor_save_actions.surface == term.surface.id) or
            (window.editor_format.waiting and window.editor_format.then_save and window.editor_format.waiting_surface == term.surface.id))
        {
            op.prior_saves.append(a(), .{ .window = window.recovered_session_window_generation, .surface = term.surface.id }) catch {
                releaseInfo(info);
                session.showNoticeKey(.app_save_failed);
                cancel(op);
                return;
            };
        }
    };
    store.?.accept(op.token, .{ .namespace = info.key, .file = info.file }) catch {
        releaseInfo(info);
        session.showNoticeKey(.app_save_failed);
        cancel(op);
        return;
    };
    op.selected = info;
}
/// 첫 저장도 Save As와 같은 문서/대상 예약 및 writer 수명을 쓴다. 이름 입력 UI는 caller가 소유한다.
pub fn firstSave(session: *host.AppSession, term: *host.Term, path: []const u8, overwriting: bool) void {
    defer @import("wake.zig").request();
    firstSaveFallible(session, term, path, overwriting) catch |err| {
        session.showNoticeKey(switch (err) {
            error.ExternalConflict => .editor_save_external_conflict,
            error.AlreadyOpen => .editor_untitled_already_open,
            else => .app_save_failed,
        });
    };
}
fn firstSaveFallible(session: *host.AppSession, term: *host.Term, path: []const u8, overwriting: bool) !void {
    const state = term.rt.editorDocument();
    if (state.path != null or state.untitled == null or state.remote != null or state.opened == null) return error.NotAnEditor;
    const info = try inspect(session, path);
    errdefer releaseInfo(info);
    if ((info.file != null) != overwriting) return error.ExternalConflict;
    const op = try beginFallible(session, term);
    errdefer cancel(op);
    op.taken = true; // native Save As sheet를 요청하지 않는다.
    if (occupied(.{ .session = session, .term = term }, op, info) or reservedPath(session, info.canonical, op.token.id)) return error.AlreadyOpen;
    try store.?.accept(op.token, .{ .namespace = info.key, .file = info.file });
    op.selected = info;
}

pub fn reservedPath(session: *host.AppSession, path: []const u8, except: ?u64) bool {
    var selected_exists = false;
    for (operations.items) |op| if (op.selected != null and op.token.id != except) {
        selected_exists = true;
        break;
    };
    if (!selected_exists) return false;
    const incoming = inspect(session, path) catch return false;
    defer releaseInfo(incoming);
    for (operations.items) |op| {
        if (op.token.id == except) continue;
        const selected = op.selected orelse continue;
        if (std.mem.eql(u8, incoming.canonical, selected.canonical)) return true;
        if (incoming.file) |file| {
            const fresh = inspect(session, selected.canonical) catch continue;
            defer releaseInfo(fresh);
            if (fresh.file) |held| if (std.meta.eql(file, held)) return true;
        }
    }
    return false;
}
pub const Hold = struct { id: u64, path: []const u8, parent: reservations.FileIdentity };
pub fn holdFor(term: *host.Term) ?Hold {
    const op = byTerm(term) orelse return null;
    if (store.?.route(identity(op.lease)) != .deferred) return null;
    const selected = op.selected orelse return null;
    return .{ .id = op.token.id, .path = selected.canonical, .parent = selected.parent };
}
pub fn holdForAdmission(session: *host.AppSession, term: *host.Term, interactive: bool) ?Hold {
    if (interactive) if (byTerm(term)) |op| {
        for (op.prior_saves.items, 0..) |origin, index| if (origin.window == session.recovered_session_window_generation and origin.surface == term.surface.id) {
            _ = op.prior_saves.orderedRemove(index);
            return null;
        };
    };
    return holdFor(term);
}
pub fn deferCommand(session: *host.AppSession, term: *host.Term) bool {
    _ = session;
    const op = byTerm(term) orelse return false;
    if (op.selected == null) return false;
    op.save_again = true;
    return true;
}
pub fn deferClose(session: *host.AppSession, term: *host.Term, target: host.PendingClose) bool {
    const op = byTerm(term) orelse return false;
    if (op.selected == null) return false;
    op.close_after = .{ .window = session.recovered_session_window_generation, .surface = term.surface.id, .target = target };
    return true;
}
fn ready(op: *Operation) bool {
    if (op.completed or op.selected == null or op.writing or !current(op) or dispatch.hasPendingDocument(identity(op.lease))) return false;
    for (host.editorSaveWindows()) |session| {
        for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| if (same(term, op.lease)) {
            if (session.ime_active or term.rt.editor_preedit.len > 0) return false;
            if ((session.editor_save_actions.active and session.editor_save_actions.surface == term.surface.id) or
                (session.editor_format.waiting and session.editor_format.waiting_surface == term.surface.id)) return false;
        };
    }
    return true;
}
pub fn claimsWriter() bool {
    if (running != null) return true;
    for (operations.items) |op| if (ready(op)) return true;
    return false;
}
fn prepare(op: *Operation, view: View) !void {
    const selected = op.selected.?;
    op.source_disk_hash = view.term.rt.editorDocument().opened.?.disk_hash;
    const fresh = try inspect(view.session, selected.canonical);
    defer releaseInfo(fresh);
    if (!std.meta.eql(selected.parent, fresh.parent) or !std.meta.eql(selected.file, fresh.file) or !std.meta.eql(selected.target, fresh.target) or occupied(view, op, fresh)) return error.ExternalConflict;
    const model_a = op.lease.owner.resourceAllocator(op.lease) orelse return error.WriteFailed;
    op.prepared = try destination.Prepared.init(model_a, view.term, selected.canonical, selected.target);
    op.prepared.?.work.?.expected_parent = selected.parent;
    for (host.editorSaveWindows()) |session| for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| if (same(term, op.lease)) {
        if (term.file_entry) |entry| {
            try op.paths.ensureUnusedCapacity(a(), 1);
            const path = try session.allocator.dupe(u8, selected.canonical);
            op.paths.appendAssumeCapacity(.{ .surface = term.surface.id, .entry = entry.id, .a = session.allocator, .path = path });
        } else if (op.untitled_number != null) {
            try op.paths.ensureUnusedCapacity(a(), 1);
            const path = try session.allocator.dupe(u8, selected.canonical);
            errdefer session.allocator.free(path);
            const entry = try @import("../untitled_save.zig").prepareEntry(session, term, path);
            op.paths.appendAssumeCapacity(.{ .surface = term.surface.id, .entry = entry.id, .a = session.allocator, .path = null, .created = entry, .window = session.recovered_session_window_generation });
            session.editor_batch_reserved_entries += 1;
        }
    };
}
// 창이 사라져도 포인터를 보관하지 않는다. 살아 있는 원래 창의 예약만 해제한다.
fn releaseEntrySlot(item: *const EntryPath) void {
    for (host.editorSaveWindows()) |session| {
        if (session.recovered_session_window_generation == item.window) {
            session.editor_batch_reserved_entries -= 1;
            return;
        }
    }
}

// 쓰기 중 창을 옮긴 경우에도 경로 채택 전에 실제 수신 창의 자리와 allocator를 검사한다.
fn canPublishEntries(op: *const Operation) bool {
    for (host.editorSaveWindows()) |session| {
        var adding: usize = 0;
        var owned: usize = 0;
        for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
            if (!same(term, op.lease)) continue;
            for (op.paths.items) |item| {
                if (item.surface != term.surface.id or item.created == null) continue;
                if (term.file_entry != null or item.a.ptr != session.allocator.ptr or item.a.vtable != session.allocator.vtable) return false;
                adding += 1;
                if (item.window == session.recovered_session_window_generation) owned += 1;
            }
        };
        var count: usize = 0;
        var it = panel.fileEntries(session);
        while (it.next()) |_| count += 1;
        if (!maru.session.editor.save_ops.canAddEntries(count, session.editor_batch_reserved_entries -| owned, adding, maru.session.dock_panel.max_entries)) return false;
    }
    return true;
}

fn finish(op: *Operation, success: bool, failure: ?anyerror) void {
    defer @import("wake.zig").request();
    const view = find(op, false);
    if (failure) |err| if (view) |v| v.session.showResponseNotice(switch (err) {
        error.ExternalConflict => .editor_save_external_conflict,
        error.NotFound => .editor_save_gone,
        error.TooLarge => .app_save_too_large,
        else => .app_save_failed,
    }, &.{});
    dispatch.releaseHeld(op.token.id, op.lease, success);
    _ = store.?.finish(op.token, success) catch unreachable;
    const again = op.save_again;
    op.save_again = false;
    if (op.close_after != null) {
        op.completed = true;
        if (op.selected) |info| releaseInfo(info);
        op.selected = null;
    } else remove(op);
    if (view) |v| if (again) @import("../save_actions.zig").saveCommand(v.session, v.term);
}

pub fn poll() void {
    for (operations.items) |op| if (op.completed) {
        if (dispatch.hasPendingDocument(identity(op.lease))) continue;
        const view = find(op, false);
        if (view) |v| {
            if ((v.session.editor_save_actions.active and v.session.editor_save_actions.surface == v.term.surface.id) or
                (v.session.editor_format.waiting and v.session.editor_format.waiting_surface == v.term.surface.id)) continue;
        }
        const intent = op.close_after.?;
        remove(op);
        for (host.editorSaveWindows()) |session| {
            if (session.recovered_session_window_generation != intent.window) continue;
            if (@import("../../pane.zig").activePane(session).activeTerm().surface.id == intent.surface) session.requestClose(intent.target);
        }
        return;
    };

    if (running) |op| {
        if (service.?.take()) |result| {
            op.prepared.?.work = result.prepared;
            running = null;
            const model_a = op.lease.owner.resourceAllocator(op.lease).?;
            if (result.failure) |failure| {
                finish(op, false, failure);
                return;
            }
            if (current(op)) for (host.editorSaveWindows()) |session| @import("../lsp.zig").notePathChanging(session, op.lease);
            if (!canPublishEntries(op) or !op.prepared.?.adopt(model_a, op.lease)) {
                if (find(op, false)) |v| v.session.showResponseNotice(.editor_untitled_written_not_adopted, &.{});
                finish(op, false, null);
                return;
            }
            op.lease.owner.get(op.lease).?.notifications.lsp_version +|= 1;
            const prepared = &op.prepared.?;
            const saved = prepared.work.?.content();
            for (host.editorSaveWindows()) |session| for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| if (same(term, op.lease)) {
                // Only adoption commits a new target. Earlier cancellation or
                // failure must not discard valid requests for the old URI.
                editor.completion_client.onSaveTargetChanged(session, term);
                for (op.paths.items) |*item| if (item.surface == term.surface.id and item.created != null and term.file_entry == null) {
                    releaseEntrySlot(item);
                    term.file_entry = item.created;
                    item.created = null;
                    session.workspaceChanged(.persisted_surface);
                };
                for (op.paths.items) |*item| if (item.surface == term.surface.id and item.path != null) {
                    if (term.file_entry) |entry| if (entry.id == item.entry) {
                        item.a.free(entry.path);
                        entry.path = item.path.?;
                        item.path = null;
                    };
                };
                @import("../backup.zig").markClean(session, term, saved, if (op.untitled_number) |number| .{ .untitled = number } else .{ .path = .{ .path = op.source_path.?, .disk_hash = op.source_disk_hash } });
                const old = term.rt.editor_grammar;
                term.rt.editor_grammar = maru.session.editor.language.grammarForPath(prepared.work.?.path);
                editor.guides_client.onGrammarChanged(term, old);
                term.rt.editor_syntax_folds_applied = false;
                editor.resetSyntaxForGrammar(session, term);
                _ = @import("../lsp.zig").noteSaved(session, term, saved);
                if (session.editor_save_close) |*state| if (std.meta.eql(state.identity, identity(op.lease))) {
                    state.epoch = term.rt.editorDocument().save_target_epoch;
                };
                session.metal_dirty = true;
                @import("../../sidebar.zig").rebuildSidebar(session) catch {};
            };
            finish(op, true, null);
        }
        return;
    }
    for (operations.items) |op| {
        if (op.selected == null or op.completed) continue;
        if (!current(op)) {
            finish(op, false, error.WriteFailed);
            return;
        }
        var input_ready = true;
        for (host.editorSaveWindows()) |session| for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| if (same(term, op.lease)) {
            if (session.ime_active) {
                input_ready = false;
                continue;
            }
            if (!editor.commitEditorPreedit(session, term)) {
                finish(op, false, error.OutOfMemory);
                return;
            }
        };
        if (!input_ready or !ready(op) or dispatch.writerBusy()) continue;
        const view = find(op, false) orelse {
            finish(op, false, error.WriteFailed);
            return;
        };
        prepare(op, view) catch |err| {
            finish(op, false, err);
            return;
        };
        if (service == null) service = worker.Service.init(a());
        startWriter(&op.prepared.?.work.?) catch |err| {
            finish(op, false, err);
            return;
        };
        op.prepared.?.work = null;
        _ = store.?.start(op.token, true, true) catch unreachable;
        op.writing = true;
        running = op;
        return;
    }
}
fn cancel(op: *Operation) void {
    if (op.selected != null) return;
    _ = store.?.cancel(op.token);
    remove(op);
}
fn remove(op: *Operation) void {
    for (operations.items, 0..) |item, i| if (item == op) {
        _ = operations.orderedRemove(i);
        break;
    };
    const model_a = op.lease.owner.resourceAllocator(op.lease).?;
    if (op.prepared) |*prepared| prepared.deinit(model_a);
    for (op.paths.items) |item| {
        if (item.path) |path| item.a.free(path);
        if (item.created) |entry| {
            releaseEntrySlot(&item);
            item.a.free(entry.path);
            item.a.destroy(entry);
        }
    }
    op.paths.deinit(a());
    op.prior_saves.deinit(a());
    if (op.selected) |info| releaseInfo(info);
    if (op.source_path) |path| a().free(path);
    _ = @constCast(op.lease.owner).release(op.lease) catch unreachable;
    a().destroy(op);
}
pub fn windowClosing(session: *host.AppSession) void {
    var i: usize = 0;
    while (i < operations.items.len) {
        const op = operations.items[i];
        if (op.token.origin.window == session.recovered_session_window_generation and op.selected == null) cancel(op) else i += 1;
    }
}
pub fn pending() usize {
    var count: usize = 0;
    for (operations.items) |op| if (op.selected != null) {
        count += 1;
    };
    return count;
}

pub fn cleanupForTests() void {
    if (!builtin.is_test) @compileError("test-only Save As cleanup");
    if (running) |op| {
        service.?.deinit(op.lease.owner.resourceAllocator(op.lease).?);
        service = null;
        running = null;
    }
    while (operations.items.len != 0) {
        const op = operations.items[0];
        op.save_again = false;
        op.close_after = null;
        if (op.completed) remove(op) else if (op.selected == null) cancel(op) else finish(op, false, null);
    }
    operations.deinit(a());
    operations = .empty;
    if (store) |*value| value.deinit();
    store = null;
    if (service) |*value| value.deinit(a());
    service = null;
}

fn startWriter(prepared: *@import("../local_save.zig").Prepared) !void {
    if (builtin.is_test) if (test_gate) |gate| return service.?.startBlockedForTest(prepared, gate);
    return service.?.start(prepared);
}
pub fn setGateForTests(gate: ?*worker.TestGate) void {
    if (!builtin.is_test) @compileError("test-only writer gate");
    test_gate = gate;
}
