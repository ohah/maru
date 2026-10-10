//! 연결 작업의 main actor 배선. 경로가 아니라 registry 문서 신원과 이력 항목을 찾는다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../app_session.zig");
const ops = @import("mod.zig");
const publication = @import("shared_edit.zig");
const registry = maru.session.editor.document_registry;
const links = maru.session.editor.history_links;
const forward = maru.session.editor.history_forward;
const step = maru.session.editor.history_step;
const sel = maru.session.editor.selection;
const delta = maru.session.editor.delta;
const AppSession = host.AppSession;
const Term = host.Term;
pub const Input = struct { term: *Term, changes: []const delta.Change };
pub const Pending = struct { operation: u64, surface: u64, direction: step.Direction };
const Staged = struct {
    term: *Term,
    lease: registry.Lease,
    selections: sel.Selections,
    allocator: std.mem.Allocator,
    changes: delta.Inverse,
    view: ?publication.Publication = null,
    span: ?ops.syntax_color.EditSpan = null,
    restore: bool,
    fn deinit(self: *Staged, a: std.mem.Allocator) void {
        if (self.view) |*view| view.deinit();
        self.changes.deinit();
        self.allocator.free(self.selections.items);
        _ = self.lease.owner; // lease는 정산 동안 호출자가 소유한다.
        _ = a;
    }
};
fn cloneChanges(a: std.mem.Allocator, changes: []const delta.Change) !delta.Inverse {
    const items = try a.alloc(delta.Change, changes.len);
    var n: usize = 0;
    errdefer {
        for (items[0..n]) |c| a.free(c.text);
        a.free(items);
    }
    for (changes) |c| {
        items[n] = .{ .start = c.start, .end = c.end, .text = try a.dupe(u8, c.text) };
        n += 1;
    }
    return .{ .allocator = a, .changes = items };
}
fn busy(self: *AppSession, term: *Term) bool {
    return self.ime_active or self.ime_editor_commit_pending or term.rt.editor_preedit.len > 0;
}
fn capture(self: *AppSession, term: *Term, changes: []const delta.Change, restore: bool, modal_key_only: bool) !Staged {
    if (term.kind != .editor or term.rt.editor_diff != null or self.ime_editor_commit_pending or term.rt.editor_preedit.len > 0 or (self.ime_active and !modal_key_only)) return error.InputTransactionPending;
    const state = term.rt.editorDocument();
    if (state.remote != null) return error.RemoteDocument;
    const file = &(state.opened orelse return error.DocumentNotOpen).file;
    const lease = term.rt.editor_document_lease orelse return error.DocumentNotRegistered;
    if (lease.owner != self.editor_documents) return error.WrongRegistry;
    const selections = ops.snapshotSelections(file.allocator, term) catch |err| blk: {
        if (err != error.NoSelection) return err;
        break :blk sel.Selections.init(try file.allocator.dupe(sel.Selection, &.{sel.Selection.at(0)}), 0);
    };
    errdefer file.allocator.free(selections.items);
    const copied = try cloneChanges(self.allocator, changes);
    return .{ .term = term, .lease = lease, .selections = selections, .allocator = file.allocator, .changes = copied, .restore = restore };
}
fn finish(self: *AppSession, staged: []Staged) void {
    // 통지는 모든 뷰의 빌린 줄이 새 정본을 가리킨 다음에만 보낸다.
    for (staged) |*item| item.view.?.publish();
    for (staged) |*item| if (item.restore) {
        item.term.rt.editor_column_anchor = null;
        ops.writeBackSelections(self, item.term, item.selections);
    };
    for (staged) |*item| {
        item.view.?.finish(item.span);
        if (item.restore) {
            ops.breakUndoGroup(item.term);
            ops.refreshAfterEdit(self, item.term, item.span) catch {};
        }
    }
    self.metal_dirty = true;
}

/// 여러 열린 문서의 편집을 한 작업으로 만든다. 파일 로드·자동 저장은 이 API의 책임이 아니다.
pub fn apply(self: *AppSession, inputs: []const Input) !u64 {
    if (inputs.len < 2) return error.NotMultipleDocuments;
    return (try applyDocuments(self, inputs)).?;
}

