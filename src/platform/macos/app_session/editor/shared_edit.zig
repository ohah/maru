//! 같은 창의 연결된 에디터 뷰에 본문·줄·좌표를 게시하는 host coordinator.
//! 할당 가능한 준비를 정본 변경 앞으로 모으고 게시 자체는 할당하지 않는다.
const std = @import("std");
const maru = @import("maru");
const app_session = @import("../../app_session.zig");
const AppSession = app_session.AppSession;
const Term = app_session.Term;
const editor_ops = @import("mod.zig");
const editor_selection = maru.session.editor.selection;
const shared_policy = maru.session.editor.shared_edit;
const syntax_color = editor_ops.syntax_color;

// 정본 변경 전 연결 뷰의 줄 저장소를 모두 준비한다. 단일 뷰는 기존 빠른 경로를 유지한다.
// 같은 창의 분할 뷰도 포함한다. 다른 창에 걸친 게시 여부는 registry의 전체 view 수로 검증한다.
const SharedPreparedView = struct {
    term: *Term,
    lines: [][]const u8,
    scroll: ?editor_ops.ScrollAnchor,
    first_piece: u32,
    primary: ?editor_selection.Selection,
    extras: []editor_selection.Selection,
    folds: ?MappedFolds,
};

// 접힘 좌표는 정본 변경 전에 새 줄 번호로 준비한다. 옛 본문은 게시 후 읽지 않는다.
const MappedFolds = struct {
    ranges: []maru.session.editor.fold.Range,
    folded: []u32,
    previous: []u32,
    marks: []editor_ops.FoldMark,
    len: usize,

    fn deinit(self: MappedFolds, allocator: std.mem.Allocator) void {
        allocator.free(self.ranges);
        allocator.free(self.folded);
        allocator.free(self.previous);
        allocator.free(self.marks);
    }
};

fn mappedRow(file: *const maru.session.editor.edit_doc.EditableFile, d: maru.session.editor.delta.Delta, at: usize) u32 {
    var cursor: usize = 0;
    var rows: usize = 0;
    for (d.changes) |c| {
        if (at < c.start) break;
        rows += file.lines.lineAt(c.start) - file.lines.lineAt(cursor);
        // 삽입 경계는 새 글자 뒤, 삭제/교체 안의 점은 변경 시작에 붙는다.
        if (at < c.end or (at == c.start and c.end > c.start)) return @intCast(rows);
        rows += std.mem.count(u8, c.text, "\n");
        cursor = c.end;
    }
    rows += file.lines.lineAt(at) - file.lines.lineAt(cursor);
    return @intCast(rows);
}

fn mappedRange(view: *Term, d: maru.session.editor.delta.Delta, range: maru.session.editor.fold.Range) ?maru.session.editor.fold.Range {
    const file = &view.rt.editorDocument().opened.?.file;
    const head = file.lines.line(range.head) orelse return null;
    const last = file.lines.line(range.last_hidden) orelse return null;
    for (d.changes) |c| {
        if (c.start <= head.start and c.end > head.contentEnd()) return null;
    }
    const h = mappedRow(file, d, head.start);
    const l = mappedRow(file, d, last.start);
    if (l <= h) return null;
    return .{ .head = h, .first_hidden = h + 1, .last_hidden = l, .level = range.level };
}

fn prepareFolds(self: *AppSession, view: *Term, d: maru.session.editor.delta.Delta, line_count: usize) !MappedFolds {
    var count: usize = 0;
    var last_head: ?u32 = null;
    for (view.rt.editor_fold_ranges) |range| {
        const mapped = mappedRange(view, d, range) orelse continue;
        if (last_head == null or last_head.? != mapped.head) count += 1;
        last_head = mapped.head;
    }
    const ranges = try self.allocator.alloc(maru.session.editor.fold.Range, count);
    errdefer self.allocator.free(ranges);
    const folded = try self.allocator.alloc(u32, count);
    errdefer self.allocator.free(folded);
    const previous = try self.allocator.alloc(u32, count);
    errdefer self.allocator.free(previous);
    const marks = try self.allocator.alloc(editor_ops.FoldMark, line_count);
    var n: usize = 0;
    var len: usize = 0;
    var folded_index: usize = 0;
    const heads = editor_ops.foldedHeads(view);
    for (view.rt.editor_fold_ranges) |range| {
        const mapped = mappedRange(view, d, range) orelse continue;
        // 병합된 머리는 중복 범위/선택으로 남기지 않는다.
        if (n > 0 and ranges[n - 1].head == mapped.head) {
            ranges[n - 1].last_hidden = @max(ranges[n - 1].last_hidden, mapped.last_hidden);
        } else {
            ranges[n] = mapped;
            n += 1;
        }
        while (folded_index < heads.len and heads[folded_index] < range.head) folded_index += 1;
        if (folded_index < heads.len and heads[folded_index] == range.head and
            (len == 0 or folded[len - 1] != mapped.head))
        {
            folded[len] = mapped.head;
            len += 1;
        }
    }
    // 사전 계산과 게시 배열의 범위 수가 일치해야 한다.
    std.debug.assert(n == count);
    return .{ .ranges = ranges, .folded = folded, .previous = previous, .marks = marks, .len = len };
}

