//! 메인 actor의 문서 열거를 유한 배치로 진행한다. worker에는 소유한 rope·조합 사본만 넘긴다.
const std = @import("std");
const maru = @import("maru");
const app = @import("../../../app_session.zig");
const model = @import("model.zig");
const search = maru.session.editor.search;
const selections = maru.session.editor.selection;
pub const Prepared = struct {
    root: []u8,
    root_index: usize,
    stamp: u64,
    cursor: usize = 0,
    ready: bool = false,
    retained: usize = 0,
    snapshot_bytes: usize,
    state: search.request.State,
    models: std.ArrayList(model.Captured) = .empty,
    seen: std.ArrayList(search.request.DocumentIdentity) = .empty,
    pub fn deinit(self: *Prepared, a: std.mem.Allocator) void {
        for (self.models.items) |*captured| captured.deinit(a);
        self.models.deinit(a);
        self.seen.deinit(a);
        self.state.deinit(a);
        a.free(self.root);
    }
    pub fn init(session: *app.AppSession, root_index: usize, request: u64, limits: search.request.Limits, snapshot_bytes: usize) !Prepared {
        if (!session.file_tree_initialized or session.tabs.items.len == 0) return error.NoSearchRoot;
        if (session.ime_active or session.ime_editor_commit_pending) return error.InputTransactionPending;
        const active = @import("../../pane.zig").activePane(session).activeTerm();
        if (app.termCwdIsRemote(active) or active.kind == .editor and active.rt.editorDocument().remote != null) return error.RemoteSearchRoot;
        const root = session.file_tree.rootAt(root_index) orelse return error.NoSearchRoot;
        const capability = session.file_tree.rootCapabilityForPath(root) orelse return error.UnverifiedSearchRoot;
        if (!std.mem.eql(u8, capability.path, root)) return error.UnverifiedSearchRoot;
        const stamp = fingerprint(session);
        return .{ .root = try session.allocator.dupe(u8, root), .root_index = root_index, .stamp = stamp, .snapshot_bytes = snapshot_bytes, .state = .{ .identity = .{ .request = request, .root = session.file_tree.rootGeneration(), .models = stamp }, .limits = limits } };
    }
    pub fn fresh(self: *const Prepared, session: *app.AppSession) bool {
        return session.file_tree_initialized and !session.ime_active and !session.ime_editor_commit_pending and
            self.stamp == fingerprint(session);
    }
    /// 복사할 본문 수는 호출자의 배치 예산으로 제한한다. 본문 크기에 따른 main 복사는 없다.
    pub fn advance(self: *Prepared, session: *app.AppSession, max_views: usize) !bool {
        if (!self.fresh(session)) return error.StaleRequest;
        if (self.ready) return true;
        var index: usize = 0;
        var consumed: usize = 0;
        for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
            defer index += 1;
            if (index < self.cursor) continue;
            if (consumed == max_views) return false;
            consumed += 1;
            self.cursor += 1;
            try self.capture(session, term);
        };
        self.ready = true;
        return true;
    }
    fn capture(self: *Prepared, session: *app.AppSession, term: *app.Term) !void {
        if (term.kind != .editor) {
            if (term.file_entry) |entry| if (entry.usesEditorBridge() and entry.remote_origin_dest.len == 0) {
                if (relativeToRoot(self.root, entry.path)) |relative| {
                    try self.state.occupy(session.allocator, relative);
                    self.state.excluded += 1;
                }
            };
            return;
        }
        const state = term.rt.editorDocument();
        if (state.remote != null) return;
        const path = state.path orelse return;
        const normalized = try std.fs.path.resolve(session.allocator, &.{path});
        defer session.allocator.free(normalized);
        const relative = relativeToRoot(self.root, normalized) orelse return;
        try self.state.occupy(session.allocator, relative);
        const opened = state.opened orelse {
            self.state.excluded += 1;
            return;
        };
        if (term.rt.editor_diff != null) {
            self.state.excluded += 1;
            return;
        }
        const document: search.request.DocumentIdentity = if (term.rt.editor_document_lease) |lease|
            .{ .owner = @intFromPtr(lease.owner), .slot = lease.document.slot, .generation = lease.document.generation }
        else
            .{ .owner = @intFromPtr(state), .slot = 0, .generation = 0 };
        for (self.seen.items) |seen| if (std.meta.eql(seen, document)) return;
        try self.seen.append(session.allocator, document);
        const composing = composingView(session, term);
        const before = self.models.items.len;
        if (!try model.captureUnique(session.allocator, &self.state, &self.models, relative, document, compositionStamp(composing), &opened.file, &self.retained, self.snapshot_bytes)) return;
        const owner = composing orelse return;
        var ranges: std.ArrayList(selections.Selection) = .empty;
        defer ranges.deinit(session.allocator);
        try ranges.append(session.allocator, selections.Selection.fromPoints(owner.rt.editor_preedit_at, owner.rt.editor_preedit_end));
        try ranges.appendSlice(session.allocator, owner.rt.editor_extra_selections);
        const merged = selections.mergeOverlapping(ranges.items, 0);
        const overlay_bytes = std.math.mul(usize, merged.len, owner.rt.editor_preedit.len) catch std.math.maxInt(usize);
        if (overlay_bytes > self.snapshot_bytes -| self.retained) {
            var rejected = self.models.pop().?;
            rejected.deinit(session.allocator);
            self.retained -= opened.file.buf.byteLen();
            self.state.excluded += 1;
            return;
        }
        // 정본·Undo에 적용하지 않는다. worker가 같은 원문 축의 비겹침 조합 범위를 적용한다.
        for (ranges.items[0..merged.len]) |range| {
            try model.addOverlay(session.allocator, &self.models.items[before], range.start(), range.end(), owner.rt.editor_preedit);
            self.retained += owner.rt.editor_preedit.len;
        }
    }
};
pub fn relativeToRoot(root: []const u8, path: []const u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(path) or root.len == 0) return null;
    const trimmed = if (root.len > 1 and root[root.len - 1] == '/') root[0 .. root.len - 1] else root;
    if (std.mem.eql(u8, trimmed, "/")) return search.request.relativePath(path[1..]) catch null;
    if (!std.mem.startsWith(u8, path, trimmed) or path.len <= trimmed.len or path[trimmed.len] != '/') return null;
    return search.request.relativePath(path[trimmed.len + 1 ..]) catch null;
}
fn composingView(session: *app.AppSession, term: *app.Term) ?*app.Term {
    const document = term.rt.editorDocument();
    for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |candidate| {
        if (candidate.kind == .editor and candidate.rt.editorDocument() == document and candidate.rt.editor_preedit.len > 0) return candidate;
    };
    return null;
}
fn compositionStamp(term: ?*app.Term) u64 {
    const owner = term orelse return 0;
    if (owner.rt.editor_preedit.len == 0) return 0;
    var hash = std.hash.Wyhash.init(0);
    hash.update(owner.rt.editor_preedit);
    hash.update(std.mem.asBytes(&owner.rt.editor_preedit_at));
    hash.update(std.mem.asBytes(&owner.rt.editor_preedit_end));
    for (owner.rt.editor_extra_selections) |selection| {
        const start = selection.start();
        const end = selection.end();
        hash.update(std.mem.asBytes(&start));
        hash.update(std.mem.asBytes(&end));
    }
    return hash.final() | 1;
}
pub fn fingerprint(session: *app.AppSession) u64 {
    if (!session.file_tree_initialized or session.tabs.items.len == 0) return 0;
    var hash = std.hash.Wyhash.init(0);
    const root_generation = session.file_tree.rootGeneration();
    hash.update(std.mem.asBytes(&root_generation));
    hash.update(std.mem.asBytes(&session.editor_project_search_disk_generation));
    hash.update(std.mem.asBytes(&session.editor_project_search_watch_generation));
    for (0..session.file_tree.rootCount()) |i| {
        const root = session.file_tree.rootAt(i).?;
        if (session.file_tree.rootCapabilityForPath(root)) |cap| {
            hash.update(std.mem.asBytes(&cap.identity.device));
            hash.update(std.mem.asBytes(&cap.identity.inode));
        }
    }
    const remote = app.termCwdIsRemote(@import("../../pane.zig").activePane(session).activeTerm());
    hash.update(std.mem.asBytes(&remote));
    for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        // 배치 cursor는 모든 surface를 센다. 터미널 삽입·닫기도 순회를 무효화해야 빠진 문서가 없다.
        hash.update(std.mem.asBytes(&term.surface.id));
        const kind: u8 = @intCast(@intFromEnum(term.kind));
        hash.update(std.mem.asBytes(&kind));
        if (term.kind != .editor) {
            if (term.file_entry) |entry| if (entry.usesEditorBridge()) {
                hash.update(std.mem.asBytes(&term.surface.id));
                hash.update(std.mem.asBytes(&entry.path.len));
                hash.update(entry.path);
                hash.update(std.mem.asBytes(&entry.editor_revision));
                hash.update(std.mem.asBytes(&entry.editor_epoch));
            };
            continue;
        }
        hash.update(std.mem.asBytes(&term.surface.id));
        const document = term.rt.editorDocument();
        if (term.rt.editor_document_lease) |lease| {
            const owner = @intFromPtr(lease.owner);
            hash.update(std.mem.asBytes(&owner));
            hash.update(std.mem.asBytes(&lease.document.slot));
            hash.update(std.mem.asBytes(&lease.document.generation));
        } else {
            const owner = @intFromPtr(document);
            hash.update(std.mem.asBytes(&owner));
        }
        const supported = term.rt.editor_diff == null and document.remote == null;
        hash.update(std.mem.asBytes(&supported));
        const opened_present = document.opened != null;
        hash.update(std.mem.asBytes(&opened_present));
        if (document.path) |path| {
            hash.update(std.mem.asBytes(&path.len));
            hash.update(path);
        }
        if (document.opened) |opened| hash.update(std.mem.asBytes(&opened.file.revision));
        const composition = compositionStamp(term);
        hash.update(std.mem.asBytes(&composition));
    };
    return hash.final();
}

