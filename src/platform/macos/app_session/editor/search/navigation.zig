//! 클릭한 파일은 worker에서 같은 검색 규칙으로 다시 검증한다. main에서는 열린 bytes를 대조한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const AppSession = host.AppSession;
const editor = @import("../mod.zig");
const pane = @import("../../pane.zig");
const search = maru.session.editor.search;
const owner = @import("owner.zig");
const backend = @import("backend.zig");
const dock = @import("dock.zig");
const verify = @import("verify.zig");
pub const Ticket = struct {
    job: backend.Backend,
    expected: search.event.Match,
    span: search.event.Range,
    path: []u8,
    identity: search.request.Identity,
    generation: u64,
    stamp: u64,
    cancelled: bool = false,
    found: bool = false,
    loaded: ?*verify.Loaded = null,
    expected_hash: ?[32]u8 = null,
    surface: u64 = 0,
    document: ?search.request.DocumentIdentity = null,
    revision: u64 = 0,
    pub fn cancel(self: *Ticket) void {
        self.cancelled = true;
        self.job.cancel();
        if (self.loaded) |loaded| loaded.cancel.store(true, .release);
    }
    pub fn retired(self: *const Ticket) bool {
        return self.job.done() and (if (self.loaded) |loaded| loaded.done.load(.acquire) else true);
    }
    pub fn deinit(self: *Ticket, a: std.mem.Allocator) void {
        self.job.deinit();
        if (self.loaded) |loaded| loaded.deinit();
        self.expected.deinit(a);
        a.free(self.path);
    }
};
fn identity(term: *host.Term) search.request.DocumentIdentity {
    const doc = term.rt.editorDocument();
    return if (term.rt.editor_document_lease) |lease| .{ .owner = @intFromPtr(lease.owner), .slot = lease.document.slot, .generation = lease.document.generation } else .{ .owner = @intFromPtr(doc), .slot = 0, .generation = 0 };
}
fn offset(term: *host.Term, pos: search.event.Position) !usize {
    const doc = term.rt.editorDocument().opened orelse return error.NoDocument;
    const line = doc.file.lines.line(pos.line) orelse return error.StaleRequest;
    if (pos.byte > line.end_with_ending - line.start) return error.StaleRequest;
    const at = line.start + pos.byte;
    if (at < doc.file.content.len and doc.file.content[at] & 0xc0 == 0x80) return error.StaleRequest;
    return at;
}
fn reveal(self: *AppSession, term: *host.Term, span: search.event.Range) !void {
    const start_at = try offset(term, span.start);
    const end_at = try offset(term, span.end);
    if (end_at < start_at) return error.StaleRequest;
    _ = self.activateExistingFileTerm(term);
    if (pane.activePane(self).activeTerm() != term) return error.InputTransactionPending;
    self.editor_search.focused = null;
    try editor.navigateTo(self, .{ .offset = start_at });
    term.rt.editor_selection = maru.session.editor.selection.Selection.fromPoints(start_at, end_at);
    self.metal_dirty = true;
}
pub fn start(self: *AppSession, row_index: usize, range_index: usize) !void {
    const state = &self.editor_search;
    if (state.stamp == null or state.stamp.? != owner.fingerprint(self)) return error.StaleRequest;
    if (row_index >= state.result.model.rows.items.len) return error.StaleRequest;
    const row = state.result.model.rows.items[row_index];
    if (range_index >= row.match.ranges.len) return error.StaleRequest;
    const span = row.match.ranges[range_index];
    switch (row.source) {
        .model => |source| {
            if (source.composition != 0) {
                dock.changed(self);
                return;
            }
            for (self.tabs.items) |tab| for (tab.panes.items) |p| for (p.terms.items) |term| {
                if (term.kind != .editor or !std.meta.eql(identity(term), source.document)) continue;
                const doc = term.rt.editorDocument().opened orelse return error.NoDocument;
                if (doc.file.revision != source.revision or owner.compositionStamp(term) != source.composition) return error.StaleRequest;
                try reveal(self, term, span);
                return;
            };
            return error.StaleRequest;
        },
        .disk => {},
    }
    // 한 번에 클릭 재검증 하나만 소유한다. 취소 직후 교체도 기존 worker 수거까지 기다린다.
    if (state.nav != null) return error.NavigationPending;
    const root = self.file_tree.rootAt(row.root_index) orelse return error.StaleRequest;
    const cap = self.file_tree.rootCapabilityForPath(root) orelse return error.StaleRequest;
    const query = self.editor_project_search_query orelse return error.StaleRequest;
    var expected: search.event.Match = .{ .path = try self.allocator.dupe(u8, row.match.path), .text = undefined, .ranges = undefined, .text_start = row.match.text_start, .text_truncated = row.match.text_truncated };
    errdefer self.allocator.free(expected.path);
    expected.text = try self.allocator.dupe(u8, row.match.text);
    errdefer self.allocator.free(expected.text);
    expected.ranges = try self.allocator.dupe(search.event.Range, row.match.ranges);
    errdefer self.allocator.free(expected.ranges);
    const path = try std.fs.path.join(self.allocator, &.{ root, try search.request.relativePath(row.match.path) });
    errdefer self.allocator.free(path);
    var job: backend.Backend = .{ .a = self.allocator, .io = self.io };
    errdefer job.deinit();
    const request_identity = state.result.identity orelse return error.StaleRequest;
    var output: search.request.State = .{ .identity = request_identity, .limits = dock.limits };
    defer output.deinit(self.allocator);
    var models: std.ArrayList(backend.model.Captured) = .empty;
    defer models.deinit(self.allocator);
    var budget = dock.budget;
    budget.navigation_bytes = @intCast(editor.read_limit_bytes);
    if (@import("builtin").is_test and query.helper_for_test != null) {
        try job.startTarget(query.helper_for_test.?, .{ .path = root, .identity = cap.identity }, row.match.path, query.text, query.options, &output, &models, budget);
    } else {
        try job.startBundledTarget(.{ .path = root, .identity = cap.identity }, row.match.path, query.text, query.options, &output, &models, budget);
    }
    state.nav = .{ .job = job, .expected = expected, .span = span, .path = path, .identity = request_identity, .generation = state.result.generation, .stamp = owner.fingerprint(self) };
}
fn openFailure(self: *AppSession, err: anyerror) void {
    self.showNoticeKey(switch (err) {
        error.TooLarge => .dbg_editor_too_large,
        error.NotUtf8 => .dbg_editor_not_utf8,
        error.OutOfMemory => .dbg_editor_oom,
        else => .dbg_editor_unreadable,
    });
}
pub fn poll(self: *AppSession) void {
    const state = &self.editor_search;
    const active = if (state.nav) |*value| value else return;
    if (active.cancelled) {
        if (active.retired()) {
            active.deinit(self.allocator);
            state.nav = null;
        }
        return;
    }
    if (active.stamp != owner.fingerprint(self) or active.generation != state.result.generation) {
        active.cancel();
        return;
    }
    if (active.loaded) |loaded| {
        if (!loaded.done.load(.acquire)) return;
        var completed = state.nav.?;
        state.nav = null;
        defer completed.deinit(self.allocator);
        if (loaded.failure != null or loaded.hash == null or completed.expected_hash == null or !std.mem.eql(u8, &loaded.hash.?, &completed.expected_hash.?)) {
            dock.changed(self);
            return;
        }
        for (self.tabs.items) |tab| for (tab.panes.items) |p| for (p.terms.items) |term| {
            if (term.surfaceId() != completed.surface or term.kind != .editor or !std.meta.eql(identity(term), completed.document.?)) continue;
            const doc = term.rt.editorDocument().opened orelse {
                dock.changed(self);
                return;
            };
            if (doc.file.revision != completed.revision) {
                dock.changed(self);
                return;
            }
            reveal(self, term, completed.span) catch {
                dock.changed(self);
            };
            return;
        };
        dock.changed(self);
        return;
    }
    if (active.job.take(active.identity)) |value| {
        var batch = value;
        defer batch.deinit(self.allocator);
        for (batch.rows.items) |row| {
            if (!std.meta.eql(row.match.text_start, active.expected.text_start) or !std.mem.eql(u8, row.match.text, active.expected.text) or row.match.text_truncated != active.expected.text_truncated) continue;
            for (row.match.ranges) |span| if (std.meta.eql(span, active.span)) {
                active.found = true;
            };
        }
    }
    const done = active.job.completion() orelse return;
    var finished = state.nav.?;
    state.nav = null;
    const ticket = &finished;
    var moved = false;
    defer if (!moved) ticket.deinit(self.allocator);
    if (done.status != .complete or !ticket.found) {
        if (done.failure) |err| switch (err) {
            error.TooLarge, error.OutOfMemory, error.Unopenable, error.UnsupportedFile, error.ReadFailed, error.StatFailed => openFailure(self, err),
            else => {},
        };
        dock.changed(self);
        return;
    }
    const opened = pane.openFileTermInActivePane(self, ticket.path, .text) catch |err| {
        openFailure(self, err);
        dock.changed(self);
        return;
    };
    const doc = opened.term.rt.editorDocument().opened orelse {
        dock.changed(self);
        return;
    };
    const hash = ticket.job.targetHash() orelse {
        dock.changed(self);
        return;
    };
    const loaded = verify.Loaded.start(self.allocator, &doc.file) catch |err| {
        openFailure(self, err);
        dock.changed(self);
        return;
    };
    // 새 문서를 연 변화는 이 클릭의 일부다. 결과는 다시 만들되 검증 사본은 자기 신원으로 계속 소유한다.
    dock.changed(self);
    ticket.loaded = loaded;
    ticket.expected_hash = hash;
    ticket.surface = opened.term.surfaceId();
    ticket.document = identity(opened.term);
    ticket.revision = doc.file.revision;
    ticket.stamp = owner.fingerprint(self);
    ticket.generation = state.result.generation;
    state.nav = finished;
    moved = true;
    // 소유권이 state로 이동했으므로 위 defer는 실행하지 않는다.
}