/// 배치의 변경 없는 대상을 빼면 한 문서만 남을 수 있다. 같은 준비 경로를 쓰되 연결 기록은 만들지 않는다.
pub fn applyDocuments(self: *AppSession, inputs: []const Input) !?u64 {
    if (inputs.len == 0) return error.NoTargets;
    self.editor_documents.pruneHistoryLinks();
    var staged: std.ArrayList(Staged) = .empty;
    defer {
        for (staged.items) |*item| item.deinit(self.allocator);
        staged.deinit(self.allocator);
    }
    try staged.ensureTotalCapacity(self.allocator, inputs.len);
    for (inputs) |input| staged.appendAssumeCapacity(try capture(self, input.term, input.changes, input.term == @import("../pane.zig").activePane(self).activeTerm() and input.term.rt.editor_selection != null, false));
    const targets = try self.allocator.alloc(forward.Target, inputs.len);
    defer self.allocator.free(targets);
    for (staged.items, targets) |*item, *target| target.* = .{ .file = &item.term.rt.editorDocument().opened.?.file, .state = &item.term.rt.editorDocument().history, .selections = &item.selections, .changes = item.changes.changes, .view_id = item.term.surface.id };
    var prepared = try forward.Prepared.prepare(self.allocator, targets);
    defer prepared.deinit();
    const members = try self.allocator.alloc(links.Member, staged.items.len);
    defer self.allocator.free(members);
    for (staged.items, prepared.items.items, members) |*item, model, *member| {
        member.* = .{ .document = item.lease.document, .epoch = model.epoch, .entry = model.entry.id };
        item.span = ops.syntax_color.spanFromInverse(model.entry.inverse.changes);
        item.view = try publication.preparePublication(self, item.term, item.changes.delta(), model.sels.items.len, item.restore);
    }
    var record: ?links.Record = if (inputs.len > 1) try self.editor_documents.links.prepare(self.editor_documents.allocator, members) else null;
    errdefer if (record) |*pending| pending.deinit(self.editor_documents.allocator);
    try prepared.commit();
    const id = if (record) |pending| pending.id else null;
    if (record) |pending| self.editor_documents.links.publish(pending);
    finish(self, staged.items);
    return id;
}
fn top(term: *Term, direction: step.Direction) ?links.Member {
    const lease = term.rt.editor_document_lease orelse return null;
    const h = &term.rt.editorDocument().history;
    const entries = if (direction == .undo) h.undo[0..h.undo_len] else h.redo[0..h.redo_len];
    if (entries.len == 0) return null;
    return .{ .document = lease.document, .epoch = h.epoch, .entry = entries[entries.len - 1].id };
}
fn viewFor(self: *AppSession, document: registry.Handle, preferred: *Term) ?*Term {
    if (preferred.rt.editor_document_lease) |lease| if (lease.owner == self.editor_documents and std.meta.eql(document, lease.document)) return preferred;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        const lease = term.rt.editor_document_lease orelse continue;
        if (term.kind == .editor and lease.owner == self.editor_documents and std.meta.eql(document, lease.document)) return term;
    };
    return null;
}
/// null은 일반 이력 경로, bool은 요청 처리/거절이다. OOM·IME는 일반 Undo로 우회하지 않는다.
pub fn attempt(self: *AppSession, term: *Term, direction: step.Direction) ?bool {
    const member = top(term, direction) orelse return null;
    self.editor_documents.pruneHistoryLinks();
    const id = self.editor_documents.links.find(member.document, member.epoch, member.entry, direction) orelse return null;
    const record = self.editor_documents.links.get(id).?;
    if (busy(self, term)) {
        self.showNoticeKey(.editor_history_refused);
        return false;
    }
    var all_top = !record.invalid;
    for (record.members) |m| all_top = all_top and self.editor_documents.isHistoryTop(m, direction);
    if (!all_top) {
        perform(self, term, id, direction, true, false) catch {
            self.showNoticeKey(.editor_history_refused);
            return false;
        };
        self.showNoticeKey(.editor_history_changed);
        return true;
    }
    self.showConfirmChoiceKeys(.{ .linked_history = .{ .operation = id, .surface = term.surface.id, .direction = direction } }, if (direction == .undo) .editor_history_undo_prompt else .editor_history_redo_prompt, .{ .primary = .editor_history_all, .alternate = .editor_history_current });
    // VS Code 방향의 클릭·방향키·Enter 선택만 받는다. 확정 문자열 속 Y/N/D가 모달을 닫고
    // 남은 문자나 Enter를 뒤 문서에 흘리지 않게 글자 단축키를 사용하지 않는다.
    self.chrome_host.confirm.letter_keys = false;
    return true;
}
pub fn choose(self: *AppSession, pending: Pending, current_only: bool) void {
    const source = @import("../pane.zig").activePane(self).activeTerm();
    if (source.surface.id != pending.surface) {
        self.showNoticeKey(.editor_history_refused);
        return;
    }
    // AppKit의 빈 확인 키도 imeEnd 안에서 전달되며 ime_active는 그 뒤 defer에서 내려간다.
    // 실제 조합·확정 텍스트·삭제·거절이 없을 때만 이 모달 선택의 빈 transaction을 허용한다.
    const modal_key_only = self.ime_inserted.items.len == 0 and !self.ime_had_marked and
        !self.ime_marked_changed and !self.ime_did_delete and !self.ime_insert_failed and
        !self.ime_editor_commit_pending;
    perform(self, source, pending.operation, pending.direction, current_only, modal_key_only) catch {
        self.showNoticeKey(.editor_history_refused);
    };
}
fn perform(self: *AppSession, source: *Term, id: u64, direction: step.Direction, current_only: bool, modal_key_only: bool) !void {
    self.editor_documents.pruneHistoryLinks();
    const record = self.editor_documents.links.get(id) orelse return error.StaleOperation;
    if (record.direction != direction or (record.invalid and !current_only)) return error.StaleOperation;
    const focused = top(source, direction) orelse return error.StaleHistory;
    if (self.editor_documents.links.find(focused.document, focused.epoch, focused.entry, direction) != id) return error.StaleHistory;
    var staged: std.ArrayList(Staged) = .empty;
    defer {
        for (staged.items) |*item| item.deinit(self.allocator);
        staged.deinit(self.allocator);
    }
    try staged.ensureTotalCapacity(self.allocator, record.members.len);
    for (record.members) |member| {
        if (current_only and !std.meta.eql(member.document, focused.document)) continue;
        const term = viewFor(self, member.document, source) orelse return error.DocumentClosed;
        const current = top(term, direction) orelse return error.StaleHistory;
        if (!std.meta.eql(current, member)) return error.StaleHistory;
        const h = &term.rt.editorDocument().history;
        const entries = if (direction == .undo) h.undo[0..h.undo_len] else h.redo[0..h.redo_len];
        staged.appendAssumeCapacity(try capture(self, term, entries[entries.len - 1].inverse.changes, term == source, modal_key_only));
    }
    const targets = try self.allocator.alloc(step.Target, staged.items.len);
    defer self.allocator.free(targets);
    for (staged.items, targets) |*item, *target| {
        const member = top(item.term, direction).?;
        target.* = .{ .file = &item.term.rt.editorDocument().opened.?.file, .state = &item.term.rt.editorDocument().history, .selections = &item.selections, .expected_id = member.entry, .expected_epoch = member.epoch };
    }
    var prepared = try step.Prepared.prepare(self.allocator, targets, direction);
    defer prepared.deinit();
    for (staged.items, prepared.items.items) |*item, model| {
        item.span = ops.syntax_color.spanFromInverse(model.mirror.inverse.changes);
        item.view = try publication.preparePublication(self, item.term, item.changes.delta(), model.next_sels.items.len, item.restore);
    }
    try prepared.commit();
    if (current_only) self.editor_documents.links.remove(self.editor_documents.allocator, id) else self.editor_documents.links.get(id).?.direction = if (direction == .undo) .redo else .undo;
    finish(self, staged.items);
}