const backend = @import("backend.zig");
/// 검색어·옵션은 요청 owner가 소유한다. worker가 끝날 때까지 교체 요청은 하나만 보관한다.
pub const Query = struct {
    text: []u8,
    helper_for_test: ?[]u8 = null,
    options: search.query.Options,
    includes: std.ArrayList([]const u8) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    root_index: usize,
    limits: search.request.Limits,
    budget: backend.Budget,
    pub fn init(a: std.mem.Allocator, root_index: usize, text: []const u8, options: search.query.Options, limits: search.request.Limits, budget: backend.Budget) !Query {
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidQuery;
        var q: Query = .{ .text = try a.dupe(u8, text), .options = options, .root_index = root_index, .limits = limits, .budget = budget };
        errdefer q.deinit(a);
        for (options.includes) |glob| try copyGlob(a, &q.includes, glob);
        for (options.excludes) |glob| try copyGlob(a, &q.excludes, glob);
        q.options.includes = q.includes.items;
        q.options.excludes = q.excludes.items;
        return q;
    }
    pub fn deinit(self: *Query, a: std.mem.Allocator) void {
        a.free(self.text);
        if (self.helper_for_test) |helper| a.free(helper);
        for (self.includes.items) |glob| a.free(glob);
        for (self.excludes.items) |glob| a.free(glob);
        self.includes.deinit(a);
        self.excludes.deinit(a);
    }
};
fn copyGlob(a: std.mem.Allocator, list: *std.ArrayList([]const u8), text: []const u8) !void {
    const owned = try a.dupe(u8, text);
    errdefer a.free(owned);
    try list.append(a, owned);
}
pub const Live = struct { job: backend.Backend, stamp: u64, identity: search.request.Identity };
pub fn cancel(session: *app.AppSession) void {
    if (session.editor_project_search_live) |*live| live.job.cancel();
    if (session.editor_project_search_prepared) |*prepared| prepared.deinit(session.allocator);
    session.editor_project_search_prepared = null;
}
pub fn poll(session: *app.AppSession) void {
    const query = if (session.editor_project_search_query) |*q| q else return;
    const stamp = fingerprint(session);
    if (session.editor_project_search_failure != null and session.editor_project_search_failure_stamp == stamp and session.editor_project_search_failure_request == session.editor_project_search_request) return;
    if (session.editor_project_search_live) |*live| {
        if (live.stamp == stamp and live.identity.request == session.editor_project_search_request) return;
        live.job.cancel();
        if (!live.job.done()) return;
        live.job.deinit();
        session.editor_project_search_live = null;
    }
    // 입력 transaction은 끝날 때까지 기다린다. 조합이 있는 것 자체는 검색을 막지 않는다.
    if (session.ime_active or session.ime_editor_commit_pending) return;
    if (session.editor_project_search_prepared) |*prepared| if (!prepared.fresh(session)) {
        prepared.deinit(session.allocator);
        session.editor_project_search_prepared = null;
    };
    if (session.editor_project_search_prepared == null) {
        session.prepareProjectSearch(query.root_index, session.editor_project_search_request, query.limits, query.budget.snapshot_bytes) catch |err| {
            fail(session, err);
            return;
        };
    }
    const prepared = &session.editor_project_search_prepared.?;
    const ready = prepared.advance(session, 32) catch |err| {
        fail(session, err);
        prepared.deinit(session.allocator);
        session.editor_project_search_prepared = null;
        return;
    };
    if (!ready or session.editor_project_search_watch_generation != session.file_tree.rootGeneration()) return;
    var job: backend.Backend = .{ .a = session.allocator, .io = session.io };
    var budget = query.budget;
    budget.expected_root = session.file_tree.rootCapabilityForPath(prepared.root).?.identity;
    const started = if (@import("builtin").is_test and query.helper_for_test != null)
        job.start(query.helper_for_test.?, prepared.root, query.text, query.options, &prepared.state, &prepared.models, budget)
    else
        job.startBundled(prepared.root, query.text, query.options, &prepared.state, &prepared.models, budget);
    started catch |err| {
        fail(session, err);
        job.deinit();
        return;
    };
    session.editor_project_search_live = .{ .job = job, .stamp = prepared.stamp, .identity = prepared.state.identity };
    session.editor_project_search_failure = null;
    prepared.deinit(session.allocator);
    session.editor_project_search_prepared = null;
}
pub fn take(session: *app.AppSession) ?backend.Batch {
    // 확정 대기 중에는 revision이 아직 그대로여도 이전 결과를 UI에 전달하면 안 된다.
    if (session.ime_active or session.ime_editor_commit_pending) return null;
    const live = if (session.editor_project_search_live) |*value| value else return null;
    if (session.editor_project_search_query == null or live.stamp != fingerprint(session) or live.identity.request != session.editor_project_search_request) {
        live.job.cancel();
        return null;
    }
    return live.job.take(live.identity);
}
pub fn deinit(session: *app.AppSession) void {
    cancel(session);
    if (session.editor_project_search_live) |*live| live.job.deinit();
    session.editor_project_search_live = null;
    if (session.editor_project_search_query) |*query| query.deinit(session.allocator);
    session.editor_project_search_query = null;
}

fn fail(session: *app.AppSession, err: anyerror) void {
    session.editor_project_search_failure = err;
    session.editor_project_search_failure_stamp = fingerprint(session);
    session.editor_project_search_failure_request = session.editor_project_search_request;
}