pub fn apply(self: *AppSession, term: *Term, d: maru.session.editor.delta.Delta, sels: *editor_selection.Selections) !maru.session.editor.delta.Inverse {
    const revision = (term.rt.editorDocument().opened orelse return error.DocumentNotOpen).file.revision;
    return applyAtRevision(self, term, d, sels, revision);
}

// 일반 타이핑은 같은 메인 스레드 사건 안에서 현재 revision을 넘긴다. 준비한 요청은 기준을 검증한다.
pub fn applyAtRevision(self: *AppSession, term: *Term, d: maru.session.editor.delta.Delta, sels: *editor_selection.Selections, base_revision: u64) !maru.session.editor.delta.Inverse {
    const state = term.rt.editorDocument();
    const opened = state.opened orelse return error.DocumentNotOpen;
    if (opened.file.revision != base_revision) return error.StaleRevision;
    if (opened.file.read_only) return error.ReadOnly;
    // Undo 기록 준비는 호출자가 정본 변경 전에 완료한다.
    return applyPrepared(self, term, d, sels, sels.items.len);
}

pub const Publication = struct {
    session: *AppSession,
    term: *Term,
    change: maru.session.editor.delta.Delta,
    views: []SharedPreparedView,
    line_count: usize,
    restore_source: bool,
    published: bool = false,
    pub fn deinit(self: *Publication) void {
        if (!self.published) for (self.views) |view| {
            self.session.allocator.free(view.lines);
            self.session.allocator.free(view.extras);
            if (view.folds) |folds| folds.deinit(self.session.allocator);
        };
        self.session.allocator.free(self.views);
    }
    // 모든 정본 변경 뒤, 통지 전에 모든 뷰의 빌린 배열부터 교체한다.
    pub fn publish(self: *Publication) void {
        // 여기부터 줄 배열과 offset의 게시에는 할당이 없다. 옛 본문을 빌린 배열은 모두 갈아 끼운다.
        for (self.views) |v| {
            for (0..self.line_count) |i| v.lines[i] = self.term.rt.editorDocument().opened.?.file.lineText(i) orelse "";
            if (v.term.rt.editor_lines.len > 0) self.session.allocator.free(v.term.rt.editor_lines);
            v.term.rt.editor_lines = v.lines;
            v.term.rt.editor_shared_lines_ready = true;
            if (v.term == self.term and self.restore_source) {
                if (self.term.rt.editor_shared_selection_buf) |buf| self.session.allocator.free(buf);
                self.term.rt.editor_shared_selection_buf = v.extras;
                continue;
            }
            v.term.rt.editor_selection = v.primary;
            if (v.term.rt.editor_extra_selections.len > 0) self.session.allocator.free(v.term.rt.editor_extra_selections);
            v.term.rt.editor_extra_selections = v.extras;
            v.term.rt.editor_column_anchor = null;
            if (v.term.rt.editor_auto_closed_at) |at| {
                v.term.rt.editor_auto_closed_at = shared_policy.mapAutoClose(self.change, at);
            }
        }
        self.published = true;
    }
    pub fn finish(self: *Publication, span: ?syntax_color.EditSpan) void {
        editor_ops.notifyDocumentEdit(self.session, self.term);
        for (self.views) |v| {
            if (v.term == self.term and self.restore_source) continue;
            if (v.folds) |folds| {
                editor_ops.publishMappedFolds(self.session, v.term, folds.ranges, folds.folded, folds.previous, folds.marks, folds.len);
                editor_ops.refreshMappedViewAfterEdit(self.session, v.term, span) catch {};
            } else editor_ops.refreshViewAfterEdit(self.session, v.term, span) catch {};
            // 다른 뷰는 같은 위치 삽입도 원래 보던 텍스트를 anchor로 유지한다.
            const mapped_scroll: ?editor_ops.ScrollAnchor = if (v.scroll) |a| .{
                .off = shared_policy.mapSelection(self.change, editor_selection.Selection.at(a.off)).focus,
            } else null;
            editor_ops.restoreScrollAnchor(self.session, v.term, mapped_scroll, .{ .changes = &.{} });
            v.term.rt.editor_first_piece = v.first_piece;
        }
    }
};
pub fn preparePublication(self: *AppSession, term: *Term, d: maru.session.editor.delta.Delta, result_selection_count: usize, restore_source: bool) !Publication {
    const state = term.rt.editorDocument();
    const file = &(state.opened orelse return error.DocumentNotOpen).file;
    const lease = term.rt.editor_document_lease orelse return error.DocumentNotRegistered;
    const count = lease.owner.viewCount(lease) orelse return error.DocumentNotRegistered;
    if (file.read_only) return error.ReadOnly;
    if (!d.isWellFormed()) return error.MalformedDelta;
    if (d.changes.len > 0 and d.changes[d.changes.len - 1].end > file.content.len) return error.OutOfRange;
    var line_count = file.lineCount();
    for (d.changes) |c| {
        line_count -= std.mem.count(u8, file.content[c.start..c.end], "\n");
        line_count += std.mem.count(u8, c.text, "\n");
    }
    const prepared = try self.allocator.alloc(SharedPreparedView, count);
    errdefer self.allocator.free(prepared);
    var n: usize = 0;
    errdefer {
        for (prepared[0..n]) |v| {
            self.allocator.free(v.lines);
            self.allocator.free(v.extras);
            if (v.folds) |folds| folds.deinit(self.allocator);
        }
    }
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |view| {
        if (view.kind != .editor or view.rt.editorDocument() != state) continue;
        if (n == count) return error.SharedViewCountMismatch;
        if (view != term and (view.rt.editor_preedit.len > 0 or (self.ime_editor_commit_pending and self.ime_terminal_target_id == view.surface.id))) return error.SharedCompositionBusy;
        const lines = try self.allocator.alloc([]const u8, line_count);
        errdefer self.allocator.free(lines);
        var primary = view.rt.editor_selection;
        var extras: []editor_selection.Selection = undefined;
        if (view == term and restore_source) {
            extras = try self.allocator.alloc(editor_selection.Selection, result_selection_count -| 1);
        } else if (primary) |sel| {
            // 매핑으로 서로 겹친 선택도 정본 변경 전에 합친다. primary 소유는 유지한다.
            const mapped = try self.allocator.alloc(editor_selection.Selection, view.rt.editor_extra_selections.len + 1);
            defer self.allocator.free(mapped);
            mapped[0] = shared_policy.mapSelection(d, sel);
            for (view.rt.editor_extra_selections, 1..) |extra, i| mapped[i] = shared_policy.mapSelection(d, extra);
            const merged = editor_selection.mergeOverlapping(mapped, 0);
            primary = mapped[merged.primary];
            extras = try self.allocator.alloc(editor_selection.Selection, merged.len - 1);
            var k: usize = 0;
            for (mapped[0..merged.len], 0..) |item, i| {
                if (i == merged.primary) continue;
                extras[k] = item;
                k += 1;
            }
        } else {
            extras = try self.allocator.alloc(editor_selection.Selection, 0);
        }
        const folds: ?MappedFolds = if ((view == term and restore_source) or view.rt.editor_folded_len == 0) null else prepareFolds(self, view, d, line_count) catch |err| {
            self.allocator.free(extras);
            return err;
        };
        prepared[n] = .{ .term = view, .lines = lines, .scroll = editor_ops.captureScrollAnchor(view) orelse if (view != term and view.rt.editor_first_line == 0) editor_ops.ScrollAnchor{ .off = 0 } else null, .first_piece = view.rt.editor_first_piece, .primary = primary, .extras = extras, .folds = folds };
        n += 1;
    };
    // 다른 창의 view는 아직 이 coordinator에 연결하지 않았다. 부분 게시로 넘기지 않는다.
    if (n != count) return error.SharedViewCountMismatch;
    return .{ .session = self, .term = term, .change = d, .views = prepared, .line_count = line_count, .restore_source = restore_source };
}
pub fn applyPrepared(self: *AppSession, term: *Term, d: maru.session.editor.delta.Delta, sels: *editor_selection.Selections, result_selection_count: usize) !maru.session.editor.delta.Inverse {
    const state = term.rt.editorDocument();
    const lease = term.rt.editor_document_lease orelse return state.opened.?.file.apply(d, sels);
    const count = lease.owner.viewCount(lease) orelse return error.DocumentNotRegistered;
    if (count <= 1) return state.opened.?.file.apply(d, sels);
    var publication = try preparePublication(self, term, d, result_selection_count, true);
    defer publication.deinit();
    const before = try self.allocator.dupe(editor_selection.Selection, sels.items);
    defer self.allocator.free(before);
    const before_state = sels.*;
    const inverse = state.opened.?.file.apply(d, sels) catch |err| {
        @memcpy(sels.items, before);
        sels.* = before_state;
        return err;
    };
    publication.publish();
    publication.finish(syntax_color.spanFromInverse(inverse.changes));
    return inverse;
}
